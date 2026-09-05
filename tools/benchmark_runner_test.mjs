import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  buildReport,
  createRuntimeConfigs,
  parseArguments,
} from "./run_comparison_benchmark.mjs";
import { BenchmarkProcessError, runMeasuredSamples } from "./lib/benchmark_process.mjs";
import {
  PROFILE_PRESETS,
  outputsMatch,
  resolveProfileOptions,
  summarizeSamples,
} from "./lib/benchmark_statistics.mjs";
import {
  normalizeBenchmarkSuite,
  resolveCaseInvocation,
  selectBenchmarkCases,
} from "./lib/benchmark_suite.mjs";
import {
  compareBaseline,
  renderBenchmarkMarkdown,
  validateBenchmarkReport,
} from "./lib/benchmark_report.mjs";
import { validateMarkdown } from "./check_comparison_benchmark.mjs";

function makeExecutable(body) {
  const directory = mkdtempSync(join(tmpdir(), "lnako-benchmark-test-"));
  const scriptPath = join(directory, "fake-runtime.mjs");
  writeFileSync(scriptPath, `#!/usr/bin/env node\n${body}\n`, "utf8");
  if (process.platform === "win32") {
    // Windows does not execute a .mjs shebang directly. Keep the test body
    // portable and expose a normal command shim that invokes this Node.
    const path = join(directory, "fake-runtime.cmd");
    const nodePath = process.execPath.replaceAll('"', '""');
    writeFileSync(path, `@echo off\r\n"${nodePath}" "%~dp0fake-runtime.mjs" %*\r\n`, "utf8");
    return { directory, path, shell: true };
  }
  chmodSync(scriptPath, 0o755);
  return { directory, path: scriptPath, shell: false };
}

function removeDirectory(directory) {
  rmSync(directory, { recursive: true, force: true });
}

test("profile presets and legacy overrides are deterministic", () => {
  assert.deepEqual(PROFILE_PRESETS, {
    smoke: { warmup: 1, samples: 3 },
    normal: { warmup: 3, samples: 10 },
    full: { warmup: 5, samples: 25 },
  });
  assert.deepEqual(resolveProfileOptions("normal"), { profile: "normal", warmup: 3, samples: 10 });
  assert.deepEqual(resolveProfileOptions("full", { iterations: 2, warmup: 0 }), { profile: "full", warmup: 0, samples: 2 });
  const options = parseArguments(["--profile", "smoke", "--iterations", "4", "--warmup", "0", "--runtimes", "lnako,cnako", "--case", "one,two", "--case", "three", "--optimization", "O0", "--timeout", "55"]);
  assert.equal(options.profile, "smoke");
  assert.deepEqual(options.runtimes, ["lnako", "cnako"]);
  assert.deepEqual(options.cases, ["one", "two", "three"]);
  assert.equal(options.iterations, 4);
  assert.equal(options.warmup, 0);
  assert.equal(options.optimization, "O0");
  assert.equal(options.timeoutMs, 55);
});

test("statistics retain observation order and use the native rounded quantile convention", () => {
  const observations = [9, 1, 7, 3];
  const summary = summarizeSamples(observations);
  assert.deepEqual(summary.samples_ns, observations);
  assert.deepEqual(observations, [9, 1, 7, 3]);
  assert.equal(summary.p25_ns, 3);
  assert.equal(summary.median_ns, 5);
  assert.equal(summary.p75_ns, 8);
  assert.equal(summary.iqr_ns, 5);
  assert.equal(summary.mad_ns, 3);
  assert.equal(outputsMatch("x\r\n", "x\n"), true);
  assert.equal(outputsMatch("x\n\n", "x\n"), false);
});

