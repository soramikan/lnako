import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "node:path";

const root = resolve(import.meta.dirname, "..");
const args = parseArguments(process.argv.slice(2));
const expectedCommit = args.commit ?? "0".repeat(40);
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const toolchainLock = JSON.parse(await readFile(resolve(root, "toolchain.lock.json"), "utf8"));
const fixturePath = resolve(root, "tests/oracle/native-cases.json");
const fixtureBytes = await readFile(fixturePath);
const fixtures = JSON.parse(fixtureBytes.toString("utf8"));
if (!Array.isArray(fixtures) || fixtures.some((fixture) => fixture === null || typeof fixture !== "object" || Array.isArray(fixture))) {
  throw new Error("native-cases.jsonのfixture配列が不正です");
}
if (fixtures.length !== 294) throw new Error(`native-cases.jsonのfixture数が不正です: ${fixtures.length}`);
const fixtureById = new Map();
for (const fixture of fixtures) {
  if (typeof fixture.id !== "string" || fixture.id.length === 0 || fixtureById.has(fixture.id)) throw new Error(`native-cases.jsonのfixture IDが不正です: ${fixture.id}`);
  if (typeof fixture.source !== "string" || fixture.source.length === 0 ||
      (fixture.commands !== undefined && (!Array.isArray(fixture.commands) || fixture.commands.some((name) => typeof name !== "string")))) {
    throw new Error(`native-cases.jsonのfixtureが不正です: ${fixture.id}`);
  }
  fixtureById.set(fixture.id, fixture);
}
const fixtureSha256 = sha256(fixtureBytes);
const expectedFixtureIds = fixtures.map((fixture) => fixture.id);
const expectedPlatforms = new Map([
  ["ubuntu-24.04", { target: "linux-x64", platform: "linux", arch: "x64", shardCount: 3 }],
  ["macos-15", { target: "macos-arm64", platform: "darwin", arch: "arm64", shardCount: 1 }],
  ["windows-2025", { target: "windows-x64", platform: "win32", arch: "x64", shardCount: 3 }],
]);
const expectedGroups = new Map([
  ["ubuntu-24.04", [
    { key: "O0", optimizations: ["O0"] },
    { key: "O1", optimizations: ["O1"] },
    { key: "O2", optimizations: ["O2"] },
    { key: "O3", optimizations: ["O3"] },
  ]],
  ["macos-15", [
    { key: "O0-O1", optimizations: ["O0", "O1"] },
    { key: "O2", optimizations: ["O2"] },
    { key: "O3", optimizations: ["O3"] },
  ]],
  ["windows-2025", [
    { key: "O0", optimizations: ["O0"] },
    { key: "O1", optimizations: ["O1"] },
    { key: "O2", optimizations: ["O2"] },
    { key: "O3", optimizations: ["O3"] },
  ]],
]);

