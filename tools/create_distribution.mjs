import { chmod, copyFile, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 0 ? value >>> 1 : (value >>> 1) ^ 0xedb88320;
  return value >>> 0;
});

const root = resolve(import.meta.dirname, "..");
const toolchainLockPath = resolve(root, "toolchain.lock.json");
const toolchainLockBytes = await readFile(toolchainLockPath);
const toolchainLock = JSON.parse(toolchainLockBytes.toString("utf8"));
const options = parseArguments(process.argv.slice(2));

if (options.help) {
  console.log(usage());
} else {
  await createDistribution(options);
}

function parseArguments(arguments_) {
  const parsed = {
    help: false,
    version: null,
    output: resolve(root, "dist"),
    binary: null,
    runtime: null,
    llvm: null,
    target: hostTarget(),
    requireLlvm: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--help" || argument === "-h") {
      parsed.help = true;
    } else if (argument === "--version") {
      parsed.version = nextValue(arguments_, ++index, argument);
    } else if (argument === "--output") {
      parsed.output = resolveAbsolute(nextValue(arguments_, ++index, argument), argument);
    } else if (argument === "--binary") {
      parsed.binary = resolveAbsolute(nextValue(arguments_, ++index, argument), argument);
    } else if (argument === "--runtime") {
      parsed.runtime = resolveAbsolute(nextValue(arguments_, ++index, argument), argument);
    } else if (argument === "--llvm-dir") {
      parsed.llvm = resolveAbsolute(nextValue(arguments_, ++index, argument), argument);
    } else if (argument === "--target") {
      parsed.target = nextValue(arguments_, ++index, argument);
      if (!targetSpec(parsed.target)) throw new Error(`正式対象外の配布targetです: ${parsed.target}`);
    } else if (argument === "--require-llvm") {
      parsed.requireLlvm = true;
    } else {
      throw new Error(`未知の引数です: ${argument}\n\n${usage()}`);
    }
  }
  if (parsed.version === null) parsed.version = readProjectVersion();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(parsed.version)) {
    throw new Error(`配布バージョンがsemver形式ではありません: ${parsed.version}`);
  }
  return parsed;
}

async function createDistribution(options_) {
  const spec = targetSpec(options_.target);
  const binary = options_.binary ?? defaultBinary(spec);
  const runtime = options_.runtime ?? defaultRuntime(spec);
  await requireFile(binary, "lnako実行ファイル");
  await requireFile(runtime, "AOTランタイム静的ライブラリ");
  if (options_.requireLlvm && options_.llvm === null) throw new Error("release配布には--llvm-dirが必要です");
  if (options_.llvm !== null) await requireDirectory(options_.llvm, "LLVM/LLD配布ルート");

  const baseName = `lnako-${options_.version}-${spec.archiveTarget}`;
  const stagingParent = resolve(options_.output, `.staging-${baseName}-${process.pid}`);
  const stagingRoot = resolve(stagingParent, baseName);
  await rm(stagingParent, { recursive: true, force: true });
  await mkdir(stagingRoot, { recursive: true });

  try {
    await copyPayload(stagingRoot, binary, runtime, options_.llvm, spec);
    const payloadFiles = await collectFiles(stagingRoot);
    const manifest = createManifest(options_, spec, binary, runtime, payloadFiles, await gitState());
    await writeJson(resolve(stagingRoot, "manifest.json"), manifest);
    const manifestFiles = await collectFiles(stagingRoot);
    const sbom = createSbom(options_, spec, manifestFiles, manifest);
    await writeJson(resolve(stagingRoot, "sbom.spdx.json"), sbom);

    const archivePath = resolve(options_.output, `${baseName}.${spec.archiveExtension}`);
    await mkdir(options_.output, { recursive: true });
    const archive = await createArchive(stagingRoot, baseName, spec.archiveFormat);
    await writeFile(archivePath, archive);
    const archiveDigest = sha256(archive);
    const sbomBytes = await readFile(resolve(stagingRoot, "sbom.spdx.json"));
    const sbomPath = resolve(options_.output, `${baseName}.spdx.json`);
    await writeFile(sbomPath, sbomBytes);
    await writeFile(`${archivePath}.sha256`, `${archiveDigest}  ${baseName}.${spec.archiveExtension}\n`);
    await writeFile(
      resolve(options_.output, "SHA256SUMS"),
      `${archiveDigest}  ${baseName}.${spec.archiveExtension}\n${sha256(sbomBytes)}  ${baseName}.spdx.json\n`,
    );
    console.log(`配布物を生成しました: ${archivePath}`);
    console.log(`SBOMを生成しました: ${sbomPath}`);
    console.log(`SHA-256: ${archiveDigest}`);
  } finally {
    await rm(stagingParent, { recursive: true, force: true });
  }
}

