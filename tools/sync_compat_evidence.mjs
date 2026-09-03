import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { readDispatchFixture } from "./dispatch_fixture.mjs";

const root = resolve(import.meta.dirname, "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const catalogPath = resolve(root, "compat/v3.7.24/command_list.json");
const matrixPath = resolve(root, "compat/v3.7.24/matrix.json");
const standardPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const evidencePath = resolve(root, "compat/v3.7.24/evidence.json");
const dispatchEvidencePath = resolve(root, "compat/v3.7.24/dispatch-evidence.json");
const dispatchCoverageEvidencePath = resolve(root, "compat/v3.7.24/dispatch-coverage-evidence.json");
const expectedExitEvidencePath = resolve(root, "compat/v3.7.24/expected-exit-evidence.json");
const compatJsCasesPath = resolve(root, "tests/oracle/compat-js-cases.json");
const compatJsEvidencePath = resolve(root, "compat/v3.7.24/compat-js-evidence.json");
const globalBindingEvidenceInputs = [
  {
    path: resolve(root, "compat/v3.7.24/global-binding-evidence.json"),
    fixtureId: "native-node-file-copy-default",
    catalogId: "command-0709",
    name: "ファイルコピーデフォルト動作",
    plugin: "plugin_node",
    accessKinds: ["global-load", "global-store", "global-load", "global-store", "global-load"],
  },
  {
    path: resolve(root, "compat/v3.7.24/directory-binding-evidence.json"),
    schema: "lnako.global-binding-evidence.v2",
    fixtureId: "native-node-directory-values",
    bindings: [
      { catalogId: "command-0731", name: "デスクトップ", plugin: "plugin_node", type: "関数" },
      { catalogId: "command-0732", name: "マイドキュメント", plugin: "plugin_node", type: "関数" },
      { catalogId: "command-0735", name: "テンポラリフォルダ", plugin: "plugin_node", type: "関数" },
    ],
    accesses: [
      { catalogId: "command-0731", name: "デスクトップ", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0732", name: "マイドキュメント", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0735", name: "テンポラリフォルダ", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
    ],
  },
];
const staticConstantEvidenceInputs = [
  {
    path: resolve(root, "compat/v3.7.24/static-constant-evidence.json"),
    fixtureId: "native-scalar-system-constants",
    globalReadCount: 17,
    literalNames: new Set(["はい", "いいえ", "真", "偽", "オン", "オフ", "NULL"]),
    plugin: "plugin_system",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-string-constant-evidence.json"),
    fixtureId: "native-string-system-constants",
    globalReadCount: 24,
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-array-constant-evidence.json"),
    fixtureId: "native-array-system-constants",
    globalReadCount: 2,
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-datetime-era-constant-evidence.json"),
    fixtureId: "native-datetime-era-data",
    catalogIds: new Map([["元号データ", "command-0227"]]),
    globalReadCount: 1,
    globalTraceCount: 3,
    manifestGlobalReadNames: ["元号データ", "元号データ", "元号データ"],
    manifestExtraGlobalReadNames: ["scalar-constants__A"],
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-datetime-plugin-era-constant-evidence.json"),
    fixtureId: "native-datetime-plugin-era-data",
    catalogIds: new Map([["元号データ", "command-0807"]]),
    globalReadCount: 1,
    globalTraceCount: 3,
    manifestGlobalReadNames: ["元号データ", "元号データ", "元号データ"],
    manifestExtraGlobalReadNames: ["scalar-constants__A"],
    literalNames: new Set(),
    plugin: "plugin_datetime",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-node-archive-constant-evidence.json"),
    fixtureId: "native-node-archive-constant",
    globalReadCount: 1,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-node-command-line-constant-evidence.json"),
    fixtureId: "native-node-command-line-constants",
    globalReadCount: 3,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-node-mother-path-constant-evidence.json"),
    fixtureId: "native-node-mother-path",
    constantNames: new Set(["母艦パス"]),
    globalReadCount: 1,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-promise-reject-constant-evidence.json"),
    fixtureId: "native-system-promise-reject",
    constantNames: new Set(["そ"]),
    globalReadCount: 1,
    manifestExtraGlobalReadNames: ["対象", "scalar-constants__F"],
    literalNames: new Set(),
    plugin: "plugin_promise",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-caniuse-agents-constant-evidence.json"),
    fixtureId: "native-caniuse-agents",
    globalReadCount: 1,
    globalTraceCount: 3,
    literalNames: new Set(),
    manifestGlobalReadNames: ["ブラウザ名変換表", "ブラウザ名変換表", "ブラウザ名変換表"],
    plugin: "plugin_caniuse",
  },
  {
    path: resolve(root, "compat/v3.7.24/static-node-http-initial-constant-evidence.json"),
    fixtureId: "native-node-http-initial-constants",
    globalReadCount: 5,
    literalNames: new Set(),
    commandPlugins: {
      "AJAXオプション": "plugin_node",
      "HTTPメソッド": "plugin_httpserver",
      "GETデータ": "plugin_httpserver",
      "POSTデータ": "plugin_httpserver",
      "FILESデータ": "plugin_httpserver",
    },
  },
];
const staticConstantFixtureIds = new Set(staticConstantEvidenceInputs.map((input) => input.fixtureId));
const oracleDirectory = resolve(root, "tests/oracle");
const forbiddenEvidenceFields = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address"]);
const hashPattern = /^[0-9a-f]{64}$/;
const siteIdPattern = /^0x[0-9a-f]{16}$/;
const throwStatementOpcode = 0xffff;
const runtimeFixtureFiles = new Set([
  "compat-js-cases.json",
  "http-server-cases.json",
  "http-server-dispatch-cases.json",
  "native-cases.json",
  "node-crypto-cases.json",
  "node-exit-cases.json",
  "node-file-cases.json",
  "node-http-cases.json",
  "node-interrupt-case.json",
  "node-native-cases.json",
  "plugin-route-cases.json",
  "plugin-system-cases.json",
  "standard-plugin-cases.json",
  "supplemental-plugin-cases.json",
  "system-runtime-cases.json",
]);
// A clean dispatch evidence file is generated against the fixture/source
// commit before it is copied into the tracked catalog. Later commits may
// update only CI, documentation, catalog derivatives, or verification tools
// that do not generate the dispatch trace; any product, fixture, catalog, or
// dispatch-generator change requires a fresh dispatch run.
const dispatchEvidenceFollowUpPaths = new Set([
  ".github/workflows/ci.yml",
  ".github/workflows/release.yml",
  "README.md",
  "benchmarks/results/latest.json",
  "benchmarks/results/latest.md",
  "docs/RELEASE.md",
  "compat/v3.7.24/dispatch-evidence.json",
  "compat/v3.7.24/dispatch-coverage-evidence.json",
  "compat/v3.7.24/expected-exit-evidence.json",
  "compat/v3.7.24/global-binding-evidence.json",
  "compat/v3.7.24/directory-binding-evidence.json",
  "compat/v3.7.24/static-constant-evidence.json",
  "compat/v3.7.24/static-string-constant-evidence.json",
  "compat/v3.7.24/static-array-constant-evidence.json",
  "compat/v3.7.24/static-datetime-era-constant-evidence.json",
  "compat/v3.7.24/static-datetime-plugin-era-constant-evidence.json",
  "compat/v3.7.24/static-node-archive-constant-evidence.json",
  "compat/v3.7.24/static-node-command-line-constant-evidence.json",
  "compat/v3.7.24/static-node-mother-path-constant-evidence.json",
  "compat/v3.7.24/static-promise-reject-constant-evidence.json",
  "compat/v3.7.24/static-caniuse-agents-constant-evidence.json",
  "compat/v3.7.24/static-node-http-initial-constant-evidence.json",
  "compat/v3.7.24/compat-js-evidence.json",
  "compat/v3.7.24/matrix.json",
  "compat/v3.7.24/standard-cnako.json",
  "compat/v3.7.24/evidence.json",
  "compat/v3.7.24/interpreter-only-classification.json",
  "docs/COMPATIBILITY_EVIDENCE.md",
  "docs/COMPATIBILITY_QUIRKS.md",
  "docs/ARCHITECTURE.md",
  "docs/CI.md",
  "docs/DEVELOPMENT.md",
  "tools/check_ci_workflow.mjs",
  "tools/check_release_workflow.mjs",
  "tools/check_dispatch_coverage_shards.mjs",
  "tools/check_aot_suite_parallel.mjs",
  "tools/check_dispatch_coverage.mjs",
  "tools/oracle/system_only.mjs",
  "tools/compare_native_oracle.mjs",
  "tools/check_static_constant_evidence.mjs",
  "tools/check_global_binding_evidence.mjs",
  "tools/check_node_exit_evidence.mjs",
  "tools/check_compat_js_evidence.mjs",
  "tools/check_distribution.mjs",
  "tools/create_distribution.mjs",
  "tools/check_benchmark_result.mjs",
  "tools/compare_interpreter_oracle.mjs",
  "tools/check_native_aot_artifacts.mjs",
  "tools/verify_native_aot_attestation.mjs",
  "docs/UNVERIFIED_EVIDENCE_PLAN.md",
  "tools/sync_compat_evidence.mjs",
]);
const arguments_ = process.argv.slice(2);
const mode = arguments_[0] ?? "--check";
const optionValue = (name) => {
  const index = arguments_.indexOf(name);
  if (index < 0) return null;
  const value = arguments_[index + 1];
  if (value === undefined || value.startsWith("--") || !isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
  return resolve(value);
};
const argumentValue = (name) => {
  const index = arguments_.indexOf(name);
  if (index < 0) return null;
  const value = arguments_[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`${name}の値がありません`);
  return value;
};
const dispatchEvidenceInputPath = optionValue("--dispatch-evidence") ?? dispatchEvidencePath;
const attestationPath = optionValue("--attestation");
const attestationBundlePath = optionValue("--attestation-bundle");
const evidenceOutputPath = optionValue("--output") ?? evidencePath;
const historicalCommit = argumentValue("--historical-commit");

if ((attestationPath === null) !== (attestationBundlePath === null)) throw new Error("--attestationと--attestation-bundleは同時に指定してください");
if (historicalCommit !== null && !/^[0-9a-f]{40}$/i.test(historicalCommit)) throw new Error("--historical-commitには40桁commitを指定してください");
if (!new Set(["--generate", "--check"]).has(mode) || arguments_.some((argument) => argument.startsWith("--") && !new Set(["--generate", "--check", "--dispatch-evidence", "--attestation", "--attestation-bundle", "--output", "--historical-commit"]).has(argument))) {
  throw new Error("usage: node tools/sync_compat_evidence.mjs [--generate|--check] [--dispatch-evidence /absolute/path] [--attestation /absolute/path --attestation-bundle /absolute/path] [--historical-commit 40-hex-commit] [--output /absolute/path]");
}
if (historicalCommit !== null && (!arguments_.includes("--dispatch-evidence") || !arguments_.includes("--output") || evidenceOutputPath === evidencePath)) {
  throw new Error("--historical-commitでは--dispatch-evidenceと明示的な非canonical --outputが必須です");
}

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;
const readJson = async (path) => JSON.parse(await readFile(path, "utf8"));

const [lock, catalog, matrix, standard, implemented, compatJsCases] = await Promise.all([
  readJson(lockPath),
  readJson(catalogPath),
  readJson(matrixPath),
  readJson(standardPath),
  readJson(implementationPath),
  readJson(compatJsCasesPath),
]);
const catalogSourceSha256 = createHash("sha256").update(await readFile(catalogPath)).digest("hex");

validateCatalog(lock, catalog, matrix, standard, implemented, catalogSourceSha256);

const records = await readFixtureRecords();
const nativeFixtureIds = new Set(records.filter((record) => record.file === "native-cases.json").map((record) => record.id));
const aotFixtureIds = new Set(records.filter((record) => record.aot).map((record) => record.id));
const compatJsFixtureIds = new Set(records.filter((record) => record.file === "compat-js-cases.json").map((record) => record.id));
const standardNames = new Set(standard.commands.map((command) => command.name));
const duplicateNames = duplicateNameSet(standard.commands);
const unresolvedByName = new Map();
const dispatchEvidenceBytes = await readFile(dispatchEvidenceInputPath);
const dispatchEvidenceBase = JSON.parse(dispatchEvidenceBytes.toString("utf8"));
const dispatchEvidenceInputSha256 = createHash("sha256").update(dispatchEvidenceBytes).digest("hex");
const dispatchCoverageEvidenceBytes = await readFile(dispatchCoverageEvidencePath);
const dispatchCoverageEvidence = JSON.parse(dispatchCoverageEvidenceBytes.toString("utf8"));
const expectedExitEvidenceBytes = await readFile(expectedExitEvidencePath);
const expectedExitEvidence = JSON.parse(expectedExitEvidenceBytes.toString("utf8"));
const compatJsEvidenceBytes = await readFile(compatJsEvidencePath);
const compatJsEvidence = JSON.parse(compatJsEvidenceBytes.toString("utf8"));
const dispatchCoverageAuditScriptSha256 = createHash("sha256")
  .update(await readFile(resolve(root, "tools/check_dispatch_coverage.mjs")))
  .digest("hex");
const staticConstantEvidenceRecords = await Promise.all(staticConstantEvidenceInputs.map(async (input) => ({
  ...input,
  evidence: JSON.parse((await readFile(input.path)).toString("utf8")),
})));
const globalBindingEvidenceRecords = await Promise.all(globalBindingEvidenceInputs.map(async (input) => ({
  ...input,
  evidence: JSON.parse((await readFile(input.path)).toString("utf8")),
})));
const suppliedAttestation = attestationPath === null ? null : await readJson(attestationPath);
const attestationBundleBytes = attestationBundlePath === null ? null : await readFile(attestationBundlePath);
const dispatchEvidence = suppliedAttestation === null
  ? dispatchEvidenceBase
  : { ...dispatchEvidenceBase, attestation: suppliedAttestation };
validateDispatchEvidence(dispatchEvidence, lock, standard, records, dispatchEvidenceInputSha256, dispatchEvidenceInputPath, attestationBundlePath, attestationBundleBytes, historicalCommit);
validateDispatchCoverageEvidence(dispatchCoverageEvidence, lock, standard, records, dispatchCoverageAuditScriptSha256);
validateExpectedExitEvidence(expectedExitEvidence, lock, standard, records);
validateCompatJsEvidence(compatJsEvidence, lock, standard, compatJsCases, records);
for (const input of staticConstantEvidenceRecords) validateStaticConstantEvidence(input.evidence, lock, standard, records, input);
for (const input of globalBindingEvidenceRecords) validateGlobalBindingEvidence(input.evidence, lock, standard, records, input);
const dispatchEvidenceByCatalogId = new Map();
for (const site of dispatchEvidence.sites) {
  const sites = dispatchEvidenceByCatalogId.get(site.catalogId) ?? [];
  sites.push(site);
  dispatchEvidenceByCatalogId.set(site.catalogId, sites);
}
const dispatchCoverageEvidenceByCatalogId = new Map();
for (const site of dispatchCoverageEvidence.sites) {
  const sites = dispatchCoverageEvidenceByCatalogId.get(site.catalogId) ?? [];
  sites.push(site);
  dispatchCoverageEvidenceByCatalogId.set(site.catalogId, sites);
}
const expectedExitEvidenceByCatalogId = new Map();
for (const entry of expectedExitEvidence.entries) {
  if (expectedExitEvidenceByCatalogId.has(entry.catalogId)) throw new Error(`expected-exit証拠のcatalog IDが重複しています: ${entry.catalogId}`);
  expectedExitEvidenceByCatalogId.set(entry.catalogId, entry);
}
const compatJsEvidenceByCatalogId = new Map();
const compatJsProofByCatalogId = new Map();
for (const entry of compatJsEvidence.entries) {
  if (compatJsEvidenceByCatalogId.has(entry.catalogId)) throw new Error(`compat-js証拠のcatalog IDが重複しています: ${entry.catalogId}`);
  compatJsEvidenceByCatalogId.set(entry.catalogId, entry);
  compatJsProofByCatalogId.set(entry.catalogId, {
    schema: compatJsEvidence.schema,
    fixture: { id: "compat-js-evidence", file: "compat/v3.7.24/compat-js-evidence.json" },
    officialComparison: compatJsEvidence.officialComparison,
  });
}
const dispatchFixtureRecord = records.find((record) => record.id === "native-dispatch-commands");
const dispatchCatalogIds = dispatchFixtureRecord?.catalogIds ?? new Map();
const staticConstantEvidenceByCatalogId = new Map();
const staticConstantProofByCatalogId = new Map();
for (const input of staticConstantEvidenceRecords) {
  for (const entry of input.evidence.entries) {
    const entries = staticConstantEvidenceByCatalogId.get(entry.catalogId) ?? [];
    entries.push(entry);
    staticConstantEvidenceByCatalogId.set(entry.catalogId, entries);
    staticConstantProofByCatalogId.set(entry.catalogId, {
      schema: input.evidence.schema,
      fixture: input.evidence.fixture,
      officialComparison: input.evidence.officialComparison,
    });
  }
}
const globalBindingEvidenceByCatalogId = new Map();
const globalBindingProofByCatalogId = new Map();
for (const input of globalBindingEvidenceRecords) {
  const bindings = Array.isArray(input.evidence.bindings) ? input.evidence.bindings : [input.evidence.binding];
  for (const binding of bindings) {
    if (globalBindingEvidenceByCatalogId.has(binding.catalogId)) throw new Error(`global binding証拠のcatalog IDが重複しています: ${binding.catalogId}`);
    globalBindingEvidenceByCatalogId.set(binding.catalogId, binding.sites);
    globalBindingProofByCatalogId.set(binding.catalogId, {
      schema: input.evidence.schema,
      fixture: input.evidence.fixture,
      officialComparison: input.evidence.officialComparison,
    });
  }
}

// A test ID in implemented.json is an explicit claim that the fixture covers
// the command. Preserve that claim even when a group fixture does not list the
// command in its optional `commands` index. The ID itself must still exist.
for (const [name, implementation] of Object.entries(implemented)) {
  if (!standardNames.has(name)) throw new Error(`実装台帳の命令が標準cnakoカタログにありません: ${name}`);
  for (const testId of implementation.tests ?? []) {
    const record = records.find((candidate) => candidate.id === testId);
    if (record === undefined) {
      const unresolved = unresolvedByName.get(name) ?? [];
      unresolved.push(testId);
      unresolvedByName.set(name, unresolved);
      continue;
    }
    addAssociation(record, name, "implemented.tests");
  }
}

const entries = standard.commands.map((command) => {
  const implementation = implemented[command.name];
  const unresolvedTestIds = [...new Set(unresolvedByName.get(command.name) ?? [])].sort();
  const interpreterFixtureIds = records
    .filter((record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id) && record.commandNames.has(command.name))
    .map((record) => record.id)
    .sort();
  const aotFixtureIdsForCommand = records
    .filter((record) => aotFixtureIds.has(record.id) && record.commandNames.has(command.name))
    .map((record) => record.id)
    .sort();

  const compatJsFixtureIdsForCommand = records
    .filter((record) => compatJsFixtureIds.has(record.id) && record.commandNames.has(command.name))
    .map((record) => record.id)
    .sort();
  const fixtureCoverageState = fixtureCoverageStateFor(command.status, interpreterFixtureIds, aotFixtureIdsForCommand, compatJsFixtureIdsForCommand);
  const dispatchSites = dispatchEvidenceByCatalogId.get(command.id) ?? [];
  const dispatchCoverageSites = dispatchCoverageEvidenceByCatalogId.get(command.id) ?? [];
  const staticConstantSites = staticConstantEvidenceByCatalogId.get(command.id) ?? [];
  const globalBindingSites = globalBindingEvidenceByCatalogId.get(command.id) ?? [];
  const compatJsSites = compatJsEvidenceByCatalogId.get(command.id)?.sites ?? [];
  const explicitlyMappedDispatch = dispatchCatalogIds.get(command.name) === command.id ||
    dispatchCoverageSites.some((site) => site.resolution === "explicit-catalog-id");
  const expectedExitProof = expectedExitEvidenceByCatalogId.get(command.id) ?? null;
  const identityResolution = duplicateNames.has(command.name)
    ? staticConstantSites.length > 0 || globalBindingSites.length > 0 || expectedExitProof !== null || compatJsSites.length > 0 || explicitlyMappedDispatch ? "explicit-catalog-id" : "ambiguous-name"
    : "unique-name";
  const selectedProof = new Set(["unique-name", "explicit-catalog-id"]).has(identityResolution) && dispatchSites.length > 0
    ? { kind: "dispatch", schema: dispatchEvidence.schema, fixture: dispatchEvidence.fixture, officialComparison: dispatchEvidence.officialComparison, sites: dispatchSites }
    : staticConstantSites.length > 0
      ? { kind: "static-constant", ...staticConstantProofByCatalogId.get(command.id), sites: staticConstantSites }
        : globalBindingSites.length > 0
          ? { kind: "global-binding", ...globalBindingProofByCatalogId.get(command.id), sites: globalBindingSites }
          : expectedExitProof !== null
            ? { kind: "expected-exit", schema: expectedExitEvidence.schema, fixture: expectedExitEvidence.fixture, officialComparison: expectedExitProof.officialComparison, sites: [expectedExitProof.site] }
          : dispatchCoverageSites.length > 0
          ? {
              kind: "coverage",
              schema: dispatchCoverageEvidence.schema,
              fixture: { id: "dispatch-coverage", file: "compat/v3.7.24/dispatch-coverage-evidence.json" },
              officialComparison: { routes: ["officialSource", "lnakoRun", "lnakoNativeO0"] },
              sites: dispatchCoverageSites,
            }
          : compatJsSites.length > 0
            ? { kind: "compat-js", ...compatJsProofByCatalogId.get(command.id), sites: compatJsSites }
          : null;
  const executionSites = selectedProof?.sites ?? [];
  const executionEvidenceState = selectedProof === null
    ? "unverified"
    : selectedProof.kind === "dispatch" && dispatchEvidence.attestation !== null
      ? "verified"
      : "trace-confirmed-unattested";
  const reason = evidenceReason(
    command.status,
    fixtureCoverageState,
    identityResolution,
    interpreterFixtureIds,
    aotFixtureIdsForCommand,
    compatJsFixtureIdsForCommand,
    unresolvedTestIds,
    executionEvidenceState,
    executionSites,
    selectedProof?.kind ?? null,
  );
  return {
    id: command.id,
    name: command.name,
    plugin: command.plugin,
    status: command.status,
    interpreterFixtureIds,
    aotFixtureIds: aotFixtureIdsForCommand,
    compatJsFixtureIds: compatJsFixtureIdsForCommand,
    associationOrigin: {
      interpreter: associationOriginsFor(command.name, records, (record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id)),
      aot: associationOriginsFor(command.name, records, (record) => aotFixtureIds.has(record.id)),
      compatJs: associationOriginsFor(command.name, records, (record) => compatJsFixtureIds.has(record.id)),
    },
    fixtureCoverageState,
    identityResolution,
    executionEvidenceState,
    executionEvidence: selectedProof !== null
      ? {
          proofSchema: selectedProof.schema,
          fixtureId: selectedProof.fixture.id,
          siteIds: executionSites.map((site) => selectedProof.kind === "coverage" ? coverageSiteKey(site) : selectedProof.kind === "compat-js" ? `${site.fixtureId}/${site.siteId}` : site.siteId).sort(),
          officialComparison: selectedProof.officialComparison.routes,
          state: executionEvidenceState,
        }
      : null,
    reason,
    ...(implementation?.reason !== undefined ? { implementationReason: implementation.reason } : {}),
    ...(unresolvedTestIds.length > 0 ? { unresolvedTestIds } : {}),
  };
});

const evidence = {
  schemaVersion: 2,
  baseline: matrix.baseline,
  sourceSha256: matrix.sourceSha256,
  commandCount: entries.length,
  duplicateNameCount: duplicateNames.size,
  fixtureInventory: {
    total: records.length,
    nativeAot: aotFixtureIds.size,
    interpreter: records.filter((record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id)).length,
    compatJs: compatJsFixtureIds.size,
  },
  fixtureCoverageStates: Object.fromEntries(
    ["paired", "interpreter-only", "aot-only", "none", "compat-js-only"].map((state) => [state, entries.filter((entry) => entry.fixtureCoverageState === state).length]),
  ),
  executionEvidenceStates: Object.fromEntries(
    ["verified", "trace-confirmed-unattested", "unverified"].map((state) => [state, entries.filter((entry) => entry.executionEvidenceState === state).length]),
  ),
  entries,
};

const expected = json(evidence);
if (mode === "--generate") {
  await writeFile(evidenceOutputPath, expected);
  console.log(`カタログ証拠レイヤーを生成しました: ${entries.length}件（verified ${evidence.executionEvidenceStates.verified}件 / trace-confirmed-unattested ${evidence.executionEvidenceStates["trace-confirmed-unattested"]}件 / unverified ${evidence.executionEvidenceStates.unverified}件）`);
} else {
  const actual = await readFile(evidenceOutputPath, "utf8");
  if (actual !== expected) throw new Error(`カタログ証拠レイヤーが最新ではありません: ${evidenceOutputPath}`);
  validateEvidence(JSON.parse(actual), lock, catalogSourceSha256, nativeFixtureIds, aotFixtureIds, compatJsFixtureIds, standard, matrix, dispatchEvidenceByCatalogId, dispatchCoverageEvidenceByCatalogId, staticConstantEvidenceByCatalogId, globalBindingEvidenceByCatalogId, globalBindingProofByCatalogId, expectedExitEvidenceByCatalogId, compatJsEvidenceByCatalogId);
  console.log(`カタログ証拠レイヤーを検証しました: ${entries.length}件（同名異plugin ${evidence.duplicateNameCount * 2} entry、verified ${evidence.executionEvidenceStates.verified}件 / trace-confirmed-unattested ${evidence.executionEvidenceStates["trace-confirmed-unattested"]}件 / unverified ${evidence.executionEvidenceStates.unverified}件）`);
}

async function readFixtureRecords() {
  const records = [];
  const files = (await readdir(oracleDirectory)).filter((file) => file.endsWith(".json")).sort();
  for (const file of files) {
    const value = await readJson(resolve(oracleDirectory, file));
    const fixtures = Array.isArray(value)
      ? value
      : Array.isArray(value.cases)
        ? value.cases
        : Array.isArray(value.entries)
          ? value.entries
          : typeof value?.id === "string"
            ? [value]
            : [];
    for (const fixture of fixtures) {
      if (typeof fixture?.id !== "string" || fixture.id.length === 0) continue;
      const sourceSha256 = typeof fixture.source === "string"
        ? createHash("sha256").update(fixture.source).digest("hex")
        : file === "compat-js-cases.json" && typeof fixture.fixture === "string"
          ? createHash("sha256").update(await readFile(resolve(root, "tests/fixtures", fixture.fixture))).digest("hex")
          : null;
      const record = {
        id: fixture.id,
        file,
        aot: file === "native-cases.json" || fixture.aot === true,
        sourceSha256,
        catalogIds: readFixtureCatalogIds(fixture, file),
        expectedDispatchRoute: fixture.expectedDispatchRoute ?? null,
        officialSourceStderrIncludes: fixture.officialSourceStderrIncludes ?? null,
        commandNames: new Set(),
        associationOrigins: new Map(),
        dispatchExpectations: Array.isArray(fixture.dispatchExpectations) ? fixture.dispatchExpectations : [],
      };
      if (!runtimeFixtureFiles.has(file) && fixture.commands !== undefined) {
        throw new Error(`実行fixture以外にcommandsがあります: ${file}/${fixture.id}`);
      }
      for (const name of Array.isArray(fixture.commands) ? fixture.commands.filter((name) => typeof name === "string") : []) {
        addAssociation(record, name, "fixture.commands");
      }
      records.push(record);
    }
  }
  const nativeCases = await readJson(resolve(oracleDirectory, "native-cases.json"));
  const dispatchFixture = await readDispatchFixture(root, nativeCases);
  const dispatchRecord = {
    id: dispatchFixture.id,
    file: dispatchFixture.file,
    aot: false,
    sourceSha256: createHash("sha256").update(dispatchFixture.source).digest("hex"),
    catalogIds: dispatchFixture.catalogIds,
    commandNames: new Set(),
    associationOrigins: new Map(),
  };
  for (const name of dispatchFixture.commands) addAssociation(dispatchRecord, name, "fixture.commands");
  records.push(dispatchRecord);
  if (new Set(records.map((record) => record.id)).size !== records.length) throw new Error("オラクルfixture IDが重複しています");

  return records;
}

function readFixtureCatalogIds(fixture, file) {
  if (fixture.catalogIds === undefined) return new Map();
  if (fixture.catalogIds === null || typeof fixture.catalogIds !== "object" || Array.isArray(fixture.catalogIds)) {
    throw new Error(`fixtureのcatalogIdsが不正です: ${file}/${fixture.id}`);
  }
  const ids = new Map();
  const usedIds = new Set();
  const standardById = new Map(standard.commands.map((command) => [command.id, command]));
  for (const [name, catalogId] of Object.entries(fixture.catalogIds)) {
    const command = standardById.get(catalogId);
    if (typeof catalogId !== "string" || command === undefined || command.name !== name || usedIds.has(catalogId)) {
      throw new Error(`fixtureのcatalogIdsが標準カタログと一致しません: ${file}/${fixture.id}/${name}`);
    }
    ids.set(name, catalogId);
    usedIds.add(catalogId);
  }
  return ids;
}

function addAssociation(record, name, origin) {
  record.commandNames.add(name);
  const origins = record.associationOrigins.get(name) ?? new Set();
  origins.add(origin);
  record.associationOrigins.set(name, origins);
}

function associationOriginsFor(name, records, predicate) {
  const result = {};
  for (const record of records) {
    if (!predicate(record) || !record.commandNames.has(name)) continue;
    result[record.id] = [...(record.associationOrigins.get(name) ?? [])].sort();
  }
  return Object.fromEntries(Object.entries(result).sort(([left], [right]) => left.localeCompare(right)));
}

function fixtureCoverageStateFor(status, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIds) {
  if (status === "compat-js") return compatJsFixtureIds.length > 0 ? "compat-js-only" : "none";
  if (interpreterFixtureIds.length > 0 && aotFixtureIds.length > 0) return "paired";
  if (interpreterFixtureIds.length > 0) return "interpreter-only";
  if (aotFixtureIds.length > 0) return "aot-only";
  return "none";
}

function evidenceReason(status, coverage, identityResolution, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIds, unresolvedTestIds, executionEvidenceState, executionSites, proofKind = null) {
  const unresolved = unresolvedTestIds.length > 0 ? ` 実装台帳の未解決fixture ID: ${unresolvedTestIds.join(", ")}。` : "";
  const identity =
    identityResolution === "ambiguous-name"
      ? "同名異pluginのため、同じfixtureへの命令名ベースの割当はcatalog IDを識別する証拠にならない。"
      : identityResolution === "explicit-catalog-id"
        ? "同名異pluginだが、fixtureの明示catalog IDで対象entryを固定した。"
      : executionEvidenceState === "unverified"
        ? "catalog IDに対する実行dispatch接続はまだ追跡していない。"
        : "一意な命令名からcatalog IDを解決した。";
  const proofDescription = proofKind === "compat-js"
    ? "明示catalog ID・operation別site IDについて、公式sourceとcompat-js実行結果、metadata-only traceを機械検証した"
    : proofKind === "static-constant"
    ? "明示catalog ID・global/literal site IDについて、同一fixtureのInterpreter/AOT trace、対応manifest、公式差分の成功を機械検証した"
    : proofKind === "global-binding"
      ? "明示catalog ID・global read/write site IDについて、同一fixtureのInterpreter/AOT trace、対応manifest、公式差分の成功を機械検証した"
      : proofKind === "expected-exit"
        ? "明示catalog ID・終了site IDについて、公式source/generated、Interpreter、AOT O0〜O3の終了結果、terminal reason、trace-end、compile manifestを機械検証した"
      : proofKind === "coverage"
        ? executionSites.some((site) => site.result === "failure")
          ? "dispatch coverage監査で同一fixture/siteのInterpreter/AOT trace、compile manifest、公式source差分と明示した期待失敗結果を機械検証した"
          : "dispatch coverage監査で同一fixture/siteのInterpreter/AOT trace、compile manifest、公式source差分の成功を機械検証した"
      : "明示catalog ID・site IDについて、同一fixtureのInterpreter/AOT trace、compile manifest、公式差分の成功を機械検証した";
  if (executionEvidenceState === "trace-confirmed-unattested") {
    return `${identity} ${proofDescription}（${executionSites.length} site）。外部attestation未導入のためexecutionEvidenceState=trace-confirmed-unattestedであり、verifiedへは昇格しない。`;
  }
  if (executionEvidenceState === "verified") {
    return `${identity} ${proofDescription}と外部attestationを機械検証した（${executionSites.length} site）。executionEvidenceState=verified。`;
  }
  if (status === "compat-js") {
    return `${identity} compat-js-cases.jsonの明示関連付けを${compatJsFixtureIds.length}件収録した（fixtureCoverageState=${coverage}）。executionEvidenceState=unverified。${unresolved}`;
  }
  const compat = compatJsFixtureIds.length > 0 ? ` compat-js補助fixture ${compatJsFixtureIds.length}件も別記録した。` : "";
  return `${identity} 明示関連付けはinterpreter ${interpreterFixtureIds.length}件、AOT ${aotFixtureIds.length}件（fixtureCoverageState=${coverage}）。${compat}executionEvidenceState=unverified。${unresolved}`;
}

function duplicateNameSet(entries) {
  const counts = new Map();
  for (const entry of entries) counts.set(entry.name, (counts.get(entry.name) ?? 0) + 1);
  return new Set([...counts].filter(([, count]) => count > 1).map(([name]) => name));
}

function coverageSiteKey(site) {
  return `${site.fixtureId}/${site.siteId}`;
}

function validateDispatchCoverageEvidence(evidence, lock, standard, records, auditScriptSha256) {
  rejectForbiddenEvidenceFields(evidence);
  assertKnownObjectKeys(evidence, ["schema", "kind", "baseline", "scope", "provenance", "coverage", "fixtures", "sites"], "dispatch-coverage-evidence");
  if (evidence.schema !== "lnako.dispatch-coverage.v1" || evidence.kind !== "sampled-unattested-dispatch-audit") {
    throw new Error("dispatch coverage証拠のschemaまたはkindが不正です");
  }
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "dispatch-coverage-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) {
    throw new Error("dispatch coverage証拠のbaselineがupstream.lock.jsonと一致しません");
  }

  assertKnownObjectKeys(evidence.scope, ["catalogEntries", "nativeEntries", "nativeUniqueNames", "fixtureSelection", "fixtureCount", "excludedFixtures", "commandAssociationIsNotExecutionEvidence"], "dispatch-coverage-evidence.scope");
  const defaultDispatchCoverageSelection = "plugin-system/system-runtime/standard-plugin/supplemental-plugin command-bearing success fixtures plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and native-cut-commands, excluding explicit AOT gaps";
  const fullDispatchCoverageSelection = "the default command-bearing selection plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and all native-cases command-bearing fixtures, excluding explicit error/termination/host gaps";
  const expectedFixtureCount = evidence.scope.fixtureSelection === defaultDispatchCoverageSelection
    ? 56
    : evidence.scope.fixtureSelection === fullDispatchCoverageSelection
      ? 227
      : null;
  if (evidence.scope.catalogEntries !== 527 || evidence.scope.nativeEntries !== 523 || evidence.scope.nativeUniqueNames !== 492 ||
      expectedFixtureCount === null || evidence.scope.fixtureCount !== expectedFixtureCount ||
      !Array.isArray(evidence.scope.excludedFixtures) || evidence.scope.commandAssociationIsNotExecutionEvidence !== true) {
    throw new Error("dispatch coverage証拠のscopeが標準527 entryと一致しません");
  }
  for (const exclusion of evidence.scope.excludedFixtures) {
    assertKnownObjectKeys(exclusion, ["key", "reason"], "dispatch-coverage-evidence.scope.excludedFixtures");
    if (typeof exclusion.key !== "string" || exclusion.key.length === 0 || typeof exclusion.reason !== "string" || exclusion.reason.length === 0) {
      throw new Error("dispatch coverage証拠の除外fixtureが不正です");
    }
  }

  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "auditScriptSha256"], "dispatch-coverage-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "dispatch-coverage-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "dispatch-coverage-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "dispatch-coverage-evidence.provenance.lnako");
  const hashPattern = /^[0-9a-f]{64}$/;
  const commitPattern = /^[0-9a-f]{40}$/i;
  const environment = evidence.provenance.environment;
  const oracle = evidence.provenance.oracle;
  const lnako = evidence.provenance.lnako;
  const platformKey = `${environment.platform}-${environment.arch}`;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(oracle.build) || oracle.build < 1 || oracle.build !== lock.nadesiko3.oracleIdentity?.build ||
      oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 ||
      oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm ||
      oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[platformKey] ||
      !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) ||
      !hashPattern.test(lnako.binarySha256) || !commitPattern.test(lnako.commit) || lnako.dirty !== false ||
      !hashPattern.test(evidence.provenance.auditScriptSha256) || evidence.provenance.auditScriptSha256 !== auditScriptSha256) {
    throw new Error("dispatch coverage証拠のprovenanceが不正です");
  }
  const currentGit = readGitState();
  if (lnako.commit !== currentGit.commit && !isAllowedDispatchEvidenceFollowUp(lnako.commit, currentGit.commit)) {
    throw new Error("cleanなdispatch coverage証拠のlnako commitが現行HEADと一致しません");
  }

  const standardById = new Map(standard.commands.map((command) => [command.id, command]));
  const recordByKey = new Map(records.map((record) => [`${record.file}/${record.id}`, record]));
  const nativeCommands = standard.commands.filter((command) => command.status === "native");
  const nativeIds = new Set(nativeCommands.map((command) => command.id));
  const nativeNames = new Set(nativeCommands.map((command) => command.name));
  if (!Array.isArray(evidence.fixtures) || evidence.fixtures.length !== evidence.scope.fixtureCount) {
    throw new Error("dispatch coverage証拠のfixture件数が不正です");
  }
  const fixtureReports = new Map();
  for (const report of evidence.fixtures) {
    assertKnownObjectKeys(report, ["id", "file", "sourceSha256", "associatedCommandNames", "associationWithoutDispatch", "observedStaticCommandNames", "observedDispatchCommandNames", "dispatchExpectations", "officialComparison", "interpreter", "aot"], "dispatch-coverage-evidence.fixture");
    const key = `${report.file}/${report.id}`;
    if (fixtureReports.has(key)) throw new Error(`dispatch coverage証拠のfixtureが重複しています: ${key}`);
    const fixture = records.find((candidate) => candidate.id === report.id && candidate.file === report.file);
    if (fixture === undefined || !hashPattern.test(report.sourceSha256) || report.sourceSha256 !== fixture.sourceSha256 ||
        !Array.isArray(report.associatedCommandNames) || new Set(report.associatedCommandNames).size !== report.associatedCommandNames.length ||
        report.associatedCommandNames.some((name) => !standard.commands.some((command) => command.name === name)) ||
        !Array.isArray(report.observedStaticCommandNames) || !Array.isArray(report.observedDispatchCommandNames) ||
        !Array.isArray(report.dispatchExpectations) || JSON.stringify(report.dispatchExpectations) !== JSON.stringify(fixture.dispatchExpectations ?? []) ||
        !Array.isArray(report.associationWithoutDispatch)) {
      throw new Error(`dispatch coverage証拠のfixture identityが不正です: ${key}`);
    }
    validateDispatchExpectations(report.dispatchExpectations, fixture.commandNames, `${key}.dispatchExpectations`);
    validateCoverageComparison(report.officialComparison, hashPattern, key, fixture);
    assertKnownObjectKeys(report.interpreter, ["dispatchEventCount", "staticSuccessSiteCount", "expectedFailureSiteCount", "expectedFailureDispatchCount", "staticSiteWithoutAotManifestCount", "traceSha256"], `${key}.interpreter`);
    assertKnownObjectKeys(report.aot, ["manifestEntryCount", "dispatchAttemptCount", "dispatchResultCount", "staticSuccessSiteCount", "expectedFailureSiteCount", "expectedFailureDispatchCount", "failedDispatchCount", "traceSha256", "compileManifestSha256"], `${key}.aot`);
    if (!Number.isSafeInteger(report.interpreter.dispatchEventCount) || report.interpreter.dispatchEventCount < 1 ||
        !Number.isSafeInteger(report.interpreter.staticSuccessSiteCount) || report.interpreter.staticSuccessSiteCount < 0 ||
        !Number.isSafeInteger(report.interpreter.expectedFailureSiteCount) || report.interpreter.expectedFailureSiteCount < 0 ||
        !Number.isSafeInteger(report.interpreter.expectedFailureDispatchCount) || report.interpreter.expectedFailureDispatchCount < 0 ||
        !Number.isSafeInteger(report.interpreter.staticSiteWithoutAotManifestCount) || report.interpreter.staticSiteWithoutAotManifestCount < 0 ||
        !hashPattern.test(report.interpreter.traceSha256) ||
        !Number.isSafeInteger(report.aot.manifestEntryCount) || report.aot.manifestEntryCount < 1 ||
        !Number.isSafeInteger(report.aot.dispatchAttemptCount) || report.aot.dispatchAttemptCount < 1 ||
        report.aot.dispatchAttemptCount !== report.aot.dispatchResultCount ||
        !Number.isSafeInteger(report.aot.staticSuccessSiteCount) || report.aot.staticSuccessSiteCount < 0 ||
        !Number.isSafeInteger(report.aot.expectedFailureSiteCount) || report.aot.expectedFailureSiteCount < 0 ||
        !Number.isSafeInteger(report.aot.expectedFailureDispatchCount) || report.aot.expectedFailureDispatchCount < 0 ||
        !Number.isSafeInteger(report.aot.failedDispatchCount) || report.aot.failedDispatchCount < 0 ||
        !hashPattern.test(report.aot.traceSha256) || !hashPattern.test(report.aot.compileManifestSha256)) {
      throw new Error(`dispatch coverage証拠のfixture trace件数が不正です: ${key}`);
    }
    fixtureReports.set(key, report);
  }

  assertKnownObjectKeys(evidence.coverage, ["unambiguousObservedNativeEntries", "unambiguousObservedNativeUniqueNames", "unambiguousObservedNativeEntryRatio", "unambiguousObservedNativeUniqueNameRatio", "unobservedNativeEntryIds", "unobservedNativeNames", "unresolvedObservedSites", "unresolvedObservedNames", "associationWithoutDispatchCount", "associationWithoutDispatch"], "dispatch-coverage-evidence.coverage");
  if (!Array.isArray(evidence.sites) || evidence.sites.length === 0) throw new Error("dispatch coverage証拠にsiteがありません");
  const siteKeys = new Set();
  const observedIds = new Set();
  const observedNames = new Set();
  const sitesByFixture = new Map();
  const unresolvedSitesByFixture = new Map();
  if (!Array.isArray(evidence.coverage.unresolvedObservedSites)) throw new Error("dispatch coverage証拠の未解決site一覧が不正です");
  for (const unresolved of evidence.coverage.unresolvedObservedSites) {
    assertKnownObjectKeys(unresolved, ["fixtureId", "file", "siteId", "sourceName", "canonicalOpcode", "opcode", "route", "runtimeRoutes", "interpreterRoutes", "interpreterCount", "aotCount", "result", "candidateCatalogIds"], "dispatch-coverage-evidence.coverage.unresolvedObservedSites");
    if (typeof unresolved.fixtureId !== "string" || typeof unresolved.file !== "string" || typeof unresolved.siteId !== "string" ||
        !/^0x[0-9a-f]{16}$/.test(unresolved.siteId) || typeof unresolved.sourceName !== "string" || unresolved.sourceName.length === 0 ||
        typeof unresolved.canonicalOpcode !== "string" || unresolved.canonicalOpcode.length === 0 || !Number.isInteger(unresolved.opcode) ||
        unresolved.opcode < 0 || unresolved.opcode > 0xffff || typeof unresolved.route !== "string" || unresolved.route.length === 0 ||
        !Array.isArray(unresolved.runtimeRoutes) || unresolved.runtimeRoutes.length === 0 || unresolved.runtimeRoutes.some((route) => typeof route !== "string" || route.length === 0) ||
        !Array.isArray(unresolved.interpreterRoutes) || unresolved.interpreterRoutes.length === 0 || unresolved.interpreterRoutes.some((route) => typeof route !== "string" || route.length === 0) ||
        !Number.isSafeInteger(unresolved.interpreterCount) || unresolved.interpreterCount < 1 || !Number.isSafeInteger(unresolved.aotCount) || unresolved.aotCount < 1 ||
        !new Set(["success", "failure"]).has(unresolved.result) || !Array.isArray(unresolved.candidateCatalogIds) ||
        unresolved.candidateCatalogIds.some((id) => typeof id !== "string" || id.length === 0)) {
      throw new Error(`dispatch coverage証拠の未解決site metadataが不正です: ${unresolved.file}/${unresolved.fixtureId}/${unresolved.siteId}`);
    }
    const fixtureKey = `${unresolved.file}/${unresolved.fixtureId}`;
    const unresolvedSites = unresolvedSitesByFixture.get(fixtureKey) ?? [];
    unresolvedSites.push(unresolved);
    unresolvedSitesByFixture.set(fixtureKey, unresolvedSites);
  }
  for (const site of evidence.sites) {
    assertKnownObjectKeys(site, ["fixtureId", "file", "siteId", "sourceName", "canonicalOpcode", "opcode", "route", "runtimeRoutes", "interpreterRoutes", "interpreterCount", "aotCount", "result", "catalogId", "name", "plugin", "catalogStatus", "resolution", "selectedOracleEquivalent"], "dispatch-coverage-evidence.site");
    const hasStringIdentity = ["fixtureId", "file", "siteId", "sourceName", "canonicalOpcode", "route", "catalogId", "name", "plugin", "catalogStatus", "resolution"]
      .every((key) => typeof site[key] === "string");
    const siteKey = hasStringIdentity ? coverageSiteKey(site) : "<invalid-site>";
    const fixtureKey = typeof site.file === "string" && typeof site.fixtureId === "string" ? `${site.file}/${site.fixtureId}` : "<invalid-fixture>";
    const fixtureReport = fixtureReports.get(fixtureKey);
    const fixtureRecord = recordByKey.get(fixtureKey);
    const expectedFailure = fixtureReport?.dispatchExpectations.find((expectation) =>
      expectation.command === site.name && dispatchExpectationIsActive(expectation, evidence.provenance.environment.platform));
    const expectedResult = expectedFailure === undefined ? "success" : expectedFailure.result;
    if (!hasStringIdentity || !fixtureReports.has(fixtureKey) || site.file.length === 0 || site.fixtureId.length === 0 || !/^0x[0-9a-f]{16}$/.test(site.siteId) ||
        siteKeys.has(siteKey) || site.sourceName !== site.name || site.canonicalOpcode.length === 0 || !Number.isInteger(site.opcode) || site.opcode < 0 || site.opcode > 0xffff ||
        site.route.length === 0 || !Array.isArray(site.runtimeRoutes) || site.runtimeRoutes.length === 0 || site.runtimeRoutes.some((route) => typeof route !== "string" || route.length === 0) ||
        !Array.isArray(site.interpreterRoutes) || site.interpreterRoutes.length === 0 || site.interpreterRoutes.some((route) => typeof route !== "string" || route.length === 0) ||
        !Number.isSafeInteger(site.interpreterCount) || site.interpreterCount < 1 || !Number.isSafeInteger(site.aotCount) || site.aotCount < 1 ||
        !new Set(["success", "failure"]).has(site.result) || site.result !== expectedResult ||
        ((site.result === "failure") !== (expectedFailure !== undefined ||
          (site.canonicalOpcode === "throw_statement" && site.route === "throw" && site.opcode === throwStatementOpcode))) ||
        site.catalogStatus !== "native" || !["unique-name", "explicit-catalog-id"].includes(site.resolution) ||
        (site.resolution === "explicit-catalog-id" && fixtureRecord?.catalogIds?.get(site.name) !== site.catalogId) ||
        site.selectedOracleEquivalent !== true) {
      throw new Error(`dispatch coverage証拠のsite metadataが不正です: ${siteKey}`);
    }
    const command = standardById.get(site.catalogId);
    if (command === undefined || !nativeIds.has(command.id) || command.name !== site.name || command.plugin !== site.plugin || site.catalogStatus !== "native") {
      throw new Error(`dispatch coverage証拠のcatalog identityが不正です: ${siteKey}`);
    }
    siteKeys.add(siteKey);
    observedIds.add(site.catalogId);
    observedNames.add(site.name);
    const fixtureSites = sitesByFixture.get(fixtureKey) ?? [];
    fixtureSites.push(site);
    sitesByFixture.set(fixtureKey, fixtureSites);
  }
  for (const [fixtureKey, report] of fixtureReports) {
    const fixtureRecord = recordByKey.get(fixtureKey);
    const unresolvedSites = unresolvedSitesByFixture.get(fixtureKey) ?? [];
    const allObservedSites = [...(sitesByFixture.get(fixtureKey) ?? []), ...unresolvedSites];
    const observedDispatchNames = [...new Set(allObservedSites.map((site) => site.name ?? site.sourceName))].sort();
    const observedStaticNames = [...new Set(allObservedSites.filter((site) => site.result === "success").map((site) => site.name ?? site.sourceName))].sort();
    if (!Array.isArray(report.observedDispatchCommandNames) || JSON.stringify([...report.observedDispatchCommandNames].sort()) !== JSON.stringify(observedDispatchNames) ||
        JSON.stringify([...report.observedStaticCommandNames].sort()) !== JSON.stringify(observedStaticNames) ||
        report.observedStaticCommandNames.some((name) => !report.observedDispatchCommandNames.includes(name))) {
      throw new Error(`dispatch coverage証拠のfixture command集計がsite集合と一致しません: ${fixtureKey}`);
    }
    if (fixtureRecord?.expectedDispatchRoute !== null) {
      const expectedNames = fixtureRecord.commandNames;
      const expectedSites = allObservedSites.filter((site) => expectedNames.has(site.name ?? site.sourceName));
      const missingNames = [...expectedNames].filter((name) => !expectedSites.some((site) => (site.name ?? site.sourceName) === name));
      if (missingNames.length > 0 || expectedSites.some((site) => site.route !== fixtureRecord.expectedDispatchRoute ||
          JSON.stringify(site.runtimeRoutes) !== JSON.stringify([fixtureRecord.expectedDispatchRoute]) ||
          JSON.stringify(site.interpreterRoutes) !== JSON.stringify([fixtureRecord.expectedDispatchRoute]))) {
        throw new Error(`dispatch coverage証拠のexpectedDispatchRouteが不一致です: ${fixtureKey}`);
      }
    }
    const fixtureSites = allObservedSites;
    const expectedFailureSites = fixtureSites.filter((site) => site.result === "failure");
    const expectedFailureSiteCount = expectedFailureSites.length;
    const expectedFailureInterpreterCount = expectedFailureSites.reduce((count, site) => count + site.interpreterCount, 0);
    const expectedFailureAotCount = expectedFailureSites.reduce((count, site) => count + site.aotCount, 0);
    const expectedSuccessSiteCount = fixtureSites.filter((site) => site.result === "success").length;
    if (report.interpreter.staticSuccessSiteCount !== expectedSuccessSiteCount ||
        report.aot.staticSuccessSiteCount !== report.interpreter.staticSuccessSiteCount ||
        report.interpreter.expectedFailureSiteCount !== expectedFailureSiteCount || report.aot.expectedFailureSiteCount !== expectedFailureSiteCount ||
        report.interpreter.expectedFailureDispatchCount !== expectedFailureInterpreterCount || report.aot.expectedFailureDispatchCount !== expectedFailureAotCount) {
      throw new Error(`dispatch coverage証拠のfixture dispatch結果集計がsite集合と一致しません: ${fixtureKey}`);
    }
    for (const expectation of report.dispatchExpectations.filter((candidate) =>
      dispatchExpectationIsActive(candidate, evidence.provenance.environment.platform))) {
      const expectedSites = expectedFailureSites.filter((site) => site.name === expectation.command);
      const interpreterCount = expectedSites.reduce((count, site) => count + site.interpreterCount, 0);
      const aotCount = expectedSites.reduce((count, site) => count + site.aotCount, 0);
      if (expectedSites.length === 0 || interpreterCount !== expectation.count || aotCount !== expectation.count) {
        throw new Error(`dispatch coverage証拠の期待失敗結果が不一致です: ${fixtureKey}/${expectation.command}`);
      }
    }
  }
  const expectedUnobservedIds = nativeCommands.filter((command) => !observedIds.has(command.id)).map((command) => command.id);
  const expectedUnobservedNames = nativeCommands.map((command) => command.name).filter((name, index, values) => values.indexOf(name) === index && !observedNames.has(name));
  if (evidence.coverage.unambiguousObservedNativeEntries !== observedIds.size || evidence.coverage.unambiguousObservedNativeUniqueNames !== observedNames.size ||
      evidence.coverage.unambiguousObservedNativeEntryRatio !== observedIds.size / nativeCommands.length ||
      evidence.coverage.unambiguousObservedNativeUniqueNameRatio !== observedNames.size / nativeNames.size ||
      JSON.stringify(evidence.coverage.unobservedNativeEntryIds) !== JSON.stringify(expectedUnobservedIds) ||
      JSON.stringify(evidence.coverage.unobservedNativeNames) !== JSON.stringify(expectedUnobservedNames) ||
      !Number.isSafeInteger(evidence.coverage.associationWithoutDispatchCount) || evidence.coverage.associationWithoutDispatchCount < 0 ||
      !Array.isArray(evidence.coverage.unresolvedObservedSites) || !Array.isArray(evidence.coverage.unresolvedObservedNames) ||
      !Array.isArray(evidence.coverage.associationWithoutDispatch) || evidence.coverage.associationWithoutDispatch.length !== evidence.coverage.associationWithoutDispatchCount) {
    throw new Error("dispatch coverage証拠の集計がsite集合と一致しません");
  }
}

