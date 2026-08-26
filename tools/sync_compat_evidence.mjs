import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const catalogPath = resolve(root, "compat/v3.7.24/command_list.json");
const matrixPath = resolve(root, "compat/v3.7.24/matrix.json");
const standardPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const evidencePath = resolve(root, "compat/v3.7.24/evidence.json");
const oracleDirectory = resolve(root, "tests/oracle");
const runtimeFixtureFiles = new Set([
  "compat-js-cases.json",
  "http-server-cases.json",
  "native-cases.json",
  "node-crypto-cases.json",
  "node-exit-cases.json",
  "node-file-cases.json",
  "node-http-cases.json",
  "node-native-cases.json",
  "plugin-system-cases.json",
  "standard-plugin-cases.json",
  "supplemental-plugin-cases.json",
  "system-runtime-cases.json",
]);
const mode = process.argv[2] ?? "--check";

if (!new Set(["--generate", "--check"]).has(mode)) {
  throw new Error("usage: node tools/sync_compat_evidence.mjs [--generate|--check]");
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
const compatJsFixtureIds = new Set(records.filter((record) => record.file === "compat-js-cases.json").map((record) => record.id));
const standardNames = new Set(standard.commands.map((command) => command.name));
const duplicateNames = duplicateNameSet(standard.commands);
const unresolvedByName = new Map();

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
  const aotFixtureIds = records
    .filter((record) => nativeFixtureIds.has(record.id) && record.commandNames.has(command.name))
    .map((record) => record.id)
    .sort();

  const compatJsFixtureIdsForCommand = records
    .filter((record) => compatJsFixtureIds.has(record.id) && record.commandNames.has(command.name))
    .map((record) => record.id)
    .sort();
  const fixtureCoverageState = fixtureCoverageStateFor(command.status, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIdsForCommand);
  const identityResolution = duplicateNames.has(command.name) ? "ambiguous-name" : "unique-name";
  const reason = evidenceReason(
    command.status,
    fixtureCoverageState,
    identityResolution,
    interpreterFixtureIds,
    aotFixtureIds,
    compatJsFixtureIdsForCommand,
    unresolvedTestIds,
  );
  return {
    id: command.id,
    name: command.name,
    plugin: command.plugin,
    status: command.status,
    interpreterFixtureIds,
    aotFixtureIds,
    compatJsFixtureIds: compatJsFixtureIdsForCommand,
    associationOrigin: {
      interpreter: associationOriginsFor(command.name, records, (record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id)),
      aot: associationOriginsFor(command.name, records, (record) => nativeFixtureIds.has(record.id)),
      compatJs: associationOriginsFor(command.name, records, (record) => compatJsFixtureIds.has(record.id)),
    },
    fixtureCoverageState,
    identityResolution,
    executionEvidenceState: "unverified",
    reason,
    ...(implementation?.reason !== undefined ? { implementationReason: implementation.reason } : {}),
    ...(unresolvedTestIds.length > 0 ? { unresolvedTestIds } : {}),
  };
});

const evidence = {
  schemaVersion: 1,
  baseline: matrix.baseline,
  sourceSha256: matrix.sourceSha256,
  commandCount: entries.length,
  duplicateNameCount: duplicateNames.size,
  fixtureInventory: {
    total: records.length,
    nativeAot: nativeFixtureIds.size,
    interpreter: records.filter((record) => !nativeFixtureIds.has(record.id) && !compatJsFixtureIds.has(record.id)).length,
    compatJs: compatJsFixtureIds.size,
  },
  fixtureCoverageStates: Object.fromEntries(
    ["paired", "interpreter-only", "aot-only", "none", "compat-js-only"].map((state) => [state, entries.filter((entry) => entry.fixtureCoverageState === state).length]),
  ),
  executionEvidenceStates: {
    unverified: entries.length,
  },
  entries,
};

const expected = json(evidence);
if (mode === "--generate") {
  await writeFile(evidencePath, expected);
  console.log(`カタログ証拠レイヤーを生成しました: ${entries.length}件（実行証拠は全${evidence.executionEvidenceStates.unverified}件unverified）`);
} else {
  const actual = await readFile(evidencePath, "utf8");
  if (actual !== expected) throw new Error(`カタログ証拠レイヤーが最新ではありません: ${evidencePath}`);
  validateEvidence(JSON.parse(actual), lock, catalogSourceSha256, nativeFixtureIds, compatJsFixtureIds, standard, matrix);
  console.log(`カタログ証拠レイヤーを検証しました: ${entries.length}件（同名異plugin ${evidence.duplicateNameCount * 2} entry、実行証拠は全件unverified）`);
}

