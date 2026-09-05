import { readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, relative, resolve } from "node:path";
import { validateBenchmarkReport } from "./lib/benchmark_report.mjs";

// A readable snapshot of the recorded measurements, without executing runtimes.
const args = process.argv.slice(2);
function option(name) {
  const index = args.indexOf(name);
  if (index < 0 || !args[index + 1]) throw new Error(`必要な引数: ${name}`);
  return args[index + 1];
}
const jsonPath = resolve(option("--json"));
const markdownPath = resolve(option("--markdown"));
const report = JSON.parse(readFileSync(jsonPath, "utf8"));
validateBenchmarkReport(report);
if (report.schema_version !== 2) throw new Error("v2の結果が必要です");
const cell = (value) => String(value ?? "未取得").replaceAll("|", "\\|").replaceAll("\n", " ");
const ms = (value) => (value / 1e6).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const link = (path) => relative(dirname(markdownPath), resolve(path)).replaceAll("\\", "/");
const measurement = (item, runtime, mode) => item.measurements.find((row) => row.runtime === runtime && row.mode === mode);
const value = (item, runtime, mode) => {
  const row = measurement(item, runtime, mode);
  return row ? ms(row.median_ns) + (row.measurement === "steady_state" && row.median_ns < 200_000_000 ? " †" : "") : "—";
};
const lines = [
  `# ベンチマーク結果 — ${report.target.os} / ${report.target.arch}`,
  "", `[概要と読み方](RESULTS.md) · [元のJSON](${cell(basename(jsonPath))})`, "",
  "## 測定条件", "", "| 項目 | 値 |", "| --- | --- |",
];
const metadata = {
  "測定日時（UTC）": new Date(report.generated_at_unix_ms).toISOString(),
  "測定コミット": `${report.git_commit}（${report.git_dirty ? "作業ツリーに変更あり" : "clean"}）`,
  "プロファイル": `${report.profile} / warmup ${report.warmup}回 / 測定 ${report.iterations}回`,
  "AOT / C / Rust 最適化": report.optimization,
  "CPU": report.hardware.cpu_model,
  "論理CPU数": report.hardware.cpu_logical_count,
  "メモリ": `${(report.hardware.total_memory_bytes / 2 ** 30).toFixed(2)} GiB`,
  "OS release": report.hardware.os_release,
  "スイートSHA-256": report.suite_sha256,
};
for (const [key, val] of Object.entries(metadata)) lines.push(`| ${key} | ${cell(val)} |`);
lines.push("", "### 処理系とコンパイラ", "", "| 処理系 | 区分 | 自己表示バージョン |", "| --- | --- | --- |");
for (const runtime of report.selected_runtimes) lines.push(`| ${runtime} | ${["c", "rust", "python"].includes(runtime) ? "参考値" : "正式比較"} | ${cell(report.toolchain[runtime])} |`);
const provenance = report.runtimes.gonako?.provenance;
if (provenance) lines.push("", `gonako配布版: ${cell(provenance.release ?? "未確認")}。配布版とバイナリの自己表示バージョンは別々に記録しています。SHA-256: \`${cell(provenance.sha256)}\`。`, ...(provenance.url ? [`[公式配布元](${provenance.url})`] : []));
lines.push("", "## 正式比較：実行時間の中央値", "",
  "単位は **ms**、小さいほど短時間です。全値にプロセス起動・終了を含み、lnako AOTの事前コンパイルは含みません。† はsteady_stateで中央値200ms未満の測定です。— は未測定・未対応で、0msではありません。",
  "", "| ケース | cnako | gonako | lnako interpreter | lnako AOT |", "| --- | ---: | ---: | ---: | ---: |");
for (const item of report.cases.filter((item) => item.measurement !== "compile")) lines.push(`| \`${item.id}\` | ${value(item, "cnako", "run")} | ${value(item, "gonako", "run")} | ${value(item, "lnako", "interpreter")} | ${value(item, "lnako", "aot_run")} |`);
lines.push("", "## 参考値：C・Rustの実行時間", "",
  "同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。",
  "", "| ケース | C | Rust |", "| --- | ---: | ---: |");
for (const item of report.cases.filter((item) => item.measurements.some((row) => ["c", "rust"].includes(row.runtime) && row.mode === "run"))) lines.push(`| \`${item.id}\` | ${value(item, "c", "run")} | ${value(item, "rust", "run")} |`);
lines.push("", "## コンパイル時間と実行ファイルサイズ", "",
  "時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。",
  "", "| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |", "| --- | --- | ---: | ---: | ---: |");
for (const item of report.cases) for (const row of item.measurements.filter((row) => row.mode === "compile")) lines.push(`| \`${item.id}\` | ${row.runtime} | ${ms(row.median_ns)} | ${ms(row.p25_ns)}–${ms(row.p75_ns)} | ${row.executable_size_bytes.toLocaleString("en-US")} |`);
lines.push("", "## ケースごとのソースと対応範囲", "",
  "cnakoとlnakoは共通ソースです。gonakoに構文調整が必要な場合は、同じ入力・反復数・期待出力で検証した別ソースをリンクしています。未対応は理由を表示し、成功値へ置き換えません。",
  "", "| ケース | 共通ソース | gonakoソース | gonakoの対応・調整内容 |", "| --- | --- | --- | --- |");
for (const item of report.cases) {
  const source = item.sources.gonako;
  const status = item.runtime_status.gonako;
  const reason = item.runtime_support?.gonako?.reason ?? status.reason ?? "共通ソースで出力一致";
  lines.push(`| \`${item.id}\` | [source](${link(item.source)}) | ${source ? `[source](${link(source)})` : "—"} | ${cell(reason)} |`);
}
lines.push("", "## 全測定のばらつき", "",
  "時間はmsです。IQRはP75−P25、MADは中央値からの絶対偏差の中央値、CVは標準偏差÷平均（%）。生サンプルは元のJSONを参照してください。",
  "", "| ケース | 処理系 / 経路 | 中央値 | P25–P75 | IQR | MAD | 平均 | 標準偏差 | CV |", "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
for (const item of report.cases) for (const row of item.measurements) lines.push(`| \`${item.id}\` | ${row.runtime} / ${row.mode} | ${ms(row.median_ns)} | ${ms(row.p25_ns)}–${ms(row.p75_ns)} | ${ms(row.iqr_ns)} | ${ms(row.mad_ns)} | ${ms(row.mean_ns)} | ${ms(row.stddev_ns)} | ${(row.cv * 100).toFixed(1)}% |`);
const count = report.cases.reduce((sum, item) => sum + item.measurements.length, 0);
lines.push("", `${report.cases.length}ケース・${count}測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。`, "");
if (report.warnings.some((warning) => warning.reason === "baseline_incompatible")) lines.push("前回結果との条件が一致せず、自動の前後比較は適用されていません。このスナップショットだけで過去版からの性能回帰とは断定しません。", "");
writeFileSync(markdownPath, lines.join("\n"));
console.log(`Rendered ${count} measurements: ${markdownPath}`);