function validateCoverageComparison(comparison, hashPattern, fixtureKey, fixture) {
  assertKnownObjectKeys(comparison, ["oracle", "routes", "selectedOracleEquivalent", "officialGeneratedAvailable", "officialGeneratedRouteUnavailableReason", "officialRoutesEquivalent", "officialSourceStderrIncludes", "results"], `${fixtureKey}.officialComparison`);
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  if (!new Set(["officialSource", "officialGenerated"]).has(comparison.oracle) || JSON.stringify(comparison.routes) !== JSON.stringify(expectedRoutes) || comparison.selectedOracleEquivalent !== true ||
      typeof comparison.officialGeneratedAvailable !== "boolean" || (comparison.officialGeneratedAvailable && comparison.officialGeneratedRouteUnavailableReason !== null) ||
      (!comparison.officialGeneratedAvailable && typeof comparison.officialGeneratedRouteUnavailableReason !== "string") ||
      typeof comparison.officialRoutesEquivalent !== "boolean" ||
      comparison.officialSourceStderrIncludes !== (fixture.officialSourceStderrIncludes ?? null)) {
    throw new Error(`dispatch coverage証拠の公式差分metadataが不正です: ${fixtureKey}`);
  }
  assertKnownObjectKeys(comparison.results, expectedRoutes, `${fixtureKey}.officialComparison.results`);
  const source = comparison.results.officialSource;
  const selected = comparison.results[comparison.oracle];
  const httpServerComparison = fixtureKey === "http-server-dispatch-cases.json/plugin-httpserver-dispatch";
  for (const route of expectedRoutes) {
    const result = comparison.results[route];
    assertKnownObjectKeys(result, httpServerComparison
      ? ["status", "signal", "stdoutSha256", "stderrSha256", "responseCount", "responseSha256"]
      : ["status", "signal", "stdoutSha256", "stderrSha256"], `${fixtureKey}.officialComparison.results.${route}`);
    if (!Number.isInteger(result.status) || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) ||
        (httpServerComparison && (!Number.isSafeInteger(result.responseCount) || result.responseCount < 0 ||
          (result.responseSha256 !== null && !hashPattern.test(result.responseSha256))))) {
      throw new Error(`dispatch coverage証拠の公式差分結果が不正です: ${fixtureKey}/${route}`);
    }
  }
  if (httpServerComparison) {
    for (const route of ["officialSource", "lnakoRun", "lnakoNativeO0"]) {
      const result = comparison.results[route];
      if (result.status !== 0 || result.signal !== null || result.responseCount !== source.responseCount || result.responseSha256 !== source.responseSha256) {
        throw new Error(`dispatch coverage証拠のHTTP応答結果が不一致です: ${fixtureKey}/${route}`);
      }
    }
  } else {
    for (const route of [comparison.oracle, "lnakoRun", "lnakoNativeO0"]) {
      const result = comparison.results[route];
      const diagnosticDifferenceAllowed = comparison.oracle === "officialSource" && comparison.officialSourceStderrIncludes !== null;
      if (result.status !== 0 || result.signal !== null || result.stdoutSha256 !== selected.stdoutSha256 ||
          (!diagnosticDifferenceAllowed && result.stderrSha256 !== selected.stderrSha256)) {
        throw new Error(`dispatch coverage証拠のsource差分結果が不一致です: ${fixtureKey}/${route}`);
      }
    }
  }
  const generated = comparison.results.officialGenerated;
  if (comparison.officialGeneratedAvailable) {
    if (generated.status !== 0 || generated.signal !== null) {
      throw new Error(`dispatch coverage証拠のgenerated成功状態が不正です: ${fixtureKey}`);
    }
    if (httpServerComparison && (generated.responseCount !== source.responseCount || generated.responseSha256 !== source.responseSha256)) {
      throw new Error(`dispatch coverage証拠のgenerated HTTP応答結果が不一致です: ${fixtureKey}`);
    }
  } else if (generated.status === 0 || generated.signal !== null || (httpServerComparison && generated.responseCount !== 0) ||
      (httpServerComparison && generated.responseSha256 !== null)) {
    throw new Error(`dispatch coverage証拠のgenerated unavailable状態が不正です: ${fixtureKey}`);
  }
}

