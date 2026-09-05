import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";

import {
  EXECUTION_MEASUREMENTS,
  PROFILE_NAMES,
  summarizeSamples,
} from "./benchmark_statistics.mjs";
import {
  CROSS_LANGUAGE_RUNTIMES,
  NADESIKO_RUNTIMES,
  RUNTIME_NAMES,
  runtimeComparisonGroup,
} from "./benchmark_suite.mjs";

const SHA256_PATTERN = /^[0-9a-f]{64}$/;

export function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function sha256File(path) {
  return sha256Bytes(readFileSync(path));
}

export function executableSizeBytes(path) {
  try {
    const size = statSync(path).size;
    return Number.isSafeInteger(size) && size >= 0 ? size : null;
  } catch {
    return null;
  }
}

export function compareBaseline(currentReport, baselineReport, { threshold = 0.1 } = {}) {
  if (!Number.isFinite(threshold) || threshold < 0) throw new Error(`baseline thresholdが不正です: ${threshold}`);
  const incompatibilities = baselineCompatibilityDifferences(currentReport, baselineReport);
  if (incompatibilities.length > 0) {
    return [{
      reason: "baseline_incompatible",
      differences: incompatibilities,
      warning_only: true,
    }];
  }
  const baseline = new Map();
  for (const item of baselineReport?.cases ?? []) {
    for (const measurement of item.measurements ?? []) {
      baseline.set(measurementKey(item, measurement), measurement);
    }
  }
  const warnings = [];
  for (const item of currentReport?.cases ?? []) {
    for (const measurement of item.measurements ?? []) {
      const previous = baseline.get(measurementKey(item, measurement));
      if (!previous || !Number.isFinite(previous.median_ns) || previous.median_ns <= 0 || !Number.isFinite(measurement.median_ns)) continue;
      const ratio = measurement.median_ns / previous.median_ns;
      if (ratio > 1 + threshold) {
        warnings.push({
          case: item.id,
          runtime: measurement.runtime,
          measurement: measurement.measurement ?? measurement.mode,
          mode: measurement.mode,
          baseline_median_ns: previous.median_ns,
          median_ns: measurement.median_ns,
          regression_ratio: ratio,
          threshold,
          reason: "median_regression",
        });
      }
    }
  }
  return warnings;
}

function baselineCompatibilityDifferences(current, baseline) {
  if (!isPlainObject(baseline)) return ["baseline is not an object"];
  const differences = [];
  if (current.target?.os !== baseline.target?.os || current.target?.arch !== baseline.target?.arch) differences.push("target");
  if ((current.git_dirty ?? null) !== (baseline.git_dirty ?? null)) differences.push("git_dirty");
  if (JSON.stringify(current.hardware ?? null) !== JSON.stringify(baseline.hardware ?? null)) differences.push("hardware");
  if (current.suite_name !== baseline.suite_name || current.suite !== baseline.suite) differences.push("suite");
  if (current.suite_sha256 !== baseline.suite_sha256) differences.push("suite_sha256");
  if ((current.optimization ?? null) !== (baseline.optimization ?? null)) differences.push("optimization");
  if ((current.profile ?? null) !== (baseline.profile ?? null)) differences.push("profile");
  if (JSON.stringify(current.toolchain ?? null) !== JSON.stringify(baseline.toolchain ?? null)) differences.push("toolchain");
  if (runtimeVersions(current) !== runtimeVersions(baseline)) differences.push("runtime_versions");
  if (JSON.stringify(current.runtimes?.gonako?.provenance ?? null) !== JSON.stringify(baseline.runtimes?.gonako?.provenance ?? null)) differences.push("gonako_provenance");
  const baselineCases = new Map((baseline.cases ?? []).map((item) => [item.id, item]));
  for (const item of current.cases ?? []) {
    const previous = baselineCases.get(item.id);
    if (!previous) {
      differences.push(`case:${item.id}:missing`);
      continue;
    }
    if (JSON.stringify(item.input ?? null) !== JSON.stringify(previous.input ?? null)) differences.push(`case:${item.id}:input`);
    if (JSON.stringify(item.source_hashes ?? null) !== JSON.stringify(previous.source_hashes ?? null)) differences.push(`case:${item.id}:source_hashes`);
  }
  return differences;
}

function runtimeVersions(report) {
  return JSON.stringify(Object.fromEntries(Object.entries(report.runtimes ?? {}).map(([runtime, record]) => [runtime, record?.version ?? null])));
}

