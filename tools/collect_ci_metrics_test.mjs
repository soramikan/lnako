import assert from "node:assert/strict";
import { test } from "node:test";

import {
  aggregateRuns,
  cacheComparisonKey,
  cacheKeyRun,
  MAX_RUN_PAGES,
  RUNS_PAGE_SIZE,
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

test("collectMetricsはrun一覧をページングして構成一致runを探す", async () => {
  const legacyRuns = Array.from({ length: RUNS_PAGE_SIZE }, (_, index) => ({ ...runFixture, id: 1000 + index, created_at: "2026-09-18T01:00:00Z" }));
  const matchingRun = { ...runFixture, id: 2000, created_at: "2026-09-20T01:00:00Z" };
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) {
      // "per_page=100" が "page=1" を含むため、ページ番号は区切り付きで読む。
      const pageNumber = Number(path.match(/[?&]page=(\d+)/)[1]);
      if (pageNumber === 1) return { workflow_runs: legacyRuns };
      if (pageNumber === 2) return { workflow_runs: [matchingRun] };
      return { workflow_runs: [] };
    }
    if (path.includes("/jobs?")) {
      const runId = Number(path.match(/runs\/(\d+)\/jobs/)[1]);
      if (runId === matchingRun.id) return { total_count: jobsFixture.length, jobs: jobsFixture };
      return { total_count: jobsFixture.length + 1, jobs: [...jobsFixture, { ...jobsFixture[0], id: 9, name: "legacy-only" }] };
    }
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 1,
    expectedJobCount: jobsFixture.length,
    includeLogs: false,
    ghApiJsonImpl,
  });
  // 1ページ目が構成不一致でも探索を打ち切らず、2ページ目の一致runを採用する。
  assert.deepEqual(result.runs.map((run) => run.id), [matchingRun.id]);
  assert.equal(result.selection.skippedByJobCount.length, RUNS_PAGE_SIZE);
  assert.equal(result.selection.exploration, "exhausted");
  assert.equal(result.selection.unexplored, false);
});

test("collectMetricsは探索上限に達したら未探索を明示する", async () => {
  const page = Array.from({ length: RUNS_PAGE_SIZE }, (_, index) => ({ ...runFixture, id: 3000 + index, created_at: "2026-09-18T01:00:00Z" }));
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: page };
    if (path.includes("/jobs?")) return { total_count: jobsFixture.length + 1, jobs: [...jobsFixture, { ...jobsFixture[0], id: 9, name: "legacy-only" }] };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 1,
    expectedJobCount: jobsFixture.length,
    includeLogs: false,
    ghApiJsonImpl,
  });
  assert.equal(result.runs.length, 0);
  assert.equal(result.selection.exploration, "page-limit");
  assert.equal(result.selection.unexplored, true);
  assert.equal(result.selection.exploredRuns, RUNS_PAGE_SIZE * MAX_RUN_PAGES);
  const markdown = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-20T00:00:00Z",
    runs: result.runs,
    aggregate: result.aggregate,
    selection: result.selection,
  });
  assert.match(markdown, /探索上限（10ページ）に達したため、未探索のrunがあります/);
});

test("collectMetricsは構成の異なるrun（--jobs）を系列から除外し採用数を明示する", async () => {
  const currentRun = { ...runFixture, id: 200, created_at: "2026-09-20T01:00:00Z" };
  const legacyRun = { ...runFixture, id: 100, created_at: "2026-09-18T01:00:00Z" };
  const logs = [];
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [currentRun, legacyRun] };
    if (path.includes("/actions/runs/200/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
    if (path.includes("/actions/runs/100/jobs?")) {
      return { total_count: jobsFixture.length + 1, jobs: [...jobsFixture, { ...jobsFixture[0], id: 3, name: "legacy-only" }] };
    }
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 2,
    expectedJobCount: jobsFixture.length,
    includeLogs: false,
    ghApiJsonImpl,
    log: (message) => logs.push(message),
  });
  // 旧構成（job数の違うrun）は採用せず、要求数を穴埋めしない。
  assert.deepEqual(result.runs.map((run) => run.id), [200]);
  assert.equal(result.selection.adopted, 1);
  assert.equal(result.selection.requested, 2);
  assert.deepEqual(result.selection.skippedByJobCount, [{ id: 100, jobs: jobsFixture.length + 1 }]);
  assert.ok(logs.some((message) => message.includes("要求2 runに対し採用1 run")));

  const markdown = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-20T00:00:00Z",
    runs: result.runs,
    aggregate: result.aggregate,
    selection: result.selection,
  });
  assert.match(markdown, /系列フィルタ: branch=- \/ jobs=2 \/ since=- \/ require-job=-（要求2 run・採用1 run・探索2 run）/);
  assert.match(markdown, /構成の異なるrun 1件を除外/);
});

