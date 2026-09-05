import { access, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const result = await readJson(resolve(root, options.json), "benchmark JSON");
const suitePath = await selectSuitePath(options.suite, result);
const suite = await readJson(resolve(root, suitePath), "benchmark suite");
const suiteBytes = await readFile(resolve(root, suitePath));
const markdown = await readFile(resolve(root, options.markdown), "utf8");

const normalizedSuite = validateSuite(suite);
await validateReport(result, normalizedSuite, suitePath, suiteBytes);
validateMarkdown(markdown, result);
console.log(`ベンチマーク結果を検証しました: ${result.cases.length}ケース・${result.cases.reduce((total, item) => total + item.measurements.length, 0)}測定行`);

async function selectSuitePath(requested, result) {
  if (requested !== null) return requested;
  // Historical release artifacts are schema v1 and must continue to verify
  // even after v2 becomes the default for newly generated reports.
  if (result?.schema_version === 1) return "benchmarks/suite.json";
  const v2 = "benchmarks/suites/v2.json";
  try {
    await access(resolve(root, v2));
    return v2;
  } catch {
    return "benchmarks/suite.json";
  }
}

function parseArguments(arguments_) {
  const options_ = { suite: null, json: "benchmarks/results/latest.json", markdown: "benchmarks/results/latest.md" };
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
  if (!suite || !Number.isInteger(suite.schema_version) || !new Set([1, 2]).has(suite.schema_version) ||
      typeof suite.name !== "string" || suite.name.length === 0 || !Array.isArray(suite.cases) || suite.cases.length === 0) {
    throw new Error("benchmark suiteのschemaが不正です");
  }
  const ids = new Set();
  for (const item of suite.cases) {
    if (!item || typeof item.id !== "string" || item.id.length === 0 || ids.has(item.id)) {
      throw new Error("benchmark suiteのcase idが不正です");
    }
    ids.add(item.id);
    if (typeof item.source !== "string" || item.source.length === 0 || typeof item.expected_stdout !== "string") {
      throw new Error(`benchmark suiteのcaseが不正です: ${item.id}`);
    }
    if (suite.schema_version === 2) validateV2SuiteCase(item);
  }
  return suite;
}

function validateV2SuiteCase(item) {
  for (const field of ["category", "kind", "description"]) {
    if (typeof item[field] !== "string" || item[field].length === 0) throw new Error(`v2 suiteの${field}が不正です: ${item.id}`);
  }
  if (!["startup", "steady_state", "compile"].includes(item.measurement)) {
    throw new Error(`v2 suiteのmeasurementが不正です: ${item.id}`);
  }
  assertUniqueStringArray(item.profiles, `v2 suiteのprofiles: ${item.id}`);
  if (item.profiles.length === 0 || item.profiles.some((profile) => !["smoke", "normal", "full"].includes(profile))) {
    throw new Error(`v2 suiteのprofilesが不正です: ${item.id}`);
  }
  assertUniqueStringArray(item.tags, `v2 suiteのtags: ${item.id}`);
  if (item.sources !== undefined) {
    if (!item.sources || typeof item.sources !== "object" || Array.isArray(item.sources) ||
        Object.values(item.sources).some((source) => typeof source !== "string" || source.length === 0)) {
      throw new Error(`v2 suiteのsourcesが不正です: ${item.id}`);
    }
  }
  if (item.input !== undefined) {
    if (!item.input || typeof item.input !== "object" || Array.isArray(item.input)) throw new Error(`v2 suiteのinputが不正です: ${item.id}`);
    assertStringArray(item.input.args, `v2 suiteのinput.args: ${item.id}`);
  }
}

function assertStringArray(value, label) {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) throw new Error(`${label}が不正です`);
}

function assertUniqueStringArray(value, label) {
  assertStringArray(value, label);
  if (new Set(value).size !== value.length) throw new Error(`${label}に重複があります`);
}

