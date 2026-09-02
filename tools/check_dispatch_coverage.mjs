import { readFileSync } from "node:fs";
import { access, link, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const arguments_ = parseArguments();
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const baseline = lock.nadesiko3;
const oracleRoot = resolve(arguments_.oracle ?? process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const oracle = await readOracleIdentity(oracleRoot, baseline);
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
if (catalog.commandCount !== 527 || !Array.isArray(catalog.commands) || catalog.commands.length !== 527) {
  throw new Error("標準cnakoカタログが527 entryではありません");
}
const catalogByName = Map.groupBy(catalog.commands, (command) => command.name);
const nativeDispatchCoverageExclusions = new Map([
  ["node-native-cases.json/plugin-node-native-archive", "公式生成JavaScriptが外部7z実行ファイルを必要とするため、既存のNodeネイティブZIPスモークテストへ分離する"],
  ["native-cases.json/native-uncaught-exception", "公式生成JavaScriptが意図的な未捕捉例外で終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-width-half-uncaught-error", "公式生成JavaScriptが意図的な未捕捉例外で終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-node-line-message-discontinued", "公式生成JavaScriptが意図的な廃止命令エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-node-line-image-discontinued", "公式生成JavaScriptが意図的な廃止命令エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-dictionary-byte-buffer-enumeration", "公式生成JavaScriptがTypedArrayへの辞書キー削除で意図的なTypeErrorを返すため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-node-exit-alias", "プロセス終了命令が意図的にtrace終端前に実行を終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-node-exit-japanese-alias", "プロセス終了命令が意図的にtrace終端前に実行を終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-node-exit-code", "プロセス終了命令が意図的にtrace終端前に実行を終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-invalid-pattern-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-invalid-escape-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-invalid-hex-escape-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-incomplete-quantifier-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-js-error-text", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-property-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-v-invalid-flags-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-control-escape-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-backreference-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-decimal-backreference-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-class-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-decimal-escape-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-zero-escape-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-unicode-named-backreference-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-invalid-capture-name-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-regexp-duplicate-capture-name-error", "公式CLI・生成JavaScriptが意図的な正規表現構文エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-byte-buffer-method-calls", "公式CLI・生成JavaScriptが意図的なreceiver未束縛エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-table-numeric-sort-bigint-error", "公式CLI・生成JavaScriptが意図的なBigInt変換エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-table-numeric-sort-mixed-bigint-error", "公式CLI・生成JavaScriptが意図的なBigInt型混在エラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-table-sparse-unique", "公式CLI・生成JavaScriptが意図的な疎配列holeエラーで終了するため、成功経路のdispatch監査から除外する"],
  ["native-cases.json/native-system-table-regexp-sparse-hole", "公式CLI・生成JavaScriptが意図的な疎配列holeエラーで終了するため、成功経路のdispatch監査から除外する"],
]);
const excludedFixtures = new Map([
  ["system-runtime-cases.json/system-runtime-execution-and-debug", "公式sourceとAOT O0の実行結果が一致せず、動的実行・非同期host境界は別の未実装証拠として扱う"],
  ...nativeDispatchCoverageExclusions,
]);
const generatedRouteUnavailableFixtures = new Map([
  ["standard-plugin-cases.json/plugin-toml-all", "公式生成JavaScriptのstandalone plugin host登録が不足する"],
  ["supplemental-plugin-cases.json/plugin-markup-all", "公式生成JavaScriptのstandalone plugin host登録が不足する"],
  ["supplemental-plugin-cases.json/plugin-kansuji-all", "公式生成JavaScriptのstandalone plugin host登録が不足する"],
  ["supplemental-plugin-cases.json/plugin-caniuse-all", "公式生成JavaScriptのstandalone plugin host登録が不足する"],
  ["system-runtime-cases.json/system-runtime-execution-and-debug", "公式生成JavaScriptのstandalone system async host登録が不足する"],
  ["native-cases.json/native-caniuse-browsers", "公式生成JavaScriptのstandalone caniuse plugin host登録が不足する"],
  ["native-cases.json/native-caniuse-agents", "公式生成JavaScriptのstandalone caniuse plugin host登録が不足する"],
  ["native-cases.json/native-kansuji-commands", "公式生成JavaScriptのstandalone kansuji plugin host登録が不足する"],
  ["native-cases.json/native-kansuji-aot-generated-boundaries", "公式生成JavaScriptのstandalone kansuji plugin host登録が不足する"],
  ["native-cases.json/native-csv-commands", "公式生成JavaScriptのstandalone CSV plugin host登録が不足する"],
  ["native-cases.json/native-toml-commands", "公式生成JavaScriptのstandalone TOML plugin host登録が不足する"],
  ["native-cases.json/native-markup-commands", "公式生成JavaScriptのstandalone markup plugin host登録が不足する"],
  ["native-cases.json/native-system-dynamic-execution", "公式生成JavaScriptのstandalone system async host登録が不足する"],
]);
const selectedFixtures = await loadSelectedFixtures();
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const normalizedDebugHost = resolve(root, "tools/oracle/normalize_debug_host.mjs");
const safeExternalHost = resolve(root, "tools/oracle/safe_external_host.mjs");
const maxBuffer = 32 * 1024 * 1024;
const throwStatementOpcode = 0xffff;
const archiveHelperName = "lnako-archive-7z-helper";
const fixtureStateMutationCommands = new Set([
  "保存",
  "SJISファイル保存",
  "EUCファイル保存",
  "ファイルコピー",
  "ファイル上書コピー",
  "ファイル移動",
  "ファイル上書移動",
  "ファイル削除",
  "フォルダ作成",
  "一時フォルダ作成",
  "圧縮",
  "解凍",
  "ファイル処理時",
  "ファイル処理強制停止",
]);

if (arguments_.output !== null) await assertOutputDoesNotExist(arguments_.output);
if (!arguments_.noBuild) buildCompiler();
await access(compiler);

// cnako3 v3.7.24 recognizes a Windows drive-letter path as a full path only
// when the separator after the drive is a backslash. The plugin resolver
// therefore treats a `D:/...` path as relative. Keep the scratch tree on the
// repository drive, which is also the default oracle drive in CI, so relative
// plugin paths remain valid on Windows.
const auditGitState = gitState();
const temporary = await mkdtemp(join(root, ".tmp-lnako-dispatch-coverage-"));
try {
  const fixtureReports = [];
  const sites = [];
  const unresolvedSites = [];
  for (const [index, fixture] of selectedFixtures.entries()) {
    const result = await runFixture(fixture, index, temporary);
    fixtureReports.push(result.report);
    sites.push(...result.sites);
    unresolvedSites.push(...result.unresolvedSites);
  }

  const report = createReport({ fixtureReports, sites, unresolvedSites, oracle, git: auditGitState });
  if (arguments_.output !== null) await writeExclusive(arguments_.output, `${JSON.stringify(report, null, 2)}\n`);
  const nativeCoverage = report.coverage.unambiguousObservedNativeEntries;
  const nativeNames = report.coverage.unambiguousObservedNativeUniqueNames;
  console.log(
    `AOT dispatch coverage audit: ${fixtureReports.length} fixtures / ${sites.length} unambiguous sites / ` +
      `${nativeCoverage}/523 native entries・${nativeNames}/492 unique names (unattested sampled coverage)`,
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function parseArguments() {
  let noBuild = false;
  let includeNative = false;
  let output = null;
  let oracle = null;
  for (let index = 0; index < process.argv.length - 2; index += 1) {
    const argument = process.argv[index + 2];
    if (argument === "--no-build") {
      if (noBuild) throw new Error("--no-buildは1回だけ指定してください");
      noBuild = true;
    } else if (argument === "--include-native") {
      if (includeNative) throw new Error("--include-nativeは1回だけ指定してください");
      includeNative = true;
    } else if (argument === "--output") {
      if (output !== null) throw new Error("--outputは1回だけ指定してください");
      output = process.argv[++index + 2] ?? null;
      if (output === null || !isAbsolute(output)) throw new Error("--outputには絶対パスを指定してください");
    } else if (argument === "--oracle") {
      if (oracle !== null) throw new Error("--oracleは1回だけ指定してください");
      oracle = process.argv[++index + 2] ?? null;
      if (oracle === null || !isAbsolute(oracle)) throw new Error("--oracleには絶対パスを指定してください");
    } else {
      throw new Error("usage: node tools/check_dispatch_coverage.mjs [--no-build] [--include-native] [--output /absolute/path] [--oracle /absolute/path]");
    }
  }
  return { noBuild, includeNative, output, oracle };
}

async function loadSelectedFixtures() {
  const specifications = [
    { file: "plugin-system-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "system-runtime-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "standard-plugin-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "supplemental-plugin-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "node-file-cases.json", selection: (testCase) => testCase.aot === true && testCase.commands?.length > 0 && testCase.expectError !== true },
    { file: "node-native-cases.json", selection: (testCase) => testCase.aot === true && testCase.commands?.length > 0 && testCase.expectError !== true },
    { file: "native-cases.json", selection: (testCase) =>
      testCase.id === "native-cut-commands" || testCase.id === "native-system-error-raise" || testCase.id === "native-system-debug" || testCase.id === "native-system-dynamic-execution" },
  ];
  if (arguments_.includeNative) {
    specifications.push({
      file: "native-cases.json",
      selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true && testCase.id !== "native-cut-commands",
    });
  }
  const fixtures = [];
  for (const specification of specifications) {
    const path = resolve(root, "tests/oracle", specification.file);
    const cases = JSON.parse(await readFile(path, "utf8"));
    if (!Array.isArray(cases)) throw new Error(`fixtureが配列ではありません: ${specification.file}`);
    for (const testCase of cases.filter(specification.selection)) {
      validateFixture(testCase, specification.file);
      if (excludedFixtures.has(`${specification.file}/${testCase.id}`)) continue;
      fixtures.push({ file: specification.file, ...testCase });
    }
  }
  const expectedFixtureCount = arguments_.includeNative ? 202 : 35;
  if (fixtures.length !== expectedFixtureCount) throw new Error(`dispatch coverageのfixture数が想定外です: ${fixtures.length}`);
  return fixtures;
}

function validateFixture(testCase, file) {
  if (typeof testCase.id !== "string" || testCase.id.length === 0 || typeof testCase.source !== "string") {
    throw new Error(`fixtureのid/sourceが不正です: ${file}`);
  }
  if (!Array.isArray(testCase.commands) || testCase.commands.length === 0 ||
      testCase.commands.some((name) => typeof name !== "string" || name.length === 0 || !catalogByName.has(name)) ||
      new Set(testCase.commands).size !== testCase.commands.length) {
    throw new Error(`fixtureのcommandsが標準527命令と一致しません: ${file}/${testCase.id}`);
  }
  if (testCase.sourceFileName !== undefined &&
      (typeof testCase.sourceFileName !== "string" || testCase.sourceFileName.length === 0 || isAbsolute(testCase.sourceFileName) ||
        testCase.sourceFileName.includes("/") || testCase.sourceFileName.includes("\\") || testCase.sourceFileName === "." || testCase.sourceFileName === "..")) {
    throw new Error(`fixtureのsourceFileNameが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.stdin !== undefined && typeof testCase.stdin !== "string") throw new Error(`fixtureのstdinが不正です: ${file}/${testCase.id}`);
  if (testCase.safeExternalMock !== undefined && typeof testCase.safeExternalMock !== "boolean") {
    throw new Error(`fixtureのsafeExternalMockが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.archiveHelper !== undefined && typeof testCase.archiveHelper !== "boolean") {
    throw new Error(`fixtureのarchiveHelperが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.dispatchExpectations !== undefined) {
    if (!Array.isArray(testCase.dispatchExpectations) || testCase.dispatchExpectations.length === 0) {
      throw new Error(`fixtureのdispatchExpectationsが不正です: ${file}/${testCase.id}`);
    }
    const expectedCommands = new Set();
    for (const expectation of testCase.dispatchExpectations) {
      if (expectation === null || typeof expectation !== "object" || Array.isArray(expectation) ||
          Object.keys(expectation).some((key) => !new Set(["command", "result", "count", "platforms"]).has(key)) ||
          typeof expectation.command !== "string" || !testCase.commands.includes(expectation.command) ||
          expectedCommands.has(expectation.command) || expectation.result !== "failure" ||
          !Number.isSafeInteger(expectation.count) || expectation.count < 1 || !validDispatchExpectationPlatforms(expectation.platforms)) {
        throw new Error(`fixtureのdispatchExpectationsが不正です: ${file}/${testCase.id}`);
      }
      expectedCommands.add(expectation.command);
    }
  }
  if (testCase.files !== undefined) {
    if (testCase.files === null || typeof testCase.files !== "object" || Array.isArray(testCase.files)) {
      throw new Error(`fixtureのfilesが不正です: ${file}/${testCase.id}`);
    }
    for (const [name, contents] of Object.entries(testCase.files)) {
      if (name.length === 0 || name === "." || name === ".." || name.includes("/") || name.includes("\\") ||
          typeof contents !== "string") {
        throw new Error(`fixtureのfilesが不正です: ${file}/${testCase.id}/${name}`);
      }
    }
  }
}

async function runFixture(fixture, index, temporary) {
  const fixtureDirectory = resolve(temporary, `${String(index).padStart(2, "0")}-${fixture.id}`);
  await mkdir(fixtureDirectory);
  const stem = `${String(index).padStart(2, "0")}-${fixture.id}`;
  const isolated = requiresIsolatedFixtureState(fixture);
  const routeDirectory = (name) => isolated ? resolve(fixtureDirectory, name) : fixtureDirectory;
  const officialSourceDirectory = routeDirectory("official-source");
  const officialGeneratedDirectory = routeDirectory("official-generated");
  const interpreterTraceDirectory = routeDirectory("interpreter-trace");
  const interpreterNoTraceDirectory = routeDirectory("interpreter-no-trace");
  const aotTraceDirectory = routeDirectory("aot-trace");
  const aotNoTraceDirectory = routeDirectory("aot-no-trace");
  const routeDirectories = [
    officialSourceDirectory,
    officialGeneratedDirectory,
    interpreterTraceDirectory,
    interpreterNoTraceDirectory,
    aotTraceDirectory,
    aotNoTraceDirectory,
  ];
  await Promise.all([...new Set(routeDirectories)].map((directory) => mkdir(directory, { recursive: true })));
  const sourceName = fixture.sourceFileName ?? `${stem}.nako3`;
  const officialSourcePath = resolve(officialSourceDirectory, sourceName);
  const officialGeneratedSourcePath = resolve(officialGeneratedDirectory, sourceName);
  const interpreterTraceSourcePath = resolve(interpreterTraceDirectory, sourceName);
  const interpreterNoTraceSourcePath = resolve(interpreterNoTraceDirectory, sourceName);
  const aotSourcePath = resolve(aotTraceDirectory, sourceName);
  const generatedPath = resolve(officialGeneratedDirectory, `${stem}.mjs`);
  const nativePath = resolve(aotTraceDirectory, `${stem}${process.platform === "win32" ? ".exe" : ""}`);
  const interpreterTracePath = resolve(interpreterTraceDirectory, "interpreter.jsonl");
  const aotTracePath = resolve(aotTraceDirectory, "aot.jsonl");
  const manifestPath = resolve(aotTraceDirectory, "compile-manifest.jsonl");
  const sourceSha256 = sha256(fixture.source);
  await Promise.all([...new Set(routeDirectories)].map(async (directory) => {
    const source = replacePluginPlaceholders(fixture.source, directory);
    for (const [name, contents] of Object.entries(fixture.files ?? {})) await writeFile(resolve(directory, name), contents, "utf8");
    await writeFile(resolve(directory, sourceName), source, "utf8");
  }));

  const baseEnvironment = fixedEnvironment();
  const lnakoEnvironment = {
    ...baseEnvironment,
    ...(fixture.safeExternalMock ? { LNAKO_TEST_OPEN_EXTERNAL: "mock" } : {}),
    ...(fixture.archiveHelper ? { LNAKO_TEST_ARCHIVE_HELPER: archiveHelperName } : {}),
  };
  const runOptions = fixture.stdin === undefined ? {} : { input: fixture.stdin };
  const oracleUsesSafeExternalHost = fixture.safeExternalMock === true || fixture.archiveHelper === true;
  const oracleHostArguments = oracleUsesSafeExternalHost
    ? ["--import", pathToFileURL(fixedHost).href, "--import", pathToFileURL(safeExternalHost).href]
    : ["--import", pathToFileURL(fixture.normalizeDebugDump === true ? normalizedDebugHost : fixedHost).href];
  const officialSource = run(process.execPath, [...oracleHostArguments, resolve(oracleRoot, "src/cnako3.mjs"), officialSourcePath], baseEnvironment, officialSourceDirectory, runOptions);
  assertSuccess(`${fixture.file}/${fixture.id} 公式source`, officialSource);
  const officialCompile = run(
    process.execPath,
    [...oracleHostArguments, resolve(oracleRoot, "src/cnako3.mjs"), "--compile", "--silent", "--output", generatedPath, officialGeneratedSourcePath],
    baseEnvironment,
    officialGeneratedDirectory,
  );
  assertSuccess(`${fixture.file}/${fixture.id} 公式JavaScript生成`, officialCompile);
  const officialGenerated = run(process.execPath, [...oracleHostArguments, generatedPath], baseEnvironment, officialGeneratedDirectory, runOptions);
  const generatedRouteUnavailable = isKnownGeneratedRouteUnavailable(fixture);
  if (generatedRouteUnavailable && officialGenerated.status !== 0 && officialGenerated.status !== 1) {
    throw new Error(`${fixture.file}/${fixture.id} 公式生成JavaScriptの既知gapと異なる終了状態です: ${officialGenerated.status}`);
  }
  if (!generatedRouteUnavailable) assertSuccess(`${fixture.file}/${fixture.id} 公式生成JavaScript`, officialGenerated);

  const interpreter = run(compiler, ["run", interpreterTraceSourcePath], { ...lnakoEnvironment, LNAKO_DISPATCH_TRACE: interpreterTracePath }, interpreterTraceDirectory, runOptions);
  assertSuccess(`${fixture.file}/${fixture.id} Interpreter`, interpreter);
  const interpreterWithoutTrace = run(compiler, ["run", interpreterNoTraceSourcePath], lnakoEnvironment, interpreterNoTraceDirectory, runOptions);
  assertSuccess(`${fixture.file}/${fixture.id} Interpreter trace無効`, interpreterWithoutTrace);
  assertEquivalent(`${fixture.file}/${fixture.id} Interpreter trace`, interpreterWithoutTrace, interpreter);
  const interpreterTrace = await readInterpreterTrace(interpreterTracePath, fixture);

  const compile = run(
    compiler,
    ["build", aotSourcePath, "-o", nativePath, "-O0"],
    { ...lnakoEnvironment, LNAKO_COMPILE_MANIFEST: manifestPath },
    aotTraceDirectory,
  );
  assertSuccess(`${fixture.file}/${fixture.id} AOT O0コンパイル`, compile);
  const manifest = await readCompileManifest(manifestPath, aotSourcePath, fixture);
  const aot = run(nativePath, [], { ...lnakoEnvironment, LNAKO_DISPATCH_TRACE: aotTracePath }, aotTraceDirectory, runOptions);
  assertSuccess(`${fixture.file}/${fixture.id} AOT O0`, aot);
  const aotWithoutTrace = run(nativePath, [], lnakoEnvironment, aotNoTraceDirectory, runOptions);
  assertSuccess(`${fixture.file}/${fixture.id} AOT O0 trace無効`, aotWithoutTrace);
  assertEquivalent(`${fixture.file}/${fixture.id} AOT trace`, aotWithoutTrace, aot);
  const aotTrace = await readAotTrace(aotTracePath, fixture, manifest.entries);
  const coverage = collectSites(fixture, interpreterTrace.events, aotTrace, manifest.entries);

  const oracleRoute = fixture.oracle === "official-generated" ? "officialGenerated" : "officialSource";
  const oracleResult = oracleRoute === "officialGenerated" ? officialGenerated : officialSource;
  const officialRoutesEquivalent = JSON.stringify(normalizeProcess(officialSource)) === JSON.stringify(normalizeProcess(officialGenerated));
  assertOfficialEquivalent(`${fixture.file}/${fixture.id} ${oracleRoute}/Interpreter`, oracleResult, interpreterWithoutTrace);
  assertOfficialEquivalent(`${fixture.file}/${fixture.id} ${oracleRoute}/AOT O0`, oracleResult, aotWithoutTrace);

  const observedCommandNames = new Set(coverage.observedCommandNames);
  const associationWithoutDispatch = fixture.commands
    .filter((name) => !observedCommandNames.has(name))
    .map((name) => ({ name, catalogIds: (catalogByName.get(name) ?? []).map((command) => command.id) }));
  return {
    report: {
      id: fixture.id,
      file: fixture.file,
      sourceSha256,
      associatedCommandNames: [...fixture.commands],
      associationWithoutDispatch,
      observedStaticCommandNames: [...coverage.staticSuccessNames].sort(),
      observedDispatchCommandNames: [...coverage.observedCommandNames].sort(),
      dispatchExpectations: fixture.dispatchExpectations ?? [],
      officialComparison: {
        oracle: oracleRoute,
        routes: ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"],
        selectedOracleEquivalent: true,
        officialGeneratedAvailable: officialGenerated.status === 0,
        officialGeneratedRouteUnavailableReason: generatedRouteUnavailable && officialGenerated.status !== 0
          ? generatedRouteUnavailableFixtures.get(`${fixture.file}/${fixture.id}`)
          : null,
        officialRoutesEquivalent,
        results: Object.fromEntries([
          ["officialSource", summarizeProcess(officialSource)],
          ["officialGenerated", summarizeProcess(officialGenerated)],
          ["lnakoRun", summarizeProcess(interpreterWithoutTrace)],
          ["lnakoNativeO0", summarizeProcess(aotWithoutTrace)],
        ]),
      },
      interpreter: {
        dispatchEventCount: interpreterTrace.events.length,
        staticSuccessSiteCount: coverage.staticSuccessSiteCount,
        expectedFailureSiteCount: coverage.expectedFailureSiteCount,
        expectedFailureDispatchCount: coverage.expectedFailureDispatchCount,
        staticSiteWithoutAotManifestCount: coverage.interpreterSitesWithoutManifest.length,
        traceSha256: interpreterTrace.rawSha256,
      },
      aot: {
        manifestEntryCount: manifest.entries.length,
        dispatchAttemptCount: aotTrace.attempts.length,
        dispatchResultCount: aotTrace.results.length,
        staticSuccessSiteCount: coverage.staticSuccessSiteCount,
        expectedFailureSiteCount: coverage.expectedFailureSiteCount,
        expectedFailureDispatchCount: coverage.expectedFailureDispatchCount,
        failedDispatchCount: aotTrace.results.filter((event) => event.success === false).length,
        traceSha256: aotTrace.rawSha256,
        compileManifestSha256: manifest.rawSha256,
      },
    },
    sites: coverage.sites,
    unresolvedSites: coverage.unresolvedSites,
  };
}

function requiresIsolatedFixtureState(fixture) {
  // Path-observing fixtures must see the same cwd and source path on every
  // route. Only fixtures that create or mutate shared files need per-route
  // directories; each process already has isolated process-local state.
  if (Object.keys(fixture.files ?? {}).length > 0) return true;
  return fixture.commands.some((name) => fixtureStateMutationCommands.has(name));
}

function isKnownGeneratedRouteUnavailable(fixture) {
  // Some fixtures use official plugin modules or the system async host. The
  // standalone generated file does not always carry the CLI's host/plugin
  // registration, so an execution failure on these explicit route families
  // is reported as unavailable. The official source CLI remains the oracle;
  // this must never be mistaken for generated-JavaScript coverage.
  return generatedRouteUnavailableFixtures.has(`${fixture.file}/${fixture.id}`);
}

function fixedEnvironment() {
  const environment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    LNAKO_TEST_NOW_MS: "1735689845678",
    LNAKO_TEST_MONOTONIC_MS: "123.5",
    LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
    LNAKO_NODE_TEST: "fixed-value",
    NAKO3_DISABLE_NEW_CONSOLE: "1",
  };
  const nodeDirectory = dirname(process.execPath);
  const pathSeparator = process.platform === "win32" ? ";" : ":";
  if (process.platform === "win32") {
    // Windows runners commonly expose the search path as `Path`, not `PATH`.
    // Preserve that key so System32 remains available for cmd.exe and other
    // host commands used by the Node process fixtures.
    environment.Path = `${nodeDirectory}${pathSeparator}${environment.Path ?? environment.PATH ?? ""}`;
    delete environment.PATH;
  } else {
    environment.PATH = `${nodeDirectory}${pathSeparator}${environment.PATH ?? ""}`;
  }
  delete environment.LNAKO_DISPATCH_TRACE;
  delete environment.LNAKO_COMPILE_MANIFEST;
  return environment;
}

function replacePluginPlaceholders(source, fixtureDirectory) {
  const replacements = {
    "${PLUGIN_CANIUSE}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_caniuse.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_KANSUJI}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_kansuji.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_MARKUP}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_markup.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_CSV}": relative(fixtureDirectory, resolve(oracleRoot, "core/src/plugin_csv.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_TOML}": relative(fixtureDirectory, resolve(oracleRoot, "core/src/plugin_toml.mjs")).replaceAll("\\", "/"),
  };
  return Object.entries(replacements).reduce((result, [placeholder, path]) => result.replaceAll(placeholder, path), source);
}

function run(command, arguments_, environment, cwd, extraOptions = {}) {
  const result = spawnSync(command, arguments_, {
    cwd,
    env: environment,
    encoding: "utf8",
    maxBuffer,
    input: extraOptions.input,
    windowsHide: true,
  });
  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? (result.error?.message ?? ""),
  };
}

function buildCompiler() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    encoding: "utf8",
    maxBuffer,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました: ${result.stderr ?? result.error?.message ?? "unknown"}`);
}

function assertSuccess(label, result) {
  if (result.status !== 0) {
    const detail = result.stderr.length > 0 ? `: ${result.stderr.slice(-2000)}` : "";
    throw new Error(`${label}に失敗しました (status=${result.status}, signal=${result.signal})${detail}`);
  }
}

function assertEquivalent(label, left, right) {
  const leftNormalized = normalizeProcess(left);
  const rightNormalized = normalizeProcess(right);
  if (JSON.stringify(leftNormalized) !== JSON.stringify(rightNormalized)) {
    throw new Error(`${label}でtrace有無の結果が変化しました`);
  }
}

function assertOfficialEquivalent(label, left, right) {
  const leftNormalized = normalizeProcess(left);
  const rightNormalized = normalizeProcess(right);
  if (JSON.stringify(leftNormalized) !== JSON.stringify(rightNormalized)) {
    throw new Error(
      `${label}で公式・lnakoの結果が一致しません: official=${JSON.stringify(leftNormalized)} lnako=${JSON.stringify(rightNormalized)}`,
    );
  }
}

function normalizeProcess(result) {
  return {
    stdout: normalizeLineEndings(result.stdout),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}

function summarizeProcess(result) {
  return {
    status: result.status,
    signal: result.signal,
    stdoutSha256: sha256(normalizeLineEndings(result.stdout)),
    stderrSha256: sha256(normalizeLineEndings(result.stderr)),
  };
}

function readJsonLines(text, label) {
  if (!text.endsWith("\n")) throw new Error(`${label}が改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${label} ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error(`${label}にdispatchと終端イベントがありません`);
  for (const [index, record] of records.entries()) {
    if (record.schema !== 2 || record.seq !== index) throw new Error(`${label} metadataが不正です: ${JSON.stringify(record)}`);
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(record, forbidden)) throw new Error(`${label}に禁止fieldがあります: ${forbidden}`);
    }
  }
  const end = records.at(-1);
  if (end.phase !== "trace-end" || end.dropped !== 0) throw new Error(`${label}が正常に完結していません`);
  return { records, rawSha256: sha256(text) };
}

async function readInterpreterTrace(path, fixture) {
  const parsed = readJsonLines(await readFile(path, "utf8"), `${fixture.id} Interpreter trace`);
  if (parsed.records.some((event) => event.engine !== "interpreter")) throw new Error(`${fixture.id} Interpreter traceのengineが不正です`);
  const events = parsed.records.slice(0, -1);
  if (events.some((event) => event.phase !== "dispatch-result" || typeof event.command !== "string" || typeof event.route !== "string" ||
      (event.result !== "success" && event.result !== "failure"))) {
    throw new Error(`${fixture.id} Interpreter traceのdispatch metadataが不正です`);
  }
  for (const event of events) assertSiteId(event.siteId, `${fixture.id} Interpreter trace`);
  if (events.length === 0) throw new Error(`${fixture.id} Interpreter traceにdispatchがありません`);
  return { events, rawSha256: parsed.rawSha256 };
}

async function readAotTrace(path, fixture, manifestEntries) {
  const parsed = readJsonLines(await readFile(path, "utf8"), `${fixture.id} AOT trace`);
  if (parsed.records.some((event) => event.engine !== "aot")) throw new Error(`${fixture.id} AOT traceのengineが不正です`);
  const events = parsed.records.slice(0, -1);
  const attempts = events.filter((event) => event.phase === "dispatch-attempt");
  const results = events.filter((event) => event.phase === "dispatch-result");
  if (attempts.length === 0 || attempts.length !== results.length) throw new Error(`${fixture.id} AOT traceのattempt/result件数が不一致です`);
  const manifestBySite = new Map(manifestEntries.map((entry) => [entry.siteId, entry]));
  const attemptsByCall = new Map();
  for (const attempt of attempts) {
    assertAotEvent(attempt, `${fixture.id} AOT attempt`, true);
    if (attempt.callId === null || !Number.isSafeInteger(attempt.callId) || attemptsByCall.has(attempt.callId)) {
      throw new Error(`${fixture.id} AOT attemptのcallIdが不正です`);
    }
    if (attempt.siteId !== null) {
      const manifest = manifestBySite.get(attempt.siteId);
      if (manifest === undefined || manifest.canonicalOpcode !== attempt.command || manifest.route !== attempt.route || manifest.opcode !== attempt.opcode) {
        throw new Error(`${fixture.id} AOT traceとmanifestのdispatchが一致しません: ${JSON.stringify({ attempt, manifest })}`);
      }
    }
    attemptsByCall.set(attempt.callId, attempt);
  }
  const resultsByCall = new Map();
  for (const result of results) {
    assertAotEvent(result, `${fixture.id} AOT result`, false);
    if (!Number.isSafeInteger(result.callId) || resultsByCall.has(result.callId) || typeof result.success !== "boolean") {
      throw new Error(`${fixture.id} AOT resultのcallId/successが不正です`);
    }
    const attempt = attemptsByCall.get(result.callId);
    if (attempt === undefined || result.siteId !== attempt.siteId || result.opcode !== attempt.opcode || result.command !== attempt.command || result.route !== attempt.route) {
      throw new Error(`${fixture.id} AOT traceのattempt/result対応が不正です`);
    }
    resultsByCall.set(result.callId, result);
  }
  if (resultsByCall.size !== attemptsByCall.size) throw new Error(`${fixture.id} AOT traceに対応しないattemptがあります`);
  const interpreterSiteIds = new Set();
  return { events, attempts, results, attemptsByCall, resultsByCall, manifestBySite, rawSha256: parsed.rawSha256, interpreterSiteIds };
}

function assertAotEvent(event, label, requireNameSource) {
  if (event.engine !== "aot" || (event.phase !== "dispatch-attempt" && event.phase !== "dispatch-result") ||
      !Number.isInteger(event.opcode) || event.opcode < 0 || event.opcode > 0xffff || typeof event.command !== "string" ||
      typeof event.route !== "string" || (requireNameSource && event.name_source !== "canonical-opcode")) {
    throw new Error(`${label}のdispatch metadataが不正です`);
  }
  assertSiteId(event.siteId, label);
}

function assertSiteId(siteId, label) {
  if (siteId !== null && (typeof siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(siteId))) throw new Error(`${label}のsiteIdが不正です`);
}

async function readCompileManifest(path, sourcePath, fixture) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error(`${fixture.id} AOT compile manifestが改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${fixture.id} AOT compile manifest ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error(`${fixture.id} AOT compile manifestにheaderと完了recordがありません`);
  for (const record of records) {
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(record, forbidden)) throw new Error(`${fixture.id} AOT compile manifestに禁止fieldがあります: ${forbidden}`);
    }
  }
  const parsed = { records, rawSha256: sha256(text) };
  const header = parsed.records[0];
  const complete = parsed.records.at(-1);
  const entries = parsed.records.slice(1, -1);
  const schema = "lnako.aot.builtin-manifest.v1";
  if (header.schema !== schema || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16" ||
      complete.schema !== schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== entries.length) {
    throw new Error(`${fixture.id} AOT compile manifest header/completeが不正です`);
  }
  const siteIds = new Set();
  const activeExpectations = activeDispatchExpectations(fixture);
  const expectedFailureCommands = new Set(activeExpectations.map((expectation) => expectation.command));
  for (const entry of entries) {
    const isBuiltinDispatch = entry.kind === "builtin-dispatch";
    const isThrowDispatch = entry.kind === "throw-dispatch" && entry.sourceName === "エラー発生" &&
      entry.canonicalOpcode === "throw_statement" && entry.route === "throw" && entry.opcode === throwStatementOpcode &&
      expectedFailureCommands.has(entry.sourceName);
    if (entry.schema !== schema || entry.phase !== "pre-opt" || (!isBuiltinDispatch && !isThrowDispatch) ||
        ![entry.sourceName, entry.canonicalOpcode, entry.route, entry.function].every((value) => typeof value === "string" && value.length > 0) ||
        !Number.isInteger(entry.opcode) || entry.opcode < 0 || entry.opcode > 0xffff || typeof entry.siteId !== "string" ||
        !/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) {
      throw new Error(`${fixture.id} AOT compile manifest entryが不正です`);
    }
    if (entry.source === null || !Number.isInteger(entry.source.line) || entry.source.line < 1 || !Number.isInteger(entry.source.column) || entry.source.column < 1 ||
        !Number.isInteger(entry.source.sourceStart) || !Number.isInteger(entry.source.sourceEnd) || entry.source.sourceStart < 0 || entry.source.sourceEnd < entry.source.sourceStart) {
      throw new Error(`${fixture.id} AOT compile manifestのsource位置が不正です`);
    }
    siteIds.add(entry.siteId);
  }
  return { entries, rawSha256: parsed.rawSha256 };
}

function collectSites(fixture, interpreterEvents, aotTrace, manifestEntries) {
  const manifestSiteIds = new Set(manifestEntries.map((entry) => entry.siteId));
  const staticInterpreterEvents = interpreterEvents.filter((event) => event.siteId !== null);
  const interpreterSitesWithoutManifest = staticInterpreterEvents
    .filter((event) => !manifestSiteIds.has(event.siteId))
    .map((event) => ({ siteId: event.siteId, command: event.command, route: event.route, result: event.result }));
  const sites = [];
  const unresolvedSites = [];
  const staticSuccessNames = new Set();
  const observedCommandNames = new Set();
  const expectedFailureByCommand = new Map(activeDispatchExpectations(fixture).map((expectation) => [expectation.command, expectation]));
  const expectedFailureCounts = new Map();
  let staticSuccessSiteCount = 0;
  let expectedFailureSiteCount = 0;
  let expectedFailureDispatchCount = 0;
  for (const entry of manifestEntries) {
    const expectedFailure = expectedFailureByCommand.get(entry.sourceName);
    if ((entry.kind === "throw-dispatch" && expectedFailure === undefined) ||
        (expectedFailure !== undefined && entry.kind !== "builtin-dispatch" && entry.kind !== "throw-dispatch")) {
      throw new Error(`${fixture.id} 期待失敗dispatchの宣言が不一致です: ${entry.sourceName}/${entry.siteId}`);
    }
    if (expectedFailure !== undefined) {
      const failedAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === false);
      const successfulAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === true);
      const failedInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "failure");
      const successfulInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "success");
      if (successfulAot.length > 0 || successfulInterpreter.length > 0) {
        throw new Error(`${fixture.id} 明示した期待失敗siteに成功dispatchがあります: ${entry.sourceName}/${entry.siteId}`);
      }
      if (failedAot.length === 0 || failedInterpreter.length === 0 || failedAot.length !== failedInterpreter.length) {
        throw new Error(`${fixture.id} 明示した期待失敗siteのInterpreter/AOT件数が一致しません: ${entry.sourceName}/${entry.siteId}`);
      }
      expectedFailureSiteCount += 1;
      expectedFailureDispatchCount += failedAot.length;
      expectedFailureCounts.set(entry.sourceName, (expectedFailureCounts.get(entry.sourceName) ?? 0) + failedAot.length);
      observedCommandNames.add(entry.sourceName);
      const routes = [...new Set(failedInterpreter.map((event) => event.route))].sort();
      const common = {
        fixtureId: fixture.id,
        file: fixture.file,
        siteId: entry.siteId,
        sourceName: entry.sourceName,
        canonicalOpcode: entry.canonicalOpcode,
        opcode: entry.opcode,
        route: entry.route,
        runtimeRoutes: [...new Set(failedAot.map((event) => event.route))].sort(),
        interpreterRoutes: routes,
        interpreterCount: failedInterpreter.length,
        aotCount: failedAot.length,
        result: "failure",
      };
      const resolution = resolveCatalogCommand(entry.sourceName, entry.route);
      if (resolution === null) {
        unresolvedSites.push({ ...common, candidateCatalogIds: (catalogByName.get(entry.sourceName) ?? []).map((command) => command.id) });
        continue;
      }
      sites.push({
        ...common,
        catalogId: resolution.command.id,
        name: resolution.command.name,
        plugin: resolution.command.plugin,
        catalogStatus: resolution.command.status,
        resolution: resolution.reason,
        selectedOracleEquivalent: true,
      });
      continue;
    }
    const successfulAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === true);
    if (successfulAot.length === 0) continue;
    const successfulInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "success");
    if (successfulInterpreter.length === 0) throw new Error(`${fixture.id} AOT成功siteに対応するInterpreter成功eventがありません`);
    staticSuccessSiteCount += 1;
    staticSuccessNames.add(entry.sourceName);
    observedCommandNames.add(entry.sourceName);
    const routes = [...new Set(successfulInterpreter.map((event) => event.route))].sort();
    const resolution = resolveCatalogCommand(entry.sourceName, entry.route);
    const common = {
      fixtureId: fixture.id,
      file: fixture.file,
      siteId: entry.siteId,
      sourceName: entry.sourceName,
      canonicalOpcode: entry.canonicalOpcode,
      opcode: entry.opcode,
      route: entry.route,
      runtimeRoutes: [...new Set(successfulAot.map((event) => event.route))].sort(),
      interpreterRoutes: routes,
      interpreterCount: successfulInterpreter.length,
      aotCount: successfulAot.length,
      result: "success",
    };
    if (resolution === null) {
      unresolvedSites.push({ ...common, candidateCatalogIds: (catalogByName.get(entry.sourceName) ?? []).map((command) => command.id) });
      continue;
    }
    sites.push({
      ...common,
      catalogId: resolution.command.id,
      name: resolution.command.name,
      plugin: resolution.command.plugin,
      catalogStatus: resolution.command.status,
      resolution: resolution.reason,
      selectedOracleEquivalent: true,
    });
  }
  for (const expectation of activeDispatchExpectations(fixture)) {
    const observedCount = expectedFailureCounts.get(expectation.command) ?? 0;
    if (observedCount !== expectation.count) {
      throw new Error(`${fixture.id} 明示した期待失敗dispatch件数が一致しません: ${expectation.command} expected=${expectation.count} actual=${observedCount}`);
    }
  }
  return {
    sites,
    unresolvedSites,
    staticSuccessNames,
    observedCommandNames,
    staticSuccessSiteCount,
    expectedFailureSiteCount,
    expectedFailureDispatchCount,
    interpreterSitesWithoutManifest,
  };
}

function activeDispatchExpectations(fixture, platform = process.platform) {
  return (fixture.dispatchExpectations ?? []).filter((expectation) =>
    expectation.platforms === undefined || expectation.platforms.includes(platform));
}

function validDispatchExpectationPlatforms(platforms) {
  return platforms === undefined ||
    (Array.isArray(platforms) && platforms.length > 0 && new Set(platforms).size === platforms.length &&
      platforms.every((platform) => ["darwin", "linux", "win32"].includes(platform)));
}

function resolveCatalogCommand(name, route) {
  const candidates = catalogByName.get(name) ?? [];
  if (candidates.length === 1) return { command: candidates[0], reason: "unique-name" };
  const routeCandidates = candidates.filter((command) => command.plugin === route);
  if (routeCandidates.length === 1) return { command: routeCandidates[0], reason: "plugin-route" };
  return null;
}

function createReport({ fixtureReports, sites, unresolvedSites, oracle, git }) {
  const nativeCommands = catalog.commands.filter((command) => command.status === "native");
  const nativeIds = new Set(nativeCommands.map((command) => command.id));
  const nativeNames = new Set(nativeCommands.map((command) => command.name));
  const observedNativeSites = sites.filter((site) => nativeIds.has(site.catalogId));
  const observedNativeIds = new Set(observedNativeSites.map((site) => site.catalogId));
  const observedNativeNames = new Set(observedNativeSites.map((site) => site.name));
  const unresolvedByName = Map.groupBy(unresolvedSites, (site) => site.sourceName);
  const associationWithoutDispatch = fixtureReports.flatMap((fixture) => fixture.associationWithoutDispatch.map((association) => ({ fixtureId: fixture.id, file: fixture.file, ...association })));
  return {
    schema: "lnako.dispatch-coverage.v1",
    kind: "sampled-unattested-dispatch-audit",
    baseline: { tag: baseline.tag, commit: baseline.commit },
    scope: {
      catalogEntries: catalog.commands.length,
      nativeEntries: nativeCommands.length,
      nativeUniqueNames: nativeNames.size,
      fixtureSelection: arguments_.includeNative
        ? "the default command-bearing selection plus all native-cases command-bearing fixtures, excluding explicit error/termination/host gaps"
        : "plugin-system/system-runtime/standard-plugin/supplemental-plugin command-bearing success fixtures plus native-cut-commands, excluding explicit AOT gaps",
      fixtureCount: fixtureReports.length,
      excludedFixtures: [...excludedFixtures].map(([key, reason]) => ({ key, reason })),
      commandAssociationIsNotExecutionEvidence: true,
    },
    provenance: {
      environment: { platform: process.platform, arch: process.arch, node: process.version },
      oracle,
      lnako: {
        binarySha256: sha256FileSync(compiler),
        commit: git.commit,
        dirty: git.dirty,
      },
      auditScriptSha256: sha256FileSync(resolve(root, "tools/check_dispatch_coverage.mjs")),
    },
    coverage: {
      unambiguousObservedNativeEntries: observedNativeIds.size,
      unambiguousObservedNativeUniqueNames: observedNativeNames.size,
      unambiguousObservedNativeEntryRatio: observedNativeIds.size / nativeCommands.length,
      unambiguousObservedNativeUniqueNameRatio: observedNativeNames.size / nativeNames.size,
      unobservedNativeEntryIds: nativeCommands.filter((command) => !observedNativeIds.has(command.id)).map((command) => command.id),
      unobservedNativeNames: nativeCommands.filter((command) => !observedNativeNames.has(command.name)).map((command) => command.name).filter((name, index, values) => values.indexOf(name) === index),
      unresolvedObservedSites: unresolvedSites,
      unresolvedObservedNames: [...unresolvedByName.keys()].sort(),
      associationWithoutDispatchCount: associationWithoutDispatch.length,
      associationWithoutDispatch,
    },
    fixtures: fixtureReports,
    sites: sites.sort(compareSites),
  };
}

function compareSites(left, right) {
  return left.fixtureId.localeCompare(right.fixtureId) || left.siteId.localeCompare(right.siteId);
}

function gitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (commit.status !== 0) throw new Error("lnakoのcommitを取得できません");
  const hash = commit.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(hash)) throw new Error("lnakoのcommit形式が不正です");
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (status.status !== 0) throw new Error("lnakoのdirty状態を取得できません");
  return { commit: hash, dirty: status.stdout.length > 0 };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function sha256FileSync(path) {
  return sha256(readFileSync(path));
}

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

