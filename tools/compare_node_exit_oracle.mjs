import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-exit-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-exit-"));

try {
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const source = resolve(temporary, `${testCase.id}.nako3`);
    await writeFile(source, testCase.source, "utf8");
    const environment = { ...process.env, TZ: "Asia/Tokyo", LNAKO_TEST_NOW_MS: "1735689845678", LNAKO_TEST_RANDOM_SEED: "5573589319906701683" };
    const official = spawnSync(process.execPath, ["--import", pathToFileURL(fixedHost).href, officialCli, source], { cwd: temporary, env: environment, encoding: "utf8" });
    const actual = spawnSync(executable, ["run", source], { cwd: temporary, env: environment, encoding: "utf8" });
    const expectedResult = normalize(official);
    const actualResult = normalize(actual);
    if (official.status !== testCase.exitCode || actual.status !== testCase.exitCode || JSON.stringify(expectedResult) !== JSON.stringify(actualResult)) {
      failures += 1;
      console.error(`Node終了差分 ${testCase.id}: official=${JSON.stringify(expectedResult)} lnako=${JSON.stringify(actualResult)}`);
    }
  }
  if (failures > 0) throw new Error(`Node終了命令の差分が${failures}件あります`);
  console.log(`Node終了命令公式差分テスト: ${cases.length}ケース・${new Set(cases.flatMap((testCase) => testCase.commands)).size}命令成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") } });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return { stdout: result.stdout.replaceAll("\r\n", "\n"), stderr: result.stderr.replaceAll("\r\n", "\n"), exitCode: result.status, signal: result.signal };
}