async function validateReport(report, suite, suitePath, suiteBytes) {
  if (!report || !Number.isInteger(report.schema_version) || !new Set([1, 2]).has(report.schema_version) ||
      report.schema_version !== suite.schema_version || report.project !== "lnako" || typeof report.version !== "string" ||
      !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(report.version) || !/^[0-9a-f]{40}$/.test(report.git_commit) ||
      !Number.isSafeInteger(report.generated_at_unix_ms) || report.generated_at_unix_ms < 0 ||
      !report.target || !new Set(["macos", "linux", "windows"]).has(report.target.os) || !new Set(["aarch64", "x86_64"]).has(report.target.arch) ||
      !report.toolchain || report.toolchain.zig !== "0.16.0" || report.toolchain.llvm !== "22.1.8" ||
      report.suite_name !== suite.name || report.suite !== suitePath ||
      !isOptimization(report.optimization) || !Number.isSafeInteger(report.iterations) || report.iterations < 1 ||
      !Number.isSafeInteger(report.warmup) || report.warmup < 0 || !Array.isArray(report.cases) || report.cases.length === 0 || report.cases.length > suite.cases.length) {
    throw new Error("benchmark JSONのmetadataが不正です");
  }
  if (report.schema_version === 2) {
    if (!["smoke", "normal", "full"].includes(report.profile) || typeof report.source !== "string" || report.source !== suitePath ||
        typeof report.git_dirty !== "boolean" || !isSha256(report.suite_sha256) || report.suite_sha256 !== sha256(suiteBytes)) {
      throw new Error("benchmark JSONのv2 metadataが不正です");
    }
  }

  const expectedCases = [];
  const seenCaseIds = new Set();
  let previousSuiteIndex = -1;
  for (const actual of report.cases) {
    const suiteIndex = suite.cases.findIndex((candidate) => candidate.id === actual?.id);
    if (suiteIndex < 0 || suiteIndex <= previousSuiteIndex || seenCaseIds.has(actual.id)) {
      throw new Error(`benchmark JSONのcase順序またはidがsuiteと一致しません: ${actual?.id ?? "?"}`);
    }
    previousSuiteIndex = suiteIndex;
    seenCaseIds.add(actual.id);
    expectedCases.push(suite.cases[suiteIndex]);
  }
  for (const [index, expected] of expectedCases.entries()) {
    const actual = report.cases[index];
    if (!actual || actual.id !== expected.id || actual.source !== expected.source || actual.expected_stdout !== expected.expected_stdout ||
        !Array.isArray(actual.measurements)) {
      throw new Error(`benchmark JSONのcaseがsuiteと一致しません: ${expected.id}`);
    }
    if (report.schema_version === 2) {
      await validateV2CaseReport(actual, expected, report.iterations);
    } else {
      validateV1CaseReport(actual, expected, report.iterations);
    }
  }
}

async function validateV2CaseReport(actual, expected, iterations) {
  for (const field of ["category", "kind", "description", "measurement"]) {
    if (actual[field] !== expected[field]) throw new Error(`benchmark JSONのcase metadataがsuiteと一致しません: ${expected.id}/${field}`);
  }
  if (JSON.stringify(actual.profiles) !== JSON.stringify(expected.profiles) || JSON.stringify(actual.tags) !== JSON.stringify(expected.tags)) {
    throw new Error(`benchmark JSONのcase metadataがsuiteと一致しません: ${expected.id}/profiles-tags`);
  }
  if (!isSha256(actual.source_sha256)) throw new Error(`benchmark JSONのsource_sha256が不正です: ${expected.id}`);
  try {
    const sourceBytes = await readFile(resolve(root, expected.source));
    if (actual.source_sha256 !== sha256(sourceBytes)) throw new Error(`benchmark JSONのsource_sha256が一致しません: ${expected.id}`);
  } catch (error) {
    if (error.message.includes("source_sha256")) throw error;
    throw new Error(`benchmark JSONのsourceを読み込めません: ${expected.id}: ${error.message}`);
  }
  const expectedArgs = expected.input?.args ?? [];
  const actualArgs = actual.input?.args ?? actual.input_args;
  if (!Array.isArray(actualArgs) || JSON.stringify(actualArgs) !== JSON.stringify(expectedArgs)) {
    throw new Error(`benchmark JSONのinputがsuiteと一致しません: ${expected.id}`);
  }
  const modes = expected.measurement === "compile" ? ["aot_compile"] : ["interpreter", "aot_compile", "aot_run"];
  validateMeasurements(actual.measurements, modes, expected.id, expected.measurement, true, iterations);
}

function validateV1CaseReport(actual, expected, iterations) {
  if (!Array.isArray(actual.measurements) || actual.measurements.length !== 3) throw new Error(`benchmark JSONのcaseがsuiteと一致しません: ${expected.id}`);
  validateMeasurements(actual.measurements, ["interpreter", "aot_compile", "aot_run"], expected.id, "startup", false, iterations);
}

