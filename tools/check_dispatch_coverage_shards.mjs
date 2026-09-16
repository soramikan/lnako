import { readdir, readFile } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { dispatchCoverageAuditSha256 } from "./lib/evidence_common.mjs";
import { computeSourceManifestSha256 } from "./lib/evidence/manifest.mjs";
import { freshnessBytes } from "./lib/evidence/provenance.mjs";
import { coverageEnv } from "./lib/coverage_env.mjs";
import * as coverage_fixtures from "./lib/coverage_fixtures.mjs";
import { mergeCoverageShards } from "./lib/coverage_merge.mjs";

const root = resolve(import.meta.dirname, "..");
const arguments_ = parseArguments();
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const baseline = lock.nadesiko3;
const currentSourceManifestSha256 = (await computeSourceManifestSha256(root)).sha256;
const auditScriptSha256 = await dispatchCoverageAuditSha256(root);
const defaultSelection = "plugin-system/system-runtime/standard-plugin/supplemental-plugin command-bearing success fixtures plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and native-cut-commands, excluding explicit AOT gaps";
const fullSelection = "the default command-bearing selection plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and all native-cases command-bearing fixtures, excluding explicit error/termination/host gaps";
// canonical 正本（darwin/arm64・231件）の freshness は Linux dedicated shard が供給する。
// macOS native 相乗り・Windows support は既定の56件のまま維持する。
const platformExpectations = new Map([
  ["darwin-arm64", { selection: defaultSelection, fixtureCount: 56 }],
  ["linux-x64", { selection: fullSelection, fixtureCount: 231 }],
  ["win32-x64", { selection: defaultSelection, fixtureCount: 56 }],
]);
const files = (await jsonFiles(arguments_.directory)).sort();
const expectedShardCount = arguments_.shardCount;
const expectedArtifactCount = expectedShardCount * platformExpectations.size;
if (files.length !== expectedArtifactCount) throw new Error(`dispatch coverage shard artifactは${expectedArtifactCount}件必要です: actual=${files.length}`);

const artifacts = [];
for (const path of files) artifacts.push(await readCoverageArtifact(path));
const byPlatform = Map.groupBy(artifacts, (artifact) => artifact.platform);
if (byPlatform.size !== platformExpectations.size || [...byPlatform.keys()].some((platform) => !platformExpectations.has(platform))) {
  throw new Error(`dispatch coverage artifactの正式OS集合が不正です: ${JSON.stringify([...byPlatform.keys()])}`);
}

const unions = new Map();
for (const [platform, expectation] of platformExpectations) {
  const shards = requirePlatform(byPlatform, platform, expectedShardCount);
  const indexes = shards.map((artifact) => artifact.shard.index).sort((left, right) => left - right);
  const expectedIndexes = Array.from({ length: expectedShardCount }, (_, index) => index);
  if (JSON.stringify(indexes) !== JSON.stringify(expectedIndexes)) {
    throw new Error(`${platform} dispatch coverage shard indexが不連続です: ${JSON.stringify(indexes)}`);
  }
  const union = new Set();
  for (const artifact of shards) {
    if (artifact.kind !== "sampled-unattested-dispatch-audit-shard" || artifact.selection !== expectation.selection ||
        artifact.shard.totalFixtureCount !== expectation.fixtureCount ||
        artifact.shard.selectedFixtureCount !== artifact.fixtureCount || artifact.shard.count !== expectedShardCount) {
      throw new Error(`${platform} dispatch coverage shard metadataが不正です: ${artifact.path}`);
    }
    for (const key of artifact.fixtureKeys) {
      if (union.has(key)) throw new Error(`${platform} dispatch coverage shardがfixtureを重複実行しています: ${key}`);
      union.add(key);
    }
  }
  if (union.size !== expectation.fixtureCount) {
    throw new Error(`${platform} dispatch coverageのshard集合が不完全です: actual=${union.size} expected=${expectation.fixtureCount}`);
  }
  unions.set(platform, union);
}
// macOS・Windows は既定56件で同一集合、Linux の231件がその上位集合であることを確認する。
const darwinUnion = unions.get("darwin-arm64");
const win32Union = unions.get("win32-x64");
const linuxUnion = unions.get("linux-x64");
assertSetEqual(win32Union, darwinUnion, "darwin-arm64/win32-x64 dispatch coverage shardのfixture集合");
assertSubset(darwinUnion, linuxUnion, "darwin-arm64 dispatch coverage shardのfixture集合（linux-x64 231件の部分集合）");

