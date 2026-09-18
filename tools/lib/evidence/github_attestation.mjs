import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { computeSourceManifestSha256Sync } from "./manifest.mjs";
import { sha256File, trackedAttestationSubjects } from "./attested_files.mjs";
import { computeBackingDigestByProof, deriveVerifiedCatalog } from "./promotion.mjs";
import { sourceManifestDeclarationBasename, sourceManifestDeclarationBytes } from "./source_manifest.mjs";
import { readFileSync } from "node:fs";

export const githubAttestationRepository = "soramikan/lnako";
export const githubAttestationWorkflow = "soramikan/lnako/.github/workflows/ci.yml";
export const githubAttestationSourceRef = "refs/heads/main";
export const githubAttestationOidcIssuer = "https://token.actions.githubusercontent.com";
export const githubAttestationPredicateType = "https://slsa.dev/provenance/v1";

export function githubAttestationVerifyArgs(path, { repository = githubAttestationRepository, commit }) {
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("GitHub attestation検証のcommitが不正です");
  return [
    "attestation", "verify", path,
    "--repo", repository,
    "--signer-workflow", githubAttestationWorkflow,
    "--signer-digest", commit,
    "--source-digest", commit,
    "--source-ref", githubAttestationSourceRef,
    "--cert-oidc-issuer", githubAttestationOidcIssuer,
    "--deny-self-hosted-runners",
    "--predicate-type", githubAttestationPredicateType,
    "--format", "json",
  ];
}

export function subjectDigestMatched(entries, digest) {
  if (!Array.isArray(entries) || entries.length === 0) return false;
  return entries.some((entry) => (entry.verificationResult?.statement?.subject ?? []).some((subject) => {
    if (Array.isArray(subject.digest)) return subject.digest.some((value) => value.algorithm === "sha256" && value.value === digest);
    return subject.digest?.sha256 === digest;
  }));
}

export function matchingAttestationEntry(entries, digest) {
  if (!Array.isArray(entries)) return null;
  return entries.find((entry) => subjectDigestMatched([entry], digest)) ?? null;
}

export function attestationIdentity(entry) {
  const statement = entry?.verificationResult?.statement;
  const invocationId = statement?.predicate?.runDetails?.metadata?.invocationId;
  if (typeof invocationId === "string" && invocationId.length > 0) return invocationId;
  const bundle = entry?.attestation?.bundle ?? entry?.bundle;
  if (bundle !== null && typeof bundle === "object" && !Array.isArray(bundle)) {
    return `bundle:${createHash("sha256").update(JSON.stringify(bundle)).digest("hex")}`;
  }
  if (statement !== null && typeof statement === "object" && !Array.isArray(statement)) {
    return `statement:${createHash("sha256").update(JSON.stringify(statement)).digest("hex")}`;
  }
  return null;
}

export function verifyGithubAttestedFile(path, digest, options) {
  const result = spawnSync("gh", githubAttestationVerifyArgs(path, options), {
    cwd: options.cwd,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`公式gh attestation verifyに失敗しました: ${path}\n${result.stderr ?? ""}`);
  let entries;
  try {
    entries = JSON.parse(result.stdout);
  } catch {
    throw new Error(`gh attestation verifyのJSON出力が不正です: ${path}`);
  }
  const entry = matchingAttestationEntry(entries, digest);
  if (entry === null) {
    throw new Error(`検証済みattestationのsubject digestが不一致です: ${path}`);
  }
  const identity = attestationIdentity(entry);
  if (identity === null) {
    throw new Error(`GitHub attestationのbundle identityを特定できません: ${path}`);
  }
  return identity;
}

export async function verifyCurrentGithubAttestation(root, { commit, repository = githubAttestationRepository } = {}) {
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("GitHub attestation検証のcommitが不正です");
  const signedDigests = new Set();
  let bundleIdentity = null;
  const rememberIdentity = (path, identity) => {
    if (bundleIdentity === null) {
      bundleIdentity = identity;
      return;
    }
    if (identity !== bundleIdentity) {
      throw new Error(`GitHub attestationが同一bundleではありません: ${path}`);
    }
  };
  for (const relativePath of trackedAttestationSubjects) {
    const path = resolve(root, relativePath);
    const digest = sha256File(path);
    rememberIdentity(path, verifyGithubAttestedFile(path, digest, { repository, commit, cwd: root }));
    signedDigests.add(digest);
  }
  const sourceManifestSha256 = computeSourceManifestSha256Sync(root).sha256;
  const declarationBytes = sourceManifestDeclarationBytes(commit, sourceManifestSha256);
  const declarationSha256 = createHash("sha256").update(declarationBytes).digest("hex");
  const temporary = mkdtempSync(join(tmpdir(), "lnako-source-manifest-"));
  const declarationPath = join(temporary, sourceManifestDeclarationBasename);
  try {
    writeFileSync(declarationPath, declarationBytes);
    rememberIdentity(declarationPath, verifyGithubAttestedFile(declarationPath, declarationSha256, { repository, commit, cwd: root }));
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
  signedDigests.add(declarationSha256);
  const canonical = JSON.parse(readFileSync(resolve(root, "compat/v3.7.24/evidence.json"), "utf8"));
  const derived = deriveVerifiedCatalog(canonical, signedDigests, await computeBackingDigestByProof(root));
  if (derived.executionEvidenceStates.verified !== 527 ||
      derived.executionEvidenceStates["trace-confirmed-unattested"] !== 0 ||
      derived.executionEvidenceStates.unverified !== 0) {
    throw new Error(`GitHub attestationから導出したcatalogが verified: 527 ではありません: verified=${derived.executionEvidenceStates.verified}`);
  }
  return {
    commit,
    sourceManifestSha256,
    verified: derived.executionEvidenceStates.verified,
    bundleIdentity,
  };
}