function validateDispatchExpectations(expectations, commandNames, label) {
  if (!Array.isArray(expectations)) throw new Error(`dispatchExpectationsが配列ではありません: ${label}`);
  const expectedCommands = new Set();
  for (const expectation of expectations) {
    if (expectation === null || typeof expectation !== "object" || Array.isArray(expectation) ||
        Object.keys(expectation).some((key) => !new Set(["command", "result", "count", "platforms"]).has(key)) ||
        typeof expectation.command !== "string" || !commandNames.has(expectation.command) ||
        expectedCommands.has(expectation.command) || expectation.result !== "failure" ||
        !Number.isSafeInteger(expectation.count) || expectation.count < 1 || !validDispatchExpectationPlatforms(expectation.platforms)) {
      throw new Error(`dispatchExpectationsが不正です: ${label}`);
    }
    expectedCommands.add(expectation.command);
  }
}

function dispatchExpectationIsActive(expectation, platform) {
  return expectation.platforms === undefined || expectation.platforms.includes(platform);
}

function validDispatchExpectationPlatforms(platforms) {
  return platforms === undefined ||
    (Array.isArray(platforms) && platforms.length > 0 && new Set(platforms).size === platforms.length &&
      platforms.every((platform) => ["darwin", "linux", "win32"].includes(platform)));
}

