import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { platformIndependentOfficialComparison } from "./dispatch_evidence_semantics.mjs";

const root = resolve(import.meta.dirname, "..");
const defaultDirectory = resolve(root, "compat/v3.7.24/attestations/32983175945");
const arguments_ = process.argv.slice(2);
const offline = arguments_.includes("--offline");
const directoryIndex = arguments_.indexOf("--directory");
if (arguments_.some((argument) => argument.startsWith("--") && argument !== "--directory" && argument !== "--offline") ||
    (directoryIndex >= 0 && (arguments_[directoryIndex + 1] === undefined || arguments_[directoryIndex + 1].startsWith("--")))) {
  throw new Error("usage: node tools/check_tracked_dispatch_attestation.mjs [--directory /absolute/path] [--offline]");
}
const directory = directoryIndex >= 0 ? resolveAbsolute(arguments_[directoryIndex + 1], "--directory") : defaultDirectory;

const expected = {
  schema: "lnako.dispatch-evidence-history.v1",
  run: "32983175945",
  attempt: 1,
  commit: "1ee47232d34711abaddb28038218258232ac3800",
  sourceRef: "refs/heads/main",
  workflow: "soramikan/lnako/.github/workflows/ci.yml",
  workflowIdentity: "https://github.com/soramikan/lnako/.github/workflows/ci.yml@refs/heads/main",
  predicateType: "https://slsa.dev/provenance/v1",
};
const expectedPlatforms = new Map([
  ["darwin-arm64", { platform: "darwin", arch: "arm64", runner: "macos-15", file: "dispatch-evidence-macos-15.json" }],
  ["linux-x64", { platform: "linux", arch: "x64", runner: "ubuntu-24.04", file: "dispatch-evidence-ubuntu-24.04.json" }],
  ["win32-x64", { platform: "win32", arch: "x64", runner: "windows-2025", file: "dispatch-evidence-windows-2025.json" }],
]);
const forbiddenFields = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address"]);
const standardCatalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));

const manifest = await readJson("manifest.json");
assertKeys(manifest, ["schema", "workflowRun", "workflowAttempt", "targetCommit", "sourceRef", "workflow", "attestation", "bundle", "catalogEvidenceUnattested", "catalogEvidence", "dispatchEvidence", "artifactSha256"], "manifest");
assertEqual(manifest.schema, expected.schema, "manifest schema");
assertEqual(manifest.workflowRun, expected.run, "workflow run");
assertEqual(manifest.workflowAttempt, expected.attempt, "workflow attempt");
assertEqual(manifest.targetCommit, expected.commit, "target commit");
assertEqual(manifest.sourceRef, expected.sourceRef, "source ref");
assertEqual(manifest.workflow, expected.workflow, "workflow");
assertEqual(manifest.attestation, "dispatch-attestation.json", "attestation path");
assertEqual(manifest.bundle, "sigstore-bundle.json", "bundle path");
assertEqual(manifest.catalogEvidenceUnattested, "catalog-evidence-unattested.json", "base catalog path");
assertEqual(manifest.catalogEvidence, "catalog-evidence-verified.json", "catalog path");
assertKeys(manifest.artifactSha256, ["dispatch-attestation.json", "sigstore-bundle.json", "catalog-evidence-unattested.json", "catalog-evidence-verified.json"], "manifest artifact digests");
for (const [name, digest] of Object.entries(manifest.artifactSha256)) assertSha256(digest, `manifest ${name} digest`);
assertNoForbiddenFields(manifest, "manifest");

