import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { isAbsolute, join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const arguments_ = parseArguments();
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const baseline = lock.nadesiko3;
const currentCommit = readGitCommit();
const auditScriptSha256 = sha256(await readFile(resolve(root, "tools/check_dispatch_coverage.mjs")));
const expectedSelection = "plugin-system/system-runtime/standard-plugin/supplemental-plugin command-bearing success fixtures plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and native-cut-commands, excluding explicit AOT gaps";
const files = (await jsonFiles(arguments_.directory)).sort();
const expectedShardCount = arguments_.shardCount;
const expectedArtifactCount = expectedShardCount * 3;
if (files.length !== expectedArtifactCount) throw new Error(`dispatch coverage shard artifactは${expectedArtifactCount}件必要です: actual=${files.length}`);

const artifacts = [];
for (const path of files) artifacts.push(await readCoverageArtifact(path));
const byPlatform = Map.groupBy(artifacts, (artifact) => artifact.platform);
const expectedPlatforms = new Set(["darwin-arm64", "linux-x64", "win32-x64"]);
if (byPlatform.size !== expectedPlatforms.size || [...byPlatform.keys()].some((platform) => !expectedPlatforms.has(platform))) {
  throw new Error(`dispatch coverage artifactの正式OS集合が不正です: ${JSON.stringify([...byPlatform.keys()])}`);
}

const mac = requirePlatform(byPlatform, "darwin-arm64", expectedShardCount);
if (mac.some((artifact) => artifact.kind !== "sampled-unattested-dispatch-audit-shard")) {
  throw new Error("macOS dispatch coverage artifactは全てshard監査である必要があります");
}
const referenceFixtureCount = mac[0].shard?.totalFixtureCount;
if (referenceFixtureCount !== 56) {
  throw new Error(`macOS dispatch coverageの全fixture件数が不正です: reference=${referenceFixtureCount}`);
}
let referenceKeys = null;
for (const platform of ["darwin-arm64", "linux-x64", "win32-x64"]) {
  const shards = platform === "darwin-arm64" ? mac : requirePlatform(byPlatform, platform, expectedShardCount);
  const indexes = shards.map((artifact) => artifact.shard.index).sort((left, right) => left - right);
  const expectedIndexes = Array.from({ length: expectedShardCount }, (_, index) => index);
  if (JSON.stringify(indexes) !== JSON.stringify(expectedIndexes)) {
    throw new Error(`${platform} dispatch coverage shard indexが不連続です: ${JSON.stringify(indexes)}`);
  }
  const union = new Set();
  for (const artifact of shards) {
    if (artifact.kind !== "sampled-unattested-dispatch-audit-shard" || artifact.shard.totalFixtureCount !== referenceFixtureCount ||
        artifact.shard.selectedFixtureCount !== artifact.fixtureCount || artifact.shard.count !== expectedShardCount) {
      throw new Error(`${platform} dispatch coverage shard metadataが不正です: ${artifact.path}`);
    }
    for (const key of artifact.fixtureKeys) {
      if (union.has(key)) throw new Error(`${platform} dispatch coverage shardがfixtureを重複実行しています: ${key}`);
      union.add(key);
    }
  }
  if (referenceKeys === null) referenceKeys = union;
  assertSetEqual(union, referenceKeys, `${platform} dispatch coverage shardのfixture集合`);
}
if (referenceKeys.size !== referenceFixtureCount) throw new Error(`macOS dispatch coverageのshard集合が不完全です: actual=${referenceKeys.size}`);

const scriptHashes = new Set(artifacts.map((artifact) => artifact.auditScriptSha256));
if (scriptHashes.size !== 1 || !scriptHashes.has(auditScriptSha256)) {
  throw new Error("dispatch coverage shardが同一の監査scriptから生成されていません");
}
console.log(`dispatch coverage shard監査: 3正式OS各${expectedShardCount} shardで56 fixtureを重複なく検証しました`);

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
      scope?.fixtureSelection !== expectedSelection || scope?.commandAssociationIsNotExecutionEvidence !== true ||
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
      provenance?.lnako?.commit !== currentCommit || provenance?.lnako?.dirty !== false ||
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
    shard,
    fixtureCount: scope.fixtureCount,
    fixtureKeys,
    auditScriptSha256: provenance.auditScriptSha256,
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

function readGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error("lnakoのcommitを取得できません");
  const commit = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("lnakoのcommit形式が不正です");
  return commit;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