function duplicateNameCount(entries) {
  return duplicateNameSet(entries).size;
}

function validateCatalog(lock, catalog, matrix, standard, implemented, catalogSourceSha256) {
  const baseline = lock?.nadesiko3;
  if (baseline === undefined) throw new Error("compat/upstream.lock.jsonにnadesiko3基準がありません");
  if (matrix.baseline?.tag !== baseline.tag || matrix.baseline?.commit !== baseline.commit) throw new Error("matrix.jsonのbaselineがupstream.lock.jsonと一致しません");
  if (standard.baseline?.tag !== baseline.tag || standard.baseline?.commit !== baseline.commit) throw new Error("standard-cnako.jsonのbaselineがupstream.lock.jsonと一致しません");
  if (matrix.sourceSha256 !== baseline.commandList.sha256 || catalogSourceSha256 !== baseline.commandList.sha256) throw new Error("公式命令カタログのSHA-256がupstream.lock.jsonと一致しません");
  if (!Array.isArray(catalog) || catalog.length !== 1145) throw new Error(`公式命令カタログが1145件ではありません: ${catalog?.length}`);
  if (!Array.isArray(matrix.entries) || matrix.entries.length !== catalog.length) throw new Error("matrix.jsonと公式命令カタログの件数が一致しません");
  if (!Array.isArray(standard.commands) || standard.commands.length !== 527) throw new Error(`標準cnako命令が527件ではありません: ${standard?.commands?.length}`);
  const matrixById = new Map();
  for (let index = 0; index < catalog.length; index += 1) {
    const source = catalog[index];
    const entry = matrix.entries[index];
    const expectedId = `command-${String(index + 1).padStart(4, "0")}`;
    if (entry.id !== expectedId) throw new Error(`matrix.jsonのカタログIDが不一致です: ${index + 1}`);
    for (const [matrixField, catalogField] of [["name", "name"], ["plugin", "plugin"], ["group", "group"], ["targets", "target"], ["type", "type"], ["args", "args"], ["category", "category"]]) {
      if (JSON.stringify(entry[matrixField]) !== JSON.stringify(source[catalogField])) throw new Error(`matrix.jsonと公式カタログの${matrixField}が不一致です: ${index + 1}`);
    }
    if (matrixById.has(entry.id)) throw new Error(`matrix.jsonのcatalog IDが重複しています: ${entry.id}`);
    matrixById.set(entry.id, entry);
  }
  const ids = new Set(standard.commands.map((command) => command.id));
  if (ids.size !== standard.commands.length) throw new Error("standard-cnako.jsonのcatalog IDが重複しています");
  const duplicateNames = duplicateNameCount(standard.commands);
  if (duplicateNames !== 31) throw new Error(`標準cnakoの重複命令名が31件ではありません: ${duplicateNames}`);
  const matrixFields = ["id", "name", "plugin", "group", "targets", "type", "args", "category", "scope", "plannedMode", "status", "tests", "platforms", "reason"];
  for (const command of standard.commands) {
    const matrixEntry = matrixById.get(command.id);
    if (matrixEntry === undefined) throw new Error(`standard-cnako.jsonのIDがmatrix.jsonにありません: ${command.id}`);
    for (const field of matrixFields) if (JSON.stringify(command[field]) !== JSON.stringify(matrixEntry[field])) throw new Error(`standard-cnako.jsonとmatrix.jsonの${field}が不一致です: ${command.id}`);
  }
  for (const name of Object.keys(implemented)) if (!standard.commands.some((command) => command.name === name)) throw new Error(`実装台帳の命令が標準cnakoにありません: ${name}`);
}

function rejectForbiddenEvidenceFields(value, path = "evidence") {
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) rejectForbiddenEvidenceFields(item, `${path}[${index}]`);
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (forbiddenEvidenceFields.has(key)) throw new Error(`証拠に禁止fieldがあります: ${path}.${key}`);
    rejectForbiddenEvidenceFields(item, `${path}.${key}`);
  }
}

function assertKnownObjectKeys(value, allowedKeys, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`証拠のobjectが不正です: ${path}`);
  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new Error(`証拠に未知fieldがあります: ${path}.${key}`);
}

function readGitState() {
  const commitResult = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (commitResult.status !== 0) throw new Error("現行lnakoのcommitを取得できません");
  const commit = commitResult.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("現行lnakoのcommit形式が不正です");
  const statusResult = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (statusResult.status !== 0) throw new Error("現行lnakoのdirty状態を取得できません");
  return { commit, dirty: statusResult.stdout.length > 0 };
}

function isAllowedDispatchEvidenceFollowUp(evidenceCommit, currentCommit) {
  if (evidenceCommit === currentCommit) return true;
  const ancestryResult = spawnSync("git", ["merge-base", "--is-ancestor", evidenceCommit, currentCommit], { cwd: root, encoding: "utf8" });
  if (ancestryResult.status !== 0) return false;
  const diffResult = spawnSync("git", ["diff", "--name-only", `${evidenceCommit}..${currentCommit}`], { cwd: root, encoding: "utf8" });
  if (diffResult.status !== 0) return false;
  const changedPaths = diffResult.stdout.split(/\r?\n/).filter((path) => path.length > 0);
  return changedPaths.length > 0 && changedPaths.every((path) => dispatchEvidenceFollowUpPaths.has(path));
}

