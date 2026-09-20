import assert from "node:assert/strict";
import { test } from "node:test";

import {
  aggregateRuns,
  cacheComparisonKey,
  cacheKeyRun,
  collectMetrics,
  collectRunMetrics,
  formatBytes,
  formatMarkdown,
  formatSeconds,
  isSameRunCacheKey,
  normalizeLogText,
  osFromJobName,
  parseCacheLog,
  parseToolchainLog,
  percentile,
  secondsBetween,
  summarize,
  summarizeCache,
} from "./collect_ci_metrics.mjs";

test("percentile and summarize compute median/p75/p90/p95", () => {
  const values = [10, 1, 5, 3, 8, 2, 9, 4, 7, 6];
  assert.equal(percentile(values, 50), 5.5);
  assert.equal(percentile(values, 100), 10);
  assert.equal(percentile([], 50), null);
  const summary = summarize(values);
  assert.equal(summary.count, 10);
  assert.equal(summary.median, 5.5);
  assert.equal(summary.p75, 7.75);
  assert.ok(Math.abs(summary.p95 - 9.55) < 1e-9);
  assert.equal(summary.min, 1);
  assert.equal(summary.max, 10);
  assert.equal(summarize([]).median, null);
  assert.equal(summarize([]).p75, null);
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

// run 35448509540 / Linux x86_64 AOT native shard 1/3 O0 の実log。
// 同一suiteのprefixを共有する別shardが保存したcacheを復元してしまい、
// 後続の保存がreservation競合で失敗した実測例である。
const linuxShardCacheLog = [
  "2026-09-19T14:30:58.9076181Z Attempting restore of Zig cache with prefix 'setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-'",
  "2026-09-19T14:30:59.7016938Z Cache hit (key 'setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-35448509540-1'): populating Zig cache directory at /home/runner/work/lnako/lnako/.zig-cache",
  "2026-09-19T14:31:07.8732988Z Cache hit for: toolchains-Linux-X64-v3-ee850565da26825639a975e71e7965fd549e3ff1241cd0bdad5795155d47d7c9",
  "2026-09-19T14:31:08.9699088Z Cache Size: ~189 MB (197923188 B)",
  "2026-09-19T14:31:08.9866320Z Cache restored from key: toolchains-Linux-X64-v3-ee850565da26825639a975e71e7965fd549e3ff1241cd0bdad5795155d47d7c9",
  "2026-09-19T14:35:02.2160923Z Cache directory is 253011854 bytes, below limit of 1610612736 bytes; keeping intact",
  "2026-09-19T14:35:02.2167124Z Saving Zig cache with key 'setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-35448509540-1'",
  "2026-09-19T14:35:03.1215943Z Failed to save: Unable to reserve cache with key setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-35448509540-1, another job may be creating this cache.",
].join("\n");

test("parseCacheLog detects a same-run Zig cache restore and the reservation failure", () => {
  const parsed = parseCacheLog(linuxShardCacheLog);
  assert.equal(parsed.zigCache.requestedPrefix, "setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-");
  assert.equal(parsed.zigCache.hit, true);
  assert.equal(parsed.zigCache.restoredKey, "setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-35448509540-1");
  assert.equal(parsed.zigCache.sizeBytes, 253011854);
  assert.equal(parsed.zigCache.limitBytes, 1610612736);
  assert.equal(parsed.zigCache.cleared, false);
  assert.equal(parsed.zigCache.saveOutcome, "failed");
  assert.match(parsed.zigCache.saveFailure, /another job may be creating this cache/);
  assert.equal(parsed.saveFailures, 1);
  assert.equal(parsed.cleared, 0);
  // actions/cacheのrestoreはkey・サイズごと記録され、Zig cacheと混ざらない。
  assert.deepEqual(parsed.restores.map((restore) => restore.key), [
    "toolchains-Linux-X64-v3-ee850565da26825639a975e71e7965fd549e3ff1241cd0bdad5795155d47d7c9",
  ]);
  assert.equal(parsed.restores[0].sizeBytes, 197923188);
  assert.deepEqual(parsed.misses, []);
  assert.equal(isSameRunCacheKey(parsed.zigCache.restoredKey, 35448509540), true);
  assert.equal(isSameRunCacheKey(parsed.zigCache.restoredKey, 35448509541), false);
  assert.deepEqual(cacheKeyRun(parsed.zigCache.restoredKey), { runId: 35448509540, attempt: 1 });
});

test("parseCacheLog detects Zig cache size-limit clear and save conflicts", () => {
  const cleared = parseCacheLog([
    "Attempting restore of Zig cache with prefix 'setup-zig-cache-v2-aot-zig-x86_64-windows-0.16.0-aot-native-v2-s0of3-O0-'",
    "Cache miss: leaving Zig cache directory at D:\\a\\lnako\\lnako\\.zig-cache unpopulated",
    "Cache directory reached 1932735283 bytes, exceeding limit of 1610612736 bytes; clearing cache",
    "Saving Zig cache with key 'setup-zig-cache-v2-aot-zig-x86_64-windows-0.16.0-aot-native-v2-s0of3-O0-1-1'",
  ].join("\n"));
  assert.equal(cleared.zigCache.hit, false);
  assert.equal(cleared.zigCache.cleared, true);
  assert.equal(cleared.zigCache.sizeBytes, 1932735283);
  assert.equal(cleared.zigCache.limitBytes, 1610612736);
  assert.equal(cleared.cleared, 1);
  // 保存行が無い場合は成功と断定しない（不明として記録する）。
  assert.equal(cleared.zigCache.saveOutcome, "unknown");

  const inaccessible = parseCacheLog([
    "Attempting restore of Zig cache with prefix 'setup-zig-cache-v2-aot_windows-zig-x86_64-windows-0.16.0-aot-native-'",
    "Cache miss: leaving Zig cache directory at D:\\a\\lnako\\lnako\\.zig-cache unpopulated",
    "Zig cache directory is inaccessible; nothing to save",
  ].join("\n"));
  assert.equal(inaccessible.zigCache.saveOutcome, "skipped");

  const noZigCache = parseCacheLog("unrelated output\n");
  assert.equal(noZigCache.zigCache, null);
  assert.deepEqual(noZigCache.restores, []);
});

test("parseCacheLog records actions/cache hits, misses and saves", () => {
  const parsed = parseCacheLog([
    "Cache hit for: nadesiko3-oracle-3.7.24-Windows-X64-ac3bedbf10111-v4",
    "Cache Size: ~2 MB (2341229 B)",
    "Cache restored successfully",
    "Cache restored from key: nadesiko3-oracle-3.7.24-Windows-X64-ac3bedbf10111-v4",
    "Cache not found for input keys: toolchains-Windows-X64-v3-abc, toolchains-Windows-X64-v3-def",
    "Adding to the cache ...",
    "Cache Size: ~102 MB (106745896 B)",
    "Cache saved with key: toolchains-Windows-X64-v3-abc",
    "Cache hit occurred on the primary key nadesiko3-oracle-3.7.24-Windows-X64-ac3bedbf10111-v4, not saving cache.",
    "Cache size of ~11000 MB (11534336000 B) is over the 10GB limit, not saving cache.",
  ].join("\n"));
  assert.deepEqual(parsed.restores, [
    { key: "nadesiko3-oracle-3.7.24-Windows-X64-ac3bedbf10111-v4", sizeBytes: 2341229 },
  ]);
  assert.deepEqual(parsed.misses, [
    { requestedKeys: ["toolchains-Windows-X64-v3-abc", "toolchains-Windows-X64-v3-def"] },
  ]);
  assert.deepEqual(parsed.saves, [
    { outcome: "saved", key: "toolchains-Windows-X64-v3-abc", sizeBytes: 106745896, failure: null },
    { outcome: "skipped-hit", key: "nadesiko3-oracle-3.7.24-Windows-X64-ac3bedbf10111-v4", sizeBytes: null, failure: null },
    { outcome: "failed", key: null, sizeBytes: null, failure: "size-over-10GB-limit" },
  ]);
  assert.equal(parsed.saveFailures, 1);
  assert.equal(parsed.zigCache, null);
});

test("summarizeCache stratifies job runtime by Zig cache hit and miss", () => {
  const parsed = parseCacheLog(linuxShardCacheLog);
  const aggregate = summarizeCache([
    { id: 1, runId: 35448509540, name: "Linux x86_64 / aot", seconds: 240, cache: parsed },
    {
      id: 2,
      runId: 35448509540,
      name: "Linux x86_64 / aot cold",
      seconds: 400,
      cache: {
        zigCache: { requestedPrefix: "p", restoredKey: null, hit: false, sizeBytes: 1000, limitBytes: 1610612736, cleared: true, saveKey: "k", saveOutcome: "saved", saveFailure: null },
        restores: [],
        misses: [{ requestedKeys: ["x"] }],
        saves: [],
        cleared: 1,
        saveFailures: 0,
      },
    },
  ]);
  assert.equal(aggregate.jobsReported, 2);
  assert.equal(aggregate.zigJobs, 2);
  assert.equal(aggregate.zigHits, 1);
  assert.equal(aggregate.zigMisses, 1);
  assert.equal(aggregate.zigSameRunRestores, 1);
  assert.equal(aggregate.zigCleared, 1);
  assert.equal(aggregate.zigSaved, 1);
  assert.equal(aggregate.zigSaveFailures, 1);
  assert.equal(aggregate.limitMiB, 1536);
  assert.equal(aggregate.coldWarm.hit.median, 240);
  assert.equal(aggregate.coldWarm.miss.median, 400);
  assert.equal(aggregate.misses, 1);
  assert.equal(aggregate.saveFailures, 1);
});

test("summarizeCache pairs cold and warm runs of the same job only", () => {
  const make = (hit, seconds, name, prefix) => ({
    id: 1,
    runId: 100,
    name,
    seconds,
    cache: {
      zigCache: { requestedPrefix: prefix, restoredKey: hit ? `k-100-1` : null, hit, sizeBytes: 1024, limitBytes: 1536 * 1024 * 1024, cleared: false, saveKey: "k", saveOutcome: "saved", saveFailure: null },
      restores: [],
      misses: [],
      saves: [],
      cleared: 0,
      saveFailures: 0,
    },
  });
  const aggregate = summarizeCache([
    // 同名jobがcold 400s / warm 200sを観測 → 差200s
    make(false, 400, "Linux x86_64 / core", "p-core-"),
    make(true, 200, "Linux x86_64 / core", "p-core-"),
    // 別suiteは同じ名前空間へ混ぜない
    make(false, 50, "Linux x86_64 / standard", "p-standard-"),
    // cold/warmの片方しか無いjobは対応表へ出さない
    make(true, 30, "Linux x86_64 / host", "p-host-"),
  ]);
  assert.equal(aggregate.pairedColdWarm.length, 1);
  assert.deepEqual(aggregate.pairedColdWarm[0], {
    name: "Linux x86_64 / core",
    coldRuns: 1,
    warmRuns: 1,
    coldMedianSeconds: 400,
    warmMedianSeconds: 200,
    deltaSeconds: 200,
  });
  // 層別の参考値は従来どおり全jobを対象にする。
  assert.equal(aggregate.coldWarm.miss.count, 2);
  assert.equal(aggregate.coldWarm.hit.count, 2);
  assert.equal(cacheComparisonKey(make(true, 1, "a", "p-")), "a|p-");
  assert.notEqual(cacheComparisonKey(make(true, 1, "a", "p-")), cacheComparisonKey(make(true, 1, "a", "q-")));
});

test("formatMarkdown renders the paired cold/warm table only when available", () => {
  const withPairs = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-19T00:00:00.000Z",
    runs: [],
    aggregate: {
      runCount: 1,
      wallTime: summarize([100]),
      queueTime: summarize([5]),
      jobCount: 1,
      runnerMinutesByOs: { linux: 1 },
      longestJobs: [],
      steps: [],
      toolchain: { jobsReported: 0, cacheHits: 0, cacheMisses: 0, llvmReinstalled: 0, llvmReused: 0, reasons: {} },
      cache: {
        jobsReported: 1, zigJobs: 1, zigHits: 1, zigMisses: 1, zigSameRunRestores: 0, zigCleared: 0,
        zigSaved: 1, zigSaveFailures: 0, zigSaveUnknown: 0, zigSizeBytes: summarize([1024]), limitMiB: 1536,
        restores: 0, misses: 0, saveFailures: 0,
        coldWarm: { hit: summarize([200]), miss: summarize([400]) },
        pairedColdWarm: [{ name: "Linux x86_64 / core", coldRuns: 1, warmRuns: 1, coldMedianSeconds: 400, warmMedianSeconds: 200, deltaSeconds: 200 }],
      },
    },
  });
  assert.match(withPairs, /cold\/warm対応表で判断する/);
  assert.match(withPairs, /\| Linux x86_64 \/ core \| 1 \| 1 \| 6m40s \| 3m20s \| 3m20s \|/);
  assert.match(withPairs, /prefixを分離した世代では0になる/);

  const withoutPairs = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-19T00:00:00.000Z",
    runs: [],
    aggregate: {
      runCount: 1, wallTime: summarize([100]), queueTime: summarize([5]), jobCount: 0,
      runnerMinutesByOs: {}, longestJobs: [], steps: [],
      toolchain: { jobsReported: 0, cacheHits: 0, cacheMisses: 0, llvmReinstalled: 0, llvmReused: 0, reasons: {} },
      cache: {
        jobsReported: 0, zigJobs: 0, zigHits: 0, zigMisses: 0, zigSameRunRestores: 0, zigCleared: 0,
        zigSaved: 0, zigSaveFailures: 0, zigSaveUnknown: 0, zigSizeBytes: summarize([]), limitMiB: null,
        restores: 0, misses: 0, saveFailures: 0,
        coldWarm: { hit: summarize([]), miss: summarize([]) },
        pairedColdWarm: [],
      },
    },
  });
  assert.doesNotMatch(withoutPairs, /^\| job（同名・同一prefix） \|/m);
  assert.match(withoutPairs, /対応表は出していない/);
  assert.match(withoutPairs, /\| Zig cache 上限 \| - \|/);
});