async function readFixtureRecords() {
  const records = [];
  const files = (await readdir(oracleDirectory)).filter((file) => file.endsWith(".json")).sort();
  for (const file of files) {
    const value = await readJson(resolve(oracleDirectory, file));
    const fixtures = Array.isArray(value) ? value : Array.isArray(value.cases) ? value.cases : Array.isArray(value.entries) ? value.entries : [];
    for (const fixture of fixtures) {
      if (typeof fixture?.id !== "string" || fixture.id.length === 0) continue;
      const record = {
        id: fixture.id,
        file,
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

function evidenceReason(status, coverage, identityResolution, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIds, unresolvedTestIds) {
  const unresolved = unresolvedTestIds.length > 0 ? ` 実装台帳の未解決fixture ID: ${unresolvedTestIds.join(", ")}。` : "";
  const identity =
    identityResolution === "ambiguous-name"
      ? "同名異pluginのため、同じfixtureへの命令名ベースの割当はcatalog IDを識別する証拠にならない。"
      : "catalog IDに対する実行dispatch接続はまだ追跡していない。";
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

function validateEvidence(actual, lock, catalogSourceSha256, nativeFixtureIds, compatJsFixtureIds, standard, matrix) {
  if (actual.commandCount !== 527 || actual.entries?.length !== 527) throw new Error("evidence.jsonの527 entry条件を満たしません");
  if (actual.baseline?.tag !== lock.nadesiko3.tag || actual.baseline?.commit !== lock.nadesiko3.commit || actual.sourceSha256 !== lock.nadesiko3.commandList.sha256 || actual.sourceSha256 !== catalogSourceSha256) throw new Error("evidence.jsonのbaselineまたはSHA-256がupstream.lock.jsonと一致しません");
  if (actual.duplicateNameCount !== 31) throw new Error("evidence.jsonが重複命令名を保持していません");
  const catalogIds = new Set(standard.commands.map((command) => command.id));
  const matrixById = new Map(matrix.entries.map((entry) => [entry.id, entry]));
  const duplicateNames = duplicateNameSet(standard.commands);
  const allowedCoverage = new Set(["paired", "interpreter-only", "aot-only", "none", "compat-js-only"]);
  const seen = new Set();
  for (const entry of actual.entries) {
    if (!catalogIds.has(entry.id) || seen.has(entry.id)) throw new Error(`evidence.jsonのcatalog IDが不正です: ${entry.id}`);
    seen.add(entry.id);
    const canonical = matrixById.get(entry.id);
    if (entry.name !== canonical.name || entry.plugin !== canonical.plugin || entry.status !== canonical.status) throw new Error(`evidence.jsonのcatalog identityが不一致です: ${entry.id}`);
    if (!allowedCoverage.has(entry.fixtureCoverageState)) throw new Error(`fixtureCoverageStateが不正です: ${entry.id}`);
    if (entry.executionEvidenceState !== "unverified") throw new Error(`executionEvidenceStateはunverifiedでなければなりません: ${entry.id}`);
    const expectedIdentity = duplicateNames.has(entry.name) ? "ambiguous-name" : "unique-name";
    if (entry.identityResolution !== expectedIdentity) throw new Error(`identityResolutionが不一致です: ${entry.id}`);
    if (entry.interpreterFixtureIds.some((id) => nativeFixtureIds.has(id) || compatJsFixtureIds.has(id))) throw new Error(`interpreterFixtureIdsにAOTまたはcompat-js IDがあります: ${entry.id}`);
    for (const id of entry.aotFixtureIds ?? []) if (!nativeFixtureIds.has(id)) throw new Error(`AOT fixture IDがnative-cases.jsonにありません: ${entry.id} -> ${id}`);
    for (const id of entry.compatJsFixtureIds ?? []) if (!compatJsFixtureIds.has(id)) throw new Error(`compatJsFixtureIdsがcompat-js-cases.jsonにありません: ${entry.id} -> ${id}`);
    if (entry.associationOrigin === undefined || typeof entry.associationOrigin !== "object") throw new Error(`associationOriginがありません: ${entry.id}`);
    for (const [mode, ids] of [["interpreter", entry.interpreterFixtureIds], ["aot", entry.aotFixtureIds], ["compatJs", entry.compatJsFixtureIds]]) {
      const origins = entry.associationOrigin[mode];
      if (origins === undefined || JSON.stringify(Object.keys(origins).sort()) !== JSON.stringify([...ids].sort())) throw new Error(`associationOriginとfixture IDが不一致です: ${entry.id}/${mode}`);
      for (const values of Object.values(origins)) if (!Array.isArray(values) || values.some((value) => !["fixture.commands", "implemented.tests"].includes(value))) throw new Error(`associationOriginの値が不正です: ${entry.id}/${mode}`);
    }
    const expectedCoverage = fixtureCoverageStateFor(entry.status, entry.interpreterFixtureIds, entry.aotFixtureIds, entry.compatJsFixtureIds);
    if (entry.fixtureCoverageState !== expectedCoverage) throw new Error(`fixtureCoverageStateが関連IDと不一致です: ${entry.id}`);
  }
  const expectedCoverageCounts = Object.fromEntries(["paired", "interpreter-only", "aot-only", "none", "compat-js-only"].map((state) => [state, actual.entries.filter((entry) => entry.fixtureCoverageState === state).length]));
  if (JSON.stringify(actual.fixtureCoverageStates) !== JSON.stringify(expectedCoverageCounts)) throw new Error("fixtureCoverageStates集計が不一致です");
  if (JSON.stringify(actual.executionEvidenceStates) !== JSON.stringify({ unverified: 527 })) throw new Error("executionEvidenceStates集計が不一致です");
}
