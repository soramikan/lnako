import { gunzipSync, gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 0 ? value >>> 1 : (value >>> 1) ^ 0xedb88320;
  return value >>> 0;
});

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
if (arguments_.includes("--self-test")) {
  if (arguments_.length !== 1) throw new Error("usage: node tools/check_distribution.mjs --self-test");
  await selfTest();
} else {
  const archive = parseArchiveArgument(arguments_);
  await verifyDistribution(archive);
  console.log(`配布物検証: ${archive}`);
}

function parseArchiveArgument(arguments_) {
  if (arguments_.length !== 2 || arguments_[0] !== "--archive") throw new Error("usage: node tools/check_distribution.mjs --archive /absolute/path/archive.tar.gz");
  const archive = arguments_[1];
  if (!isAbsolute(archive)) throw new Error("--archiveには絶対パスを指定してください");
  if (!archive.endsWith(".tar.gz") && !archive.endsWith(".zip")) throw new Error("配布アーカイブは.tar.gzまたは.zipでなければなりません");
  return resolve(archive);
}

async function verifyDistribution(archivePath) {
  const archiveBytes = await readFile(archivePath);
  const archiveName = basename(archivePath);
  const baseName = archiveName.endsWith(".tar.gz") ? archiveName.slice(0, -7) : archiveName.slice(0, -4);
  const directory = dirname(archivePath);
  const checksumPath = `${archivePath}.sha256`;
  const sbomPath = join(directory, `${baseName}.spdx.json`);
  const sumsPath = join(directory, "SHA256SUMS");
  const expectedDigest = sha256(archiveBytes);
  const checksumText = await readFile(checksumPath, "utf8");
  if (checksumText !== `${expectedDigest}  ${archiveName}\n`) throw new Error(`アーカイブSHA-256 sidecarが一致しません: ${archivePath}`);
  const sums = parseChecksums(await readFile(sumsPath, "utf8"));
  if (sums.get(archiveName) !== expectedDigest) throw new Error(`SHA256SUMSにアーカイブのdigestがありません: ${archiveName}`);
  const externalSbom = await readFile(sbomPath);
  if (sums.get(basename(sbomPath)) !== sha256(externalSbom)) throw new Error(`SHA256SUMSにSBOMのdigestがありません: ${basename(sbomPath)}`);

  const entries = archivePath.endsWith(".tar.gz") ? parseTarGz(archiveBytes) : parseZip(archiveBytes);
  const prefix = `${baseName}/`;
  for (const name of entries.keys()) {
    if (!name.startsWith(prefix) || name.includes("..") || name.startsWith("/") || name.includes("\\")) {
      throw new Error(`アーカイブ内の相対パスが不正です: ${name}`);
    }
  }
  const manifestBytes = requireEntry(entries, `${prefix}manifest.json`);
  const sbomBytes = requireEntry(entries, `${prefix}sbom.spdx.json`);
  if (!Buffer.from(sbomBytes).equals(externalSbom)) throw new Error("外部SBOMとアーカイブ内SBOMが一致しません");
  const manifest = parseJson(manifestBytes, "manifest.json");
  const sbom = parseJson(sbomBytes, "sbom.spdx.json");
  validateManifest(manifest, prefix, entries);
  validateSbom(sbom, prefix, entries);
  validateArchiveContents(manifest, sbom, prefix, entries);
  return { manifest, sbom, entries };
}

