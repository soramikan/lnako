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
const runtimeFixtureFiles = new Set([
  "compat-js-cases.json",
  "http-server-cases.json",
  "native-cases.json",
  "node-crypto-cases.json",
  "node-exit-cases.json",
  "node-file-cases.json",
  "node-http-cases.json",
  "node-interrupt-case.json",
  "node-native-cases.json",
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
  "README.md",
  "benchmarks/results/latest.json",
  "benchmarks/results/latest.md",
  "compat/v3.7.24/dispatch-evidence.json",
  "compat/v3.7.24/static-constant-evidence.json",
  "compat/v3.7.24/static-string-constant-evidence.json",
  "compat/v3.7.24/static-array-constant-evidence.json",
  "compat/v3.7.24/static-datetime-era-constant-evidence.json",
  "compat/v3.7.24/static-node-archive-constant-evidence.json",
  "compat/v3.7.24/static-node-command-line-constant-evidence.json",
  "compat/v3.7.24/static-node-mother-path-constant-evidence.json",
  "compat/v3.7.24/static-caniuse-agents-constant-evidence.json",
  "compat/v3.7.24/static-node-http-initial-constant-evidence.json",
  "compat/v3.7.24/evidence.json",
  "compat/v3.7.24/interpreter-only-classification.json",
  "docs/COMPATIBILITY_EVIDENCE.md",
  "docs/COMPATIBILITY_QUIRKS.md",
  "docs/CI.md",
  "docs/DEVELOPMENT.md",
  "tools/check_ci_workflow.mjs",
  "tools/check_aot_suite_parallel.mjs",
  "tools/compare_native_oracle.mjs",
  "tools/check_static_constant_evidence.mjs",
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

const [lock, catalog, matrix, standard, implemented] = await Promise.all([
  readJson(lockPath),
  readJson(catalogPath),
  readJson(matrixPath),
  readJson(standardPath),
  readJson(implementationPath),
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
const staticConstantEvidenceRecords = await Promise.all(staticConstantEvidenceInputs.map(async (input) => ({
  ...input,
  evidence: JSON.parse((await readFile(input.path)).toString("utf8")),
})));
const suppliedAttestation = attestationPath === null ? null : await readJson(attestationPath);
const attestationBundleBytes = attestationBundlePath === null ? null : await readFile(attestationBundlePath);
const dispatchEvidence = suppliedAttestation === null
  ? dispatchEvidenceBase
  : { ...dispatchEvidenceBase, attestation: suppliedAttestation };
validateDispatchEvidence(dispatchEvidence, lock, standard, records, dispatchEvidenceInputSha256, dispatchEvidenceInputPath, attestationBundlePath, attestationBundleBytes, historicalCommit);
for (const input of staticConstantEvidenceRecords) validateStaticConstantEvidence(input.evidence, lock, standard, records, input);
const dispatchEvidenceByCatalogId = new Map();
for (const site of dispatchEvidence.sites) {
  const sites = dispatchEvidenceByCatalogId.get(site.catalogId) ?? [];
  sites.push(site);
  dispatchEvidenceByCatalogId.set(site.catalogId, sites);
}
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
  const identityResolution = duplicateNames.has(command.name) ? "ambiguous-name" : "unique-name";
  const dispatchSites = dispatchEvidenceByCatalogId.get(command.id) ?? [];
  const staticConstantSites = staticConstantEvidenceByCatalogId.get(command.id) ?? [];
  const selectedProof = identityResolution === "unique-name"
    ? dispatchSites.length > 0
      ? { kind: "dispatch", schema: dispatchEvidence.schema, fixture: dispatchEvidence.fixture, officialComparison: dispatchEvidence.officialComparison, sites: dispatchSites }
      : staticConstantSites.length > 0
        ? { kind: "static-constant", ...staticConstantProofByCatalogId.get(command.id), sites: staticConstantSites }
        : null
    : null;
  const executionSites = selectedProof?.sites ?? [];
  const executionEvidenceState = selectedProof === null
    ? "unverified"
    : selectedProof.kind === "static-constant" || dispatchEvidence.attestation === null
      ? "trace-confirmed-unattested"
      : "verified";
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
          siteIds: executionSites.map((site) => site.siteId).sort(),
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
  validateEvidence(JSON.parse(actual), lock, catalogSourceSha256, nativeFixtureIds, aotFixtureIds, compatJsFixtureIds, standard, matrix, dispatchEvidenceByCatalogId, staticConstantEvidenceByCatalogId);
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
      const record = {
        id: fixture.id,
        file,
        aot: file === "native-cases.json" || fixture.aot === true,
        sourceSha256: typeof fixture.source === "string" ? createHash("sha256").update(fixture.source).digest("hex") : null,
        commandNames: new Set(),
        associationOrigins: new Map(),
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
    commandNames: new Set(),
    associationOrigins: new Map(),
  };
  for (const name of dispatchFixture.commands) addAssociation(dispatchRecord, name, "fixture.commands");
  records.push(dispatchRecord);
  if (new Set(records.map((record) => record.id)).size !== records.length) throw new Error("オラクルfixture IDが重複しています");

  return records;
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
      : "catalog IDに対する実行dispatch接続はまだ追跡していない。";
  const proofDescription = proofKind === "static-constant"
    ? "明示catalog ID・global/literal site IDについて、同一fixtureのInterpreter/AOT trace、対応manifest、公式差分の成功を機械検証した"
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
    if (duplicateNameSet(standard.commands).has(site.name)) throw new Error(`同名命令をdispatch証拠へ昇格できません: ${site.name}`);
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
    const digests = subjects.map((subject) => attestedSha256(subject)).filter((digest) => digest !== null).sort();
    return JSON.stringify(digests) === JSON.stringify(expectedDigests);
  });
  if (!matchesAllSubjects) throw new Error("検証済みattestation bundleの3 OS subject digestが一致しません");
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

function validateEvidence(actual, lock, catalogSourceSha256, nativeFixtureIds, aotFixtureIds, compatJsFixtureIds, standard, matrix, dispatchEvidenceByCatalogId, staticConstantEvidenceByCatalogId) {
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
    const expectedIdentity = duplicateNames.has(entry.name) ? "ambiguous-name" : "unique-name";
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
      const isStaticConstantProof = proof?.proofSchema === "lnako.static-constant-evidence.v2";
      const proofSites = isDispatchProof
        ? dispatchEvidenceByCatalogId.get(entry.id) ?? []
        : isStaticConstantProof
          ? staticConstantEvidenceByCatalogId.get(entry.id) ?? []
          : [];
      const expectedSiteIds = proofSites.map((site) => site.siteId).sort();
      const validStaticState = isStaticConstantProof && entry.executionEvidenceState === "trace-confirmed-unattested" && entry.status === "native" && matrix.entries.find((candidate) => candidate.id === entry.id)?.type === "定数";
      const validDispatchState = isDispatchProof && ["verified", "trace-confirmed-unattested"].includes(entry.executionEvidenceState);
      if (entry.identityResolution !== "unique-name" || (!validDispatchState && !validStaticState) ||
          (isDispatchProof && proof.fixtureId !== "native-dispatch-commands") || (isStaticConstantProof && !staticConstantFixtureIds.has(proof.fixtureId)) ||
          proof.state !== entry.executionEvidenceState || !Array.isArray(proof.siteIds) || proof.siteIds.length === 0 || JSON.stringify(proof.siteIds) !== JSON.stringify(expectedSiteIds) ||
          !Array.isArray(proof.officialComparison) || proof.officialComparison.length === 0) {
        throw new Error(`dispatch証拠付きentryが不正です: ${entry.id}`);
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
