import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-native-"));

try {
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const sourcePath = resolve(temporary, `${testCase.id}.nako3`);
    const generatedJavaScript = resolve(temporary, `${testCase.id}.mjs`);
    const nativeExecutable = resolve(temporary, `${testCase.id}${process.platform === "win32" ? ".exe" : ""}`);
    await writeFile(sourcePath, testCase.source, "utf8");
    const options = {
      cwd: temporary,
      encoding: "utf8",
      env: { ...process.env, TZ: "Asia/Tokyo", LNAKO_LLVM_TRACE: "1" },
      maxBuffer: 16 * 1024 * 1024,
    };
    const officialSource = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const officialCompile = spawnSync(process.execPath, [officialCli, "--compile", "--silent", "--output", generatedJavaScript, sourcePath], options);
    const officialGenerated = officialCompile.status === 0 ? spawnSync(process.execPath, [generatedJavaScript], options) : officialCompile;
    const interpreted = spawnSync(executable, ["run", sourcePath], options);
    const nativeCompile = spawnSync(executable, ["build", sourcePath, "-o", nativeExecutable, "-O2"], options);
    const native = nativeCompile.status === 0 ? spawnSync(nativeExecutable, [], options) : nativeCompile;
    const results = {
      officialSource: normalize(officialSource),
      officialGenerated: normalize(officialGenerated),
      lnakoRun: normalize(interpreted),
      lnakoNative: normalize(native),
    };
    const expected = JSON.stringify(results.officialSource);
    if (Object.values(results).some((result) => result.exitCode !== 0 || JSON.stringify(result) !== expected)) {
      failures += 1;
      console.error(`AOT実行差分 ${testCase.id}:\n${JSON.stringify(results, null, 2)}`);
      if (officialCompile.status !== 0) console.error(`公式JavaScript生成エラー:\n${officialCompile.stderr}`);
      if (nativeCompile.status !== 0) console.error(`lnakoネイティブ生成エラー:\n${nativeCompile.stderr}`);
    }
  }
  if (failures > 0) throw new Error(`AOT実行結果の差分が${failures}件あります`);
  console.log(`公式cnako3・公式生成JavaScript・lnako run・LLVM AOTの4経路差分テスト: ${cases.length}件成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return {
    stdout: result.stdout.replaceAll("\r\n", "\n"),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}
