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

  // Issue #297 第6回レビュー: 実登録候補ごとの助詞・可変長・不足判定と、
  // アクセサ・エスケープキー・複合式entryの解析段階拒否をInterpreter/AOTで
  // 固定する。既存9ケースの集計は変更せず、このブロックだけを追加する。
  {
    const reviewRoot = resolve(temporary, "package-review6-297");
    const app = resolve(reviewRoot, "app");
    const sandboxHome = resolve(reviewRoot, "home");
    mkdirSync(sandboxHome, { recursive: true });
    const write = (relative, data) => {
      const path = resolve(app, relative);
      mkdirSync(resolve(path, ".."), { recursive: true });
      writeFileSync(path, data);
    };
    const manifest = `[package]
name = "package-review6-297"
version = "0.1.0"
license = "MIT"

[profiles.compat]
runtime = "lnako"
os = "linux"
cpu = "x86_64"
abi = "gnu"
compat-js = true

[dependencies.path]
ghost = { path = "packages/ghost" }
variable = { path = "packages/variable" }
variable0 = { path = "packages/variable0" }
bad = { path = "packages/bad" }
short = { path = "packages/short" }
`;
    const packageManifest = (name) => `[package]
name = "${name}"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "main.nako3"
`;
    write("nako.toml", manifest);
    write("packages/ghost/nako.toml", packageManifest("ghost"));
    write("packages/ghost/main.nako3", `!「./a.mjs」を取り込む。
!「./b.mjs」を取り込む。
●差分とは
  3を外部命令で戻る。
ここまで
●順序とは
  3を10から外部引算で戻る。
ここまで
●両方とは
  3を10から外部競合で戻る。
ここまで
`);
    write("packages/ghost/a.mjs", `export default {
  外部命令: { type: "func", josi: [["を"]], fn: (a) => Number(a) * 2 },
  外部引算: { type: "func", josi: [["から"],["を"]], fn: (a, b) => Number(a) - Number(b) },
  外部競合: { type: "func", josi: [["から"],["を"]], fn: (a, b) => Number(a) - Number(b) },
};
`);
    write("packages/ghost/b.mjs", `export default { 外部競合: { type: "func", josi: [["を"],["から"]], fn: (b, a) => Number(a) - Number(b) + 100 } };
function 未使用() {
  navigator.nako3.addPluginObject("b", {
    外部命令: { type: "func", josi: [["に"]], fn: (a) => Number(a) * 3 },
    外部引算: { type: "func", josi: [["を"],["から"]], fn: (b, a) => Number(a) - Number(b) + 100 }
  });
}
`);
    write("packages/variable/nako.toml", packageManifest("variable"));
    write("packages/variable/plugin.mjs", `export default { 外部可変: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(1) } };
`);
    write("packages/variable/main.nako3", `!「./plugin.mjs」を取り込む。
●試験とは
  3と5を外部可変で戻る。
ここまで
`);
    write("packages/variable0/nako.toml", packageManifest("variable0"));
    write("packages/variable0/plugin.mjs", `export default { 外部可変: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(0) } };
`);
    write("packages/variable0/main.nako3", `!「./plugin.mjs」を取り込む。
●試験とは
  3と5を外部可変で戻る。
ここまで
`);
    write("packages/bad/nako.toml", packageManifest("bad"));
    write("packages/bad/main.nako3", `!「./plugin.mjs」を取り込む。
●アクセサとは
  3をアクセサで戻る。
ここまで
●エスケープとは
  3をエスケープで戻る。
ここまで
●複合式とは
  3を複合式で戻る。
ここまで
`);
    write("packages/bad/plugin.mjs", `export default {
  アクセサ: { type: "func", josi: [["を"]], fn: (a) => a * 2, get type() { return "const" }, value: 8 },
  エスケープ: { type: "func", josi: [["を"]], fn: (a) => a * 2, "ty\u0070e": "const", value: 8 },
  複合式: { type: "func", josi: [["を"]], fn: (a) => Number(a) * 2 } && { type: "const", value: 8 },
};
`);
    const entry = (pkg, body) => `!「pkg:${pkg}」を取り込む。\n${pkg}__試験()を表示。\n`;
    const callBody = (call) => `!「./plugin.mjs」を取り込む。\n●試験とは\n  ${call}\nここまで\n試験()を表示。\n`;
    const runApp = (args, cwd = app) => spawnSync(executable, args, { ...options, cwd, env: { ...options.env, HOME: sandboxHome, XDG_CACHE_HOME: resolve(sandboxHome, "cache") } });
    const official = (plugin, call) => {
      const dir = resolve(reviewRoot, `official-${Math.random().toString(36).slice(2)}`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(resolve(dir, "plugin.mjs"), plugin);
      writeFileSync(resolve(dir, "oracle.nako3"), callBody(call));
      return spawnSync(process.execPath, [officialCli, "oracle.nako3"], { ...options, cwd: dir, env: { ...options.env, HOME: sandboxHome } });
    };

    write("packages/short/nako.toml", packageManifest("short"));
    write("packages/short/plugin.mjs", `export default { 不足: { type: "func", josi: [["を"],["に"],["から"]], fn: (a, b, c) => [a, b, c] } };
`);
    write("packages/short/main.nako3", `!「./plugin.mjs」を取り込む。
●試験とは
  5を不足で戻る。
ここまで
`);
    write("ghost_main.nako3", `!「pkg:ghost」を取り込む。
ghost__差分()を表示
ghost__順序()を表示
ghost__両方()を表示
`);
    const ghostInterpreter = runApp(["run", "ghost_main.nako3", "--compat-js", "--profile", "compat", "--offline"]);
    if (ghostInterpreter.status !== 0 || normalize(ghostInterpreter).stdout !== "6\n7\n107\n") {
      failures += 1;
      console.error(`Issue #297 第6回 実登録候補の助詞割当(Interpreter): ${JSON.stringify(normalize(ghostInterpreter))}\n${ghostInterpreter.stderr ?? ""}`);
    }
    if (process.platform !== "win32") {
      const ghostBinary = resolve(reviewRoot, `review6-ghost${executableSuffix}`);
      const ghostBuild = runApp(["build", "ghost_main.nako3", "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", ghostBinary, "-O0"]);
      const ghostAot = ghostBuild.status === 0 ? spawnSync(ghostBinary, [], { ...options, cwd: app, env: { ...options.env, HOME: sandboxHome } }) : ghostBuild;
      if (ghostBuild.status !== 0 || ghostAot.status !== 0 || normalize(ghostAot).stdout !== "6\n7\n107\n") {
        failures += 1;
        console.error(`Issue #297 第6回 実登録候補の助詞割当(AOT): build=${JSON.stringify(normalize(ghostBuild))} aot=${JSON.stringify(normalize(ghostAot))}`);
      }
    }

    write("variable_main.nako3", entry("variable"));
    const variableInterpreter = runApp(["run", "variable_main.nako3", "--compat-js", "--profile", "compat", "--offline"]);
    if (variableInterpreter.status !== 0 || normalize(variableInterpreter).stdout !== "3\n") {
      failures += 1;
      console.error(`Issue #297 第6回 可変長助詞(Interpreter): ${JSON.stringify(normalize(variableInterpreter))}\n${variableInterpreter.stderr ?? ""}`);
    }
    if (process.platform !== "win32") {
      const variableBinary = resolve(reviewRoot, `review6-variable${executableSuffix}`);
      const variableBuild = runApp(["build", "variable_main.nako3", "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", variableBinary, "-O0"]);
      const variableAot = variableBuild.status === 0 ? spawnSync(variableBinary, [], { ...options, cwd: app, env: { ...options.env, HOME: sandboxHome } }) : variableBuild;
      if (variableBuild.status !== 0 || variableAot.status !== 0 || normalize(variableAot).stdout !== "3\n") {
        failures += 1;
        console.error(`Issue #297 第6回 可変長助詞(AOT): build=${JSON.stringify(normalize(variableBuild))} aot=${JSON.stringify(normalize(variableAot))}`);
      }
    }

    // 実行時 false の可変長指定は、未整列引数のまま実行時に拒否される。
    write("var_bool0.nako3", `!「pkg:variable0」を取り込む。\nvariable0__試験()を表示。\n`);
    const bool0Official = official(`export default { 外部可変: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(0) } };\n`, "3と5を外部可変で戻る。");
    const bool0Interpreter = runApp(["run", "var_bool0.nako3", "--compat-js", "--profile", "compat", "--offline"]);
    if (bool0Interpreter.status === 0 || !(bool0Interpreter.stderr ?? "").includes("未解決の引数")) {
      failures += 1;
      console.error(`Issue #297 第6回 実行時可変長falseの拒否(Interpreter): ${JSON.stringify(normalize(bool0Interpreter))}`);
    }
    if (!`${bool0Official.stdout ?? ""}${bool0Official.stderr ?? ""}`.includes("未解決の引数")) {
      failures += 1;
      console.error(`Issue #297 第6回 実行時可変長falseの公式拒否: ${JSON.stringify(normalize(bool0Official))}`);
    }

    const rejectCases = [
      { id: "accessor", name: "アクセサ", message: "未解決", plugin: `export default { 外部: { type: "func", josi: [["を"]], fn: (a) => a * 2, get type() { return "const" }, value: 8 } };\n` },
      { id: "escaped", name: "エスケープ", message: "未解決", plugin: `export default { 外部: { type: "func", josi: [["を"]], fn: (a) => a * 2, "ty\u0070e": "const", value: 8 } };\n` },
      { id: "object-expression", name: "複合式", message: "未解決", plugin: `export default { 外部: { type: "func", josi: [["を"]], fn: (a) => Number(a) * 2 } && { type: "const", value: 8 } };\n` },

    ];
    for (const item of rejectCases) {
      const source = `!「pkg:bad」を取り込む。\nbad__${item.name}()を表示。\n`;
      write(`review6-${item.id}.nako3`, source);
      const rejectInterpreter = runApp(["run", `review6-${item.id}.nako3`, "--compat-js", "--profile", "compat", "--offline"]);
      if (rejectInterpreter.status === 0 || !(rejectInterpreter.stderr ?? "").includes(item.message)) {
        failures += 1;
        console.error(`Issue #297 第6回 ${item.id}の解析拒否(Interpreter): ${JSON.stringify(normalize(rejectInterpreter))}\n${rejectInterpreter.stderr ?? ""}`);
      }
      if (process.platform !== "win32") {
        const rejectBinary = resolve(reviewRoot, `review6-reject-${item.id}${executableSuffix}`);
        const rejectBuild = runApp(["build", `review6-${item.id}.nako3`, "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", rejectBinary, "-O0"]);
        if (rejectBuild.status === 0 || !(rejectBuild.stderr ?? "").includes(item.message)) {
          failures += 1;
          console.error(`Issue #297 第6回 ${item.id}の解析拒否(AOT): ${JSON.stringify(normalize(rejectBuild))}`);
        }
      }
      const officialRejected = official(item.plugin, "3を外部で戻る。");
      if (!`${officialRejected.stdout ?? ""}${officialRejected.stderr ?? ""}`.includes("未解決の引数")) {
        failures += 1;
        console.error(`Issue #297 第6回 ${item.id}の公式拒否: ${JSON.stringify(normalize(officialRejected))}`);
      }
    }
    {
      write("review6-missing-two.nako3", `!「pkg:short」を取り込む。\nshort__試験()を表示。\n`);
      const missingInterpreter = runApp(["run", "review6-missing-two.nako3", "--compat-js", "--profile", "compat", "--offline"]);
      if (missingInterpreter.status === 0 || !(missingInterpreter.stderr ?? "").includes("引数が不足")) {
        failures += 1;
        console.error(`Issue #297 第6回 missing-twoの解析拒否(Interpreter): ${JSON.stringify(normalize(missingInterpreter))}\n${missingInterpreter.stderr ?? ""}`);
      }
      if (process.platform !== "win32") {
        const missingBinary = resolve(reviewRoot, `review6-missing-two${executableSuffix}`);
        const missingBuild = runApp(["build", "review6-missing-two.nako3", "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", missingBinary, "-O0"]);
        if (missingBuild.status === 0 || !(missingBuild.stderr ?? "").includes("引数が不足")) {
          failures += 1;
          console.error(`Issue #297 第6回 missing-twoの解析拒否(AOT): ${JSON.stringify(normalize(missingBuild))}\n${missingBuild.stderr ?? ""}`);
        }
      }
      const missingOfficial = official(`export default { 外部: { type: "func", josi: [["を"],["に"],["から"]], fn: (a, b, c) => [a, b, c] } };\n`, "5を外部で戻る。");
      if (!`${missingOfficial.stdout ?? ""}${missingOfficial.stderr ?? ""}`.includes("引数が不足")) {
        failures += 1;
        console.error(`Issue #297 第6回 missing-twoの公式拒否: ${JSON.stringify(normalize(missingOfficial))}`);
      }
    }
    if (failures === 0) console.log("Issue #297 第6回レビュー: 実登録候補と解析境界のInterpreter/AOT一致");
  }

  // Issue #297 第7回レビュー: (1) 空の josi 表を取得済みの0スロットとして扱い、
  // 連文マーカーを実引数に数えないこと、(2) 実行時に候補を確定する呼出しでも
  // 固定スロット順に式を一度だけ評価すること、(3) 先発の未確定catch-allが
  // 後発の実登録可変長命令の実行時メタデータ利用を無効にしないことを固定する。
  // 公式cnako3は `pkg:` を持たないため、Interpreter/AOTの比較はlnako固有の
  // 一時プロジェクト内で行い、期待値だけを公式の直接ESM取り込みで確認する。
  {
    const reviewRoot = resolve(temporary, "package-review7-297");
    const app = resolve(reviewRoot, "app");
    const sandboxHome = resolve(reviewRoot, "home");
    mkdirSync(sandboxHome, { recursive: true });
    const write = (relative, data) => {
      const path = resolve(app, relative);
      mkdirSync(resolve(path, ".."), { recursive: true });
      writeFileSync(path, data);
    };
    const manifest = `[package]
name = "package-review7-297"
version = "0.1.0"
license = "MIT"

[profiles.compat]
runtime = "lnako"
os = "linux"
cpu = "x86_64"
abi = "gnu"
compat-js = true

[dependencies.path]
zerostaticreal = { path = "packages/zerostaticreal" }
zerostaticmarkerreal = { path = "packages/zerostaticmarkerreal" }
zerostaticmarker = { path = "packages/zerostaticmarker" }
zeroruntimereal = { path = "packages/zeroruntimereal" }
zeroruntimemarkerreal = { path = "packages/zeroruntimemarkerreal" }
zeroruntimemarker = { path = "packages/zeroruntimemarker" }
zerovariablereal = { path = "packages/zerovariablereal" }
zerovariablemarkerreal = { path = "packages/zerovariablemarkerreal" }
zerovariablemarker = { path = "packages/zerovariablemarker" }
orderghost = { path = "packages/orderghost" }
orderboth = { path = "packages/orderboth" }
orderstatic = { path = "packages/orderstatic" }
orderruntime = { path = "packages/orderruntime" }
catchearly = { path = "packages/catchearly" }
catchcontrol = { path = "packages/catchcontrol" }
`;
    const packageManifest = (name) => `[package]
name = "${name}"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "main.nako3"
`;
    const runApp = (args, cwd = app) => spawnSync(executable, args, {
      ...options,
      cwd,
      env: {
        ...options.env,
        HOME: sandboxHome,
        LOCALAPPDATA: sandboxHome,
        XDG_CACHE_HOME: resolve(sandboxHome, "cache"),
      },
    });
    const runInterpreter = (entry) => runApp(["run", entry, "--compat-js", "--profile", "compat", "--offline"]);
    const runAot = (entry, name) => {
      if (process.platform === "win32") return null;
      const binary = resolve(reviewRoot, `${name}${executableSuffix}`);
      const build = runApp(["build", entry, "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-O0", "-o", binary]);
      return { build, run: build.status === 0 ? spawnSync(binary, [], {
        ...options,
        cwd: app,
        env: { ...options.env, HOME: sandboxHome, LOCALAPPDATA: sandboxHome, XDG_CACHE_HOME: resolve(sandboxHome, "cache") },
      }) : build };
    };
    const official = (files, source) => {
      const dir = resolve(reviewRoot, `official-${Math.random().toString(36).slice(2)}`);
      mkdirSync(dir, { recursive: true });
      for (const [name, data] of Object.entries(files)) writeFileSync(resolve(dir, name), data);
      writeFileSync(resolve(dir, "oracle.nako3"), source);
      return spawnSync(process.execPath, [officialCli, "oracle.nako3"], {
        ...options,
        cwd: dir,
        env: { ...options.env, HOME: sandboxHome, XDG_CACHE_HOME: resolve(sandboxHome, "cache") },
      });
    };
    const unresolved = "『戻』文の直前に未解決の引数があります";
    // 空の助詞表は解析時に拒否されるため、手前の式（表示x）を実行しない。
    // 診断の有無だけでなく、stdoutが空であることも固定する。
    const expectDiagnostic = (label, result, text = unresolved) => {
      if (result.status === 0 || !`${result.stderr ?? ""}`.includes(text) || (result.stdout ?? "") !== "") {
        failures += 1;
        console.error(`Issue #297 第7回 ${label}: 解析診断を返しませんでした ${JSON.stringify(normalize(result))}`);
      }
    };
    const expectInterpreter = (label, entry, stdout) => {
      const result = runInterpreter(entry);
      if (result.status !== 0 || normalize(result).stdout !== stdout) {
        failures += 1;
        console.error(`Issue #297 第7回 ${label}(Interpreter): ${JSON.stringify(normalize(result))}\n${result.stderr ?? ""}`);
      }
    };
    const expectAotDiagnostic = (label, entry, text = unresolved) => {
      const result = runAot(entry, `review7-${label}`);
      if (result == null) return;
      const observed = result.build.status === 0 ? result.run : result.build;
      if (observed.status === 0 || !(observed.stderr ?? "").includes(text) || (observed.stdout ?? "") !== "") {
        failures += 1;
        console.error(`Issue #297 第7回 ${label}(AOT): build=${JSON.stringify(normalize(result.build))} run=${JSON.stringify(normalize(result.run))}`);
      }
    };
    const expectAot = (label, entry, stdout) => {
      const result = runAot(entry, `review7-${label}`);
      if (result == null) return;
      if (result.build.status !== 0 || result.run.status !== 0 || normalize(result.run).stdout !== stdout) {
        failures += 1;
        console.error(`Issue #297 第7回 ${label}(AOT): build=${JSON.stringify(normalize(result.build))} run=${JSON.stringify(normalize(result.run))}\n${result.build.stderr ?? ""}`);
      }
    };

    write("nako.toml", manifest);
    for (const name of [
      "zerostaticreal", "zerostaticmarkerreal", "zerostaticmarker",
      "zeroruntimereal", "zeroruntimemarkerreal", "zeroruntimemarker",
      "zerovariablereal", "zerovariablemarkerreal", "zerovariablemarker",
      "orderghost", "orderboth",
      "orderstatic", "orderruntime", "catchearly", "catchcontrol",
    ]) {
      write(`packages/${name}/nako.toml`, packageManifest(name));
      // 依存解決は全packageのexport targetを先に検証するため、各対照の
      // main.nako3を書き終えるまで有効なプレースホルダを置く。
      write(`packages/${name}/main.nako3`, "1を戻す。\n");
    }

    // (1) 空の助詞表。静的経路 (isVariableJosi 省略) と実行時経路 (Boolean(0)) の
    // 両方で、実引数だけ・マーカーと実引数・マーカーだけを対照する。
    // 診断対象と非診断対象は同じパッケージに置けない（パッケージ全体が
    // コンパイルされる）ため、対照ごとに独立したパッケージにする。
    const zeroCases = [
      { tail: "real", label: "実引数", body: "3を外部命令で戻る。", diagnostic: true },
      { tail: "markerreal", label: "連文実引数", body: "「x」と表示して3を外部命令で戻る。", diagnostic: true },
      { tail: "marker", label: "連文単独", body: "「x」と表示して外部命令で戻る。", diagnostic: false },
    ];
    for (const variant of [
      { base: "zerostatic", label: "空助詞表(静的)", extra: "" },
      { base: "zeroruntime", label: "空助詞表(実行時)", extra: ", isVariableJosi: Boolean(0)" },
      // `isVariableJosi`が式でも、空の`josi`表は0スロットとして静的に
      // 確定している。可変長の真偽に依存せず解析時に拒否する。
      { base: "zerovariable", label: "空助詞表(可変真)", extra: ", isVariableJosi: Boolean(1)" },
    ]) {
      for (const item of zeroCases) {
        const name = `${variant.base}${item.tail}`;
        write(`packages/${name}/main.nako3`, `!「./plugin.mjs」を取り込む。\n●試験とは\n  ${item.body}\nここまで\n`);
        write(`packages/${name}/plugin.mjs`, `export default { 外部命令: { type: "func", josi: [], fn: (...args) => args.length${variant.extra} } };\n`);
        const entry = `review7-${name}.nako3`;
        write(entry, `!「pkg:${name}」を取り込む。\n${name}__試験()を表示。\n`);
        if (item.diagnostic) {
          expectDiagnostic(`${variant.label}-${item.label}-Interpreter`, runInterpreter(entry));
          expectAotDiagnostic(`${variant.label}-${item.label}-AOT`, entry);
        } else {
          // マーカーだけは診断しない。既存の連文戻り値 undefined は第6回までと
          // 同じ制約なので、値ではなく「マーカーを実引数として渡さない」ことを固定する。
          const marker = runInterpreter(entry);
          if (marker.status !== 0 || !(marker.stderr ?? "").includes("run:") || (marker.stderr ?? "").includes("未解決の引数")) {
            failures += 1;
            console.error(`Issue #297 第7回 ${variant.label}-${item.label}(Interpreter): ${JSON.stringify(normalize(marker))}\n${marker.stderr ?? ""}`);
          }
          const markerAot = runAot(entry, `review7-${name}`);
          if (markerAot != null && (markerAot.build.status !== 0 || markerAot.run.status !== 0 || (markerAot.run.stderr ?? "").includes("未解決の引数"))) {
            failures += 1;
            console.error(`Issue #297 第7回 ${variant.label}-${item.label}(AOT): build=${JSON.stringify(normalize(markerAot.build))} run=${JSON.stringify(normalize(markerAot.run))}`);
          }
        }
        if (item.tail === "real") {
          const officialReal = official({ "plugin.mjs": `export default { 外部命令: { type: "func", josi: [], fn: (...args) => args.length${variant.extra} } };\n` }, `!「./plugin.mjs」を取り込む。\n●試験とは\n  3を外部命令で戻る。\nここまで\n試験()を表示。\n`);
          if (!`${officialReal.stdout ?? ""}${officialReal.stderr ?? ""}`.includes(unresolved)) {
            failures += 1;
            console.error(`Issue #297 第7回 ${variant.label}の公式直接ESM拒否: ${JSON.stringify(normalize(officialReal))}`);
          }
        }
      }
    }

    // (1b) 助詞順の異なる二候補が並ぶ実登録フォールバック。後発が未登録なら
    // 先発の [["から"],["を"]] 計画、両方が実登録された`pkg:`なら後発の
    // [["を"],["から"]] 計画で評価する。式は選ばれた経路で一度だけ評価し、
    // 先に評価する式が例外なら後続の式を実行しない。
    const orderPackageMain = `!「./plugin.mjs」を取り込む。
!「./b.mjs」を取り込む。
●甲とは
 「a」と表示。
 3を戻す。
ここまで
●乙とは
 「b」と表示。
 10を戻す。
ここまで
●例外甲とは
 「a」と表示。
 「失敗A」のエラー発生
ここまで
●例外乙とは
 「b」と表示。
 「失敗B」のエラー発生
ここまで
●試験とは
甲()を乙()から外部命令で戻る。
ここまで
●例外試験甲とは
例外甲()を乙()から外部命令で戻る。
ここまで
●例外試験乙とは
例外甲()を例外乙()から外部命令で戻る。
ここまで
●例外試験後とは
乙()を例外甲()から外部命令で戻る。
ここまで
`;
    const orderEarlier = 'export default { 外部命令: { type: "func", josi: [["から"],["を"]], fn: (a, b) => a - b } };\n';
    const orderGhost = `export default {};
function 未使用() { navigator.nako3.addPluginObject("b", { 外部命令: { type: "func", josi: [["を"],["から"]], fn: (b, a) => a - b + 100 } }); }
`;
    const orderLater = 'export default { 外部命令: { type: "func", josi: [["を"],["から"]], fn: (b, a) => a - b + 100 } };\n';
    for (const variant of [
      { id: "orderghost", label: "後発未登録", later: orderGhost },
      { id: "orderboth", label: "両方実登録", later: orderLater },
    ]) {
      write(`packages/${variant.id}/main.nako3`, orderPackageMain);
      write(`packages/${variant.id}/plugin.mjs`, orderEarlier);
      write(`packages/${variant.id}/b.mjs`, variant.later);
    }
    write("review7-orderghost-value.nako3", "!「pkg:orderghost」を取り込む。\norderghost__試験()を表示。\n");
    write("review7-orderboth-value.nako3", "!「pkg:orderboth」を取り込む。\norderboth__試験()を表示。\n");
    const writeOrderError = (file, pkg, name) => write(file,
      `!「pkg:${pkg}」を取り込む。\nエラー監視\n${pkg}__${name}()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
    writeOrderError("review7-orderghost-exc-a.nako3", "orderghost", "例外試験甲");
    writeOrderError("review7-orderghost-exc-b.nako3", "orderghost", "例外試験乙");
    writeOrderError("review7-orderboth-exc-a.nako3", "orderboth", "例外試験甲");
    writeOrderError("review7-orderboth-exc-after.nako3", "orderboth", "例外試験後");
    expectInterpreter("後発未登録-評価順", "review7-orderghost-value.nako3", "b\na\n7\n");
    expectAot("後発未登録-評価順", "review7-orderghost-value.nako3", "b\na\n7\n");
    expectInterpreter("後発未登録-先発例外", "review7-orderghost-exc-a.nako3", "b\na\n捕捉:失敗A\n");
    expectAot("後発未登録-先発例外", "review7-orderghost-exc-a.nako3", "b\na\n捕捉:失敗A\n");
    expectInterpreter("後発未登録-後発例外", "review7-orderghost-exc-b.nako3", "b\n捕捉:失敗B\n");
    expectAot("後発未登録-後発例外", "review7-orderghost-exc-b.nako3", "b\n捕捉:失敗B\n");
    expectInterpreter("両方実登録-評価順", "review7-orderboth-value.nako3", "a\nb\n107\n");
    expectAot("両方実登録-評価順", "review7-orderboth-value.nako3", "a\nb\n107\n");
    expectInterpreter("両方実登録-先発例外", "review7-orderboth-exc-a.nako3", "a\n捕捉:失敗A\n");
    expectAot("両方実登録-先発例外", "review7-orderboth-exc-a.nako3", "a\n捕捉:失敗A\n");
    expectInterpreter("両方実登録-後発例外", "review7-orderboth-exc-after.nako3", "b\na\n捕捉:失敗A\n");
    expectAot("両方実登録-後発例外", "review7-orderboth-exc-after.nako3", "b\na\n捕捉:失敗A\n");
    const officialOrderGhost = official({ "plugin.mjs": orderEarlier, "b.mjs": orderGhost }, `${orderPackageMain}試験()を表示。\n`);
    if (officialOrderGhost.status !== 0 || normalize(officialOrderGhost).stdout !== "b\na\n7\n") {
      failures += 1;
      console.error(`Issue #297 第7回 後発未登録の公式直接ESM: ${JSON.stringify(normalize(officialOrderGhost))}`);
    }
    const officialOrderGhostException = official({ "plugin.mjs": orderEarlier, "b.mjs": orderGhost }, `${orderPackageMain}エラー監視\n例外試験乙()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
    if (officialOrderGhostException.status !== 0 || normalize(officialOrderGhostException).stdout !== "b\n捕捉:失敗B\n") {
      failures += 1;
      console.error(`Issue #297 第7回 後発未登録の公式例外: ${JSON.stringify(normalize(officialOrderGhostException))}`);
    }

    // (2) 実行時の候補が決まった助詞スロット順に式を一度だけ評価する。
    // josi [["から"],["を"]] は 乙()→b, 甲()→a の順で評価し、a-b=7。
    const orderFunctions = `!「./plugin.mjs」を取り込む。
●甲とは
 「a」と表示。
 3を戻す。
ここまで
●乙とは
 「b」と表示。
 10を戻す。
ここまで
●試験とは
甲()を乙()から外部命令で戻る。
ここまで
●例外甲とは
 「a」と表示。
 「失敗A」のエラー発生
ここまで
●例外乙とは
 「b」と表示。
 「失敗B」のエラー発生
ここまで
●例外試験甲とは
例外甲()を乙()から外部命令で戻る。
ここまで
●例外試験乙とは
例外甲()を例外乙()から外部命令で戻る。
ここまで
`;
    // 例外の順序対照: 乙が先に評価されるため、乙で例外なら甲は表示されない。
    const orderExceptions = `●甲とは
 「a」と表示。
 「失敗A」のエラー発生
ここまで
●乙とは
 「b」と表示。
 10を戻す。
ここまで
●試験とは
甲()を乙()から外部命令で戻る。
ここまで
`;
    const orderExceptionsLate = `●甲とは
 「a」と表示。
 3を戻す。
ここまで
●乙とは
 「b」と表示。
 「失敗B」のエラー発生
ここまで
●試験とは
甲()を乙()から外部命令で戻る。
ここまで
`;
    for (const variant of [
      { id: "orderstatic", label: "評価順(静的)", extra: "" },
      { id: "orderruntime", label: "評価順(実行時)", extra: ", isVariableJosi: Boolean(0)" },
    ]) {
      write(`packages/${variant.id}/main.nako3`, orderFunctions);
      write(`packages/${variant.id}/plugin.mjs`, `export default { 外部命令: { type: "func", josi: [["から"],["を"]], fn: (a, b) => a - b${variant.extra} } };\n`);
      write(`review7-${variant.id}-value.nako3`, `!「pkg:${variant.id}」を取り込む。\n${variant.id}__試験()を表示。\n`);
      write(`review7-${variant.id}-exception.nako3`, `!「pkg:${variant.id}」を取り込む。\nエラー監視\n${variant.id}__例外試験甲()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
      write(`review7-${variant.id}-exception-late.nako3`, `!「pkg:${variant.id}」を取り込む。\nエラー監視\n${variant.id}__例外試験乙()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
      expectInterpreter(`${variant.label}-正常`, `review7-${variant.id}-value.nako3`, "b\na\n7\n");
      expectAot(`${variant.label}-正常`, `review7-${variant.id}-value.nako3`, "b\na\n7\n");
      expectInterpreter(`${variant.label}-先発例外`, `review7-${variant.id}-exception.nako3`, "b\na\n捕捉:失敗A\n");
      expectAot(`${variant.label}-先発例外`, `review7-${variant.id}-exception.nako3`, "b\na\n捕捉:失敗A\n");
      expectInterpreter(`${variant.label}-後発例外`, `review7-${variant.id}-exception-late.nako3`, "b\n捕捉:失敗B\n");
      expectAot(`${variant.label}-後発例外`, `review7-${variant.id}-exception-late.nako3`, "b\n捕捉:失敗B\n");
    }
    const officialOrder = official({ "plugin.mjs": `export default { 外部命令: { type: "func", josi: [["から"],["を"]], fn: (a, b) => a - b, isVariableJosi: Boolean(0) } };\n` }, `${orderFunctions}試験()を表示。\n`);
    if (officialOrder.status !== 0 || normalize(officialOrder).stdout !== "b\na\n7\n") {
      failures += 1;
      console.error(`Issue #297 第7回 評価順の公式直接ESM: ${JSON.stringify(normalize(officialOrder))}`);
    }
    const officialException = official({ "plugin.mjs": `export default { 外部命令: { type: "func", josi: [["から"],["を"]], fn: (a, b) => a - b, isVariableJosi: Boolean(0) } };\n` }, `!「./plugin.mjs」を取り込む。\n${orderExceptions}エラー監視\n試験()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
    if (officialException.status !== 0 || normalize(officialException).stdout !== "b\na\n捕捉:失敗A\n") {
      failures += 1;
      console.error(`Issue #297 第7回 評価順の公式例外: ${JSON.stringify(normalize(officialException))}`);
    }
    const officialExceptionLate = official({ "plugin.mjs": `export default { 外部命令: { type: "func", josi: [["から"],["を"]], fn: (a, b) => a - b, isVariableJosi: Boolean(0) } };\n` }, `!「./plugin.mjs」を取り込む。\n${orderExceptionsLate}エラー監視\n試験()を表示。\nエラーならば\n「捕捉:{エラーメッセージ}」を表示。\nここまで\n`);
    if (officialExceptionLate.status !== 0 || normalize(officialExceptionLate).stdout !== "b\n捕捉:失敗B\n") {
      failures += 1;
      console.error(`Issue #297 第7回 評価順の公式後発例外: ${JSON.stringify(normalize(officialExceptionLate))}`);
    }

    // (3) 先発の未確定catch-all (default spread) があっても、後発の実登録
    // 可変長命令のメタデータで 3と5 を割り当てる。後発の実登録が勝つ対照も置く。
    write("packages/catchearly/main.nako3", `!「./b.mjs」を取り込む。\n!「./plugin.mjs」を取り込む。\n●試験とは\n3と5を外部命令で戻る。\nここまで\n`);
    write("packages/catchearly/b.mjs", `const p = { 外部無関係: { type: "func", josi: [], fn: () => 3 } };\nexport default { ...p };\n`);
    write("packages/catchearly/plugin.mjs", `export default { 外部命令: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(1) } };\n`);
    write("packages/catchcontrol/main.nako3", `!「./b.mjs」を取り込む。\n!「./plugin.mjs」を取り込む。\n●試験とは\n3と5を外部命令で戻る。\nここまで\n`);
    write("packages/catchcontrol/b.mjs", `const p = { 外部命令: { type: "func", josi: [["と","を"]], fn: () => 99 } };\nexport default { ...p };\n`);
    write("packages/catchcontrol/plugin.mjs", `export default { 外部命令: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(1) } };\n`);
    for (const name of ["catchearly", "catchcontrol"]) {
      write(`review7-${name}.nako3`, `!「pkg:${name}」を取り込む。\n${name}__試験()を表示。\n`);
      expectInterpreter(`${name}`, `review7-${name}.nako3`, "3\n");
      expectAot(`${name}`, `review7-${name}.nako3`, "3\n");
    }
    const officialCatch = official({
      "b.mjs": `const p = { 外部無関係: { type: "func", josi: [], fn: () => 3 } };\nexport default { ...p };\n`,
      "plugin.mjs": `export default { 外部命令: { type: "func", josi: [["と","を"]], fn: (...args) => args.length, isVariableJosi: Boolean(1) } };\n`,
    }, `!「./b.mjs」を取り込む。\n!「./plugin.mjs」を取り込む。\n●試験とは\n3と5を外部命令で戻る。\nここまで\n試験()を表示。\n`);
    if (officialCatch.status !== 0 || normalize(officialCatch).stdout !== "3\n") {
      failures += 1;
      console.error(`Issue #297 第7回 先発catch-allの公式直接ESM: ${JSON.stringify(normalize(officialCatch))}`);
    }
    if (failures === 0) console.log("Issue #297 第7回レビュー: 空助詞表・評価順・先発catch-allのInterpreter/AOT一致");
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