function validateDispatchEvidence(evidence, lock, standard, records, inputSha256, inputPath, bundlePath, bundleBytes, historicalCommit = null) {
  rejectForbiddenEvidenceFields(evidence);
  assertKnownObjectKeys(evidence, ["schema", "generator", "baseline", "fixture", "officialComparison", "attestation", "provenance", "trace", "sites"], "dispatch-evidence");
  if (evidence?.schema !== "lnako.dispatch-evidence.v2" || evidence.generator !== "tools/check_dispatch_trace.mjs") {
    throw new Error("dispatch証拠のschemaまたは生成元が不正です");
  }
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "dispatch-evidence.baseline");
  if (evidence.baseline?.tag !== lock.nadesiko3.tag || evidence.baseline?.commit !== lock.nadesiko3.commit) {
    throw new Error("dispatch証拠のbaselineがupstream.lock.jsonと一致しません");
  }
  if (evidence.attestation !== null) validateAttestation(evidence.attestation, evidence, inputSha256, inputPath, bundlePath, bundleBytes);
  // Historical dispatch evidence may intentionally reference a fixture from
  // the attested commit rather than the current checkout. Reject an invalid
  // historical commit before comparing that historical fixture hash with the
  // current native-cases.json, so the security check remains about commit
  // identity instead of depending on later fixture edits.
  if (historicalCommit !== null && evidence?.provenance?.lnako?.commit !== historicalCommit) {
    throw new Error("--historical-commitとdispatch証拠のcommitが一致しません");
  }
  assertKnownObjectKeys(evidence.fixture, ["id", "file", "sourceSha256"], "dispatch-evidence.fixture");
  const fixture = records.find((record) => record.id === evidence.fixture?.id);
  if (fixture === undefined || fixture.file !== "native-cases.json") throw new Error("dispatch証拠のfixtureがnative-cases.jsonにありません");
  if (evidence.fixture.file !== fixture.file || evidence.fixture.sourceSha256 !== fixture.sourceSha256) throw new Error("dispatch証拠のfixture source SHA-256が一致しません");
  const configuredCatalogIds = fixture.catalogIds ?? new Map();
  const comparison = evidence.officialComparison;
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  assertKnownObjectKeys(comparison, ["oracle", "routes", "equivalent", "results"], "dispatch-evidence.officialComparison");
  assertKnownObjectKeys(comparison.results, expectedRoutes, "dispatch-evidence.officialComparison.results");
  if (comparison?.oracle !== "official-source" || comparison.equivalent !== true || JSON.stringify(comparison.routes) !== JSON.stringify(expectedRoutes)) {
    throw new Error("dispatch証拠の公式差分比較が不完全です");
  }
  const hashPattern = /^[0-9a-f]{64}$/;
  const officialSourceResult = comparison.results?.officialSource;
  for (const route of expectedRoutes) {
    const result = comparison.results?.[route];
    assertKnownObjectKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `dispatch-evidence.officialComparison.results.${route}`);
    if (result?.status !== 0 || result.signal !== null || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) || result.stdoutSha256 !== officialSourceResult?.stdoutSha256 || result.stderrSha256 !== officialSourceResult?.stderrSha256) {
      throw new Error(`dispatch証拠の公式差分結果が不正です: ${route}`);
    }
  }
  if (evidence.trace?.interpreter?.schema !== 2 || evidence.trace?.aot?.schema !== 2 || !Number.isSafeInteger(evidence.trace.interpreter.eventCount) || evidence.trace.interpreter.eventCount < 1 || !Number.isSafeInteger(evidence.trace.aot.eventCount) || evidence.trace.aot.eventCount < 1) {
    throw new Error("dispatch証拠のtrace schemaまたは件数が不正です");
  }
  assertKnownObjectKeys(evidence.trace, ["interpreter", "aot"], "dispatch-evidence.trace");
  assertKnownObjectKeys(evidence.trace.interpreter, ["schema", "eventCount"], "dispatch-evidence.trace.interpreter");
  assertKnownObjectKeys(evidence.trace.aot, ["schema", "eventCount"], "dispatch-evidence.trace.aot");
  if (!Array.isArray(evidence.sites) || evidence.sites.length === 0) throw new Error("dispatch証拠にsiteがありません");
  if (evidence.sites.length > evidence.trace.interpreter.eventCount || evidence.trace.aot.eventCount < evidence.sites.length * 2) {
    throw new Error("dispatch証拠のsite数がtrace eventCountと整合しません");
  }
  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "dispatch-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "dispatch-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "dispatch-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "dispatch-evidence.provenance.lnako");
  assertKnownObjectKeys(evidence.provenance.raw, ["interpreterTraceSha256", "aotTraceSha256", "compileManifestSha256"], "dispatch-evidence.provenance.raw");
  const commitPattern = /^[0-9a-f]{40}$/i;
  if (![evidence.provenance.environment.platform, evidence.provenance.environment.arch, evidence.provenance.environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(evidence.provenance.oracle.build) || evidence.provenance.oracle.build < 1 || evidence.provenance.oracle.build !== lock.nadesiko3.oracleIdentity?.build || evidence.provenance.oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || evidence.provenance.oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 || evidence.provenance.oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || evidence.provenance.oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm || evidence.provenance.oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[evidence.provenance.environment.platform + "-" + evidence.provenance.environment.arch] ||
      !hashPattern.test(evidence.provenance.oracle.cliSha256) || !hashPattern.test(evidence.provenance.oracle.markerSha256) || !hashPattern.test(evidence.provenance.oracle.treeSha256) ||
      !hashPattern.test(evidence.provenance.lnako.binarySha256) || !commitPattern.test(evidence.provenance.lnako.commit) || typeof evidence.provenance.lnako.dirty !== "boolean" ||
      !hashPattern.test(evidence.provenance.raw.interpreterTraceSha256) || !hashPattern.test(evidence.provenance.raw.aotTraceSha256) || !hashPattern.test(evidence.provenance.raw.compileManifestSha256)) {
    throw new Error("dispatch証拠のprovenanceが不正です");
  }
  const currentGit = readGitState();
  if (evidence.provenance.lnako.commit !== currentGit.commit && evidence.provenance.lnako.dirty !== true && historicalCommit !== evidence.provenance.lnako.commit &&
      !isAllowedDispatchEvidenceFollowUp(evidence.provenance.lnako.commit, currentGit.commit)) {
    throw new Error("cleanなdispatch証拠のlnako commitが現行HEADと一致しません");
  }
  const standardById = new Map(standard.commands.map((command) => [command.id, command]));
  const siteIds = new Set();
  const catalogIds = new Set();
  const expectedNames = new Set(fixture.commandNames);
  for (const site of evidence.sites) {
    assertKnownObjectKeys(site, ["catalogId", "name", "plugin", "siteId", "sourceName", "canonicalOpcode", "opcode", "route", "runtime", "officialEquivalent"], "dispatch-evidence.site");
    assertKnownObjectKeys(site.runtime, ["interpreter", "aot"], "dispatch-evidence.site.runtime");
    assertKnownObjectKeys(site.runtime.interpreter, ["result", "route", "count"], "dispatch-evidence.site.runtime.interpreter");
    assertKnownObjectKeys(site.runtime.aot, ["success", "callId", "count"], "dispatch-evidence.site.runtime.aot");
    if (siteIds.has(site.siteId) || typeof site.siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(site.siteId)) throw new Error(`dispatch証拠のsiteIdが不正または重複しています: ${site.siteId}`);
    siteIds.add(site.siteId);
    const command = standardById.get(site.catalogId);
    if (command === undefined || command.name !== site.name || command.plugin !== site.plugin || !expectedNames.has(site.name)) throw new Error(`dispatch証拠のcatalog identityが不正です: ${site.catalogId}`);
    const configuredCatalogId = configuredCatalogIds.get(site.name);
    if (duplicateNameSet(standard.commands).has(site.name) && configuredCatalogId !== site.catalogId) throw new Error(`明示catalog IDのない同名命令をdispatch証拠へ昇格できません: ${site.name}`);
    if (typeof site.sourceName !== "string" || site.sourceName !== site.name || typeof site.canonicalOpcode !== "string" || typeof site.route !== "string" || !Number.isInteger(site.opcode) || site.opcode < 0 || site.opcode > 0xffff) throw new Error(`dispatch証拠のdispatch metadataが不正です: ${site.siteId}`);
    if (site.runtime?.interpreter?.result !== "success" || typeof site.runtime.interpreter.route !== "string" || site.runtime.interpreter.route.length === 0 || !Number.isSafeInteger(site.runtime.interpreter.count) || site.runtime.interpreter.count < 1 || site.runtime?.aot?.success !== true || !Number.isSafeInteger(site.runtime.aot.callId) || !Number.isSafeInteger(site.runtime.aot.count) || site.runtime.aot.count < 1 || site.officialEquivalent !== true) throw new Error(`dispatch証拠のruntime成否が不正です: ${site.siteId}`);
    catalogIds.add(site.catalogId);
  }
  for (const name of expectedNames) if (![...catalogIds].some((id) => standardById.get(id)?.name === name)) throw new Error(`dispatch証拠に明示命令${name}のsiteがありません`);
}

function validateAttestation(attestation, evidence, inputSha256, inputPath, bundlePath, bundleBytes) {
  assertKnownObjectKeys(attestation, ["schema", "repository", "workflow", "sourceRef", "commit", "predicateType", "verifiedBy", "bundleSha256", "subjects"], "dispatch-evidence.attestation");
  if (attestation.schema !== "lnako.dispatch-attestation.v1" || attestation.repository !== "soramikan/lnako" ||
      attestation.workflow !== "soramikan/lnako/.github/workflows/ci.yml" || attestation.sourceRef !== "refs/heads/main" ||
      attestation.predicateType !== "https://slsa.dev/provenance/v1" || attestation.verifiedBy !== "gh attestation verify" ||
      !/^[0-9a-f]{40}$/i.test(attestation.commit) || !/^[0-9a-f]{64}$/.test(attestation.bundleSha256) || !Array.isArray(attestation.subjects) || bundlePath === null) {
    throw new Error("dispatch証拠のattestation identityが不正です");
  }
  const expectedPlatforms = new Set(["darwin-arm64", "linux-x64", "win32-x64"]);
  if (attestation.subjects.length !== expectedPlatforms.size) throw new Error("dispatch証拠のattestationが3正式OSを含みません");
  const seen = new Set();
  for (const subject of attestation.subjects) {
    assertKnownObjectKeys(subject, ["platform", "arch", "evidenceSha256"], "dispatch-evidence.attestation.subject");
    const platform = `${subject.platform}-${subject.arch}`;
    if (!expectedPlatforms.has(platform) || seen.has(platform) || !/^[0-9a-f]{64}$/.test(subject.evidenceSha256)) {
      throw new Error(`dispatch証拠のattestation subjectが不正です: ${platform}`);
    }
    seen.add(platform);
  }
  if (seen.size !== expectedPlatforms.size || attestation.commit !== evidence.provenance.lnako.commit || evidence.provenance.lnako.dirty !== false) {
    throw new Error("dispatch証拠のattestation commit、clean状態、またはOS集合が一致しません");
  }
  const currentPlatform = `${evidence.provenance.environment.platform}-${evidence.provenance.environment.arch}`;
  const currentSubject = attestation.subjects.find((subject) => `${subject.platform}-${subject.arch}` === currentPlatform);
  if (currentSubject === undefined || currentSubject.evidenceSha256 !== inputSha256) throw new Error(`dispatch証拠のattestation digestが一致しません: ${currentPlatform}`);
  verifyAttestationBundle(attestation, inputPath, bundlePath, bundleBytes);
}

function verifyAttestationBundle(attestation, inputPath, bundlePath, bundleBytes) {
  if (!Buffer.isBuffer(bundleBytes)) throw new Error("attestation bundleを読み込めません");
  if (createHash("sha256").update(bundleBytes).digest("hex") !== attestation.bundleSha256) {
    throw new Error("dispatch証拠のattestation bundle SHA-256が一致しません");
  }
  const result = spawnSync("gh", [
    "attestation", "verify", inputPath,
    "--bundle", bundlePath,
    "--repo", attestation.repository,
    "--signer-workflow", attestation.workflow,
    "--signer-digest", attestation.commit,
    "--source-digest", attestation.commit,
    "--source-ref", attestation.sourceRef,
    "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
    "--deny-self-hosted-runners",
    "--predicate-type", attestation.predicateType,
    "--format", "json",
  ], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`公式gh attestation verifyに失敗しました: ${result.stderr}`);
  let verified;
  try {
    verified = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`gh attestation verifyのJSON出力が不正です: ${error.message}`);
  }
  const expectedDigests = attestation.subjects.map((subject) => subject.evidenceSha256).sort();
  const matchesAllSubjects = Array.isArray(verified) && verified.some((entry) => {
    const subjects = entry.verificationResult?.statement?.subject;
    if (!Array.isArray(subjects)) return false;
    const parsedSubjects = subjects.map((subject) => ({ name: subject?.name, digest: attestedSha256(subject) }));
    if (parsedSubjects.some((subject) => subject.digest === null)) return false;
    const digests = parsedSubjects.map((subject) => subject.digest).sort();
    if (digests.length !== expectedDigests.length && digests.length !== expectedDigests.length + 1) return false;
    if (new Set(digests).size !== digests.length || expectedDigests.some((digest) => !digests.includes(digest))) return false;
    if (digests.length === expectedDigests.length + 1) {
      const extras = parsedSubjects.filter((subject) => !expectedDigests.includes(subject.digest));
      if (extras.length !== 1 || extras[0].name !== "lnako-native-aot-aggregate-evidence.json") return false;
    }
    return true;
  });
  if (!matchesAllSubjects) throw new Error("検証済みattestation bundleのdispatch subject digestが一致しません");
}

function attestedSha256(subject) {
  if (Array.isArray(subject?.digest)) {
    const entry = subject.digest.find((value) => value?.algorithm === "sha256" && /^[0-9a-f]{64}$/.test(value?.value));
    return entry?.value ?? null;
  }
  return /^[0-9a-f]{64}$/.test(subject?.digest?.sha256) ? subject.digest.sha256 : null;
}

