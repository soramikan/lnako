// tracked canonical evidence が現行ソースから再生成される内容と一致するか検証する。
// 各ジェネレータは measured 形を stage へ出力し、freshnessBytes（canonicalize＋
// environment 除去後の決定的 byte 列）でコミット済み正本と比較する。
// 揮発 metadata（provenance.lnako・environment.node・絶対パス・ephemeral 値）は
// 比較へ入らず、純粋な内容クレームの差分だけを検出する。
// coverage 正本は Linux dedicated shard の merge 結果が freshness を供給するため、
// ここでは coverage を除く16件を扱う。

import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalizeEvidenceDocument, freshnessBytes, stripEnvironmentForComparison } from "./lib/evidence/provenance.mjs";
import { json } from "./lib/evidence/constants.mjs";
import {
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

const usage = "usage: node tools/check_evidence_freshness.mjs [--no-build] [--rounds N] [--dispatch-evidence PATH] [--compat-js-evidence PATH] [--help]";
const noBuild = arguments_.includes("--no-build");
const help = arguments_.includes("--help") || arguments_.includes("-h");

const coverageBasename = "dispatch-coverage-evidence.json";

validateArguments();
if (help) {
  console.log(`${usage}

coverage を除く16件の canonical evidence について、現行ソースから measured 形を
再生成し freshnessBytes がコミット済み正本と一致することを確認します。
スクリプトが生成するファイルは --rounds（既定2）回連続で生成・比較し、
run ごとの揮発値が canonical 比較へ混入しないこともあわせて確認します。
--dispatch-evidence / --compat-js-evidence は CI job が別 step で生成済みの
measured artifact を転用する場合に指定します（そのファイルは再生成せず比較のみ）。
--no-build は既存の normal ReleaseSafe バイナリを使う場合に最初の build を省略します。`);
} else {
  await main();
}

function optionValue(flag) {
  const index = arguments_.indexOf(flag);
  if (index === -1 || index + 1 >= arguments_.length) throw new Error(usage);
  return arguments_[index + 1];
}

function validateArguments() {
  const allowed = new Set(["--no-build", "--help", "-h", "--rounds", "--dispatch-evidence", "--compat-js-evidence"]);
  const valueFlags = new Set(["--rounds", "--dispatch-evidence", "--compat-js-evidence"]);
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (!allowed.has(argument)) throw new Error(usage);
    if (valueFlags.has(argument)) {
      index += 1;
      if (index >= arguments_.length) throw new Error(usage);
    }
  }
}

