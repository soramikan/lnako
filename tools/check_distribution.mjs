import { gunzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

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
  if (manifest.executable !== binary.path || manifest.runtimeLibrary !== runtime.path) throw new Error("配布manifestのartifact pathが一致しません");
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) throw new Error("配布manifestのfilesが空です");
  const seen = new Set();
  for (const file of manifest.files) {
    if (!file || typeof file.path !== "string" || !/^[0-9a-f]{64}$/.test(file.sha256) || !Number.isSafeInteger(file.size) || seen.has(file.path)) throw new Error("配布manifestのfile recordが不正です");
    seen.add(file.path);
    const bytes = requireEntry(entries, `${prefix}${file.path}`);
    if (sha256(bytes) !== file.sha256 || bytes.length !== file.size) throw new Error(`配布manifestのfile digestが不一致です: ${file.path}`);
  }
  if (manifest.toolchain.included) {
    if (manifest.toolchain.files.length === 0) throw new Error("LLVM/LLD同梱manifestにtoolchain filesがありません");
    for (const file of manifest.toolchain.files) requireEntry(entries, `${prefix}${file}`);
  } else if (manifest.toolchain.files.length !== 0) throw new Error("LLVM/LLD非同梱manifestにtoolchain filesがあります");
}

function validateManifestArtifact(artifact, prefix, entries, label) {
  if (!artifact || typeof artifact.path !== "string" || !/^[0-9a-f]{64}$/.test(artifact.sha256)) throw new Error(`配布manifestの${label} artifactが不正です`);
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
    if (!file || typeof file.fileName !== "string" || seen.has(file.fileName) || !Array.isArray(file.checksums)) throw new Error("SBOMのfile recordが不正です");
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

function parseTarGz(bytes) {
  const tar = gunzipSync(bytes);
  const entries = new Map();
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = readField(header, 0, 100);
    const size = parseOctal(readField(header, 124, 12));
    const dataStart = offset + 512;
    const dataEnd = dataStart + size;
    if (!name || dataEnd > tar.length || entries.has(name)) throw new Error(`tar entryが不正です: ${name}`);
    entries.set(name, Buffer.from(tar.subarray(dataStart, dataEnd)));
    offset = dataStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function parseZip(bytes) {
  const entries = new Map();
  for (let offset = 0; offset + 4 <= bytes.length;) {
    const signature = bytes.readUInt32LE(offset);
    if (signature === 0x04034b50) {
      const flags = bytes.readUInt16LE(offset + 6);
      const method = bytes.readUInt16LE(offset + 8);
      const compressedSize = bytes.readUInt32LE(offset + 18);
      const nameLength = bytes.readUInt16LE(offset + 26);
      const extraLength = bytes.readUInt16LE(offset + 28);
      if ((flags & 0x08) !== 0 || method !== 0) throw new Error("未対応のzip entry形式です");
      const nameStart = offset + 30;
      const name = bytes.subarray(nameStart, nameStart + nameLength).toString("utf8");
      const dataStart = nameStart + nameLength + extraLength;
      const dataEnd = dataStart + compressedSize;
      if (!name || dataEnd > bytes.length || entries.has(name)) throw new Error(`zip entryが不正です: ${name}`);
      entries.set(name, Buffer.from(bytes.subarray(dataStart, dataEnd)));
      offset = dataEnd;
      continue;
    }
    if (signature === 0x02014b50 || signature === 0x06054b50) break;
    throw new Error(`zip signatureが不正です: 0x${signature.toString(16)}`);
  }
  return entries;
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
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`tar sizeが不正です: ${value}`);
  return parsed;
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
    for (const target of targets) {
      const result = spawnSync(process.execPath, [resolve(root, "tools/create_distribution.mjs"), "--version", "9.9.9-test", "--target", target, "--output", output, "--binary", binary, "--runtime", runtime], {
        cwd: root,
        encoding: "utf8",
        maxBuffer: 4 * 1024 * 1024,
      });
      if (result.status !== 0) throw new Error(`配布self-test生成に失敗しました(${target}): ${result.stderr}`);
      const extension = target === "windows-x64" ? "zip" : "tar.gz";
      await verifyDistribution(resolve(output, `lnako-9.9.9-test-${target}.${extension}`));
    }
    console.log("配布物self-test: tar.gz・zip・SHA-256・SPDX SBOM・manifest検証成功");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
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
