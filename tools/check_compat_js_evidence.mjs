import { access, link, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const catalogPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const casesPath = resolve(root, "tests/oracle/compat-js-cases.json");
const evidencePath = resolve(root, "compat/v3.7.24/compat-js-evidence.json");
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const arguments_ = process.argv.slice(2);
const noBuild = arguments_.includes("--no-build");
const evidenceOutput = optionValue("--evidence-output");
const oracleArgument = optionValue("--oracle");
const oracleRoot = resolve(oracleArgument ?? process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const operationByName = new Map([
  ["JS実行", "eval"],
  ["JSオブジェクト取得", "lookup"],
  ["JS関数実行", "call"],
  ["JSメソッド実行", "method-call"],
]);
const operationNames = ["eval", "lookup", "call", "method-call"];
const hashPattern = /^[0-9a-f]{64}$/;
const siteIdPattern = /^0x[0-9a-f]{16}$/;
const commitPattern = /^[0-9a-f]{40}$/i;
const maxBuffer = 32 * 1024 * 1024;

if (arguments_.some((argument) => argument.startsWith("--") && !new Set(["--no-build", "--evidence-output", "--oracle"]).has(argument))) {
  throw new Error("usage: node tools/check_compat_js_evidence.mjs [--no-build] [--evidence-output /absolute/path] [--oracle /absolute/path]");
}
if (evidenceOutput !== null) await ensureDestinationFree(evidenceOutput);

const [lock, catalog, implemented, cases] = await Promise.all([
  readJson(lockPath),
  readJson(catalogPath),
  readJson(implementationPath),
  readJson(casesPath),
]);
validatePlan(lock, catalog, implemented, cases);
if (!noBuild) buildCompatLnako();
await access(compiler);
const oracle = await readOracleIdentity(oracleRoot, lock.nadesiko3);
const temporary = await mkdtemp(join(tmpdir(), "lnako-compat-js-evidence-"));

try {
  const reports = [];
  for (const testCase of cases) reports.push(await runCase(testCase, oracle.cliPath));
  const evidence = await makeEvidence(lock, catalog, cases, reports, oracle);
  validateEvidence(evidence, lock, catalog, cases, { allowDirty: true });

  if (evidenceOutput !== null) {
    const git = readGitState();
    if (git.dirty) throw new Error("compat-js証拠の生成にはcleanなlnako作業ツリーが必要です");
    await writeExclusive(evidenceOutput, `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(`compat-js実行証拠を生成しました: ${evidence.entries.length} entry / ${evidence.scope.caseCount}ケース`);
  } else {
    const actual = JSON.parse(await readFile(evidencePath, "utf8"));
    validateEvidence(actual, lock, catalog, cases, { allowDirty: false });
    validateLiveSites(actual, reports);
    console.log(`compat-js実行証拠を検証しました: ${actual.entries.length} entry / ${actual.scope.caseCount}ケース（tracked artifact）`);
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runCase(testCase, cliPath) {
  const sourcePath = resolve(root, "tests/fixtures", testCase.fixture);
  const source = await readFile(sourcePath, "utf8");
  const tracePath = resolve(temporary, `${testCase.id}.jsonl`);
  const baseEnv = { ...process.env, TZ: "Asia/Tokyo" };
  delete baseEnv.LNAKO_COMPAT_JS_TRACE;
  const options = { cwd: root, encoding: "utf8", env: baseEnv, maxBuffer };
  const official = spawnSync(process.execPath, [cliPath, sourcePath], options);
  const actual = spawnSync(compiler, ["run", sourcePath, "--compat-js"], {
    ...options,
    env: { ...baseEnv, LNAKO_COMPAT_JS_TRACE: tracePath },
  });
  const expectedFailure = testCase.expectedFailure === true;
  const officialFailed = failed(official);
  const actualFailed = failed(actual);
  if (expectedFailure) {
    if (!officialFailed || !actualFailed) throw new Error(`compat-js期待失敗の成否が不一致です: ${testCase.id}`);
  } else if (official.status !== 0 || actual.status !== 0 || JSON.stringify(normalizeSuccess(official)) !== JSON.stringify(normalizeSuccess(actual))) {
    throw new Error(`compat-js公式差分に失敗しました: ${testCase.id}\nofficial=${JSON.stringify(normalizeSuccess(official))}\nlnako=${JSON.stringify(normalizeSuccess(actual))}`);
  }
  const trace = await readTrace(tracePath);
  if (!expectedFailure && trace === null) throw new Error(`compat-js traceが出力されませんでした: ${testCase.id}`);
  if (trace !== null) {
    validateTrace(trace.events, testCase.id, !expectedFailure);
    if (expectedFailure && directOperations(trace.events, testCase.id).length > 0) throw new Error(`期待失敗caseに成功siteがあります: ${testCase.id}`);
  }
  return {
    id: testCase.id,
    fixture: testCase.fixture,
    sourceSha256: sha256(source),
    expectedFailure,
    equivalent: expectedFailure ? officialFailed && actualFailed : true,
    results: {
      officialSource: resultSummary(official),
      lnakoCompatJs: resultSummary(actual),
    },
    trace: expectedFailure || trace === null ? null : {
      schema: 1,
      eventCount: trace.events.length,
      operations: directOperations(trace.events, testCase.id),
    },
    traceSha256: expectedFailure ? null : trace?.rawSha256 ?? null,
  };
}

async function makeEvidence(lock, catalog, cases, reports, oracle) {
  const git = readGitState();
  const compatCommands = catalog.commands.filter((command) => command.plannedMode === "compat-js");
  const reportsWithOperations = reports.filter((report) => report.trace?.operations.length > 0).map((report) => report.id);
  const entries = compatCommands.map((command) => {
    const sites = reports.flatMap((report) => (report.trace?.operations ?? [])
      .filter((operation) => operation.command === command.name)
      .map((operation) => ({
        fixtureId: report.id,
        siteId: operation.siteId,
        command: operation.command,
        operation: operation.operation,
        runtime: { interpreter: { attemptCount: operation.attemptCount, resultCount: operation.resultCount, success: operation.result === "success" } },
        officialEquivalent: report.equivalent,
      })))
      .sort((left, right) => left.fixtureId.localeCompare(right.fixtureId) || left.siteId.localeCompare(right.siteId));
    if (sites.length === 0) throw new Error(`compat-js命令の直接siteがありません: ${command.id}/${command.name}`);
    return {
      catalogId: command.id,
      name: command.name,
      plugin: command.plugin,
      operation: operationByName.get(command.name),
      fixtureIds: [...new Set(sites.map((site) => site.fixtureId))].sort(),
      sites,
      runtime: { interpreter: { attemptCount: sites.length, resultCount: sites.length, success: true } },
      officialEquivalent: sites.every((site) => site.officialEquivalent),
    };
  });
  return {
    schema: "lnako.compat-js-evidence.v1",
    generator: "tools/check_compat_js_evidence.mjs",
    baseline: { tag: lock.nadesiko3.tag, commit: lock.nadesiko3.commit },
    scope: {
      catalogEntries: compatCommands.length,
      operations: operationNames,
      fixtureSelection: "all compat-js-cases.json cases; only successful direct root sites select catalog evidence",
      caseCount: cases.length,
      successCaseCount: reports.filter((report) => !report.expectedFailure).length,
      expectedFailureCaseCount: reports.filter((report) => report.expectedFailure).length,
      selectedProofCaseIds: reportsWithOperations,
      commandNames: compatCommands.map((command) => command.name).sort(),
      nativeDispatchEvidenceSeparate: true,
    },
    officialComparison: {
      oracle: "official-source",
      routes: ["officialSource", "lnakoCompatJs"],
      equivalent: reports.every((report) => report.equivalent),
      comparisonRule: "success cases compare normalized stdout, exit status, and signal; stderr is retained only as SHA-256",
      cases: reports.map((report) => ({
        id: report.id,
        fixture: { file: report.fixture, sourceSha256: report.sourceSha256 },
        expectedFailure: report.expectedFailure,
        equivalent: report.equivalent,
        results: report.results,
        trace: report.trace,
      })),
    },
    attestation: null,
    provenance: {
      environment: { platform: process.platform, arch: process.arch, node: process.version },
      oracle: {
        build: oracle.build,
        archiveSha256: oracle.archiveSha256,
        cliSha256: oracle.cliSha256,
        markerSha256: oracle.markerSha256,
        treeHashAlgorithm: oracle.treeHashAlgorithm,
        treeSha256: oracle.treeSha256,
      },
      lnako: { binarySha256: sha256(await readFile(compiler)), commit: git.commit, dirty: git.dirty },
      raw: { traceSha256ByCase: Object.fromEntries(reports.filter((report) => report.traceSha256 !== null).map((report) => [report.id, report.traceSha256])) },
    },
    entries,
  };
}

function validatePlan(lock, catalog, implemented, cases) {
  if (catalog.commandCount !== 527 || !Array.isArray(catalog.commands) || catalog.commands.length !== 527) throw new Error("標準cnakoカタログが527 entryではありません");
  if (!Array.isArray(cases) || cases.length === 0) throw new Error("compat-js-cases.jsonが空です");
  const commands = catalog.commands.filter((command) => command.plannedMode === "compat-js");
  if (commands.length !== operationNames.length || JSON.stringify(commands.map((command) => command.name).sort()) !== JSON.stringify([...operationByName.keys()].sort())) throw new Error("compat-js計画命令とoperation対応が一致しません");
  const caseIds = new Set();
  const testedNames = [];
  for (const testCase of cases) {
    if (typeof testCase.id !== "string" || caseIds.has(testCase.id) || typeof testCase.fixture !== "string") throw new Error(`compat-js case identityが不正です: ${testCase.id}`);
    caseIds.add(testCase.id);
    for (const name of testCase.commands ?? []) {
      testedNames.push(name);
      const implementation = implemented[name];
      if (implementation?.status !== "compat-js" || !implementation.tests?.includes(testCase.id)) throw new Error(`実装台帳にcompat-js caseがありません: ${name}/${testCase.id}`);
    }
  }
  if (JSON.stringify([...new Set(testedNames)].sort()) !== JSON.stringify(commands.map((command) => command.name).sort())) throw new Error("compat-js caseのcatalog命令集合が不一致です");
  if (lock.nadesiko3?.tag !== "3.7.24" || typeof lock.nadesiko3?.commit !== "string") throw new Error("compat-js baselineが不正です");
}

function validateEvidence(evidence, lock, catalog, cases, { allowDirty }) {
  rejectForbiddenFields(evidence);
  assertKeys(evidence, ["schema", "generator", "baseline", "scope", "officialComparison", "attestation", "provenance", "entries"], "compat-js-evidence");
  if (evidence.schema !== "lnako.compat-js-evidence.v1" || evidence.generator !== "tools/check_compat_js_evidence.mjs") throw new Error("compat-js証拠のschemaまたはgeneratorが不正です");
  assertKeys(evidence.baseline, ["tag", "commit"], "compat-js-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) throw new Error("compat-js証拠のbaselineが不一致です");
  assertKeys(evidence.scope, ["catalogEntries", "operations", "fixtureSelection", "caseCount", "successCaseCount", "expectedFailureCaseCount", "selectedProofCaseIds", "commandNames", "nativeDispatchEvidenceSeparate"], "compat-js-evidence.scope");
  const expectedCommands = catalog.commands.filter((command) => command.plannedMode === "compat-js");
  const expectedNames = expectedCommands.map((command) => command.name).sort();
  if (evidence.scope.catalogEntries !== expectedCommands.length || JSON.stringify(evidence.scope.operations) !== JSON.stringify(operationNames) || JSON.stringify(evidence.scope.commandNames) !== JSON.stringify(expectedNames) || evidence.scope.caseCount !== cases.length || evidence.scope.successCaseCount + evidence.scope.expectedFailureCaseCount !== cases.length || !Array.isArray(evidence.scope.selectedProofCaseIds) || evidence.scope.nativeDispatchEvidenceSeparate !== true) throw new Error("compat-js証拠のscopeが不一致です");
  if (evidence.attestation !== null) throw new Error("compat-js証拠のattestationは未対応です");

  const comparison = evidence.officialComparison;
  assertKeys(comparison, ["oracle", "routes", "equivalent", "comparisonRule", "cases"], "compat-js-evidence.officialComparison");
  if (comparison.oracle !== "official-source" || JSON.stringify(comparison.routes) !== JSON.stringify(["officialSource", "lnakoCompatJs"]) || comparison.equivalent !== true || typeof comparison.comparisonRule !== "string" || !Array.isArray(comparison.cases) || comparison.cases.length !== cases.length) throw new Error("compat-js公式比較のrouteまたはcase数が不正です");
  const caseById = new Map(cases.map((testCase) => [testCase.id, testCase]));
  const comparisonIds = new Set();
  for (const item of comparison.cases) {
    assertKeys(item, ["id", "fixture", "expectedFailure", "equivalent", "results", "trace"], "compat-js-evidence.case");
    const expected = caseById.get(item.id);
    if (expected === undefined || comparisonIds.has(item.id) || item.fixture.file !== expected.fixture || item.expectedFailure !== (expected.expectedFailure === true) || item.equivalent !== true) throw new Error(`compat-js evidence case identityが不正です: ${item.id}`);
    comparisonIds.add(item.id);
    if (!hashPattern.test(item.fixture.sourceSha256)) throw new Error(`compat-js fixture SHA-256が不正です: ${item.id}`);
    validateRouteResults(item.results, item.expectedFailure, `compat-js-evidence.case.${item.id}`);
    if (item.expectedFailure) {
      if (item.trace !== null) throw new Error(`期待失敗caseにtraceがあります: ${item.id}`);
    } else {
      validateTraceSummary(item.trace, item.id);
    }
  }
  if (comparisonIds.size !== cases.length) throw new Error("compat-js evidence case集合が不一致です");

  assertKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "compat-js-evidence.provenance");
  assertKeys(evidence.provenance.environment, ["platform", "arch", "node"], "compat-js-evidence.provenance.environment");
  assertKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "compat-js-evidence.provenance.oracle");
  assertKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "compat-js-evidence.provenance.lnako");
  assertKeys(evidence.provenance.raw, ["traceSha256ByCase"], "compat-js-evidence.provenance.raw");
  validateProvenance(evidence.provenance, lock, allowDirty);

  const commandById = new Map(expectedCommands.map((command) => [command.id, command]));
  if (!Array.isArray(evidence.entries) || evidence.entries.length !== expectedCommands.length) throw new Error("compat-js証拠entry数が不正です");
  const entryIds = new Set();
  for (const entry of evidence.entries) {
    assertKeys(entry, ["catalogId", "name", "plugin", "operation", "fixtureIds", "sites", "runtime", "officialEquivalent"], "compat-js-evidence.entry");
    const command = commandById.get(entry.catalogId);
    if (command === undefined || entry.name !== command.name || entry.plugin !== command.plugin || entry.operation !== operationByName.get(command.name) || entryIds.has(entry.catalogId) || entry.officialEquivalent !== true || !Array.isArray(entry.fixtureIds) || !Array.isArray(entry.sites) || entry.sites.length === 0) throw new Error(`compat-js証拠entry identityが不正です: ${entry.catalogId}`);
    entryIds.add(entry.catalogId);
    assertKeys(entry.runtime, ["interpreter"], `compat-js-evidence.entry.${entry.catalogId}.runtime`);
    assertKeys(entry.runtime.interpreter, ["attemptCount", "resultCount", "success"], `compat-js-evidence.entry.${entry.catalogId}.runtime.interpreter`);
    if (entry.runtime.interpreter.attemptCount !== entry.sites.length || entry.runtime.interpreter.resultCount !== entry.sites.length || entry.runtime.interpreter.success !== true || JSON.stringify(entry.fixtureIds) !== JSON.stringify([...new Set(entry.sites.map((site) => site.fixtureId))].sort())) throw new Error(`compat-js証拠entry runtimeが不正です: ${entry.catalogId}`);
    const siteKeys = new Set();
    for (const site of entry.sites) {
      assertKeys(site, ["fixtureId", "siteId", "command", "operation", "runtime", "officialEquivalent"], `compat-js-evidence.entry.${entry.catalogId}.site`);
      assertKeys(site.runtime, ["interpreter"], "compat-js-evidence.site.runtime");
      assertKeys(site.runtime.interpreter, ["attemptCount", "resultCount", "success"], "compat-js-evidence.site.runtime.interpreter");
      const key = `${site.fixtureId}/${site.siteId}`;
      if (!caseById.has(site.fixtureId) || !siteIdPattern.test(site.siteId) || site.command !== entry.name || site.operation !== entry.operation || siteKeys.has(key) || site.officialEquivalent !== true || site.runtime.interpreter.attemptCount !== 1 || site.runtime.interpreter.resultCount !== 1 || site.runtime.interpreter.success !== true) throw new Error(`compat-js証拠siteが不正です: ${entry.catalogId}/${key}`);
      siteKeys.add(key);
    }
  }
  if (entryIds.size !== expectedCommands.length) throw new Error("compat-js証拠entry集合が不一致です");
}

function validateLiveSites(evidence, reports) {
  const current = new Set(reports.flatMap((report) => (report.trace?.operations ?? []).map((operation) => `${report.id}/${operation.siteId}`)));
  for (const entry of evidence.entries) for (const site of entry.sites) if (!current.has(`${site.fixtureId}/${site.siteId}`)) throw new Error(`現行compat-js traceにtracked siteがありません: ${entry.catalogId}/${site.fixtureId}/${site.siteId}`);
}

function validateRouteResults(results, expectedFailure, label) {
  assertKeys(results, ["officialSource", "lnakoCompatJs"], `${label}.results`);
  for (const [route, result] of Object.entries(results)) {
    assertKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256", "failed"], `${label}.results.${route}`);
    if ((typeof result.status !== "number" && result.status !== null) || (result.signal !== null && typeof result.signal !== "string") || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) || typeof result.failed !== "boolean") throw new Error(`${label}のresultが不正です: ${route}`);
    if (result.failed !== expectedFailure) throw new Error(`${label}の成否が不正です: ${route}`);
  }
  const official = results.officialSource;
  const actual = results.lnakoCompatJs;
  if (!expectedFailure && (actual.status !== official.status || actual.signal !== official.signal || actual.stdoutSha256 !== official.stdoutSha256)) throw new Error(`${label}の公式stdout/status比較が不一致です`);
}

function validateTraceSummary(trace, caseId) {
  if (trace === null || typeof trace !== "object") throw new Error(`compat-js成功caseにtraceがありません: ${caseId}`);
  assertKeys(trace, ["schema", "eventCount", "operations"], `compat-js-evidence.case.${caseId}.trace`);
  if (trace.schema !== 1 || !Number.isSafeInteger(trace.eventCount) || trace.eventCount < 1 || !Array.isArray(trace.operations)) throw new Error(`compat-js trace summaryが不正です: ${caseId}`);
  for (const operation of trace.operations) {
    assertKeys(operation, ["siteId", "command", "operation", "attemptCount", "resultCount", "result"], `compat-js-evidence.case.${caseId}.operation`);
    if (!siteIdPattern.test(operation.siteId) || !operationByName.has(operation.command) || operationByName.get(operation.command) !== operation.operation || operation.attemptCount !== 1 || operation.resultCount !== 1 || operation.result !== "success") throw new Error(`compat-js trace operationが不正です: ${caseId}/${operation.siteId}`);
  }
}

function validateProvenance(provenance, lock, allowDirty) {
  const environment = provenance.environment;
  const oracle = provenance.oracle;
  const lnako = provenance.lnako;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) || !Number.isSafeInteger(oracle.build) || oracle.build !== lock.nadesiko3.oracleIdentity?.build || oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 || oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm || oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[`${environment.platform}-${environment.arch}`] || !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) || !hashPattern.test(lnako.binarySha256) || !commitPattern.test(lnako.commit) || (!allowDirty && lnako.dirty !== false)) throw new Error("compat-js証拠のprovenanceが不正です");
  for (const hash of Object.values(provenance.raw.traceSha256ByCase)) if (!hashPattern.test(hash)) throw new Error("compat-js trace raw SHA-256が不正です");
}

function directOperations(events, caseId) {
  const attempts = events.filter((event) => event.phase === "compat-js-attempt" && event.siteId !== null);
  const results = events.filter((event) => event.phase === "compat-js-result" && event.siteId !== null);
  const operations = [];
  const seen = new Set();
  for (const attempt of attempts) {
    const key = `${attempt.siteId}/${attempt.command}/${attempt.operation}`;
    const matches = results.filter((result) => result.siteId === attempt.siteId && result.command === attempt.command && result.operation === attempt.operation && result.seq > attempt.seq);
    if (seen.has(key) || matches.length !== 1) throw new Error(`compat-js traceのattempt/result対応が不正です: ${caseId}/${key}`);
    const result = matches[0];
    seen.add(key);
    if (result.result !== "success") continue;
    operations.push({ siteId: attempt.siteId, command: attempt.command, operation: attempt.operation, attemptCount: 1, resultCount: 1, result: result.result });
  }
  return operations.sort((left, right) => left.siteId.localeCompare(right.siteId));
}

function validateTrace(events, caseId, requireEnd = true) {
  if (!Array.isArray(events) || events.length < 1) throw new Error(`compat-js traceが空です: ${caseId}`);
  for (const event of events) {
    if (event.phase === "compat-js-attempt") {
      assertKeys(event, ["schema", "engine", "phase", "seq", "siteId", "command", "operation"], `compat-js trace.${caseId}`);
      if (event.schema !== 1 || event.engine !== "interpreter" || !Number.isSafeInteger(event.seq) || (event.siteId !== null && !siteIdPattern.test(event.siteId)) || !operationByName.has(event.command) || operationByName.get(event.command) !== event.operation) throw new Error(`compat-js attempt eventが不正です: ${caseId}`);
    } else if (event.phase === "compat-js-result") {
      assertKeys(event, ["schema", "engine", "phase", "seq", "siteId", "command", "operation", "result"], `compat-js trace.${caseId}`);
      if (event.schema !== 1 || event.engine !== "interpreter" || !Number.isSafeInteger(event.seq) || (event.siteId !== null && !siteIdPattern.test(event.siteId)) || !operationByName.has(event.command) || operationByName.get(event.command) !== event.operation || !["success", "failure"].includes(event.result)) throw new Error(`compat-js result eventが不正です: ${caseId}`);
    } else if (event.phase === "trace-end") {
      assertKeys(event, ["schema", "engine", "phase", "seq", "dropped"], `compat-js trace.${caseId}`);
      if (event.schema !== 1 || event.engine !== "interpreter" || !Number.isSafeInteger(event.seq) || event.dropped !== 0) throw new Error(`compat-js trace-endが不正です: ${caseId}`);
    } else throw new Error(`compat-js traceに未知phaseがあります: ${caseId}/${event.phase}`);
  }
  if (requireEnd && events.at(-1)?.phase !== "trace-end") throw new Error(`compat-js traceがtrace-endで終わりません: ${caseId}`);
}

async function readTrace(path) {
  let bytes;
  try {
    bytes = await readFile(path);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  const text = bytes.toString("utf8");
  const events = text.split(/\r?\n/).filter((line) => line.length > 0).map((line) => JSON.parse(line));
  return { events, rawSha256: sha256(bytes) };
}

function normalizeSuccess(result) {
  return { stdout: String(result.stdout ?? "").replaceAll("\r\n", "\n"), exitCode: result.status, signal: result.signal };
}

function resultSummary(result) {
  return { status: result.status, signal: result.signal, stdoutSha256: sha256(String(result.stdout ?? "").replaceAll("\r\n", "\n")), stderrSha256: sha256(String(result.stderr ?? "").replaceAll("\r\n", "\n")), failed: failed(result) };
}

function failed(result) {
  const output = `${String(result.stdout ?? "")}\n${String(result.stderr ?? "")}`;
  return result.status !== 0 || result.signal !== null || String(result.stderr ?? "").length > 0 || /\[(?:実行時)?エラー\]/.test(output) || output.includes("実行時エラー:");
}

function assertKeys(value, keys, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`objectが不正です: ${path}`);
  const allowed = new Set(keys);
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new Error(`未知fieldがあります: ${path}.${key}`);
}

function rejectForbiddenFields(value, path = "compat-js-evidence") {
  const forbidden = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address"]);
  if (Array.isArray(value)) return value.forEach((item, index) => rejectForbiddenFields(item, `${path}[${index}]`));
  if (value === null || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (forbidden.has(key)) throw new Error(`証拠に禁止fieldがあります: ${path}.${key}`);
    rejectForbiddenFields(item, `${path}.${key}`);
  }
}

async function readOracleIdentity(directory, baseline) {
  const markerPath = resolve(directory, ".lnako-oracle.json");
  const cliPath = resolve(directory, "src/cnako3.mjs");
  const markerBytes = await readFile(markerPath);
  const marker = JSON.parse(markerBytes.toString("utf8"));
  const expected = baseline.oracleIdentity;
  const platform = `${process.platform}-${process.arch}`;
  const treeSha256 = await oracleTreeHash(directory);
  const cliSha256 = sha256(await readFile(cliPath));
  const markerSha256 = sha256(markerBytes);
  if (marker.tag !== baseline.tag || marker.commit !== baseline.commit || marker.archiveSha256 !== baseline.archive.sha256 || marker.oracleBuild !== expected.build || cliSha256 !== expected.cliSha256 || markerSha256 !== expected.markerSha256 || marker.treeSha256 !== treeSha256 || marker.treeSha256 !== expected.treeSha256ByPlatform?.[platform] || expected.treeHashAlgorithm !== oracleTreeHashAlgorithm) throw new Error("公式オラクルの固定情報がlockと一致しません");
  return { build: marker.oracleBuild, archiveSha256: baseline.archive.sha256, cliSha256, markerSha256, treeHashAlgorithm: oracleTreeHashAlgorithm, treeSha256, cliPath };
}

function buildCompatLnako() {
  const result = spawnSync("zig", ["build", "-Dcompat-js=true"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") }, maxBuffer });
  if (result.status !== 0) throw new Error(`QuickJS互換lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function readGitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (commit.status !== 0 || status.status !== 0) throw new Error("lnakoのGit状態を取得できません");
  return { commit: commit.stdout.trim(), dirty: status.stdout.length > 0 };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function optionValue(name) {
  const index = arguments_.indexOf(name);
  if (index < 0) return null;
  const value = arguments_[index + 1];
  if (value === undefined || value.startsWith("--") || !isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
  return value;
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function ensureDestinationFree(path) {
  try {
    await access(path);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  throw new Error(`compat-js証拠の出力先は既に存在します: ${path}`);
}

async function writeExclusive(path, contents) {
  const temporaryPath = join(dirname(path), `.lnako-compat-js-evidence-${process.pid}.tmp`);
  try {
    await writeFile(temporaryPath, contents, { encoding: "utf8", flag: "wx" });
    try {
      await link(temporaryPath, path);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error(`compat-js証拠の出力先は既に存在します: ${path}`);
      throw new Error("compat-js証拠を原子的に出力できません", { cause: error });
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }
}