test("normalizeLogText strips ANSI escapes and timestamp prefixes", () => {
  const normalized = normalizeLogText("\u001b[36;1m2026-09-19T14:30:59.7016938Z Cache hit (key 'k')\u001b[0m\r\n");
  assert.equal(normalized, "Cache hit (key 'k')\n");
});

test("formatBytes renders MiB and KiB", () => {
  assert.equal(formatBytes(1610612736), "1536 MiB");
  assert.equal(formatBytes(253011854), "241 MiB");
  assert.equal(formatBytes(2048), "2 KiB");
  assert.equal(formatBytes(null), "-");
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

  // 旧シグネチャ（第4引数がdurationMsの数値）も近似wall timeへ退行せず受け付ける。
  assert.equal(collectRunMetrics(runFixture, jobsFixture, undefined, 900000).wallSeconds, 900);
  assert.equal(collectRunMetrics(runFixture, jobsFixture, new Map(), { durationMs: 600000 }).wallSeconds, 600);
  assert.equal(collectRunMetrics(runFixture, jobsFixture, undefined, 900000).jobs[0].seconds, 1050);

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

test("collectMetrics restricts the series to one branch when --branch is given", async () => {
  const calls = [];
  const ghApiJsonImpl = async (path) => {
    calls.push(path);
    if (path.includes("/runs?")) return { workflow_runs: [runFixture] };
    if (path.includes("/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    branch: "improve/ci",
    runCount: 5,
    includeLogs: false,
    ghApiJsonImpl,
  });
  // 他branchのrunが混ざると§10の系列比較が成立しないため、seriesはbranchで絞る。
  assert.ok(calls.some((path) => path.includes("/runs?") && path.includes("branch=improve%2Fci")));

  const withoutBranch = [];
  await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 1,
    includeLogs: false,
    ghApiJsonImpl: async (path) => {
      withoutBranch.push(path);
      if (path.includes("/runs?")) return { workflow_runs: [runFixture] };
      if (path.includes("/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
      if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
      throw new Error(`unexpected path: ${path}`);
    },
  });
  assert.ok(withoutBranch.some((path) => path.includes("/runs?") && !path.includes("branch=")));
});

test("collectMetricsは100件超のjobをページングで全件取得する", async () => {
  const page1Jobs = Array.from({ length: 100 }, (_, index) => ({ ...jobsFixture[0], id: 1000 + index, name: `job-${index}` }));
  const page2Jobs = Array.from({ length: 20 }, (_, index) => ({ ...jobsFixture[0], id: 2000 + index, name: `job-b-${index}` }));
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [runFixture] };
    if (path.includes("/jobs?")) {
      return path.includes("page=2")
        ? { total_count: 120, jobs: page2Jobs }
        : { total_count: 120, jobs: page1Jobs };
    }
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const { aggregate } = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 1,
    includeLogs: false,
    ghApiJsonImpl,
    ghApiLogImpl: async () => "",
  });
  assert.equal(aggregate.jobCount, 120);
});

test("formatSecondsは繰り上がりを分へ正しく伝播させる", () => {
  assert.equal(formatSeconds(119.6), "2m00s");
  assert.equal(formatSeconds(59.6), "1m00s");
  assert.equal(formatSeconds(59.4), "59s");
  assert.equal(formatSeconds(90), "1m30s");
  assert.equal(formatSeconds(5), "5s");
  assert.equal(formatSeconds(Number.NaN), "-");
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
  assert.match(markdown, /## Cache \(Zigグローバルcache \/ actions\/cache\)/);
  assert.match(markdown, /同一run保存cacheの復元/);
  assert.match(markdown, /17m30s/);
});