function validateStaticConstantEvidence(evidence, lock, standard, records, definition) {
  rejectForbiddenEvidenceFields(evidence);
  assertKnownObjectKeys(evidence, ["schema", "generator", "baseline", "fixture", "officialComparison", "attestation", "provenance", "trace", "entries"], "static-constant-evidence");
  if (evidence.schema !== "lnako.static-constant-evidence.v2" || evidence.generator !== "tools/check_static_constant_evidence.mjs") {
    throw new Error("静的定数証拠のschemaまたは生成元が不正です");
  }
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "static-constant-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) {
    throw new Error("静的定数証拠のbaselineがupstream.lock.jsonと一致しません");
  }

  const fixture = records.find((record) => record.id === definition.fixtureId);
  if (fixture === undefined || fixture.file !== "native-cases.json") throw new Error("静的定数証拠のfixtureがnative-cases.jsonにありません");
  assertKnownObjectKeys(evidence.fixture, ["id", "file", "sourceSha256", "globalReadNames", "literalNames"], "static-constant-evidence.fixture");
  if (evidence.fixture.id !== fixture.id || evidence.fixture.file !== fixture.file || evidence.fixture.sourceSha256 !== fixture.sourceSha256) {
    throw new Error("静的定数証拠のfixture identityまたはsource SHA-256が一致しません");
  }
  const globalReadNames = evidence.fixture.globalReadNames;
  const literalNames = evidence.fixture.literalNames;
  const expectedStaticNames = definition.constantNames ?? fixture.commandNames;
  if (!Array.isArray(globalReadNames) || !Array.isArray(literalNames) ||
      globalReadNames.length !== definition.globalReadCount || literalNames.length !== definition.literalNames.size ||
      new Set(globalReadNames).size !== globalReadNames.length || new Set(literalNames).size !== literalNames.length ||
      literalNames.some((name) => !definition.literalNames.has(name)) ||
      globalReadNames.some((name) => definition.literalNames.has(name)) ||
      new Set([...globalReadNames, ...literalNames]).size !== expectedStaticNames.size ||
      [...expectedStaticNames].some((name) => !globalReadNames.includes(name) && !literalNames.includes(name))) {
    throw new Error("静的定数証拠のliteral/global分類が不正です");
  }

  const comparison = evidence.officialComparison;
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  assertKnownObjectKeys(comparison, ["oracle", "routes", "equivalent", "results"], "static-constant-evidence.officialComparison");
  assertKnownObjectKeys(comparison.results, expectedRoutes, "static-constant-evidence.officialComparison.results");
  if (!new Set(["official-source", "official-generated"]).has(comparison.oracle) || comparison.equivalent !== true || JSON.stringify(comparison.routes) !== JSON.stringify(expectedRoutes)) {
    throw new Error("静的定数証拠の公式差分比較が不完全です");
  }
  const hashPattern = /^[0-9a-f]{64}$/;
  const oracleRoute = comparison.oracle === "official-generated" ? "officialGenerated" : "officialSource";
  const oracleResult = comparison.results[oracleRoute];
  for (const route of expectedRoutes) {
    const result = comparison.results[route];
    assertKnownObjectKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `static-constant-evidence.officialComparison.results.${route}`);
    const compared = route === oracleRoute || route === "lnakoRun" || route === "lnakoNativeO0";
    if (result.status !== 0 || result.signal !== null || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) ||
        (compared && (result.stdoutSha256 !== oracleResult.stdoutSha256 || result.stderrSha256 !== oracleResult.stderrSha256))) {
      throw new Error(`静的定数証拠の公式差分結果が不正です: ${route}`);
    }
  }
  if (evidence.attestation !== null) throw new Error("静的定数証拠に未対応のattestationがあります");

  assertKnownObjectKeys(evidence.trace, ["global", "literal"], "static-constant-evidence.trace");
  for (const [kind, names, expectedEventCount] of [["global", globalReadNames, definition.globalTraceCount ?? globalReadNames.length], ["literal", literalNames, literalNames.length]]) {
    assertKnownObjectKeys(evidence.trace[kind], ["interpreter", "aot"], `static-constant-evidence.trace.${kind}`);
    for (const engine of ["interpreter", "aot"]) {
      assertKnownObjectKeys(evidence.trace[kind][engine], ["schema", "eventCount"], `static-constant-evidence.trace.${kind}.${engine}`);
      if (evidence.trace[kind][engine].schema !== 1 || evidence.trace[kind][engine].eventCount !== expectedEventCount) {
        throw new Error(`静的定数証拠の${kind}/${engine} trace件数が不正です`);
      }
    }
  }

  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "static-constant-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "static-constant-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "static-constant-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "static-constant-evidence.provenance.lnako");
  assertKnownObjectKeys(evidence.provenance.raw, ["interpreterTraceSha256", "aotTraceSha256", "globalManifestSha256", "literalInterpreterTraceSha256", "literalAotTraceSha256", "literalManifestSha256"], "static-constant-evidence.provenance.raw");
  const commitPattern = /^[0-9a-f]{40}$/i;
  const environment = evidence.provenance.environment;
  const oracle = evidence.provenance.oracle;
  const lnako = evidence.provenance.lnako;
  const raw = evidence.provenance.raw;
  const platformKey = `${environment.platform}-${environment.arch}`;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(oracle.build) || oracle.build < 1 || oracle.build !== lock.nadesiko3.oracleIdentity?.build ||
      oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 ||
      oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm ||
      oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[platformKey] ||
      !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) ||
      !hashPattern.test(lnako.binarySha256) || !commitPattern.test(lnako.commit) || lnako.dirty !== false ||
      !hashPattern.test(raw.interpreterTraceSha256) || !hashPattern.test(raw.aotTraceSha256) || !hashPattern.test(raw.globalManifestSha256) ||
      !hashPattern.test(raw.literalInterpreterTraceSha256) || !hashPattern.test(raw.literalAotTraceSha256) || !hashPattern.test(raw.literalManifestSha256)) {
    throw new Error("静的定数証拠のprovenanceが不正です");
  }
  const currentGit = readGitState();
  if (lnako.commit !== currentGit.commit && !isAllowedDispatchEvidenceFollowUp(lnako.commit, currentGit.commit)) {
    throw new Error("cleanな静的定数証拠のlnako commitが現行HEADと一致しません");
  }

  const standardById = new Map(standard.commands.map((command) => [command.id, command]));
  const standardByName = new Map();
  for (const command of standard.commands) {
    const commands = standardByName.get(command.name) ?? [];
    commands.push(command);
    standardByName.set(command.name, commands);
  }
  const configuredCatalogIds = definition.catalogIds ?? new Map();
  for (const [name, id] of configuredCatalogIds) {
    const command = standardById.get(id);
    if (!expectedStaticNames.has(name) || command?.name !== name) {
      throw new Error(`静的定数証拠のcatalog ID指定が不正です: ${name}/${id}`);
    }
  }
  if (!Array.isArray(evidence.entries) || evidence.entries.length !== globalReadNames.length + literalNames.length) throw new Error("静的定数証拠のentry数が不正です");
  const names = { global: new Set(), literal: new Set() };
  const catalogIds = new Set();
  const siteKeys = new Set();
  for (const entry of evidence.entries) {
    assertKnownObjectKeys(entry, ["catalogId", "name", "plugin", "kind", "siteId", "runtime", "officialEquivalent"], "static-constant-evidence.entry");
    assertKnownObjectKeys(entry.runtime, ["interpreter", "aot"], "static-constant-evidence.entry.runtime");
    assertKnownObjectKeys(entry.runtime.interpreter, ["success", "count"], "static-constant-evidence.entry.runtime.interpreter");
    assertKnownObjectKeys(entry.runtime.aot, ["success", "count"], "static-constant-evidence.entry.runtime.aot");
    const command = standardById.get(entry.catalogId);
    const commandsByName = standardByName.get(entry.name) ?? [];
    const expectedCatalogId = configuredCatalogIds.get(entry.name);
    const identityMatches = expectedCatalogId === undefined
      ? commandsByName.length === 1 && entry.catalogId === commandsByName[0].id
      : entry.catalogId === expectedCatalogId;
    const expectedNames = entry.kind === "global-read" ? globalReadNames : entry.kind === "literal" ? literalNames : null;
    const nameSet = entry.kind === "global-read" ? names.global : entry.kind === "literal" ? names.literal : null;
    const siteKey = `${entry.kind}:${entry.siteId}`;
    if (command === undefined || command.name !== entry.name || command.plugin !== entry.plugin || command.plugin !== expectedStaticConstantPlugin(definition, entry.name) ||
        command.type !== "定数" || command.status !== "native" || !identityMatches || expectedNames === null || !expectedNames.includes(entry.name) ||
        nameSet === null || nameSet.has(entry.name) || catalogIds.has(entry.catalogId) || siteKeys.has(siteKey) || !/^0x[0-9a-f]{16}$/.test(entry.siteId) ||
        entry.officialEquivalent !== true || entry.runtime.interpreter.success !== true || entry.runtime.interpreter.count !== 1 ||
        entry.runtime.aot.success !== true || entry.runtime.aot.count !== 1) {
      throw new Error(`静的定数証拠entryが不正です: ${entry.name}`);
    }
    nameSet.add(entry.name);
    catalogIds.add(entry.catalogId);
    siteKeys.add(siteKey);
  }
  if (names.global.size !== globalReadNames.length || names.literal.size !== literalNames.length || [...names.global].some((name) => !globalReadNames.includes(name)) || [...names.literal].some((name) => !literalNames.includes(name))) throw new Error("静的定数証拠のname集合が不一致です");
}

function expectedStaticConstantPlugin(definition, name) {
  return definition.commandPlugins?.[name] ?? definition.plugin;
}

function globalBindingDefinitions(definition) {
  return definition.bindings ?? [{ catalogId: definition.catalogId, name: definition.name, plugin: definition.plugin }];
}

function globalBindingAccesses(definition) {
  return definition.accesses ?? definition.accessKinds.map((kind) => ({
    catalogId: definition.catalogId,
    name: definition.name,
    plugin: definition.plugin,
    kind,
    phase: kind === "global-load" ? "global-read" : "global-write",
  }));
}

function validateGlobalBindingEvidence(evidence, lock, standard, records, definition) {
  const expectedBindings = globalBindingDefinitions(definition);
  const expectedAccesses = globalBindingAccesses(definition);
  const expectedSchema = definition.schema ?? "lnako.global-binding-evidence.v1";
  const bindingField = expectedBindings.length === 1 ? "binding" : "bindings";
  rejectForbiddenEvidenceFields(evidence);
  assertKnownObjectKeys(evidence, ["schema", "generator", "baseline", "fixture", bindingField, "officialComparison", "attestation", "provenance", "trace"], "global-binding-evidence");
  if (evidence.schema !== expectedSchema || evidence.generator !== "tools/check_global_binding_evidence.mjs") {
    throw new Error("global binding証拠のschemaまたは生成元が不正です");
  }
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "global-binding-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) {
    throw new Error("global binding証拠のbaselineがupstream.lock.jsonと一致しません");
  }

  const fixture = records.find((record) => record.id === definition.fixtureId && record.file === "native-cases.json");
  if (fixture === undefined) throw new Error(`global binding証拠のfixtureがnative-cases.jsonにありません: ${definition.fixtureId}`);
  assertKnownObjectKeys(evidence.fixture, ["id", "file", "sourceSha256"], "global-binding-evidence.fixture");
  if (evidence.fixture.id !== fixture.id || evidence.fixture.file !== fixture.file || evidence.fixture.sourceSha256 !== fixture.sourceSha256 || !/^[0-9a-f]{64}$/.test(evidence.fixture.sourceSha256)) {
    throw new Error("global binding証拠のfixture identityまたはsource SHA-256が一致しません");
  }

  for (const expectedBinding of expectedBindings) {
    const command = standard.commands.find((candidate) => candidate.id === expectedBinding.catalogId);
    if (command === undefined || command.name !== expectedBinding.name || command.plugin !== expectedBinding.plugin || command.status !== "native" || command.type !== (expectedBinding.type ?? "変数")) {
      throw new Error("global binding証拠のcatalog identityが標準カタログと一致しません");
    }
  }
  const actualBindings = expectedBindings.length === 1 ? [evidence.binding] : evidence.bindings;
  if (!Array.isArray(actualBindings) || actualBindings.length !== expectedBindings.length) throw new Error("global binding証拠のbinding数が不一致です");
  const siteIds = new Set();
  for (const [bindingIndex, expectedBinding] of expectedBindings.entries()) {
    const actualBinding = actualBindings[bindingIndex];
    const expectedSites = expectedAccesses.filter((access) => access.catalogId === expectedBinding.catalogId);
    assertKnownObjectKeys(actualBinding, ["catalogId", "name", "plugin", "accessSequence", "sites"], "global-binding-evidence.binding");
    if (actualBinding.catalogId !== expectedBinding.catalogId || actualBinding.name !== expectedBinding.name || actualBinding.plugin !== expectedBinding.plugin ||
        !Array.isArray(actualBinding.accessSequence) || JSON.stringify(actualBinding.accessSequence) !== JSON.stringify(expectedSites.map((site) => site.kind)) ||
        !Array.isArray(actualBinding.sites) || actualBinding.sites.length !== expectedSites.length) {
      throw new Error(`global binding証拠のbinding access sequenceが不一致です: ${bindingIndex}`);
    }
    actualBinding.sites.forEach((site, siteIndex) => {
      assertKnownObjectKeys(site, ["catalogId", "name", "plugin", "kind", "siteId"], "global-binding-evidence.site");
      const expected = expectedSites[siteIndex];
      if (site.catalogId !== expected.catalogId || site.name !== expected.name || site.plugin !== expected.plugin ||
          site.kind !== expected.kind || !/^0x[0-9a-f]{16}$/.test(site.siteId) || siteIds.has(site.siteId)) {
        throw new Error(`global binding証拠のsiteが不正です: ${bindingIndex}/${siteIndex}`);
      }
      siteIds.add(site.siteId);
    });
  }

  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  const comparison = evidence.officialComparison;
  assertKnownObjectKeys(comparison, ["oracle", "routes", "equivalent", "results"], "global-binding-evidence.officialComparison");
  assertKnownObjectKeys(comparison.results, expectedRoutes, "global-binding-evidence.officialComparison.results");
  if (comparison.oracle !== "official-source" || comparison.equivalent !== true || JSON.stringify(comparison.routes) !== JSON.stringify(expectedRoutes)) {
    throw new Error("global binding証拠の公式差分比較が不完全です");
  }
  const hashPattern = /^[0-9a-f]{64}$/;
  const oracleResult = comparison.results.officialSource;
  for (const route of expectedRoutes) {
    const result = comparison.results[route];
    assertKnownObjectKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `global-binding-evidence.officialComparison.results.${route}`);
    if (result.status !== 0 || result.signal !== null || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) ||
        result.stdoutSha256 !== oracleResult.stdoutSha256 || result.stderrSha256 !== oracleResult.stderrSha256) {
      throw new Error(`global binding証拠の公式差分結果が不正です: ${route}`);
    }
  }
  if (evidence.attestation !== null) throw new Error("global binding証拠に未対応のattestationがあります");

  assertKnownObjectKeys(evidence.trace, ["interpreter", "aot"], "global-binding-evidence.trace");
  for (const engine of ["interpreter", "aot"]) {
    assertKnownObjectKeys(evidence.trace[engine], ["schema", "eventCount"], `global-binding-evidence.trace.${engine}`);
    if (evidence.trace[engine].schema !== 1 || evidence.trace[engine].eventCount !== expectedAccesses.length) {
      throw new Error(`global binding証拠の${engine} trace件数が不正です`);
    }
  }

  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "global-binding-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "global-binding-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "global-binding-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "global-binding-evidence.provenance.lnako");
  assertKnownObjectKeys(evidence.provenance.raw, ["interpreterTraceSha256", "aotTraceSha256", "globalManifestSha256"], "global-binding-evidence.provenance.raw");
  const environment = evidence.provenance.environment;
  const oracle = evidence.provenance.oracle;
  const lnako = evidence.provenance.lnako;
  const raw = evidence.provenance.raw;
  const platformKey = `${environment.platform}-${environment.arch}`;
  const commitPattern = /^[0-9a-f]{40}$/i;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(oracle.build) || oracle.build < 1 || oracle.build !== lock.nadesiko3.oracleIdentity?.build ||
      oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 ||
      oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm ||
      oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[platformKey] ||
      !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) ||
      !hashPattern.test(lnako.binarySha256) || !commitPattern.test(lnako.commit) || lnako.dirty !== false ||
      !hashPattern.test(raw.interpreterTraceSha256) || !hashPattern.test(raw.aotTraceSha256) || !hashPattern.test(raw.globalManifestSha256)) {
    throw new Error("global binding証拠のprovenanceが不正です");
  }
  const currentGit = readGitState();
  if (lnako.commit !== currentGit.commit && !isAllowedDispatchEvidenceFollowUp(lnako.commit, currentGit.commit)) {
    throw new Error("cleanなglobal binding証拠のlnako commitが現行HEADと一致しません");
  }
}