function measurementKey(item, measurement) {
  return [item.id, measurement.runtime, measurement.measurement ?? "", measurement.mode ?? ""].join("\u0000");
}

/**
 * Validate a comparison result independently of the command line checker.
 * Schema v1 deliberately has a small compatibility allowance; schema v2 is
 * strict about the metadata needed to interpret a comparison result.
 */
export function validateBenchmarkReport(report, { allowFailed = false } = {}) {
  if (!isPlainObject(report)) throw new Error("benchmark JSONはobjectである必要があります");
  if (report.schema_version !== 1 && report.schema_version !== 2) throw new Error(`未対応のschema_versionです: ${report.schema_version}`);
  if (report.project !== "lnako" || typeof report.version !== "string" || report.version.length === 0 || typeof report.git_commit !== "string") {
    throw new Error("メタ情報が不足しています");
  }
  if (!isPlainObject(report.target) || typeof report.target.os !== "string" || typeof report.target.arch !== "string") {
    throw new Error("target情報が不足しています");
  }
  if (!isPlainObject(report.toolchain)) throw new Error("toolchain情報が不足しています");
  if (!Number.isSafeInteger(report.generated_at_unix_ms) || report.generated_at_unix_ms < 0) throw new Error("generated_at_unix_msが不正です");
  if (typeof report.suite_name !== "string" || report.suite_name.length === 0 || typeof report.suite !== "string" || report.suite.length === 0) {
    throw new Error("suite情報が不足しています");
  }
  if (!Object.hasOwn(report, "score") && !Object.hasOwn(report, "global_score")) {
    // A deliberately empty branch documents that benchmark reports do not
    // produce a cross-category score. The property checks below reject one.
  } else {
    throw new Error("benchmark reportにglobal scoreを追加できません");
  }
  if (!Array.isArray(report.cases) || report.cases.length === 0) throw new Error("casesが空です");
  if (report.schema_version === 1) validateV1Report(report);
  else validateV2Report(report, { allowFailed });
  return report;
}

function validateV1Report(report) {
  if (!isFinitePositiveInteger(report.iterations) || !isNonNegativeInteger(report.warmup)) throw new Error("v1のiterations/warmupが不正です");
  for (const item of report.cases) {
    if (!isPlainObject(item) || typeof item.id !== "string" || item.id.length === 0 || typeof item.expected_stdout !== "string") {
      throw new Error(`case ${item?.id ?? "?"} の基本情報が不足しています`);
    }
    if (!Array.isArray(item.measurements) || item.measurements.length === 0) throw new Error(`case ${item.id} に計測値がありません`);
    validateMeasurements(item, report, false);
  }
}

function validateV2Report(report, { allowFailed }) {
  if (!/^[0-9a-f]{40}$/.test(report.git_commit)) throw new Error("v2のgit_commitが不正です");
  if (typeof report.git_dirty !== "boolean") throw new Error("v2のgit_dirtyが不正です");
  validateHardware(report.hardware);
  if (typeof report.suite_sha256 !== "string" || !SHA256_PATTERN.test(report.suite_sha256)) throw new Error("v2のsuite_sha256が不正です");
  if (!PROFILE_NAMES.includes(report.profile)) throw new Error(`v2のprofileが不正です: ${report.profile}`);
  if (!isFinitePositiveInteger(report.iterations) || !isNonNegativeInteger(report.warmup)) throw new Error("v2のiterations/warmupが不正です");
  if (!Object.hasOwn(report, "optimization") || !/^O[0-3]$/.test(report.optimization)) throw new Error("v2のoptimizationが不正です");
  if (!isFinitePositiveInteger(report.timeout_ms)) throw new Error("v2のtimeout_msが不正です");
  if (report.status !== "success" && !(allowFailed && report.status === "failed")) throw new Error(`v2のstatusが不正です: ${report.status}`);
  if (!Array.isArray(report.failures) || (report.status === "success" && report.failures.length !== 0) || (report.status === "failed" && report.failures.length === 0)) throw new Error("v2のfailuresが不正です");
  if (!Array.isArray(report.warnings)) throw new Error("v2のwarningsが不正です");
  if (!Array.isArray(report.selected_runtimes) || report.selected_runtimes.some((runtime) => !RUNTIME_NAMES.includes(runtime)) || new Set(report.selected_runtimes).size !== report.selected_runtimes.length || typeof report.runtime_selection_explicit !== "boolean") {
    throw new Error("v2のruntime selectionが不正です");
  }
  if (!isPlainObject(report.runtimes)) throw new Error("v2のruntimesが不足しています");
  for (const runtime of RUNTIME_NAMES) {
    const record = report.runtimes[runtime];
    if (!isPlainObject(record) || typeof record.available !== "boolean" || typeof record.selected !== "boolean" || typeof record.group !== "string") {
      throw new Error(`v2のruntime metadataが不正です: ${runtime}`);
    }
    if (record.provenance !== undefined) {
      const provenance = record.provenance;
      if (!isPlainObject(provenance) || !SHA256_PATTERN.test(provenance.sha256) || (provenance.release !== null && typeof provenance.release !== "string") || (provenance.url !== null && typeof provenance.url !== "string")) {
        throw new Error(`v2のruntime provenanceが不正です: ${runtime}`);
      }
    }
    if (record.group !== runtimeComparisonGroup(runtime)) throw new Error(`v2のruntime groupが不正です: ${runtime}`);
    if (record.selected !== report.selected_runtimes.includes(runtime)) throw new Error(`v2のruntime selectionが不一致です: ${runtime}`);
  }
  if (!isPlainObject(report.comparison_groups) || !sameRuntimeSet(report.comparison_groups["nadesiko-implementation"], NADESIKO_RUNTIMES) || !sameRuntimeSet(report.comparison_groups["cross-language-reference"], CROSS_LANGUAGE_RUNTIMES)) {
    throw new Error("v2のcomparison_groupsが不正です");
  }
  const ids = new Set();
  for (const item of report.cases) {
    validateV2Case(item, report, ids);
  }
}

