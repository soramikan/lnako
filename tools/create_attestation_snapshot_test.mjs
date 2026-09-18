import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import {
  interpretPullRequestResult,
  matchingSourceSnapshotOnRef,
  parseArguments,
  publishGeneratedSnapshot,
  snapshotBranchName,
  snapshotCommitMessage,
  snapshotExistsOnRef,
  snapshotManifestGitPath,
} from "./create_attestation_snapshot.mjs";

const matchingHash = "a".repeat(64);

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

function writeSnapshot(cwd, runId, sourceManifestSha256 = matchingHash) {
  const relative = snapshotManifestGitPath(runId);
  mkdirSync(join(cwd, relative, ".."), { recursive: true });
  writeFileSync(join(cwd, relative), `${JSON.stringify({
    schema: "lnako.canonical-attestation.v2",
    workflowRun: runId,
    sourceManifestSha256,
  }, null, 2)}\n`);
  writeFileSync(join(cwd, relative, "..", "catalog-evidence-verified.json"), "{}\n");
  writeFileSync(join(cwd, relative, "..", "sigstore-bundle.json"), "{}\n");
}

function createPullRequestMock(status, stderr = "", stdout = "https://example.test/pr/1\n") {
  const calls = [];
  const createPullRequest = (arguments_) => {
    calls.push(arguments_);
    return { status, stdout, stderr, error: null };
  };
  return { calls, createPullRequest };
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

test("interpretPullRequestResult は成功・既存・失敗を区別する", () => {
  assert.equal(interpretPullRequestResult({ status: 0, stdout: "https://example.test/pr/1\n", stderr: "" }), "pr-created");
  assert.equal(interpretPullRequestResult({ status: 1, stdout: "", stderr: "a pull request already exists for attestation/run-1\n" }), "pr-exists");
  assert.throws(
    () => interpretPullRequestResult({ status: 1, stdout: "", stderr: "GraphQL: GitHub Actions is not permitted\n" }),
    /gh pr create が失敗しました/,
  );
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
      sourceManifestSha256: matchingHash,
    });
    assert.equal(action, "skip-tracked");
    assert.equal(git(repos.origin, ["log", "-1", "--format=%s"]), snapshotCommitMessage("111"));
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot は同一source manifestの現行snapshotがあればskipする", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "111");
    git(repos.work, ["add", "-A"]);
    git(repos.work, ["commit", "-m", snapshotCommitMessage("111")]);
    git(repos.work, ["push", "origin", "main"]);
    writeSnapshot(repos.work, "222");
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
      sourceManifestSha256: matchingHash,
    });
    assert.equal(action, "skip-current-manifest");
    assert.equal(matchingSourceSnapshotOnRef(repos.work, "origin/main", matchingHash), "111");
    assert.equal(snapshotExistsOnRef(repos.work, "origin/main", "222"), false);
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
      sourceManifestSha256: "b".repeat(64),
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

test("publishGeneratedSnapshot は既存snapshotブランチがあれば再commitせずPRを作る", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "222");
    const first = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
      sourceManifestSha256: "b".repeat(64),
    });
    assert.equal(first, "pushed-branch");
    const sha = git(repos.origin, ["rev-parse", "attestation/run-222"]);
    const mock = createPullRequestMock(0);
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      sourceManifestSha256: "b".repeat(64),
      createPullRequest: mock.createPullRequest,
    });
    assert.equal(action, "pr-created");
    assert.equal(mock.calls.length, 1);
    assert.equal(mock.calls[0].head, "attestation/run-222");
    assert.equal(git(repos.origin, ["rev-parse", "attestation/run-222"]), sha);
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot は既存PRなら pr-exists を返す", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "222");
    publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
      sourceManifestSha256: "b".repeat(64),
    });
    const mock = createPullRequestMock(1, "GraphQL: A pull request already exists for these branches");
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      sourceManifestSha256: "b".repeat(64),
      createPullRequest: mock.createPullRequest,
    });
    assert.equal(action, "pr-exists");
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot はPR作成失敗を拒否する", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "222");
    assert.throws(() => publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      sourceManifestSha256: "b".repeat(64),
      createPullRequest: createPullRequestMock(1, "GraphQL: GitHub Actions is not permitted").createPullRequest,
    }), /gh pr create が失敗しました/);
  } finally {
    rmSync(repos.directory, { recursive: true, force: true });
  }
});

test("publishGeneratedSnapshot は既存ブランチをforce-with-leaseで置き換える", () => {
  const repos = makeRepositories();
  try {
    writeSnapshot(repos.work, "222");
    publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
      sourceManifestSha256: "b".repeat(64),
    });
    const first = git(repos.origin, ["rev-parse", "attestation/run-222"]);
    git(repos.work, ["checkout", "main"]);
    writeSnapshot(repos.work, "222", "b".repeat(64));
    writeFileSync(join(repos.work, snapshotManifestGitPath("222")), `${JSON.stringify({
      schema: "lnako.canonical-attestation.v2",
      workflowRun: "222",
      sourceManifestSha256: "b".repeat(64),
      replaced: true,
    }, null, 2)}\n`);
    const action = publishGeneratedSnapshot(repos.work, {
      runId: "222",
      ref: "main",
      createPr: false,
      sourceManifestSha256: "b".repeat(64),
    });
    assert.equal(action, "pushed-branch");
    const second = git(repos.origin, ["rev-parse", "attestation/run-222"]);
    assert.notEqual(second, first);
    const shown = git(repos.origin, ["show", "attestation/run-222:compat/v3.7.24/attestations/222/manifest.json"]);
    assert.match(shown, /"replaced": true/);
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