if (!Array.isArray(manifest.dispatchEvidence) || manifest.dispatchEvidence.length !== expectedPlatforms.size) {
  throw new Error("tracked dispatch evidenceは3正式OSの完全集合でなければなりません");
}
const manifestSubjects = new Map();
for (const record of manifest.dispatchEvidence) {
  assertKeys(record, ["platform", "arch", "runner", "path", "sha256"], "dispatch manifest entry");
  const platformKey = `${record.platform}-${record.arch}`;
  const platform = expectedPlatforms.get(platformKey);
  if (platform === undefined || manifestSubjects.has(platformKey)) throw new Error(`dispatch manifestのOSが不正です: ${platformKey}`);
  assertEqual(record.runner, platform.runner, `${platformKey} runner`);
  assertEqual(record.path, `dispatch/${platform.file}`, `${platformKey} path`);
  assertSha256(record.sha256, `${platformKey} digest`);
  const path = safeChild(record.path, `${platformKey} path`);
  const bytes = await readFile(path);
  assertEqual(sha256(bytes), record.sha256, `${platformKey} file digest`);
  const evidence = JSON.parse(bytes.toString("utf8"));
  validateDispatchEvidence(evidence, platformKey, record.sha256);
  manifestSubjects.set(platformKey, { ...record, evidence });
}
if (manifestSubjects.size !== expectedPlatforms.size) throw new Error("dispatch manifestのOS集合が不完全です");

const attestation = await readJson(manifest.attestation);
assertEqual(sha256(await readFile(safeChild(manifest.attestation, "attestation path"))), manifest.artifactSha256[manifest.attestation], "attestation digest");
assertKeys(attestation, ["schema", "repository", "workflow", "sourceRef", "commit", "predicateType", "verifiedBy", "bundleSha256", "subjects"], "dispatch attestation");
assertEqual(attestation.schema, "lnako.dispatch-attestation.v1", "attestation schema");
assertEqual(attestation.repository, "soramikan/lnako", "attestation repository");
assertEqual(attestation.workflow, expected.workflow, "attestation workflow");
assertEqual(attestation.sourceRef, expected.sourceRef, "attestation source ref");
assertEqual(attestation.commit, expected.commit, "attestation commit");
assertEqual(attestation.predicateType, expected.predicateType, "attestation predicate type");
assertEqual(attestation.verifiedBy, "gh attestation verify", "attestation verifier");
assertNoForbiddenFields(attestation, "dispatch attestation");
const attestationSubjects = subjectMap(attestation.subjects, "dispatch attestation subjects");
assertSubjectDigests(attestationSubjects, manifestSubjects, "dispatch attestation");

const bundleBytes = await readFile(safeChild(manifest.bundle, "bundle path"));
assertSha256(attestation.bundleSha256, "attestation bundle digest");
assertEqual(sha256(bundleBytes), attestation.bundleSha256, "bundle digest");
assertEqual(sha256(bundleBytes), manifest.artifactSha256[manifest.bundle], "manifest bundle digest");
const bundle = JSON.parse(bundleBytes.toString("utf8"));
assertKeys(bundle, ["mediaType", "verificationMaterial", "dsseEnvelope"], "Sigstore bundle");
assertEqual(bundle.mediaType, "application/vnd.dev.sigstore.bundle.v0.3+json", "Sigstore bundle media type");
const envelope = bundle.dsseEnvelope;
assertKeys(envelope, ["payloadType", "payload", "signatures"], "DSSE envelope");
assertEqual(envelope.payloadType, "application/vnd.in-toto+json", "DSSE payload type");
if (!Array.isArray(envelope.signatures) || envelope.signatures.length === 0) throw new Error("Sigstore bundleに署名がありません");
const statement = JSON.parse(Buffer.from(envelope.payload, "base64").toString("utf8"));
assertKeys(statement, ["_type", "subject", "predicateType", "predicate"], "in-toto statement");
assertEqual(statement.predicateType, expected.predicateType, "bundle predicate type");
const bundleSubjects = subjectMap(statement.subject, "bundle subjects");
assertSubjectDigests(bundleSubjects, manifestSubjects, "bundle subjects");
const workflow = statement.predicate?.buildDefinition?.externalParameters?.workflow;
assertEqual(workflow?.repository, "https://github.com/soramikan/lnako", "bundle workflow repository");
assertEqual(workflow?.path, ".github/workflows/ci.yml", "bundle workflow path");
assertEqual(workflow?.ref, expected.sourceRef, "bundle workflow ref");
assertEqual(statement.predicate?.buildDefinition?.internalParameters?.github?.event_name, "push", "bundle event");
assertEqual(statement.predicate?.buildDefinition?.internalParameters?.github?.runner_environment, "github-hosted", "bundle runner environment");
assertEqual(statement.predicate?.runDetails?.builder?.id, expected.workflowIdentity, "bundle workflow identity");
const invocationId = statement.predicate?.runDetails?.metadata?.invocationId;
if (invocationId !== `https://github.com/soramikan/lnako/actions/runs/${expected.run}/attempts/${expected.attempt}`) {
  throw new Error(`bundle invocation identityが不正です: ${invocationId}`);
}
const dependency = statement.predicate?.buildDefinition?.resolvedDependencies?.find((entry) => entry.digest?.gitCommit === expected.commit);
if (dependency === undefined) throw new Error("bundleに対象commitのresolved dependencyがありません");
if (!offline) {
  for (const subject of manifestSubjects.values()) verifyWithGh(safeChild(subject.path, "dispatch evidence path"), subject.sha256, safeChild(manifest.bundle, "bundle path"));
}