function validateV2Case(item, report, ids) {
  if (!isPlainObject(item) || typeof item.id !== "string" || item.id.length === 0 || ids.has(item.id)) throw new Error(`v2 case idが不正です: ${item?.id ?? "?"}`);
  ids.add(item.id);
  if (typeof item.source !== "string" || item.source.length === 0 || !isPlainObject(item.sources)) throw new Error(`v2 case ${item.id}.source/sourcesが不正です`);
  for (const key of ["category", "kind", "description"]) if (typeof item[key] !== "string" || item[key].length === 0) throw new Error(`v2 case ${item.id}.${key}が不正です`);
  if (!EXECUTION_MEASUREMENTS.includes(item.measurement)) throw new Error(`v2 case ${item.id}.measurementが不正です`);
  if (!Array.isArray(item.profiles) || item.profiles.some((profile) => !PROFILE_NAMES.includes(profile))) throw new Error(`v2 case ${item.id}.profilesが不正です`);
  if (!Array.isArray(item.tags) || item.tags.some((tag) => typeof tag !== "string")) throw new Error(`v2 case ${item.id}.tagsが不正です`);
  if (typeof item.expected_stdout !== "string") throw new Error(`v2 case ${item.id}.expected_stdoutが不正です`);
  if (!isPlainObject(item.source_hashes)) throw new Error(`v2 case ${item.id}.source_hashesが不足しています`);
  for (const [runtime, hash] of Object.entries(item.source_hashes)) {
    if (!RUNTIME_NAMES.includes(runtime) || !SHA256_PATTERN.test(hash)) throw new Error(`v2 case ${item.id}.source_hashesが不正です`);
  }
  if (!isPlainObject(item.runtime_status)) throw new Error(`v2 case ${item.id}.runtime_statusが不足しています`);
  for (const runtime of RUNTIME_NAMES) validateRuntimeStatus(item.runtime_status[runtime], item.id, runtime);
  if (!Array.isArray(item.measurements)) throw new Error(`v2 case ${item.id}.measurementsが不正です`);
  validateMeasurements(item, report, true);
  const measuredRuntimes = new Set(item.measurements.map((measurement) => measurement.runtime));
  for (const runtime of RUNTIME_NAMES) {
    const status = item.runtime_status[runtime];
    if (status.status === "measured" && !measuredRuntimes.has(runtime)) throw new Error(`v2 case ${item.id}/${runtime}のstatusとmeasurementが不一致です`);
    if (status.status !== "measured" && measuredRuntimes.has(runtime)) throw new Error(`v2 case ${item.id}/${runtime}のskip statusとmeasurementが不一致です`);
  }
}

