import assert from "node:assert/strict";
import { test } from "node:test";

import {
  aggregateRuns,
  collectMetrics,
  collectRunMetrics,
  formatMarkdown,
  osFromJobName,
  parseToolchainLog,
  percentile,
  secondsBetween,
  summarize,
} from "./collect_ci_metrics.mjs";

test("percentile and summarize compute median/p90/p95", () => {
  const values = [10, 1, 5, 3, 8, 2, 9, 4, 7, 6];
  assert.equal(percentile(values, 50), 5.5);
  assert.equal(percentile(values, 100), 10);
  assert.equal(percentile([], 50), null);
  const summary = summarize(values);
  assert.equal(summary.count, 10);
  assert.equal(summary.median, 5.5);
  assert.ok(Math.abs(summary.p95 - 9.55) < 1e-9);
  assert.equal(summary.min, 1);
  assert.equal(summary.max, 10);
  assert.equal(summarize([]).median, null);
});

test("osFromJobName groups matrix jobs by OS", () => {
  assert.equal(osFromJobName("macOS arm64 / mac-core-standard-support"), "macOS");
  assert.equal(osFromJobName("Windows x86_64 / AOT native shard 1/3 / O0"), "Windows");
  assert.equal(osFromJobName("Linux x86_64 / core"), "Linux");
  assert.equal(osFromJobName("Verify dispatch coverage shards"), "other");
});

test("parseToolchainLog detects cache hit with reuse and reinstall reasons", () => {
  const hitReuse = parseToolchainLog([
    "Cache restored from key: toolchains-macOS-ARM64-v3-abc123",
    "LLVM cache valid:",
    "  version=22.1.8",
    "  platform=macos-aarch64",
  ].join("\n"));
  assert.deepEqual(hitReuse, { cacheHit: true, llvmReinstalled: false, llvmReason: null });

  const hitReinstall = parseToolchainLog([
    "2026-09-18T01:12:30.1976960Z Cache hit for: toolchains-llvm-22.1.8-quickjs-2026-06-04-macOS-ARM64-v2-minimal",
    "2026-09-18T01:12:35.1558410Z LLVM cache invalid:",
    "2026-09-18T01:12:35.1558420Z   reason=marker-missing",
    "2026-09-18T01:12:35.1558430Z   path=/Users/runner/work/lnako/lnako/.cache/toolchains/llvm-22.1.8-macos-aarch64",
    "2026-09-18T01:12:35.1558440Z LLVM 22.1.8をセットアップします: /Users/runner/work/lnako/lnako/.cache/toolchains/llvm-22.1.8-macos-aarch64",
  ].join("\n"));
  assert.deepEqual(hitReinstall, { cacheHit: true, llvmReinstalled: true, llvmReason: "marker-missing" });

  const miss = parseToolchainLog([
    "Cache not found for input keys: toolchains-macOS-ARM64-v3-abc123",
    "LLVM 22.1.8をセットアップします: /x",
  ].join("\n"));
  assert.equal(miss.cacheHit, false);
  assert.equal(miss.llvmReinstalled, true);
  assert.equal(miss.llvmReason, "unknown");

  const empty = parseToolchainLog("unrelated output\n");
  assert.deepEqual(empty, { cacheHit: null, llvmReinstalled: null, llvmReason: null });
});

const runFixture = {
  id: 100,
  event: "pull_request",
  conclusion: "success",
  head_branch: "feature",
  created_at: "2026-09-18T01:00:00Z",
  updated_at: "2026-09-18T01:20:00Z",
  run_started_at: "2026-09-18T01:00:10Z",
};

const jobsFixture = [
  {
    id: 1,
    name: "macOS arm64 / mac-core-standard-support",
    conclusion: "success",
    created_at: "2026-09-18T01:00:05Z",
    started_at: "2026-09-18T01:00:30Z",
    completed_at: "2026-09-18T01:18:00Z",
    steps: [
      { name: "Set up pinned LLVM and LLD", started_at: "2026-09-18T01:01:00Z", completed_at: "2026-09-18T01:06:00Z" },
      { name: "Test", started_at: "2026-09-18T01:10:00Z", completed_at: "2026-09-18T01:14:00Z" },
    ],
  },
  {
    id: 2,
    name: "Linux x86_64 / core",
    conclusion: "success",
    created_at: "2026-09-18T01:00:05Z",
    started_at: "2026-09-18T01:00:06Z",
    completed_at: "2026-09-18T01:11:00Z",
    steps: [
      { name: "Set up pinned LLVM and LLD", started_at: "2026-09-18T01:02:00Z", completed_at: "2026-09-18T01:04:00Z" },
    ],
  },
];

test("collectRunMetrics and aggregateRuns compute wall/runner/step stats", () => {
  const toolchainByJob = new Map([[1, { cacheHit: true, llvmReinstalled: true, llvmReason: "marker-missing" }]]);
  const run = collectRunMetrics(runFixture, jobsFixture, toolchainByJob);
  assert.equal(run.wallSeconds, 1200);
  assert.equal(run.queueSeconds, 10);
  assert.equal(run.jobs[0].seconds, 1050);
  assert.equal(run.jobs[0].queueSeconds, 25);
  assert.equal(run.jobs[0].os, "macOS");

  const aggregate = aggregateRuns([run]);
  assert.equal(aggregate.runCount, 1);
  assert.equal(aggregate.jobCount, 2);
  assert.equal(aggregate.runnerMinutesByOs.macOS, 17.5);
  assert.equal(aggregate.runnerMinutesByOs.Linux, 10.9);
  assert.equal(aggregate.longestJobs[0].name, "macOS arm64 / mac-core-standard-support");
  const llvmStep = aggregate.steps.find((step) => step.name === "Set up pinned LLVM and LLD");
  assert.equal(llvmStep.count, 2);
  assert.equal(llvmStep.median, 210);
  assert.equal(aggregate.toolchain.jobsReported, 1);
  assert.equal(aggregate.toolchain.llvmReinstalled, 1);
  assert.deepEqual(aggregate.toolchain.reasons, { "marker-missing": 1 });
});

test("collectMetrics fetches runs, jobs and logs through injected gh api", async () => {
  const calls = [];
  const ghApiJsonImpl = async (path) => {
    calls.push(path);
    if (path.includes("/runs?")) return { workflow_runs: [runFixture, { ...runFixture, id: 99, conclusion: "failure" }] };
    if (path.includes("/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const ghApiLogImpl = async (path) => {
    calls.push(path);
    return "Cache restored from key: toolchains-x\nLLVM cache valid:\n  version=22.1.8";
  };
  const { runs, aggregate } = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 5,
    includeLogs: true,
    ghApiJsonImpl,
    ghApiLogImpl,
  });
  assert.equal(runs.length, 1);
  assert.equal(runs[0].wallSeconds, 900);
  assert.equal(aggregate.toolchain.jobsReported, 2);
  assert.equal(aggregate.toolchain.llvmReused, 2);
  assert.ok(calls.some((path) => path.includes("/actions/jobs/1/logs")));
  assert.ok(calls.some((path) => path.includes("/actions/jobs/2/logs")));
});

test("formatMarkdown renders the KPI sections", () => {
  const run = collectRunMetrics(runFixture, jobsFixture);
  const aggregate = aggregateRuns([run]);
  const markdown = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-18T00:00:00Z",
    runs: [run],
    aggregate,
  });
  assert.match(markdown, /CI performance metrics/);
  assert.match(markdown, /workflow wall time/);
  assert.match(markdown, /OS別 runner time/);
  assert.match(markdown, /LLVM toolchain cache/);
  assert.match(markdown, /17m30s/);
});