if (args.selfTest) {
  runSelfTest();
  console.log("native AOT artifact検査: shard partition・schema・tamper拒否のself-test成功");
} else {
  const files = await collectArtifactFiles(args.directory);
  const records = [];
  const seen = new Set();
  for (const file of files) {
    const parsed = parseArtifactPath(args.directory, file);
    if (parsed === null) throw new Error(`native AOT artifactのpathが不正です: ${relative(args.directory, file)}`);
    const key = `${parsed.runner}\0${parsed.shardIndex}\0${parsed.optimizationKey}`;
    if (seen.has(key)) throw new Error(`native AOT artifactが重複しています: ${key}`);
    seen.add(key);
    const bytes = await readFile(file);
    const artifact = JSON.parse(bytes.toString("utf8"));
    validateArtifact(artifact, parsed);
    records.push({ ...parsed, file, bytes, artifact, artifactSha256: sha256(bytes) });
  }

  const expectedArtifactCount = [...expectedPlatforms].reduce((total, [runner, platform]) => total + platform.shardCount * expectedGroups.get(runner).length, 0);
  if (records.length !== expectedArtifactCount) throw new Error(`native AOT artifact数が不正です: ${records.length}/${expectedArtifactCount}`);

  const first = records[0]?.artifact;
  if (first === undefined) throw new Error("native AOT artifactが空です");
  validateSharedMetadata(records, first);
  const targets = [];
  for (const [runner, platform] of expectedPlatforms) {
    const targetRecords = records.filter((record) => record.runner === runner).sort(recordOrder);
    const expectedTargetCount = platform.shardCount * expectedGroups.get(runner).length;
    if (targetRecords.length !== expectedTargetCount) throw new Error(`${runner}のartifact数が不正です`);
    const optimizationSummaries = [];
    for (const group of expectedGroups.get(runner)) {
      const groupRecords = targetRecords.filter((record) => record.optimizationKey === group.key);
      if (groupRecords.length !== platform.shardCount) throw new Error(`${runner}/${group.key}のshard数が不正です`);
      const expectedByShard = new Map(groupRecords.map((record) => [record.shardIndex, expectedShardIds(group, record.shardIndex, platform.shardCount)]));
      for (const record of groupRecords) {
        const expectedIds = expectedByShard.get(record.shardIndex);
        if (JSON.stringify(record.artifact.fixtures.map((fixture) => fixture.id)) !== JSON.stringify(expectedIds)) {
          throw new Error(`native AOT artifactのfixture partitionが不一致です: ${runner}/${group.key}/${record.shardIndex}`);
        }
      }
      const union = new Set();
      for (const record of groupRecords) {
        for (const fixture of record.artifact.fixtures) {
          if (union.has(fixture.id)) throw new Error(`native AOT fixtureが同一OS／optimization内で重複しています: ${runner}/${group.key}/${fixture.id}`);
          union.add(fixture.id);
        }
      }
      if (union.size !== fixtures.length || expectedFixtureIds.some((id) => !union.has(id))) {
        throw new Error(`native AOT fixtureが同一OS／optimization内で全件揃っていません: ${runner}/${group.key}`);
      }
      optimizationSummaries.push({
        optimizationKey: group.key,
        optimizations: group.optimizations,
        shardCount: groupRecords.length,
        fixtureCount: union.size,
        artifacts: groupRecords.map((record) => ({
          shardIndex: record.shardIndex,
          artifactName: record.artifactName,
          artifactSha256: record.artifactSha256,
          fixtureCount: record.artifact.fixtureCount,
          fixtureIds: record.artifact.fixtures.map((fixture) => fixture.id),
        })),
      });
    }
    targets.push({
      target: platform.target,
      runner,
      environment: { platform: platform.platform, arch: platform.arch },
      artifactCount: targetRecords.length,
      fixtureCount: fixtures.length,
      optimizationGroups: optimizationSummaries,
    });
  }

  const aggregate = {
    schema: "lnako.native-aot-aggregate-evidence.v1",
    generator: "tools/check_native_aot_artifacts.mjs",
    generatedAt: new Date().toISOString(),
    baseline: first.baseline,
    commit: args.commit,
    toolchain: first.toolchain,
    fixtureSet: {
      file: "tests/oracle/native-cases.json",
      sha256: fixtureSha256,
      fixtureCount: fixtures.length,
      commandNameCount: new Set(fixtures.flatMap((fixture) => fixture.commands ?? [])).size,
    },
    targets,
  };
  if (args.output !== null) await writeFile(args.output, `${JSON.stringify(aggregate, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
  console.log(`3正式OSのnative AOT artifactを全件検証しました: ${records.length} artifact / ${fixtures.length} fixture / O0〜O3`);
}

function parseArguments(arguments_) {
  const parsed = { directory: null, commit: null, output: null, selfTest: false };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--self-test") {
      if (parsed.selfTest) throw new Error("--self-testは1回だけ指定してください");
      parsed.selfTest = true;
    } else if (argument === "--directory") parsed.directory = nextAbsolute(arguments_, ++index, argument);
    else if (argument === "--commit") parsed.commit = nextValue(arguments_, ++index, argument);
    else if (argument === "--output") parsed.output = nextAbsolute(arguments_, ++index, argument);
    else throw new Error("usage: node tools/check_native_aot_artifacts.mjs --directory /absolute/path --commit SHA [--output /absolute/path] | --self-test");
  }
  if (parsed.selfTest) {
    if (parsed.directory !== null || parsed.commit !== null || parsed.output !== null) throw new Error("--self-testとartifact検査引数は併用できません");
    return parsed;
  }
  if (parsed.directory === null || parsed.commit === null || !/^[0-9a-f]{40}$/i.test(parsed.commit)) throw new Error("--directoryと40桁の--commitが必要です");
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

function nextAbsolute(arguments_, index, argument) {
  const value = nextValue(arguments_, index, argument);
  if (!isAbsolute(value)) throw new Error(`${argument}には絶対パスを指定してください`);
  return resolve(value);
}

async function collectArtifactFiles(directory) {
  const files = [];
  async function visit(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = resolve(path, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile()) files.push(child);
      else throw new Error(`native AOT artifact directoryに特殊entryがあります: ${relative(directory, child)}`);
    }
  }
  await visit(directory);
  return files.sort();
}

function parseArtifactPath(directory, file) {
  const segments = relative(directory, file).split(sep);
  if (segments.length < 2) return null;
  const artifactName = segments[segments.length - 2];
  const fileName = basename(file);
  const directoryMatch = /^lnako-native-oracle-(ubuntu-24\.04|macos-15|windows-2025)-shard-(\d+)-(O[0-3](?:-O[0-3])?)$/.exec(artifactName);
  const fileMatch = /^lnako-native-oracle-(\d+)-(O[0-3](?:-O[0-3])?)\.json$/.exec(fileName);
  if (directoryMatch === null || fileMatch === null || directoryMatch[2] !== fileMatch[1] || directoryMatch[3] !== fileMatch[2]) return null;
  return {
    runner: directoryMatch[1],
    shardIndex: Number(directoryMatch[2]),
    optimizationKey: directoryMatch[3],
    artifactName,
  };
}

function validateArtifact(artifact, parsed) {
  assertExactKeys(artifact, ["schema", "generatedAt", "baseline", "oracle", "lnako", "toolchain", "artifactSha256", "environment", "fixtureCount", "routeCount", "routes", "knownOracleSelections", "status", "comparisonSucceeded", "failureCount", "selection", "fixtures"], "native AOT artifact");
  rejectForbidden(artifact, parsed.artifactName);
  const platform = expectedPlatforms.get(parsed.runner);
  if (platform === undefined) throw new Error(`native AOT artifactのrunnerが不正です: ${parsed.runner}`);
  const group = expectedGroups.get(parsed.runner).find((candidate) => candidate.key === parsed.optimizationKey);
  if (group === undefined || parsed.shardIndex < 0 || parsed.shardIndex >= platform.shardCount) throw new Error(`native AOT artifactのmatrix keyが不正です: ${parsed.artifactName}`);
  if (artifact.schema !== "lnako.native-oracle-artifact.v3" || artifact.status !== "success" || artifact.comparisonSucceeded !== true || artifact.failureCount !== 0) {
    throw new Error(`native AOT artifactが成功結果ではありません: ${parsed.artifactName}`);
  }
  if (typeof artifact.generatedAt !== "string" || Number.isNaN(Date.parse(artifact.generatedAt))) throw new Error(`native AOT artifactの生成日時が不正です: ${parsed.artifactName}`);
  if (artifact.lnako.commit !== expectedCommit || artifact.lnako.dirty !== false) throw new Error(`native AOT artifactのcommit／dirty状態が不正です: ${parsed.artifactName}`);
  assertExactKeys(artifact.baseline, ["repository", "tag", "commit", "archiveSha256"], `${parsed.artifactName}.baseline`);
  if (artifact.baseline.repository !== lock.nadesiko3.repository || artifact.baseline.tag !== lock.nadesiko3.tag || artifact.baseline.commit !== lock.nadesiko3.commit || artifact.baseline.archiveSha256 !== lock.nadesiko3.archive.sha256) {
    throw new Error(`native AOT artifactの公式baselineが不正です: ${parsed.artifactName}`);
  }
  assertExactKeys(artifact.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], `${parsed.artifactName}.oracle`);
  const expectedTreeSha256 = lock.nadesiko3.oracleIdentity.treeSha256ByPlatform[`${platform.platform}-${platform.arch}`];
  if (artifact.oracle.build !== lock.nadesiko3.oracleIdentity.build || artifact.oracle.archiveSha256 !== lock.nadesiko3.archive.sha256 ||
      artifact.oracle.cliSha256 !== lock.nadesiko3.oracleIdentity.cliSha256 || artifact.oracle.markerSha256 !== lock.nadesiko3.oracleIdentity.markerSha256 ||
      artifact.oracle.treeHashAlgorithm !== lock.nadesiko3.oracleIdentity.treeHashAlgorithm || artifact.oracle.treeSha256 !== expectedTreeSha256) {
    throw new Error(`native AOT artifactの公式oracle identityが不正です: ${parsed.artifactName}`);
  }
  assertExactKeys(artifact.lnako, ["commit", "dirty"], `${parsed.artifactName}.lnako`);
  assertExactKeys(artifact.toolchain, ["zig", "llvm", "node"], `${parsed.artifactName}.toolchain`);
  if (artifact.toolchain.zig !== toolchainLock.zig.version || artifact.toolchain.llvm !== toolchainLock.llvm.version || artifact.toolchain.node !== toolchainLock.node.version) {
    throw new Error(`native AOT artifactのtoolchainが不正です: ${parsed.artifactName}`);
  }
  assertExactKeys(artifact.artifactSha256, ["compareScript", "lnakoBinary"], `${parsed.artifactName}.artifactSha256`);
  assertHash(artifact.artifactSha256.compareScript, `${parsed.artifactName}.artifactSha256.compareScript`);
  assertHash(artifact.artifactSha256.lnakoBinary, `${parsed.artifactName}.artifactSha256.lnakoBinary`);
  assertEnvironment(artifact.environment, platform, parsed.artifactName);
  if (!Number.isSafeInteger(artifact.fixtureCount) || artifact.fixtureCount < 1 || !Number.isSafeInteger(artifact.routeCount) || artifact.routeCount < 1 || !Array.isArray(artifact.fixtures)) {
    throw new Error(`native AOT artifactの集計値またはfixturesが不正です: ${parsed.artifactName}`);
  }
  assertExactKeys(artifact.knownOracleSelections, ["defaultOfficialSource", "officialSource", "officialGenerated"], `${parsed.artifactName}.knownOracleSelections`);
  const expectedOracleSelections = {
    defaultOfficialSource: artifact.fixtures?.filter((fixture) => fixture?.knownOracleSelection === null).length ?? -1,
    officialSource: artifact.fixtures?.filter((fixture) => fixture?.knownOracleSelection === "official-source").length ?? -1,
    officialGenerated: artifact.fixtures?.filter((fixture) => fixture?.knownOracleSelection === "official-generated").length ?? -1,
  };
  if (JSON.stringify(artifact.knownOracleSelections) !== JSON.stringify(expectedOracleSelections) ||
      !Object.values(artifact.knownOracleSelections).every((value) => Number.isSafeInteger(value) && value >= 0)) {
    throw new Error(`native AOT artifactのknown oracle集計が不正です: ${parsed.artifactName}`);
  }
  assertExactKeys(artifact.selection, ["mode", "shardIndex", "shardCount", "totalFixtureCount", "optimizations"], `${parsed.artifactName}.selection`);
  const expectedMode = platform.shardCount === 1 ? "all" : "weighted-source-command";
  if (artifact.selection.mode !== expectedMode || artifact.selection.totalFixtureCount !== fixtures.length || JSON.stringify(artifact.selection.optimizations) !== JSON.stringify(group.optimizations)) {
    throw new Error(`native AOT artifactのselectionが不正です: ${parsed.artifactName}`);
  }
  if (expectedMode === "all") {
    if (artifact.selection.shardIndex !== null || artifact.selection.shardCount !== 1) throw new Error(`native AOT artifactのall selectionが不正です: ${parsed.artifactName}`);
  } else if (artifact.selection.shardIndex !== parsed.shardIndex || artifact.selection.shardCount !== platform.shardCount) {
    throw new Error(`native AOT artifactのweighted selectionが不正です: ${parsed.artifactName}`);
  }
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", ...group.optimizations.map((optimization) => `lnakoNative${optimization}`)];
  if (JSON.stringify(artifact.routes) !== JSON.stringify(expectedRoutes) || artifact.routeCount !== expectedRoutes.length) throw new Error(`native AOT artifactのrouteが不正です: ${parsed.artifactName}`);
  if (artifact.fixtureCount !== artifact.fixtures.length || artifact.fixtureCount < 1 || artifact.selection.totalFixtureCount !== fixtures.length) throw new Error(`native AOT artifactのfixtureCountが不正です: ${parsed.artifactName}`);
  assertHash(artifact.baseline.archiveSha256, `${parsed.artifactName}.baseline.archiveSha256`);
  assertHash(artifact.oracle.archiveSha256, `${parsed.artifactName}.oracle.archiveSha256`);
  assertHash(artifact.oracle.cliSha256, `${parsed.artifactName}.oracle.cliSha256`);
  assertHash(artifact.oracle.markerSha256, `${parsed.artifactName}.oracle.markerSha256`);
  assertHash(artifact.oracle.treeSha256, `${parsed.artifactName}.oracle.treeSha256`);
  assertHash(artifact.artifactSha256.compareScript, `${parsed.artifactName}.compareScript`);
  assertHash(artifact.artifactSha256.lnakoBinary, `${parsed.artifactName}.lnakoBinary`);
  const seen = new Set();
  for (const fixture of artifact.fixtures) {
    assertExactKeys(fixture, ["id", "knownOracleSelection", "oracleRoute", "comparedRoutes", "equivalent", "failureKinds", "sourceSha256", "generatedJavaScriptSha256", "results", "compileStatuses", "compileManifest"], `${parsed.artifactName}.fixture`);
    if (!fixtureById.has(fixture.id) || seen.has(fixture.id) || fixture.equivalent !== true || !Array.isArray(fixture.failureKinds) || fixture.failureKinds.length !== 0) throw new Error(`native AOT artifactのfixture結果が不正です: ${parsed.artifactName}/${fixture.id}`);
    seen.add(fixture.id);
    const sourceFixture = fixtureById.get(fixture.id);
    if (fixture.sourceSha256 !== sha256(sourceFixture.source)) throw new Error(`native AOT artifactのsource hashが不一致です: ${parsed.artifactName}/${fixture.id}`);
    if (fixture.generatedJavaScriptSha256 !== null) assertHash(fixture.generatedJavaScriptSha256, `${parsed.artifactName}/${fixture.id}.generatedJavaScriptSha256`);
    const expectedKnownOracleSelection = sourceFixture.oracle ?? null;
    const expectedOracleRoute = expectedKnownOracleSelection === "official-generated" ? "officialGenerated" : "officialSource";
    if (fixture.knownOracleSelection !== expectedKnownOracleSelection || fixture.oracleRoute !== expectedOracleRoute) throw new Error(`native AOT artifactのoracle選択が不正です: ${parsed.artifactName}/${fixture.id}`);
    const expectedComparedRoutes = expectedRoutes.filter((route) =>
      (fixture.knownOracleSelection !== "official-generated" || route !== "officialSource") &&
      (fixture.knownOracleSelection !== "official-source" || route !== "officialGenerated"),
    );
    if (JSON.stringify(fixture.comparedRoutes) !== JSON.stringify(expectedComparedRoutes)) throw new Error(`native AOT artifactの比較routeが不正です: ${parsed.artifactName}/${fixture.id}`);
    assertExactKeys(fixture.results, expectedRoutes, `${parsed.artifactName}/${fixture.id}.results`);
    for (const result of Object.values(fixture.results)) {
      assertExactKeys(result, ["exitCode", "signal", "stderrClass", "stdoutSha256", "stderrSha256"], `${parsed.artifactName}/${fixture.id}.result`);
      if ((result.exitCode !== null && !Number.isSafeInteger(result.exitCode)) || (result.signal !== null && typeof result.signal !== "string") || !["success", "runtime-error"].includes(result.stderrClass)) throw new Error(`native AOT artifactのroute結果が不正です: ${parsed.artifactName}/${fixture.id}`);
      assertHash(result.stdoutSha256, `${parsed.artifactName}/${fixture.id}.stdoutSha256`);
      assertHash(result.stderrSha256, `${parsed.artifactName}/${fixture.id}.stderrSha256`);
    }
    assertExactKeys(fixture.compileStatuses, group.optimizations, `${parsed.artifactName}/${fixture.id}.compileStatuses`);
    if (Object.values(fixture.compileStatuses).some((status) => status !== 0)) throw new Error(`native AOT artifactのcompile statusが不正です: ${parsed.artifactName}/${fixture.id}`);
    if (group.optimizations.includes("O0")) {
      if (fixture.compileManifest === null) throw new Error(`native AOT artifactのO0 manifestがありません: ${parsed.artifactName}/${fixture.id}`);
      assertExactKeys(fixture.compileManifest, ["complete", "entries"], `${parsed.artifactName}/${fixture.id}.compileManifest`);
      if (fixture.compileManifest.complete !== true || !Array.isArray(fixture.compileManifest.entries)) throw new Error(`native AOT artifactのO0 manifestが不正です: ${parsed.artifactName}/${fixture.id}`);
      for (const entry of fixture.compileManifest.entries) {
        assertExactKeys(entry, ["canonicalOpcode", "opcode", "route", "siteId", "sourceName"], `${parsed.artifactName}/${fixture.id}.compileManifest.entry`);
        if ([entry.canonicalOpcode, entry.route, entry.sourceName].some((value) => typeof value !== "string" || value.length === 0) ||
            !Number.isInteger(entry.opcode) || entry.opcode < 0 || entry.opcode > 0xffff || !/^0x[0-9a-f]{16}$/.test(entry.siteId)) {
          throw new Error(`native AOT artifactのO0 manifest entryが不正です: ${parsed.artifactName}/${fixture.id}`);
        }
      }
    } else if (fixture.compileManifest !== null) throw new Error(`native AOT artifactに不要なmanifestがあります: ${parsed.artifactName}/${fixture.id}`);
    rejectForbidden(fixture, `${parsed.artifactName}/${fixture.id}`);
  }
}

function validateSharedMetadata(records, first) {
  for (const record of records) {
    const artifact = record.artifact;
    if (artifact.baseline.repository !== first.baseline.repository || artifact.baseline.tag !== first.baseline.tag || artifact.baseline.commit !== first.baseline.commit || artifact.baseline.archiveSha256 !== first.baseline.archiveSha256) throw new Error("native AOT artifactの公式baselineが混在しています");
    if (artifact.lnako.commit !== expectedCommit) throw new Error("native AOT artifactのsource commitが不一致です");
    if (artifact.toolchain.zig !== toolchainLock.zig.version || artifact.toolchain.llvm !== toolchainLock.llvm.version || artifact.toolchain.node !== toolchainLock.node.version) throw new Error("native AOT artifactのtoolchainが固定値と不一致です");
    if (artifact.oracle.archiveSha256 !== first.oracle.archiveSha256 || artifact.oracle.cliSha256 !== first.oracle.cliSha256 || artifact.oracle.markerSha256 !== first.oracle.markerSha256 || artifact.oracle.treeHashAlgorithm !== first.oracle.treeHashAlgorithm) throw new Error("native AOT artifactのoracle identityが混在しています");
  }
  if (first.baseline.repository !== lock.nadesiko3.repository || first.baseline.commit !== lock.nadesiko3.commit || first.baseline.tag !== lock.nadesiko3.tag || first.baseline.archiveSha256 !== lock.nadesiko3.archive.sha256) throw new Error("native AOT artifactのbaselineがupstream lockと不一致です");
}

function assertEnvironment(environment, platform, label) {
  assertExactKeys(environment, ["platform", "arch", "node"], `${label}.environment`);
  if (environment.platform !== platform.platform || environment.arch !== platform.arch || environment.node !== `v${toolchainLock.node.version}`) throw new Error(`native AOT artifactのenvironmentが不正です: ${label}`);
}

function expectedShardIds(group, shardIndex, shardCount) {
  if (shardCount === 1) return expectedFixtureIds;
  const bins = Array.from({ length: shardCount }, (_, index) => ({ index, weight: 0, indexes: [] }));
  const weighted = fixtures
    .map((fixture, index) => ({ index, weight: Math.max(1, fixture.source.length) + (fixture.commands?.length ?? 0) * 8 }))
    .sort((left, right) => right.weight - left.weight || left.index - right.index);
  for (const item of weighted) {
    const bin = bins.reduce((best, candidate) => candidate.weight < best.weight ? candidate : best);
    bin.weight += item.weight;
    bin.indexes.push(item.index);
  }
  const selected = new Set(bins[shardIndex].indexes);
  return fixtures.filter((_, index) => selected.has(index)).map((fixture) => fixture.id);
}

function recordOrder(left, right) {
  return left.optimizationKey.localeCompare(right.optimizationKey) || left.shardIndex - right.shardIndex;
}

function assertExactKeys(value, expected, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) throw new Error(`${label}のkey一覧が不正です`);
}

function assertHash(value, label) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) throw new Error(`${label}のSHA-256が不正です`);
}

function rejectForbidden(value, path) {
  const forbidden = new Set(["stdout", "stderr", "arguments", "args", "value", "values", "pointer", "address", "sourcePath", "cwd"]);
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectForbidden(item, `${path}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (forbidden.has(key)) throw new Error(`native AOT artifactに禁止fieldがあります: ${path}.${key}`);
    rejectForbidden(item, `${path}.${key}`);
  }
}

