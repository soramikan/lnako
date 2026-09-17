import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { computeSourceManifestSha256Sync } from "./manifest.mjs";

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

export const attestationsDirectory = "compat/v3.7.24/attestations";
export const canonicalAttestationSchema = "lnako.canonical-attestation.v1";
export const canonicalAttestationSchemaV2 = "lnako.canonical-attestation.v2";
export const dispatchAttestationSchemaV2 = "lnako.dispatch-attestation.v2";
export const dispatchAttestationSchemaV3 = "lnako.dispatch-attestation.v3";

const hashPattern = /^[0-9a-f]{64}$/;

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
  if (typeof attestation?.sourceManifest?.sha256 === "string") digests.add(attestation.sourceManifest.sha256);
  return digests;
}

export function assertTrackedSubjects(attestation, root) {
  const hasTracked = attestation.schema === dispatchAttestationSchemaV2 || attestation.schema === dispatchAttestationSchemaV3;
  if (!hasTracked) {
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

// 現行snapshotの解決は走査型で行い、pointerファイルは使わない。候補は
// canonical-attestation.v2 のmanifest（sourceManifest宣言を持つ形）に限る。
// v1以前の履歴snapshotは宣言subjectを持たず現行になり得ないため、
// sourceManifestSha256が偶然一致しても候補へ含めずunattestedとして扱う。
// ここでは構造とmanifest一致だけを確認し、署名・内容の完全検証は
// check_tracked_dispatch_attestation.mjs が担う。
export async function loadCurrentAttestation(root, attestationsRoot = resolve(root, attestationsDirectory)) {
  const sourceManifestSha256 = computeSourceManifestSha256Sync(root).sha256;
  let entries;
  try {
    entries = await readdir(attestationsRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !/^[0-9]+$/.test(entry.name)) continue;
    const directory = resolve(attestationsRoot, entry.name);
    const manifestPath = resolve(directory, "manifest.json");
    let manifest;
    try {
      manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw new Error(`attestation manifestのJSONが不正です: ${entry.name}`);
    }
    if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) continue;
    if (manifest.schema !== canonicalAttestationSchemaV2) continue;
    if (!/^[0-9]+$/.test(manifest.workflowRun ?? "") || manifest.workflowRun !== entry.name) continue;
    if (!hashPattern.test(manifest.sourceManifestSha256 ?? "")) continue;
    if (manifest.sourceManifestSha256 !== sourceManifestSha256) continue;
    candidates.push({ directory, manifest, manifestPath });
  }
  if (candidates.length === 0) return null;
  const runs = new Set(candidates.map((candidate) => candidate.manifest.workflowRun));
  if (runs.size !== candidates.length) {
    throw new Error("現行manifestに一致するattestation snapshotのworkflowRunが重複しています");
  }
  candidates.sort((left, right) => (BigInt(left.manifest.workflowRun) > BigInt(right.manifest.workflowRun) ? -1 : 1));
  return snapshotHandle(candidates[0].directory, candidates[0].manifest, candidates[0].manifestPath);
}

// 指定ディレクトリを現行 snapshot として読む。走査規則（dirname === workflowRun）は
// 適用しない。--output-dir で run ID 以外の basename へ書いた成果物を検証するため。
export async function loadAttestationSnapshot(root, snapshotDirectory) {
  const sourceManifestSha256 = computeSourceManifestSha256Sync(root).sha256;
  const directory = resolve(snapshotDirectory);
  const manifestPath = resolve(directory, "manifest.json");
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`attestation manifestのJSONが不正です: ${directory}`);
  }
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) return null;
  if (manifest.schema !== canonicalAttestationSchemaV2) return null;
  if (!/^[0-9]+$/.test(manifest.workflowRun ?? "") || !hashPattern.test(manifest.sourceManifestSha256 ?? "")) return null;
  if (manifest.sourceManifestSha256 !== sourceManifestSha256) return null;
  return snapshotHandle(directory, manifest, manifestPath);
}

function snapshotHandle(directory, manifest, manifestPath) {
  return {
    directory,
    manifest,
    manifestPath,
    attestationPath: resolve(directory, "dispatch-attestation.json"),
    bundlePath: resolve(directory, "sigstore-bundle.json"),
    sourceManifestPath: resolve(directory, "source-manifest.json"),
  };
}
