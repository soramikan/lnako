import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

  // ESM pluginの戻り値候補（`3を外部倍算で戻る`）は、既存のpackage動的
  // 呼出し経路を通る。公式・Interpreter・AOTを同じ一時packageで比較し、
  // 助詞付き候補が6を返すことを固定する。fixture件数契約は増やさない。
  {
    const pkgRoot = join(temporary, "esm-return-package");
    const ownedRoot = join(pkgRoot, "packages", "owned");
    await mkdir(ownedRoot, { recursive: true });
    await writeFile(
      join(pkgRoot, "nako.toml"),
      [
        "[package]",
        'name = "esm-return-host"',
        'version = "0.1.0"',
        'license = "MIT"',
        "",
        "[profiles.compat]",
        'runtime = "lnako"',
        'os = "linux"',
        'cpu = "x86_64"',
        'abi = "gnu"',
        "compat-js = true",
        "",
        "[dependencies.path]",
        'owned = { path = "packages/owned" }',
        "",
      ].join("\n"),
    );
    await writeFile(
      join(ownedRoot, "nako.toml"),
      [
        "[package]",
        'name = "owned"',
        'version = "1.0.0"',
        'license = "MIT"',
        "",
        "[[exports]]",
        'name = "main"',
        'path = "main.nako3"',
        "",
      ].join("\n"),
    );
    await writeFile(
      join(ownedRoot, "plugin.mjs"),
      'export default { 外部倍算: { type: "func", josi: [["を"]], fn: (value) => Number(value) * 2 }, 外部命令: { type: "func", josi: [["を"]], fn: (...args) => args.length, isVariableJosi: Boolean(0) } };\n',
    );
    await writeFile(
      join(ownedRoot, "main.nako3"),
      "!「./plugin.mjs」を取り込む。\n●試験とは\n3を外部倍算で戻る。\nここまで\n●連文とは\n「x」と表示して3を外部命令で戻る。\nここまで\n",
    );
    await writeFile(join(ownedRoot, "oracle.nako3"), "!「./plugin.mjs」を取り込む。\n●試験とは\n3を外部倍算で戻る。\nここまで\n試験()を表示。\n");
    await writeFile(join(pkgRoot, "main.nako3"), "!「pkg:owned」を取り込む。\nowned__試験()を表示。\nowned__連文()を表示。\n");

    const packageOptions = { ...options, cwd: pkgRoot };
    const officialCandidate = spawnSync(process.execPath, [officialCli, join(ownedRoot, "oracle.nako3")], {
      ...options,
      cwd: ownedRoot,
    });
    const interpreterCandidate = spawnSync(
      executable,
      ["run", "main.nako3", "--compat-js", "--profile", "compat", "--offline"],
      packageOptions,
    );
    const generatedCandidate = join(pkgRoot, `native${executableSuffix}`);
    const buildCandidate = spawnSync(
      executable,
      ["build", "main.nako3", "-o", generatedCandidate, "--compat-js", "--profile", "compat", "--offline", "--backend", "aot"],
      packageOptions,
    );
    const aotCandidate = buildCandidate.status === 0 ? spawnSync(generatedCandidate, [], packageOptions) : buildCandidate;
    if (
      officialCandidate.status !== 0 ||
      officialCandidate.stdout !== "6\n" ||
      interpreterCandidate.status !== 0 ||
      interpreterCandidate.stdout !== "6\nx\n3\n" ||
      buildCandidate.status !== 0 ||
      aotCandidate.status !== 0 ||
      aotCandidate.stdout !== "6\nx\n3\n"
    ) {
      failures += 1;
      console.error(
        `ESM戻り値候補のpackage回帰差分:\nofficial=${JSON.stringify(normalize(officialCandidate), null, 2)}\n` +
          `interpreter=${JSON.stringify(normalize(interpreterCandidate), null, 2)}\n` +
          `build=${JSON.stringify(normalize(buildCandidate), null, 2)}\n` +
          `aot=${JSON.stringify(normalize(aotCandidate), null, 2)}`,
      );
    }
  }

  // 直接取り込んだ ESM plugin も、取り込み位置以降の戻り値候補を既存の
  // 動的命令call経路で実行する。package を介さない同じ構成で、公式・
  // Interpreter・既存 embedded 実行ファイルが6を返すことを固定する。
  // 直接取り込みの LLVM AOT は起点から `opcode=call` の未対応診断のまま
  // 据え置き、追加実装しない。
  {
    const directRoot = join(temporary, "esm-return-direct");
    await mkdir(directRoot, { recursive: true });
    await writeFile(
      join(directRoot, "plugin.mjs"),
      'export default { 外部倍算: { type: "func", josi: [["を"]], fn: (value) => Number(value) * 2 } };\n',
    );
    const directSource =
      "!「./plugin.mjs」を取り込む。\n●試験とは\n3を外部倍算で戻る。\nここまで\n試験()を表示。\n";
    await writeFile(join(directRoot, "main.nako3"), directSource);
    await writeFile(join(directRoot, "oracle.nako3"), directSource);

    const directOptions = { ...options, cwd: directRoot };
    const officialDirect = spawnSync(process.execPath, [officialCli, "oracle.nako3"], directOptions);
    const interpreterDirect = spawnSync(executable, ["run", "main.nako3", "--compat-js"], directOptions);
    const generatedDirect = join(directRoot, `embedded${executableSuffix}`);
    const buildDirect = spawnSync(
      executable,
      ["build", "main.nako3", "-o", generatedDirect, "--compat-js", "--backend", "embedded"],
      directOptions,
    );
    const embeddedDirect = buildDirect.status === 0 ? spawnSync(generatedDirect, [], directOptions) : buildDirect;
    const generatedDirectAot = join(directRoot, `native${executableSuffix}`);
    const buildDirectAot = spawnSync(
      executable,
      ["build", "main.nako3", "-o", generatedDirectAot, "--compat-js", "--backend", "aot", "-O0"],
      directOptions,
    );
    if (
      officialDirect.status !== 0 ||
      officialDirect.stdout !== "6\n" ||
      interpreterDirect.status !== 0 ||
      interpreterDirect.stdout !== "6\n" ||
      buildDirect.status !== 0 ||
      embeddedDirect.status !== 0 ||
      embeddedDirect.stdout !== "6\n" ||
      buildDirectAot.status === 0 ||
      !(buildDirectAot.stderr ?? "").includes("UnsupportedInstruction")
    ) {
      failures += 1;
      console.error(
        `ESM戻り値候補の直接取り込み回帰差分:\nofficial=${JSON.stringify(normalize(officialDirect), null, 2)}\n` +
          `interpreter=${JSON.stringify(normalize(interpreterDirect), null, 2)}\n` +
          `embeddedBuild=${JSON.stringify(normalize(buildDirect), null, 2)}\n` +
          `embedded=${JSON.stringify(normalize(embeddedDirect), null, 2)}\n` +
          `aotBuild=${JSON.stringify(normalize(buildDirectAot), null, 2)}`,
      );
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