async function readOracleIdentity(directory, expectedBaseline) {
  const markerPath = resolve(directory, ".lnako-oracle.json");
  const cliPath = resolve(directory, "src/cnako3.mjs");
  const markerBytes = await readFile(markerPath);
  const marker = JSON.parse(markerBytes.toString("utf8"));
  const expected = expectedBaseline.oracleIdentity;
  const treeSha256 = await oracleTreeHash(directory);
  const cliSha256 = sha256(await readFile(cliPath));
  const markerSha256 = sha256(markerBytes);
  const platform = `${process.platform}-${process.arch}`;
  if (marker.tag !== expectedBaseline.tag || marker.commit !== expectedBaseline.commit || marker.archiveSha256 !== expectedBaseline.archive.sha256 ||
      marker.treeSha256 !== treeSha256 || marker.treeSha256 !== expected?.treeSha256ByPlatform?.[platform] ||
      marker.oracleBuild !== expected?.build || cliSha256 !== expected?.cliSha256 || markerSha256 !== expected?.markerSha256 ||
      expected?.treeHashAlgorithm !== oracleTreeHashAlgorithm) {
    throw new Error("公式オラクルの固定情報がlockと一致しません");
  }
  return {
    build: marker.oracleBuild,
    archiveSha256: marker.archiveSha256,
    cliSha256,
    markerSha256,
    treeHashAlgorithm: oracleTreeHashAlgorithm,
    treeSha256,
  };
}

async function assertOutputDoesNotExist(path) {
  try {
    await access(path);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  throw new Error(`dispatch coverage auditの出力先は既に存在します: ${path}`);
}

async function writeExclusive(path, content) {
  const temporaryPath = resolve(dirname(path), `.lnako-dispatch-coverage-${process.pid}-${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, content, { encoding: "utf8", flag: "wx" });
    try {
      await link(temporaryPath, path);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error(`dispatch coverage auditの出力先は既に存在します: ${path}`);
      throw new Error(`dispatch coverage auditを出力できません: ${path}`, { cause: error });
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }
}