function validateManifest(manifest, prefix, entries) {
  if (manifest.schema !== "lnako.distribution-manifest.v1" || manifest.name !== "lnako" || typeof manifest.version !== "string" || typeof manifest.target !== "string") {
    throw new Error("配布manifestのschemaまたは識別子が不正です");
  }
  if (!manifest.source || !/^[0-9a-f]{40}$/.test(manifest.source.commit) || typeof manifest.source.dirty !== "boolean") throw new Error("配布manifestのsourceが不正です");
  if (!manifest.build || manifest.build.zig !== "0.16.0" || manifest.build.llvm !== "22.1.8" || manifest.build.compatJsIncluded !== false) throw new Error("配布manifestの固定toolchain情報が不正です");
  if (!manifest.toolchain || typeof manifest.toolchain.included !== "boolean" || !Array.isArray(manifest.toolchain.files)) throw new Error("配布manifestのtoolchainが不正です");
  const binary = validateManifestArtifact(manifest.artifacts?.binary, prefix, entries, "binary");
  const runtime = validateManifestArtifact(manifest.artifacts?.runtime, prefix, entries, "runtime");
  if (manifest.executable !== binary.path || manifest.runtimeLibrary !== runtime.path || manifest.sbom !== "sbom.spdx.json") throw new Error("配布manifestのartifactまたはSBOM pathが一致しません");
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) throw new Error("配布manifestのfilesが空です");
  const seen = new Set();
  for (const file of manifest.files) {
    if (!file || !isSafeRelativePath(file.path) || file.path === "manifest.json" || file.path === "sbom.spdx.json" || !/^[0-9a-f]{64}$/.test(file.sha256) || !Number.isSafeInteger(file.size) || seen.has(file.path)) throw new Error("配布manifestのfile recordが不正です");
    seen.add(file.path);
    const bytes = requireEntry(entries, `${prefix}${file.path}`);
    if (sha256(bytes) !== file.sha256 || bytes.length !== file.size) throw new Error(`配布manifestのfile digestが不一致です: ${file.path}`);
  }
  if (!seen.has(binary.path) || !seen.has(runtime.path)) throw new Error("配布manifestのartifactがfilesにありません");
  if (manifest.toolchain.included) {
    if (manifest.toolchain.files.length === 0) throw new Error("LLVM/LLD同梱manifestにtoolchain filesがありません");
    for (const file of manifest.toolchain.files) {
      if (!isSafeRelativePath(file) || !seen.has(file)) throw new Error(`LLVM/LLD toolchain fileがmanifestにありません: ${file}`);
      requireEntry(entries, `${prefix}${file}`);
    }
  } else if (manifest.toolchain.files.length !== 0) throw new Error("LLVM/LLD非同梱manifestにtoolchain filesがあります");
}

function validateManifestArtifact(artifact, prefix, entries, label) {
  if (!artifact || !isSafeRelativePath(artifact.path) || artifact.path === "manifest.json" || artifact.path === "sbom.spdx.json" || !/^[0-9a-f]{64}$/.test(artifact.sha256)) throw new Error(`配布manifestの${label} artifactが不正です`);
  const bytes = requireEntry(entries, `${prefix}${artifact.path}`);
  if (sha256(bytes) !== artifact.sha256) throw new Error(`配布manifestの${label} digestが不一致です`);
  return artifact;
}

function validateSbom(sbom, prefix, entries) {
  if (sbom.spdxVersion !== "SPDX-2.3" || sbom.SPDXID !== "SPDXRef-DOCUMENT" || !Array.isArray(sbom.packages) || !Array.isArray(sbom.files) || !Array.isArray(sbom.relationships)) {
    throw new Error("SBOMのSPDX 2.3構造が不正です");
  }
  if (!sbom.packages.some((component) => component.name === "lnako" && component.licenseDeclared === "MIT")) throw new Error("SBOMにlnako packageがありません");
  const seen = new Set();
  for (const file of sbom.files) {
    if (!file || !isSafeRelativePath(file.fileName) || seen.has(file.fileName) || !Array.isArray(file.checksums)) throw new Error("SBOMのfile recordが不正です");
    const checksum = file.checksums.find((candidate) => candidate.algorithm === "SHA256")?.checksumValue;
    if (!/^[0-9a-f]{64}$/.test(checksum ?? "")) throw new Error(`SBOMのSHA-256が不正です: ${file.fileName}`);
    seen.add(file.fileName);
    const bytes = requireEntry(entries, `${prefix}${file.fileName}`);
    if (sha256(bytes) !== checksum) throw new Error(`SBOMのfile digestが不一致です: ${file.fileName}`);
  }
  if (!sbom.relationships.some((relationship) => relationship.spdxElementId === "SPDXRef-DOCUMENT" && relationship.relationshipType === "DESCRIBES" && relationship.relatedSpdxElement === "SPDXRef-Package-lnako")) {
    throw new Error("SBOMのlnako relationshipがありません");
  }
}

