import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

// The CI attestation signs every canonical evidence file that can back a
// catalog entry's selected proof. The list is fixed and complete: a catalog
// entry may be promoted to verified only when the digest of the file that
// backs its proof appears among the signed subjects.
export const trackedAttestationSubjects = [
  "compat/v3.7.24/compat-js-evidence.json",
  "compat/v3.7.24/directory-binding-evidence.json",
  "compat/v3.7.24/dispatch-coverage-evidence.json",
  "compat/v3.7.24/dispatch-evidence.json",
  "compat/v3.7.24/expected-exit-evidence.json",
  "compat/v3.7.24/global-binding-evidence.json",
  "compat/v3.7.24/static-array-constant-evidence.json",
  "compat/v3.7.24/static-caniuse-agents-constant-evidence.json",
  "compat/v3.7.24/static-constant-evidence.json",
  "compat/v3.7.24/static-datetime-era-constant-evidence.json",
  "compat/v3.7.24/static-datetime-plugin-era-constant-evidence.json",
  "compat/v3.7.24/static-node-archive-constant-evidence.json",
  "compat/v3.7.24/static-node-command-line-constant-evidence.json",
  "compat/v3.7.24/static-node-http-initial-constant-evidence.json",
  "compat/v3.7.24/static-node-mother-path-constant-evidence.json",
  "compat/v3.7.24/static-promise-reject-constant-evidence.json",
  "compat/v3.7.24/static-string-constant-evidence.json",
];

export const currentAttestationPointerPath = "compat/v3.7.24/attestations/current.json";
export const currentAttestationPointerSchema = "lnako.current-attestation.v1";
export const canonicalAttestationSchema = "lnako.canonical-attestation.v1";
export const dispatchAttestationSchemaV2 = "lnako.dispatch-attestation.v2";

const hashPattern = /^[0-9a-f]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/i;

export function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function sha256File(path) {
  return sha256Bytes(readFileSync(path));
}

export function signedEvidenceDigests(attestation) {
  const digests = new Set();
  for (const subject of attestation?.subjects ?? []) {
    if (typeof subject?.evidenceSha256 === "string") digests.add(subject.evidenceSha256);
  }
  for (const subject of attestation?.trackedSubjects ?? []) {
    if (typeof subject?.sha256 === "string") digests.add(subject.sha256);
  }
  return digests;
}

export function assertTrackedSubjects(attestation, root) {
  const isV2 = attestation.schema === dispatchAttestationSchemaV2;
  if (!isV2) {
    if (attestation.trackedSubjects !== undefined) throw new Error("dispatch証拠のattestation schemaがtrackedSubjectsに対応していません");
    return;
  }
  const subjects = attestation.trackedSubjects;
  const expected = new Set(trackedAttestationSubjects);
  if (!Array.isArray(subjects) || subjects.length !== expected.size) {
    throw new Error("追跡attestation subjectがcanonical証拠17件の完全集合ではありません");
  }
  const seen = new Set();
  for (const subject of subjects) {
    if (subject === null || typeof subject !== "object" || Array.isArray(subject) ||
        JSON.stringify(Object.keys(subject).sort()) !== JSON.stringify(["path", "sha256"])) {
      throw new Error("追跡attestation subjectのfield集合が不正です");
    }
    if (!expected.has(subject.path) || seen.has(subject.path)) {
      throw new Error(`追跡attestation subjectのpathが不正です: ${subject.path}`);
    }
    seen.add(subject.path);
    if (!hashPattern.test(subject.sha256)) throw new Error(`追跡attestation subjectのdigestが不正です: ${subject.path}`);
    if (sha256File(resolve(root, subject.path)) !== subject.sha256) {
      throw new Error(`追跡attestation subject digestが現行証拠と一致しません: ${subject.path}`);
    }
  }
}

export async function loadCurrentAttestation(root) {
  const pointerPath = resolve(root, currentAttestationPointerPath);
  try {
    await access(pointerPath);
  } catch {
    return null;
  }
  let pointer;
  try {
    pointer = JSON.parse(await readFile(pointerPath, "utf8"));
  } catch (error) {
    throw new Error(`current attestation pointerのJSONが不正です: ${error.message}`);
  }
  const keys = ["schema", "workflowRun", "workflowAttempt", "targetCommit", "sourceRef", "workflow", "sourceManifestSha256", "directory"];
  if (pointer === null || typeof pointer !== "object" || Array.isArray(pointer) ||
      JSON.stringify(Object.keys(pointer).sort()) !== JSON.stringify([...keys].sort()) ||
      pointer.schema !== currentAttestationPointerSchema || !/^[0-9]+$/.test(pointer.workflowRun ?? "") ||
      !Number.isSafeInteger(pointer.workflowAttempt) || pointer.workflowAttempt < 1 ||
      !commitPattern.test(pointer.targetCommit ?? "") || pointer.sourceRef !== "refs/heads/main" ||
      pointer.workflow !== "soramikan/lnako/.github/workflows/ci.yml" || !hashPattern.test(pointer.sourceManifestSha256 ?? "") ||
      typeof pointer.directory !== "string" || !/^[0-9]+$/.test(pointer.directory)) {
    throw new Error("current attestation pointerのschemaまたはidentityが不正です");
  }
  const directory = resolve(root, "compat/v3.7.24/attestations", pointer.directory);
  return {
    pointer,
    attestationPath: resolve(directory, "dispatch-attestation.json"),
    bundlePath: resolve(directory, "sigstore-bundle.json"),
    manifestPath: resolve(directory, "manifest.json"),
  };
}
