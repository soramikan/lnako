import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { readDispatchFixture } from "./dispatch_fixture.mjs";
import { evidenceEnv } from "./lib/evidence/env.mjs";
import * as evidence_constants from "./lib/evidence/constants.mjs";
import * as records_mod from "./lib/evidence/records.mjs";
import * as validators from "./lib/evidence/validators.mjs";
import * as evidence_common from "./lib/evidence_common.mjs";


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
const globalBindingEvidenceInputs = evidence_constants.buildGlobalBindingEvidenceInputs(root);
const staticConstantEvidenceInputs = evidence_constants.buildStaticConstantEvidenceInputs(root);
const staticConstantFixtureIds = new Set(staticConstantEvidenceInputs.map((input) => input.fixtureId));
const oracleDirectory = resolve(root, "tests/oracle");


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

const json = evidence_constants.json;
const readJson = evidence_constants.readJson;

const [lock, catalog, matrix, standard, implemented, compatJsCases] = await Promise.all([
  readJson(lockPath),
  readJson(catalogPath),
  readJson(matrixPath),
  readJson(standardPath),
  readJson(implementationPath),
  readJson(compatJsCasesPath),
]);
const catalogSourceSha256 = createHash("sha256").update(await readFile(catalogPath)).digest("hex");

validators.validateCatalog(lock, catalog, matrix, standard, implemented, catalogSourceSha256);

Object.assign(evidenceEnv, { root, oracleDirectory, staticConstantFixtureIds, standard });
const records = await records_mod.readFixtureRecords();
const nativeFixtureIds = new Set(records.filter((record) => record.file === "native-cases.json").map((record) => record.id));
const aotFixtureIds = new Set(records.filter((record) => record.aot).map((record) => record.id));
const compatJsFixtureIds = new Set(records.filter((record) => record.file === "compat-js-cases.json").map((record) => record.id));
const standardNames = new Set(standard.commands.map((command) => command.name));
const duplicateNames = validators.duplicateNameSet(standard.commands);
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
const dispatchCoverageAuditScriptSha256 = await evidence_common.dispatchCoverageAuditSha256(root);
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
validators.validateDispatchEvidence(dispatchEvidence, lock, standard, records, dispatchEvidenceInputSha256, dispatchEvidenceInputPath, attestationBundlePath, attestationBundleBytes, historicalCommit);
validators.validateDispatchCoverageEvidence(dispatchCoverageEvidence, lock, standard, records, dispatchCoverageAuditScriptSha256);
validators.validateExpectedExitEvidence(expectedExitEvidence, lock, standard, records);
validators.validateCompatJsEvidence(compatJsEvidence, lock, standard, compatJsCases, records);
for (const input of staticConstantEvidenceRecords) validators.validateStaticConstantEvidence(input.evidence, lock, standard, records, input);
for (const input of globalBindingEvidenceRecords) validators.validateGlobalBindingEvidence(input.evidence, lock, standard, records, input);
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
    records_mod.addAssociation(record, name, "implemented.tests");
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
  const fixtureCoverageState = records_mod.fixtureCoverageStateFor(command.status, interpreterFixtureIds, aotFixtureIdsForCommand, compatJsFixtureIdsForCommand);
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
  const reason = records_mod.evidenceReason(
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
      interpreter: records_mod.associationOriginsFor(command.name, records, (record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id)),
      aot: records_mod.associationOriginsFor(command.name, records, (record) => aotFixtureIds.has(record.id)),
      compatJs: records_mod.associationOriginsFor(command.name, records, (record) => compatJsFixtureIds.has(record.id)),
    },
    fixtureCoverageState,
    identityResolution,
    executionEvidenceState,
    executionEvidence: selectedProof !== null
      ? {
          proofSchema: selectedProof.schema,
          fixtureId: selectedProof.fixture.id,
          siteIds: executionSites.map((site) => selectedProof.kind === "coverage" ? validators.coverageSiteKey(site) : selectedProof.kind === "compat-js" ? `${site.fixtureId}/${site.siteId}` : site.siteId).sort(),
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
  validators.validateEvidence(JSON.parse(actual), lock, catalogSourceSha256, nativeFixtureIds, aotFixtureIds, compatJsFixtureIds, standard, matrix, dispatchEvidenceByCatalogId, dispatchCoverageEvidenceByCatalogId, staticConstantEvidenceByCatalogId, globalBindingEvidenceByCatalogId, globalBindingProofByCatalogId, expectedExitEvidenceByCatalogId, compatJsEvidenceByCatalogId);
  console.log(`カタログ証拠レイヤーを検証しました: ${entries.length}件（同名異plugin ${evidence.duplicateNameCount * 2} entry、verified ${evidence.executionEvidenceStates.verified}件 / trace-confirmed-unattested ${evidence.executionEvidenceStates["trace-confirmed-unattested"]}件 / unverified ${evidence.executionEvidenceStates.unverified}件）`);
}

