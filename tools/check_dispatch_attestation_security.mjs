import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { platformIndependentOfficialComparison } from "./dispatch_evidence_semantics.mjs";
import { trackedAttestationSubjects } from "./lib/evidence/attested_files.mjs";
import { computeSourceManifestSha256Sync } from "./lib/evidence/manifest.mjs";

const root = resolve(import.meta.dirname, "..");
const temporary = await mkdtemp(join(tmpdir(), "lnako-attestation-security-"));
try {
  const evidence = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/dispatch-evidence.json"), "utf8"));
  const commit = gitHead();
  evidence.attestation = null;
  evidence.provenance.lnako.commit = commit;
  evidence.provenance.lnako.dirty = false;
  evidence.provenance.lnako.sourceManifestSha256 = computeSourceManifestSha256Sync(root).sha256;

  const evidencePath = resolve(temporary, "dispatch-evidence.json");
  const evidenceBytes = Buffer.from(`${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  await writeFile(evidencePath, evidenceBytes, { flag: "wx" });

  const bundlePath = resolve(temporary, "fake-bundle.json");
  const bundleBytes = Buffer.from('{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{},"dsseEnvelope":{}}\n', "utf8");
  await writeFile(bundlePath, bundleBytes, { flag: "wx" });

  const evidenceSha256 = sha256(evidenceBytes);
  const platformVariant = structuredClone(evidence);
  for (const result of Object.values(platformVariant.officialComparison.results)) result.stdoutSha256 = result.stdoutSha256 === "0".repeat(64) ? "1".repeat(64) : "0".repeat(64);
  if (JSON.stringify(platformIndependentOfficialComparison(evidence.officialComparison)) !== JSON.stringify(platformIndependentOfficialComparison(platformVariant.officialComparison))) {
    throw new Error("OS依存の公式出力hashをcross-OS dispatch意味比較へ混入させています");
  }
  const currentPlatform = `${evidence.provenance.environment.platform}-${evidence.provenance.environment.arch}`;
  const subjects = [
    { platform: "darwin", arch: "arm64", evidenceSha256: currentPlatform === "darwin-arm64" ? evidenceSha256 : "0".repeat(64) },
    { platform: "linux", arch: "x64", evidenceSha256: currentPlatform === "linux-x64" ? evidenceSha256 : "1".repeat(64) },
    { platform: "win32", arch: "x64", evidenceSha256: currentPlatform === "win32-x64" ? evidenceSha256 : "2".repeat(64) },
  ];
  const attestation = {
    schema: "lnako.dispatch-attestation.v1",
    repository: "soramikan/lnako",
    workflow: "soramikan/lnako/.github/workflows/ci.yml",
    sourceRef: "refs/heads/main",
    commit,
    predicateType: "https://slsa.dev/provenance/v1",
    verifiedBy: "gh attestation verify",
    bundleSha256: sha256(bundleBytes),
    subjects,
  };
  const attestationPath = resolve(temporary, "fake-attestation.json");
  await writeFile(attestationPath, `${JSON.stringify(attestation, null, 2)}\n`, { flag: "wx" });

  const missingBundleOutput = resolve(temporary, "missing-bundle-output.json");
  const missingBundle = runSync(evidencePath, attestationPath, null, missingBundleOutput);
  assertRejected(missingBundle, "--attestationと--attestation-bundleは同時に指定してください", "bundle省略");
  await assertAbsent(missingBundleOutput);

  const forgedOutput = resolve(temporary, "forged-output.json");
  const forged = runSync(evidencePath, attestationPath, bundlePath, forgedOutput);
  assertRejected(forged, "公式gh attestation verifyに失敗しました", "偽造bundle");
  await assertAbsent(forgedOutput);

  // trackedSubjects (schema v2) structural rejection happens before the online
  // bundle check, so a fake bundle cannot mask a forged tracked path or digest.
  const realTrackedSubjects = [];
  for (const relativePath of trackedAttestationSubjects) {
    realTrackedSubjects.push({ path: relativePath, sha256: sha256(await readFile(resolve(root, relativePath))) });
  }
  const v2Base = { ...attestation, schema: "lnako.dispatch-attestation.v2" };

  const unknownPathAttestation = {
    ...v2Base,
    trackedSubjects: [{ path: "compat/v3.7.24/evidence.json", sha256: "0".repeat(64) }, ...realTrackedSubjects.slice(1)],
  };
  const unknownPathAttestationPath = resolve(temporary, "unknown-path-attestation.json");
  await writeFile(unknownPathAttestationPath, `${JSON.stringify(unknownPathAttestation, null, 2)}\n`, { flag: "wx" });
  const unknownPathOutput = resolve(temporary, "unknown-path-output.json");
  assertRejected(runSync(evidencePath, unknownPathAttestationPath, bundlePath, unknownPathOutput), "追跡attestation subjectのpathが不正です", "canonical集合外のtracked subject");
  await assertAbsent(unknownPathOutput);

  const wrongDigestSubjects = realTrackedSubjects.map((subject, index) =>
    index === 0 ? { ...subject, sha256: "0".repeat(64) } : subject);
  const wrongDigestAttestation = { ...v2Base, trackedSubjects: wrongDigestSubjects };
  const wrongDigestAttestationPath = resolve(temporary, "wrong-digest-attestation.json");
  await writeFile(wrongDigestAttestationPath, `${JSON.stringify(wrongDigestAttestation, null, 2)}\n`, { flag: "wx" });
  const wrongDigestOutput = resolve(temporary, "wrong-digest-output.json");
  assertRejected(runSync(evidencePath, wrongDigestAttestationPath, bundlePath, wrongDigestOutput), "追跡attestation subject digestが現行証拠と一致しません", "現行証拠と不一致のtracked digest");
  await assertAbsent(wrongDigestOutput);

  const missingTrackedAttestation = { ...v2Base, trackedSubjects: realTrackedSubjects.slice(0, -1) };
  const missingTrackedPath = resolve(temporary, "missing-tracked-attestation.json");
  await writeFile(missingTrackedPath, `${JSON.stringify(missingTrackedAttestation, null, 2)}\n`, { flag: "wx" });
  const missingTrackedOutput = resolve(temporary, "missing-tracked-output.json");
  assertRejected(runSync(evidencePath, missingTrackedPath, bundlePath, missingTrackedOutput), "追跡attestation subjectがcanonical証拠17件の完全集合ではありません", "不完全なtracked subject集合");
  await assertAbsent(missingTrackedOutput);

  console.log("dispatch attestation安全性検査: metadata単体・偽造bundle・tracked subject偽造・OS依存出力hashのcross-OS除外を検査");
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function runSync(evidencePath, attestationPath, bundlePath, outputPath) {
  const arguments_ = [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", evidencePath,
    "--attestation", attestationPath,
  ];
  if (bundlePath !== null) arguments_.push("--attestation-bundle", bundlePath);
  arguments_.push("--output", outputPath);
  return spawnSync(process.execPath, arguments_, { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
}

function assertRejected(result, message, label) {
  if (result.status === 0 || !result.stderr.includes(message)) {
    throw new Error(`${label}を期待どおり拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
}

async function assertAbsent(path) {
  try {
    await readFile(path);
    throw new Error(`拒否後に出力が残りました: ${path}`);
  } catch (error) {
    if (error?.message?.startsWith("拒否後に出力が残りました")) throw error;
    if (error?.code !== "ENOENT") throw error;
  }
}

function gitHead() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const commit = result.stdout.trim();
  if (result.status !== 0 || !/^[0-9a-f]{40}$/i.test(commit)) throw new Error("現行commitを取得できません");
  return commit;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