test("collectMetricsは部分再実行run（run_attempt>1）を系列から除外する", async () => {
  // 部分再実行runは再実行されなかったjobが前attemptの実行時刻のまま返り、
  // /timingのrun_duration_msは最新attemptしか指さないため、wall／runner minutes／
  // step統計が単一実行区間にならない（実測: run 35472553438はwall 6m18s・最長job 17m26s）。
  const rerunRun = { ...runFixture, id: 400, run_attempt: 2, created_at: "2026-09-20T02:00:00Z" };
  const freshRun = { ...runFixture, id: 500, run_attempt: 1, created_at: "2026-09-20T01:00:00Z" };
  const logs = [];
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [rerunRun, freshRun] };
    if (path.includes("/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 2,
    includeLogs: false,
    ghApiJsonImpl,
    log: (message) => logs.push(message),
  });
  assert.deepEqual(result.runs.map((run) => run.id), [freshRun.id]);
  assert.deepEqual(result.selection.skippedByAttempt, [{ id: rerunRun.id, attempt: 2 }]);
  assert.equal(result.runs[0].attempt, 1);
  assert.ok(logs.some((message) => message.includes("部分再実行runを除外: 1件")));
  assert.ok(!logs.some((message) => message.includes("構成の異なるrunを除外: 1件")), "部分再実行runを構成不一致として数えない");

  const markdown = formatMarkdown({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    generatedAt: "2026-09-20T00:00:00Z",
    runs: result.runs,
    aggregate: result.aggregate,
    selection: result.selection,
  });
  assert.match(markdown, /部分再実行run（run_attempt > 1）1件を除外/);
});

test("collectMetricsはfull実行でないrun（sentinel jobが未実行）を系列から除外する", async () => {
  // lightweight runはmatrix jobをskipしてもjob数がfullと同じ（skipも一覧へ出る）。
  // fullでだけ走るsentinel jobを必須にすることでfull実行だけを系列へ採用する。
  const lightweightRun = { ...runFixture, id: 800, created_at: "2026-09-20T03:00:00Z" };
  const fullRun = { ...runFixture, id: 900, created_at: "2026-09-20T02:00:00Z" };
  const sentinelName = "Verify native AOT artifacts";
  const fullJobs = [...jobsFixture, { ...jobsFixture[0], id: 30, name: sentinelName, conclusion: "success" }];
  const lightweightJobs = [...jobsFixture, { ...jobsFixture[0], id: 31, name: sentinelName, conclusion: "skipped" }];
  const logs = [];
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [lightweightRun, fullRun] };
    if (path.includes("/actions/runs/800/jobs?")) return { total_count: lightweightJobs.length, jobs: lightweightJobs };
    if (path.includes("/actions/runs/900/jobs?")) return { total_count: fullJobs.length, jobs: fullJobs };
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 2,
    expectedJobCount: fullJobs.length,
    requireJobs: [sentinelName],
    includeLogs: false,
    ghApiJsonImpl,
    log: (message) => logs.push(message),
  });
  assert.deepEqual(result.runs.map((run) => run.id), [fullRun.id]);
  assert.deepEqual(result.selection.skippedByRequiredJob, [{ id: lightweightRun.id, missing: [sentinelName] }]);
  assert.deepEqual(result.selection.requireJobs, [sentinelName]);
  assert.ok(logs.some((message) => message.includes("full実行でないrunを除外: 1件")));
});

test("collectMetricsは--since境界より古いrunが失敗続きでも探索を打ち切る", async () => {
  // 日時境界は成功状態・部分再実行より先に判定する。境界より古いrunが
  // 失敗・キャンセルばかりでも「境界到達」を認識できること（page-limitの誤報防止）。
  const recentRun = { ...runFixture, id: 1000, created_at: "2026-09-20T03:00:00Z" };
  const oldCancelled = { ...runFixture, id: 1100, created_at: "2026-09-19T03:00:00Z", conclusion: "cancelled" };
  const oldFailed = { ...runFixture, id: 1200, created_at: "2026-09-18T03:00:00Z", conclusion: "failure" };
  const logs = [];
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [recentRun, oldCancelled, oldFailed] };
    if (path.includes("/jobs?")) {
      return path.includes("/actions/runs/1000/") || path.includes("runs/1000")
        ? { total_count: jobsFixture.length, jobs: jobsFixture }
        : { total_count: 0, jobs: [] };
    }
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 3,
    since: "2026-09-20T00:00:00Z",
    includeLogs: false,
    ghApiJsonImpl,
    log: (message) => logs.push(message),
  });
  assert.deepEqual(result.runs.map((run) => run.id), [recentRun.id]);
  assert.equal(result.selection.exploration, "since");
  assert.equal(result.selection.unexplored, false);
});

