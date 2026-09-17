// update_current_evidence.mjs と check_evidence_freshness.mjs が共有する
// 正本 evidence ジェネレータ起動列。各 step は measured 形を outputPath へ出力し、
// canonical 化（provenance.lnako・environment.node の除去）は書込み側が行う。

import { access } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

export const evidenceBasenames = [
  "dispatch-evidence.json",
  "dispatch-coverage-evidence.json",
  "expected-exit-evidence.json",
  "compat-js-evidence.json",
  "global-binding-evidence.json",
  "directory-binding-evidence.json",
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
];

const staticFixtures = [
  ["native-scalar-system-constants", "static-constant-evidence.json"],
  ["native-string-system-constants", "static-string-constant-evidence.json"],
  ["native-array-system-constants", "static-array-constant-evidence.json"],
  ["native-datetime-era-data", "static-datetime-era-constant-evidence.json"],
  ["native-datetime-plugin-era-data", "static-datetime-plugin-era-constant-evidence.json"],
  ["native-node-archive-constant", "static-node-archive-constant-evidence.json"],
  ["native-node-command-line-constants", "static-node-command-line-constant-evidence.json"],
  ["native-node-mother-path", "static-node-mother-path-constant-evidence.json"],
  ["native-system-promise-reject", "static-promise-reject-constant-evidence.json"],
  ["native-caniuse-agents", "static-caniuse-agents-constant-evidence.json"],
  ["native-node-http-initial-constants", "static-node-http-initial-constant-evidence.json"],
];

function step(basename, script, args) {
  return { basename, script, args };
}

// normal ReleaseSafe バイナリで生成する16件（compat-js を除く）。
export function normalGeneratorSteps(outputPathFor) {
  const steps = [
    step("dispatch-evidence.json", "check_dispatch_trace.mjs", ["--no-build", "--evidence-output", outputPathFor("dispatch-evidence.json")]),
    step("dispatch-coverage-evidence.json", "check_dispatch_coverage.mjs", ["--no-build", "--include-native", "--output", outputPathFor("dispatch-coverage-evidence.json")]),
    step("expected-exit-evidence.json", "check_node_exit_evidence.mjs", ["--no-build", "--output", outputPathFor("expected-exit-evidence.json")]),
    step("global-binding-evidence.json", "check_global_binding_evidence.mjs", ["--no-build", "--profile", "file-copy", "--evidence-output", outputPathFor("global-binding-evidence.json")]),
    step("directory-binding-evidence.json", "check_global_binding_evidence.mjs", ["--no-build", "--profile", "node-directory", "--evidence-output", outputPathFor("directory-binding-evidence.json")]),
  ];
  for (const [fixtureId, basename] of staticFixtures) {
    steps.push(step(basename, "check_static_constant_evidence.mjs", ["--no-build", "--fixture", fixtureId, "--evidence-output", outputPathFor(basename)]));
  }
  return steps;
}

// QuickJS ReleaseSafe バイナリで生成する1件。
export function compatJsGeneratorStep(outputPathFor) {
  return step("compat-js-evidence.json", "check_compat_js_evidence.mjs", ["--no-build", "--evidence-output", outputPathFor("compat-js-evidence.json")]);
}

export function runToolCommand(root, command, args, label) {
  const environment = {
    ...process.env,
    ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache"),
  };
  const result = spawnSync(command, args, {
    cwd: root,
    env: environment,
    stdio: "inherit",
  });
  if (result.error) throw new Error(`${label} の起動に失敗しました: ${result.error.message}`, { cause: result.error });
  if (result.status !== 0) {
    const signal = result.signal === null ? "" : ` signal=${result.signal}`;
    throw new Error(`${label} が失敗しました: status=${result.status}${signal}`);
  }
}

export function runToolScript(root, script, args) {
  runToolCommand(root, process.execPath, [resolve(root, "tools", script), ...args], script);
}

export function buildNormalCompiler(root) {
  runToolCommand(root, "zig", ["build", "-Doptimize=ReleaseSafe"], "normal ReleaseSafe build");
}

export function buildQuickJsCompiler(root) {
  runToolCommand(root, "zig", ["build", "-Doptimize=ReleaseSafe", "-Dcompat-js=true"], "QuickJS ReleaseSafe build");
}

export async function assertCompilerExists(root, label) {
  const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
  try {
    await access(compiler);
  } catch (error) {
    throw new Error(`${label}バイナリがありません: ${compiler}`, { cause: error });
  }
}
