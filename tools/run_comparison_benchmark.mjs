import { spawnSync } from "node:child_process";
import {
  accessSync,
  constants,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { delimiter, dirname, isAbsolute, join, resolve } from "node:path";
import { tmpdir, platform, arch } from "node:os";
import { X_OK } from "node:constants";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));

const isWindows = platform() === "win32";
const isDarwin = platform() === "darwin";
const executableSuffix = isWindows ? ".exe" : "";
const darwinSysroot = isDarwin ? detectDarwinSysroot() : null;

const runtimes = new Map([
  ["cnako", { command: resolveSpawnCommand(options.cnako), versionFlag: "-v", sourceExtensions: [".nako3"] }],
  ["gonako", { command: resolveSpawnCommand(options.gonako), versionFlag: null, sourceExtensions: [".nako3"] }],
  ["python", { command: resolveSpawnCommand(options.python), versionFlag: "--version", sourceExtensions: [".py"] }],
  ["c", { command: resolveSpawnCommand(options.clang), versionFlag: "--version", sourceExtensions: [".c"] }],
  ["rust", { command: resolveSpawnCommand(options.rustc), versionFlag: "--version", sourceExtensions: [".rs"] }],
  ["lnako", { command: resolveSpawnCommand(options.lnako), versionFlag: "--version", sourceExtensions: [".nako3"] }],
]);

const suite = loadSuite(resolve(root, options.suite));
const tempDir = makeTempDir();
try {
  const report = buildReport(suite, tempDir);
  writeJson(options.output, report);
  writeMarkdown(options.markdown, report);
} finally {
  try {
    rmSync(tempDir, { recursive: true, force: true });
  } catch {
    // ignore cleanup failure
  }
}

console.log(`比較ベンチマークを完了しました: ${options.output}`);

