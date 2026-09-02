import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/interpreter-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-interpreter-"));

try {
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const sourcePath = resolve(temporary, `${testCase.id}.nako3`);
    await writeFile(sourcePath, testCase.source, "utf8");
    const options = {
      cwd: temporary,
      encoding: "utf8",
      env: { ...process.env, TZ: "Asia/Tokyo" },
      maxBuffer: 16 * 1024 * 1024,
    };
    const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const actual = spawnSync(executable, ["run", sourcePath], options);
    const expectedResult = normalize(official);
    const actualResult = normalize(actual);
    if (official.status !== 0 || actual.status !== 0 || JSON.stringify(expectedResult) !== JSON.stringify(actualResult)) {
      failures += 1;
      console.error(
        `実行差分 ${testCase.id}:\nofficial=${JSON.stringify(expectedResult)}\nlnako  =${JSON.stringify(actualResult)}`,
      );
    }
  }
  if (failures > 0) throw new Error(`実行結果の差分が${failures}件あります`);
  console.log(`公式cnako3 v3.7.24との実行差分テスト: ${cases.length}件成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const options = {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  };
  const result = spawnSync("zig", ["build"], options);
  if (result.status !== 0 || result.error) throw new Error(`lnakoのビルドに失敗しました:\n${describeProcessResult(result)}`);

  const sanity = spawnSync(executable, ["--version"], options);
  if (sanity.status === 0) return;
  if (sanity.error?.code !== "ENOEXEC") {
    throw new Error(`lnakoの生成compilerを実行できません:\n${describeProcessResult(sanity)}`);
  }

  // A cancelled or interrupted runner can leave a cache entry that lets Zig
  // report a successful build while installing an unusable executable. Retry
  // once from generated output and the shared build cache after detecting the
  // precise invalid-format error; normal builds keep their cache fast path.
  rmSync(resolve(root, "zig-out"), { recursive: true, force: true });
  rmSync(resolve(root, ".zig-cache"), { recursive: true, force: true });
  const retry = spawnSync("zig", ["build"], options);
  if (retry.status !== 0 || retry.error) throw new Error(`lnakoのcache再構築に失敗しました:\n${describeProcessResult(retry)}`);
  const retrySanity = spawnSync(executable, ["--version"], options);
  if (retrySanity.status !== 0 || retrySanity.error) {
    throw new Error(`lnakoのcache再構築後も生成compilerを実行できません:\n${describeProcessResult(retrySanity)}`);
  }
}

function normalize(result) {
  return {
    stdout: normalizeOutput(result.stdout),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status ?? null,
    signal: result.signal ?? null,
    spawnError: result.error ? describeSpawnError(result.error) : null,
  };
}

function normalizeOutput(output) {
  return String(output ?? "").replaceAll("\r\n", "\n");
}

function describeProcessResult(result) {
  const details = [];
  if (result.error) details.push(describeSpawnError(result.error));
  if (result.signal) details.push(`signal=${result.signal}`);
  if (result.status !== null && result.status !== undefined) details.push(`exitCode=${result.status}`);
  const stderr = normalizeOutput(result.stderr);
  if (stderr.length > 0) details.push(`stderr=${stderr}`);
  return details.length > 0 ? details.join(", ") : "プロセスが終了状態を返しませんでした";
}

function describeSpawnError(error) {
  const code = error.code ?? error.name ?? "spawn-error";
  return `${code}: ${error.message}`;
}
