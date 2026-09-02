import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-archive-"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-native-cases.json"), "utf8"));
const builtinCase = cases.find((testCase) => testCase.id === "plugin-node-native-archive");
const hermeticCase = cases.find((testCase) => testCase.id === "plugin-node-native-archive-hermetic");
if (builtinCase === undefined || hermeticCase === undefined) throw new Error("Node archive fixtureが不足しています");

const crcTable = new Uint32Array(256);
for (let index = 0; index < crcTable.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 0 ? value >>> 1 : (value >>> 1) ^ 0xedb88320;
  crcTable[index] = value >>> 0;
}

try {
  buildLnako();
  await runBuiltinSmoke(builtinCase, temporary);
  await runHermeticDifferential(hermeticCase, temporary);
  console.log(`NodeネイティブZIP検証: 組み込み経路と公式helper差分・${hermeticCase.commands.length}命令・AOT O0〜O3成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runBuiltinSmoke(testCase, parent) {
  const sourcePath = resolve(parent, "archive.nako3");
  await writeFile(sourcePath, testCase.source, "utf8");
  const result = spawnSync(executable, ["run", sourcePath], { cwd: parent, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  const stdout = normalizeLineEndings(result.stdout);
  if (result.status !== 0 || stdout !== "7z\ntrue\ntrue\nABC\n2\nnative-tool\n") {
    throw new Error(`Node ZIP組み込みスモークテストに失敗しました: status=${result.status} stdout=${JSON.stringify(stdout)} stderr=${result.stderr}`);
  }
  if ((await readFile(resolve(parent, "second-output", "second.txt"), "utf8")) !== "XYZ") throw new Error("コールバック版ZIPの展開内容が不正です");
  if ((await stat(resolve(parent, "archive.zip"))).size <= 22) throw new Error("ZIPアーカイブが空です");
  for (const optimization of ["O0", "O1", "O2", "O3"]) await runBuiltinAotCase(testCase.source, parent, optimization);
}

async function runBuiltinAotCase(source, parent, optimization) {
  const directory = resolve(parent, `aot-${optimization}`);
  await mkdir(directory);
  const sourcePath = resolve(directory, "archive.nako3");
  const nativePath = resolve(directory, `archive-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
  await writeFile(sourcePath, source, "utf8");
  const compile = spawnSync(executable, ["build", sourcePath, "-o", nativePath, `-${optimization}`], {
    cwd: directory,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (compile.status !== 0) throw new Error(`Node ZIP AOT ${optimization}ビルドに失敗しました: ${compile.stderr}`);
  const result = spawnSync(nativePath, [], { cwd: directory, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  const stdout = result.stdout.replaceAll("\r\n", "\n");
  if (result.status !== 0 || stdout !== "7z\ntrue\ntrue\nABC\n2\nnative-tool\n") {
    throw new Error(`Node ZIP AOT ${optimization}実行に失敗しました: status=${result.status} stdout=${JSON.stringify(stdout)} stderr=${result.stderr}`);
  }
  if ((await readFile(resolve(directory, "second-output", "second.txt"), "utf8")) !== "XYZ") throw new Error(`Node ZIP AOT ${optimization}の展開内容が不正です`);
  if ((await stat(resolve(directory, "archive.zip"))).size <= 22) throw new Error(`Node ZIP AOT ${optimization}のZIPアーカイブが空です`);
}

async function runHermeticDifferential(testCase, parent) {
  const sourceName = "archive-hermetic.nako3";
  const officialSourceDirectory = resolve(parent, "hermetic-official-source");
  const officialGeneratedDirectory = resolve(parent, "hermetic-official-generated");
  const interpreterDirectory = resolve(parent, "hermetic-interpreter");
  const aotDirectories = Object.fromEntries(["O0", "O1", "O2", "O3"].map((optimization) => [optimization, resolve(parent, `hermetic-aot-${optimization}`)]));
  await Promise.all([
    officialSourceDirectory,
    officialGeneratedDirectory,
    interpreterDirectory,
    ...Object.values(aotDirectories),
  ].map((directory) => mkdir(directory, { recursive: true })));
  const sourceDirectories = [officialSourceDirectory, officialGeneratedDirectory, interpreterDirectory, ...Object.values(aotDirectories)];
  await Promise.all(sourceDirectories.map((directory) => writeFile(resolve(directory, sourceName), testCase.source, "utf8")));

  const oracleRoot = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
  const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
  const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
  const safeExternalHost = resolve(root, "tools/oracle/safe_external_host.mjs");
  const environment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    LNAKO_NODE_TEST: "fixed-value",
    LNAKO_TEST_NOW_MS: "1735689845678",
    LNAKO_TEST_MONOTONIC_MS: "123.5",
    LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
    NAKO3_DISABLE_NEW_CONSOLE: "1",
  };
  const lnakoEnvironment = { ...environment, LNAKO_TEST_ARCHIVE_HELPER: "lnako-archive-7z-helper" };
  const officialArguments = ["--import", pathToFileURL(fixedHost).href, "--import", pathToFileURL(safeExternalHost).href];
  const spawnOptions = { env: environment, encoding: "utf8", maxBuffer: 16 * 1024 * 1024, windowsHide: true };
  const officialSourcePath = resolve(officialSourceDirectory, sourceName);
  const officialGeneratedSourcePath = resolve(officialGeneratedDirectory, sourceName);
  const generatedPath = resolve(officialGeneratedDirectory, "archive-hermetic.mjs");
  const officialSource = spawnSync(process.execPath, [...officialArguments, officialCli, officialSourcePath], { ...spawnOptions, cwd: officialSourceDirectory });
  assertSuccess("Node archive公式source", officialSource);
  const officialCompile = spawnSync(process.execPath, [...officialArguments, officialCli, "--compile", "--silent", "--output", generatedPath, officialGeneratedSourcePath], {
    ...spawnOptions,
    cwd: officialGeneratedDirectory,
  });
  assertSuccess("Node archive公式JavaScript生成", officialCompile);
  const officialGenerated = spawnSync(process.execPath, [...officialArguments, generatedPath], { ...spawnOptions, cwd: officialGeneratedDirectory });
  assertSuccess("Node archive公式生成JavaScript", officialGenerated);

  const interpreterSource = resolve(interpreterDirectory, sourceName);
  const interpreter = spawnSync(executable, ["run", interpreterSource], { ...spawnOptions, env: lnakoEnvironment, cwd: interpreterDirectory });
  assertSuccess("Node archive lnako Interpreter", interpreter);
  assertProcessEqual("Node archive公式source/generated", officialSource, officialGenerated);
  assertProcessEqual("Node archive公式source/Interpreter", officialSource, interpreter);

  const ignoredByRoute = (directory, executableName, generatedName = null) => new Set([
    sourceName,
    executableName,
    ...(generatedName === null ? [] : [generatedName]),
  ]);
  const expectedFiles = await semanticSnapshot(officialSourceDirectory, ignoredByRoute(officialSourceDirectory, "never"));
  const generatedFiles = await semanticSnapshot(officialGeneratedDirectory, ignoredByRoute(officialGeneratedDirectory, "never", basename(generatedPath)));
  assertSemanticEqual("Node archive公式source/generated", expectedFiles, generatedFiles);
  const interpreterFiles = await semanticSnapshot(interpreterDirectory, ignoredByRoute(interpreterDirectory, "never"));
  assertSemanticEqual("Node archive公式source/Interpreter", expectedFiles, interpreterFiles);

  for (const optimization of ["O0", "O1", "O2", "O3"]) {
    const directory = aotDirectories[optimization];
    const sourcePath = resolve(directory, sourceName);
    const nativePath = resolve(parent, `hermetic-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
    const compile = spawnSync(executable, ["build", sourcePath, "-o", nativePath, `-${optimization}`], {
      ...spawnOptions,
      env: lnakoEnvironment,
      cwd: directory,
    });
    assertSuccess(`Node archive AOT ${optimization}コンパイル`, compile);
    const result = spawnSync(nativePath, [], { ...spawnOptions, env: lnakoEnvironment, cwd: directory });
    assertSuccess(`Node archive AOT ${optimization}`, result);
    assertProcessEqual(`Node archive公式source/AOT ${optimization}`, officialSource, result);
    const files = await semanticSnapshot(directory, ignoredByRoute(directory, basename(nativePath)));
    assertSemanticEqual(`Node archive公式source/AOT ${optimization}`, expectedFiles, files);
  }
}

function assertSuccess(label, result) {
  if (result.status !== 0) throw new Error(`${label}に失敗しました: status=${result.status} signal=${result.signal} stderr=${JSON.stringify(result.stderr)}`);
}

function assertProcessEqual(label, left, right) {
  const expected = normalize(left);
  const actual = normalize(right);
  if (JSON.stringify(expected) !== JSON.stringify(actual)) {
    throw new Error(`${label}の結果が一致しません: expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}`);
  }
}

function assertSemanticEqual(label, left, right) {
  if (JSON.stringify(left) !== JSON.stringify(right)) {
    throw new Error(`${label}のZIP意味結果が一致しません: expected=${JSON.stringify(left)} actual=${JSON.stringify(right)}`);
  }
}

function normalizeLineEndings(value) {
  return (value ?? "").replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

function normalize(result) {
  return { stdout: normalizeLineEndings(result.stdout), stderrClass: result.status === 0 ? "success" : "runtime-error", exitCode: result.status, signal: result.signal };
}

async function semanticSnapshot(directory, ignored) {
  const result = [];
  await visit(directory);
  return result.sort((left, right) => left.path.localeCompare(right.path));

  async function visit(current) {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const path = resolve(current, entry.name);
      const rel = relative(directory, path).replaceAll("\\", "/");
      // The official compiler materializes its runtime support tree beside
      // the generated module. These are compiler artifacts, not archive
      // outputs, so keep them out of the cross-route semantic snapshot.
      if (ignored.has(rel) || rel === "nako3runtime" || rel.startsWith("nako3runtime/") || rel === "node_modules" || rel.startsWith("node_modules/")) continue;
      if (entry.isDirectory()) {
        result.push({ path: `${rel}/`, kind: "directory" });
        await visit(path);
      } else {
        const bytes = await readFile(path);
        if (rel.endsWith(".zip")) result.push({ path: rel, kind: "zip", entries: readStoredZip(bytes) });
        else result.push({ path: rel, kind: "file", size: bytes.length, sha256: sha256(bytes) });
      }
    }
  }
}

function readStoredZip(bytes) {
  const entries = [];
  let offset = 0;
  while (offset + 4 <= bytes.length) {
    const signature = bytes.readUInt32LE(offset);
    if (signature === 0x02014b50 || signature === 0x06054b50) break;
    if (signature !== 0x04034b50 || offset + 30 > bytes.length) throw new Error("ZIP local headerが不正です");
    const flags = bytes.readUInt16LE(offset + 6);
    const method = bytes.readUInt16LE(offset + 8);
    const crc = bytes.readUInt32LE(offset + 14);
    const size = bytes.readUInt32LE(offset + 22);
    const nameLength = bytes.readUInt16LE(offset + 26);
    const extraLength = bytes.readUInt16LE(offset + 28);
    const dataStart = offset + 30 + nameLength + extraLength;
    const dataEnd = dataStart + size;
    if ((flags & 0x0008) !== 0 || method !== 0 || dataEnd > bytes.length) throw new Error("stored ZIP以外のアーカイブです");
    const name = bytes.subarray(offset + 30, offset + 30 + nameLength).toString("utf8").replaceAll("\\", "/");
    const data = bytes.subarray(dataStart, dataEnd);
    if (crc32(data) !== crc) throw new Error(`ZIP CRC不一致: ${name}`);
    entries.push({ name, directory: name.endsWith("/"), size: data.length, crc32: crc, sha256: sha256(data) });
    offset = dataEnd;
  }
  if (entries.length === 0) throw new Error("ZIP entryがありません");
  return entries.sort((left, right) => left.name.localeCompare(right.name));
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = (value >>> 8) ^ crcTable[(value ^ byte) & 0xff];
  return (value ^ 0xffffffff) >>> 0;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") } });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}