function validateRuntimeStatus(status, caseId, runtime) {
  if (!isPlainObject(status) || typeof status.selected !== "boolean" || typeof status.available !== "boolean" || typeof status.status !== "string" || typeof status.group !== "string") {
    throw new Error(`v2 case ${caseId}/${runtime}のruntime_statusが不正です`);
  }
  if (status.group !== runtimeComparisonGroup(runtime)) throw new Error(`v2 case ${caseId}/${runtime}のruntime groupが不正です`);
  if (!["measured", "skipped", "failed"].includes(status.status)) throw new Error(`v2 case ${caseId}/${runtime}のstatusが不正です`);
  if (status.status === "measured" && (!status.selected || !status.available)) throw new Error(`v2 case ${caseId}/${runtime}のmeasured statusが不正です`);
  // An explicitly selected runtime that is unavailable is a hard benchmark
  // failure, so its status is allowed to be failed while available=false.
  if (status.status === "failed" && !status.selected) throw new Error(`v2 case ${caseId}/${runtime}のfailed statusが不正です`);
  if (status.status === "skipped" && (typeof status.reason !== "string" || status.reason.length === 0)) throw new Error(`v2 case ${caseId}/${runtime}のskip reasonが不足しています`);
  if (status.status === "failed" && (typeof status.reason !== "string" || status.reason.length === 0)) throw new Error(`v2 case ${caseId}/${runtime}のfailure reasonが不足しています`);
}

