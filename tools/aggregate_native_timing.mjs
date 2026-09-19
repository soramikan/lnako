// 収集したfixture timing artifactを集約し、shard weight tableの入力を出す。
//
// 入力はCIがuploadした `lnako-native-timing-*` artifactを展開したディレクトリ。
// 出力はfixture × platform のmedian total cost（LPT再配分のweight）と、
// optimization別のbuild/run内訳である。
import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { TIMING_SCHEMA, buildTimingAggregate, validateTimingDocument } from "./native_oracle_timing.mjs";

// GitHub Actionsの複数artifactダウンロード（`gh run download -p 'lnako-native-timing-*'`）
// は、artifact名ごとのサブディレクトリへ展開する。直下と階層1の両方から.jsonを
// 集め、それより深い階層は契約違反として拒否する（黙って0件にしない）。
async function collectJsonPaths(directory) {
  const entries = [...await readdir(directory, { withFileTypes: true })].sort((left, right) => left.name.localeCompare(right.name));
  const paths = [];
  for (const entry of entries) {
    if (entry.isFile()) {
      if (entry.name.endsWith(".json")) paths.push({ label: entry.name, path: resolve(directory, entry.name) });
      continue;
    }
    if (!entry.isDirectory()) continue;
    const children = [...await readdir(resolve(directory, entry.name), { withFileTypes: true })].sort((left, right) => left.name.localeCompare(right.name));
    if (children.some((child) => child.isDirectory())) throw new Error(`timing artifactの展開階層が深すぎます: ${entry.name}`);
    for (const child of children) {
      if (child.isFile() && child.name.endsWith(".json")) paths.push({ label: `${entry.name}/${child.name}`, path: resolve(directory, entry.name, child.name) });
    }
  }
  return paths;
}

export async function loadTimingDocuments(directory) {
  const paths = await collectJsonPaths(directory);
  const documents = [];
  for (const { label, path } of paths) {
    let parsed;
    try {
      parsed = JSON.parse(await readFile(path, "utf8"));
    } catch (error) {
      throw new Error(`timing documentをJSONとして読めません: ${label}: ${error.message}`);
    }
    if (parsed?.schema !== TIMING_SCHEMA) throw new Error(`未知のtiming document schemaです: ${label}`);
    validateTimingDocument(parsed);
    documents.push(parsed);
  }
  return documents;
}

export function formatTimingAggregate(aggregate, { limit = 30 } = {}) {
  const lines = [
    "# AOT fixture timing aggregate",
    "",
    `入力document数: ${aggregate.documents}（集約対象: ${aggregate.aggregatedDocuments}、concurrency: ${aggregate.concurrency ?? "-"}）`,
    ...(aggregate.skippedByStatus.length === 0 ? [] : [`除外したstatus: ${aggregate.skippedByStatus.map((entry) => `${entry.status}×${entry.count}`).join(", ")}`]),
    "",
    "## fixture別 median total cost（LPT weight候補）",
    "",
    "| platform | fixture | observations | median total | median official | median interpreter |",
    "| --- | --- | ---: | ---: | ---: | ---: |",
    ...aggregate.fixtures.slice(0, limit).map((fixture) =>
      `| ${fixture.platform} | ${fixture.id} | ${fixture.observations} | ${formatMs(fixture.medianTotalMs)} | ${formatMs(fixture.medianOfficialMs)} | ${formatMs(fixture.medianInterpreterMs)} |`),
    "",
    "## platform × optimization 別 median build／run",
    "",
    "| platform | optimization | fixture | observations | median build | median run |",
    "| --- | --- | --- | ---: | ---: | ---: |",
    ...aggregate.optimizations.slice(0, limit).map((entry) =>
      `| ${entry.platform} | ${entry.optimization} | ${entry.id} | ${entry.observations} | ${formatMs(entry.medianBuildMs)} | ${formatMs(entry.medianRunMs)} |`),
    "",
    "medianは平均ではなく中央値であり、run間の外れ値に引きずられない。",
    "cold／warm cacheは混ぜない。concurrencyが混在する入力は集約前に拒否し、",
    "statusがsuccess以外のdocumentはweight集計から除外する。",
    "",
  ];
  return `${lines.join("\n")}\n`;
}

export function formatMs(value) {
  if (!Number.isFinite(value)) return "-";
  return value >= 1000 ? `${(value / 1000).toFixed(2)}s` : `${Math.round(value)}ms`;
}

function parseArguments(argumentsList) {
  const options = { directory: null, output: null, limit: 30 };
  const takeValue = (index, name) => {
    const value = argumentsList[index + 1];
    if (value === undefined) throw new Error(`${name}には値が必要です`);
    return value;
  };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--directory") options.directory = takeValue(index, "--directory"), index += 1;
    else if (argument === "--output") options.output = takeValue(index, "--output"), index += 1;
    else if (argument === "--limit") options.limit = Number(takeValue(index, "--limit")), index += 1;
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/aggregate_native_timing.mjs --directory <timing artifact展開先> [--output <markdown>] [--limit 30]`);
  }
  if (options.directory === null) throw new Error("--directoryにはtiming artifactを展開したディレクトリを指定してください");
  if (!Number.isSafeInteger(options.limit) || options.limit < 1) throw new Error("--limitには正の整数を指定してください");
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    const options = parseArguments(process.argv.slice(2));
    const documents = await loadTimingDocuments(options.directory);
    if (documents.length === 0) throw new Error(`timing documentがありません: ${options.directory}`);
    const aggregate = buildTimingAggregate(documents);
    if (aggregate.aggregatedDocuments === 0) {
      throw new Error(`集約対象のtiming documentがありません（status=successが0件。除外内訳: ${aggregate.skippedByStatus.map((entry) => `${entry.status}×${entry.count}`).join(", ") || "なし"}）`);
    }
    const markdown = formatTimingAggregate(aggregate, { limit: options.limit });
    if (options.output) {
      await writeFile(resolve(options.output), markdown, "utf8");
      console.log(`timing aggregateを${options.output}へ書き出しました: ${aggregate.aggregatedDocuments}/${documents.length} documents`);
    } else {
      process.stdout.write(markdown);
    }
  } catch (error) {
    console.error(`aggregate_native_timing.mjs failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
