import assert from "node:assert/strict";
import { test } from "node:test";
import { parseArguments, snapshotManifestGitPath } from "./create_attestation_snapshot.mjs";

test("parseArguments はローカル生成のみを既定にし git publish option を拒否する", () => {
  const options = parseArguments(["--run-id", "35236586118"]);
  assert.equal(options.runId, "35236586118");
  assert.equal(options.noVerify, false);
  assert.equal("noPush" in options, false);
  assert.equal("noPr" in options, false);
  assert.equal("ref" in options, false);
  assert.equal(parseArguments(["--run-id", "1", "--no-verify"]).noVerify, true);
  assert.throws(() => parseArguments(["--run-id", "1", "--no-pr"]), /ローカル生成のみ/);
  assert.throws(() => parseArguments(["--run-id", "1", "--no-push"]), /ローカル生成のみ/);
  assert.throws(() => parseArguments(["--run-id", "1", "--branch", "attestation/run-1"]), /ローカル生成のみ/);
  assert.throws(() => parseArguments(["--run-id", "1", "--ref", "main"]), /ローカル生成のみ/);
});

test("snapshotManifestGitPath は走査型snapshotの固定規則に従う", () => {
  assert.equal(snapshotManifestGitPath("35236586118"), "compat/v3.7.24/attestations/35236586118/manifest.json");
});