async function copyPayload(stagingRoot, binary, runtime, llvm, spec) {
  await copyPayloadFile(binary, resolve(stagingRoot, "bin", spec.executable), true);
  await copyPayloadFile(runtime, resolve(stagingRoot, "lib", spec.runtimeLibrary), false);
  await copyPayloadFile(resolve(root, "README.md"), resolve(stagingRoot, "README.md"), false);
  await copyPayloadFile(resolve(root, "LICENSE"), resolve(stagingRoot, "LICENSE"), false);
  await copyPayloadFile(resolve(root, "THIRD_PARTY_NOTICES.md"), resolve(stagingRoot, "THIRD_PARTY_NOTICES.md"), false);
  await copyPayloadFile(resolve(root, "include/lnako_plugin_v1.h"), resolve(stagingRoot, "include/lnako_plugin_v1.h"), false);
  await copyPayloadFile(resolve(root, "compat/v3.7.24/UPSTREAM_LICENSE"), resolve(stagingRoot, "compat/v3.7.24/UPSTREAM_LICENSE"), false);
  for (const document of ["ARCHITECTURE.md", "DEVELOPMENT.md", "NATIVE_PLUGIN_ABI.md", "COMPATIBILITY_EVIDENCE.md", "COMPATIBILITY_QUIRKS.md"]) {
    await copyPayloadFile(resolve(root, "docs", document), resolve(stagingRoot, "docs", document), false);
  }
  if (llvm !== null) await copyPinnedLlvm(stagingRoot, llvm, spec);
}

async function copyPinnedLlvm(stagingRoot, llvmRoot, spec) {
  for (const entry of spec.llvmFiles) {
    const source = resolve(llvmRoot, entry.source);
    const destination = resolve(stagingRoot, "llvm", entry.destination);
    await copyPayloadFile(source, destination, entry.executable);
  }
}

async function copyPayloadFile(source, destination, executable) {
  await requireFile(source, `配布入力 ${relative(root, source) || source}`);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination);
  if (executable && process.platform !== "win32") await chmod(destination, 0o755);
}

function createManifest(options_, spec, binary, runtime, payloadFiles, git) {
  return {
    schema: "lnako.distribution-manifest.v1",
    name: "lnako",
    version: options_.version,
    target: spec.archiveTarget,
    platform: spec.platform,
    arch: spec.arch,
    executable: `bin/${spec.executable}`,
    runtimeLibrary: `lib/${spec.runtimeLibrary}`,
    source: {
      repository: "https://github.com/soramikan/lnako",
      commit: git.commit,
      dirty: git.dirty,
    },
    build: {
      zig: "0.16.0",
      llvm: "22.1.8",
      quickjs: "2026-06-04",
      compatJsIncluded: false,
    },
    toolchain: {
      included: options_.llvm !== null,
      lockSha256: sha256(toolchainLockBytes),
      llvmArchiveSha256: toolchainLock.llvm.artifacts[spec.toolchainKey]?.sha256 ?? null,
      files: options_.llvm === null ? [] : spec.llvmFiles.map((entry) => `llvm/${entry.destination}`),
    },
    artifacts: {
      binary: { path: `bin/${spec.executable}`, sha256: sha256FileSync(binary) },
      runtime: { path: `lib/${spec.runtimeLibrary}`, sha256: sha256FileSync(runtime) },
    },
    sbom: "sbom.spdx.json",
    files: payloadFiles.map((file) => ({ path: file.path, sha256: file.sha256, size: file.size })),
  };
}