test("fake process output mismatches and timeout are hard failures", () => {
  const wrong = makeExecutable("process.stdout.write('wrong\\n');");
  const sleeping = makeExecutable("setTimeout(() => {}, 1000);");
  try {
    assert.throws(
      () => runMeasuredSamples({ command: wrong.path, expectedStdout: "expected\n", warmup: 0, samples: 1, timeoutMs: 1000, shell: wrong.shell }),
      (error) => error instanceof BenchmarkProcessError && error.code === "output_mismatch",
    );
    assert.throws(
      () => runMeasuredSamples({ command: sleeping.path, expectedStdout: null, warmup: 0, samples: 1, timeoutMs: 20, shell: sleeping.shell }),
      (error) => error instanceof BenchmarkProcessError && error.code === "timeout",
    );
  } finally {
    removeDirectory(wrong.directory);
    removeDirectory(sleeping.directory);
  }
});

test("v2 suite validates metadata, expands same sources, and selects profile cases", () => {
  const suite = normalizeBenchmarkSuite({
    schema_version: 2,
    name: "test-suite",
    cases: [{
      id: "case-one",
      category: "core",
      kind: "micro",
      description: "test",
      measurement: "steady_state",
      profiles: ["smoke", "normal"],
      tags: ["portable"],
      source: "benchmarks/cases/test/source.nako3",
      sources: { cnako: "same", lnako: "same" },
      input: { args: ["4"] },
      expected_stdout: "ok\n",
      input_variants: { smoke: { args: ["1"] } },
      expected_stdout_variants: { smoke: "smoke\n" },
    }],
  });
  assert.equal(suite.cases[0].sources.cnako, suite.cases[0].source);
  assert.deepEqual(resolveCaseInvocation(suite.cases[0], "smoke"), { args: ["1"], expected_stdout: "smoke\n" });
  assert.equal(selectBenchmarkCases(suite, { profile: "full" }).length, 0);
  assert.throws(() => normalizeBenchmarkSuite({ schema_version: 2, name: "bad", cases: [{ id: "bad", category: "core", kind: "micro", description: "x", measurement: "steady_state", profiles: ["smoke"], tags: [], source: "x.nako3", sources: { cnako: "same", lnako: "same" } }] }));
});

test("selected runnable output failure is recorded and makes the report failed", () => {
  const source = makeExecutable("");
  const sourcePath = join(source.directory, "source.nako3");
  writeFileSync(sourcePath, "# test\n", "utf8");
  const fake = makeExecutable("if (process.argv.includes('-v')) process.stdout.write('fake\\n'); else process.stdout.write('wrong\\n');");
  const suite = normalizeBenchmarkSuite({
    schema_version: 2,
    name: "failure-suite",
    cases: [{ id: "failure-case", category: "core", kind: "micro", description: "failure", measurement: "startup", profiles: ["smoke"], tags: [], source: sourcePath, sources: { cnako: "same", lnako: "same" }, input: { args: [] }, expected_stdout: "expected\n" }],
  });
  const suiteFile = join(source.directory, "suite.json");
  writeFileSync(suiteFile, JSON.stringify(suite), "utf8");
  const options = {
    suite: suiteFile,
    profile: "smoke",
    runtimes: ["cnako"],
    optimization: "O2",
    timeoutMs: 1000,
    baseline: null,
  };
  const configs = new Map([
    ["cnako", { command: fake.path, versionFlag: "-v" }],
    ["gonako", { command: fake.path, versionFlag: null }],
    ["python", { command: fake.path, versionFlag: "--version" }],
    ["c", { command: fake.path, versionFlag: "--version" }],
    ["rust", { command: fake.path, versionFlag: "--version" }],
    ["lnako", { command: fake.path, versionFlag: "--version" }],
  ]);
  const resultDirectory = mkdtempSync(join(tmpdir(), "lnako-benchmark-result-"));
  try {
    const report = buildReport(suite, resultDirectory, options, configs);
    assert.equal(report.status, "failed");
    assert.equal(report.failures.length, 1);
    assert.equal(report.failures[0].code, "output_mismatch");
    assert.equal(report.cases[0].runtime_status.cnako.status, "failed");
    assert.equal(typeof report.git_dirty, "boolean");
    assert.equal(typeof report.hardware.cpu_logical_count, "number");
    assert.equal(typeof report.hardware.total_memory_bytes, "number");
    assert.equal(typeof report.hardware.os_release, "string");
    validateBenchmarkReport(report, { allowFailed: true });
  } finally {
    removeDirectory(source.directory);
    removeDirectory(fake.directory);
    removeDirectory(resultDirectory);
  }
});

