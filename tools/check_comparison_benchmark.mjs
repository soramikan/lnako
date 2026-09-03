import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const options = parseArguments(process.argv.slice(2));
const root = resolve(import.meta.dirname, "..");

const json = JSON.parse(await readFile(resolve(root, options.json), "utf8"));
const markdown = await readFile(resolve(root, options.markdown), "utf8");

if (json.schema_version !== 1) throw new Error("未対応のschema_versionです");
if (!json.project || !json.version || typeof json.git_commit !== "string") throw new Error("メタ情報が不足しています");
if (!json.target?.os || !json.target?.arch) throw new Error("target情報が不足しています");
if (!json.toolchain || typeof json.toolchain !== "object") throw new Error("toolchain情報が不足しています");
if (typeof json.generated_at_unix_ms !== "number") throw new Error("generated_at_unix_msが不正です");
if (!json.suite_name || !json.suite) throw new Error("suite情報が不足しています");
if (typeof json.iterations !== "number" || json.iterations <= 0) throw new Error("iterationsが不正です");
if (typeof json.warmup !== "number" || json.warmup < 0) throw new Error("warmupが不正です");
if (!Array.isArray(json.cases) || json.cases.length === 0) throw new Error("casesが空です");

for (const item of json.cases) {
  if (!item.id || typeof item.expected_stdout !== "string") throw new Error(`case ${item.id ?? "?"} の基本情報が不足しています`);
  if (!Array.isArray(item.measurements) || item.measurements.length === 0) {
    throw new Error(`case ${item.id} に計測値がありません`);
  }
  for (const m of item.measurements) {
    if (!m.runtime || !m.mode) throw new Error(`case ${item.id} のmeasurementにruntime/modeがありません`);
    if (!Array.isArray(m.samples_ns) || m.samples_ns.length === 0) throw new Error(`case ${item.id}/${m.runtime}/${m.mode} のsamples_nsが空です`);
    if (typeof m.min_ns !== "number" || typeof m.median_ns !== "number" || typeof m.max_ns !== "number") {
      throw new Error(`case ${item.id}/${m.runtime}/${m.mode} の集計値が不正です`);
    }
    if (m.min_ns > m.median_ns || m.median_ns > m.max_ns) {
      throw new Error(`case ${item.id}/${m.runtime}/${m.mode} のmin/median/maxの大小関係が不正です`);
    }
    if (m.samples_ns.some((s) => typeof s !== "number" || s < 0)) {
      throw new Error(`case ${item.id}/${m.runtime}/${m.mode} に負のサンプル値が含まれています`);
    }
    const sorted = [...m.samples_ns].sort((a, b) => a - b);
    if (sorted[0] !== m.min_ns) throw new Error(`case ${item.id}/${m.runtime}/${m.mode} のmin_nsが実際の最小値と一致しません`);
    if (sorted[sorted.length - 1] !== m.max_ns) throw new Error(`case ${item.id}/${m.runtime}/${m.mode} のmax_nsが実際の最大値と一致しません`);
  }
}

// Markdown sanity checks
if (!markdown.startsWith("# lnako comparison benchmark")) throw new Error("Markdownの見出しが不正です");
for (const item of json.cases) {
  if (!markdown.includes(`## ${item.id}`)) throw new Error(`Markdownにcase ${item.id} の見出しがありません`);
  if (!markdown.includes(item.expected_stdout.trimEnd())) throw new Error(`Markdownにcase ${item.id} の期待stdoutがありません`);
  for (const m of item.measurements) {
    const row = `| ${m.runtime} | ${m.mode} | ${m.samples_ns.length} | ${m.min_ns} | ${m.median_ns} | ${m.max_ns} |`;
    if (!markdown.includes(row)) throw new Error(`Markdownにcase ${item.id}/${m.runtime}/${m.mode} の行がありません`);
  }
}

console.log(`比較ベンチマーク結果を検証しました: ${json.cases.length} cases / ${json.suite_name}`);

function parseArguments(arguments_) {
  const parsed = { json: null, markdown: null };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--json") parsed.json = nextValue(arguments_, ++index, argument);
    else if (argument === "--markdown") parsed.markdown = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/check_comparison_benchmark.mjs --json <path> --markdown <path>`);
  }
  if (!parsed.json || !parsed.markdown) throw new Error("--json と --markdown を指定してください");
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}
