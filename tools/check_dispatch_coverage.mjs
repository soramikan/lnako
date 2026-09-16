import { readFileSync } from "node:fs";
import { access, link, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";
import { coverageEnv } from "./lib/coverage_env.mjs";
import * as coverage_process from "./lib/coverage_process.mjs";
import * as coverage_fixtures from "./lib/coverage_fixtures.mjs";
import * as coverage_http from "./lib/coverage_http.mjs";
import * as coverage_sites from "./lib/coverage_sites.mjs";
import { sha256, sha256FileSync, normalizeLineEndings, readOracleIdentity, assertOutputDoesNotExist, writeExclusive, validDispatchExpectationPlatforms } from "./lib/evidence_common.mjs";


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
Object.assign(coverageEnv, {
  root,
  oracle,
  oracleRoot,
  baseline,
  lock,
  catalog,
  catalogByName,
  nativeDispatchCoverageExclusions: coverage_fixtures.nativeDispatchCoverageExclusions,
  excludedFixtures: coverage_fixtures.excludedFixtures,
  generatedRouteUnavailableFixtures: coverage_fixtures.generatedRouteUnavailableFixtures,
  arguments_,
});
const fixturePool = await coverage_fixtures.loadSelectedFixtures();
const selectedFixtures = coverage_fixtures.selectFixtureShard(fixturePool, arguments_.fixtureShard);
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const systemOnlyRunner = resolve(root, "tools/oracle/system_only.mjs");
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
if (!arguments_.noBuild) coverage_process.buildCompiler();
await access(compiler);

// cnako3 v3.7.24 recognizes a Windows drive-letter path as a full path only
// when the separator after the drive is a backslash. The plugin resolver
// therefore treats a `D:/...` path as relative. Keep the scratch tree on the
// repository drive, which is also the default oracle drive in CI, so relative
// plugin paths remain valid on Windows.
const temporary = await mkdtemp(join(root, ".tmp-lnako-dispatch-coverage-"));
Object.assign(coverageEnv, {
  root,
  oracle,
  oracleRoot,
  baseline,
  lock,
  catalog,
  catalogByName,
  compiler,
  fixedHost,
  systemOnlyRunner,
  normalizedDebugHost,
  safeExternalHost,
  arguments_,
  maxBuffer,
  throwStatementOpcode,
  archiveHelperName,
  fixtureStateMutationCommands,
  excludedFixtures: coverage_fixtures.excludedFixtures,
  generatedRouteUnavailableFixtures: coverage_fixtures.generatedRouteUnavailableFixtures,
  nativeDispatchCoverageExclusions: coverage_fixtures.nativeDispatchCoverageExclusions,
  fixturePool,
  temporary,
});
let loopbackServer = null;
try {
  if (selectedFixtures.some((fixture) => fixture.file === "node-http-cases.json")) {
    loopbackServer = await coverage_process.startLoopbackServer();
  }
  const fixtureReports = [];
  const sites = [];
  const unresolvedSites = [];
  for (const [index, fixture] of selectedFixtures.entries()) {
    console.error(`dispatch fixture ${index + 1}/${selectedFixtures.length}: ${fixture.file}/${fixture.id}`);
    const result = fixture.httpServer === true
      ? await coverage_http.runHttpServerFixture(fixture, index, temporary)
      : await runFixture(fixture, index, temporary, loopbackServer?.base ?? null);
    fixtureReports.push(result.report);
    sites.push(...result.sites);
    unresolvedSites.push(...result.unresolvedSites);
  }

  const report = await coverage_sites.createReport({ fixtureReports, sites, unresolvedSites, oracle });
  if (arguments_.output !== null) await writeExclusive(arguments_.output, `${JSON.stringify(report, null, 2)}\n`);
  const nativeCoverage = report.coverage.unambiguousObservedNativeEntries;
  const nativeNames = report.coverage.unambiguousObservedNativeUniqueNames;
  console.log(
    `AOT dispatch coverage audit: ${fixtureReports.length} fixtures / ${sites.length} unambiguous sites / ` +
      `${nativeCoverage}/523 native entries・${nativeNames}/492 unique names (unattested sampled coverage)`,
  );
} catch (error) {
  // Report before cleanup: child termination or scratch removal can fail too.
  console.error(error?.stack ?? error);
  throw error;
} finally {
  if (loopbackServer !== null) await coverage_process.stopLoopbackServer(loopbackServer.process);
  await rm(temporary, { recursive: true, force: true });
}

function parseArguments() {
  let noBuild = false;
  let includeNative = false;
  let output = null;
  let oracle = null;
  let fixtureShardIndex = null;
  let fixtureShardCount = null;
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
    } else if (argument === "--fixture-shard-index") {
      if (fixtureShardIndex !== null) throw new Error("--fixture-shard-indexは1回だけ指定してください");
      fixtureShardIndex = coverage_fixtures.parseShardInteger(argument, process.argv[++index + 2]);
    } else if (argument === "--fixture-shard-count") {
      if (fixtureShardCount !== null) throw new Error("--fixture-shard-countは1回だけ指定してください");
      fixtureShardCount = coverage_fixtures.parseShardInteger(argument, process.argv[++index + 2]);
    } else {
      throw new Error("usage: node tools/check_dispatch_coverage.mjs [--no-build] [--include-native] [--output /absolute/path] [--oracle /absolute/path] [--fixture-shard-index N --fixture-shard-count N]");
    }
  }
  if ((fixtureShardIndex === null) !== (fixtureShardCount === null)) {
    throw new Error("--fixture-shard-indexと--fixture-shard-countは同時に指定してください");
  }
  if (fixtureShardCount !== null && (fixtureShardCount < 2 || fixtureShardIndex >= fixtureShardCount)) {
    throw new Error("fixture shardのindex/countが不正です");
  }
  return {
    noBuild,
    includeNative,
    output,
    oracle,
    fixtureShard: { index: fixtureShardIndex, count: fixtureShardCount ?? 1 },
  };
}

