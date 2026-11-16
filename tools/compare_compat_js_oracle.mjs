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

  // `--compat-js --backend aot` も公式・interpreterと比較する。ただし次の
  // 3ケースはAOTの対象外なので理由付きで除外する。
  // - `compat-js-host`: §9.1 のとおり `sys.__exec`（組み込み命令の文字列
  //   dispatch）を含み、AOTでは明示エラーになる。境界そのものは
  //   tools/check_aot_quickjs_separation.mjs で固定する。
  // - `compat-js-hatena`: `JS:`指定のハテナ関数はAOTが
  //   JavaScriptCompatibilityRequiredで拒否する（interpreter専用）。
  // - `compat-js-plugin-imports`: namespaceを持たないbare ESM pluginの命令を
  //   AOT codegenが解決できずUnknownAssignmentTargetになる（ESM pluginの
  //   AOT invokeは tests/fixtures/package-plugin-npm の参照fixtureが担当）。
  //
  // `compat-js-object-get-name.nako3` の2者一致（interpreter/AOT）は
  // tools/check_aot_quickjs_separation.mjs が担当する。cnako3 の `__findVar`
  // は外側クロージャのローカルや `__v0` のシステム定数を探索せず、数値引数で
  // 例外になるため、このfixtureを公式との3者比較には含めない。
  const aotSkips = new Map([
    ["compat-js-host", "sys.__exec（組み込み命令の動的dispatch）はAOT未対応"],
    ["compat-js-hatena", "JS:指定のハテナ関数はAOT未対応"],
    ["compat-js-plugin-imports", "bare ESM plugin命令のAOT codegen未対応"],
  ]);
  let aotCaseCount = 0;
  for (const testCase of cases) {
    if (aotSkips.has(testCase.id)) continue;
    aotCaseCount += 1;
    const sourcePath = resolve(root, "tests/fixtures", testCase.fixture);
    const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const interpreter = spawnSync(executable, ["run", sourcePath, "--compat-js"], options);
    const generated = resolve(temporary, `compat-js-aot-${testCase.id}`);
    const build = spawnSync(executable, ["build", sourcePath, "-o", generated, "--compat-js", "--backend", "aot"], options);
    let aot = build;
    if (build.status === 0) aot = spawnSync(generated, [], options);
    const officialSummary = testCase.expectedFailure ? normalizeFailure(official) : normalize(official);
    const interpreterSummary = testCase.expectedFailure ? normalizeFailure(interpreter) : normalize(interpreter);
    const aotSummary = testCase.expectedFailure ? normalizeFailure(aot) : normalize(aot);
    const mismatched = build.status !== 0 || (testCase.expectedFailure
      ? !officialSummary.failed || !interpreterSummary.failed || !aotSummary.failed
      : official.status !== 0 ||
        interpreter.status !== 0 ||
        aot.status !== 0 ||
        JSON.stringify(aotSummary) !== JSON.stringify(officialSummary) ||
        JSON.stringify(aotSummary) !== JSON.stringify(interpreterSummary));
    if (mismatched) {
      failures += 1;
      console.error(
        `QuickJS AOT差分 ${testCase.id}:\nofficial=${JSON.stringify(officialSummary, null, 2)}\n` +
          `interpreter=${JSON.stringify(interpreterSummary, null, 2)}\naot=${JSON.stringify(aotSummary, null, 2)}`,
      );
      if (build.stderr) console.error(`AOT build stderr:\n${build.stderr}`);
      if (aot.stderr) console.error(`AOT stderr:\n${aot.stderr}`);
    }
  }

  // ホスト変数bridge（`__getSysVar` / `__findVar` / `__setSysVar` /
  // `__getSore` / `__setSore`）の3者一致。oracleの9ケースへ10件目を足すと
  // compat-js-evidence.json の件数契約を壊すため、fixtureはここで直接比較する。
  // 関数内ローカルと無修飾 `__setSysVar` は cnako3 3.7.24 と意図的に差がある
  // ためこのfixtureには含めず、2者一致を check_aot_quickjs_separation.mjs が
  // `compat-js-var-bridge-lnako.nako3` で固定する。
  const variableBridgeFixture = resolve(root, "tests/fixtures/compat-js-var-bridge.nako3");
  const officialBridge = spawnSync(process.execPath, [officialCli, variableBridgeFixture], options);
  const interpreterBridge = spawnSync(executable, ["run", variableBridgeFixture, "--compat-js"], options);
  const generatedBridge = resolve(temporary, "compat-js-var-bridge");
  const buildBridge = spawnSync(executable, ["build", variableBridgeFixture, "-o", generatedBridge, "--compat-js", "--backend", "aot"], options);
  const aotBridge = buildBridge.status === 0 ? spawnSync(generatedBridge, [], options) : buildBridge;
  const bridgeSummaries = [normalize(officialBridge), normalize(interpreterBridge), normalize(aotBridge)];
  if (
    buildBridge.status !== 0 ||
    officialBridge.status !== 0 ||
    interpreterBridge.status !== 0 ||
    aotBridge.status !== 0 ||
    JSON.stringify(bridgeSummaries[0]) !== JSON.stringify(bridgeSummaries[1]) ||
    JSON.stringify(bridgeSummaries[0]) !== JSON.stringify(bridgeSummaries[2])
  ) {
    failures += 1;
    console.error(`QuickJS 変数bridgeの3者差分: official=${JSON.stringify(bridgeSummaries[0], null, 2)}\ninterpreter=${JSON.stringify(bridgeSummaries[1], null, 2)}\naot=${JSON.stringify(bridgeSummaries[2], null, 2)}`);
    if (officialBridge.stderr) console.error(`公式stderr:\n${officialBridge.stderr}`);
    if (interpreterBridge.stderr) console.error(`interpreter stderr:\n${interpreterBridge.stderr}`);
    if (buildBridge.stderr) console.error(`AOT build stderr:\n${buildBridge.stderr}`);
    if (aotBridge.stderr) console.error(`AOT stderr:\n${aotBridge.stderr}`);
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
  console.log(
    `QuickJS公式差分テスト: ${cases.length}ケース・${commandCount}命令・AOT ${aotCaseCount}ケース` +
      `（AOT対象外 ${aotSkips.size}件: ${[...aotSkips.keys()].join(", ")}）・` +
      "変数bridge 3者一致・埋め込み実行ファイル成功",
  );
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