const baseCatalog = await readJson(manifest.catalogEvidenceUnattested);
assertEqual(sha256(await readFile(safeChild(manifest.catalogEvidenceUnattested, "base catalog path"))), manifest.artifactSha256[manifest.catalogEvidenceUnattested], "base catalog digest");
validateBaseCatalog(baseCatalog, manifestSubjects);
const catalog = await readJson(manifest.catalogEvidence);
assertEqual(sha256(await readFile(safeChild(manifest.catalogEvidence, "catalog path"))), manifest.artifactSha256[manifest.catalogEvidence], "catalog digest");
assertNoForbiddenFields(catalog, "catalog evidence");
assertEqual(catalog.schemaVersion, 2, "catalog schema");
assertEqual(catalog.commandCount, 527, "catalog command count");
assertEqual(catalog.executionEvidenceStates?.verified, 4, "historical catalog verified count");
assertEqual(catalog.executionEvidenceStates?.["trace-confirmed-unattested"], 0, "historical catalog unattested count");
assertEqual(catalog.executionEvidenceStates?.unverified, 523, "historical catalog unverified count");
validateHistoricalCatalog(baseCatalog, catalog, manifestSubjects);

const currentEvidence = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/evidence.json"), "utf8"));
assertEqual(currentEvidence.executionEvidenceStates?.verified, 0, "current catalog verified count");
console.log(`追跡dispatch attestationを検証しました: run ${expected.run} / target ${expected.commit} / 3 OS / historical verified 4（current verified 0）`);

function verifyWithGh(evidencePath, digest, bundlePath) {
  const result = spawnSync("gh", [
    "attestation", "verify", evidencePath,
    "--bundle", bundlePath,
    "--repo", "soramikan/lnako",
    "--signer-workflow", "soramikan/lnako/.github/workflows/ci.yml",
    "--signer-digest", expected.commit,
    "--source-digest", expected.commit,
    "--source-ref", expected.sourceRef,
    "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
    "--deny-self-hosted-runners",
    "--predicate-type", expected.predicateType,
    "--format", "json",
  ], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`公式gh attestation verifyに失敗しました: ${evidencePath}`);
  let entries;
  try {
    entries = JSON.parse(result.stdout);
  } catch {
    throw new Error(`gh attestation verifyのJSON出力が不正です: ${evidencePath}`);
  }
  if (!Array.isArray(entries) || entries.length === 0) throw new Error(`gh attestation verifyが検証済みattestationを返しませんでした: ${evidencePath}`);
  const matched = entries.some((entry) => (entry.verificationResult?.statement?.subject ?? []).some((subject) => {
    if (Array.isArray(subject.digest)) return subject.digest.some((value) => value.algorithm === "sha256" && value.value === digest);
    return subject.digest?.sha256 === digest;
  }));
  if (!matched) throw new Error(`検証済みattestationのsubject digestが不一致です: ${evidencePath}`);
}