function validateArchiveContents(manifest, sbom, prefix, entries) {
  const expectedArchiveEntries = new Set([`${prefix}manifest.json`, `${prefix}sbom.spdx.json`]);
  for (const file of manifest.files) expectedArchiveEntries.add(`${prefix}${file.path}`);
  if (entries.size !== expectedArchiveEntries.size) throw new Error("アーカイブにmanifest外のentryがあります");
  for (const name of expectedArchiveEntries) if (!entries.has(name)) throw new Error(`manifestに対応するentryがありません: ${name}`);
  for (const name of entries.keys()) if (!expectedArchiveEntries.has(name)) throw new Error(`manifest外のアーカイブentryです: ${name}`);

  const expectedSbomFiles = new Set([...expectedArchiveEntries]
    .filter((name) => name !== `${prefix}sbom.spdx.json`)
    .map((name) => name.slice(prefix.length)));
  const actualSbomFiles = new Set();
  for (const file of sbom.files) {
    if (!isSafeRelativePath(file.fileName) || actualSbomFiles.has(file.fileName)) throw new Error(`SBOMのfile pathが不正です: ${file.fileName}`);
    actualSbomFiles.add(file.fileName);
  }
  if (actualSbomFiles.size !== expectedSbomFiles.size) throw new Error("SBOMのfile一覧がアーカイブと一致しません");
  for (const name of expectedSbomFiles) if (!actualSbomFiles.has(name)) throw new Error(`SBOMに対応するfileがありません: ${name}`);
}

function parseTarGz(bytes) {
  const tar = gunzipSync(bytes);
  const entries = new Map();
  let offset = 0;
  let zeroBlocks = 0;
  for (; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (isZeroBlock(header)) {
      zeroBlocks += 1;
      offset += 512;
      if (zeroBlocks >= 2) break;
      continue;
    }
    if (zeroBlocks !== 0 || !validTarChecksum(header)) throw new Error("tar header checksumまたは終端が不正です");
    if (!header.subarray(257, 263).toString("ascii").startsWith("ustar")) throw new Error("未対応のtar formatです");
    const name = readField(header, 0, 100);
    const type = header[156];
    if (type !== 0 && type !== 0x30) throw new Error(`tarのregular file以外のentryです: ${name}`);
    const size = parseOctal(readField(header, 124, 12));
    const dataStart = offset + 512;
    const dataEnd = dataStart + size;
    const paddedEnd = dataStart + Math.ceil(size / 512) * 512;
    if (!name || dataEnd > tar.length || paddedEnd > tar.length || entries.has(name)) throw new Error(`tar entryが不正です: ${name}`);
    entries.set(name, Buffer.from(tar.subarray(dataStart, dataEnd)));
    offset = paddedEnd;
  }
  if (zeroBlocks < 2 || offset > tar.length || tar.subarray(offset).some((byte) => byte !== 0)) throw new Error("tarの終端が不正です");
  return entries;
}

