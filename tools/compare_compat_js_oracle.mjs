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

  // Issue #297: ローカルパス依存パッケージ内のESM plugin命令を、戻り値の
  // 助詞呼出し（`3を外部倍算で戻る`）としてInterpreterとAOTの双方で実行する。
  // 公式cnako3は`pkg:`ローカルパス依存を持たないlnako独自機能のため、この
  // ブロックは公式fixtures・公式比較へ混入させず、一時プロジェクトで
  // Interpreter/AOTの実行結果と拒否診断だけを検証する。
  {
    const packageRoot = resolve(temporary, "package-calls-297");
    const app = resolve(packageRoot, "app");
    const reject = resolve(packageRoot, "reject");
    const sandboxHome = resolve(packageRoot, "home");
    mkdirSync(resolve(app, "packages/owned"), { recursive: true });
    mkdirSync(resolve(reject, "packages/badpkg"), { recursive: true });
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
`;
    const rejectManifest = manifest.replace('owned = { path = "packages/owned" }', 'badpkg = { path = "packages/badpkg" }');
    const ownedManifest = `[package]
name = "owned"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "main.nako3"
`;
    const plugin = `export default {
  外部倍算: { type: "func", josi: [["を"]], fn: (value) => Number(value) * 2 },
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
束縛値()を表示
改行値()を表示
`;
    const badManifest = `[package]
name = "badpkg"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "main.nako3"
`;
    const badMain = `!「./plugin.mjs」を取り込む。
●定数呼出とは
  3を外部定数で戻る。
ここまで
`;
    const rejectMain = `!「pkg:badpkg」を取り込む
badpkg__定数呼出()を表示
`;

    writeFileSync(resolve(app, "nako.toml"), manifest);
    writeFileSync(resolve(app, "main.nako3"), main);
    writeFileSync(resolve(app, "packages/owned/nako.toml"), ownedManifest);
    writeFileSync(resolve(app, "packages/owned/main.nako3"), ownedMain);
    writeFileSync(resolve(app, "packages/owned/plugin.mjs"), plugin);
    writeFileSync(resolve(reject, "nako.toml"), rejectManifest);
    writeFileSync(resolve(reject, "main.nako3"), rejectMain);
    writeFileSync(resolve(reject, "packages/badpkg/nako.toml"), badManifest);
    writeFileSync(resolve(reject, "packages/badpkg/main.nako3"), badMain);
    writeFileSync(resolve(reject, "packages/badpkg/plugin.mjs"), "export default { 外部定数: { type: 'const', value: 8 } };\n");

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
    const expectedPackageStdout = "6\n6\nx\n8\n5\n\n\n";
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

    const rejectInterpreter = spawnSync(
      executable,
      ["run", "main.nako3", "--compat-js", "--profile", "compat", "--offline"],
      sandboxOptions(reject),
    );
    const rejectDiagnostic = "『戻』文の直前に未解決の引数があります";
    if (rejectInterpreter.status === 0 || !(rejectInterpreter.stderr ?? "").includes(rejectDiagnostic)) {
      failures += 1;
      console.error(
        `Issue #297 パッケージ定数への保留引数をInterpreterが拒否しませんでした: ${JSON.stringify(normalize(rejectInterpreter))}`,
      );
    }
    if (process.platform !== "win32") {
      const rejectBinary = resolve(packageRoot, `package-calls-297-reject${executableSuffix}`);
      const rejectBuild = spawnSync(
        executable,
        ["build", "main.nako3", "--compat-js", "--backend", "aot", "--profile", "compat", "--offline", "-o", rejectBinary, "-O0"],
        sandboxOptions(reject),
      );
      if (rejectBuild.status === 0 || !(rejectBuild.stderr ?? "").includes(rejectDiagnostic) || existsSync(rejectBinary)) {
        failures += 1;
        console.error(
          `Issue #297 パッケージ定数への保留引数をAOTが拒否しませんでした: ${JSON.stringify(normalize(rejectBuild))}`,
        );
      }
    }
    if (failures === 0) {
      console.log("Issue #297 パッケージ戻り値候補: Interpreter/AOTの関数呼出しと定数の保留引数拒否が一致");
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