const scriptHashes = new Set(artifacts.map((artifact) => artifact.auditScriptSha256));
if (scriptHashes.size !== 1 || !scriptHashes.has(auditScriptSha256)) {
  throw new Error("dispatch coverage shardが同一の監査scriptから生成されていません");
}

// Linux 231件 shard を全件実行形へ merge し、canonical 正本と freshnessBytes で照合する。
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
Object.assign(coverageEnv, {
  root,
  catalog,
  catalogByName: Map.groupBy(catalog.commands, (command) => command.name),
  excludedFixtures: coverage_fixtures.excludedFixtures,
  arguments_: { includeNative: true, fixtureShard: { index: null } },
});
const fixturePool = await coverage_fixtures.loadSelectedFixtures();
const fixtureOrder = fixturePool.map((fixture) => `${fixture.file}/${fixture.id}`);
assertSetEqual(linuxUnion, new Set(fixtureOrder), "linux-x64 dispatch coverage shardのfixture集合（fixture pool全体）");
const merged = mergeCoverageShards(
  byPlatform.get("linux-x64").map((artifact) => artifact.document),
  { fixtureOrder, catalog },
);
const canonicalBytes = freshnessBytes(JSON.parse(await readFile(resolve(root, "compat/v3.7.24/dispatch-coverage-evidence.json"), "utf8")));
if (freshnessBytes(merged) !== canonicalBytes) {
  throw new Error("Linux dispatch coverage shardのmerge結果がcanonical正本と一致しません\nnode tools/update_current_evidence.mjs で正本を再生成し、コードと証拠を同じコミットにまとめてください。");
}
console.log(`dispatch coverage shard監査: 3正式OS各${expectedShardCount} shard（darwin/win32=56件、linux=231件⊃56件）を重複なく検証し、Linux mergeがcanonical正本と一致しました`);

function parseArguments() {
  let directory = null;
  let shardCount = 3;
  let shardCountSpecified = false;
  for (let index = 0; index < process.argv.length - 2; index += 1) {
    const argument = process.argv[index + 2];
    if (argument === "--directory") {
      if (directory !== null) throw new Error("--directoryは1回だけ指定してください");
      directory = process.argv[++index + 2] ?? null;
      if (directory === null || !isAbsolute(directory)) throw new Error("--directoryには絶対パスを指定してください");
    } else if (argument === "--shard-count") {
      if (shardCountSpecified) throw new Error("--shard-countは1回だけ指定してください");
      shardCountSpecified = true;
      const value = process.argv[++index + 2] ?? null;
      if (value === null || !/^\d+$/.test(value)) throw new Error("--shard-countには2以上の整数を指定してください");
      shardCount = Number(value);
      if (!Number.isSafeInteger(shardCount) || shardCount < 2) throw new Error("--shard-countには2以上の整数を指定してください");
    } else {
      throw new Error("usage: node tools/check_dispatch_coverage_shards.mjs --directory /absolute/path [--shard-count N]");
    }
  }
  if (directory === null) throw new Error("--directoryが必要です");
  return { directory: resolve(directory), shardCount };
}

async function jsonFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await jsonFiles(path));
    else if (entry.isFile() && entry.name.endsWith(".json")) files.push(path);
  }
  return files;
}