test("collectMetricsは--sinceより前のrunを系列から除外する", async () => {
  const newer = { ...runFixture, id: 300, created_at: "2026-09-20T01:00:00Z" };
  const older = { ...runFixture, id: 100, created_at: "2026-09-18T01:00:00Z" };
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [newer, older] };
    if (path.includes("/jobs?")) return { total_count: jobsFixture.length, jobs: jobsFixture };
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 5,
    since: "2026-09-19T00:00:00Z",
    includeLogs: false,
    ghApiJsonImpl,
  });
  assert.deepEqual(result.runs.map((run) => run.id), [300]);
  assert.equal(result.selection.since, "2026-09-19T00:00:00Z");
  await assert.rejects(
    collectMetrics({ repo: "soramikan/lnako", workflow: "ci.yml", runCount: 1, since: "not-a-date", includeLogs: false, ghApiJsonImpl }),
    /--sinceにはISO8601/,
  );
});

test("collectRunMetricsはskipされたstepを統計から除外する", () => {
  // GitHubは実行しなかったstepも `conclusion: "skipped"` として返し、
  // started_at == completed_at（0秒）になる。除外しないとmedian/p95が歪む。
  const job = {
    id: 7,
    name: "Linux x86_64 / compat-aot",
    conclusion: "success",
    created_at: "2026-09-18T01:00:05Z",
    started_at: "2026-09-18T01:00:06Z",
    completed_at: "2026-09-18T01:08:00Z",
    steps: [
      { name: "Test QuickJS build", conclusion: "success", started_at: "2026-09-18T01:01:00Z", completed_at: "2026-09-18T01:05:00Z" },
      { name: "Differential interpreter test", conclusion: "skipped", started_at: "2026-09-18T01:05:00Z", completed_at: "2026-09-18T01:05:00Z" },
      { name: "Build QuickJS compiler", conclusion: "success", started_at: "2026-09-18T01:05:00Z", completed_at: "2026-09-18T01:07:30Z" },
    ],
  };
  const metrics = collectRunMetrics({ ...runFixture, id: 7 }, [job]);
  assert.deepEqual(metrics.jobs[0].steps.map((step) => step.name), ["Test QuickJS build", "Build QuickJS compiler"]);
  const aggregate = aggregateRuns([metrics]);
  assert.equal(aggregate.steps.every((step) => step.median > 0), true);
  const quickjs = aggregate.steps.find((step) => step.name === "Test QuickJS build");
  assert.equal(quickjs.count, 1);
  assert.equal(quickjs.median, 240);
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

test("collectMetricsはページング後も宣言件数に届かないrunを除外する", async () => {
  // jobs APIがtotal_count=47と言いながら46件しか返さない場合、そのrunの
  // runner minutes／最長job／step統計は欠落分だけ過少になる。宣言値では
  // なく実際の取得件数で構成判定し、不完全なrunは系列へ採用しない。
  const incompleteRun = { ...runFixture, id: 600 };
  const completeRun = { ...runFixture, id: 700 };
  const logs = [];
  const ghApiJsonImpl = async (path) => {
    if (path.includes("/runs?")) return { workflow_runs: [incompleteRun, completeRun] };
    if (path.includes("/actions/runs/600/jobs?")) {
      // 2ページ目は空で返し、宣言件数へ届かない状態を再現する。
      return path.includes("page=2")
        ? { total_count: jobsFixture.length + 1, jobs: [] }
        : { total_count: jobsFixture.length + 1, jobs: jobsFixture };
    }
    if (path.includes("/actions/runs/700/jobs?")) {
      return { total_count: jobsFixture.length, jobs: jobsFixture };
    }
    if (path.endsWith("/timing")) return { run_duration_ms: 900_000 };
    throw new Error(`unexpected path: ${path}`);
  };
  const result = await collectMetrics({
    repo: "soramikan/lnako",
    workflow: "ci.yml",
    runCount: 2,
    expectedJobCount: jobsFixture.length,
    includeLogs: false,
    ghApiJsonImpl,
    log: (message) => logs.push(message),
  });
  assert.deepEqual(result.runs.map((run) => run.id), [completeRun.id]);
  assert.deepEqual(result.selection.skippedByJobCount, [{ id: incompleteRun.id, jobs: jobsFixture.length }]);
  assert.ok(logs.some((message) => message.includes("ページング取得後も一部欠落のため除外")));
});

test("formatSecondsは負の差分も正しい絶対値で表示する", () => {
  // 差分（warm−cold）は負になり得る。符号を分離しないと-100秒が"-2m20s"になる。
  assert.equal(formatSeconds(-100), "-1m40s");
  assert.equal(formatSeconds(-59.4), "-59s");
  assert.equal(formatSeconds(-119.6), "-2m00s");
  assert.equal(formatSeconds(-5), "-5s");
  assert.equal(formatSeconds(-3600), "-60m00s");
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