function validateMeasurements(measurements, modes, id, measurementKind, modern, iterations) {
  if (measurements.length !== modes.length) throw new Error(`benchmark JSONのmeasurement数が不正です: ${id}`);
  for (const [measurementIndex, measurement] of measurements.entries()) {
    const mode = modes[measurementIndex];
    if (!measurement || measurement.mode !== mode || !Array.isArray(measurement.samples_ns) ||
        measurement.samples_ns.length !== iterations ||
        !measurement.samples_ns.every(isNonNegativeSafeInteger)) {
      throw new Error(`benchmark JSONのmeasurementが不正です: ${id}/${mode}`);
    }
    const samples = measurement.samples_ns;
    const sorted = [...samples].sort((left, right) => left - right);
    const hasModernStats = modern || Object.hasOwn(measurement, "p25_ns");
    const expected = hasModernStats ? calculateStats(samples) : calculateLegacyStats(samples);
    for (const key of ["min_ns", "median_ns", "max_ns"]) {
      if (measurement[key] !== expected[key]) throw new Error(`benchmark JSONのsummaryがsamplesと一致しません: ${id}/${mode}/${key}`);
    }
    if (hasModernStats) validateModernStats(measurement, expected, id, mode);
    if (mode === "aot_compile" && measurement.binary_size_samples_bytes !== undefined && measurement.binary_size_samples_bytes !== null) {
      if (!Array.isArray(measurement.binary_size_samples_bytes) || !measurement.binary_size_samples_bytes.every(isNonNegativeSafeInteger) ||
          measurement.binary_size_samples_bytes.length !== samples.length ||
          measurement.binary_size_bytes !== medianModern(measurement.binary_size_samples_bytes)) {
        throw new Error(`benchmark JSONのbinary size summaryが不正です: ${id}/${mode}`);
      }
    }
    if (modern) {
      if (measurementKind === "compile" && mode !== "aot_compile") throw new Error(`compile caseのmodeが不正です: ${id}`);
      if (!Array.isArray(measurement.warnings) || measurement.warnings.some((warning) => typeof warning !== "string")) {
        throw new Error(`benchmark JSONのwarningsが不正です: ${id}/${mode}`);
      }
      if (measurement.warnings.includes("short_duration_lt_200ms") && measurement.median_ns >= 200_000_000) {
        throw new Error(`短時間warningの条件が不正です: ${id}/${mode}`);
      }
    }
  }
}

function validateModernStats(actual, expected, id, mode) {
  for (const key of ["p25_ns", "median_ns", "p75_ns", "iqr_ns", "mad_ns"]) {
    if (!isNonNegativeSafeInteger(actual[key]) || actual[key] !== expected[key]) throw new Error(`benchmark JSONのsummaryが不正です: ${id}/${mode}/${key}`);
  }
  for (const key of ["mean_ns", "stddev_ns", "cv"]) {
    if (!Number.isFinite(actual[key]) || !nearlyEqual(actual[key], expected[key])) throw new Error(`benchmark JSONのsummaryが不正です: ${id}/${mode}/${key}`);
  }
}

function calculateStats(samples) {
  const sorted = [...samples].sort((left, right) => left - right);
  const median_ns = medianModern(sorted);
  const p25_ns = quantileModern(sorted, 1, 4);
  const p75_ns = quantileModern(sorted, 3, 4);
  const mean_ns = samples.reduce((total, sample) => total + sample, 0) / samples.length;
  const variance = samples.reduce((total, sample) => total + (sample - mean_ns) ** 2, 0) / samples.length;
  const deviations = samples.map((sample) => Math.abs(sample - median_ns)).sort((left, right) => left - right);
  return {
    min_ns: sorted[0], p25_ns, median_ns, p75_ns, max_ns: sorted.at(-1), iqr_ns: p75_ns - p25_ns,
    mad_ns: medianModern(deviations), mean_ns, stddev_ns: Math.sqrt(variance), cv: mean_ns === 0 ? 0 : Math.sqrt(variance) / mean_ns,
  };
}

function calculateLegacyStats(samples) {
  const sorted = [...samples].sort((left, right) => left - right);
  return { min_ns: sorted[0], median_ns: medianLegacy(sorted), max_ns: sorted.at(-1) };
}

function quantileModern(sorted, numerator, denominator) {
  if (sorted.length === 1 || numerator === 0) return sorted[0];
  if (numerator === denominator) return sorted.at(-1);
  const scaled = (sorted.length - 1) * numerator;
  const lower = Math.floor(scaled / denominator);
  const remainder = scaled % denominator;
  if (remainder === 0 || lower + 1 >= sorted.length) return sorted[lower];
  return sorted[lower] + Math.floor(((sorted[lower + 1] - sorted[lower]) * remainder) / denominator + 0.5);
}

function medianModern(sorted) {
  return quantileModern(sorted, 1, 2);
}

function medianLegacy(sorted) {
  const middle = sorted.length / 2;
  if (sorted.length % 2 !== 0) return sorted[Math.floor(middle)];
  return Math.floor((sorted[middle - 1] + sorted[middle]) / 2);
}

function nearlyEqual(left, right) {
  const scale = Math.max(1, Math.abs(left), Math.abs(right));
  return Math.abs(left - right) <= scale * 1e-9;
}

function isOptimization(value) {
  return ["O0", "O1", "O2", "O3"].includes(value);
}

function isSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function isNonNegativeSafeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function validateMarkdown(markdown, report) {
  const requiredLines = [
    "# lnako benchmark",
    `- schema: \`${report.schema_version}\``,
    `- git_commit: \`${report.git_commit}\``,
    ...(report.schema_version === 2 ? [`- git_dirty: \`${report.git_dirty}\``] : []),
    `- target: \`${report.target.os}/${report.target.arch}\``,
    `- toolchain: Zig \`${report.toolchain.zig}\`, LLVM/LLD \`${report.toolchain.llvm}\``,
    `- suite_name: \`${report.suite_name}\``,
    `- suite: \`${report.suite}\``,
    ...(report.schema_version === 2 ? [`- suite_sha256: \`${report.suite_sha256}\``] : []),
    `- optimization: \`${report.optimization}\``,
    `- iterations: \`${report.iterations}\``,
    `- warmup: \`${report.warmup}\``,
  ];
  if (report.schema_version === 2) requiredLines.splice(7, 0, `- profile: \`${report.profile}\``);
  for (const line of requiredLines) if (!markdown.includes(line)) throw new Error(`benchmark Markdownに必要な行がありません: ${line}`);
  if (report.schema_version === 1) validateLegacyMarkdown(markdown, report);
  else validateV2Markdown(markdown, report);
}

function validateLegacyMarkdown(markdown, report) {
  const rows = [...markdown.matchAll(/^\| `([^`]+)` \| `([^`]+)` \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|$/gm)]
    .map((match) => ({ id: match[1], mode: match[2], samples: Number(match[3]), min: Number(match[4]), median: Number(match[5]), max: Number(match[6]) }));
  const expectedRows = report.cases.flatMap((item) => item.measurements.map((measurement) => ({
    id: item.id, mode: measurement.mode, samples: measurement.samples_ns.length, min: measurement.min_ns, median: measurement.median_ns, max: measurement.max_ns,
  })));
  if (rows.length !== expectedRows.length) throw new Error(`benchmark Markdownの測定行数が不一致です: ${rows.length}/${expectedRows.length}`);
  for (const [index, expected] of expectedRows.entries()) if (JSON.stringify(rows[index]) !== JSON.stringify(expected)) throw new Error(`benchmark Markdownの測定行がJSONと一致しません: ${expected.id}/${expected.mode}`);
}

function validateV2Markdown(markdown, report) {
  const rows = [...markdown.matchAll(/^\| `([^`]+)` \| `([^`]+)` \| `([^`]+)` \| `([^`]+)` \| (\d+) \| ([0-9]+) \| ([0-9]+) \| ([0-9]+) \| ([0-9]+) \| ([0-9]+) \| ([0-9]+) \| ([0-9]+) \| ([0-9.eE+-]+) \| ([0-9.eE+-]+) \| ([0-9.eE+-]+) \| ([0-9]+|-) \|$/gm)]
    .map((match) => ({ category: match[1], id: match[2], measurement: match[3], mode: match[4], samples: Number(match[5]), min: Number(match[6]), p25: Number(match[7]), median: Number(match[8]), p75: Number(match[9]), max: Number(match[10]), iqr: Number(match[11]), mad: Number(match[12]), mean: Number(match[13]), stddev: Number(match[14]), cv: Number(match[15]), binarySize: match[16] === "-" ? null : Number(match[16]) }));
  const expectedRows = report.cases.flatMap((item) => item.measurements.map((measurement) => ({
    category: item.category, id: item.id, measurement: item.measurement, mode: measurement.mode, samples: measurement.samples_ns.length,
    min: measurement.min_ns, p25: measurement.p25_ns, median: measurement.median_ns, p75: measurement.p75_ns, max: measurement.max_ns,
    iqr: measurement.iqr_ns, mad: measurement.mad_ns, mean: measurement.mean_ns, stddev: measurement.stddev_ns, cv: measurement.cv,
    binarySize: measurement.binary_size_bytes ?? null,
  })));
  if (rows.length !== expectedRows.length) throw new Error(`benchmark Markdownの測定行数が不一致です: ${rows.length}/${expectedRows.length}`);
  for (const [index, expected] of expectedRows.entries()) {
    const actual = rows[index];
    for (const key of ["category", "id", "measurement", "mode", "samples", "min", "p25", "median", "p75", "max", "iqr", "mad", "binarySize"]) {
      if (actual[key] !== expected[key]) throw new Error(`benchmark Markdownの測定行がJSONと一致しません: ${expected.id}/${expected.mode}/${key}`);
    }
    for (const key of ["mean", "stddev", "cv"]) if (!nearlyEqual(actual[key], expected[key])) throw new Error(`benchmark Markdownの測定行がJSONと一致しません: ${expected.id}/${expected.mode}/${key}`);
  }
}