function validateBaseCatalog(base, subjects) {
  assertNoForbiddenFields(base, "base catalog");
  assertKeys(base, ["schemaVersion", "baseline", "sourceSha256", "commandCount", "duplicateNameCount", "fixtureInventory", "fixtureCoverageStates", "executionEvidenceStates", "entries"], "base catalog");
  assertEqual(base.schemaVersion, 2, "base catalog schema");
  assertEqual(base.commandCount, 527, "base catalog command count");
  assertKeys(base.executionEvidenceStates, ["verified", "trace-confirmed-unattested", "unverified"], "base catalog execution states");
  assertEqual(base.executionEvidenceStates?.verified, 0, "base catalog verified count");
  assertEqual(base.executionEvidenceStates?.["trace-confirmed-unattested"], 4, "base catalog unattested count");
  assertEqual(base.executionEvidenceStates?.unverified, 523, "base catalog unverified count");
  if (!Array.isArray(base.entries) || base.entries.length !== standardCatalog.commands.length) throw new Error("base catalog entry数がstandard catalogと一致しません");
  const dispatchIds = dispatchSiteSummary(subjects);
  const entriesById = new Map();
  for (const [index, entry] of base.entries.entries()) {
    const standard = standardCatalog.commands[index];
    if (standard === undefined || entry.id !== standard.id || entry.name !== standard.name || entry.plugin !== standard.plugin || entry.status !== standard.status) {
      throw new Error(`base catalogの標準ID/name/plugin/statusが不一致です: ${entry.id}`);
    }
    if (entriesById.has(entry.id)) throw new Error(`base catalog IDが重複しています: ${entry.id}`);
    entriesById.set(entry.id, entry);
    const promoted = dispatchIds.has(entry.id);
    if (promoted !== (entry.executionEvidenceState === "trace-confirmed-unattested")) throw new Error(`base catalogのdispatch stateが不一致です: ${entry.id}`);
    if (promoted) {
      const summary = dispatchIds.get(entry.id);
      if (JSON.stringify([...new Set(entry.executionEvidence?.siteIds ?? [])].sort()) !== JSON.stringify([...summary.siteIds].sort()) ||
          JSON.stringify(entry.executionEvidence?.officialComparison) !== JSON.stringify(summary.officialComparison)) {
        throw new Error(`base catalogのexecution evidenceがdispatchから導出できません: ${entry.id}`);
      }
    } else if (entry.executionEvidence !== null) throw new Error(`未検証entryにexecution evidenceがあります: ${entry.id}`);
  }
  if (dispatchIds.size !== 4) throw new Error(`署名dispatchの昇格対象IDが4件ではありません: ${dispatchIds.size}`);
  validateCatalogEntryStates(base, dispatchIds, "trace-confirmed-unattested", "base catalog");
}

function validateHistoricalCatalog(base, historical, subjects) {
  const derived = structuredClone(base);
  derived.executionEvidenceStates = { verified: 4, "trace-confirmed-unattested": 0, unverified: 523 };
  const dispatchIds = dispatchSiteSummary(subjects);
  let promoted = 0;
  for (const entry of derived.entries) {
    if (!dispatchIds.has(entry.id)) continue;
    promoted += 1;
    entry.executionEvidenceState = "verified";
    entry.executionEvidence.state = "verified";
    entry.reason = entry.reason
      .replace("成功を機械検証した（", "成功と外部attestationを機械検証した（")
      .replace("。外部attestation未導入のためexecutionEvidenceState=trace-confirmed-unattestedであり、verifiedへは昇格しない。", "。executionEvidenceState=verified。");
  }
  if (promoted !== 4) throw new Error(`historical catalogの昇格対象が4件ではありません: ${promoted}`);
  if (JSON.stringify(derived) !== JSON.stringify(historical)) throw new Error("historical catalog evidenceがbase catalogと署名dispatchから導出できません");
  validateCatalogEntryStates(historical, dispatchIds, "verified", "historical catalog");
}