function validateMeasurements(item, report, strictV2) {
  const seen = new Set();
  for (const measurement of item.measurements) {
    if (!isPlainObject(measurement) || !RUNTIME_NAMES.includes(measurement.runtime) || typeof measurement.mode !== "string" || measurement.mode.length === 0) {
      throw new Error(`case ${item.id}のmeasurementにruntime/modeがありません`);
    }
    const key = `${measurement.runtime}\u0000${measurement.mode}`;
    if (seen.has(key)) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}が重複しています`);
    seen.add(key);
    if (!Array.isArray(measurement.samples_ns) || measurement.samples_ns.length === 0 || measurement.samples_ns.some((sample) => !Number.isSafeInteger(sample) || sample < 0)) {
      throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のsamples_nsが不正です`);
    }
    if (strictV2) {
      if (!EXECUTION_MEASUREMENTS.includes(measurement.measurement)) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のmeasurementが不正です`);
      if (measurement.group !== runtimeComparisonGroup(measurement.runtime)) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のgroupが不正です`);
      if (measurement.samples_ns.length !== report.iterations) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のsamples数が不一致です`);
      if (measurement.correctness_checked !== true) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のcorrectness_checkedが不正です`);
      if (measurement.measurement === "steady_state" && measurement.timing_scope !== "process_batched_wall") throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のsteady_state timing_scopeが不正です`);
    }
    const expected = summarizeSamples(measurement.samples_ns);
    for (const keyName of ["min_ns", "median_ns", "max_ns"]) {
      if (!sameNumber(measurement[keyName], expected[keyName])) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}の${keyName}がsamplesと一致しません`);
    }
    if (strictV2) {
      for (const keyName of ["p25_ns", "p75_ns", "iqr_ns", "mad_ns", "mean_ns", "stddev_ns", "cv"]) {
        if (!sameNumber(measurement[keyName], expected[keyName])) throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}の${keyName}がsamplesと一致しません`);
      }
    }
    if (measurement.executable_size_bytes !== undefined && measurement.executable_size_bytes !== null && !isNonNegativeInteger(measurement.executable_size_bytes)) {
      throw new Error(`case ${item.id}/${measurement.runtime}/${measurement.mode}のexecutable_size_bytesが不正です`);
    }
  }
}

function sameNumber(left, right) {
  return typeof left === "number" && Number.isFinite(left) && Object.is(left, right);
}

function sameRuntimeSet(actual, expected) {
  return Array.isArray(actual) && actual.length === expected.length && expected.every((runtime) => actual.includes(runtime));
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isFinitePositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function isNonNegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function validateHardware(hardware) {
  if (!isPlainObject(hardware) || (hardware.cpu_model !== null && typeof hardware.cpu_model !== "string") || !isFinitePositiveInteger(hardware.cpu_logical_count) || !isFinitePositiveInteger(hardware.total_memory_bytes) || typeof hardware.os_release !== "string" || hardware.os_release.length === 0) {
    throw new Error("v2のhardware情報が不正です");
  }
}

export function renderBenchmarkMarkdown(report) {
  const lines = [
    "# lnako comparison benchmark",
    "",
    `- schema: \`${report.schema_version}\``,
    `- suite: \`${report.suite_name}\``,
    `- suite path: \`${report.suite}\``,
    `- git_commit: \`${report.git_commit}\``,
    `- target: \`${report.target.os}/${report.target.arch}\``,
    ...(report.schema_version === 2 ? [
      `- git_dirty: \`${report.git_dirty}\``,
      `- hardware.cpu_model: \`${escapeMarkdownCell(report.hardware.cpu_model ?? "N/A")}\``,
      `- hardware.cpu_logical_count: \`${report.hardware.cpu_logical_count}\``,
      `- hardware.total_memory_bytes: \`${report.hardware.total_memory_bytes}\``,
      `- hardware.os_release: \`${escapeMarkdownCell(report.hardware.os_release)}\``,
    ] : []),
    `- generated_at_unix_ms: \`${report.generated_at_unix_ms}\``,
    `- profile: \`${report.profile ?? "legacy"}\``,
    `- iterations: \`${report.iterations}\``,
    `- warmup: \`${report.warmup}\``,
    `- optimization: \`${report.optimization ?? "O2"}\``,
    "",
    "## Toolchain versions",
    "",
    "| tool | version |",
    "|---|---|",
  ];
  for (const [name, version] of Object.entries(report.toolchain)) lines.push(`| ${name} | \`${escapeMarkdownCell(version ?? "N/A")}\` |`);
  lines.push("");
  if (report.schema_version === 2) {
    lines.push("正式比較: cnako・gonako・lnako。C・Rust・Pythonは参考値で、未選択・未対応のケースは数値を記録しません。", "");
    if (report.runtimes?.gonako?.provenance) lines.push(`gonako distribution: ${escapeMarkdownCell(JSON.stringify(report.runtimes.gonako.provenance))}`, "");
    lines.push("## Comparison groups", "", "| group | runtimes |", "|---|---|", `| nadesiko-implementation | ${report.comparison_groups["nadesiko-implementation"].join(", ")} |`, `| cross-language-reference | ${report.comparison_groups["cross-language-reference"].join(", ")} |`, "");
  }
  if (report.warnings?.length > 0) {
    lines.push("## Warnings", "");
    for (const warning of report.warnings) lines.push(`- ${escapeMarkdownCell(typeof warning === "string" ? warning : JSON.stringify(warning))}`);
    lines.push("");
  }
  for (const item of report.cases) {
    lines.push(`## ${item.id}`, "", `category: \`${escapeMarkdownCell(item.category ?? "legacy")}\``, `kind: \`${escapeMarkdownCell(item.kind ?? "legacy")}\``, `measurement: \`${item.measurement ?? "legacy"}\``, `expected stdout: \`${escapeMarkdownCell(JSON.stringify(item.expected_stdout))}\``, "");
    if (report.schema_version === 1) {
      lines.push("| runtime | mode | samples | min (ns) | median (ns) | max (ns) |", "|---|---|---:|---:|---:|---:|");
      for (const measurement of item.measurements) lines.push(`| ${measurement.runtime} | ${measurement.mode} | ${measurement.samples_ns.length} | ${measurement.min_ns} | ${measurement.median_ns} | ${measurement.max_ns} |`);
    } else {
      lines.push("| runtime | group | measurement | mode | samples | min (ns) | p25 (ns) | median (ns) | p75 (ns) | max (ns) | IQR (ns) | MAD (ns) | mean (ns) | stddev (ns) | CV | executable bytes |", "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
      for (const measurement of item.measurements) {
        lines.push(`| ${measurement.runtime} | ${measurement.group} | ${measurement.measurement} | ${measurement.mode} | ${measurement.samples_ns.length} | ${measurement.min_ns} | ${measurement.p25_ns} | ${measurement.median_ns} | ${measurement.p75_ns} | ${measurement.max_ns} | ${measurement.iqr_ns} | ${measurement.mad_ns} | ${measurement.mean_ns} | ${measurement.stddev_ns} | ${measurement.cv} | ${measurement.executable_size_bytes ?? "N/A"} |`);
      }
      if (item.runtime_support) {
        for (const [runtime, support] of Object.entries(item.runtime_support)) {
          if (support.reason) lines.push("", `${runtime} source/support: ${escapeMarkdownCell(support.reason)}`);
        }
      }
      if (item.runtime_status) {
        lines.push("", "Runtime status:", "");
        for (const [runtime, status] of Object.entries(item.runtime_status)) {
          lines.push(`- ${runtime}: ${status.status}${status.reason ? ` (${escapeMarkdownCell(status.reason)})` : ""}`);
        }
      }
    }
    lines.push("");
  }
  return lines.join("\n");
}

function escapeMarkdownCell(value) {
  return String(value).replaceAll("|", "\\|").replaceAll("\n", "\\n");
}
