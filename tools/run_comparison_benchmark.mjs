import { spawnSync } from "node:child_process";
import {
  accessSync,
  constants,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { delimiter, dirname, isAbsolute, join, resolve } from "node:path";
import { arch as hostArch, cpus, platform, release as osRelease, tmpdir, totalmem } from "node:os";
import { X_OK } from "node:constants";
import { fileURLToPath } from "node:url";

import {
  PROFILE_NAMES,
  parseNonNegativeInteger,
  parsePositiveInteger,
  resolveProfileOptions,
  outputsMatch,
  summarizeSamples,
} from "./lib/benchmark_statistics.mjs";
import {
  CROSS_LANGUAGE_RUNTIMES,
  NADESIKO_RUNTIMES,
  RUNTIME_NAMES,
  loadBenchmarkSuite,
  resolveCaseInvocation,
  runtimeComparisonGroup,
  selectBenchmarkCases,
  sourceForRuntime,
} from "./lib/benchmark_suite.mjs";
import {
  BenchmarkProcessError,
  assertSuccessfulProcess,
  runMeasuredSamples,
  runProcess,
} from "./lib/benchmark_process.mjs";
import {
  compareBaseline,
  executableSizeBytes,
  renderBenchmarkMarkdown,
  sha256File,
  validateBenchmarkReport,
} from "./lib/benchmark_report.mjs";

export const root = resolve(import.meta.dirname, "..");
export const DEFAULT_SUITE = "benchmarks/suites/v2.json";
export const LEGACY_SUITE = "benchmarks/comparison/suite.json";
export const DEFAULT_TIMEOUT_MS = 120_000;

const isWindows = platform() === "win32";
const isDarwin = platform() === "darwin";
const executableSuffix = isWindows ? ".exe" : "";

export function parseArguments(arguments_) {
  const parsed = {
    suite: DEFAULT_SUITE,
    output: "benchmarks/comparison/results/latest.json",
    markdown: "benchmarks/comparison/results/latest.md",
    profile: "normal",
    runtimes: null,
    runtimesExplicit: false,
    cases: null,
    optimization: "O2",
    timeoutMs: DEFAULT_TIMEOUT_MS,
    baseline: null,
    baselineThreshold: 0.1,
    iterations: undefined,
    warmup: undefined,
    lnako: "lnako",
    python: "python3",
    clang: "clang",
    cnako: "cnako3",
    gonako: "gonako",
    rustc: "rustc",
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--suite") parsed.suite = nextValue(arguments_, ++index, argument);
    else if (argument === "--output") parsed.output = nextValue(arguments_, ++index, argument);
    else if (argument === "--markdown") parsed.markdown = nextValue(arguments_, ++index, argument);
    else if (argument === "--profile") parsed.profile = nextValue(arguments_, ++index, argument);
    else if (argument === "--runtimes") {
      parsed.runtimes = parseList(nextValue(arguments_, ++index, argument), RUNTIME_NAMES, argument);
      parsed.runtimesExplicit = true;
    }
    else if (argument === "--case") parsed.cases = appendList(parsed.cases, nextValue(arguments_, ++index, argument));
    else if (argument === "--optimization") parsed.optimization = parseOptimization(nextValue(arguments_, ++index, argument));
    else if (argument === "--timeout" || argument === "--timeout-ms") parsed.timeoutMs = parsePositiveInteger(nextValue(arguments_, ++index, argument), "timeout");
    else if (argument === "--baseline") parsed.baseline = nextValue(arguments_, ++index, argument);
    else if (argument === "--baseline-threshold") parsed.baselineThreshold = parsePercentage(nextValue(arguments_, ++index, argument));
    else if (argument === "--iterations") parsed.iterations = parsePositiveInteger(nextValue(arguments_, ++index, argument), "iterations");
    else if (argument === "--warmup") parsed.warmup = parseNonNegativeInteger(nextValue(arguments_, ++index, argument), "warmup");
    else if (argument === "--lnako") parsed.lnako = nextValue(arguments_, ++index, argument);
    else if (argument === "--python") parsed.python = nextValue(arguments_, ++index, argument);
    else if (argument === "--clang") parsed.clang = nextValue(arguments_, ++index, argument);
    else if (argument === "--cnako") parsed.cnako = nextValue(arguments_, ++index, argument);
    else if (argument === "--gonako") parsed.gonako = nextValue(arguments_, ++index, argument);
    else if (argument === "--rustc") parsed.rustc = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}`);
  }
  if (!PROFILE_NAMES.includes(parsed.profile)) throw new Error(`未知のbenchmark profileです: ${parsed.profile}`);
  if (process.env.LNAKO_BENCHMARK_LNAKO) parsed.lnako = process.env.LNAKO_BENCHMARK_LNAKO;
  if (process.env.LNAKO_BENCHMARK_PYTHON) parsed.python = process.env.LNAKO_BENCHMARK_PYTHON;
  if (process.env.LNAKO_BENCHMARK_CLANG) parsed.clang = process.env.LNAKO_BENCHMARK_CLANG;
  if (process.env.LNAKO_BENCHMARK_CNAKO) parsed.cnako = process.env.LNAKO_BENCHMARK_CNAKO;
  if (process.env.LNAKO_BENCHMARK_GONAKO) parsed.gonako = process.env.LNAKO_BENCHMARK_GONAKO;
  if (process.env.LNAKO_BENCHMARK_RUSTC) parsed.rustc = process.env.LNAKO_BENCHMARK_RUSTC;
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

function appendList(list, value) {
  const values = value.split(",").map((part) => part.trim()).filter(Boolean);
  if (values.length === 0) throw new Error(`空のcase指定です: ${value}`);
  return [...(list ?? []), ...values];
}

function parseList(value, allowed, argument) {
  if (value === "all") return null;
  const list = value.split(",").map((part) => part.trim()).filter(Boolean);
  if (list.length === 0 || list.some((item) => !allowed.includes(item))) {
    throw new Error(`${argument}に未知の値があります: ${value}`);
  }
  return [...new Set(list)];
}

function parseOptimization(value) {
  if (!/^O[0-3]$/.test(value)) throw new Error(`optimizationはO0〜O3で指定してください: ${value}`);
  return value;
}

function parsePercentage(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw new Error(`baseline thresholdが不正です: ${value}`);
  return number > 1 ? number / 100 : number;
}

export function resolveSuitePath(suiteOption) {
  const requested = resolve(root, suiteOption);
  if (suiteOption === DEFAULT_SUITE && !existsSync(requested)) {
    const legacy = resolve(root, LEGACY_SUITE);
    if (existsSync(legacy)) {
      console.warn(`v2 suiteが見つからないため、v1 suiteへフォールバックします: ${LEGACY_SUITE}`);
      return legacy;
    }
  }
  return requested;
}

export function createRuntimeConfigs(options) {
  return new Map([
    ["cnako", { command: resolveSpawnCommand(options.cnako), versionFlag: "-v" }],
    ["gonako", { command: resolveSpawnCommand(options.gonako), versionFlag: "--version" }],
    ["python", { command: resolveSpawnCommand(options.python), versionFlag: "--version" }],
    ["c", { command: resolveSpawnCommand(options.clang), versionFlag: "--version" }],
    ["rust", { command: resolveSpawnCommand(options.rustc), versionFlag: "--version" }],
    ["lnako", { command: resolveSpawnCommand(options.lnako), versionFlag: "--version" }],
  ]);
}

export function buildReport(suite, tempDir, options = {}, runtimeConfigs = null) {
  options = { ...parseArguments([]), ...options };
  runtimeConfigs ??= createRuntimeConfigs(options);
  const profileOptions = resolveProfileOptions(options.profile, options);
  const selectedRuntimes = options.runtimes ?? RUNTIME_NAMES;
  const available = new Map();
  const runtimeRecords = {};
  for (const runtime of RUNTIME_NAMES) {
    const config = runtimeConfigs.get(runtime);
    const isAvailable = config !== undefined && isCommandAvailable(config.command, config.versionFlag);
    if (isAvailable) available.set(runtime, config);
    runtimeRecords[runtime] = {
      command: config?.command ?? null,
      version: config ? getCommandVersion(config.command, config.versionFlag) : null,
      available: isAvailable,
      selected: selectedRuntimes.includes(runtime),
      group: runtimeComparisonGroup(runtime),
      ...(runtime === "gonako" && isAvailable && selectedRuntimes.includes(runtime) ? { provenance: gonakoProvenance(config.command) } : {}),
    };
  }
  const selectedCases = selectBenchmarkCases(suite, { profile: options.profile, caseIds: options.cases });
  const failures = [];
  const warnings = [];
  const caseReports = [];
  for (const item of selectedCases) {
    const caseDir = join(tempDir, item.id);
    mkdirSync(caseDir, { recursive: true });
    const invocation = resolveCaseInvocation(item, options.profile);
    const sourceHashes = collectSourceHashes(item);
    const runtimeStatus = {};
    const measurements = [];
    for (const runtime of RUNTIME_NAMES) {
      const config = runtimeConfigs.get(runtime);
      const source = sourceForRuntime(item, runtime);
      const status = {
        selected: selectedRuntimes.includes(runtime),
        available: available.has(runtime),
        status: "skipped",
        reason: null,
        group: runtimeComparisonGroup(runtime),
      };
      runtimeStatus[runtime] = status;
      if (!status.selected) {
        status.reason = "not_selected";
        continue;
      }
      if (!status.available) {
        status.reason = "runtime_unavailable";
        if (options.runtimesExplicit) {
          status.status = "failed";
          failures.push(formatFailure(item, runtime, new Error(`指定されたruntimeが利用できません: ${runtime}`), "runtime_unavailable"));
        }
        continue;
      }
      const support = item.runtime_support?.[runtime] ?? suite.runtime_support?.[runtime];
      if (support?.supported === false) {
        status.reason = `unsupported: ${support.reason}`;
        continue;
      }
      if (source === undefined) {
        status.reason = "source_unavailable";
        if (support?.supported === true) {
          status.status = "failed";
          failures.push(formatFailure(item, runtime, new Error(`対応を宣言したruntimeのsourceがありません: ${runtime}`), "source_unavailable"));
        }
        continue;
      }
      const sourcePath = resolve(root, source);
      if (!isReadable(sourcePath)) {
        status.status = "failed";
        status.reason = "source_missing";
        failures.push(formatFailure(item, runtime, new Error(`suiteに宣言されたsourceがありません: ${source}`), "source_missing"));
        continue;
      }
      try {
        const records = item.legacy
          ? runLegacyRuntimeBenchmark(item, runtime, config, sourcePath, caseDir, profileOptions, options)
          : runV2RuntimeBenchmark(item, runtime, config, sourcePath, caseDir, invocation, profileOptions, options);
        measurements.push(...records);
        status.status = records.length > 0 ? "measured" : "skipped";
        if (records.length === 0) status.reason = "measurement_unsupported";
        for (const record of records) {
          if (record.measurement === "steady_state" && record.median_ns < 200_000_000) {
            warnings.push({
              case: item.id,
              runtime,
              mode: record.mode,
              reason: "steady_state_batch_under_200ms",
              median_ns: record.median_ns,
            });
          }
        }
      } catch (error) {
        status.status = "failed";
        status.reason = error instanceof Error ? error.message : String(error);
        failures.push(formatFailure(item, runtime, error));
      }
    }
    caseReports.push({
      id: item.id,
      category: item.category,
      kind: item.kind,
      description: item.description,
      measurement: item.measurement,
      profiles: [...item.profiles],
      tags: [...item.tags],
      source: item.source,
      source_hashes: sourceHashes,
      sources: { ...item.sources },
      runtime_support: { ...item.runtime_support },
      input: { args: [...invocation.args] },
      expected_stdout: invocation.expected_stdout,
      measurements,
      runtime_status: runtimeStatus,
    });
  }
  const suiteOption = options.suite ?? (suite.legacy ? LEGACY_SUITE : DEFAULT_SUITE);
  const report = {
    schema_version: suite.schema_version,
    project: "lnako",
    version: getProjectVersion(),
    git_commit: getGitCommit(),
    git_dirty: getGitDirty(),
    generated_at_unix_ms: Date.now(),
    target: { os: normalizeTargetOs(platform()), arch: normalizeTargetArch(hostArch()) },
    hardware: collectHardwareMetadata(),
    toolchain: collectToolchainVersions(runtimeConfigs),
    suite_name: suite.name,
    suite: suiteOption,
    suite_sha256: hashSuiteIfAvailable(suiteOption),
    runtime_support: { ...suite.runtime_support },
    optimization: options.optimization,
    profile: options.profile,
    iterations: profileOptions.samples,
    warmup: profileOptions.warmup,
    timeout_ms: options.timeoutMs,
    selected_runtimes: [...selectedRuntimes],
    runtime_selection_explicit: options.runtimesExplicit === true,
    runtimes: runtimeRecords,
    comparison_groups: {
      "nadesiko-implementation": [...NADESIKO_RUNTIMES],
      "cross-language-reference": [...CROSS_LANGUAGE_RUNTIMES],
    },
    warnings,
    failures,
    status: failures.length === 0 ? "success" : "failed",
    cases: caseReports,
  };
  if (options.baseline !== null && options.baseline !== undefined) addBaselineWarnings(report, options.baseline, options.baselineThreshold);
  return report;
}

function runV2RuntimeBenchmark(item, runtime, config, sourcePath, caseDir, invocation, profileOptions, options) {
  if (item.measurement === "compile") {
    return supportsCompilation(runtime)
      ? [runCompilationMeasurement(runtime, config, sourcePath, caseDir, invocation, profileOptions, options, "compile")]
      : [];
  }
  const records = [];
  if (runtime === "lnako") {
    records.push(runExecutionMeasurement(runtime, "interpreter", config.command, lnakoRunArgs(sourcePath, invocation.args), invocation.expected_stdout, item.measurement, profileOptions, options));
    const artifact = runCompilationMeasurement(runtime, config, sourcePath, caseDir, invocation, profileOptions, options, "compile");
    records.push(artifact);
    records.push(runExecutionMeasurement(runtime, "aot_run", executablePath(artifact.executable_path), invocation.args, invocation.expected_stdout, item.measurement, profileOptions, options, artifact.executable_size_bytes));
    return records;
  }
  if (runtime === "c" || runtime === "rust") {
    const artifact = runCompilationMeasurement(runtime, config, sourcePath, caseDir, invocation, profileOptions, options, "compile");
    records.push(artifact);
    records.push(runExecutionMeasurement(runtime, "run", executablePath(artifact.executable_path), invocation.args, invocation.expected_stdout, item.measurement, profileOptions, options, artifact.executable_size_bytes));
    return records;
  }
  records.push(runExecutionMeasurement(runtime, "run", config.command, getSourceRunArgs(runtime, sourcePath, invocation.args), invocation.expected_stdout, item.measurement, profileOptions, options));
  return records;
}

function runLegacyRuntimeBenchmark(item, runtime, config, sourcePath, caseDir, profileOptions, options) {
  const records = [];
  if (runtime === "lnako") {
    records.push(runExecutionMeasurement(runtime, "interpreter", config.command, lnakoRunArgs(sourcePath, []), item.expected_stdout, "startup", profileOptions, options));
    const artifact = runCompilationMeasurement(runtime, config, sourcePath, caseDir, { args: [], expected_stdout: item.expected_stdout }, profileOptions, options, "aot_compile");
    artifact.mode = "aot_compile";
    records.push(artifact);
    records.push(runExecutionMeasurement(runtime, "aot_run", executablePath(artifact.executable_path), [], item.expected_stdout, "startup", profileOptions, options, artifact.executable_size_bytes));
    return records;
  }
  if (runtime === "c" || runtime === "rust") {
    const artifact = runCompilationMeasurement(runtime, config, sourcePath, caseDir, { args: [], expected_stdout: item.expected_stdout }, profileOptions, options, "compile");
    records.push(artifact);
    records.push(runExecutionMeasurement(runtime, "run", executablePath(artifact.executable_path), [], item.expected_stdout, "startup", profileOptions, options, artifact.executable_size_bytes));
    return records;
  }
  records.push(runExecutionMeasurement(runtime, "run", config.command, getSourceRunArgs(runtime, sourcePath, []), item.expected_stdout, "startup", profileOptions, options));
  return records;
}

function supportsCompilation(runtime) {
  return runtime === "lnako" || runtime === "c" || runtime === "rust";
}

function runCompilationMeasurement(runtime, config, sourcePath, caseDir, invocation, profileOptions, options, mode) {
  const filename = runtime === "lnako" ? "lnako-aot" : runtime === "c" ? "ref-c" : "ref-rust";
  const outputPath = join(caseDir, `${filename}${executableSuffix}`);
  const compileArgs = compilerArgs(runtime, sourcePath, outputPath, options.optimization);
  const result = runMeasuredSamples({
    command: config.command,
    args: compileArgs,
    cwd: root,
    warmup: profileOptions.warmup,
    samples: profileOptions.samples,
    timeoutMs: options.timeoutMs,
    shell: needsShell(config.command),
  });
  if (!canExecute(outputPath)) throw new Error(`コンパイル後の実行ファイルがありません: ${outputPath}`);
  const executable = executablePath(outputPath);
  const correctness = runProcess(executable, invocation.args, { cwd: root, timeoutMs: options.timeoutMs, shell: needsShell(executable) });
  assertSuccessfulProcess(executable, invocation.args, correctness);
  if (!outputsMatch(correctness.stdout, invocation.expected_stdout)) {
    throw new BenchmarkProcessError(`コンパイル後の出力が一致しません: ${runtime}`, {
      code: "output_mismatch",
      expected_stdout: invocation.expected_stdout,
      actual_stdout: correctness.stdout,
      command: executable,
      args: invocation.args,
    });
  }
  const summary = summarizeSamples(result.samples_ns);
  return {
    runtime,
    group: runtimeComparisonGroup(runtime),
    measurement: "compile",
    mode,
    timing_scope: "process_wall",
    correctness_checked: true,
    executable_path: executable,
    executable_size_bytes: executableSizeBytes(executable),
    warnings: [],
    ...summary,
  };
}

function runExecutionMeasurement(runtime, mode, command, args, expectedStdout, measurement, profileOptions, options, executableSize = null) {
  const result = runMeasuredSamples({
    command,
    args,
    cwd: root,
    expectedStdout,
    warmup: profileOptions.warmup,
    samples: profileOptions.samples,
    timeoutMs: options.timeoutMs,
    shell: needsShell(command),
  });
  const summary = summarizeSamples(result.samples_ns);
  const warnings = measurement === "steady_state" && summary.median_ns < 200_000_000
    ? ["process-batched wall median is under 200ms; treat the result as startup-sensitive"]
    : [];
  return {
    runtime,
    group: runtimeComparisonGroup(runtime),
    measurement,
    mode,
    timing_scope: measurement === "steady_state" ? "process_batched_wall" : "process_wall",
    correctness_checked: true,
    executable_size_bytes: executableSize,
    warnings,
    ...summary,
  };
}

function compilerArgs(runtime, sourcePath, outputPath, optimization) {
  const level = optimization.slice(1);
  if (runtime === "lnako") return ["build", sourcePath, `-${optimization}`, "-o", outputPath];
  if (runtime === "c") {
    const sysroot = isDarwin ? detectDarwinSysroot() : null;
    return [`-${optimization}`, ...(sysroot === null ? [] : ["-isysroot", sysroot]), sourcePath, "-o", outputPath];
  }
  return ["-C", `opt-level=${level}`, sourcePath, "-o", outputPath];
}

function getSourceRunArgs(runtime, sourcePath, inputArgs) {
  if (runtime === "gonako") return ["run", sourcePath, ...inputArgs];
  return [sourcePath, ...inputArgs];
}

function lnakoRunArgs(sourcePath, inputArgs) {
  return ["run", sourcePath, ...inputArgs];
}

function formatFailure(item, runtime, error, explicitCode = null) {
  const details = error?.details ?? {};
  return {
    case: item.id,
    runtime,
    code: explicitCode ?? error?.code ?? "process_failed",
    reason: error instanceof Error ? error.message : String(error),
    timeout: error?.code === "timeout",
    expected_stdout: details.expected_stdout ?? null,
    actual_stdout: details.actual_stdout ?? null,
  };
}

function collectSourceHashes(item) {
  const hashes = {};
  for (const [runtime, source] of Object.entries(item.sources ?? {})) {
    const path = resolve(root, source);
    if (isReadable(path)) {
      try {
        hashes[runtime] = sha256File(path);
      } catch {
        // Keep the runtime status as the source of truth for unreadable files.
      }
    }
  }
  return hashes;
}

function addBaselineWarnings(report, baselineOption, threshold) {
  try {
    const baselinePath = resolve(root, baselineOption);
    const baseline = JSON.parse(readFileSync(baselinePath, "utf8"));
    report.baseline = { path: baselineOption, threshold, loaded: true };
    report.warnings.push(...compareBaseline(report, baseline, { threshold }));
  } catch (error) {
    report.baseline = { path: baselineOption, threshold, loaded: false };
    report.warnings.push({ reason: "baseline_unavailable", path: baselineOption, message: error.message });
  }
}

function hashSuiteIfAvailable(suiteOption) {
  try {
    return sha256File(resolveSuitePath(suiteOption));
  } catch {
    return null;
  }
}

function isReadable(path) {
  try {
    accessSync(path, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

// Windowsでは拡張子なしのコマンド名（npm .cmdシム等）をspawnSyncから
// 直接起動できないため、PATH上のPATHEXT候補を解決する。
export function resolveSpawnCommand(command) {
  if (!isWindows || isAbsolute(command) || dirname(command) !== ".") return command;
  const pathExts = (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").toLowerCase().split(";");
  for (const rawDir of (process.env.PATH ?? "").split(delimiter)) {
    const dir = rawDir.replace(/^"+|"+$/g, "");
    if (!dir) continue;
    for (const extension of pathExts) {
      const candidate = join(dir, `${command}${extension}`);
      try {
        accessSync(candidate);
        return candidate;
      } catch {
        // continue
      }
    }
  }
  return command;
}

function needsShell(command) {
  return isWindows && /\.(cmd|bat)$/i.test(command);
}

export function gonakoProvenance(command, receiptPath = process.env.LNAKO_BENCHMARK_GONAKO_PROVENANCE) {
  const sha256 = sha256File(command);
  if (!receiptPath) return { sha256, release: null, url: null };
  const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
  if (receipt.sha256 !== sha256 || typeof receipt.release !== "string" || typeof receipt.url !== "string") {
    throw new Error("gonakoの配布証明と実行バイナリが一致しません");
  }
  return { sha256, release: receipt.release, url: receipt.url };
}

function isCommandAvailable(command, versionFlag) {
  if (!command) return false;
  if (isAbsolute(command)) {
    try {
      accessSync(command, X_OK);
      return true;
    } catch {
      return false;
    }
  }
  if (versionFlag !== null) {
    const result = spawnSync(command, [versionFlag], { shell: needsShell(command), encoding: "utf8", timeout: 5_000 });
    if (result.status === 0) return true;
  }
  const probe = platform() === "win32" ? "where" : "which";
  return spawnSync(probe, [command], { shell: false, encoding: "utf8" }).status === 0;
}

function getCommandVersion(command, versionFlag) {
  if (versionFlag === null || !isCommandAvailable(command, versionFlag)) return null;
  const result = spawnSync(command, [versionFlag], { shell: needsShell(command), encoding: "utf8", timeout: 5_000, maxBuffer: 8 * 1024 * 1024 });
  if (result.status !== 0) return null;
  const output = result.stdout || result.stderr || "";
  return output.split(/\r?\n/)[0].trim() || null;
}

function collectToolchainVersions(runtimeConfigs) {
  const versions = {};
  for (const runtime of RUNTIME_NAMES) {
    const config = runtimeConfigs.get(runtime);
    versions[runtime] = config ? getCommandVersion(config.command, config.versionFlag) : null;
  }
  versions.zig = getCommandVersion("zig", "version");
  // A system llvm-config may describe a different LLVM from the selected AOT toolchain.
  versions.llvm = process.env.LNAKO_LLVM_DIR
    ? getCommandVersion(join(process.env.LNAKO_LLVM_DIR, "bin", isWindows ? "llvm-config.exe" : "llvm-config"), "--version")
    : null;
  return versions;
}

function detectDarwinSysroot() {
  const result = spawnSync("xcrun", ["--show-sdk-path"], { encoding: "utf8", shell: false, timeout: 5_000 });
  if (result.error || result.status !== 0) return null;
  const sysroot = result.stdout.trim();
  return sysroot.length > 0 ? sysroot : null;
}

function canExecute(path) {
  for (const candidate of [path, `${path}.exe`]) {
    try {
      accessSync(candidate, X_OK);
      return true;
    } catch {
      // continue
    }
  }
  return false;
}

function executablePath(path) {
  for (const candidate of [path, `${path}.exe`]) {
    try {
      accessSync(candidate, X_OK);
      return candidate;
    } catch {
      // continue
    }
  }
  return path;
}

function normalizeTargetOs(value) {
  return value === "darwin" ? "macos" : value === "win32" ? "windows" : value;
}

function normalizeTargetArch(value) {
  return value === "arm64" ? "aarch64" : value === "x64" ? "x86_64" : value;
}

function getProjectVersion() {
  try {
    const buildZig = readFileSync(resolve(root, "build.zig.zon"), "utf8");
    const match = buildZig.match(/\.version\s*=\s*"([^"]+)"/);
    return match ? match[1] : "0.0.0-dev";
  } catch {
    return "0.0.0-dev";
  }
}

function getGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8", shell: false, timeout: 5_000 });
  return result.error || result.status !== 0 ? "" : result.stdout.trim();
}

function getGitDirty() {
  const override = process.env.LNAKO_BENCHMARK_GIT_DIRTY;
  if (override === "1" || override === "true") return true;
  if (override === "0" || override === "false") return false;
  const result = spawnSync("git", ["status", "--porcelain", "--untracked-files=all"], {
    cwd: root,
    encoding: "utf8",
    shell: false,
    timeout: 5_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) return true;
  return result.stdout.trim().length !== 0;
}

function collectHardwareMetadata() {
  const processors = cpus();
  return {
    cpu_model: processors[0]?.model ?? null,
    cpu_logical_count: processors.length,
    total_memory_bytes: totalmem(),
    os_release: osRelease(),
  };
}

export function writeJson(path, report) {
  const absolutePath = resolve(root, path);
  mkdirSync(dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

export function writeMarkdown(path, report) {
  const absolutePath = resolve(root, path);
  mkdirSync(dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, renderBenchmarkMarkdown(report), "utf8");
}

export function main(arguments_ = process.argv.slice(2)) {
  const options = parseArguments(arguments_);
  const suitePath = resolveSuitePath(options.suite);
  const suite = loadBenchmarkSuite(suitePath);
  options.suite = relativeSuitePath(suitePath);
  const tempDir = mkdtempSync(join(tmpdir(), "lnako-comparison-"));
  let report;
  try {
    report = buildReport(suite, tempDir, options, createRuntimeConfigs(options));
    validateBenchmarkReport(report, { allowFailed: true });
    writeJson(options.output, report);
    writeMarkdown(options.markdown, report);
  } finally {
    try {
      rmSync(tempDir, { recursive: true, force: true });
    } catch {
      // cleanup failure must not hide the benchmark result
    }
  }
  if (report.status === "failed") {
    throw new Error(`比較ベンチマークが失敗しました: ${report.failures.length}件。結果: ${options.output}`);
  }
  console.log(`比較ベンチマークを完了しました: ${options.output}`);
  return report;
}

function relativeSuitePath(path) {
  const prefix = `${root}/`;
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
