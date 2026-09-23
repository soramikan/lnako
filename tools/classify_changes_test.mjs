import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import { categoryOf, classify, decide, diffPaths, isLightPath } from "./classify_changes.mjs";

const root = resolve(import.meta.dirname, "..");

test("docs/** と root *.md と attestation snapshot のみの変更はlight", () => {
  const result = classify([
    "docs/COMPATIBILITY.md",
    "docs/ci-performance.md",
    "README.md",
    "AGENTS.md",
    "compat/v3.7.24/attestations/35306098302/manifest.json",
    "compat/v3.7.24/attestations/35306098302/dispatch-attestation.json",
  ]);
  assert.equal(result.level, "light");
  assert.equal(result.reason, "allow-list");
  assert.deepEqual(result.heavyPaths, []);
});

test("Issue/PRテンプレートと .gitmessage のみの変更はlight", () => {
  const result = classify([
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/PULL_REQUEST_TEMPLATE/feature.md",
    ".gitmessage",
  ]);
  assert.equal(result.level, "light");
  assert.equal(result.reason, "allow-list");
  assert.deepEqual(result.heavyPaths, []);
});

test("full CIが必要なパスが1件でも混ざればfull", () => {
  const result = classify(["docs/COMPATIBILITY.md", "src/main.zig"]);
  assert.equal(result.level, "full");
  assert.equal(result.reason, "heavy-paths");
  assert.deepEqual(result.heavyPaths, ["src/main.zig"]);
});

test("コード・テスト・workflow・toolchain・compat正本はfull", () => {
  for (const path of [
    "src/main.zig",
    "build.zig",
    "build.zig.zon",
    "tests/fixtures/run-control.nako3",
    "tools/setup_llvm.mjs",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".githooks/pre-push",
    "toolchain.lock.json",
    "compat/v3.7.24/dispatch-evidence.json",
    "compat/upstream.lock.json",
    "compat/v3.7.24/attestations.json",
    "LICENSE",
    "package.json",
  ]) {
    assert.equal(classify([path]).level, "full", path);
    assert.equal(isLightPath(path), false, path);
  }
});

test("深い階層の *.md はallow-listに含めない", () => {
  assert.equal(isLightPath("src/notes.md"), false);
  assert.equal(isLightPath("tools/lib/README.md"), false);
});

test("attestations以外のcompat配下はfull", () => {
  assert.equal(isLightPath("compat/v3.7.24/attestations/1/a.json"), true);
  assert.equal(isLightPath("compat/v3.7.24/attestations"), false);
  assert.equal(isLightPath("compat/v3.7.24/catalog.json"), false);
});

test("空diffはfull（vacuous lightで検証をスキップしない）", () => {
  const result = classify([]);
  assert.equal(result.level, "full");
  assert.equal(result.reason, "empty-diff");
});

test("空白行のみの入力もempty-diffとしてfull", () => {
  const result = classify(["", "  ", "\n"]);
  assert.equal(result.level, "full");
  assert.equal(result.reason, "empty-diff");
});

test("categoryOfは分類カテゴリを返す", () => {
  assert.equal(categoryOf("docs/a.md"), "docs");
  assert.equal(categoryOf("README.md"), "root-markdown");
  assert.equal(categoryOf("compat/v3.7.24/attestations/1/m.json"), "attestation-snapshot");
  assert.equal(categoryOf("src/main.zig"), "full-required");
});

test("decideはpull_request/push以外のeventをfullへ倒す", () => {
  for (const event of ["workflow_dispatch", "schedule", "release", "pull_request_target"]) {
    const result = decide({ event, base: "", head: "HEAD", files: "" });
    assert.equal(result.level, "full", event);
    assert.equal(result.reason, `event:${event}`, event);
  }
});

test("decideはbase欠落・zero shaをfullへ倒す", () => {
  for (const base of ["", "0000000000000000000000000000000000000000"]) {
    const result = decide({ event: "push", base, head: "HEAD", files: "" });
    assert.equal(result.level, "full", base);
    assert.equal(result.reason, "no-base", base);
  }
});

test("decideの--filesはgitを介さず分類する", () => {
  const dir = mkdtempSync(join(tmpdir(), "lnako-classify-"));
  const files = join(dir, "files.txt");
  writeFileSync(files, "docs/a.md\nREADME.md\n");
  const result = decide({ event: "pull_request", base: "", head: "HEAD", files });
  assert.equal(result.level, "light");
});

test("CLIは--filesの分類結果をstdoutと--outputへ書き出す", () => {
  const dir = mkdtempSync(join(tmpdir(), "lnako-classify-"));
  const files = join(dir, "files.txt");
  const output = join(dir, "output.txt");
  writeFileSync(files, "docs/a.md\nsrc/main.zig\n");
  const result = spawnSync(process.execPath, [
    resolve(root, "tools/classify_changes.mjs"),
    "--event", "pull_request",
    "--files", files,
    "--output", output,
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^level=full$/m);
  assert.match(result.stdout, /^reason=heavy-paths$/m);
  assert.match(result.stdout, /src\/main\.zig/);
  assert.equal(readFileSync(output, "utf8"), "level=full\nreason=heavy-paths\n");
});

test("CIと同じ相対パス起動でもlevelを出力する", () => {
  const dir = mkdtempSync(join(tmpdir(), "lnako-classify-"));
  const files = join(dir, "files.txt");
  const output = join(dir, "output.txt");
  writeFileSync(files, "docs/a.md\n");
  const result = spawnSync(process.execPath, [
    "tools/classify_changes.mjs",
    "--event", "pull_request",
    "--files", files,
    "--output", output,
  ], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^level=light$/m);
  assert.equal(readFileSync(output, "utf8"), "level=light\nreason=allow-list\n");
});

test("--filesが読めない場合はdiff-errorでfullへ倒す", () => {
  const result = decide({ event: "pull_request", base: "", head: "HEAD", files: "/nonexistent/files.txt" });
  assert.equal(result.level, "full");
  assert.equal(result.reason, "diff-error");
});

test("diffPathsはrenameの移動元パスも分類対象へ含める", () => {
  const dir = mkdtempSync(join(tmpdir(), "lnako-classify-git-"));
  const git = (args) => {
    const result = spawnSync("git", args, { cwd: dir, encoding: "utf8" });
    assert.equal(result.status, 0, `${args.join(" ")}: ${result.stderr}`);
    return result.stdout;
  };
  git(["init", "-q"]);
  git(["config", "user.email", "test@example.com"]);
  git(["config", "user.name", "test"]);
  writeFileSync(join(dir, "heavy.zig"), "pub fn x() void {}\n");
  git(["add", "."]);
  git(["commit", "-qm", "init"]);
  const base = git(["rev-parse", "HEAD"]).trim();
  git(["mv", "heavy.zig", "renamed.md"]);
  git(["commit", "-qm", "rename"]);
  // --no-renamesなしだと移動先しか出ずheavy→light移動を取りこぼす。
  const names = diffPaths(base, "HEAD", dir).sort();
  assert.deepEqual(names, ["heavy.zig", "renamed.md"]);
  assert.equal(classify(names).level, "full");
});