function validateCatalogEntryStates(catalog, dispatchIds, dispatchState, label) {
  if (!Array.isArray(catalog.entries) || catalog.entries.length !== 527) throw new Error(`${label} entry数が527件ではありません`);
  const counts = { verified: 0, "trace-confirmed-unattested": 0, unverified: 0 };
  const stateIds = new Map([["verified", new Set()], ["trace-confirmed-unattested", new Set()], ["unverified", new Set()]]);
  for (const entry of catalog.entries) {
    if (!Object.hasOwn(counts, entry.executionEvidenceState)) throw new Error(`${label}に未知のexecutionEvidenceStateがあります: ${entry.id}`);
    counts[entry.executionEvidenceState] += 1;
    stateIds.get(entry.executionEvidenceState).add(entry.id);
    const promoted = dispatchIds.has(entry.id);
    if (promoted) {
      if (entry.executionEvidenceState !== dispatchState || entry.identityResolution !== "unique-name") throw new Error(`${label}のdispatch entry state／identityが不正です: ${entry.id}`);
      assertKeys(entry.executionEvidence, ["proofSchema", "fixtureId", "siteIds", "officialComparison", "state"], `${label} execution evidence`);
      assertEqual(entry.executionEvidence.proofSchema, "lnako.dispatch-evidence.v2", `${label} proof schema`);
      assertEqual(entry.executionEvidence.fixtureId, "native-cut-commands", `${label} fixture ID`);
      assertEqual(entry.executionEvidence.state, dispatchState, `${label} execution evidence state`);
      const summary = dispatchIds.get(entry.id);
      assertEqual(JSON.stringify([...new Set(entry.executionEvidence.siteIds)].sort()), JSON.stringify([...summary.siteIds].sort()), `${label} site IDs`);
      assertEqual(JSON.stringify(entry.executionEvidence.officialComparison), JSON.stringify(summary.officialComparison), `${label} official comparison routes`);
    } else {
      if (entry.executionEvidenceState !== "unverified" || entry.executionEvidence !== null) throw new Error(`${label}非dispatch entryのstate／evidenceが不正です: ${entry.id}`);
    }
  }
  assertEqual(JSON.stringify(counts), JSON.stringify({ verified: dispatchState === "verified" ? 4 : 0, "trace-confirmed-unattested": dispatchState === "trace-confirmed-unattested" ? 4 : 0, unverified: 523 }), `${label} state再集計`);
  assertEqual(JSON.stringify([...stateIds.get(dispatchState)].sort()), JSON.stringify([...dispatchIds.keys()].sort()), `${label} dispatch ID集合`);
  for (const [state, ids] of stateIds) if (state !== dispatchState && state !== "unverified" && ids.size !== 0) throw new Error(`${label}に不正な昇格IDがあります`);
}

function dispatchSiteSummary(subjects) {
  const result = new Map();
  let semantic = null;
  for (const subject of subjects.values()) {
    const evidence = subject.evidence;
    const currentSemantic = JSON.stringify({ baseline: evidence.baseline, fixture: evidence.fixture, officialComparison: platformIndependentOfficialComparison(evidence.officialComparison), sites: evidence.sites, trace: evidence.trace });
    if (semantic === null) semantic = currentSemantic;
    else if (semantic !== currentSemantic) throw new Error("3 OSのdispatch evidence意味内容が一致しません");
    for (const site of evidence.sites) {
      const summary = result.get(site.catalogId) ?? { siteIds: new Set(), routes: new Set(), officialComparison: evidence.officialComparison.routes };
      summary.siteIds.add(site.siteId);
      summary.routes.add(site.route);
      result.set(site.catalogId, summary);
    }
  }
  return result;
}

async function readJson(name) {
  return JSON.parse(await readFile(resolve(directory, name), "utf8"));
}

function safeChild(name, label) {
  if (isAbsolute(name) || name.includes("\\") || name.split("/").includes("..")) throw new Error(`${label}が安全な相対パスではありません`);
  const path = resolve(directory, name);
  if (relative(directory, path).startsWith("..")) throw new Error(`${label}がスナップショット外です`);
  return path;
}

