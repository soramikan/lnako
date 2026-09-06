import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const generatedEvidenceNames = new Set([
  "dispatch-evidence.json",
  "dispatch-coverage-evidence.json",
  "expected-exit-evidence.json",
  "compat-js-evidence.json",
  "global-binding-evidence.json",
  "directory-binding-evidence.json",
  "interpreter-only-classification.json",
  "evidence.json",
  "summary.json",
  "static-constant-evidence.json",
  "static-string-constant-evidence.json",
  "static-array-constant-evidence.json",
  "static-datetime-era-constant-evidence.json",
  "static-datetime-plugin-era-constant-evidence.json",
  "static-node-archive-constant-evidence.json",
  "static-node-command-line-constant-evidence.json",
  "static-node-mother-path-constant-evidence.json",
  "static-promise-reject-constant-evidence.json",
  "static-caniuse-agents-constant-evidence.json",
  "static-node-http-initial-constant-evidence.json",
]);

const excludedManifestPrefixes = [
  "compat/v3.7.24/attestations/",
  "docs/",
  ".github/",
  ".githooks/",
  ".devin/",
  ".cache/",
  ".git",
  "benchmarks/results/",
];

const excludedManifestSuffixes = [
  "/gonako.nako3",
];

const excludedManifestGlobs = [
  /^AGENTS\.md$/,
  /^CLAUDE\.md$/,
  /^README\.md$/,
  /^README.*\.md$/,
  /^LICENSE.*$/,
  /^UPSTREAM_LICENSE$/,
  /^\.gitignore$/,
  /^\.gitattributes$/,
  /^\.editorconfig$/,
  /^tools\/fast_forward_evidence\.mjs$/,
  /^tools\/create_benchmark_oracle_shim\.mjs$/,
  /^tools\/prune_llvm_toolchain\.mjs$/,
  /^tools\/benchmark_.*\.mjs$/,
  /^tools\/render_benchmark_.*\.mjs$/,
  /^tools\/run_comparison_.*\.mjs$/,
  /^tools\/setup_benchmark_.*\.mjs$/,
  /^tools\/compare_native_oracle\.mjs$/,
  /^tools\/compare_interpreter_oracle\.mjs$/,
  /^tools\/check_distribution\.mjs$/,
  /^tools\/create_distribution\.mjs$/,
  /^tools\/check_ci_workflow\.mjs$/,
  /^tools\/check_release_workflow\.mjs$/,
  /^tools\/check_aot_suite_parallel\.mjs$/,
  /^tools\/check_dispatch_coverage_shards\.mjs$/,
  /^tools\/update_current_evidence\.mjs$/,
  /^tools\/sync_compat_evidence\.mjs$/,
  /^tools\/check_interpreter_only_classification\.mjs$/,
  /^tools\/source_structure\.json$/,
  /^docs\/.*$/,
  /^benchmarks\/results\/.*$/,
  /^benchmarks\/cases\/.*\/gonako\.nako3$/,
];

export function isManifestInput(relativePath) {
  for (const prefix of excludedManifestPrefixes) {
    if (relativePath.startsWith(prefix)) return false;
  }
  for (const suffix of excludedManifestSuffixes) {
    if (relativePath.endsWith(suffix)) return false;
  }
  const basename = relativePath.split("/").pop();
  if (generatedEvidenceNames.has(basename)) return false;
  for (const glob of excludedManifestGlobs) {
    if (glob.test(relativePath)) return false;
  }
  return true;
}

export function listManifestInputFiles(root) {
  const result = spawnSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" });
  if (result.status !== 0 || result.error) throw new Error("git ls-filesに失敗しました");
  const files = result.stdout
    .split("\0")
    .filter((name) => name.length > 0)
    .filter(isManifestInput)
    .sort();
  return files;
}

export function computeSourceManifestSha256Sync(root) {
  const files = listManifestInputFiles(root);
  const hash = createHash("sha256");
  for (const relative of files) {
    const content = readFileSync(resolve(root, relative));
    hash.update(`${relative}\0`);
    hash.update(content);
  }
  return {
    sha256: hash.digest("hex"),
    files,
  };
}

export async function computeSourceManifestSha256(root) {
  return computeSourceManifestSha256Sync(root);
}

export function assertSourceManifestMatchesSync(root, expectedSha256) {
  const actual = computeSourceManifestSha256Sync(root);
  if (actual.sha256 !== expectedSha256) {
    throw new Error(`source manifest SHA-256が一致しません: expected ${expectedSha256}, actual ${actual.sha256}`);
  }
}

export async function assertSourceManifestMatches(root, expectedSha256) {
  assertSourceManifestMatchesSync(root, expectedSha256);
}