function validateExpectedExitEvidence(evidence, lock, standard, records) {
  rejectForbiddenEvidenceFields(evidence, "expected-exit-evidence");
  assertKnownObjectKeys(evidence, ["schema", "generator", "baseline", "fixture", "officialComparison", "provenance", "entries"], "expected-exit-evidence");
  if (evidence.schema !== "lnako.expected-exit-evidence.v1" || evidence.generator !== "tools/check_node_exit_evidence.mjs") throw new Error("expected-exit証拠のschemaまたは生成元が不正です");
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "expected-exit-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) throw new Error("expected-exit証拠のbaselineがupstream.lock.jsonと一致しません");
  assertKnownObjectKeys(evidence.fixture, ["id", "files", "cases"], "expected-exit-evidence.fixture");
  if (evidence.fixture.id !== "node-exit-evidence" || JSON.stringify(evidence.fixture.files) !== JSON.stringify(["tests/oracle/node-exit-cases.json", "tests/oracle/node-interrupt-case.json"]) || !Array.isArray(evidence.fixture.cases) || evidence.fixture.cases.length !== 4) throw new Error("expected-exit証拠のfixture identityが不正です");
  assertKnownObjectKeys(evidence.officialComparison, ["routes", "equivalent"], "expected-exit-evidence.officialComparison");
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0", "lnakoNativeO1", "lnakoNativeO2", "lnakoNativeO3"];
  if (JSON.stringify(evidence.officialComparison.routes) !== JSON.stringify(expectedRoutes) || evidence.officialComparison.equivalent !== true) throw new Error("expected-exit証拠のroute集合が不正です");
  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "expected-exit-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "expected-exit-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "expected-exit-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "expected-exit-evidence.provenance.lnako");
  assertKnownObjectKeys(evidence.provenance.raw, ["traceSha256"], "expected-exit-evidence.provenance.raw");
  const environment = evidence.provenance.environment;
  const oracle = evidence.provenance.oracle;
  const lnako = evidence.provenance.lnako;
  const platformKey = `${environment.platform}-${environment.arch}`;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(oracle.build) || oracle.build < 1 || oracle.build !== lock.nadesiko3.oracleIdentity?.build ||
      oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 ||
      oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm ||
      oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[platformKey] ||
      !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) ||
      !hashPattern.test(lnako.binarySha256) || !/^[0-9a-f]{40}$/i.test(lnako.commit) || lnako.dirty !== false) {
    throw new Error("expected-exit証拠のprovenanceが不正です");
  }
  const currentGit = readGitState();
  if (lnako.commit !== currentGit.commit && !isAllowedDispatchEvidenceFollowUp(lnako.commit, currentGit.commit)) throw new Error("cleanなexpected-exit証拠のlnako commitが現行HEADと一致しません");
  const standardById = new Map(standard.commands.map((command) => [command.id, command]));
  const recordById = new Map(records.map((record) => [record.id, record]));
  const casesById = new Map();
  for (const item of evidence.fixture.cases) {
    assertKnownObjectKeys(item, ["id", "command", "catalogId", "sourceSha256"], "expected-exit-evidence.fixture.case");
    if (casesById.has(item.id) || !hashPattern.test(item.sourceSha256)) throw new Error(`expected-exit証拠のfixture caseが不正です: ${item.id}`);
    const record = recordById.get(item.id);
    const command = standardById.get(item.catalogId);
    if (record === undefined || record.sourceSha256 !== item.sourceSha256 || command === undefined || command.name !== item.command || command.plugin !== "plugin_node" || command.status !== "native" ||
        (duplicateNames.has(item.command) && record.catalogIds?.get(item.command) !== item.catalogId)) throw new Error(`expected-exit証拠のfixture caseがcatalog/fixtureと不一致です: ${item.id}`);
    casesById.set(item.id, item);
  }
  if (evidence.entries.length !== casesById.size) throw new Error("expected-exit証拠のentry数がfixture case数と一致しません");
  for (const entry of evidence.entries) {
    assertKnownObjectKeys(entry, ["caseId", "catalogId", "name", "plugin", "sourceSha256", "expectedExitCode", "terminalReason", "officialComparison", "site", "trace", "compileStatuses"], "expected-exit-evidence.entry");
    const fixtureCase = casesById.get(entry.caseId);
    const command = standardById.get(entry.catalogId);
    if (fixtureCase === undefined || command === undefined || entry.catalogId !== fixtureCase.catalogId || entry.name !== fixtureCase.command || entry.plugin !== "plugin_node" || entry.sourceSha256 !== fixtureCase.sourceSha256 || ![0, 7].includes(entry.expectedExitCode) || !["process-exit", "interrupt-callback"].includes(entry.terminalReason)) throw new Error(`expected-exit証拠entryのidentityが不正です: ${entry.caseId}`);
    assertKnownObjectKeys(entry.officialComparison, ["oracle", "routes", "equivalent", "results"], `expected-exit-evidence.entry(${entry.caseId}).officialComparison`);
    if (entry.officialComparison.oracle !== "official-source" || JSON.stringify(entry.officialComparison.routes) !== JSON.stringify(expectedRoutes) || entry.officialComparison.equivalent !== true) throw new Error(`expected-exit証拠entryの公式比較が不正です: ${entry.caseId}`);
    assertKnownObjectKeys(entry.officialComparison.results, expectedRoutes, `expected-exit-evidence.entry(${entry.caseId}).results`);
    const oracleResult = entry.officialComparison.results.officialSource;
    for (const route of expectedRoutes) {
      const result = entry.officialComparison.results[route];
      assertKnownObjectKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `expected-exit-evidence.entry(${entry.caseId}).result.${route}`);
      if (result.status !== entry.expectedExitCode || result.signal !== null || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) || result.stdoutSha256 !== oracleResult.stdoutSha256 || result.stderrSha256 !== oracleResult.stderrSha256) throw new Error(`expected-exit証拠entryのroute結果が不一致です: ${entry.caseId}/${route}`);
    }
    assertKnownObjectKeys(entry.site, ["siteId", "sourceName", "canonicalOpcode", "opcode", "route"], `expected-exit-evidence.entry(${entry.caseId}).site`);
    if (!siteIdPattern.test(entry.site.siteId) || entry.site.sourceName !== entry.name || entry.site.canonicalOpcode !== (entry.terminalReason === "interrupt-callback" ? "node_interrupt_callback" : entry.expectedExitCode === 7 ? "node_process_exit" : "node_exit") || !Number.isInteger(entry.site.opcode) || entry.site.opcode < 0 || entry.site.opcode > 0xffff || (entry.terminalReason === "interrupt-callback" ? entry.site.route !== "node-interrupt" : entry.site.route !== "builtin") || entry.site.siteId.length !== 18) throw new Error(`expected-exit証拠entryのsiteが不正です: ${entry.caseId}`);
    assertKnownObjectKeys(entry.trace, ["interpreter", "aot", "compileManifest"], `expected-exit-evidence.entry(${entry.caseId}).trace`);
    validateExpectedExitTraceSummary(entry.trace.interpreter, entry, "interpreter");
    for (const optimization of ["O0", "O1", "O2", "O3"]) validateExpectedExitTraceSummary(entry.trace.aot[optimization], entry, `aot-${optimization}`);
    assertKnownObjectKeys(entry.trace.compileManifest, ["complete", "entries", "rawSha256"], `expected-exit-evidence.entry(${entry.caseId}).compileManifest`);
    if (entry.trace.compileManifest.complete !== true || !Array.isArray(entry.trace.compileManifest.entries) || !hashPattern.test(entry.trace.compileManifest.rawSha256)) throw new Error(`expected-exit証拠entryのmanifestが不正です: ${entry.caseId}`);
    const manifestTarget = entry.trace.compileManifest.entries.find((candidate) => candidate.sourceName === entry.name);
    if (manifestTarget === undefined || manifestTarget.siteId !== entry.site.siteId || manifestTarget.sourceName !== entry.site.sourceName || manifestTarget.canonicalOpcode !== entry.site.canonicalOpcode || manifestTarget.opcode !== entry.site.opcode || manifestTarget.route !== entry.site.route) throw new Error(`expected-exit証拠entryのmanifest targetがsiteと不一致です: ${entry.caseId}`);
    const compileStatuses = entry.compileStatuses;
    assertKnownObjectKeys(compileStatuses, ["O0", "O1", "O2", "O3"], `expected-exit-evidence.entry(${entry.caseId}).compileStatuses`);
    if (Object.values(compileStatuses).some((status) => status !== 0)) throw new Error(`expected-exit証拠entryのcompile statusが不正です: ${entry.caseId}`);
  }
  if (new Set(evidence.entries.map((entry) => entry.catalogId)).size !== evidence.entries.length) throw new Error("expected-exit証拠のcatalog IDが重複しています");
  return casesById;
}

function validateExpectedExitTraceSummary(trace, entry, label) {
  assertKnownObjectKeys(trace, ["eventCount", "terminalReason", "exitCode", "signal", "target", "traceSha256"], `expected-exit-evidence.${label}`);
  if (!Number.isSafeInteger(trace.eventCount) || trace.eventCount < 1 || trace.terminalReason !== entry.terminalReason || trace.exitCode !== entry.expectedExitCode || trace.signal !== null || !hashPattern.test(trace.traceSha256)) throw new Error(`expected-exit証拠のtrace終端が不正です: ${entry.caseId}/${label}`);
  if (label === "interpreter") {
    assertKnownObjectKeys(trace.target, ["siteId", "sourceName", "route", "result", "count"], `expected-exit-evidence.${entry.caseId}.interpreter.target`);
    if (trace.target.siteId !== entry.site.siteId || trace.target.sourceName !== entry.name || trace.target.result !== "success" || !Number.isSafeInteger(trace.target.count) || trace.target.count < 1) throw new Error(`expected-exit証拠のInterpreter targetが不正です: ${entry.caseId}`);
  } else {
    assertKnownObjectKeys(trace.target, ["siteId", "sourceName", "canonicalOpcode", "opcode", "route", "result", "callId", "count", "unmatchedCallCount"], `expected-exit-evidence.${entry.caseId}.${label}.target`);
    if (trace.target.siteId !== entry.site.siteId || trace.target.sourceName !== entry.name || trace.target.canonicalOpcode !== entry.site.canonicalOpcode || trace.target.opcode !== entry.site.opcode || trace.target.route !== entry.site.route || trace.target.result !== true || !Number.isSafeInteger(trace.target.callId) || !Number.isSafeInteger(trace.target.count) || trace.target.count < 1 || !Number.isSafeInteger(trace.target.unmatchedCallCount) || trace.target.unmatchedCallCount < 0 || (entry.terminalReason === "process-exit" && trace.target.unmatchedCallCount !== 0)) throw new Error(`expected-exit証拠のAOT targetが不正です: ${entry.caseId}/${label}`);
  }
}

function validateCompatJsEvidence(evidence, lock, standard, cases, records) {
  rejectForbiddenEvidenceFields(evidence, "compat-js-evidence");
  assertKnownObjectKeys(evidence, ["schema", "generator", "baseline", "scope", "officialComparison", "attestation", "provenance", "entries"], "compat-js-evidence");
  if (evidence.schema !== "lnako.compat-js-evidence.v1" || evidence.generator !== "tools/check_compat_js_evidence.mjs") throw new Error("compat-js証拠のschemaまたは生成元が不正です");
  assertKnownObjectKeys(evidence.baseline, ["tag", "commit"], "compat-js-evidence.baseline");
  if (evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) throw new Error("compat-js証拠のbaselineがupstream.lock.jsonと一致しません");

  const operationByName = new Map([
    ["JS実行", "eval"],
    ["JSオブジェクト取得", "lookup"],
    ["JS関数実行", "call"],
    ["JSメソッド実行", "method-call"],
  ]);
  const expectedCommands = standard.commands.filter((command) => command.plannedMode === "compat-js");
  const expectedNames = expectedCommands.map((command) => command.name).sort();
  assertKnownObjectKeys(evidence.scope, ["catalogEntries", "operations", "fixtureSelection", "caseCount", "successCaseCount", "expectedFailureCaseCount", "selectedProofCaseIds", "commandNames", "nativeDispatchEvidenceSeparate"], "compat-js-evidence.scope");
  if (evidence.scope.catalogEntries !== expectedCommands.length || JSON.stringify(evidence.scope.operations) !== JSON.stringify(["eval", "lookup", "call", "method-call"]) || JSON.stringify(evidence.scope.commandNames) !== JSON.stringify(expectedNames) || evidence.scope.caseCount !== cases.length || evidence.scope.successCaseCount + evidence.scope.expectedFailureCaseCount !== cases.length || !Array.isArray(evidence.scope.selectedProofCaseIds) || evidence.scope.nativeDispatchEvidenceSeparate !== true) throw new Error("compat-js証拠のscopeが不正です");
  if (evidence.attestation !== null) throw new Error("compat-js証拠のattestationは未対応です");

  const recordById = new Map(records.filter((record) => record.file === "compat-js-cases.json").map((record) => [record.id, record]));
  const caseById = new Map(cases.map((testCase) => [testCase.id, testCase]));
  const comparison = evidence.officialComparison;
  assertKnownObjectKeys(comparison, ["oracle", "routes", "equivalent", "comparisonRule", "cases"], "compat-js-evidence.officialComparison");
  if (comparison.oracle !== "official-source" || JSON.stringify(comparison.routes) !== JSON.stringify(["officialSource", "lnakoCompatJs"]) || comparison.equivalent !== true || typeof comparison.comparisonRule !== "string" || !Array.isArray(comparison.cases) || comparison.cases.length !== cases.length) throw new Error("compat-js公式比較のrouteまたはcase数が不正です");
  const comparisonIds = new Set();
  const proofCaseIds = [];
  for (const item of comparison.cases) {
    assertKnownObjectKeys(item, ["id", "fixture", "expectedFailure", "equivalent", "results", "trace"], "compat-js-evidence.case");
    const expected = caseById.get(item.id);
    const record = recordById.get(item.id);
    if (expected === undefined || record === undefined || comparisonIds.has(item.id) || item.fixture.file !== expected.fixture || item.fixture.sourceSha256 !== record.sourceSha256 || item.expectedFailure !== (expected.expectedFailure === true) || item.equivalent !== true) throw new Error(`compat-js証拠caseのidentityが不正です: ${item.id}`);
    comparisonIds.add(item.id);
    if (!hashPattern.test(item.fixture.sourceSha256)) throw new Error(`compat-js証拠caseのsource SHA-256が不正です: ${item.id}`);
    validateCompatJsRouteResults(item.results, item.expectedFailure, item.id);
    if (item.expectedFailure) {
      if (item.trace !== null) throw new Error(`compat-js期待失敗caseにtraceがあります: ${item.id}`);
    } else {
      validateCompatJsTraceSummary(item.trace, item.id, operationByName);
      if (item.trace.operations.length > 0) proofCaseIds.push(item.id);
    }
  }
  if (comparisonIds.size !== cases.length || JSON.stringify(evidence.scope.selectedProofCaseIds) !== JSON.stringify(proofCaseIds)) throw new Error("compat-js証拠case集合またはselected proofが不一致です");

  assertKnownObjectKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "compat-js-evidence.provenance");
  assertKnownObjectKeys(evidence.provenance.environment, ["platform", "arch", "node"], "compat-js-evidence.provenance.environment");
  assertKnownObjectKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "compat-js-evidence.provenance.oracle");
  assertKnownObjectKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "compat-js-evidence.provenance.lnako");
  assertKnownObjectKeys(evidence.provenance.raw, ["traceSha256ByCase"], "compat-js-evidence.provenance.raw");
  const environment = evidence.provenance.environment;
  const oracle = evidence.provenance.oracle;
  const lnako = evidence.provenance.lnako;
  const platformKey = `${environment.platform}-${environment.arch}`;
  if (![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) || !Number.isSafeInteger(oracle.build) || oracle.build !== lock.nadesiko3.oracleIdentity?.build || oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 || oracle.cliSha256 !== lock.nadesiko3.oracleIdentity?.cliSha256 || oracle.markerSha256 !== lock.nadesiko3.oracleIdentity?.markerSha256 || oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity?.treeHashAlgorithm || oracle.treeSha256 !== lock.nadesiko3.oracleIdentity?.treeSha256ByPlatform?.[platformKey] || !hashPattern.test(oracle.archiveSha256) || !hashPattern.test(oracle.cliSha256) || !hashPattern.test(oracle.markerSha256) || !hashPattern.test(oracle.treeSha256) || !hashPattern.test(lnako.binarySha256) || !/^[0-9a-f]{40}$/i.test(lnako.commit) || lnako.dirty !== false) throw new Error("compat-js証拠のprovenanceが不正です");
  const expectedTraceCaseIds = cases.filter((testCase) => testCase.expectedFailure !== true).map((testCase) => testCase.id).sort();
  const actualTraceCaseIds = Object.keys(evidence.provenance.raw.traceSha256ByCase).sort();
  if (JSON.stringify(expectedTraceCaseIds) !== JSON.stringify(actualTraceCaseIds) || Object.values(evidence.provenance.raw.traceSha256ByCase).some((hash) => !hashPattern.test(hash))) throw new Error("compat-js証拠のraw trace SHA-256集合が不正です");
  const currentGit = readGitState();
  if (lnako.commit !== currentGit.commit && !isAllowedDispatchEvidenceFollowUp(lnako.commit, currentGit.commit)) throw new Error("cleanなcompat-js証拠のlnako commitが現行HEADと一致しません");

  const commandById = new Map(expectedCommands.map((command) => [command.id, command]));
  if (!Array.isArray(evidence.entries) || evidence.entries.length !== expectedCommands.length) throw new Error("compat-js証拠のentry数が不正です");
  const entryIds = new Set();
  for (const entry of evidence.entries) {
    assertKnownObjectKeys(entry, ["catalogId", "name", "plugin", "operation", "fixtureIds", "sites", "runtime", "officialEquivalent"], "compat-js-evidence.entry");
    const command = commandById.get(entry.catalogId);
    if (command === undefined || entry.name !== command.name || entry.plugin !== command.plugin || entry.operation !== operationByName.get(command.name) || entryIds.has(entry.catalogId) || entry.officialEquivalent !== true || !Array.isArray(entry.fixtureIds) || !Array.isArray(entry.sites) || entry.sites.length === 0) throw new Error(`compat-js証拠entryのidentityが不正です: ${entry.catalogId}`);
    entryIds.add(entry.catalogId);
    assertKnownObjectKeys(entry.runtime, ["interpreter"], "compat-js-evidence.entry.runtime");
    assertKnownObjectKeys(entry.runtime.interpreter, ["attemptCount", "resultCount", "success"], "compat-js-evidence.entry.runtime.interpreter");
    if (entry.runtime.interpreter.attemptCount !== entry.sites.length || entry.runtime.interpreter.resultCount !== entry.sites.length || entry.runtime.interpreter.success !== true || JSON.stringify(entry.fixtureIds) !== JSON.stringify([...new Set(entry.sites.map((site) => site.fixtureId))].sort())) throw new Error(`compat-js証拠entryのruntimeが不正です: ${entry.catalogId}`);
    const siteKeys = new Set();
    for (const site of entry.sites) {
      assertKnownObjectKeys(site, ["fixtureId", "siteId", "command", "operation", "runtime", "officialEquivalent"], "compat-js-evidence.site");
      assertKnownObjectKeys(site.runtime, ["interpreter"], "compat-js-evidence.site.runtime");
      assertKnownObjectKeys(site.runtime.interpreter, ["attemptCount", "resultCount", "success"], "compat-js-evidence.site.runtime.interpreter");
      const key = `${site.fixtureId}/${site.siteId}`;
      if (!caseById.has(site.fixtureId) || !siteIdPattern.test(site.siteId) || site.command !== entry.name || site.operation !== entry.operation || siteKeys.has(key) || site.officialEquivalent !== true || site.runtime.interpreter.attemptCount !== 1 || site.runtime.interpreter.resultCount !== 1 || site.runtime.interpreter.success !== true) throw new Error(`compat-js証拠siteが不正です: ${entry.catalogId}/${key}`);
      siteKeys.add(key);
    }
  }
  if (entryIds.size !== expectedCommands.length) throw new Error("compat-js証拠のentry集合が不一致です");
}