function validateDispatchEvidence(evidence, platformKey, digest) {
  assertKeys(evidence, ["schema", "generator", "fixture", "baseline", "provenance", "officialComparison", "sites", "trace", "attestation"], `${platformKey} dispatch evidence`);
  assertEqual(evidence.schema, "lnako.dispatch-evidence.v2", `${platformKey} evidence schema`);
  assertEqual(evidence.generator, "tools/check_dispatch_trace.mjs", `${platformKey} evidence generator`);
  assertEqual(evidence.fixture?.id, "native-cut-commands", `${platformKey} fixture`);
  assertEqual(evidence.provenance?.lnako?.commit, expected.commit, `${platformKey} evidence commit`);
  assertEqual(evidence.provenance?.lnako?.dirty, false, `${platformKey} clean tree`);
  assertEqual(`${evidence.provenance?.environment?.platform}-${evidence.provenance?.environment?.arch}`, platformKey, `${platformKey} evidence platform`);
  assertEqual(evidence.officialComparison?.oracle, "official-source", `${platformKey} official oracle`);
  assertEqual(JSON.stringify(evidence.officialComparison?.routes), JSON.stringify(["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"]), `${platformKey} official routes`);
  assertEqual(evidence.officialComparison?.equivalent, true, `${platformKey} official comparison`);
  const officialSource = evidence.officialComparison.results?.officialSource;
  for (const route of ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"]) {
    const result = evidence.officialComparison.results?.[route];
    assertKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `${platformKey} official result`);
    assertEqual(result.status, 0, `${platformKey} ${route} status`);
    assertEqual(result.signal, null, `${platformKey} ${route} signal`);
    assertSha256(result.stdoutSha256, `${platformKey} ${route} stdout digest`);
    assertSha256(result.stderrSha256, `${platformKey} ${route} stderr digest`);
    assertEqual(result.stdoutSha256, officialSource.stdoutSha256, `${platformKey} ${route} stdout equivalence`);
    assertEqual(result.stderrSha256, officialSource.stderrSha256, `${platformKey} ${route} stderr equivalence`);
  }
  assertEqual(evidence.trace?.interpreter?.schema, 2, `${platformKey} interpreter trace schema`);
  assertEqual(evidence.trace?.aot?.schema, 2, `${platformKey} AOT trace schema`);
  if (!Number.isSafeInteger(evidence.trace?.interpreter?.eventCount) || !Number.isSafeInteger(evidence.trace?.aot?.eventCount) || evidence.trace.interpreter.eventCount < 1 || evidence.trace.aot.eventCount < 1) throw new Error(`${platformKey} trace eventCountが不正です`);
  assertEqual(evidence.attestation, null, `${platformKey} embedded attestation`);
  if (!Array.isArray(evidence.sites) || evidence.sites.length !== 35) throw new Error(`${platformKey} dispatch site countが不正です`);
  const standardById = new Map(standardCatalog.commands.map((command) => [command.id, command]));
  const siteIds = new Set();
  for (const site of evidence.sites) {
    assertKeys(site, ["catalogId", "name", "plugin", "siteId", "sourceName", "canonicalOpcode", "opcode", "route", "runtime", "officialEquivalent"], `${platformKey} dispatch site`);
    assertKeys(site.runtime, ["interpreter", "aot"], `${platformKey} dispatch runtime`);
    assertKeys(site.runtime.interpreter, ["result", "route", "count"], `${platformKey} interpreter runtime`);
    assertKeys(site.runtime.aot, ["success", "callId", "count"], `${platformKey} AOT runtime`);
    if (siteIds.has(site.siteId) || !/^0x[0-9a-f]{16}$/.test(site.siteId)) throw new Error(`${platformKey} siteIdが不正または重複しています`);
    siteIds.add(site.siteId);
    const command = standardById.get(site.catalogId);
    if (command === undefined || command.name !== site.name || command.plugin !== site.plugin || command.name !== site.sourceName) throw new Error(`${platformKey} catalog identityが不正です: ${site.catalogId}`);
    if (standardCatalog.commands.filter((candidate) => candidate.name === site.name).length !== 1) throw new Error(`${platformKey} 曖昧な命令を昇格できません: ${site.name}`);
    assertEqual(site.runtime.interpreter.result, "success", `${platformKey} interpreter success`);
    assertEqual(site.runtime.aot.success, true, `${platformKey} AOT success`);
    if (!Number.isSafeInteger(site.runtime.interpreter.count) || site.runtime.interpreter.count < 1 || !Number.isSafeInteger(site.runtime.aot.callId) || !Number.isSafeInteger(site.runtime.aot.count) || site.runtime.aot.count < 1) throw new Error(`${platformKey} runtime countが不正です`);
    assertEqual(site.officialEquivalent, true, `${platformKey} site official equivalence`);
  }
  if (evidence.sites.length > evidence.trace.interpreter.eventCount || evidence.trace.aot.eventCount < evidence.sites.length * 2) throw new Error(`${platformKey} trace eventCountがsite数と整合しません`);
  assertNoForbiddenFields(evidence, `${platformKey} dispatch evidence`);
  if (digest !== undefined) assertSha256(digest, `${platformKey} digest`);
}

