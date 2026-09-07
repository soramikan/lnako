import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { outputsMatch } from "./lib/benchmark_statistics.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export function summarizeCode(ir, assembly) {
  const calls = {};
  for (const match of ir.matchAll(/\bcall\b[^\n]*?@([\w.$]+)/g)) calls[match[1]] = (calls[match[1]] ?? 0) + 1;
  return {
    static_call_sites: calls,
    stack_probe_mentions: (assembly.match(/\b_+chkstk\b/g) ?? []).length,
    sqrt_mentions: (assembly.match(/\b(?:v?sqrt\w*|_?sqrt)\b/g) ?? []).length,
    typed_definitions: [...ir.matchAll(/^define\s+.*?\b(double|i1)\s+@([^ (]+)/gm)].map((m) => m[2]),
  };
}

export function profile(arguments_) {
  let output = null;
  let compiler = join(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
  let sampling = false;
  for (let i = 0; i < arguments_.length; i++) {
    const arg = arguments_[i];
    if (arg === "--output" || arg === "--lnako") {
      const value = arguments_[++i];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a path`);
      if (arg === "--output") output = resolve(value); else compiler = resolve(value);
    } else if (arg === "--windows-sampling") sampling = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!output) throw new Error("--output is required");
  if (existsSync(output)) throw new Error("Use a new output directory to preserve previous evidence");
  if (sampling && process.platform !== "win32") throw new Error("Windows sampling requires Windows");
  const llvm = process.env.LNAKO_LLVM_DIR;
  if (!llvm) throw new Error("LNAKO_LLVM_DIR must select the pinned LLVM toolchain");
  mkdirSync(output, { recursive: true });
  const executableSuffix = process.platform === "win32" ? ".exe" : "";
  const clang = join(llvm, "bin", `clang${executableSuffix}`);
  const suite = JSON.parse(readFileSync(join(root, "benchmarks/suites/v2.json"), "utf8"));
  const testCase = suite.cases.find((item) => item.id === "nbody");
  const source = join(root, testCase.source);
  const binary = join(output, `nbody${executableSuffix}`);
  const irPath = join(output, "nbody.ll");
  const assemblyPath = join(output, "nbody.s");
  const commands = [];
  function run(command, args, { optional = false, env = process.env, log = null } = {}) {
    const result = spawnSync(command, args, { cwd: output, env, encoding: "utf8", timeout: 120_000, maxBuffer: 64 * 1024 * 1024 });
    commands.push({ command, args, pid: result.pid ?? null, status: result.status, signal: result.signal, error: result.error?.message ?? null });
    if (log) writeFileSync(join(output, log), (result.stdout ?? "") + (result.stderr ?? ""));
    if (result.status !== 0 && !optional) throw new Error(`${command} failed: ${result.error?.message ?? result.stderr}`);
    return result;
  }
  const revision = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const status = spawnSync("git", ["status", "--porcelain=v1", "--untracked-files=no"], { cwd: root, encoding: "utf8" });
  const manifest = { source_sha256: createHash("sha256").update(readFileSync(source)).digest("hex"), repository_commit: revision.status === 0 ? revision.stdout.trim() : null, repository_tracked_dirty: status.status === 0 ? status.stdout.trim().length > 0 : null, compiler_path: compiler, schema: "lnako.numeric-profile.v1", platform: process.platform, arch: process.arch, source: testCase.source, arguments: testCase.input.args, commands, sampling: "not-requested" };
  try {
    const traceEnv = { ...process.env, LNAKO_LLVM_TRACE: "1" };
    run(compiler, ["build", source, "-O3", "-o", binary], { env: traceEnv, log: "compile-stages.log" });
    const mapPath = `${binary}.map`;
    manifest.link_map = existsSync(mapPath) ? { file: mapPath, sha256: createHash("sha256").update(readFileSync(mapPath)).digest("hex") } : null;
    run(compiler, ["build", source, "-O3", "--emit", "llvm-ir", "-o", irPath], { log: "ir-build.log" });
    run(clang, ["-S", "-x", "ir", "-O3", irPath, "-o", assemblyPath], { log: "assembly-build.log" });
    manifest.assembly_scope = "clang assembly from the optimized LLVM module; linked disassembly is separate";
    const readobj = join(llvm, "bin", `llvm-readobj${executableSuffix}`);
    const objdump = join(llvm, "bin", `llvm-objdump${executableSuffix}`);
    manifest.imports = existsSync(readobj)
      ? (run(readobj, process.platform === "win32" ? ["--coff-imports", "--symbols", binary] : ["--needed-libs", "--symbols", binary], { log: "imports-symbols.txt" }), "collected")
      : "tool-unavailable";
    manifest.linked_disassembly = existsSync(objdump)
      ? (run(objdump, ["-d", binary], { log: "linked-disassembly.txt" }), "collected")
      : "tool-unavailable";
    const checked = run(binary, testCase.input.args, { env: { ...process.env, LNAKO_PERF_COUNTERS: "1" }, log: "runtime-counters.log" });
    if (!outputsMatch(checked.stdout, testCase.expected_stdout)) throw new Error("nbody output mismatch");
    manifest.output_verified = true;
    manifest.code = summarizeCode(readFileSync(irPath, "utf8"), readFileSync(assemblyPath, "utf8"));
    manifest.binary_sha256 = createHash("sha256").update(readFileSync(binary)).digest("hex");
    manifest.compiler_sha256 = createHash("sha256").update(readFileSync(compiler)).digest("hex");
    manifest.binary_bytes = readFileSync(binary).length;
    if (sampling) {
      // A private WPR instance leaves unrelated recording sessions alone.
      // https://learn.microsoft.com/windows-hardware/test/wpt/wpr-command-line-options
      const instance = `lnako-nbody-${process.pid}`;
      run("wpr.exe", ["-start", "CPU", "-filemode", "-recordtempto", output, "-instancename", instance], { log: "wpr-start.log" });
      try {
        for (let i = 0; i < 100; i++) run(binary, testCase.input.args);
      } finally {
        run("wpr.exe", ["-stop", join(output, "nbody-cpu.etl"), "-instancename", instance], { log: "wpr-stop.log" });
      }
      manifest.sampling = "etl-collected-analysis-required";
      // Export the ETL while still on Windows so analysis can run on another
      // host without requiring Windows trace decoding libraries.
      // https://learn.microsoft.com/windows-server/administration/windows-commands/tracerpt
      run("tracerpt.exe", [join(output, "nbody-cpu.etl"), "-o", join(output, "nbody-events.xml"), "-of", "XML", "-summary", join(output, "trace-summary.txt"), "-y"], { log: "tracerpt.log" });
      manifest.trace_export = "xml-and-summary-collected";
    }
  } finally {
    writeFileSync(join(output, "profile.json"), JSON.stringify(manifest, null, 2) + "\n");
  }
  return manifest;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) profile(process.argv.slice(2));