function validateCompatJsRouteResults(results, expectedFailure, caseId) {
  assertKnownObjectKeys(results, ["officialSource", "lnakoCompatJs"], `compat-js-evidence.case.${caseId}.results`);
  for (const [route, result] of Object.entries(results)) {
    assertKnownObjectKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256", "failed"], `compat-js-evidence.case.${caseId}.results.${route}`);
    if ((typeof result.status !== "number" && result.status !== null) || (result.signal !== null && typeof result.signal !== "string") || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) || result.failed !== expectedFailure) throw new Error(`compat-js証拠のresultが不正です: ${caseId}/${route}`);
  }
  const official = results.officialSource;
  const actual = results.lnakoCompatJs;
  if (!expectedFailure && (official.status !== 0 || actual.status !== 0 || official.signal !== null || actual.signal !== null || official.stdoutSha256 !== actual.stdoutSha256)) throw new Error(`compat-js証拠の公式比較が不一致です: ${caseId}`);
}

function validateCompatJsTraceSummary(trace, caseId, operationByName) {
  assertKnownObjectKeys(trace, ["schema", "eventCount", "operations"], `compat-js-evidence.case.${caseId}.trace`);
  if (trace.schema !== 1 || !Number.isSafeInteger(trace.eventCount) || trace.eventCount < 1 || !Array.isArray(trace.operations)) throw new Error(`compat-js証拠のtrace summaryが不正です: ${caseId}`);
  for (const operation of trace.operations) {
    assertKnownObjectKeys(operation, ["siteId", "command", "operation", "attemptCount", "resultCount", "result"], `compat-js-evidence.case.${caseId}.operation`);
    if (!siteIdPattern.test(operation.siteId) || !operationByName.has(operation.command) || operationByName.get(operation.command) !== operation.operation || operation.attemptCount !== 1 || operation.resultCount !== 1 || operation.result !== "success") throw new Error(`compat-js証拠のtrace operationが不正です: ${caseId}/${operation.siteId}`);
  }
}

function validateEvidence(actual, lock, catalogSourceSha256, nativeFixtureIds, aotFixtureIds, compatJsFixtureIds, standard, matrix, dispatchEvidenceByCatalogId, dispatchCoverageEvidenceByCatalogId, staticConstantEvidenceByCatalogId, globalBindingEvidenceByCatalogId, globalBindingProofByCatalogId, expectedExitEvidenceByCatalogId, compatJsEvidenceByCatalogId) {
  rejectForbiddenEvidenceFields(actual);
  assertKnownObjectKeys(actual, ["schemaVersion", "baseline", "sourceSha256", "commandCount", "duplicateNameCount", "fixtureInventory", "fixtureCoverageStates", "executionEvidenceStates", "entries"], "evidence");
  assertKnownObjectKeys(actual.baseline, ["tag", "commit"], "evidence.baseline");
  assertKnownObjectKeys(actual.fixtureInventory, ["total", "nativeAot", "interpreter", "compatJs"], "evidence.fixtureInventory");
  assertKnownObjectKeys(actual.fixtureCoverageStates, ["paired", "interpreter-only", "aot-only", "none", "compat-js-only"], "evidence.fixtureCoverageStates");
  assertKnownObjectKeys(actual.executionEvidenceStates, ["verified", "trace-confirmed-unattested", "unverified"], "evidence.executionEvidenceStates");
  if (actual.schemaVersion !== 2 || actual.commandCount !== 527 || actual.entries?.length !== 527) throw new Error("evidence.jsonのschemaまたは527 entry条件を満たしません");
  if (actual.baseline?.tag !== lock.nadesiko3.tag || actual.baseline?.commit !== lock.nadesiko3.commit || actual.sourceSha256 !== lock.nadesiko3.commandList.sha256 || actual.sourceSha256 !== catalogSourceSha256) throw new Error("evidence.jsonのbaselineまたはSHA-256がupstream.lock.jsonと一致しません");
  if (actual.duplicateNameCount !== 31) throw new Error("evidence.jsonが重複命令名を保持していません");
  const catalogIds = new Set(standard.commands.map((command) => command.id));
  const matrixById = new Map(matrix.entries.map((entry) => [entry.id, entry]));
  const duplicateNames = duplicateNameSet(standard.commands);
  const allowedCoverage = new Set(["paired", "interpreter-only", "aot-only", "none", "compat-js-only"]);
  const seen = new Set();
  for (const entry of actual.entries) {
    assertKnownObjectKeys(entry, ["id", "name", "plugin", "status", "interpreterFixtureIds", "aotFixtureIds", "compatJsFixtureIds", "associationOrigin", "fixtureCoverageState", "identityResolution", "executionEvidenceState", "executionEvidence", "reason", "implementationReason", "unresolvedTestIds"], `evidence.entries.${entry.id ?? "unknown"}`);
    if (!catalogIds.has(entry.id) || seen.has(entry.id)) throw new Error(`evidence.jsonのcatalog IDが不正です: ${entry.id}`);
    seen.add(entry.id);
    const canonical = matrixById.get(entry.id);
    if (entry.name !== canonical.name || entry.plugin !== canonical.plugin || entry.status !== canonical.status) throw new Error(`evidence.jsonのcatalog identityが不一致です: ${entry.id}`);
    if (!allowedCoverage.has(entry.fixtureCoverageState)) throw new Error(`fixtureCoverageStateが不正です: ${entry.id}`);
    if (!new Set(["verified", "trace-confirmed-unattested", "unverified"]).has(entry.executionEvidenceState)) throw new Error(`executionEvidenceStateが不正です: ${entry.id}`);
    const hasStaticConstantProof = (staticConstantEvidenceByCatalogId.get(entry.id) ?? []).length > 0;
    const hasDispatchProof = (dispatchEvidenceByCatalogId.get(entry.id) ?? []).length > 0 || (dispatchCoverageEvidenceByCatalogId.get(entry.id) ?? []).length > 0;
    const hasGlobalBindingProof = (globalBindingEvidenceByCatalogId.get(entry.id) ?? []).length > 0;
    const hasExpectedExitProof = expectedExitEvidenceByCatalogId.has(entry.id);
    const hasCompatJsProof = (compatJsEvidenceByCatalogId.get(entry.id)?.sites ?? []).length > 0;
    const expectedIdentity = duplicateNames.has(entry.name)
      ? hasStaticConstantProof || hasDispatchProof || hasGlobalBindingProof || hasExpectedExitProof || hasCompatJsProof ? "explicit-catalog-id" : "ambiguous-name"
      : "unique-name";
    if (entry.identityResolution !== expectedIdentity) throw new Error(`identityResolutionが不一致です: ${entry.id}`);
    if (entry.interpreterFixtureIds.some((id) => nativeFixtureIds.has(id) || compatJsFixtureIds.has(id))) throw new Error(`interpreterFixtureIdsにAOTまたはcompat-js IDがあります: ${entry.id}`);
    for (const id of entry.aotFixtureIds ?? []) if (!aotFixtureIds.has(id)) throw new Error(`AOT fixture IDがAOT対応fixtureにありません: ${entry.id} -> ${id}`);
    for (const id of entry.compatJsFixtureIds ?? []) if (!compatJsFixtureIds.has(id)) throw new Error(`compatJsFixtureIdsがcompat-js-cases.jsonにありません: ${entry.id} -> ${id}`);
    if (entry.associationOrigin === undefined || typeof entry.associationOrigin !== "object") throw new Error(`associationOriginがありません: ${entry.id}`);
    for (const [mode, ids] of [["interpreter", entry.interpreterFixtureIds], ["aot", entry.aotFixtureIds], ["compatJs", entry.compatJsFixtureIds]]) {
      const origins = entry.associationOrigin[mode];
      if (origins === undefined || JSON.stringify(Object.keys(origins).sort()) !== JSON.stringify([...ids].sort())) throw new Error(`associationOriginとfixture IDが不一致です: ${entry.id}/${mode}`);
      for (const values of Object.values(origins)) if (!Array.isArray(values) || values.some((value) => !["fixture.commands", "implemented.tests"].includes(value))) throw new Error(`associationOriginの値が不正です: ${entry.id}/${mode}`);
    }
    const expectedCoverage = fixtureCoverageStateFor(entry.status, entry.interpreterFixtureIds, entry.aotFixtureIds, entry.compatJsFixtureIds);
    if (entry.fixtureCoverageState !== expectedCoverage) throw new Error(`fixtureCoverageStateが関連IDと不一致です: ${entry.id}`);
    if (entry.executionEvidenceState !== "unverified") {
      assertKnownObjectKeys(entry.executionEvidence, ["proofSchema", "fixtureId", "siteIds", "officialComparison", "state"], `evidence.entries.${entry.id}.executionEvidence`);
      const proof = entry.executionEvidence;
      const isDispatchProof = proof?.proofSchema === "lnako.dispatch-evidence.v2";
      const isDispatchCoverageProof = proof?.proofSchema === "lnako.dispatch-coverage.v1";
      const isStaticConstantProof = proof?.proofSchema === "lnako.static-constant-evidence.v2";
      const isGlobalBindingProof = proof?.proofSchema === "lnako.global-binding-evidence.v1" || proof?.proofSchema === "lnako.global-binding-evidence.v2";
      const isExpectedExitProof = proof?.proofSchema === "lnako.expected-exit-evidence.v1";
      const isCompatJsProof = proof?.proofSchema === "lnako.compat-js-evidence.v1";
      const proofSites = isDispatchProof
        ? dispatchEvidenceByCatalogId.get(entry.id) ?? []
        : isDispatchCoverageProof
          ? dispatchCoverageEvidenceByCatalogId.get(entry.id) ?? []
        : isStaticConstantProof
          ? staticConstantEvidenceByCatalogId.get(entry.id) ?? []
        : isGlobalBindingProof
          ? globalBindingEvidenceByCatalogId.get(entry.id) ?? []
        : isExpectedExitProof
          ? expectedExitEvidenceByCatalogId.has(entry.id) ? [expectedExitEvidenceByCatalogId.get(entry.id).site] : []
        : isCompatJsProof
          ? compatJsEvidenceByCatalogId.get(entry.id)?.sites ?? []
          : [];
      const expectedSiteIds = proofSites.map((site) => isDispatchCoverageProof ? coverageSiteKey(site) : isCompatJsProof ? `${site.fixtureId}/${site.siteId}` : site.siteId).sort();
      const validStaticState = isStaticConstantProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "native" && matrix.entries.find((candidate) => candidate.id === entry.id)?.type === "定数";
      const validGlobalBindingState = isGlobalBindingProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "native" && hasGlobalBindingProof;
      const validExpectedExitState = isExpectedExitProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "native" && hasExpectedExitProof;
      const validCompatJsState = isCompatJsProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "compat-js" && hasCompatJsProof;
      const validDispatchState = isDispatchProof && ["verified", "trace-confirmed-unattested"].includes(entry.executionEvidenceState);
      const validDispatchCoverageState = isDispatchCoverageProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "native";
      if (!new Set(["unique-name", "explicit-catalog-id"]).has(entry.identityResolution) || (!validDispatchState && !validDispatchCoverageState && !validStaticState && !validGlobalBindingState && !validExpectedExitState && !validCompatJsState) ||
          (isDispatchProof && proof.fixtureId !== "native-dispatch-commands") ||
          (isDispatchCoverageProof && proof.fixtureId !== "dispatch-coverage") ||
          (isStaticConstantProof && !staticConstantFixtureIds.has(proof.fixtureId)) ||
          (isGlobalBindingProof && proof.fixtureId !== globalBindingProofByCatalogId.get(entry.id)?.fixture.id) ||
          (isExpectedExitProof && proof.fixtureId !== "node-exit-evidence") ||
          (isCompatJsProof && proof.fixtureId !== "compat-js-evidence") ||
          proof.state !== entry.executionEvidenceState || !Array.isArray(proof.siteIds) || proof.siteIds.length === 0 || JSON.stringify(proof.siteIds) !== JSON.stringify(expectedSiteIds) ||
          !Array.isArray(proof.officialComparison) || proof.officialComparison.length === 0 ||
          (isDispatchCoverageProof && JSON.stringify(proof.officialComparison) !== JSON.stringify(["officialSource", "lnakoRun", "lnakoNativeO0"])) ||
          (isGlobalBindingProof && JSON.stringify(proof.officialComparison) !== JSON.stringify(["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"])) ||
          (isExpectedExitProof && JSON.stringify(proof.officialComparison) !== JSON.stringify(["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0", "lnakoNativeO1", "lnakoNativeO2", "lnakoNativeO3"])) ||
          (isCompatJsProof && JSON.stringify(proof.officialComparison) !== JSON.stringify(["officialSource", "lnakoCompatJs"]))) {
        throw new Error(`実行証拠付きentryが不正です: ${entry.id}`);
      }
    } else if (entry.executionEvidence !== null) {
      throw new Error(`unverified entryにdispatch証拠があります: ${entry.id}`);
    }
  }
  const expectedCoverageCounts = Object.fromEntries(["paired", "interpreter-only", "aot-only", "none", "compat-js-only"].map((state) => [state, actual.entries.filter((entry) => entry.fixtureCoverageState === state).length]));
  if (JSON.stringify(actual.fixtureCoverageStates) !== JSON.stringify(expectedCoverageCounts)) throw new Error("fixtureCoverageStates集計が不一致です");
  const expectedExecutionStates = Object.fromEntries(["verified", "trace-confirmed-unattested", "unverified"].map((state) => [state, actual.entries.filter((entry) => entry.executionEvidenceState === state).length]));
  if (JSON.stringify(actual.executionEvidenceStates) !== JSON.stringify(expectedExecutionStates)) throw new Error("executionEvidenceStates集計が不一致です");
}