function subjectMap(subjects, label) {
  if (!Array.isArray(subjects) || subjects.length !== expectedPlatforms.size) throw new Error(`${label}は3 subjectの完全集合でなければなりません`);
  const result = new Map();
  for (const subject of subjects) {
    if (typeof subject?.platform === "string") {
      assertKeys(subject, ["platform", "arch", "evidenceSha256"], label);
      const key = `${subject.platform}-${subject.arch}`;
      assertSha256(subject.evidenceSha256, `${label} ${key}`);
      if (result.has(key)) throw new Error(`${label}に重複OSがあります: ${key}`);
      result.set(key, subject.evidenceSha256);
    } else {
      assertKeys(subject, ["name", "digest"], label);
      assertSha256(subject.digest?.sha256, `${label} ${subject.name}`);
      if (result.has(subject.name)) throw new Error(`${label}に重複subjectがあります: ${subject.name}`);
      result.set(subject.name, subject.digest.sha256);
    }
  }
  return result;
}

function assertSubjectDigests(actual, expectedSubjects, label) {
  const expectedByDigest = new Map([...expectedSubjects].map(([key, value]) => [value.sha256 ?? value, key]));
  if (actual.size !== expectedSubjects.size) throw new Error(`${label} subject数が不正です`);
  const actualDigests = new Set(actual.values());
  const expectedDigests = new Set([...expectedSubjects.values()].map((value) => value.sha256 ?? value));
  if (JSON.stringify([...actualDigests].sort()) !== JSON.stringify([...expectedDigests].sort())) {
    throw new Error(`${label} subject digest集合がmanifestと一致しません`);
  }
  for (const digest of actualDigests) if (!expectedByDigest.has(digest)) throw new Error(`${label}に未知のdigestがあります: ${digest}`);
}

function assertKeys(value, keys, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...keys].sort())) {
    throw new Error(`${label}のfield集合が不正です`);
  }
}

function assertNoForbiddenFields(value, label, path = label) {
  if (Array.isArray(value)) return value.forEach((item, index) => assertNoForbiddenFields(item, label, `${path}[${index}]`));
  if (value === null || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (forbiddenFields.has(key)) throw new Error(`${label}に禁止field ${path}.${key} があります`);
    assertNoForbiddenFields(child, label, `${path}.${key}`);
  }
}

function assertEqual(actual, expectedValue, label) {
  if (actual !== expectedValue) throw new Error(`${label}が不正です: expected=${JSON.stringify(expectedValue)} actual=${JSON.stringify(actual)}`);
}

function assertSha256(value, label) {
  if (!/^[0-9a-f]{64}$/.test(value ?? "")) throw new Error(`${label}はSHA-256ではありません`);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function resolveAbsolute(value, label) {
  if (!isAbsolute(value)) throw new Error(`${label}には絶対パスを指定してください`);
  return resolve(value);
}
