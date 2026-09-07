import { access, copyFile, mkdtemp, mkdir, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isManifestInput } from "./lib/evidence/manifest.mjs";

const root = resolve(fileURLToPath(import.meta.url), "..", "..");
const compat = resolve(root, "compat/v3.7.24");
const arguments_ = process.argv.slice(2);

const usage = "usage: node tools/update_current_evidence.mjs [--no-build] [--help]";
const noBuild = arguments_.includes("--no-build");
const help = arguments_.includes("--help") || arguments_.includes("-h");

const evidenceFiles = [
  { basename: "dispatch-evidence.json", canonical: resolve(compat, "dispatch-evidence.json") },
  { basename: "dispatch-coverage-evidence.json", canonical: resolve(compat, "dispatch-coverage-evidence.json") },
  { basename: "expected-exit-evidence.json", canonical: resolve(compat, "expected-exit-evidence.json") },
  { basename: "compat-js-evidence.json", canonical: resolve(compat, "compat-js-evidence.json") },
  { basename: "global-binding-evidence.json", canonical: resolve(compat, "global-binding-evidence.json") },
  { basename: "directory-binding-evidence.json", canonical: resolve(compat, "directory-binding-evidence.json") },
  { basename: "static-constant-evidence.json", canonical: resolve(compat, "static-constant-evidence.json") },
  { basename: "static-string-constant-evidence.json", canonical: resolve(compat, "static-string-constant-evidence.json") },
  { basename: "static-array-constant-evidence.json", canonical: resolve(compat, "static-array-constant-evidence.json") },
  { basename: "static-datetime-era-constant-evidence.json", canonical: resolve(compat, "static-datetime-era-constant-evidence.json") },
  { basename: "static-datetime-plugin-era-constant-evidence.json", canonical: resolve(compat, "static-datetime-plugin-era-constant-evidence.json") },
  { basename: "static-node-archive-constant-evidence.json", canonical: resolve(compat, "static-node-archive-constant-evidence.json") },
  { basename: "static-node-command-line-constant-evidence.json", canonical: resolve(compat, "static-node-command-line-constant-evidence.json") },
  { basename: "static-node-mother-path-constant-evidence.json", canonical: resolve(compat, "static-node-mother-path-constant-evidence.json") },
  { basename: "static-promise-reject-constant-evidence.json", canonical: resolve(compat, "static-promise-reject-constant-evidence.json") },
  { basename: "static-caniuse-agents-constant-evidence.json", canonical: resolve(compat, "static-caniuse-agents-constant-evidence.json") },
  { basename: "static-node-http-initial-constant-evidence.json", canonical: resolve(compat, "static-node-http-initial-constant-evidence.json") },
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

validateArguments();
if (help) {
  console.log(`${usage}\n\n追跡済みの互換性証拠を削除せず、manifest対象のコード変更をstageした作業ツリーで全17証拠を再生成します。生成後はコードと証拠を同じコミットにまとめてください。\n--no-build は既存のnormal ReleaseSafeバイナリを使う場合に、最初のnormal buildだけを省略します。\nQuickJS互換証拠の生成後はnormal ReleaseSafe buildへ復元します。`);
} else {
  await main();
}

function validateArguments() {
  const allowed = new Set(["--no-build", "--help", "-h"]);
  if (arguments_.some((argument) => !allowed.has(argument))) throw new Error(usage);
}

async function main() {
  const initialState = assertSourceTreeReady("開始時");
  const stage = await createStageDirectory();
  console.log(`互換性証拠のstage: ${stage}`);

  let primaryError = null;
  let quickJsBuildStarted = false;
  let restoreError = null;
  try {
    if (noBuild) {
      await assertCompilerExists("--no-buildで使用するnormal ReleaseSafe");
    } else {
      buildNormal();
    }

    await runNormalEvidenceGenerators(stage);

    // The compat-js build replaces the same zig-out/bin/lnako path. Mark the
    // restore as needed before invoking the build so even a partially failed
    // QuickJS build is followed by an attempt to put the normal compiler back.
    quickJsBuildStarted = true;
    buildQuickJs();
    runScript("check_compat_js_evidence.mjs", [
      "--no-build",
      "--evidence-output",
      stagePath(stage, "compat-js-evidence.json"),
    ]);
  } catch (error) {
    primaryError = error;
  } finally {
    if (quickJsBuildStarted) {
      try {
        buildNormal();
      } catch (error) {
        restoreError = error;
      }
    }
  }

  if (primaryError !== null || restoreError !== null) {
    throw combineErrors(primaryError, restoreError, stage);
  }

  assertSourceTreeReady(`証拠コピー前 (stage: ${stage})`);
  const finalCommit = readGitCommit();
  if (initialState.commit !== finalCommit) {
    throw new Error(`処理中にHEADが変化しました: ${initialState.commit} -> ${finalCommit}\n追跡済み証拠はコピーしていません。stageを診断用に保持しています: ${stage}`);
  }
  await copyStagedEvidence(stage);
  runScript("sync_compat_evidence.mjs", ["--generate"]);
  runScript("check_interpreter_only_classification.mjs", ["--generate"]);
  console.log(`互換性証拠ファイルを現行ソースで更新しました（17件、stage保持: ${stage}）`);
}

async function createStageDirectory() {
  const cache = resolve(root, ".cache");
  await mkdir(cache, { recursive: true });
  return mkdtemp(join(cache, "evidence-update-"));
}

async function runNormalEvidenceGenerators(stage) {
  // Keep dispatch and coverage adjacent and sequential. Coverage uses a
  // repository-local scratch tree on some platforms and removes it only when
  // its audit has finished.
  runScript("check_dispatch_trace.mjs", [
    "--no-build",
    "--evidence-output",
    stagePath(stage, "dispatch-evidence.json"),
  ]);
  runScript("check_dispatch_coverage.mjs", [
    "--no-build",
    "--include-native",
    "--output",
    stagePath(stage, "dispatch-coverage-evidence.json"),
  ]);
  runScript("check_node_exit_evidence.mjs", [
    "--no-build",
    "--output",
    stagePath(stage, "expected-exit-evidence.json"),
  ]);
  runScript("check_global_binding_evidence.mjs", [
    "--no-build",
    "--profile",
    "file-copy",
    "--evidence-output",
    stagePath(stage, "global-binding-evidence.json"),
  ]);
  runScript("check_global_binding_evidence.mjs", [
    "--no-build",
    "--profile",
    "node-directory",
    "--evidence-output",
    stagePath(stage, "directory-binding-evidence.json"),
  ]);
  for (const [fixtureId, basename] of staticFixtures) {
    runScript("check_static_constant_evidence.mjs", [
      "--no-build",
      "--fixture",
      fixtureId,
      "--evidence-output",
      stagePath(stage, basename),
    ]);
  }
}

async function copyStagedEvidence(stage) {
  for (const { basename, canonical } of evidenceFiles) {
    await copyFile(stagePath(stage, basename), canonical);
  }
}

async function assertCompilerExists(label) {
  const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
  try {
    await access(compiler);
  } catch (error) {
    throw new Error(`${label}バイナリがありません: ${compiler}`, { cause: error });
  }
}

function buildNormal() {
  runCommand("zig", ["build", "-Doptimize=ReleaseSafe"], "normal ReleaseSafe build");
}

function buildQuickJs() {
  runCommand("zig", ["build", "-Doptimize=ReleaseSafe", "-Dcompat-js=true"], "QuickJS ReleaseSafe build");
}

function runScript(script, args) {
  runCommand(process.execPath, [resolve(root, "tools", script), ...args], script);
}

function runCommand(command, args, label) {
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

function assertSourceTreeReady(context) {
  const state = readGitState();
  if (state.unstagedManifestInputs.length > 0 || state.untrackedManifestInputs.length > 0) {
    throw new Error(`${context}にはmanifest対象ファイルにunstaged/untrackedな変更があってはいけません。先にstageまたは削除してください。\n${state.unstagedManifestInputs.concat(state.untrackedManifestInputs).join("\n")}`);
  }
  return state;
}

function readGitCommit() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (commit.error || commit.status !== 0) throw new Error("現行commitを取得できません");
  const hash = commit.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(hash)) throw new Error("現行commit形式が不正です");
  return hash;
}