function createSbom(options_, spec, files, manifest) {
  const packages = [
    sbomPackage("SPDXRef-Package-lnako", "lnako", options_.version, "MIT", "pkg:github/soramikan/lnako@" + options_.version),
  ];
  if (options_.llvm !== null) {
    packages.push(sbomPackage("SPDXRef-Package-LLVM", "LLVM/LLD", "22.1.8", "Apache-2.0 WITH LLVM-exception", "pkg:generic/llvm@22.1.8"));
  }
  const fileRecords = files.map((file, index) => ({
    SPDXID: `SPDXRef-File-${index + 1}`,
    fileName: file.path,
    checksums: [{ algorithm: "SHA256", checksumValue: file.sha256 }],
    licenseConcluded: "NOASSERTION",
    copyrightText: "NOASSERTION",
  }));
  const relationships = [
    { spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: "SPDXRef-Package-lnako" },
    ...fileRecords.map((file) => ({ spdxElementId: "SPDXRef-Package-lnako", relationshipType: "CONTAINS", relatedSpdxElement: file.SPDXID })),
  ];
  if (options_.llvm !== null) relationships.push({ spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: "SPDXRef-Package-LLVM" });
  return {
    spdxVersion: "SPDX-2.3",
    dataLicense: "CC0-1.0",
    SPDXID: "SPDXRef-DOCUMENT",
    name: `lnako-${options_.version}-${spec.archiveTarget}`,
    documentNamespace: `https://github.com/soramikan/lnako/spdx/${options_.version}/${spec.archiveTarget}`,
    creationInfo: {
      created: "1970-01-01T00:00:00Z",
      creators: ["Tool: lnako distribution builder"],
    },
    documentComment: "This SBOM describes the files in the lnako distribution archive. Nadesiko 3, Node.js, and QuickJS are test or optional compatibility inputs and are not shipped in the normal archive.",
    packages,
    files: fileRecords,
    relationships,
    annotations: [{ annotationType: "OTHER", annotator: "Tool: lnako distribution builder", annotationDate: "1970-01-01T00:00:00Z", comment: `manifestSha256=${sha256(JSON.stringify(manifest))}` }],
  };
}

function sbomPackage(SPDXID, name, version, license, purl) {
  return {
    SPDXID,
    name,
    versionInfo: version,
    downloadLocation: "NOASSERTION",
    filesAnalyzed: false,
    licenseConcluded: license,
    licenseDeclared: license,
    copyrightText: "NOASSERTION",
    externalRefs: [{ referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: purl }],
  };
}

async function createArchive(stagingRoot, baseName, format) {
  const files = await collectFiles(stagingRoot);
  if (format === "tar.gz") {
    const entries = await Promise.all(files.map(async (file) => ({
      name: `${baseName}/${file.path}`,
      data: await readFile(resolve(stagingRoot, file.path)),
      executable: file.path.startsWith("bin/") || file.path.startsWith("llvm/bin/"),
    })));
    return createTarGz(entries);
  }
  const entries = await Promise.all(files.map(async (file) => ({
    name: `${baseName}/${file.path}`,
    data: await readFile(resolve(stagingRoot, file.path)),
    executable: file.path.startsWith("bin/") || file.path.startsWith("llvm/bin/"),
  })));
  return createZip(entries);
}