function parseArguments(arguments_) {
  const parsed = {
    suite: "benchmarks/comparison/suite.json",
    output: "benchmarks/comparison/results/latest.json",
    markdown: "benchmarks/comparison/results/latest.md",
    iterations: 5,
    warmup: 1,
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
    else if (argument === "--iterations") parsed.iterations = parsePositiveInt(nextValue(arguments_, ++index, argument));
    else if (argument === "--warmup") parsed.warmup = parsePositiveInt(nextValue(arguments_, ++index, argument));
    else if (argument === "--lnako") parsed.lnako = nextValue(arguments_, ++index, argument);
    else if (argument === "--python") parsed.python = nextValue(arguments_, ++index, argument);
    else if (argument === "--clang") parsed.clang = nextValue(arguments_, ++index, argument);
    else if (argument === "--cnako") parsed.cnako = nextValue(arguments_, ++index, argument);
    else if (argument === "--gonako") parsed.gonako = nextValue(arguments_, ++index, argument);
    else if (argument === "--rustc") parsed.rustc = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}`);
  }
  // Allow environment overrides.
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

function parsePositiveInt(value) {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`正の整数が必要です: ${value}`);
  return n;
}

function loadSuite(path) {
  const suite = JSON.parse(readFileSync(path, "utf8"));
  if (suite.schema_version !== 1) throw new Error("未対応のsuite schema_versionです");
  if (!suite.name || !Array.isArray(suite.cases) || suite.cases.length === 0) throw new Error("suiteが空です");
  const ids = new Set();
  for (const item of suite.cases) {
    if (!item.id || !item.expected_stdout || typeof item.sources !== "object") {
      throw new Error(`suiteのケース定義が不正です: ${JSON.stringify(item)}`);
    }
    if (ids.has(item.id)) throw new Error(`重複したcase idです: ${item.id}`);
    ids.add(item.id);
  }
  return suite;
}

function makeTempDir() {
  const base = mkdtempSync(join(tmpdir(), "lnako-comparison-"));
  return base;
}

function buildReport(suite, tempDir) {
  const generatedAt = Date.now();
  const target = { os: platform(), arch: arch() };
  const toolchain = collectToolchainVersions();
  const availableRuntimes = new Map();
  for (const [runtime, config] of runtimes) {
    if (isCommandAvailable(config.command, config.versionFlag)) {
      availableRuntimes.set(runtime, config);
    } else {
      console.warn(`コマンドが利用できません、スキップします: ${config.command}`);
    }
  }
  const caseReports = [];
  for (const item of suite.cases) {
    const caseDir = join(tempDir, item.id);
    mkdirSync(caseDir, { recursive: true });
    const measurements = [];
    for (const [runtime, config] of availableRuntimes) {
      const source = item.sources[runtime];
      if (!source) continue;
      const sourcePath = resolve(root, source);
      try {
        accessSync(sourcePath, constants.R_OK);
      } catch {
        console.warn(`ソースファイルが存在しません、スキップします: ${source}`);
        continue;
      }
      try {
        const runtimeMeasurements = runRuntimeBenchmark(item, runtime, config, sourcePath, caseDir);
        for (const m of runtimeMeasurements) measurements.push(m);
      } catch (error) {
        console.warn(`case ${item.id} / runtime ${runtime} の計測に失敗しました: ${error.message}`);
      }
    }
    caseReports.push({
      id: item.id,
      expected_stdout: item.expected_stdout,
      measurements,
    });
  }
  return {
    schema_version: 1,
    project: "lnako",
    version: getProjectVersion(),
    git_commit: getGitCommit(),
    generated_at_unix_ms: generatedAt,
    target,
    toolchain,
    suite_name: suite.name,
    suite: options.suite,
    optimization: "O2",
    iterations: options.iterations,
    warmup: options.warmup,
    cases: caseReports,
  };
}

// Windowsでは拡張子なしのコマンド名（cnako3等のnpm .cmdシム）を
// spawnSyncから直接起動できないため、PATH上のPATHEXT候補を解決する。
function resolveSpawnCommand(command) {
  if (!isWindows || isAbsolute(command) || dirname(command) !== ".") return command;
  const pathExts = (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").toLowerCase().split(";");
  for (const rawDir of (process.env.PATH ?? "").split(delimiter)) {
    const dir = rawDir.replace(/^"+|"+$/g, "");
    if (!dir) continue;
    for (const ext of pathExts) {
      const candidate = join(dir, `${command}${ext}`);
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

function spawnTool(command, args, options_ = {}) {
  return spawnSync(command, args, { shell: needsShell(command), encoding: "utf8", ...options_ });
}

function detectDarwinSysroot() {
  const result = spawnSync("xcrun", ["--show-sdk-path"], { encoding: "utf8", shell: false });
  if (result.error || result.status !== 0) return null;
  const sysroot = result.stdout.trim();
  return sysroot.length > 0 ? sysroot : null;
}

function isCommandAvailable(command, versionFlag) {
  if (isAbsolute(command)) {
    try {
      accessSync(command, X_OK);
      return true;
    } catch {
      return false;
    }
  }
  if (versionFlag) {
    const result = spawnTool(command, [versionFlag]);
    if (result.status === 0) return true;
  }
  return whichCommand(command);
}

function whichCommand(command) {
  const probe = platform() === "win32" ? "where" : "which";
  const result = spawnSync(probe, [command], { shell: false, encoding: "utf8" });
  return result.status === 0;
}

function collectToolchainVersions() {
  const versions = {};
  for (const [runtime, config] of runtimes) {
    versions[runtime] = getCommandVersion(config.command, config.versionFlag);
  }
  versions.zig = getCommandVersion("zig", "version");
  return versions;
}

function getCommandVersion(command, flag) {
  if (!isCommandAvailable(command, flag)) return null;
  if (!flag) return null;
  const result = spawnTool(command, [flag], { maxBuffer: 8 * 1024 * 1024 });
  if (result.error || result.status !== 0) {
    if (flag !== "--version") {
      return getCommandVersion(command, "--version");
    }
    return null;
  }
  const output = result.stdout || result.stderr;
  const first = output.split(/\r?\n/)[0].trim();
  return first || null;
}

function runRuntimeBenchmark(item, runtime, config, sourcePath, caseDir) {
  const measurements = [];
  if (runtime === "lnako") {
      const interpreterSamples = collectSamples(
      config.command,
      ["run", sourcePath],
      item.expected_stdout
    );
    measurements.push(summarizeSamples(runtime, "interpreter", interpreterSamples));

    const binPath = join(caseDir, `lnako-aot${executableSuffix}`);
    const compileSamples = collectSamples(
      config.command,
      ["build", sourcePath, "-O2", "-o", binPath],
      null
    );
    measurements.push(summarizeSamples(runtime, "aot_compile", compileSamples));

    if (canExecute(binPath)) {
      const runSamples = collectSamples(executablePath(binPath), [], item.expected_stdout);
      measurements.push(summarizeSamples(runtime, "aot_run", runSamples));
    }
  } else if (runtime === "c" || runtime === "rust") {
    const binName = runtime === "c" ? "ref-c" : "ref-rust";
    const binPath = join(caseDir, `${binName}${executableSuffix}`);
    const compileArgs =
      runtime === "c"
        ? ["-O2", ...(darwinSysroot !== null ? ["-isysroot", darwinSysroot] : []), sourcePath, "-o", binPath]
        : ["-O", sourcePath, "-o", binPath];
    const compileSamples = collectSamples(config.command, compileArgs, null);
    measurements.push(summarizeSamples(runtime, "compile", compileSamples));

    if (canExecute(binPath)) {
      const runSamples = collectSamples(executablePath(binPath), [], item.expected_stdout);
      measurements.push(summarizeSamples(runtime, "run", runSamples));
    }
  } else {
    const runArgs = runtime === "gonako" ? ["run", sourcePath] : [sourcePath];
    const runSamples = collectSamples(config.command, runArgs, item.expected_stdout);
    measurements.push(summarizeSamples(runtime, "run", runSamples));
  }
  return measurements;
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

function collectSamples(command, args, expectedStdout) {
  const samples = [];
  for (let i = 0; i < options.warmup + options.iterations; i += 1) {
    const started = process.hrtime.bigint();
    const result = spawnTool(command, args, {
      maxBuffer: 64 * 1024 * 1024,
    });
    const finished = process.hrtime.bigint();
    const ns = Number(finished - started);

    if (result.error) {
      throw new Error(`プロセス起動失敗: ${command} ${args.join(" ")}: ${result.error.message}`);
    }
    if (result.status !== 0) {
      const stdout = result.stdout ?? "";
      const stderr = result.stderr ?? "";
      throw new Error(`プロセスが終了コード0ではありません: ${command} ${args.join(" ")}\nstatus: ${result.status}\nstdout: ${stdout}\nstderr: ${stderr}`);
    }
    if (expectedStdout !== null && !outputsMatch(result.stdout ?? "", expectedStdout)) {
      throw new Error(`出力が一致しません\n期待値: ${JSON.stringify(expectedStdout)}\n実際: ${JSON.stringify(result.stdout)}`);
    }
    if (i >= options.warmup) samples.push(ns);
  }
  return samples;
}

function outputsMatch(actual, expected) {
  return normalizeOutput(actual) === normalizeOutput(expected);
}

function normalizeOutput(output) {
  return output.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n+$/, "\n");
}

function summarizeSamples(runtime, mode, samples) {
  if (samples.length === 0) throw new Error("サンプルが空です");
  const sorted = [...samples].sort((a, b) => a - b);
  let median;
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 0) {
    median = Math.floor((sorted[mid - 1] + sorted[mid]) / 2);
  } else {
    median = sorted[mid];
  }
  return {
    runtime,
    mode,
    samples_ns: samples,
    min_ns: sorted[0],
    median_ns: median,
    max_ns: sorted[sorted.length - 1],
  };
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
  const result = spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
    shell: false,
  });
  if (result.error || result.status !== 0) return "";
  return result.stdout.trim();
}

function writeJson(path, report) {
  const absolutePath = resolve(root, path);
  mkdirSync(dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, JSON.stringify(report, null, 2) + "\n", "utf8");
}

function writeMarkdown(path, report) {
  const lines = [];
  lines.push(`# lnako comparison benchmark`);
  lines.push("");
  lines.push(`- suite: \`${report.suite_name}\``);
  lines.push(`- suite path: \`${report.suite}\``);
  lines.push(`- git_commit: \`${report.git_commit}\``);
  lines.push(`- target: \`${report.target.os}/${report.target.arch}\``);
  lines.push(`- generated_at_unix_ms: \`${report.generated_at_unix_ms}\``);
  lines.push(`- iterations: \`${report.iterations}\``);
  lines.push(`- warmup: \`${report.warmup}\``);
  lines.push(`- optimization: \`${report.optimization}\``);
  lines.push("");
  lines.push("## Toolchain versions");
  lines.push("");
  lines.push("| tool | version |");
  lines.push("|---|---|");
  for (const [name, version] of Object.entries(report.toolchain)) {
    lines.push(`| ${name} | \`${version ?? "N/A"}\` |`);
  }
  lines.push("");

  for (const item of report.cases) {
    lines.push(`## ${item.id}`);
    lines.push("");
    lines.push(`expected stdout: \`${item.expected_stdout.trimEnd()}\``);
    lines.push("");
    lines.push("| runtime | mode | samples | min (ns) | median (ns) | max (ns) |");
    lines.push("|---|---|---:|---:|---:|---:|");
    for (const m of item.measurements) {
      lines.push(`| ${m.runtime} | ${m.mode} | ${m.samples_ns.length} | ${m.min_ns} | ${m.median_ns} | ${m.max_ns} |`);
    }
    lines.push("");
  }

  const md = lines.join("\n");
  const absolutePath = resolve(root, path);
  mkdirSync(dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, md, "utf8");
}