function parseZip(bytes) {
  const eocdOffset = findZipEnd(bytes);
  const entryCount = bytes.readUInt16LE(eocdOffset + 10);
  const centralSize = bytes.readUInt32LE(eocdOffset + 12);
  const centralOffset = bytes.readUInt32LE(eocdOffset + 16);
  if (bytes.readUInt16LE(eocdOffset + 4) !== 0 || bytes.readUInt16LE(eocdOffset + 6) !== 0 ||
      bytes.readUInt16LE(eocdOffset + 8) !== entryCount || entryCount === 0 ||
      centralOffset + centralSize !== eocdOffset) throw new Error("zip central directoryが不正です");

  const localEntries = [];
  for (let offset = 0; offset < centralOffset;) {
    requireZipBytes(bytes, offset, 30, "local header");
    if (bytes.readUInt32LE(offset) !== 0x04034b50) throw new Error("zip local headerが不正です");
    const flags = bytes.readUInt16LE(offset + 6);
    const method = bytes.readUInt16LE(offset + 8);
    const crc = bytes.readUInt32LE(offset + 14);
    const compressedSize = bytes.readUInt32LE(offset + 18);
    const uncompressedSize = bytes.readUInt32LE(offset + 22);
    const nameLength = bytes.readUInt16LE(offset + 26);
    const extraLength = bytes.readUInt16LE(offset + 28);
    if (flags !== 0x800 || method !== 0 || compressedSize !== uncompressedSize) throw new Error("未対応のzip entry形式です");
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const dataEnd = dataStart + compressedSize;
    requireZipBytes(bytes, nameStart, nameLength + extraLength + compressedSize, "local entry");
    const name = decodeZipName(bytes, nameStart, nameLength);
    const data = Buffer.from(bytes.subarray(dataStart, dataEnd));
    if (!name || localEntries.some((entry) => entry.name === name) || crc32(data) !== crc) throw new Error(`zip entryが不正です: ${name}`);
    localEntries.push({ name, data, crc, compressedSize, offset });
    offset = dataEnd;
  }
  if (localEntries.length !== entryCount) throw new Error("zip local entry数がcentral directoryと一致しません");

  const entries = new Map();
  let centralCursor = centralOffset;
  for (let index = 0; index < entryCount; index += 1) {
    requireZipBytes(bytes, centralCursor, 46, "central header");
    if (bytes.readUInt32LE(centralCursor) !== 0x02014b50) throw new Error("zip central headerが不正です");
    const flags = bytes.readUInt16LE(centralCursor + 8);
    const method = bytes.readUInt16LE(centralCursor + 10);
    const crc = bytes.readUInt32LE(centralCursor + 16);
    const compressedSize = bytes.readUInt32LE(centralCursor + 20);
    const uncompressedSize = bytes.readUInt32LE(centralCursor + 24);
    const nameLength = bytes.readUInt16LE(centralCursor + 28);
    const extraLength = bytes.readUInt16LE(centralCursor + 30);
    const commentLength = bytes.readUInt16LE(centralCursor + 32);
    const diskNumber = bytes.readUInt16LE(centralCursor + 34);
    const localOffset = bytes.readUInt32LE(centralCursor + 42);
    const nameStart = centralCursor + 46;
    requireZipBytes(bytes, nameStart, nameLength + extraLength + commentLength, "central entry");
    const name = decodeZipName(bytes, nameStart, nameLength);
    const local = localEntries[index];
    if (flags !== 0x800 || method !== 0 || uncompressedSize !== compressedSize || diskNumber !== 0 ||
        name !== local.name || crc !== local.crc || compressedSize !== local.compressedSize || localOffset !== local.offset) {
      throw new Error(`zip central directory entryがlocal headerと一致しません: ${name}`);
    }
    entries.set(name, local.data);
    centralCursor = nameStart + nameLength + extraLength + commentLength;
  }
  if (centralCursor !== eocdOffset) throw new Error("zip central directoryの長さが不正です");
  return entries;
}

function findZipEnd(bytes) {
  for (let offset = bytes.length - 22; offset >= Math.max(0, bytes.length - 65557); offset -= 1) {
    if (offset < 0 || bytes.readUInt32LE(offset) !== 0x06054b50) continue;
    requireZipBytes(bytes, offset, 22, "end of central directory");
    const commentLength = bytes.readUInt16LE(offset + 20);
    if (offset + 22 + commentLength === bytes.length) return offset;
  }
  throw new Error("zip end of central directoryがありません");
}

function requireZipBytes(bytes, offset, length, label) {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > bytes.length) {
    throw new Error(`zip ${label}の範囲が不正です`);
  }
}

function decodeZipName(bytes, offset, length) {
  const raw = bytes.subarray(offset, offset + length);
  const name = raw.toString("utf8");
  if (!Buffer.from(name, "utf8").equals(raw)) throw new Error("zip entry名がUTF-8ではありません");
  return name;
}

