import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { delimiter, join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const hook = join(root, ".githooks", "pre-push");

function makeFakeEnvironment({ mergeBaseStatus = 0, statusOutput = "", zigStatus = 0, nodeStatus = 0 } = {}) {
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
  *) exit 0 ;;
esac
`);
  writeExecutable(join(bin, "zig"), `#!/bin/sh
printf 'zig %s\\n' "$*" >> "$HOOK_LOG"
exit "$HOOK_ZIG_STATUS"
`);
  writeExecutable(join(bin, "node"), `#!/bin/sh
printf 'node %s\\n' "$*" >> "$HOOK_LOG"
exit "$HOOK_NODE_STATUS"
`);
  return {
    directory,
    cwd: directory,
    log,
    env: {
      ...process.env,
      PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
      HOOK_LOG: log,
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
  const shellArgs = process.platform === "win32" ? ["--noprofile", "--norc", hook] : [hook];
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
      "zig build fmt-check",
      "zig build test",
      "node tools/sync_compat_evidence.mjs --check",
      "node tools/check_interpreter_only_classification.mjs --check",
    ]);
    assertNoGitMutation(environment);
  } finally {
    rmSync(environment.directory, { recursive: true, force: true });
  }
});