async function runFixture(fixture, index, temporary, loopbackBase) {
  const fixtureDirectory = resolve(temporary, `${String(index).padStart(2, "0")}-${fixture.id}`);
  await mkdir(fixtureDirectory);
  const stem = `${String(index).padStart(2, "0")}-${fixture.id}`;
  const isolated = coverage_fixtures.requiresIsolatedFixtureState(fixture);
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
    const source = coverage_fixtures.replacePluginPlaceholders(fixture.source, directory, loopbackBase, fixture);
    for (const [name, contents] of Object.entries(fixture.files ?? {})) await writeFile(resolve(directory, name), contents, "utf8");
    await writeFile(resolve(directory, sourceName), source, "utf8");
  }));

  const baseEnvironment = {
    ...coverage_fixtures.fixedEnvironment(),
    ...(fixture.networkTopology ? { LNAKO_TEST_NETWORK_TOPOLOGY: fixture.networkTopology } : {}),
  };
  const lnakoEnvironment = {
    ...baseEnvironment,
    ...(fixture.safeExternalMock ? { LNAKO_TEST_OPEN_EXTERNAL: "mock" } : {}),
    ...(fixture.archiveHelper ? { LNAKO_TEST_ARCHIVE_HELPER: archiveHelperName } : {}),
    ...(fixture.pluginRoute ? { LNAKO_PLUGIN_ROUTE: fixture.pluginRoute } : {}),
  };
  const runOptions = fixture.stdin === undefined ? {} : { input: fixture.stdin };
  const oracleUsesSafeExternalHost = fixture.safeExternalMock === true || fixture.archiveHelper === true;
  const oracleHostArguments = oracleUsesSafeExternalHost
    ? ["--import", pathToFileURL(fixedHost).href, "--import", pathToFileURL(safeExternalHost).href]
    : ["--import", pathToFileURL(fixture.normalizeDebugDump === true ? normalizedDebugHost : fixedHost).href];
  const officialCli = fixture.pluginRoute === "plugin_system" ? systemOnlyRunner : resolve(oracleRoot, "src/cnako3.mjs");
  const officialSource = coverage_process.run(process.execPath, [...oracleHostArguments, officialCli, officialSourcePath], baseEnvironment, officialSourceDirectory, runOptions);
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} 公式source`, officialSource);
  if (fixture.officialSourceStdoutIncludes !== undefined && !officialSource.stdout.includes(fixture.officialSourceStdoutIncludes)) {
    throw new Error(`${fixture.file}/${fixture.id} 公式CLI sourceの既知エラー出力が見つかりません: ${fixture.officialSourceStdoutIncludes}`);
  }
  if (fixture.officialSourceStderrIncludes !== undefined && !officialSource.stderr.includes(fixture.officialSourceStderrIncludes)) {
    throw new Error(`${fixture.file}/${fixture.id} 公式CLI sourceの既知診断出力が見つかりません: ${fixture.officialSourceStderrIncludes}`);
  }
  const officialCompile = coverage_process.run(
    process.execPath,
    [...oracleHostArguments, officialCli, "--compile", "--silent", "--output", generatedPath, officialGeneratedSourcePath],
    baseEnvironment,
    officialGeneratedDirectory,
  );
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} 公式JavaScript生成`, officialCompile);
  const generatedRouteUnavailable = coverage_fixtures.isKnownGeneratedRouteUnavailable(fixture);
  const officialGenerated = fixture.pluginRoute === "plugin_system"
    ? coverage_process.unavailableProcess(coverage_fixtures.generatedRouteUnavailableFixtures.get(`${fixture.file}/${fixture.id}`))
    : coverage_process.run(process.execPath, [...oracleHostArguments, generatedPath], baseEnvironment, officialGeneratedDirectory, runOptions);
  if (generatedRouteUnavailable && officialGenerated.status !== 0 && officialGenerated.status !== 1) {
    throw new Error(`${fixture.file}/${fixture.id} 公式生成JavaScriptの既知gapと異なる終了状態です: ${officialGenerated.status}`);
  }
  if (!generatedRouteUnavailable) coverage_process.assertSuccess(`${fixture.file}/${fixture.id} 公式生成JavaScript`, officialGenerated);

  const interpreter = coverage_process.run(compiler, ["run", interpreterTraceSourcePath], { ...lnakoEnvironment, LNAKO_DISPATCH_TRACE: interpreterTracePath }, interpreterTraceDirectory, runOptions);
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} Interpreter`, interpreter);
  const interpreterWithoutTrace = coverage_process.run(compiler, ["run", interpreterNoTraceSourcePath], lnakoEnvironment, interpreterNoTraceDirectory, runOptions);
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} Interpreter trace無効`, interpreterWithoutTrace);
  coverage_process.assertEquivalent(`${fixture.file}/${fixture.id} Interpreter trace`, interpreterWithoutTrace, interpreter);
  const interpreterTrace = await coverage_sites.readInterpreterTrace(interpreterTracePath, fixture);

  const compile = coverage_process.run(
    compiler,
    ["build", aotSourcePath, "-o", nativePath, "-O0"],
    { ...lnakoEnvironment, LNAKO_COMPILE_MANIFEST: manifestPath },
    aotTraceDirectory,
  );
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} AOT O0コンパイル`, compile);
  const manifest = await coverage_sites.readCompileManifest(manifestPath, aotSourcePath, fixture);
  const aot = coverage_process.run(nativePath, [], { ...lnakoEnvironment, LNAKO_DISPATCH_TRACE: aotTracePath }, aotTraceDirectory, runOptions);
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} AOT O0`, aot);
  const aotWithoutTrace = coverage_process.run(nativePath, [], lnakoEnvironment, aotNoTraceDirectory, runOptions);
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} AOT O0 trace無効`, aotWithoutTrace);
  coverage_process.assertEquivalent(`${fixture.file}/${fixture.id} AOT trace`, aotWithoutTrace, aot);
  const aotTrace = await coverage_sites.readAotTrace(aotTracePath, fixture, manifest.entries);
  const coverage = coverage_sites.collectSites(fixture, interpreterTrace.events, aotTrace, manifest.entries);

  const oracleRoute = fixture.oracle === "official-generated" ? "officialGenerated" : "officialSource";
  const oracleResult = oracleRoute === "officialGenerated" ? officialGenerated : officialSource;
  const officialRoutesEquivalent = JSON.stringify(coverage_process.normalizeProcess(officialSource)) === JSON.stringify(coverage_process.normalizeProcess(officialGenerated));
  coverage_process.assertOfficialEquivalent(`${fixture.file}/${fixture.id} ${oracleRoute}/Interpreter`, oracleResult, interpreterWithoutTrace);
  coverage_process.assertOfficialEquivalent(`${fixture.file}/${fixture.id} ${oracleRoute}/AOT O0`, oracleResult, aotWithoutTrace);

  const observedCommandNames = new Set(coverage.observedCommandNames);
  const associationWithoutDispatch = fixture.commands
    .filter((name) => !observedCommandNames.has(name))
    .map((name) => ({ name, catalogIds: (catalogByName.get(name) ?? []).map((command) => command.id) }));
  if (fixture.expectedDispatchRoute !== undefined && associationWithoutDispatch.length > 0) {
    throw new Error(`${fixture.file}/${fixture.id} expectedDispatchRoute対象命令がdispatchされていません: ${JSON.stringify(associationWithoutDispatch)}`);
  }
  const volatileOutputContext = {
    volatilePaths: [temporary, root, oracleRoot],
    volatileStrings: loopbackBase === null ? [] : [loopbackBase],
  };
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
          ? coverage_fixtures.generatedRouteUnavailableFixtures.get(`${fixture.file}/${fixture.id}`)
          : null,
        officialRoutesEquivalent,
        officialSourceStderrIncludes: fixture.officialSourceStderrIncludes ?? null,
        results: Object.fromEntries([
          ["officialSource", coverage_process.summarizeProcess(officialSource, volatileOutputContext)],
          ["officialGenerated", coverage_process.summarizeProcess(officialGenerated, volatileOutputContext)],
          ["lnakoRun", coverage_process.summarizeProcess(interpreterWithoutTrace, volatileOutputContext)],
          ["lnakoNativeO0", coverage_process.summarizeProcess(aotWithoutTrace, volatileOutputContext)],
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