function parseChecksums(text) {
  const result = new Map();
  for (const line of text.trimEnd().split("\n")) {
    const match = /^([0-9a-f]{64})  (.+)$/.exec(line.replace(/\r$/, ""));
    if (match === null || result.has(match[2])) throw new Error(`SHA256SUMSの行が不正です: ${line}`);
    result.set(match[2], match[1]);
  }
  return result;
}

function readField(buffer, offset, length) {
  return buffer.subarray(offset, offset + length).toString("utf8").replace(/\0.*$/, "").trim();
}

function parseOctal(value) {
  if (value.length === 0) return 0;
  if (!/^[0-7]+$/.test(value)) throw new Error(`tar sizeが不正です: ${value}`);
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`tar sizeが不正です: ${value}`);
  return parsed;
}

function isZeroBlock(block) {
  return block.every((byte) => byte === 0);
}

function validTarChecksum(header) {
  const stored = parseOctal(readField(header, 148, 8));
  let sum = 0;
  for (let index = 0; index < header.length; index += 1) sum += index >= 148 && index < 156 ? 0x20 : header[index];
  return stored === sum;
}

function isSafeRelativePath(path) {
  return typeof path === "string" && path.length > 0 && !path.startsWith("/") && !path.includes("\\") &&
    path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = (value >>> 8) ^ crcTable[(value ^ byte) & 0xff];
  return (value ^ 0xffffffff) >>> 0;
}

function requireEntry(entries, name) {
  const value = entries.get(name);
  if (value === undefined) throw new Error(`アーカイブに必要なentryがありません: ${name}`);
  return value;
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch (error) {
    throw new Error(`${label}がJSONではありません: ${error.message}`);
  }
}

