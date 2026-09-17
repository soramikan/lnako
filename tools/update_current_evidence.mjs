import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isManifestInput } from "./lib/evidence/manifest.mjs";
import { json } from "./lib/evidence/constants.mjs";
import { canonicalizeEvidenceDocument } from "./lib/evidence/provenance.mjs";
import { isCanonicalEnvironment } from "./lib/evidence/validators.mjs";
import {
  evidenceBasenames,
  normalGeneratorSteps,
  compatJsGeneratorStep,
  runToolScript,
  buildNormalCompiler,
  buildQuickJsCompiler,
  assertCompilerExists,
} from "./lib/evidence/generators.mjs";

const root = resolve(fileURLToPath(import.meta.url), "..", "..");
const compat = resolve(root, "compat/v3.7.24");
const arguments_ = process.argv.slice(2);

const usage = "usage: node tools/update_current_evidence.mjs [--no-build] [--help]";
const noBuild = arguments_.includes("--no-build");
const help = arguments_.includes("--help") || arguments_.includes("-h");

const evidenceFiles = evidenceBasenames.map((basename) => ({ basename, canonical: resolve(compat, basename) }));

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
  // canonical 正本は生成環境 darwin/arm64 を宣言する。他環境では canonicalize 後も
  // 当該環境の platform/arch が残るため、書き込み後の sync が必ず失敗する。
  // 部分書き換え状態を残さないよう、生成より前に拒否する。
  if (!isCanonicalEnvironment({ platform: process.platform, arch: process.arch })) {
    throw new Error(`canonical証拠の生成はdarwin/arm64でのみ有効です（この環境: ${process.platform}/${process.arch}）。Linux dedicated shardが供給するcoverage merge結果の照合には tools/check_dispatch_coverage_shards.mjs を使ってください。`);
  }
  const initialState = assertSourceTreeReady("開始時");
  const stage = await createStageDirectory();
  console.log(`互換性証拠のstage: ${stage}`);

  let primaryError = null;
  let quickJsBuildStarted = false;
  let restoreError = null;
  try {
    if (noBuild) {
      await assertCompilerExists(root, "--no-buildで使用するnormal ReleaseSafe");
    } else {
      buildNormalCompiler(root);
    }

    await runNormalEvidenceGenerators(stage);

    // The compat-js build replaces the same zig-out/bin/lnako path. Mark the
    // restore as needed before invoking the build so even a partially failed
    // QuickJS build is followed by an attempt to put the normal compiler back.
    quickJsBuildStarted = true;
    buildQuickJsCompiler(root);
    const compatJs = compatJsGeneratorStep((basename) => stagePath(stage, basename));
    runScript(compatJs.script, compatJs.args);
  } catch (error) {
    primaryError = error;
  } finally {
    if (quickJsBuildStarted) {
      try {
        buildNormalCompiler(root);
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
  const { written, skipped } = await copyStagedEvidence(stage);
  runScript("sync_compat_evidence.mjs", ["--generate"]);
  runScript("check_interpreter_only_classification.mjs", ["--generate"]);
  console.log(`互換性証拠ファイルを現行ソースで更新しました（canonical 更新${written}件・変更なし${skipped}件、stage保持: ${stage}）`);
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
  for (const step of normalGeneratorSteps((basename) => stagePath(stage, basename))) {
    runToolScript(root, step.script, step.args);
  }
}

// staged measured evidence を canonical 形へ変換し、内容が変わったファイルだけを
// 書き換える。無関係な変更で全17件が書き換わることを防ぐ。
async function copyStagedEvidence(stage) {
  let written = 0;
  let skipped = 0;
  for (const { basename, canonical } of evidenceFiles) {
    const measured = JSON.parse(await readFile(stagePath(stage, basename), "utf8"));
    const canonicalBytes = json(canonicalizeEvidenceDocument(measured));
    let existing = null;
    try {
      existing = await readFile(canonical, "utf8");
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    if (existing === canonicalBytes) {
      skipped += 1;
      continue;
    }
    await writeFile(canonical, canonicalBytes);
    written += 1;
  }
  return { written, skipped };
}

function runScript(script, args) {
  runToolScript(root, script, args);
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
