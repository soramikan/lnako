import { createHash } from "node:crypto";
import { json } from "./constants.mjs";

// source manifest宣言（lnako.source-manifest.v1）。揮発するmanifest値をcanonical
// 証拠へ埋め込む代わりに、{schema, commit, sourceManifestSha256} の決定的JSONを
// CI attestationの署名subjectとし、snapshot検証が宣言blobのdigestを経由して
// 現行ソースへ束縛する。serializationはcanonical json（2空白＋末尾改行）で固定し、
// 誰が生成しても同一byte列になる。
export const sourceManifestDeclarationSchema = "lnako.source-manifest.v1";
export const sourceManifestDeclarationBasename = "lnako-source-manifest.json";

const hashPattern = /^[0-9a-f]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/i;

export function sourceManifestDeclarationBytes(commit, sourceManifestSha256) {
  if (!commitPattern.test(commit) || !hashPattern.test(sourceManifestSha256)) {
    throw new Error("source manifest宣言のcommitまたはmanifest digestが不正です");
  }
  return json({ schema: sourceManifestDeclarationSchema, commit: commit.toLowerCase(), sourceManifestSha256 });
}

export function sourceManifestDeclarationSha256(commit, sourceManifestSha256) {
  return createHash("sha256").update(sourceManifestDeclarationBytes(commit, sourceManifestSha256)).digest("hex");
}

// 宣言blobは再生成byte列と完全一致しなければならない。field単位の検査も行い、
// 不一致時に分かりやすいerrorを返す。
export function validateSourceManifestDeclarationBytes(bytes, commit, sourceManifestSha256) {
  let document;
  try {
    document = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error("source manifest宣言のJSONが不正です");
  }
  if (document === null || typeof document !== "object" || Array.isArray(document) ||
      JSON.stringify(Object.keys(document).sort()) !== JSON.stringify(["commit", "schema", "sourceManifestSha256"]) ||
      document.schema !== sourceManifestDeclarationSchema || document.commit !== commit.toLowerCase() ||
      document.sourceManifestSha256 !== sourceManifestSha256) {
    throw new Error("source manifest宣言のschemaまたはidentityが不正です");
  }
  if (bytes.toString("utf8") !== sourceManifestDeclarationBytes(commit, sourceManifestSha256)) {
    throw new Error("source manifest宣言がcanonical byte列ではありません");
  }
}