test("explicitly selected unavailable runtimes and declared missing sources fail, while unmapped optional runtimes skip", () => {
  const suite = normalizeBenchmarkSuite({
    schema_version: 2,
    name: "availability-suite",
    cases: [{
      id: "missing-source",
      category: "core",
      kind: "micro",
      description: "missing",
      measurement: "startup",
      profiles: ["smoke"],
      tags: [],
      source: "/tmp/lnako-benchmark-test-missing/source.nako3",
      sources: { cnako: "same", lnako: "same" },
      input: { args: [] },
      expected_stdout: "",
    }],
  });
  const options = {
    suite: null,
    profile: "smoke",
    runtimes: ["cnako"],
    runtimesExplicit: true,
    optimization: "O2",
    timeoutMs: 1000,
    baseline: null,
  };
  const missingRuntime = new Map([["cnako", { command: "/tmp/lnako-benchmark-no-such-runtime", versionFlag: "-v" }]]);
  const resultDirectory = mkdtempSync(join(tmpdir(), "lnako-benchmark-result-"));
  try {
    options.suite = join(resultDirectory, "suite.json");
    writeFileSync(options.suite, JSON.stringify(suite), "utf8");
    const report = buildReport(suite, resultDirectory, options, missingRuntime);
    assert.equal(report.status, "failed");
    assert.equal(report.cases[0].runtime_status.cnako.status, "failed");
    assert.equal(report.cases[0].runtime_status.cnako.reason, "runtime_unavailable");
    validateBenchmarkReport(report, { allowFailed: true });
  } finally {
    removeDirectory(resultDirectory);
  }
});

test("baseline comparisons are warning-only and reject incompatible inputs", () => {
  const current = {
    target: { os: "linux", arch: "x86_64" },
    git_dirty: false,
    hardware: { cpu_model: "test", cpu_logical_count: 2, total_memory_bytes: 1024, os_release: "test" },
    suite_name: "suite",
    suite: "suite.json",
    suite_sha256: "a",
    optimization: "O2",
    profile: "normal",
    toolchain: { zig: "0.16.0" },
    runtimes: { cnako: { version: "3.7.24" } },
    cases: [{ id: "x", input: { args: ["2"] }, source_hashes: { cnako: "b" }, measurements: [{ runtime: "cnako", mode: "run", median_ns: 20 }] }],
  };
  const baseline = structuredClone(current);
  baseline.cases[0].input.args = ["3"];
  const warnings = compareBaseline(current, baseline);
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].reason, "baseline_incompatible");
});

test("v1 reports remain accepted by the v2 checker", () => {
  const summary = summarizeSamples([30, 10, 20]);
  const report = {
    schema_version: 1,
    project: "lnako",
    version: "0.0.0-dev",
    git_commit: "",
    generated_at_unix_ms: 1,
    target: { os: "linux", arch: "x86_64" },
    toolchain: { zig: "0.16.0" },
    suite_name: "legacy",
    suite: "benchmarks/comparison/suite.json",
    optimization: "O2",
    iterations: 3,
    warmup: 1,
    cases: [{ id: "legacy-case", expected_stdout: "ok\n", measurements: [{ runtime: "lnako", mode: "interpreter", ...summary }] }],
  };
  validateBenchmarkReport(report);
  validateMarkdown(renderBenchmarkMarkdown(report), report);
});
