import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { validateBenchmarkReport } from "./lib/benchmark_report.mjs";

export const root = resolve(import.meta.dirname, "..");

export function parseArguments(arguments_) {
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

export function validateMarkdown(markdown, report) {
  if (typeof markdown !== "string" || !markdown.startsWith("# lnako comparison benchmark")) {
    throw new Error("Markdownの見出しが不正です");
  }
  for (const item of report.cases) {
    if (!markdown.includes(`## ${item.id}`)) throw new Error(`Markdownにcase ${item.id} の見出しがありません`);
    const expectedJson = JSON.stringify(item.expected_stdout);
    const expectedLegacy = item.expected_stdout.trimEnd();
    const escapedJson = escapeMarkdownCell(expectedJson);
    const escapedLegacy = escapeMarkdownCell(expectedLegacy);
    if (!markdown.includes(`expected stdout: \`${escapedJson}\``) && !markdown.includes(`expected stdout: \`${escapedLegacy}\``)) {
      throw new Error(`Markdownにcase ${item.id} の期待stdoutがありません`);
    }
  }
  const rows = report.schema_version === 2 ? parseV2Rows(markdown) : parseV1Rows(markdown);
  const expectedRows = report.cases.flatMap((item) => item.measurements.map((measurement) => ({ item, measurement })));
  if (rows.length !== expectedRows.length) throw new Error(`Markdownの測定行数が不一致です: ${rows.length}/${expectedRows.length}`);
  for (const [index, expected] of expectedRows.entries()) {
    const actual = rows[index];
    const measurement = expected.measurement;
    if (report.schema_version === 1) {
      const expectedRow = {
        runtime: measurement.runtime,
        mode: measurement.mode,
        samples: measurement.samples_ns.length,
        min: measurement.min_ns,
        median: measurement.median_ns,
        max: measurement.max_ns,
      };
      if (JSON.stringify(actual) !== JSON.stringify(expectedRow)) throw new Error(`Markdownの測定行がJSONと一致しません: ${expected.item.id}/${measurement.mode}`);
    } else {
      const expectedRow = {
        runtime: measurement.runtime,
        group: measurement.group,
        measurement: measurement.measurement,
        mode: measurement.mode,
        samples: measurement.samples_ns.length,
        min: measurement.min_ns,
        p25: measurement.p25_ns,
        median: measurement.median_ns,
        p75: measurement.p75_ns,
        max: measurement.max_ns,
        iqr: measurement.iqr_ns,
        mad: measurement.mad_ns,
        mean: measurement.mean_ns,
        stddev: measurement.stddev_ns,
        cv: measurement.cv,
        executable: measurement.executable_size_bytes ?? "N/A",
      };
      if (JSON.stringify(actual) !== JSON.stringify(expectedRow)) throw new Error(`Markdownの測定行がJSONと一致しません: ${expected.item.id}/${measurement.mode}`);
    }
  }
}

function escapeMarkdownCell(value) {
  return String(value).replaceAll("|", "\\|").replaceAll("\n", "\\n");
}

function parseV1Rows(markdown) {
  return [...markdown.matchAll(/^\| ([^|]+) \| ([^|]+) \| (\d+) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \|$/gm)].map((match) => ({
    runtime: match[1],
    mode: match[2],
    samples: Number(match[3]),
    min: Number(match[4]),
    median: Number(match[5]),
    max: Number(match[6]),
  }));
}

function parseV2Rows(markdown) {
  return [...markdown.matchAll(/^\| ([^|]+) \| ([^|]+) \| ([^|]+) \| ([^|]+) \| (\d+) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([0-9]+(?:\.[0-9]+)?) \| ([^|]+) \|$/gm)].map((match) => ({
    runtime: match[1],
    group: match[2],
    measurement: match[3],
    mode: match[4],
    samples: Number(match[5]),
    min: Number(match[6]),
    p25: Number(match[7]),
    median: Number(match[8]),
    p75: Number(match[9]),
    max: Number(match[10]),
    iqr: Number(match[11]),
    mad: Number(match[12]),
    mean: Number(match[13]),
    stddev: Number(match[14]),
    cv: Number(match[15]),
    executable: match[16] === "N/A" ? "N/A" : Number(match[16]),
  }));
}

export async function checkFiles(jsonPath, markdownPath) {
  let report;
  let markdown;
  try {
    report = JSON.parse(await readFile(jsonPath, "utf8"));
  } catch (error) {
    throw new Error(`benchmark JSONを読み込めません: ${error.message}`);
  }
  try {
    markdown = await readFile(markdownPath, "utf8");
  } catch (error) {
    throw new Error(`benchmark Markdownを読み込めません: ${error.message}`);
  }
  validateBenchmarkReport(report);
  validateMarkdown(markdown, report);
  return report;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.dirname, "check_comparison_benchmark.mjs")) {
  try {
    const options = parseArguments(process.argv.slice(2));
    const report = await checkFiles(options.json, options.markdown);
    const measured = report.cases.reduce((count, item) => count + item.measurements.length, 0);
    console.log(`比較ベンチマーク結果を検証しました: ${report.cases.length} cases / ${measured} measurements`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
