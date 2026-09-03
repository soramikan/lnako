import { rm } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(import.meta.url), "..", "..");
const compat = resolve(root, "compat/v3.7.24");
const noBuild = process.argv.includes("--no-build");

function run(script, args) {
  const result = spawnSync(process.execPath, [resolve(root, "tools", script), ...args], {
    cwd: root,
    env: process.env,
    stdio: "inherit",
  });
  if (result.status !== 0) throw new Error(`${script} が失敗しました`);
}

async function deleteIfExists(path) {
  await rm(path, { force: true });
}

if (!noBuild) {
  const build = spawnSync("zig", ["build"], { cwd: root, stdio: "inherit" });
  if (build.status !== 0) throw new Error("zig build が失敗しました");
}

const dispatchEvidence = resolve(compat, "dispatch-evidence.json");
const dispatchCoverageEvidence = resolve(compat, "dispatch-coverage-evidence.json");
const expectedExitEvidence = resolve(compat, "expected-exit-evidence.json");
const compatJsEvidence = resolve(compat, "compat-js-evidence.json");
const globalBindingEvidence = resolve(compat, "global-binding-evidence.json");
const directoryBindingEvidence = resolve(compat, "directory-binding-evidence.json");

await deleteIfExists(dispatchEvidence);
await deleteIfExists(dispatchCoverageEvidence);
await deleteIfExists(expectedExitEvidence);
await deleteIfExists(compatJsEvidence);
await deleteIfExists(globalBindingEvidence);
await deleteIfExists(directoryBindingEvidence);

run("check_dispatch_trace.mjs", ["--no-build", "--evidence-output", dispatchEvidence]);
run("check_dispatch_coverage.mjs", ["--no-build", "--output", dispatchCoverageEvidence]);
run("check_node_exit_evidence.mjs", ["--no-build", "--output", expectedExitEvidence]);
run("check_compat_js_evidence.mjs", ["--no-build", "--evidence-output", compatJsEvidence]);
run("check_global_binding_evidence.mjs", ["--no-build", "--profile", "file-copy", "--evidence-output", globalBindingEvidence]);
run("check_global_binding_evidence.mjs", ["--no-build", "--profile", "node-directory", "--evidence-output", directoryBindingEvidence]);

const staticFixtures = [
  ["native-scalar-system-constants", resolve(compat, "static-constant-evidence.json")],
  ["native-string-system-constants", resolve(compat, "static-string-constant-evidence.json")],
  ["native-array-system-constants", resolve(compat, "static-array-constant-evidence.json")],
  ["native-datetime-era-data", resolve(compat, "static-datetime-era-constant-evidence.json")],
  ["native-datetime-plugin-era-data", resolve(compat, "static-datetime-plugin-era-constant-evidence.json")],
  ["native-node-archive-constant", resolve(compat, "static-node-archive-constant-evidence.json")],
  ["native-node-command-line-constants", resolve(compat, "static-node-command-line-constant-evidence.json")],
  ["native-node-mother-path", resolve(compat, "static-node-mother-path-constant-evidence.json")],
  ["native-system-promise-reject", resolve(compat, "static-promise-reject-constant-evidence.json")],
  ["native-caniuse-agents", resolve(compat, "static-caniuse-agents-constant-evidence.json")],
  ["native-node-http-initial-constants", resolve(compat, "static-node-http-initial-constant-evidence.json")],
];

for (const [fixtureId, path] of staticFixtures) {
  await deleteIfExists(path);
  run("check_static_constant_evidence.mjs", ["--no-build", "--fixture", fixtureId, "--evidence-output", path]);
}

run("sync_compat_evidence.mjs", ["--generate"]);

console.log("互換性証拠ファイルを現行HEADで更新しました");