function createTarGz(entries) {
  const chunks = [];
  for (const entry of entries.sort((left, right) => comparePaths(left.name, right.name))) {
    const header = Buffer.alloc(512, 0);
    writeField(header, 0, 100, entry.name);
    writeOctal(header, 100, 8, entry.executable ? 0o755 : 0o644);
    writeOctal(header, 108, 8, 0);
    writeOctal(header, 116, 8, 0);
    writeOctal(header, 124, 12, entry.data.length);
    writeOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = 0x30;
    writeField(header, 257, 6, "ustar\0");
    writeField(header, 263, 2, "00");
    writeField(header, 265, 32, "root");
    writeField(header, 297, 32, "root");
    const checksum = [...header].reduce((sum, byte) => sum + byte, 0);
    writeOctal(header, 148, 8, checksum);
    chunks.push(header, entry.data);
    const padding = (512 - (entry.data.length % 512)) % 512;
    if (padding > 0) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  const gzip = gzipSync(Buffer.concat(chunks), { level: 9, mtime: 0 });
  gzip.fill(0, 4, 8);
  return gzip;
}

function createZip(entries) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const entry of entries.sort((left, right) => comparePaths(left.name, right.name))) {
    const name = Buffer.from(entry.name, "utf8");
    const crc = crc32(entry.data);
    const localHeader = Buffer.alloc(30 + name.length);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0x800, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(33, 12);
    localHeader.writeUInt32LE(crc, 14);
    localHeader.writeUInt32LE(entry.data.length, 18);
    localHeader.writeUInt32LE(entry.data.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    name.copy(localHeader, 30);
    local.push(localHeader, entry.data);

    const centralHeader = Buffer.alloc(46 + name.length);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0x800, 8);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(33, 14);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(entry.data.length, 20);
    centralHeader.writeUInt32LE(entry.data.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt32LE((entry.executable ? 0o100755 : 0o100644) * 0x10000, 38);
    centralHeader.writeUInt32LE(offset, 42);
    name.copy(centralHeader, 46);
    central.push(centralHeader);
    offset += localHeader.length + entry.data.length;
  }
  const localBytes = Buffer.concat(local);
  const centralBytes = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(localBytes.length, 16);
  return Buffer.concat([localBytes, centralBytes, end]);
}

function writeField(buffer, offset, length, value) {
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length > length) throw new Error(`アーカイブ名が長すぎます: ${value}`);
  bytes.copy(buffer, offset);
}

function writeOctal(buffer, offset, length, value) {
  const text = Math.trunc(value).toString(8);
  if (text.length > length - 1) throw new Error(`tar数値フィールドが長すぎます: ${value}`);
  buffer.fill(0x30, offset, offset + length - 1);
  buffer.write(text, offset + length - 1 - text.length, "ascii");
  buffer[offset + length - 1] = 0;
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

async function collectFiles(directory) {
  const result = [];
  await walk(directory, directory, result);
  result.sort((left, right) => comparePaths(left.path, right.path));
  return result;
}

async function walk(rootDirectory, directory, result) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      await walk(rootDirectory, path, result);
    } else {
      const bytes = await readFile(path);
      result.push({ path: relative(rootDirectory, path).replaceAll("\\", "/"), size: bytes.length, sha256: sha256(bytes) });
    }
  }
}

async function requireFile(path, label) {
  const information = await stat(path).catch(() => null);
  if (information === null || !information.isFile()) throw new Error(`${label}が見つかりません: ${path}`);
}

async function requireDirectory(path, label) {
  const information = await stat(path).catch(() => null);
  if (information === null || !information.isDirectory()) throw new Error(`${label}が見つかりません: ${path}`);
}

function defaultBinary(spec) {
  if (spec.archiveTarget !== hostTarget()) throw new Error(`別targetには--binaryを指定してください: ${spec.archiveTarget}`);
  return resolve(root, "zig-out/bin", spec.executable);
}

function defaultRuntime(spec) {
  if (spec.archiveTarget !== hostTarget()) throw new Error(`別targetには--runtimeを指定してください: ${spec.archiveTarget}`);
  return resolve(root, "zig-out/lib", spec.runtimeLibrary);
}