async function main() {
  const rounds = parseRounds();
  const provided = new Map();
  const dispatchEvidence = optionalPath("--dispatch-evidence");
  const compatJsEvidence = optionalPath("--compat-js-evidence");
  if (dispatchEvidence !== null) provided.set("dispatch-evidence.json", dispatchEvidence);
  if (compatJsEvidence !== null) provided.set("compat-js-evidence.json", compatJsEvidence);

  const cache = resolve(root, ".cache");
  await mkdir(cache, { recursive: true });
  const stage = await mkdtemp(join(cache, "evidence-freshness-"));
  const committedBytes = new Map();
  const committedDocuments = new Map();
  const mismatches = new Set();
  const mismatchDetails = new Map();
  let compared = 0;

  // freshnessBytes 一致時は内容同一。不一致時のみ差分のある leaf path を診断に出す。
  const diffLeafPaths = (left, right, path, out, limit = 8) => {
    if (out.length >= limit) return;
    if (typeof left !== typeof right || left === null || right === null || typeof left !== "object") {
      if (left !== right) out.push(path || "<root>");
      return;
    }
    for (const key of new Set([...Object.keys(left), ...Object.keys(right)])) diffLeafPaths(left[key], right[key], path === "" ? key : `${path}.${key}`, out, limit);
  };

  const compare = async (basename, measuredPath) => {
    if (!committedBytes.has(basename)) {
      const committedDocument = JSON.parse(await readFile(resolve(compat, basename), "utf8"));
      committedBytes.set(basename, freshnessBytes(committedDocument));
      committedDocuments.set(basename, stripEnvironmentForComparison(canonicalizeEvidenceDocument(committedDocument)));
    }
    const generatedDocument = stripEnvironmentForComparison(canonicalizeEvidenceDocument(JSON.parse(await readFile(measuredPath, "utf8"))));
    compared += 1;
    if (json(generatedDocument) !== committedBytes.get(basename)) {
      mismatches.add(basename);
      if (!mismatchDetails.has(basename)) {
        const leaves = [];
        diffLeafPaths(committedDocuments.get(basename), generatedDocument, "", leaves);
        mismatchDetails.set(basename, leaves);
      }
    }
  };

  // ジェネレータは既存出力を上書きしないため、round ごとに別ディレクトリへ生成する。
  const roundPathFor = async (round) => {
    const roundDirectory = join(stage, `round-${round}`);
    await mkdir(roundDirectory, { recursive: true });
    return (basename) => join(roundDirectory, basename);
  };

  if (noBuild) {
    await assertCompilerExists(root, "--no-buildで使用するnormal ReleaseSafe");
  } else {
    buildNormalCompiler(root);
  }

  const normalSteps = (pathFor) => normalGeneratorSteps(pathFor)
    .filter((step) => step.basename !== coverageBasename && !provided.has(step.basename));

  for (let round = 1; round <= rounds; round += 1) {
    const roundPath = await roundPathFor(round);
    for (const step of normalSteps(roundPath)) {
      runToolScript(root, step.script, step.args);
      await compare(step.basename, roundPath(step.basename));
    }
  }

  if (provided.has("compat-js-evidence.json")) {
    await compare("compat-js-evidence.json", provided.get("compat-js-evidence.json"));
  } else {
    // compat-js build は zig-out/bin/lnako を差し替えるため、失敗しても
    // normal ReleaseSafe への復元を必ず試みる。
    buildQuickJsCompiler(root);
    let primaryError = null;
    let restoreError = null;
    try {
      for (let round = 1; round <= rounds; round += 1) {
        const roundPath = await roundPathFor(round);
        const compatJs = compatJsGeneratorStep(roundPath);
        runToolScript(root, compatJs.script, compatJs.args);
        await compare(compatJs.basename, roundPath(compatJs.basename));
      }
    } catch (error) {
      primaryError = error;
    } finally {
      try {
        buildNormalCompiler(root);
      } catch (error) {
        restoreError = error;
      }
    }
    if (primaryError !== null) throw primaryError;
    if (restoreError !== null) throw new Error(`normal ReleaseSafeへの復元に失敗しました: ${restoreError.message}`, { cause: restoreError });
  }

  for (const [basename, measuredPath] of provided) {
    if (basename === "compat-js-evidence.json") continue;
    await compare(basename, measuredPath);
  }

  if (mismatches.size > 0) {
    const detail = [...mismatches].sort().map((basename) => {
      const leaves = mismatchDetails.get(basename) ?? [];
      return `${basename}: ${leaves.length === 0 ? "（差分leaf特定不可）" : leaves.join(", ")}`;
    }).join("\n");
    // 不一致時のstageは差分診断用に残す。成功時のみ削除する。
    throw new Error(`canonical evidence が現行ソースの再生成結果と一致しません:\n${detail}\nnode tools/update_current_evidence.mjs で正本を再生成し、コードと証拠を同じコミットにまとめてください（stage保持: ${stage}）。`);
  }
  await rm(stage, { recursive: true, force: true });
  console.log(`canonical evidence freshness OK（${compared}回比較）`);
}

function parseRounds() {
  if (!arguments_.includes("--rounds")) return 2;
  const value = Number(optionValue("--rounds"));
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`--rounds は1以上の整数を指定してください: ${optionValue("--rounds")}`);
  return value;
}

function optionalPath(flag) {
  if (!arguments_.includes(flag)) return null;
  return resolve(optionValue(flag));
}
