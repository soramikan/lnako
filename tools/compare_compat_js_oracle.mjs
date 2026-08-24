import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/compat-js-cases.json"), "utf8"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const options = { cwd: root, encoding: "utf8", env: { ...process.env, TZ: "Asia/Tokyo" }, maxBuffer: 32 * 1024 * 1024 };
const temporary = await mkdtemp(join(tmpdir(), "lnako-compat-js-"));

try {
  buildCompatLnako();
  let failures = 0;
  for (const testCase of cases) {
    const sourcePath = resolve(root, "tests/fixtures", testCase.fixture);
    const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const actual = spawnSync(executable, ["run", sourcePath, "--compat-js"], options);
    const expected = testCase.expectedFailure ? normalizeFailure(official) : normalize(official);
    const received = testCase.expectedFailure ? normalizeFailure(actual) : normalize(actual);
    const mismatched = testCase.expectedFailure
      ? !expected.failed || !received.failed
      : official.status !== 0 || actual.status !== 0 || JSON.stringify(expected) !== JSON.stringify(received);
    if (mismatched) {
      failures += 1;
      console.error(`QuickJS互換差分 ${testCase.id}:\nofficial=${JSON.stringify(expected, null, 2)}\nlnako=${JSON.stringify(received, null, 2)}`);
      if (official.stderr) console.error(`公式stderr:\n${official.stderr}`);
      if (actual.stderr) console.error(`lnako stderr:\n${actual.stderr}`);
    }
  }

  const importFixture = resolve(root, "tests/fixtures/compat-js-plugin-imports.nako3");
  const withoutFlag = spawnSync(executable, ["run", importFixture], options);
  if (withoutFlag.status === 0 || !withoutFlag.stderr.includes("JavaScriptの取り込みには--compat-jsが必要です")) {
    failures += 1;
    console.error(`--compat-js省略時にJS取り込みを拒否しませんでした: ${JSON.stringify(normalize(withoutFlag))}`);
  }

  const hatenaFixture = resolve(root, "tests/fixtures/compat-js-hatena.nako3");
  const hatenaWithoutFlag = spawnSync(executable, ["run", hatenaFixture], options);
  if (hatenaWithoutFlag.status === 0 || !hatenaWithoutFlag.stderr.includes("QuickJsCompatibilityRequired")) {
    failures += 1;
    console.error(`ハテナ関数のJS:指定を通常モードで拒否しませんでした: ${JSON.stringify(normalize(hatenaWithoutFlag))}`);
  }

  const generated = resolve(temporary, process.platform === "win32" ? "compat-program.exe" : "compat-program");
  const build = spawnSync(executable, ["build", importFixture, "-o", generated, "--compat-js"], options);
  const embedded = spawnSync(generated, [], options);
  const officialEmbedded = spawnSync(process.execPath, [officialCli, importFixture], options);
  if (build.status !== 0 || embedded.status !== 0 || JSON.stringify(normalize(embedded)) !== JSON.stringify(normalize(officialEmbedded))) {
    failures += 1;
    console.error(`QuickJS埋め込み実行ファイル差分:\nbuild=${JSON.stringify(normalize(build))}\nofficial=${JSON.stringify(normalize(officialEmbedded))}\nembedded=${JSON.stringify(normalize(embedded))}`);
  }

  const invalidEmit = spawnSync(executable, ["build", importFixture, "-o", generated, "--compat-js", "--emit", "obj"], options);
  if (invalidEmit.status !== 2 || !invalidEmit.stderr.includes("--emit exeだけ")) {
    failures += 1;
    console.error(`QuickJS互換の不正emitを拒否しませんでした: ${JSON.stringify(normalize(invalidEmit))}`);
  }

  if (failures > 0) throw new Error(`QuickJS互換モードの公式差分が${failures}件あります`);
  const commandCount = new Set(cases.flatMap((testCase) => testCase.commands)).size;
  console.log(`QuickJS公式差分テスト: ${cases.length}ケース・${commandCount}命令・埋め込み実行ファイル成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildCompatLnako() {
  const result = spawnSync("zig", ["build", "-Dcompat-js=true"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`QuickJS互換lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return {
    stdout: result.stdout.replaceAll("\r\n", "\n"),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}

function normalizeFailure(result) {
  const output = `${result.stdout}\n${result.stderr}`;
  return { failed: result.status !== 0 || result.stderr.length > 0 || /\[(?:実行時)?エラー\]/.test(output) || output.includes("実行時エラー:") };
}
