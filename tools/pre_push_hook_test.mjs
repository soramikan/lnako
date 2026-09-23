import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const hook = join(root, ".githooks", "pre-push");

function makeFakeEnvironment({ mergeBaseStatus = 0, statusOutput = "", zigStatus = 0, nodeStatus = 0, diffOutput = "", classifierLevel = "" } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "lnako-pre-push-test-"));
  const bin = join(directory, "bin");
  const log = join(directory, "commands.log");
  mkdirSync(bin, { recursive: true });
  writeFileSync(log, "", "utf8");
  // The fake git reports a stable repository root and records every command so
  // the tests can prove that the hook never reaches git add/commit.
  writeExecutable(join(bin, "git"), `#!/bin/sh
printf 'git %s\\n' "$*" >> "$HOOK_LOG"
case "$*" in
  'rev-parse --show-toplevel') printf '%s\\n' "$HOOK_REPO_ROOT" ;;
  'merge-base --is-ancestor'*) exit "$HOOK_MERGE_BASE_STATUS" ;;
  'status --porcelain=v1 --untracked-files=all') printf '%s' "$HOOK_STATUS_OUTPUT" ;;
  'diff'*|'diff-tree'*)
    if [ -n "$HOOK_DIFF_OUTPUT" ]; then
      printf '%s\\n' "$HOOK_DIFF_OUTPUT"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
`);
  writeExecutable(join(bin, "zig"), `#!/bin/sh
printf 'zig %s\\n' "$*" >> "$HOOK_LOG"
exit "$HOOK_ZIG_STATUS"
`);
  writeExecutable(join(bin, "node"), `#!/bin/sh
case "$*" in
  *'tools/classify_changes.mjs'*)
    if [ -n "$HOOK_CLASSIFIER_LEVEL" ]; then
      printf 'level=%s\\n' "$HOOK_CLASSIFIER_LEVEL"
    fi
    exit 0
    ;;
  *)
    printf 'node %s\\n' "$*" >> "$HOOK_LOG"
    exit "$HOOK_NODE_STATUS"
    ;;
esac
`);
  return {
    directory,
    cwd: directory,
    log,
    env: {
      ...process.env,
      HOOK_LOG: log,
      HOOK_DIFF_OUTPUT: diffOutput,
      HOOK_CLASSIFIER_LEVEL: classifierLevel,
      // A relative root keeps the fake hook portable under Git Bash on
      // Windows, where a native C:\ path is not a valid bash cd operand.
      HOOK_REPO_ROOT: ".",
      HOOK_MERGE_BASE_STATUS: String(mergeBaseStatus),
      HOOK_STATUS_OUTPUT: statusOutput,
      HOOK_ZIG_STATUS: String(zigStatus),
      HOOK_NODE_STATUS: String(nodeStatus),
    },
  };
}

function writeExecutable(path, content) {
  writeFileSync(path, content, "utf8");
  chmodSync(path, 0o755);
}

function runHook(environment, input) {
  const shell = process.platform === "win32" ? "bash" : "sh";
  // Git Bash converts the inherited Windows PATH and may discard or reorder
  // injected entries. Set the fake command directory after the shell starts.
  const launcher = 'export PATH="$PWD/bin:$PATH"; export HOOK_LOG="$PWD/commands.log"; exec sh "$1"';
  const shellArgs = [
    ...(process.platform === "win32" ? ["--noprofile", "--norc"] : []),
    "-c", launcher, "hook-test", hook.replaceAll("\\", "/"),
  ];
  return spawnSync(shell, shellArgs, {
    cwd: environment.cwd,
    env: environment.env,
    input,
    encoding: "utf8",
  });
}

function logLines(environment) {
  return readFileSync(environment.log, "utf8").trim().split("\n").filter(Boolean);
}

function assertNoGitMutation(environment) {
  const lines = logLines(environment);
  assert.equal(lines.some((line) => /^git (add|commit)( |$)/.test(line)), false, lines.join("\n"));
}

const pushInput = "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222\n";
const newBranchInput = "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 0000000000000000000000000000000000000000\n";

test("non-fast-forward push aborts before any git mutation", () => {
  const environment = makeFakeEnvironment({ mergeBaseStatus: 1 });
  try {
    const result = runHook(environment, pushInput);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /non-fast-forward/);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("dirty checkout aborts before validation commands or git mutation", () => {
  const environment = makeFakeEnvironment({ statusOutput: " M tracked.txt\n" });
  try {
    const result = runHook(environment, newBranchInput);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /working tree is not clean/);
    const lines = logLines(environment);
    assert.equal(lines.some((line) => line.startsWith("zig ")), false);
    assert.equal(lines.some((line) => line.startsWith("node ")), false);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("fmt or test failure aborts before compatibility check and git mutation", () => {
  const environment = makeFakeEnvironment({ zigStatus: 1 });
  try {
    const result = runHook(environment, newBranchInput);
    assert.notEqual(result.status, 0);
    assert.deepEqual(logLines(environment).filter((line) => line.startsWith("zig ")), ["zig build fmt-check"]);
    assert.equal(logLines(environment).some((line) => line.startsWith("node ")), false);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("successful validation runs all required read-only checks", () => {
  const environment = makeFakeEnvironment();
  try {
    const result = runHook(environment, newBranchInput);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(logLines(environment), [
      "git rev-parse --show-toplevel",
      "git status --porcelain=v1 --untracked-files=all",
      "git rev-parse --verify refs/remotes/origin/main",
      "git merge-base refs/remotes/origin/main 1111111111111111111111111111111111111111",
      "git diff-tree --no-commit-id --name-only -r 1111111111111111111111111111111111111111",
      "zig build fmt-check",
      "zig build test --test-timeout 5m",
      "node tools/check_source_structure.mjs",
      "node tools/sync_compat_evidence.mjs --check",
      "node tools/check_interpreter_only_classification.mjs --check",
    ]);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("non-code changes skip zig build and test", () => {
  const environment = makeFakeEnvironment({
    diffOutput: "docs/COMPATIBILITY.md\n",
  });
  try {
    const result = runHook(environment, pushInput);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /non-code changes detected; skipping zig build and test/);
    const lines = logLines(environment);
    assert.equal(lines.some((line) => line.startsWith("zig ")), false);
    assert.deepEqual(lines.filter((line) => line.startsWith("node ")), [
      "node tools/check_docs_current.mjs",
      "node tools/check_source_structure.mjs",
      "node tools/sync_compat_evidence.mjs --check",
      "node tools/check_interpreter_only_classification.mjs --check",
    ]);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("code changes run zig build and test", () => {
  const environment = makeFakeEnvironment({
    diffOutput: "src/main.zig\n",
  });
  try {
    const result = runHook(environment, pushInput);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(/non-code changes detected/.test(result.stderr), false);
    const lines = logLines(environment);
    assert.equal(lines.includes("zig build fmt-check"), true);
    assert.equal(lines.includes("zig build test --test-timeout 5m"), true);
    assert.deepEqual(lines.filter((line) => line.startsWith("node ")), [
      "node tools/check_source_structure.mjs",
      "node tools/sync_compat_evidence.mjs --check",
      "node tools/check_interpreter_only_classification.mjs --check",
    ]);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});

test("source structure failure stops the push before evidence checks", () => {
  const environment = makeFakeEnvironment({ nodeStatus: 1 });
  try {
    const result = runHook(environment, newBranchInput);
    assert.notEqual(result.status, 0);
    assert.deepEqual(logLines(environment).filter((line) => line.startsWith("node ")), [
      "node tools/check_source_structure.mjs",
    ]);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});