function readGitState() {
  const commit = readGitCommit();
  const status = spawnSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: root, encoding: "utf8" });
  if (status.error || status.status !== 0) throw new Error("lnakoのdirty状態を取得できません");
  const unstagedManifestInputs = [];
  const untrackedManifestInputs = [];
  for (const line of status.stdout.split("\n")) {
    if (line.length < 4) continue;
    const statusCode = line.slice(0, 2);
    const path = line.slice(3).split(" -> ").pop();
    if (statusCode[1] !== " " && statusCode[1] !== "?" && isManifestInput(path)) unstagedManifestInputs.push(path);
    if (statusCode === "??" && isManifestInput(path)) untrackedManifestInputs.push(path);
  }
  return { commit, unstagedManifestInputs, untrackedManifestInputs, status: status.stdout };
}

function stagePath(stage, basename) {
  return join(stage, basename);
}

function combineErrors(primaryError, restoreError, stage) {
  const messages = [];
  if (primaryError !== null) messages.push(primaryError instanceof Error ? primaryError.message : String(primaryError));
  if (restoreError !== null) messages.push(`normal ReleaseSafeへの復元にも失敗しました: ${restoreError instanceof Error ? restoreError.message : String(restoreError)}`);
  messages.push(`追跡済み証拠はコピーしていません。stageを診断用に保持しています: ${stage}`);
  return new Error(messages.join("\n"), { cause: primaryError ?? restoreError ?? undefined });
}
