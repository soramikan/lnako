import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFile, spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-native-"));
const maxBuffer = 16 * 1024 * 1024;

try {
  buildLnako();
  let failures = 0;
  let generatedOracleCases = 0;
  let sourceOracleCases = 0;
  for (const testCase of cases) {
    if (testCase.oracle !== undefined && testCase.oracle !== "official-source" && testCase.oracle !== "official-generated") {
      throw new Error(`未知のAOTオラクル指定です: ${testCase.id}: ${testCase.oracle}`);
    }
  }
  const completed = await runCases(cases, temporary, executable, officialCli, nativeOracleConcurrency());
  for (const { testCase, results, officialCompile, compileErrors } of completed) {
    if (testCase.oracle === "official-generated") generatedOracleCases += 1;
    if (testCase.oracle === "official-source") sourceOracleCases += 1;
    const oracleKey = testCase.oracle === "official-generated" ? "officialGenerated" : "officialSource";
    const expected = JSON.stringify(results[oracleKey]);
    const compared = Object.entries(results).filter(([key]) =>
      (testCase.oracle !== "official-generated" || key !== "officialSource") &&
      (testCase.oracle !== "official-source" || key !== "officialGenerated")
    );
    if (compared.some(([, result]) => JSON.stringify(result) !== expected)) {
      failures += 1;
      console.error(`AOT実行差分 ${testCase.id}:\n${JSON.stringify(results, null, 2)}`);
      if (officialCompile.status !== 0) console.error(`公式JavaScript生成エラー:\n${officialCompile.stderr}`);
      if (compileErrors.length > 0) console.error(`lnakoネイティブ生成エラー:\n${compileErrors.join("\n")}`);
    }
  }
  if (failures > 0) throw new Error(`AOT実行結果の差分が${failures}件あります`);
  console.log(
    `公式cnako3・公式生成JavaScript・lnako run・LLVM AOT O0/O1/O2/O3の7経路実行差分テスト: ${cases.length}件成功` +
      (generatedOracleCases + sourceOracleCases > 0
        ? `（既知の公式経路差: CLI基準${sourceOracleCases}件、生成JavaScript基準${generatedOracleCases}件）`
        : ""),
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runCases(cases, temporary, executable, officialCli, concurrency) {
  const completed = new Array(cases.length);
  const infrastructureErrors = new Array(cases.length);
  let nextIndex = 0;
  async function worker() {
    while (true) {
      const index = nextIndex++;
      if (index >= cases.length) return;
      try {
        completed[index] = await runCase(cases[index], index, temporary, executable, officialCli);
      } catch (error) {
        infrastructureErrors[index] = error;
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, cases.length) }, worker));
  const firstError = infrastructureErrors.find((error) => error !== undefined);
  if (firstError) throw firstError;
  return completed;
}

async function runCase(testCase, index, temporary, executable, officialCli) {
  // The ordinal makes temporary paths unique even if a future fixture list
  // accidentally contains duplicate IDs. Each worker owns one fixture, and
  // all commands within that fixture remain sequential. A private cwd also
  // prevents future fixtures that use relative files from racing each other.
  const stem = `${String(index).padStart(3, "0")}-${testCase.id}`;
  const fixtureDirectory = resolve(temporary, stem);
  await mkdir(fixtureDirectory);
  const sourcePath = resolve(fixtureDirectory, `${stem}.nako3`);
  const generatedJavaScript = resolve(fixtureDirectory, `${stem}.mjs`);
  await writeFile(sourcePath, testCase.source, "utf8");
  const options = {
    cwd: fixtureDirectory,
    env: { ...process.env, TZ: "Asia/Tokyo", LNAKO_LLVM_TRACE: "1" },
    maxBuffer,
  };
  const officialSource = await runProcess(process.execPath, [officialCli, sourcePath], options);
  const officialCompile = await runProcess(process.execPath, [officialCli, "--compile", "--silent", "--output", generatedJavaScript, sourcePath], options);
  const officialGenerated = officialCompile.status === 0 ? await runProcess(process.execPath, [generatedJavaScript], options) : officialCompile;
  const interpreted = await runProcess(executable, ["run", sourcePath], options);
  const results = {
    officialSource: normalize(officialSource),
    officialGenerated: normalize(officialGenerated),
    lnakoRun: normalize(interpreted),
  };
  const compileErrors = [];
  for (const optimization of ["O0", "O1", "O2", "O3"]) {
    const nativeExecutable = resolve(fixtureDirectory, `${stem}-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
    const nativeCompile = await runProcess(executable, ["build", sourcePath, "-o", nativeExecutable, `-${optimization}`], options);
    results[`lnakoNative${optimization}`] = normalize(nativeCompile.status === 0 ? await runProcess(nativeExecutable, [], options) : nativeCompile);
    if (nativeCompile.status !== 0) compileErrors.push(`${optimization}:\n${nativeCompile.stderr}`);
  }
  return { testCase, results, officialCompile, compileErrors };
}

function runProcess(command, arguments_, options) {
  return new Promise((resolveProcess) => {
    execFile(command, arguments_, options, (error, stdout, stderr) => {
      resolveProcess({
        status: error === null ? 0 : typeof error.code === "number" ? error.code : null,
        signal: error?.signal ?? null,
        stdout: stdout ?? "",
        stderr: stderr || (error?.message ?? ""),
      });
    });
  });
}

function nativeOracleConcurrency() {
  const configured = process.env.LNAKO_NATIVE_ORACLE_JOBS;
  if (configured === undefined || configured === "2") return 2;
  if (configured === "1") return 1;
  throw new Error("LNAKO_NATIVE_ORACLE_JOBSは1または2を指定してください");
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
