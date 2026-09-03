import { createHash } from "node:crypto";
import { access, readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { isAbsolute, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const toolchainLock = JSON.parse(await readFile(resolve(root, "toolchain.lock.json"), "utf8"));
const fixtureBytes = await readFile(resolve(root, "tests/oracle/native-cases.json"));
const fixtures = JSON.parse(fixtureBytes.toString("utf8"));
const fixtureIds = fixtures.map((fixture) => fixture.id);
const fixtureIdSet = new Set(fixtureIds);
const expectedPlatforms = [
  {
    target: "linux-x64",
    runner: "ubuntu-24.04",
    platform: "linux",
    arch: "x64",
    shardCount: 3,
    groups: [
      { key: "O0", optimizations: ["O0"] },
      { key: "O1", optimizations: ["O1"] },
      { key: "O2", optimizations: ["O2"] },
      { key: "O3", optimizations: ["O3"] },
    ],
  },
  {
    target: "macos-arm64",
    runner: "macos-15",
    platform: "darwin",
    arch: "arm64",
    shardCount: 1,
    groups: [
      { key: "O0-O1", optimizations: ["O0", "O1"] },
      { key: "O2", optimizations: ["O2"] },
      { key: "O3", optimizations: ["O3"] },
    ],
  },
  {
    target: "windows-x64",
    runner: "windows-2025",
    platform: "win32",
    arch: "x64",
    shardCount: 3,
    groups: [
      { key: "O0", optimizations: ["O0"] },
      { key: "O1", optimizations: ["O1"] },
      { key: "O2", optimizations: ["O2"] },
      { key: "O3", optimizations: ["O3"] },
    ],
  },
];
const expectedArtifactCount = expectedPlatforms.reduce((total, platform) => total + platform.shardCount * platform.groups.length, 0);
if (!Array.isArray(fixtures) || fixtures.length !== 292 || fixtures.some((fixture) => fixture === null || typeof fixture !== "object" || Array.isArray(fixture))) {
  throw new Error("native-cases.jsonのfixture集合が不正です");
}
if (fixtureIds.some((id) => typeof id !== "string" || id.length === 0) || fixtureIdSet.size !== fixtures.length) throw new Error("native-cases.jsonのfixture IDが不正です");

const evidenceBytes = await readFile(options.evidence);
const evidence = JSON.parse(evidenceBytes.toString("utf8"));
validateAggregate(evidence);
const evidenceSha256 = sha256(evidenceBytes);
const bundleBytes = await readFile(options.bundle);
const bundleSha256 = sha256(bundleBytes);
verifyWithGh(options.evidence, evidenceSha256);

const attestation = {
  schema: "lnako.native-aot-attestation.v1",
  repository: options.repository,
  workflow: options.workflow,
  sourceRef: options.sourceRef,
  commit: options.commit,
  predicateType: "https://slsa.dev/provenance/v1",
  verifiedBy: "gh attestation verify",
  bundleSha256,
  subject: {
    file: "lnako-native-aot-aggregate-evidence.json",
    sha256: evidenceSha256,
    targetCount: evidence.targets.length,
    artifactCount: expectedArtifactCount,
    fixtureCount: evidence.fixtureSet.fixtureCount,
  },
};
await writeExclusive(options.output, `${JSON.stringify(attestation, null, 2)}\n`);
console.log(`native AOT aggregate attestationを検証しました: ${evidence.targets.length} OS / ${expectedArtifactCount} artifact / ${evidence.fixtureSet.fixtureCount} fixture`);

function parseArguments(arguments_) {
  const allowed = new Set(["--evidence", "--bundle", "--output", "--repository", "--commit", "--source-ref", "--workflow"]);
  if (arguments_.some((argument) => argument.startsWith("--") && !allowed.has(argument))) throw new Error("未知のオプションです");
  const valueFor = (name) => {
    const indexes = arguments_.flatMap((argument, index) => argument === name ? [index] : []);
    if (indexes.length !== 1) return null;
    const value = arguments_[indexes[0] + 1];
    if (value === undefined || value.startsWith("--")) throw new Error(`${name}の値がありません`);
    return value;
  };
  const absoluteFor = (name) => {
    const value = valueFor(name);
    if (value === null) return null;
    if (!isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
    return resolve(value);
  };
  const parsed = {
    evidence: absoluteFor("--evidence"),
    bundle: absoluteFor("--bundle"),
    output: absoluteFor("--output"),
    repository: valueFor("--repository"),
    commit: valueFor("--commit"),
    sourceRef: valueFor("--source-ref"),
    workflow: valueFor("--workflow"),
  };
  if (Object.values(parsed).some((value) => value === null) || !/^[0-9a-f]{40}$/i.test(parsed.commit) ||
      parsed.repository !== "soramikan/lnako" || parsed.sourceRef !== "refs/heads/main" ||
      parsed.workflow !== "soramikan/lnako/.github/workflows/ci.yml") {
    throw new Error("native AOT attestation検証のidentity引数が不正です");
  }
  return parsed;
}

function validateAggregate(aggregate) {
  rejectForbidden(aggregate);
  assertExactKeys(aggregate, ["schema", "generator", "generatedAt", "baseline", "commit", "toolchain", "fixtureSet", "targets"], "native AOT aggregate");
  if (aggregate.schema !== "lnako.native-aot-aggregate-evidence.v1" || aggregate.generator !== "tools/check_native_aot_artifacts.mjs" ||
      typeof aggregate.generatedAt !== "string" || Number.isNaN(Date.parse(aggregate.generatedAt)) || aggregate.commit !== options.commit) {
    throw new Error("native AOT aggregateのschema／generator／commitが不正です");
  }
  assertExactKeys(aggregate.baseline, ["repository", "tag", "commit", "archiveSha256"], "native AOT aggregate.baseline");
  if (aggregate.baseline.repository !== lock.nadesiko3.repository || aggregate.baseline.tag !== lock.nadesiko3.tag ||
      aggregate.baseline.commit !== lock.nadesiko3.commit || aggregate.baseline.archiveSha256 !== lock.nadesiko3.archive.sha256) {
    throw new Error("native AOT aggregateの公式baselineが不正です");
  }
  assertExactKeys(aggregate.toolchain, ["zig", "llvm", "node"], "native AOT aggregate.toolchain");
  if (aggregate.toolchain.zig !== toolchainLock.zig.version || aggregate.toolchain.llvm !== toolchainLock.llvm.version || aggregate.toolchain.node !== toolchainLock.node.version) {
    throw new Error("native AOT aggregateのtoolchainが不正です");
  }
  assertExactKeys(aggregate.fixtureSet, ["file", "sha256", "fixtureCount", "commandNameCount"], "native AOT aggregate.fixtureSet");
  const expectedCommandNameCount = new Set(fixtures.flatMap((fixture) => fixture.commands ?? [])).size;
  if (aggregate.fixtureSet.file !== "tests/oracle/native-cases.json" || aggregate.fixtureSet.sha256 !== sha256(fixtureBytes) ||
      aggregate.fixtureSet.fixtureCount !== fixtures.length || aggregate.fixtureSet.commandNameCount !== expectedCommandNameCount) {
    throw new Error("native AOT aggregateのfixture setが不正です");
  }
  if (!Array.isArray(aggregate.targets) || aggregate.targets.length !== expectedPlatforms.length) throw new Error("native AOT aggregateのOS集合が不正です");
  const artifactNames = new Set();
  for (const [index, target] of aggregate.targets.entries()) {
    const expected = expectedPlatforms[index];
    assertExactKeys(target, ["target", "runner", "environment", "artifactCount", "fixtureCount", "optimizationGroups"], `native AOT aggregate.targets[${index}]`);
    if (target.target !== expected.target || target.runner !== expected.runner || target.artifactCount !== expected.shardCount * expected.groups.length ||
        target.fixtureCount !== fixtures.length) throw new Error(`native AOT aggregateのtarget metadataが不正です: ${expected.target}`);
    assertExactKeys(target.environment, ["platform", "arch"], `native AOT aggregate.targets[${index}].environment`);
    if (target.environment.platform !== expected.platform || target.environment.arch !== expected.arch) throw new Error(`native AOT aggregateのtarget environmentが不正です: ${expected.target}`);
    if (!Array.isArray(target.optimizationGroups) || target.optimizationGroups.length !== expected.groups.length) throw new Error(`native AOT aggregateのoptimization group数が不正です: ${expected.target}`);
    for (const [groupIndex, group] of target.optimizationGroups.entries()) {
      const expectedGroup = expected.groups[groupIndex];
      assertExactKeys(group, ["optimizationKey", "optimizations", "shardCount", "fixtureCount", "artifacts"], `${expected.target}.optimizationGroups[${groupIndex}]`);
      if (group.optimizationKey !== expectedGroup.key || JSON.stringify(group.optimizations) !== JSON.stringify(expectedGroup.optimizations) ||
          group.shardCount !== expected.shardCount || group.fixtureCount !== fixtures.length || !Array.isArray(group.artifacts) || group.artifacts.length !== expected.shardCount) {
        throw new Error(`native AOT aggregateのoptimization groupが不正です: ${expected.target}/${expectedGroup.key}`);
      }
      const groupIds = new Set();
      for (const [shardIndex, artifact] of group.artifacts.entries()) {
        assertExactKeys(artifact, ["shardIndex", "artifactName", "artifactSha256", "fixtureCount", "fixtureIds"], `${expected.target}/${expectedGroup.key}.artifact`);
        const expectedIds = expectedShardIds(shardIndex, expected.shardCount);
        const expectedArtifactName = `lnako-native-oracle-${expected.runner}-shard-${shardIndex}-${expectedGroup.key}`;
        if (artifact.shardIndex !== shardIndex || artifact.artifactName !== expectedArtifactName || artifactNames.has(artifact.artifactName) ||
            !/^[0-9a-f]{64}$/.test(artifact.artifactSha256) || artifact.fixtureCount !== expectedIds.length ||
            JSON.stringify(artifact.fixtureIds) !== JSON.stringify(expectedIds)) {
          throw new Error(`native AOT aggregateのartifactが不正です: ${expected.target}/${expectedGroup.key}/${shardIndex}`);
        }
        artifactNames.add(artifact.artifactName);
        for (const id of artifact.fixtureIds) {
          if (!fixtureIdSet.has(id) || groupIds.has(id)) throw new Error(`native AOT aggregateのfixture partitionが不正です: ${expected.target}/${expectedGroup.key}/${id}`);
          groupIds.add(id);
        }
      }
      if (groupIds.size !== fixtures.length) throw new Error(`native AOT aggregateのfixture全件性が不正です: ${expected.target}/${expectedGroup.key}`);
    }
  }
  if (artifactNames.size !== expectedArtifactCount) throw new Error(`native AOT aggregateのartifact総数が不正です: ${artifactNames.size}/${expectedArtifactCount}`);
}

function expectedShardIds(shardIndex, shardCount) {
  if (shardCount === 1) return fixtureIds;
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

function verifyWithGh(evidencePath, digest) {
  const result = spawnSync("gh", [
    "attestation", "verify", evidencePath,
    "--bundle", options.bundle,
    "--repo", options.repository,
    "--signer-workflow", options.workflow,
    "--signer-digest", options.commit,
    "--source-digest", options.commit,
    "--source-ref", options.sourceRef,
    "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
    "--deny-self-hosted-runners",
    "--predicate-type", "https://slsa.dev/provenance/v1",
    "--format", "json",
  ], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`公式gh attestation verifyに失敗しました: ${result.stderr}`);
  let entries;
  try {
    entries = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`gh attestation verifyのJSON出力が不正です: ${error.message}`);
  }
  if (!Array.isArray(entries) || entries.length === 0) throw new Error("gh attestation verifyが検証済みattestationを返しませんでした");
  const matched = entries.some((entry) => (entry.verificationResult?.statement?.subject ?? []).some((subject) => {
    if (Array.isArray(subject.digest)) return subject.digest.some((value) => value.algorithm === "sha256" && value.value === digest);
    return subject.digest?.sha256 === digest;
  }));
  if (!matched) throw new Error("検証済みattestationのsubject digestがnative AOT aggregateと一致しません");
}

function rejectForbidden(value, path = "native-aot-aggregate") {
  const forbidden = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address", "cwd"]);
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectForbidden(item, `${path}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (forbidden.has(key)) throw new Error(`native AOT aggregateに禁止fieldがあります: ${path}.${key}`);
    rejectForbidden(item, `${path}.${key}`);
  }
}

function assertExactKeys(value, expected, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) {
    throw new Error(`${label}のkey一覧が不正です`);
  }
}

async function writeExclusive(path, content) {
  try {
    await access(path);
    throw new Error(`出力先は既に存在します: ${path}`);
  } catch (error) {
    if (error?.message?.startsWith("出力先は既に存在します")) throw error;
    if (error?.code !== "ENOENT") throw error;
  }
  await writeFile(path, content, { encoding: "utf8", flag: "wx" });
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
