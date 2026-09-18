import assert from "node:assert/strict";
import { test } from "node:test";
import {
  githubAttestationOidcIssuer,
  githubAttestationPredicateType,
  githubAttestationSourceRef,
  githubAttestationVerifyArgs,
  githubAttestationWorkflow,
  subjectDigestMatched,
} from "./lib/evidence/github_attestation.mjs";

const commit = "b588e91c343f613aec82a649a957f09a3f21a50c";

test("githubAttestationVerifyArgs は公式gh attestation verifyの固定引数を組む", () => {
  const args = githubAttestationVerifyArgs("/tmp/evidence.json", { commit });
  assert.deepEqual(args.slice(0, 3), ["attestation", "verify", "/tmp/evidence.json"]);
  assert.equal(args[args.indexOf("--signer-workflow") + 1], githubAttestationWorkflow);
  assert.equal(args[args.indexOf("--source-digest") + 1], commit);
  assert.equal(args[args.indexOf("--signer-digest") + 1], commit);
  assert.equal(args[args.indexOf("--source-ref") + 1], githubAttestationSourceRef);
  assert.equal(args[args.indexOf("--cert-oidc-issuer") + 1], githubAttestationOidcIssuer);
  assert.equal(args[args.indexOf("--predicate-type") + 1], githubAttestationPredicateType);
  assert.ok(args.includes("--deny-self-hosted-runners"));
  assert.throws(() => githubAttestationVerifyArgs("/tmp/evidence.json", { commit: "not-a-commit" }), /commitが不正/);
});

test("subjectDigestMatched はsha256 subjectを受理し不一致を拒否する", () => {
  const digest = "a".repeat(64);
  assert.equal(subjectDigestMatched([{
    verificationResult: { statement: { subject: [{ digest: { sha256: digest } }] } },
  }], digest), true);
  assert.equal(subjectDigestMatched([{
    verificationResult: { statement: { subject: [{ digest: [{ algorithm: "sha256", value: digest }] }] } },
  }], digest), true);
  assert.equal(subjectDigestMatched([{
    verificationResult: { statement: { subject: [{ digest: { sha256: "b".repeat(64) } }] } },
  }], digest), false);
  assert.equal(subjectDigestMatched([], digest), false);
});