async function readCoverageArtifact(path) {
  const evidence = JSON.parse(await readFile(path, "utf8"));
  if (evidence?.schema !== "lnako.dispatch-coverage.v1" || !["sampled-unattested-dispatch-audit", "sampled-unattested-dispatch-audit-shard"].includes(evidence.kind)) {
    throw new Error(`dispatch coverage artifactのschemaまたはkindが不正です: ${path}`);
  }
  if (evidence.baseline?.tag !== baseline.tag || evidence.baseline?.commit !== baseline.commit) {
    throw new Error(`dispatch coverage artifactのbaselineが不正です: ${path}`);
  }
  const scope = evidence.scope;
  if (scope?.catalogEntries !== 527 || scope?.nativeEntries !== 523 || scope?.nativeUniqueNames !== 492 ||
      ![defaultSelection, fullSelection].includes(scope?.fixtureSelection) || scope?.commandAssociationIsNotExecutionEvidence !== true ||
      !Array.isArray(scope?.excludedFixtures) || !Number.isSafeInteger(scope?.fixtureCount) || scope.fixtureCount < 1) {
    throw new Error(`dispatch coverage artifactのscopeが不正です: ${path}`);
  }
  const shard = evidence.kind === "sampled-unattested-dispatch-audit-shard" ? scope.fixtureShard ?? null : null;
  if (evidence.kind === "sampled-unattested-dispatch-audit" && Object.hasOwn(scope ?? {}, "fixtureShard")) {
    throw new Error(`全件dispatch coverage artifactにshard metadataがあります: ${path}`);
  }
  if (evidence.kind === "sampled-unattested-dispatch-audit-shard" &&
      (shard === null || shard.mode !== "weighted-source-command" || !Number.isSafeInteger(shard.index) || shard.index < 0 ||
       !Number.isSafeInteger(shard.count) || shard.index >= shard.count || shard.count < 2 ||
       !Number.isSafeInteger(shard.totalFixtureCount) || shard.totalFixtureCount < scope.fixtureCount ||
       shard.selectedFixtureCount !== scope.fixtureCount)) {
    throw new Error(`dispatch coverage shard metadataが不正です: ${path}`);
  }
  const environment = evidence.provenance?.environment;
  const platform = `${environment?.platform}-${environment?.arch}`;
  const provenance = evidence.provenance;
  if (!environment || ![environment.platform, environment.arch, environment.node].every((value) => typeof value === "string" && value.length > 0) ||
      typeof provenance?.lnako?.binarySha256 !== "string" || typeof provenance?.lnako?.sourceManifestSha256 !== "string" ||
      provenance?.lnako?.sourceManifestSha256 !== currentSourceManifestSha256 ||
      provenance?.auditScriptSha256 !== auditScriptSha256) {
    throw new Error(`dispatch coverage artifactの現行HEAD／監査script provenanceが不正です: ${path}`);
  }
  if (!Array.isArray(evidence.fixtures) || evidence.fixtures.length !== scope.fixtureCount) {
    throw new Error(`dispatch coverage artifactのfixture件数が不正です: ${path}`);
  }
  const fixtureKeys = new Set();
  for (const fixture of evidence.fixtures) {
    if (typeof fixture?.file !== "string" || fixture.file.length === 0 || typeof fixture.id !== "string" || fixture.id.length === 0) {
      throw new Error(`dispatch coverage artifactのfixture identityが不正です: ${path}`);
    }
    const key = `${fixture.file}/${fixture.id}`;
    if (fixtureKeys.has(key)) throw new Error(`dispatch coverage artifactのfixtureが重複しています: ${path}/${key}`);
    fixtureKeys.add(key);
  }
  if (!Array.isArray(evidence.sites) || evidence.sites.length === 0 ||
      evidence.sites.some((site) => !fixtureKeys.has(`${site?.file}/${site?.fixtureId}`))) {
    throw new Error(`dispatch coverage artifactのsiteがfixture集合外です: ${path}`);
  }
  if (!Array.isArray(evidence.coverage?.unresolvedObservedSites) ||
      evidence.coverage.unresolvedObservedSites.some((site) => !fixtureKeys.has(`${site?.file}/${site?.fixtureId}`))) {
    throw new Error(`dispatch coverage artifactのunresolved siteがfixture集合外です: ${path}`);
  }
  return {
    path,
    platform,
    kind: evidence.kind,
    selection: scope.fixtureSelection,
    shard,
    fixtureCount: scope.fixtureCount,
    fixtureKeys,
    auditScriptSha256: provenance.auditScriptSha256,
    document: evidence,
  };
}

function requirePlatform(byPlatform, platform, count) {
  const artifacts = byPlatform.get(platform) ?? [];
  if (artifacts.length !== count) throw new Error(`${platform} dispatch coverage artifact件数が不正です: expected=${count} actual=${artifacts.length}`);
  return artifacts;
}

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不一致です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}

function assertSubset(subset, superset, label) {
  const missing = [...subset].filter((value) => !superset.has(value));
  if (missing.length === 0) return;
  throw new Error(`${label}が不一致です: missing=${JSON.stringify(missing)}`);
}