function targetSpec(target) {
  return {
    "macos-arm64": {
      archiveTarget: "macos-arm64", platform: "darwin", arch: "arm64", toolchainKey: "macos-aarch64",
      executable: "lnako", runtimeLibrary: "liblnako_runtime.a", archiveExtension: "tar.gz", archiveFormat: "tar.gz",
      llvmFiles: [
        { source: "bin/clang", destination: "bin/clang", executable: true },
        { source: "bin/ld64.lld", destination: "bin/ld64.lld", executable: true },
        { source: "lib/libLLVM-C.dylib", destination: "lib/libLLVM-C.dylib", executable: false },
      ],
    },
    "linux-x64": {
      archiveTarget: "linux-x64", platform: "linux", arch: "x64", toolchainKey: "linux-x86_64",
      executable: "lnako", runtimeLibrary: "liblnako_runtime.a", archiveExtension: "tar.gz", archiveFormat: "tar.gz",
      llvmFiles: [
        { source: "bin/clang", destination: "bin/clang", executable: true },
        { source: "bin/ld.lld", destination: "bin/ld.lld", executable: true },
        { source: "lib/libLLVM-C.so", destination: "lib/libLLVM-C.so", executable: false },
      ],
    },
    "windows-x64": {
      archiveTarget: "windows-x64", platform: "win32", arch: "x64", toolchainKey: "windows-x86_64",
      executable: "lnako.exe", runtimeLibrary: "lnako_runtime.lib", archiveExtension: "zip", archiveFormat: "zip",
      llvmFiles: [
        { source: "bin/clang.exe", destination: "bin/clang.exe", executable: true },
        { source: "bin/lld-link.exe", destination: "bin/lld-link.exe", executable: true },
        { source: "bin/LLVM-C.dll", destination: "bin/LLVM-C.dll", executable: false },
      ],
    },
  }[target] ?? null;
}

function hostTarget() {
  if (process.platform === "darwin" && process.arch === "arm64") return "macos-arm64";
  if (process.platform === "linux" && process.arch === "x64") return "linux-x64";
  if (process.platform === "win32" && process.arch === "x64") return "windows-x64";
  throw new Error(`正式対応外のホストです: ${process.platform}-${process.arch}`);
}

function readProjectVersion() {
  const zon = readFileSync(resolve(root, "build.zig.zon"));
  const match = /\.version\s*=\s*"([^"]+)"/.exec(zon);
  if (match === null) throw new Error("build.zig.zonからversionを取得できません");
  return match[1];
}

function gitState() {
  const commit = capture("git", ["rev-parse", "HEAD"]).trim();
  const dirty = spawnSync("git", ["diff", "--quiet"], { cwd: root }).status !== 0;
  return { commit, dirty };
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha256FileSync(path) {
  return sha256(requireFileSync(path));
}

function requireFileSync(path) {
  try {
    return readFileSync(path);
  } catch {
    throw new Error(`配布入力を読み込めません: ${path}`);
  }
}

function capture(command, arguments_) {
  const result = spawnSync(command, arguments_, { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error(`${command} ${arguments_.join(" ")} が失敗しました`);
  return result.stdout;
}

function resolveAbsolute(value, argument) {
  if (!isAbsolute(value)) throw new Error(`${argument}には絶対パスを指定してください: ${value}`);
  return resolve(value);
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

function writeJson(path, value) {
  return writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function usage() {
  return `使い方: node tools/create_distribution.mjs [options]

  --version <version>       配布バージョン（既定: build.zig.zon）
  --target <target>         macos-arm64 / linux-x64 / windows-x64
  --output <absolute-path>  出力ディレクトリ（既定: dist）
  --binary <absolute-path>  lnako実行ファイル
  --runtime <absolute-path> AOTランタイム静的ライブラリ
  --llvm-dir <absolute-path> 同梱するLLVM/LLD配布ルート
  --require-llvm             LLVM/LLD同梱を必須にする
`;
}
