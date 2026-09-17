import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import {
  parseArguments,
  publishGeneratedSnapshot,
  snapshotBranchName,
  snapshotCommitMessage,
  snapshotExistsOnRef,
  snapshotManifestGitPath,
} from "./create_attestation_snapshot.mjs";

function git(cwd, args) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")}\n${result.stderr}`);
  }
  return result.stdout.trim();
}

function makeRepositories() {
  const directory = mkdtempSync(join(tmpdir(), "lnako-attestation-push-"));
  const origin = join(directory, "origin.git");
  const work = join(directory, "work");
  git(directory, ["init", "--bare", "--initial-branch=main", origin]);
  git(origin, ["symbolic-ref", "HEAD", "refs/heads/main"]);
  git(directory, ["clone", origin, work]);
  git(work, ["checkout", "-B", "main"]);
  git(work, ["config", "user.name", "snapshot-test"]);
  git(work, ["config", "user.email", "snapshot-test@example.com"]);
  writeFileSync(join(work, "README"), "init\n");
  git(work, ["add", "README"]);
  git(work, ["commit", "-m", "init"]);
  git(work, ["push", "-u", "origin", "main"]);
  return { directory, origin, work };
}

function writeSnapshot(cwd, runId) {
  const relative = snapshotManifestGitPath(runId);
  mkdirSync(join(cwd, relative, ".."), { recursive: true });
  writeFileSync(join(cwd, relative), `${JSON.stringify({
    schema: "lnako.canonical-attestation.v2",
    workflowRun: runId,
    sourceManifestSha256: "a".repeat(64),
  }, null, 2)}\n`);
}

test("parseArguments はPR作成を既定にし --no-pr / --no-push を受け付ける", () => {
  const options = parseArguments(["--run-id", "35236586118"]);
  assert.equal(options.runId, "35236586118");
  assert.equal(options.ref, "main");
  assert.equal(options.noPush, false);
  assert.equal(options.noPr, false);
  assert.equal(options.noVerify, false);
  assert.equal(parseArguments(["--run-id", "1", "--no-pr"]).noPr, true);
  assert.equal(parseArguments(["--run-id", "1", "--no-push"]).noPush, true);
  assert.equal(parseArguments(["--run-id", "1", "--ref", "release"]).ref, "release");
});

test("snapshotCommitMessage と path は走査型snapshotの固定規則に従う", () => {
  assert.equal(snapshotCommitMessage("35236586118"), "CI run 35236586118 のattestation snapshotを追跡 (verified: 527)");
  assert.equal(snapshotManifestGitPath("35236586118"), "compat/v3.7.24/attestations/35236586118/manifest.json");
  assert.equal(snapshotBranchName("35236586118"), "attestation/run-35236586118");
});

test("publishGeneratedSnapshot は既に追跡済みならpushせずskipする", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "111");
    git(repos.work, ["add", "-A"]);
    git(repos.work, ["commit", "-m", snapshotCommitMessage("111")]);
    git(repos.work, ["push", "origin", "main"]);
    writeFileSync(join(repos.work, "README"), "dirty\n");
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "111",
      ref: "main",
      createPr: false,
    });
    assert.equal(action, "skip-tracked");
    assert.equal(git(repos.origin, ["log", "-1", "--format=%s"]), snapshotCommitMessage("111"));
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot は attestation/run-* ブランチへpushする", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "222");
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
    });
    assert.equal(action, "pushed-branch");
    assert.equal(snapshotExistsOnRef(repos.work, "origin/main", "222"), false);
    assert.equal(snapshotExistsOnRef(repos.work, "origin/attestation/run-222", "222"), true);
    assert.equal(git(repos.origin, ["log", "-1", "--format=%s", "attestation/run-222"]), snapshotCommitMessage("222"));
    assert.equal(git(repos.origin, ["log", "-1", "--format=%s", "main"]), "init");
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot は --no-push でcommitしない", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "333");
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "333",
      ref: "main",
      noPush: true,
      createPr: false,
    });
    assert.equal(action, "local-only");
    assert.equal(snapshotExistsOnRef(repos.work, "origin/main", "333"), false);
    assert.equal(git(repos.origin, ["log", "-1", "--format=%s"]), "init");
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});
