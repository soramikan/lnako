import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const suite = await readJson(resolve(root, options.suite), "benchmark suite");
const report = await readJson(resolve(root, options.json), "benchmark JSON");
const markdown = await readFile(resolve(root, options.markdown), "utf8");

validateSuite(suite);
validateReport(report, suite, options.suite);
validateMarkdown(markdown, report);
console.log(`ベンチマーク結果を検証しました: ${report.cases.length}ケース・${report.cases.length * 3}測定行`);

function parseArguments(arguments_) {
  const options_ = {
    suite: "benchmarks/suite.json",
    json: "benchmarks/results/latest.json",
    markdown: "benchmarks/results/latest.md",
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--suite") options_.suite = nextValue(arguments_, ++index, argument);
    else if (argument === "--json") options_.json = nextValue(arguments_, ++index, argument);
    else if (argument === "--markdown") options_.markdown = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/check_benchmark_result.mjs [--suite path] [--json path] [--markdown path]`);
  }
  return options_;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new Error(`${label}をJSONとして読み込めません: ${error.message}`);
  }
}

function validateSuite(suite) {
  if (!suite || suite.schema_version !== 1 || typeof suite.name !== "string" || suite.name.length === 0 || !Array.isArray(suite.cases) || suite.cases.length === 0) {
    throw new Error("benchmark suiteのschemaが不正です");
  }
  const ids = new Set();
  for (const item of suite.cases) {
    if (!item || typeof item.id !== "string" || item.id.length === 0 || ids.has(item.id) || typeof item.source !== "string" || item.source.length === 0 || typeof item.expected_stdout !== "string") {
      throw new Error("benchmark suiteのcaseが不正です");
    }
    ids.add(item.id);
  }
}

function validateReport(report, suite, suitePath) {
  if (!report || report.schema_version !== 1 || report.project !== "lnako" || typeof report.version !== "string" ||
      !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(report.version) || !/^[0-9a-f]{40}$/.test(report.git_commit) ||
      !Number.isSafeInteger(report.generated_at_unix_ms) || report.generated_at_unix_ms < 0 ||
      !report.target || !new Set(["macos", "linux", "windows"]).has(report.target.os) || !new Set(["aarch64", "x86_64"]).has(report.target.arch) ||
      !report.toolchain || report.toolchain.zig !== "0.16.0" || report.toolchain.llvm !== "22.1.8" ||
      report.suite_name !== suite.name || report.suite !== suitePath || report.optimization !== "O2" ||
      !Number.isSafeInteger(report.iterations) || report.iterations < 1 || !Number.isSafeInteger(report.warmup) || report.warmup < 0 ||
      !Array.isArray(report.cases) || report.cases.length !== suite.cases.length) {
    throw new Error("benchmark JSONのmetadataが不正です");
  }

  const modes = ["interpreter", "aot_compile", "aot_run"];
  for (const [index, expected] of suite.cases.entries()) {
    const actual = report.cases[index];
    if (!actual || actual.id !== expected.id || actual.source !== expected.source || actual.expected_stdout !== expected.expected_stdout ||
        !Array.isArray(actual.measurements) || actual.measurements.length !== modes.length) {
      throw new Error(`benchmark JSONのcaseがsuiteと一致しません: ${expected.id}`);
    }
    const seenModes = new Set();
    for (const [measurementIndex, measurement] of actual.measurements.entries()) {
      if (!measurement || measurement.mode !== modes[measurementIndex] || seenModes.has(measurement.mode) || !Array.isArray(measurement.samples_ns) ||
          measurement.samples_ns.length !== report.iterations || !measurement.samples_ns.every(isNonNegativeSafeInteger) ||
          !isNonNegativeSafeInteger(measurement.min_ns) || !isNonNegativeSafeInteger(measurement.median_ns) || !isNonNegativeSafeInteger(measurement.max_ns)) {
        throw new Error(`benchmark JSONのmeasurementが不正です: ${expected.id}/${modes[measurementIndex]}`);
      }
      const samples = [...measurement.samples_ns];
      const sorted = [...samples].sort((left, right) => left - right);
      if (JSON.stringify(samples) !== JSON.stringify(sorted) || measurement.min_ns !== sorted[0] || measurement.max_ns !== sorted.at(-1) || measurement.median_ns !== median(sorted)) {
        throw new Error(`benchmark JSONのsummaryがsamplesと一致しません: ${expected.id}/${measurement.mode}`);
      }
      seenModes.add(measurement.mode);
    }
  }
}

function isNonNegativeSafeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function median(sorted) {
  const middle = sorted.length / 2;
  if (sorted.length % 2 !== 0) return sorted[Math.floor(middle)];
  const left = sorted[middle - 1];
  const right = sorted[middle];
  return Math.floor(left / 2) + Math.floor(right / 2) + (left % 2 + right % 2 >= 2 ? 1 : 0);
}

function validateMarkdown(markdown, report) {
  const requiredLines = [
    "# lnako benchmark",
    `- schema: \`${report.schema_version}\``,
    `- git_commit: \`${report.git_commit}\``,
    `- target: \`${report.target.os}/${report.target.arch}\``,
    `- toolchain: Zig \`${report.toolchain.zig}\`, LLVM/LLD \`${report.toolchain.llvm}\``,
    `- suite_name: \`${report.suite_name}\``,
    `- suite: \`${report.suite}\``,
    `- optimization: \`${report.optimization}\``,
    `- iterations: \`${report.iterations}\``,
    `- warmup: \`${report.warmup}\``,
    "| case | mode | samples | min (ns) | median (ns) | max (ns) |",
  ];
  for (const line of requiredLines) if (!markdown.includes(line)) throw new Error(`benchmark Markdownに必要な行がありません: ${line}`);

  const rows = [...markdown.matchAll(/^\| `([^`]+)` \| `([^`]+)` \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|$/gm)]
    .map((match) => ({ id: match[1], mode: match[2], samples: Number(match[3]), min: Number(match[4]), median: Number(match[5]), max: Number(match[6]) }));
  const expectedRows = report.cases.flatMap((item) => item.measurements.map((measurement) => ({
    id: item.id,
    mode: measurement.mode,
    samples: measurement.samples_ns.length,
    min: measurement.min_ns,
    median: measurement.median_ns,
    max: measurement.max_ns,
  })));
  if (rows.length !== expectedRows.length) throw new Error(`benchmark Markdownの測定行数が不一致です: ${rows.length}/${expectedRows.length}`);
  for (const [index, expected] of expectedRows.entries()) {
    if (JSON.stringify(rows[index]) !== JSON.stringify(expected)) throw new Error(`benchmark Markdownの測定行がJSONと一致しません: ${expected.id}/${expected.mode}`);
  }
}
