import assert from "node:assert/strict";
import { test } from "node:test";
import {
  sourceManifestDeclarationBasename,
  sourceManifestDeclarationBytes,
  sourceManifestDeclarationSha256,
  validateSourceManifestDeclarationBytes,
} from "./lib/evidence/source_manifest.mjs";

const commit = "fb015179478169cf4a595094766d4b9582d2925b";
const manifestSha256 = "cdb05fdc307dd5d568e97e0ac8e4ea06fe8fe120be3aaa300c5ddecdddd3768b";

test("sourceManifestDeclarationBytes は決定的なcanonical byte列を生成する", () => {
  const bytes = sourceManifestDeclarationBytes(commit, manifestSha256);
  assert.equal(bytes, `{
  "schema": "lnako.source-manifest.v1",
  "commit": "${commit}",
  "sourceManifestSha256": "${manifestSha256}"
}
`);
  assert.equal(bytes, sourceManifestDeclarationBytes(commit, manifestSha256));
  assert.match(sourceManifestDeclarationSha256(commit, manifestSha256), /^[0-9a-f]{64}$/);
});

test("validateSourceManifestDeclarationBytes は正しい宣言を受理し偽造を拒否する", () => {
  const bytes = sourceManifestDeclarationBytes(commit, manifestSha256);
  validateSourceManifestDeclarationBytes(bytes, commit, manifestSha256);
  assert.throws(() => validateSourceManifestDeclarationBytes(bytes, "0".repeat(40), manifestSha256), /schemaまたはidentityが不正/);
  assert.throws(() => validateSourceManifestDeclarationBytes(bytes, commit, "0".repeat(64)), /schemaまたはidentityが不正/);
  const mutated = JSON.parse(bytes);
  mutated.commit = "0".repeat(40);
  assert.throws(() => validateSourceManifestDeclarationBytes(`${JSON.stringify(mutated, null, 2)}\n`, commit, manifestSha256), /schemaまたはidentityが不正/);
  const forged = JSON.parse(bytes);
  forged.schema = "lnako.source-manifest.v2";
  assert.throws(() => validateSourceManifestDeclarationBytes(`${JSON.stringify(forged, null, 2)}\n`, commit, manifestSha256), /schemaまたはidentityが不正/);
  assert.throws(() => validateSourceManifestDeclarationBytes(`{"schema":"lnako.source-manifest.v1","commit":"${commit}","sourceManifestSha256":"${manifestSha256}"}\n`, commit, manifestSha256), /canonical byte列ではありません/);
  assert.throws(() => validateSourceManifestDeclarationBytes("not-json", commit, manifestSha256), /JSONが不正/);
});

test("sourceManifestDeclarationBytes は不正な引数を拒否する", () => {
  assert.throws(() => sourceManifestDeclarationBytes("not-a-commit", manifestSha256), /不正/);
  assert.throws(() => sourceManifestDeclarationBytes(commit, "not-a-hash"), /不正/);
  assert.equal(sourceManifestDeclarationBasename, "lnako-source-manifest.json");
});
