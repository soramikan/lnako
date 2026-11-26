import { mkdirSync, writeFileSync, existsSync } from "node:fs";
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
const executableSuffix = process.platform === "win32" ? ".exe" : "";
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

  // `--compat-js --backend aot` も公式・interpreterと比較する。`sys.__exec`
  // （組み込み命令の文字列dispatch）を含む `compat-js-host` は、AOTの
  // コア命令ディスパッチ接続後に3者一致の対象へ含める。残る次の2ケースは
  // AOTの対象外なので理由付きで除外する。
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
    const generated = resolve(temporary, `compat-js-aot-${testCase.id}${executableSuffix}`);
    const build = spawnSync(executable, ["build", sourcePath, "-o", generated, "--compat-js", "--backend", "aot"], options);
    let aot = build;
    if (build.status === 0) aot = spawnSync(generated, [], options);
    const officialSummary = testCase.expectedFailure ? normalizeFailure(official) : normalize(official);
    const interpreterSummary = testCase.expectedFailure ? normalizeFailure(interpreter) : normalize(interpreter);
    const aotSummary = testCase.expectedFailure ? normalizeFailure(aot) : normalize(aot);
    const mismatched = build.status !== 0 ||
      build.error != null ||
      official.error != null ||
      interpreter.error != null ||
      aot.error != null ||
      (testCase.expectedFailure
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
  const generatedBridge = resolve(temporary, `compat-js-var-bridge${executableSuffix}`);
  const buildBridge = spawnSync(executable, ["build", variableBridgeFixture, "-o", generatedBridge, "--compat-js", "--backend", "aot"], options);
  const aotBridge = buildBridge.status === 0 ? spawnSync(generatedBridge, [], options) : buildBridge;
  const bridgeSummaries = [normalize(officialBridge), normalize(interpreterBridge), normalize(aotBridge)];
  if (
    buildBridge.status !== 0 ||
    buildBridge.error != null ||
    officialBridge.status !== 0 ||
    officialBridge.error != null ||
    interpreterBridge.status !== 0 ||
    interpreterBridge.error != null ||
    aotBridge.status !== 0 ||
    aotBridge.error != null ||
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
  if (withoutFlag.status === 0 || withoutFlag.error != null || !(withoutFlag.stderr ?? "").includes("JavaScriptの取り込みには--compat-jsが必要です")) {
    failures += 1;
    console.error(`--compat-js省略時にJS取り込みを拒否しませんでした: ${JSON.stringify(normalize(withoutFlag))}`);
  }

  const hatenaFixture = resolve(root, "tests/fixtures/compat-js-hatena.nako3");
  const hatenaWithoutFlag = spawnSync(executable, ["run", hatenaFixture], options);
  if (hatenaWithoutFlag.status === 0 || hatenaWithoutFlag.error != null || !(hatenaWithoutFlag.stderr ?? "").includes("QuickJsCompatibilityRequired")) {
    failures += 1;
    console.error(`ハテナ関数のJS:指定を通常モードで拒否しませんでした: ${JSON.stringify(normalize(hatenaWithoutFlag))}`);
  }

  const generated = resolve(temporary, `compat-program${executableSuffix}`);
  const build = spawnSync(executable, ["build", importFixture, "-o", generated, "--compat-js"], options);
  const embedded = spawnSync(generated, [], options);
  const officialEmbedded = spawnSync(process.execPath, [officialCli, importFixture], options);
  if (
    build.status !== 0 ||
    build.error != null ||
    embedded.status !== 0 ||
    embedded.error != null ||
    officialEmbedded.error != null ||
    JSON.stringify(normalize(embedded)) !== JSON.stringify(normalize(officialEmbedded))
  ) {
    failures += 1;
    console.error(`QuickJS埋め込み実行ファイル差分:\nbuild=${JSON.stringify(normalize(build))}\nofficial=${JSON.stringify(normalize(officialEmbedded))}\nembedded=${JSON.stringify(normalize(embedded))}`);
  }

  const invalidEmit = spawnSync(executable, ["build", importFixture, "-o", generated, "--compat-js", "--emit", "obj"], options);
  if (invalidEmit.status !== 2 || invalidEmit.error != null || !(invalidEmit.stderr ?? "").includes("--emit exeだけ")) {
    failures += 1;
    console.error(`QuickJS互換の不正emitを拒否しませんでした: ${JSON.stringify(normalize(invalidEmit))}`);
  }

  // Issue #297: パッケージ内ESMの戻り値候補について、助詞スロットの割り当てと
  // 静的に確定できないentryの拒否をInterpreter/AOTで検証する。公式cnako3は
  // `pkg:`ローカルパス依存を持たないlnako独自機能のため、このブロックは公式
  // fixtures・公式比較へ混入させず、一時プロジェクトで両経路の出力と拒否診断を
  // 検証する。同じNako構文を公式の直接ESM取り込みでも実行し、期待値を固定する。
  {
    const packageRoot = resolve(temporary, "package-calls-297");
    const app = resolve(packageRoot, "app");
    const sandboxHome = resolve(packageRoot, "home");
    mkdirSync(resolve(app, "packages/owned"), { recursive: true });
    mkdirSync(resolve(app, "packages/badpkg"), { recursive: true });
    mkdirSync(sandboxHome, { recursive: true });

    const manifest = `[package]
name = "package-calls-297"
version = "0.1.0"
license = "MIT"

[profiles.compat]
runtime = "lnako"
os = "linux"
cpu = "x86_64"
abi = "gnu"
compat-js = true

[dependencies.path]
owned = { path = "packages/owned" }
badpkg = { path = "packages/badpkg" }
`;
    const packageManifest = (name) => `[package]
name = "${name}"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "main.nako3"
`;
    const plugin = `export default {
  外部倍算: { type: "func", josi: [["を"]], fn: (value) => Number(value) * 2 },
  外部引算: { type: "func", josi: [["から"],["を"]], fn: (a, b) => Number(a) - Number(b) },
  外部定数: { type: "const", value: 8 },
};
`;
    const ownedMain = `!「./plugin.mjs」を取り込む。
●試験とは
  3を外部倍算で戻る。
ここまで
●C風とは
  外部倍算(3)を戻る。
ここまで
●定数値とは
  「x」と表示して外部定数を戻る。
ここまで
●連文とは
  「x」と表示して3を外部倍算で戻る。
ここまで
●引算とは
  3を10から外部引算で戻る。
ここまで
`;
    const main = `!「pkg:owned」を取り込む
●束縛値とは
  N=5
  Nで戻る。
ここまで
●改行値とは
  改行で戻る。
ここまで
owned__試験()を表示
owned__C風()を表示
owned__定数値()を表示
owned__連文()を表示
owned__引算()を表示
束縛値()を表示
改行値()を表示
`;
    const badPlugin = `export default {
  外部定数: { type: "const", value: 8, fn(x) { return x; } },
  式が型: { type: "func" && "const", value: 8 },
  上書き: { type: "func", josi: [["を"]], fn: (x) => x },
  上書き: { type: "const", value: 8 },
  助詞不明: { type: "func", josi: buildJosi(), fn: (x) => x },
  外部倍算: { type: "func", josi: [["を"]], fn: (x) => Number(x) * 2 },
};
`;
    const badMain = `!「./plugin.mjs」を取り込む。
●定数呼出とは
  3を外部定数で戻る。
ここまで
●式型呼出とは
  3を式が型で戻る。
ここまで
●上書き呼出とは
  3を上書きで戻る。
ここまで
●助詞不明呼出とは
  3を助詞不明で戻る。
ここまで
●誤助詞とは
  3に外部倍算で戻る。
ここまで
●余分とは
  3を4から外部倍算で戻る。
ここまで
`;

    writeFileSync(resolve(app, "nako.toml"), manifest);
    writeFileSync(resolve(app, "main.nako3"), main);
    writeFileSync(resolve(app, "packages/owned/nako.toml"), packageManifest("owned"));
    writeFileSync(resolve(app, "packages/owned/main.nako3"), ownedMain);
    writeFileSync(resolve(app, "packages/owned/plugin.mjs"), plugin);
    writeFileSync(resolve(app, "packages/badpkg/nako.toml"), packageManifest("badpkg"));
    writeFileSync(resolve(app, "packages/badpkg/main.nako3"), badMain);
    writeFileSync(resolve(app, "packages/badpkg/plugin.mjs"), badPlugin);

    const sandboxOptions = (cwd) => ({
      ...options,
      cwd,
      env: {
        ...options.env,
        HOME: sandboxHome,
        LOCALAPPDATA: sandboxHome,
        XDG_CACHE_HOME: resolve(sandboxHome, "cache"),
      },
    });
    const expectedPackageStdout = "6\n6\nx\n8\nx\n6\n7\n5\n\n\n";
    const packageInterpreter = spawnSync(
      executable,
      ["run", "main.nako3", "--compat-js", "--profile", "compat", "--offline"],
      sandboxOptions(app),
    );
    if (packageInterpreter.status !== 0 || normalize(packageInterpreter).stdout !== expectedPackageStdout) {
      failures += 1;
      console.error(
        `Issue #297 パッケージ戻り値候補のInterpreter実行差分: ${JSON.stringify(normalize(packageInterpreter))}`,
      );
      if (packageInterpreter.stderr) console.error(`Interpreter stderr:\n${packageInterpreter.stderr}`);
    }

    // Windowsのcompat AOTリンクは既存の未対応境界のため、AOT実行は他OSで固定する。
    if (process.platform !== "win32") {
      const packageBinary = resolve(packageRoot, `package-calls-297${executableSuffix}`);
      const packageBuild = spawnSync(
        executable,
        ["build", "main.nako3", "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", packageBinary, "-O0"],
        sandboxOptions(app),
      );
      const packageAot = packageBuild.status === 0 ? spawnSync(packageBinary, [], sandboxOptions(app)) : packageBuild;
      if (
        packageBuild.status !== 0 ||
        packageAot.status !== 0 ||
        normalize(packageAot).stdout !== expectedPackageStdout
      ) {
        failures += 1;
        console.error(
          `Issue #297 パッケージ戻り値候補のAOT実行差分: build=${JSON.stringify(normalize(packageBuild))} aot=${JSON.stringify(normalize(packageAot))}`,
        );
        if (packageBuild.stderr) console.error(`AOT build stderr:\n${packageBuild.stderr}`);
      }
    }

    // 公式3.7.24の直接ESM取り込みで、同じ助詞呼出しの期待値を実行して固定する。
    const officialRoot = resolve(packageRoot, "official-esm");
    mkdirSync(officialRoot, { recursive: true });
    writeFileSync(resolve(officialRoot, "plugin.mjs"), plugin);
    writeFileSync(resolve(officialRoot, "oracle.nako3"), `!「./plugin.mjs」を取り込む。
●試験とは
  3を外部倍算で戻る。
ここまで
●C風とは
  外部倍算(3)を戻る。
ここまで
●定数値とは
  「x」と表示して外部定数を戻る。
ここまで
●連文とは
  「x」と表示して3を外部倍算で戻る。
ここまで
●引算とは
  3を10から外部引算で戻る。
ここまで
試験()を表示。
C風()を表示。
定数値()を表示。
連文()を表示。
引算()を表示。
`);
    const officialSuccess = spawnSync(
      process.execPath,
      [officialCli, "oracle.nako3"],
      sandboxOptions(officialRoot),
    );
    const expectedOfficialStdout = "6\n6\nx\n8\nx\n6\n7\n";
    if (officialSuccess.status !== 0 || normalize(officialSuccess).stdout !== expectedOfficialStdout) {
      failures += 1;
      console.error(
        `Issue #297 公式ESM直接取り込みの助詞呼出し差分: ${JSON.stringify(normalize(officialSuccess))}`,
      );
      if (officialSuccess.stderr) console.error(`公式stderr:\n${officialSuccess.stderr}`);
    }

    const diagnosticText = "『戻』文の直前に未解決の引数があります";
    const rejectCases = [
      {
        id: "method-const",
        call: "badpkg__定数呼出()を表示",
        officialMain: `!「./plugin.mjs」を取り込む。\n●試験とは\n  3を外部定数で戻る。\nここまで\n試験()を表示。\n`,
        officialPlugin: `export default { 外部定数: { type: "const", value: 8, fn(x) { return x; } } };\n`,
      },
      {
        id: "computed-type",
        call: "badpkg__式型呼出()を表示",
        officialMain: `!「./plugin.mjs」を取り込む。\n●試験とは\n  3を外部定数で戻る。\nここまで\n試験()を表示。\n`,
        officialPlugin: `export default { 外部定数: { type: "func" && "const", value: 8 } };\n`,
      },
      {
        id: "duplicate-key",
        call: "badpkg__上書き呼出()を表示",
        officialMain: `!「./plugin.mjs」を取り込む。\n●試験とは\n  3を外部倍算で戻る。\nここまで\n試験()を表示。\n`,
        officialPlugin: `export default {\n  外部倍算: { type: "func", josi: [["を"]], fn: (x) => x },\n  外部倍算: { type: "const", value: 8 },\n};\n`,
      },
      {
        id: "wrong-particle",
        call: "badpkg__誤助詞()を表示",
        officialMain: `!「./plugin.mjs」を取り込む。\n●試験とは\n  3に外部倍算で戻る。\nここまで\n試験()を表示。\n`,
        officialPlugin: `export default { 外部倍算: { type: "func", josi: [["を"]], fn: (x) => Number(x) * 2 } };\n`,
      },
      {
        id: "extra-argument",
        call: "badpkg__余分()を表示",
        officialMain: `!「./plugin.mjs」を取り込む。\n●試験とは\n  3を4から外部倍算で戻る。\nここまで\n試験()を表示。\n`,
        officialPlugin: `export default { 外部倍算: { type: "func", josi: [["を"]], fn: (x) => Number(x) * 2 } };\n`,
      },
      {
        id: "unknown-josi",
        call: "badpkg__助詞不明呼出()を表示",
        officialMain: null,
        officialPlugin: null,
      },
    ];

    for (const item of rejectCases) {
      const rejectSource = resolve(app, `reject-${item.id}.nako3`);
      writeFileSync(rejectSource, `!「pkg:badpkg」を取り込む\n${item.call}\n`);
      const rejectInterpreter = spawnSync(
        executable,
        ["run", `reject-${item.id}.nako3`, "--compat-js", "--profile", "compat", "--offline"],
        sandboxOptions(app),
      );
      if (rejectInterpreter.status === 0 || !(rejectInterpreter.stderr ?? "").includes(diagnosticText)) {
        failures += 1;
        console.error(
          `Issue #297 ${item.id}をInterpreterが拒否しませんでした: ${JSON.stringify(normalize(rejectInterpreter))}`,
        );
      }
      if (process.platform !== "win32") {
        const rejectBinary = resolve(packageRoot, `package-calls-297-reject-${item.id}${executableSuffix}`);
        const rejectBuild = spawnSync(
          executable,
          ["build", `reject-${item.id}.nako3`, "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", rejectBinary, "-O0"],
          sandboxOptions(app),
        );
        if (rejectBuild.status === 0 || !(rejectBuild.stderr ?? "").includes(diagnosticText) || existsSync(rejectBinary)) {
          failures += 1;
          console.error(
            `Issue #297 ${item.id}をAOTが拒否しませんでした: ${JSON.stringify(normalize(rejectBuild))}`,
          );
        }
      }
      if (item.officialMain != null) {
        const officialCase = resolve(packageRoot, `official-${item.id}`);
        mkdirSync(officialCase, { recursive: true });
        writeFileSync(resolve(officialCase, "plugin.mjs"), item.officialPlugin);
        writeFileSync(resolve(officialCase, "oracle.nako3"), item.officialMain);
        const officialRejected = spawnSync(process.execPath, [officialCli, "oracle.nako3"], sandboxOptions(officialCase));
        const officialOutput = `${officialRejected.stdout ?? ""}${officialRejected.stderr ?? ""}`;
        if (!officialOutput.includes("未解決の引数")) {
          failures += 1;
          console.error(
            `Issue #297 公式ESM直接取り込みが${item.id}を拒否しませんでした: ${JSON.stringify(normalize(officialRejected))}`,
          );
        }
      }
    }
    if (failures === 0) {
      console.log("Issue #297 パッケージ戻り値候補: 公式直接ESMとInterpreter/AOTの助詞割当・拒否診断が一致");
    }
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
  const summary = {
    stdout: (result.stdout ?? "").replaceAll("\r\n", "\n"),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
  if (result.error != null) summary.error = result.error?.message ?? null;
  return summary;
}

function normalizeFailure(result) {
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const output = `${stdout}\n${stderr}`;
  return { failed: result.error != null || result.status !== 0 || stderr.length > 0 || /\[(?:実行時)?エラー\]/.test(output) || output.includes("実行時エラー:") };
}