function runSelfTest() {
  const records = [];
  for (const [runner, platform] of expectedPlatforms) {
    for (const group of expectedGroups.get(runner)) {
      const union = new Set();
      for (let shardIndex = 0; shardIndex < platform.shardCount; shardIndex += 1) {
        const ids = expectedShardIds(group, shardIndex, platform.shardCount);
        for (const id of ids) {
          if (union.has(id)) throw new Error(`self-testのshardが重複しています: ${runner}/${group.key}/${id}`);
          union.add(id);
        }
        const artifactName = `${runner}-${group.key}-${shardIndex}`;
        const artifact = syntheticArtifact(runner, group.key, shardIndex, ids);
        validateArtifact(artifact, { runner, shardIndex, optimizationKey: group.key, artifactName });
        records.push({ artifact });
      }
      if (union.size !== fixtures.length || expectedFixtureIds.some((id) => !union.has(id))) throw new Error(`self-testのshardが全件ではありません: ${runner}/${group.key}`);
    }
  }
  const expectedArtifactCount = [...expectedPlatforms].reduce((total, [runner, platform]) => total + platform.shardCount * expectedGroups.get(runner).length, 0);
  if (records.length !== expectedArtifactCount) throw new Error(`self-testのartifact総数が不正です: ${records.length}/${expectedArtifactCount}`);
  const artifact = records[0].artifact;
  const tampered = structuredClone(artifact);
  tampered.fixtures[0].equivalent = false;
  let rejected = false;
  try {
    validateArtifact(tampered, { runner: "ubuntu-24.04", shardIndex: 0, optimizationKey: "O0", artifactName: "synthetic" });
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error("self-testのtamper拒否に失敗しました");
}

function syntheticArtifact(runner, optimizationKey, shardIndex, ids) {
  const group = expectedGroups.get(runner).find((candidate) => candidate.key === optimizationKey);
  const hash = "a".repeat(64);
  const routes = ["officialSource", "officialGenerated", "lnakoRun", ...group.optimizations.map((optimization) => `lnakoNative${optimization}`)];
  const baseline = { repository: lock.nadesiko3.repository, tag: lock.nadesiko3.tag, commit: lock.nadesiko3.commit, archiveSha256: lock.nadesiko3.archive.sha256 };
  const fixtures_ = ids.map((id) => {
    const sourceFixture = fixtureById.get(id);
    const knownOracleSelection = sourceFixture.oracle ?? null;
    const comparedRoutes = routes.filter((route) => (knownOracleSelection !== "official-generated" || route !== "officialSource") && (knownOracleSelection !== "official-source" || route !== "officialGenerated"));
    return {
      id,
      knownOracleSelection,
      oracleRoute: knownOracleSelection === "official-generated" ? "officialGenerated" : "officialSource",
      comparedRoutes,
      equivalent: true,
      failureKinds: [],
      sourceSha256: sha256(sourceFixture.source),
      generatedJavaScriptSha256: null,
      results: Object.fromEntries(routes.map((route) => [route, { exitCode: 0, signal: null, stderrClass: "success", stdoutSha256: hash, stderrSha256: hash }])),
      compileStatuses: Object.fromEntries(group.optimizations.map((optimization) => [optimization, 0])),
      compileManifest: group.optimizations.includes("O0") ? { complete: true, entries: [] } : null,
    };
  });
  const platform = expectedPlatforms.get(runner);
  return {
    schema: "lnako.native-oracle-artifact.v3",
    generatedAt: new Date().toISOString(),
    baseline,
    oracle: {
      build: lock.nadesiko3.oracleIdentity.build,
      archiveSha256: baseline.archiveSha256,
      cliSha256: lock.nadesiko3.oracleIdentity.cliSha256,
      markerSha256: lock.nadesiko3.oracleIdentity.markerSha256,
      treeHashAlgorithm: lock.nadesiko3.oracleIdentity.treeHashAlgorithm,
      treeSha256: lock.nadesiko3.oracleIdentity.treeSha256ByPlatform[`${platform.platform}-${platform.arch}`],
    },
    lnako: { commit: expectedCommit, dirty: false },
    toolchain: { zig: toolchainLock.zig.version, llvm: toolchainLock.llvm.version, node: toolchainLock.node.version },
    artifactSha256: { compareScript: hash, lnakoBinary: hash },
    environment: { platform: platform.platform, arch: platform.arch, node: `v${toolchainLock.node.version}` },
    fixtureCount: fixtures_.length,
    routeCount: routes.length,
    routes,
    knownOracleSelections: {
      defaultOfficialSource: fixtures_.filter((fixture) => fixture.knownOracleSelection === null).length,
      officialSource: fixtures_.filter((fixture) => fixture.knownOracleSelection === "official-source").length,
      officialGenerated: fixtures_.filter((fixture) => fixture.knownOracleSelection === "official-generated").length,
    },
    status: "success",
    comparisonSucceeded: true,
    failureCount: 0,
    selection: platform.shardCount === 1
      ? { mode: "all", shardIndex: null, shardCount: 1, totalFixtureCount: fixtures.length, optimizations: group.optimizations }
      : { mode: "weighted-source-command", shardIndex, shardCount: platform.shardCount, totalFixtureCount: fixtures.length, optimizations: group.optimizations },
    fixtures: fixtures_,
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
