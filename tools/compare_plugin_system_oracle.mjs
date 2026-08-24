import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-plugin-system-"));

try {
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const sourcePath = resolve(temporary, `${testCase.id}.nako3`);
    await writeFile(sourcePath, testCase.source, "utf8");
    const options = {
      cwd: temporary,
      encoding: "utf8",
      env: {
        ...process.env,
        TZ: "Asia/Tokyo",
        LNAKO_TEST_NOW_MS: "1735689845678",
        LNAKO_TEST_MONOTONIC_MS: "123.5",
        LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
      },
      maxBuffer: 16 * 1024 * 1024,
    };
    const official = spawnSync(process.execPath, ["--import", pathToFileURL(fixedHost).href, officialCli, sourcePath], options);
    const actual = spawnSync(executable, ["run", sourcePath], options);
    const expectedResult = normalize(official);
    const actualResult = normalize(actual);
    if (official.status !== 0 || actual.status !== 0 || JSON.stringify(expectedResult) !== JSON.stringify(actualResult)) {
      failures += 1;
      console.error(`plugin_system差分 ${testCase.id}:\nofficial=${JSON.stringify(expectedResult)}\nlnako  =${JSON.stringify(actualResult)}`);
      if (official.stderr) console.error(`公式stderr:\n${official.stderr}`);
      if (actual.stderr) console.error(`lnako stderr:\n${actual.stderr}`);
    }
  }
  if (failures > 0) throw new Error(`plugin_system実行結果の差分が${failures}件あります`);
  const commandCount = new Set(cases.flatMap((testCase) => testCase.commands)).size;
  console.log(`plugin_system公式差分テスト: ${cases.length}ケース・${commandCount}命令成功`);
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
