import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { readDispatchFixture } from "../../dispatch_fixture.mjs";
import { evidenceEnv as env } from "./env.mjs";
import { readJson, runtimeFixtureFiles } from "./constants.mjs";

export async function readFixtureRecords() {
  const records = [];
  const files = (await readdir(env.oracleDirectory)).filter((file) => file.endsWith(".json")).sort();
  for (const file of files) {
    const value = await readJson(resolve(env.oracleDirectory, file));
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
          ? createHash("sha256").update(await readFile(resolve(env.root, "tests/fixtures", fixture.fixture))).digest("hex")
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
  const nativeCases = await readJson(resolve(env.oracleDirectory, "native-cases.json"));
  const dispatchFixture = await readDispatchFixture(env.root, nativeCases);
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


export function readFixtureCatalogIds(fixture, file) {
  if (fixture.catalogIds === undefined) return new Map();
  if (fixture.catalogIds === null || typeof fixture.catalogIds !== "object" || Array.isArray(fixture.catalogIds)) {
    throw new Error(`fixtureのcatalogIdsが不正です: ${file}/${fixture.id}`);
  }
  const ids = new Map();
  const usedIds = new Set();
  const standardById = new Map(env.standard.commands.map((command) => [command.id, command]));
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


export function addAssociation(record, name, origin) {
  record.commandNames.add(name);
  const origins = record.associationOrigins.get(name) ?? new Set();
  origins.add(origin);
  record.associationOrigins.set(name, origins);
}


export function associationOriginsFor(name, records, predicate) {
  const result = {};
  for (const record of records) {
    if (!predicate(record) || !record.commandNames.has(name)) continue;
    result[record.id] = [...(record.associationOrigins.get(name) ?? [])].sort();
  }
  return Object.fromEntries(Object.entries(result).sort(([left], [right]) => left.localeCompare(right)));
}


export function fixtureCoverageStateFor(status, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIds) {
  if (status === "compat-js") return compatJsFixtureIds.length > 0 ? "compat-js-only" : "none";
  if (interpreterFixtureIds.length > 0 && aotFixtureIds.length > 0) return "paired";
  if (interpreterFixtureIds.length > 0) return "interpreter-only";
  if (aotFixtureIds.length > 0) return "aot-only";
  return "none";
}


export function evidenceReason(status, coverage, identityResolution, interpreterFixtureIds, aotFixtureIds, compatJsFixtureIds, unresolvedTestIds, executionEvidenceState, executionSites, proofKind = null) {
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