async function selfTest() {
  const temporary = await mkdtemp(join(tmpdir(), "lnako-distribution-check-"));
  try {
    const binary = resolve(temporary, "fake-lnako");
    const runtime = resolve(temporary, "fake-runtime.a");
    await writeFile(binary, "fake executable\n");
    await writeFile(runtime, "fake runtime\n");
    const output = resolve(temporary, "dist");
    const targets = [...new Set([hostTarget(), "linux-x64", "windows-x64"])];
    const archives = [];
    for (const target of targets) {
      const result = spawnSync(process.execPath, [resolve(root, "tools/create_distribution.mjs"), "--version", "9.9.9-test", "--target", target, "--output", output, "--binary", binary, "--runtime", runtime], {
        cwd: root,
        encoding: "utf8",
        maxBuffer: 4 * 1024 * 1024,
      });
      if (result.status !== 0) throw new Error(`配布self-test生成に失敗しました(${target}): ${result.stderr}`);
      const extension = target === "windows-x64" ? "zip" : "tar.gz";
      const archive = resolve(output, `lnako-9.9.9-test-${target}.${extension}`);
      await verifyDistribution(archive);
      archives.push(archive);
    }
    const tarArchive = archives.find((archive) => archive.endsWith(".tar.gz"));
    const zipArchive = archives.find((archive) => archive.endsWith(".zip"));
    if (tarArchive === undefined || zipArchive === undefined) throw new Error("配布self-testにtar.gzまたはzipがありません");
    await expectRejectedArchive(tarArchive, mutateTarHeader, "tar-checksum");
    await expectRejectedArchive(tarArchive, mutateTarExtraEntry, "tar-extra-entry");
    await expectRejectedArchive(tarArchive, mutateTarTrailing, "tar-trailing");
    await expectRejectedArchive(zipArchive, mutateZipPayload, "zip-crc");
    console.log("配布物self-test: tar.gz・zip・SHA-256・SPDX SBOM・manifest・改変拒否検証成功");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function expectRejectedArchive(archivePath, mutate, label) {
  const temporary = await mkdtemp(join(tmpdir(), `lnako-distribution-negative-${label}-`));
  try {
    const archiveName = basename(archivePath);
    const baseName = archiveName.endsWith(".tar.gz") ? archiveName.slice(0, -7) : archiveName.slice(0, -4);
    const mutated = mutate(await readFile(archivePath));
    const sbom = await readFile(join(dirname(archivePath), `${baseName}.spdx.json`));
    const caseArchive = join(temporary, archiveName);
    const archiveDigest = sha256(mutated);
    const sbomDigest = sha256(sbom);
    await writeFile(caseArchive, mutated);
    await writeFile(`${caseArchive}.sha256`, `${archiveDigest}  ${archiveName}\n`);
    await writeFile(join(temporary, `${baseName}.spdx.json`), sbom);
    await writeFile(join(temporary, "SHA256SUMS"), `${archiveDigest}  ${archiveName}\n${sbomDigest}  ${baseName}.spdx.json\n`);
    let rejected = false;
    try {
      await verifyDistribution(caseArchive);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`配布self-testが不正な${label}アーカイブを受理しました`);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

function mutateTarHeader(bytes) {
  const tar = gunzipSync(bytes);
  const mutated = Buffer.from(tar);
  mutated[0] ^= 1;
  return gzipSync(mutated, { level: 9, mtime: 0 });
}

function mutateTarExtraEntry(bytes) {
  const tar = gunzipSync(bytes);
  const firstName = readField(tar, 0, 100);
  const prefixEnd = firstName.lastIndexOf("/");
  if (prefixEnd < 0) throw new Error("配布self-testのtar prefixがありません");
  const name = `${firstName.slice(0, prefixEnd + 1)}__unmanifested_self_test__`;
  const data = Buffer.from("unexpected entry\n", "utf8");
  const header = createTarTestHeader(name, data.length);
  const payload = tar.subarray(0, tar.length - 1024);
  const padding = Buffer.alloc((512 - (data.length % 512)) % 512);
  return gzipSync(Buffer.concat([payload, header, data, padding, Buffer.alloc(1024)]), { level: 9, mtime: 0 });
}

function mutateTarTrailing(bytes) {
  const tar = gunzipSync(bytes);
  return gzipSync(Buffer.concat([tar, Buffer.from("trailing bytes", "utf8")]), { level: 9, mtime: 0 });
}

function mutateZipPayload(bytes) {
  const mutated = Buffer.from(bytes);
  if (mutated.readUInt32LE(0) !== 0x04034b50) throw new Error("配布self-testのzip local headerがありません");
  const nameLength = mutated.readUInt16LE(26);
  const extraLength = mutated.readUInt16LE(28);
  const dataStart = 30 + nameLength + extraLength;
  if (dataStart >= mutated.length) throw new Error("配布self-testのzip payloadがありません");
  mutated[dataStart] ^= 1;
  return mutated;
}

function createTarTestHeader(name, size) {
  const header = Buffer.alloc(512, 0);
  writeTarTestField(header, 0, 100, name);
  writeTarTestOctal(header, 100, 8, 0o644);
  writeTarTestOctal(header, 124, 12, size);
  header.fill(0x20, 148, 156);
  header[156] = 0x30;
  writeTarTestField(header, 257, 6, "ustar\0");
  writeTarTestField(header, 263, 2, "00");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  writeTarTestOctal(header, 148, 8, checksum);
  return header;
}

function writeTarTestField(buffer, offset, length, value) {
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length > length) throw new Error(`配布self-testのtar fieldが長すぎます: ${value}`);
  bytes.copy(buffer, offset);
}

function writeTarTestOctal(buffer, offset, length, value) {
  const text = Math.trunc(value).toString(8);
  if (text.length > length - 1) throw new Error(`配布self-testのtar数値が長すぎます: ${value}`);
  buffer.fill(0x30, offset, offset + length - 1);
  buffer.write(text, offset + length - 1 - text.length, "ascii");
  buffer[offset + length - 1] = 0;
}

function hostTarget() {
  if (process.platform === "darwin" && process.arch === "arm64") return "macos-arm64";
  if (process.platform === "linux" && process.arch === "x64") return "linux-x64";
  if (process.platform === "win32" && process.arch === "x64") return "windows-x64";
  throw new Error(`正式対応外のホストです: ${process.platform}-${process.arch}`);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
