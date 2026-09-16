import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { sha256Bytes, trackedAttestationSubjects } from "./attested_files.mjs";

// catalog entry の executionEvidence は `proofSchema|fixtureId` で裏付け証拠を
// 一意に指す。fixture field を持たない証拠（dispatch coverage・compat-js）の
// fixtureId は catalog 生成側が合成する固定 ID とする。
const syntheticFixtureIdBySchema = new Map([
  ["lnako.dispatch-coverage.v1", "dispatch-coverage"],
  ["lnako.compat-js-evidence.v1", "compat-js-evidence"],
]);

export function proofKeyForEvidenceDocument(document) {
  if (typeof document?.schema !== "string") return null;
  const fixtureId = document?.fixture?.id ?? syntheticFixtureIdBySchema.get(document.schema);
  return typeof fixtureId === "string" ? `${document.schema}|${fixtureId}` : null;
}

// tracked 証拠17件それぞれの内容 digest を proof key に対応付ける。
// derived view の昇格判定はコミット済み正本（canonical）の digest で行う。
export async function computeBackingDigestByProof(root) {
  const result = new Map();
  for (const relativePath of trackedAttestationSubjects) {
    const bytes = await readFile(resolve(root, relativePath));
    const key = proofKeyForEvidenceDocument(JSON.parse(bytes.toString("utf8")));
    if (key === null) throw new Error(`追跡証拠がproof keyを持ちません: ${relativePath}`);
    if (result.has(key)) throw new Error(`追跡証拠のproof keyが重複しています: ${key}`);
    result.set(key, sha256Bytes(bytes));
  }
  return result;
}

// canonical evidence.json は常時 unattested で保持し、verified view は署名済み
// digest を持つ snapshot から導出する。昇格は executionEvidence.state・reason・
// 集計カウンタを決定的に書き換えるだけで、entry の内容クレームは変更しない。
export function deriveVerifiedCatalog(canonicalEvidence, signedDigests, backingDigestByProof) {
  const derived = structuredClone(canonicalEvidence);
  for (const entry of derived.entries) {
    if (entry.executionEvidenceState !== "trace-confirmed-unattested" || entry.executionEvidence === null) continue;
    const proof = entry.executionEvidence;
    const digest = backingDigestByProof.get(`${proof.proofSchema}|${proof.fixtureId}`);
    if (digest === undefined || !signedDigests.has(digest)) continue;
    entry.executionEvidenceState = "verified";
    proof.state = "verified";
    entry.reason = promoteReasonToVerified(entry.reason, entry.id);
  }
  derived.executionEvidenceStates = Object.fromEntries(
    ["verified", "trace-confirmed-unattested", "unverified"].map((state) => [state, derived.entries.filter((entry) => entry.executionEvidenceState === state).length]),
  );
  return derived;
}

function promoteReasonToVerified(reason, id) {
  const promoted = reason
    .replace("を機械検証した（", "を機械検証したと外部attestationを機械検証した（")
    .replace("。外部attestation未導入のためexecutionEvidenceState=trace-confirmed-unattestedであり、verifiedへは昇格しない。", "。executionEvidenceState=verified。");
  if (promoted === reason || !promoted.endsWith("executionEvidenceState=verified。")) {
    throw new Error(`verified昇格のreason変換が不正です: ${id}`);
  }
  return promoted;
}
