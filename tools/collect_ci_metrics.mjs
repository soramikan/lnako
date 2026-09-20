// CI performance metrics collector. Fetches completed workflow runs through
// the gh CLI and reports wall time, queue time, runner-minutes, per-step
// medians, and LLVM toolchain cache reuse. The pure functions are exported so
// tools/collect_ci_metrics_test.mjs can verify them without network access.
import { spawnSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const LLVM_SETUP_STEP = "Set up pinned LLVM and LLD";
export const TOOLCHAIN_CACHE_PATH = ".cache/toolchains";
export const SETUP_ZIG_STEP = "Run mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29";
export const ACTIONS_CACHE_STEP_PREFIX = "Run actions/cache@";
// 改善計画2 §10の系列収集でrun一覧を辿るページ幅と上限。
// 上限に達した場合は「未探索あり」を出力へ明示し、静かに取りこぼさない。
export const RUNS_PAGE_SIZE = 100;
export const MAX_RUN_PAGES = 10;

/**
 * GitHubのjob logは全行にtimestamp prefixが付き、ANSI escapeも含むため、
 * 行跨ぎのpatternを評価する前に正規化する。
 */
export function normalizeLogText(text) {
  return text
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "")
    .replace(/\r/g, "")
    .replace(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z /gm, "");
}

/**
 * Zigグローバルcache（mlugg/setup-zig）とactions/cacheの両方を解析する。
 *
 * - `zigCache`: setup-zigが管理するZig cacheの復元key・hit/miss・cache
 *   ディレクトリサイズ・上限・上限超過によるclear・保存結果
 * - `restores` / `misses` / `saves`: 同一job内の全cache操作（toolchain、
 *   oracle、Zig tarballを含む）の生イベント
 *
 * setup-zigは保存keyへrunId-attemptを付けてprefix一致で復元するため、
 * 復元されたkeyがこのrun自身のものであるかどうかもreportで判別できる。
 */
export function parseCacheLog(text) {
  const clean = normalizeLogText(text);
  const result = {
    zigCache: null,
    restores: [],
    misses: [],
    saves: [],
    cleared: 0,
    saveFailures: 0,
  };
  let pendingRestore = null;
  let pendingSave = null;
  for (const line of clean.split("\n")) {
    let match;
    if ((match = /^Attempting restore of Zig cache with prefix '([^']*)'$/.exec(line)) !== null) {
      result.zigCache = {
        requestedPrefix: match[1],
        restoredKey: null,
        hit: null,
        sizeBytes: null,
        limitBytes: null,
        cleared: null,
        saveKey: null,
        saveOutcome: null,
        saveFailure: null,
      };
      pendingRestore = null;
      continue;
    }
    if ((match = /^Cache hit \(key '([^']*)'\): populating Zig cache directory at /.exec(line)) !== null) {
      if (result.zigCache === null) continue;
      result.zigCache.hit = true;
      result.zigCache.restoredKey = match[1];
      continue;
    }
    if (/^Cache miss: leaving Zig cache directory at /.test(line)) {
      if (result.zigCache === null) continue;
      result.zigCache.hit = false;
      continue;
    }
    if ((match = /^Cache directory is (\d+) bytes, below limit of (\d+) bytes; keeping intact$/.exec(line)) !== null) {
      if (result.zigCache === null) continue;
      result.zigCache.sizeBytes = Number(match[1]);
      result.zigCache.limitBytes = Number(match[2]);
      result.zigCache.cleared = false;
      continue;
    }
    if ((match = /^Cache directory reached (\d+) bytes, exceeding limit of (\d+) bytes; clearing cache$/.exec(line)) !== null) {
      if (result.zigCache === null) continue;
      result.zigCache.sizeBytes = Number(match[1]);
      result.zigCache.limitBytes = Number(match[2]);
      result.zigCache.cleared = true;
      result.cleared += 1;
      continue;
    }
    if ((match = /^Saving Zig cache with key '([^']*)'$/.exec(line)) !== null) {
      if (result.zigCache === null) continue;
      result.zigCache.saveKey = match[1];
      pendingSave = { key: match[1], sizeBytes: null };
      continue;
    }
    if (/^Zig cache directory is inaccessible; nothing to save$/.test(line)) {
      if (result.zigCache !== null) result.zigCache.saveOutcome = "skipped";
      continue;
    }
    if ((match = /^Cache hit for: (.+)$/.exec(line)) !== null) {
      pendingRestore = { key: match[1].trim(), sizeBytes: null };
      result.restores.push(pendingRestore);
      continue;
    }
    if ((match = /^Cache restored from key: (.+)$/.exec(line)) !== null) {
      if (pendingRestore !== null && pendingRestore.key === "") pendingRestore.key = match[1].trim();
      else if (pendingRestore === null) {
        pendingRestore = { key: match[1].trim(), sizeBytes: null };
        result.restores.push(pendingRestore);
      }
      continue;
    }
    if ((match = /^Cache not found for (?:input )?keys?: (.+)$/.exec(line)) !== null) {
      result.misses.push({ requestedKeys: match[1].split(",").map((key) => key.trim()).filter((key) => key.length > 0) });
      pendingRestore = null;
      continue;
    }
    if ((match = /^Cache Size: ~\d+ MB \((\d+) B\)$/.exec(line)) !== null) {
      const sizeBytes = Number(match[1]);
      if (pendingRestore !== null && pendingRestore.sizeBytes === null) pendingRestore.sizeBytes = sizeBytes;
      else if (pendingSave !== null && pendingSave.sizeBytes === null) pendingSave.sizeBytes = sizeBytes;
      else if (result.zigCache !== null && result.zigCache.sizeBytes === null) result.zigCache.sizeBytes = sizeBytes;
      continue;
    }
    if ((match = /^Adding to the cache \.\.\.$/.exec(line)) !== null) {
      pendingSave = { key: null, sizeBytes: null };
      continue;
    }
    if ((match = /^Cache saved with key: (.+)$/.exec(line)) !== null) {
      const key = match[1].trim();
      result.saves.push({ outcome: "saved", key, sizeBytes: pendingSave?.sizeBytes ?? null, failure: null });
      pendingSave = null;
      continue;
    }
    if ((match = /^Cache hit occurred on the primary key (.+), not saving cache\.$/.exec(line)) !== null) {
      result.saves.push({ outcome: "skipped-hit", key: match[1].trim(), sizeBytes: null, failure: null });
      pendingSave = null;
      continue;
    }
    if ((match = /^Cache size of ~\d+ MB \(\d+ B\) is over the (.+), not saving cache\.$/.exec(line)) !== null) {
      result.saves.push({ outcome: "failed", key: pendingSave?.key ?? null, sizeBytes: pendingSave?.sizeBytes ?? null, failure: `size-over-${match[1].replaceAll(" ", "-")}` });
      result.saveFailures += 1;
      pendingSave = null;
      continue;
    }
    if ((match = /^(?:Failed to save|Failed to reserve cache|Cache reservation failed): (.+)$/.exec(line)) !== null) {
      result.saves.push({ outcome: "failed", key: pendingSave?.key ?? null, sizeBytes: pendingSave?.sizeBytes ?? null, failure: match[1].trim() });
      result.saveFailures += 1;
      pendingSave = null;
      continue;
    }
  }
  if (result.zigCache !== null && result.zigCache.saveKey !== null && result.zigCache.saveOutcome === null) {
    const matching = result.saves.find((save) => save.key === result.zigCache.saveKey);
    result.zigCache.saveOutcome = matching?.outcome ?? "unknown";
    result.zigCache.saveFailure = matching?.failure ?? null;
  }
  return result;
}

/**
 * setup-zigは保存keyへ `runId-attempt` を付ける。復元keyからrun idを取り出せば、
 * 「同一runの別jobが保存したcacheを復元した」＝未完成cacheの巻き込みを検出できる。
 */
export function cacheKeyRun(key) {
  const match = /-(\d+)-(\d+)$/.exec(typeof key === "string" ? key : "");
  return match === null ? null : { runId: Number(match[1]), attempt: Number(match[2]) };
}

export function isSameRunCacheKey(key, runId) {
  const parsed = cacheKeyRun(key);
  return parsed !== null && Number.isSafeInteger(runId) && parsed.runId === runId;
}

export function secondsBetween(startedAt, completedAt) {
  return (Date.parse(completedAt) - Date.parse(startedAt)) / 1000;
}

export function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 1) return sorted[0];
  const rank = (p / 100) * (sorted.length - 1);
  const lower = Math.floor(rank);
  const upper = Math.ceil(rank);
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower);
}

export function summarize(values) {
  const clean = values.filter((value) => Number.isFinite(value));
  if (clean.length === 0) return { count: 0, min: null, median: null, p75: null, p90: null, p95: null, max: null, mean: null };
  return {
    count: clean.length,
    min: Math.min(...clean),
    median: percentile(clean, 50),
    // 改善計画2 §10はmedian/p75/p90/p95の蓄積を求めるためp75も出す。
    p75: percentile(clean, 75),
    p90: percentile(clean, 90),
    p95: percentile(clean, 95),
    max: Math.max(...clean),
    mean: clean.reduce((total, value) => total + value, 0) / clean.length,
  };
}

export function osFromJobName(name) {
  if (/^macOS/.test(name)) return "macOS";
  if (/^Windows/.test(name)) return "Windows";
  if (/^Linux/.test(name)) return "Linux";
  return "other";
}

/**
 * Parse the log of one job and report the toolchain cache outcome.
 * `cacheHit` is true only when the actions/cache restore reported a hit for
 * the .cache/toolchains entry. `llvmReinstalled` is true when setup_llvm.mjs
 * ran a full install (download or libLLVM-C relink).
 */
export function parseToolchainLog(text) {
  const clean = normalizeLogText(text);
  const result = { cacheHit: null, llvmReinstalled: null, llvmReason: null };
  if (/Cache restored from key: toolchains-/.test(clean) || /Cache hit for: toolchains-/.test(clean)) result.cacheHit = true;
  if (/Cache not found for (?:input )?keys?:[^\n]*toolchains-|Cache miss[^\n]*toolchains-/.test(clean)) result.cacheHit = false;
  const invalid = /LLVM cache invalid:\s*\n\s*reason=([a-z-]+)/.exec(clean);
  if (invalid) {
    result.llvmReinstalled = true;
    result.llvmReason = invalid[1];
  } else if (/LLVM cache valid:/.test(clean)) {
    result.llvmReinstalled = false;
  } else if (/LLVM \d+\.\d+\.\d+をセットアップします/.test(clean)) {
    // Logs from before the reason classification was added.
    result.llvmReinstalled = true;
    result.llvmReason = "unknown";
  }
  return result;
}

export function collectRunMetrics(run, jobs, toolchainByJob = new Map(), options = {}) {
  // 旧シグネチャは第4引数がdurationMsの数値だった。数値を渡すと分割代入は
  // 黙って成立しdurationMs=nullへ退行して近似wall timeを返すため正規化する。
  const resolved = typeof options === "number" ? { durationMs: options } : options;
  const { durationMs = null, cacheByJob = new Map() } = resolved;
  const jobMetrics = jobs.map((job) => {
    // GitHubは実行されなかったstepも`conclusion: "skipped"`として返し、
    // そのstarted_atとcompleted_atは同時刻（0秒）になる。除外しないと
    // §10のstep統計（median/p75/p90/p95）が0秒の観測で薄まり、
    // 例: `Test QuickJS build` がmedian 0s・p95 384s のように歪む。
    const steps = (job.steps ?? [])
      .filter((step) => step.conclusion !== "skipped")
      .filter((step) => step.started_at && step.completed_at)
      .map((step) => ({ name: step.name, seconds: secondsBetween(step.started_at, step.completed_at) }));
    return {
      name: job.name,
      os: osFromJobName(job.name),
      conclusion: job.conclusion,
      runId: run.id,
      seconds: job.started_at && job.completed_at ? secondsBetween(job.started_at, job.completed_at) : null,
      queueSeconds: job.started_at && job.created_at ? secondsBetween(job.created_at, job.started_at) : null,
      steps,
      toolchain: toolchainByJob.get(job.id) ?? null,
      cache: cacheByJob.get(job.id) ?? null,
    };
  });
  return {
    id: run.id,
    event: run.event,
    attempt: run.run_attempt ?? 1,
    conclusion: run.conclusion,
    headBranch: run.head_branch,
    createdAt: run.created_at,
    // /actions/runs/{id}/timing のrun_duration_msは実実行区間。
    // 取れない場合はcreated→updatedの近似へfallbackする。
    wallSeconds: Number.isFinite(durationMs) ? durationMs / 1000 : secondsBetween(run.created_at, run.updated_at),
    queueSeconds: run.run_started_at ? secondsBetween(run.created_at, run.run_started_at) : null,
    jobs: jobMetrics,
  };
}

export function aggregateRuns(runMetrics) {
  const allJobs = runMetrics.flatMap((run) => run.jobs);
  const runnerSecondsByOs = new Map();
  for (const job of allJobs) {
    if (!Number.isFinite(job.seconds)) continue;
    runnerSecondsByOs.set(job.os, (runnerSecondsByOs.get(job.os) ?? 0) + job.seconds);
  }
  const jobByName = new Map();
  for (const job of allJobs) {
    if (!Number.isFinite(job.seconds)) continue;
    const list = jobByName.get(job.name) ?? [];
    list.push(job.seconds);
    jobByName.set(job.name, list);
  }
  const longestJobs = [...jobByName.entries()]
    .map(([name, values]) => ({ name, ...summarize(values) }))
    .sort((left, right) => (right.median ?? 0) - (left.median ?? 0));
  const stepByName = new Map();
  for (const job of allJobs) {
    for (const step of job.steps) {
      const list = stepByName.get(step.name) ?? [];
      list.push(step.seconds);
      stepByName.set(step.name, list);
    }
  }
  const steps = [...stepByName.entries()]
    .map(([name, values]) => ({ name, ...summarize(values) }))
    .sort((left, right) => (right.median ?? 0) - (left.median ?? 0));
  const toolchainJobs = allJobs.filter((job) => job.toolchain !== null);
  return {
    runCount: runMetrics.length,
    wallTime: summarize(runMetrics.map((run) => run.wallSeconds)),
    queueTime: summarize(runMetrics.map((run) => run.queueSeconds)),
    jobCount: allJobs.length,
    runnerMinutesByOs: Object.fromEntries([...runnerSecondsByOs.entries()].map(([os, seconds]) => [os, seconds / 60])),
    longestJobs,
    steps,
    toolchain: {
      jobsReported: toolchainJobs.length,
      cacheHits: toolchainJobs.filter((job) => job.toolchain.cacheHit === true).length,
      cacheMisses: toolchainJobs.filter((job) => job.toolchain.cacheHit === false).length,
      llvmReinstalled: toolchainJobs.filter((job) => job.toolchain.llvmReinstalled === true).length,
      llvmReused: toolchainJobs.filter((job) => job.toolchain.llvmReinstalled === false).length,
      reasons: toolchainJobs.reduce((reasons, job) => {
        if (job.toolchain.llvmReason) reasons[job.toolchain.llvmReason] = (reasons[job.toolchain.llvmReason] ?? 0) + 1;
        return reasons;
      }, {}),
    },
    cache: summarizeCache(allJobs.filter((job) => job.cache !== null)),
  };
}

/**
 * 同名jobをrun横断で同一視するためのkey。
 * Zig cacheのcold/warmはjob種別ごとに比較しないと意味がない
 * （matrixの別suite・別shardを混ぜると差がcache以外の要因で決まる）。
 */
export function cacheComparisonKey(job) {
  return `${job.name}|${job.cache.zigCache?.requestedPrefix ?? ""}`;
}

/**
 * Zigグローバルcacheとactions/cacheの実測をjob横断で集計する。
 * `coldWarm` は同名job（同一prefix）のうち、coldなrunとwarmなrunの
 * job実行時間を層別した値である。matrixの別suiteを混ぜないため、
 * cacheの効果だけを比較できる。
 */
export function summarizeCache(cacheJobs) {
  const zigJobs = cacheJobs.filter((job) => job.cache.zigCache !== null);
  const zigCache = (job) => job.cache.zigCache;
  const outcome = (job) => zigCache(job).saveOutcome;
  const byHit = (hit) => summarize(zigJobs.filter((job) => zigCache(job).hit === hit).map((job) => job.seconds));
  const limits = zigJobs.map((job) => zigCache(job).limitBytes).filter((value) => Number.isFinite(value));
  const sameRunRestores = zigJobs.filter((job) => isSameRunCacheKey(zigCache(job).restoredKey, job.runId)).length;
  // 同名jobが複数runでcold/warm両方を観測した場合だけ、その差を出す。
  const byJob = new Map();
  for (const job of zigJobs) {
    const key = cacheComparisonKey(job);
    const entry = byJob.get(key) ?? { name: job.name, cold: [], warm: [] };
    if (zigCache(job).hit === true) entry.warm.push(job.seconds);
    else if (zigCache(job).hit === false) entry.cold.push(job.seconds);
    byJob.set(key, entry);
  }
  const paired = [...byJob.values()]
    .filter((entry) => entry.cold.length > 0 && entry.warm.length > 0)
    .map((entry) => {
      const coldMedian = summarize(entry.cold).median;
      const warmMedian = summarize(entry.warm).median;
      return {
        name: entry.name,
        coldRuns: entry.cold.length,
        warmRuns: entry.warm.length,
        coldMedianSeconds: coldMedian,
        warmMedianSeconds: warmMedian,
        deltaSeconds: coldMedian === null || warmMedian === null ? null : coldMedian - warmMedian,
      };
    })
    .sort((left, right) => (right.deltaSeconds ?? 0) - (left.deltaSeconds ?? 0));
  return {
    jobsReported: cacheJobs.length,
    zigJobs: zigJobs.length,
    zigHits: zigJobs.filter((job) => zigCache(job).hit === true).length,
    zigMisses: zigJobs.filter((job) => zigCache(job).hit === false).length,
    zigSameRunRestores: sameRunRestores,
    zigCleared: zigJobs.filter((job) => zigCache(job).cleared === true).length,
    zigSaved: zigJobs.filter((job) => outcome(job) === "saved").length,
    zigSaveFailures: zigJobs.filter((job) => outcome(job) === "failed").length,
    zigSaveUnknown: zigJobs.filter((job) => outcome(job) === "unknown").length,
    zigSizeBytes: summarize(zigJobs.map((job) => zigCache(job).sizeBytes)),
    limitMiB: limits.length === 0 ? null : Math.max(...limits) / (1024 * 1024),
    restores: cacheJobs.reduce((total, job) => total + job.cache.restores.length, 0),
    misses: cacheJobs.reduce((total, job) => total + job.cache.misses.length, 0),
    saveFailures: cacheJobs.reduce((total, job) => total + job.cache.saveFailures, 0),
    coldWarm: { hit: byHit(true), miss: byHit(false) },
    pairedColdWarm: paired,
  };
}

export function formatMarkdown({ repo, workflow, generatedAt, runs, aggregate, selection = null }) {
  const lines = [
    "# CI performance metrics",
    "",
    `対象: ${repo} / workflow: ${workflow}`,
    `生成: ${generatedAt}`,
    `分析run数: ${aggregate.runCount}（成功した完了runのみ）`,
    ...(selection === null ? [] : [`系列フィルタ: branch=${selection.branch ?? "-"} / jobs=${selection.expectedJobCount ?? "-"} / since=${selection.since ?? "-"} / require-job=${(selection.requireJobs ?? []).join(",") || "-"}（要求${selection.requested} run・採用${selection.adopted} run・探索${selection.exploredRuns ?? "-"} run）`]),
    ...(selection !== null && selection.adopted < selection.requested
      ? (() => {
        const reasons = [
          ["構成の異なるrun", selection.skippedByJobCount.length],
          ["部分再実行run", (selection.skippedByAttempt ?? []).length],
          ["full実行でないrun", (selection.skippedByRequiredJob ?? []).length],
        ].filter(([, count]) => count > 0).map(([label, count]) => `${label} ${count}件`);
        const detail = reasons.length > 0 ? `${reasons.join("・")}を除外した` : "対象runが尽きた";
        return [`注意: ${detail}ため、採用run数が要求${selection.requested}に達していません（旧構成で穴埋めしない）。`];
      })()
      : []),
    ...(selection !== null && (selection.skippedByAttempt ?? []).length > 0
      ? [`注意: 部分再実行run（run_attempt > 1）${selection.skippedByAttempt.length}件を除外しました。再実行されなかったjobは前attemptの実行時刻のまま返り、/timingのrun_duration_msは最新attemptしか指さないため、wall／runner minutes／step統計が単一の実行区間になりません。`]
      : []),
    ...(selection !== null && selection.unexplored === true
      ? [`注意: run一覧の探索上限（${MAX_RUN_PAGES}ページ）に達したため、未探索のrunがあります。採用数とpercentileは不完全です。`]
      : []),
    "",
    "## 対象run",
    "",
    "| run id | event | branch | wall time | queue | jobs |",
    "| --- | --- | --- | ---: | ---: | ---: |",
    ...runs.map((run) => `| ${run.id} | ${run.event} | ${run.headBranch} | ${formatSeconds(run.wallSeconds)} | ${formatSeconds(run.queueSeconds)} | ${run.jobs.length} |`),
    "",
    "## Wall time",
    "",
    "| metric | median | p75 | p90 | p95 | min | max |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    `| workflow wall time | ${formatSeconds(aggregate.wallTime.median)} | ${formatSeconds(aggregate.wallTime.p75)} | ${formatSeconds(aggregate.wallTime.p90)} | ${formatSeconds(aggregate.wallTime.p95)} | ${formatSeconds(aggregate.wallTime.min)} | ${formatSeconds(aggregate.wallTime.max)} |`,
    `| job queue time | ${formatSeconds(aggregate.queueTime.median)} | ${formatSeconds(aggregate.queueTime.p75)} | ${formatSeconds(aggregate.queueTime.p90)} | ${formatSeconds(aggregate.queueTime.p95)} | ${formatSeconds(aggregate.queueTime.min)} | ${formatSeconds(aggregate.queueTime.max)} |`,
    "",
    "## OS別 runner time（分析run合計）",
    "",
    "| OS | runner-minutes |",
    "| --- | ---: |",
    ...Object.entries(aggregate.runnerMinutesByOs).map(([os, minutes]) => `| ${os} | ${minutes.toFixed(1)} |`),
    `| **total** | **${Object.values(aggregate.runnerMinutesByOs).reduce((a, b) => a + b, 0).toFixed(1)}** |`,
    "",
    "## 最長job（median上位10）",
    "",
    "| job | median | p75 | p95 |",
    "| --- | ---: | ---: | ---: |",
    ...aggregate.longestJobs.slice(0, 10).map((job) => `| ${job.name} | ${formatSeconds(job.median)} | ${formatSeconds(job.p75)} | ${formatSeconds(job.p95)} |`),
    "",
    "## 主要step（median上位15）",
    "",
    "| step | count | median | p75 | p95 |",
    "| --- | ---: | ---: | ---: | ---: |",
    ...aggregate.steps.slice(0, 15).map((step) => `| ${step.name} | ${step.count} | ${formatSeconds(step.median)} | ${formatSeconds(step.p75)} | ${formatSeconds(step.p95)} |`),
    "",
    "## LLVM toolchain cache",
    "",
    `計測job数: ${aggregate.toolchain.jobsReported}`,
    "",
    "| metric | value |",
    "| --- | ---: |",
    `| cache hit | ${aggregate.toolchain.cacheHits} |`,
    `| cache miss | ${aggregate.toolchain.cacheMisses} |`,
    `| LLVM reinstall | ${aggregate.toolchain.llvmReinstalled} |`,
    `| LLVM reuse | ${aggregate.toolchain.llvmReused} |`,
    "",
    `reason内訳: ${Object.entries(aggregate.toolchain.reasons).map(([reason, count]) => `${reason}=${count}`).join(", ") || "なし"}`,
    "",
    "## Cache (Zigグローバルcache / actions/cache)",
    "",
    `計測job数: ${aggregate.cache.jobsReported}（うちZig cache管理job: ${aggregate.cache.zigJobs}）`,
    "",
    "| metric | value |",
    "| --- | ---: |",
    `| Zig cache hit | ${aggregate.cache.zigHits} |`,
    `| Zig cache miss | ${aggregate.cache.zigMisses} |`,
    `| 同一run保存cacheの復元 | ${aggregate.cache.zigSameRunRestores} |`,
    `| Zig cache 保存成功 | ${aggregate.cache.zigSaved} |`,
    `| Zig cache 保存失敗 | ${aggregate.cache.zigSaveFailures} |`,
    `| Zig cache 保存結果不明 | ${aggregate.cache.zigSaveUnknown} |`,
    `| Zig cache size limit超過によるclear | ${aggregate.cache.zigCleared} |`,
    `| Zig cache 上限 | ${aggregate.cache.limitMiB === null ? "-" : `${aggregate.cache.limitMiB.toFixed(0)} MiB`} |`,
    `| Zig cache directory size median | ${formatBytes(aggregate.cache.zigSizeBytes.median)} |`,
    `| Zig cache directory size max | ${formatBytes(aggregate.cache.zigSizeBytes.max)} |`,
    `| actions/cache restore | ${aggregate.cache.restores} |`,
    `| actions/cache miss | ${aggregate.cache.misses} |`,
    `| actions/cache 保存失敗 | ${aggregate.cache.saveFailures} |`,
    "",
    "| Zig cache | job数 | job実行時間 median | p90 |",
    "| --- | ---: | ---: | ---: |",
    `| hit（warm） | ${aggregate.cache.coldWarm.hit.count} | ${formatSeconds(aggregate.cache.coldWarm.hit.median)} | ${formatSeconds(aggregate.cache.coldWarm.hit.p90)} |`,
    `| miss（cold） | ${aggregate.cache.coldWarm.miss.count} | ${formatSeconds(aggregate.cache.coldWarm.miss.median)} | ${formatSeconds(aggregate.cache.coldWarm.miss.p90)} |`,
    "",
    "上の表はmatrixの別suite・別shardを混ぜた参考値である。cacheの効果は",
    "同名job（同一prefix）のcold/warm対応表で判断する。",
    "",
  ];
  if (aggregate.cache.pairedColdWarm.length > 0) {
    lines.push(
      "| job（同名・同一prefix） | cold run数 | warm run数 | cold median | warm median | 短縮 |",
      "| --- | ---: | ---: | ---: | ---: | ---: |",
      ...aggregate.cache.pairedColdWarm.map((entry) =>
        `| ${entry.name} | ${entry.coldRuns} | ${entry.warmRuns} | ${formatSeconds(entry.coldMedianSeconds)} | ${formatSeconds(entry.warmMedianSeconds)} | ${formatSeconds(entry.deltaSeconds)} |`),
      "",
    );
  } else {
    lines.push(
      "同名jobがcold/warm両方を観測したrunがまだ無いため、対応表は出していない。",
      "",
    );
  }
  lines.push(
    "同一run保存cacheの復元は、同一prefixを共有する並行jobが保存した未完成cacheを",
    "復元した回数である。prefixを分離した世代では0になる。",
    "",
  );
  return `${lines.join("\n")}\n`;
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "-";
  const mib = bytes / (1024 * 1024);
  return mib >= 1 ? `${mib.toFixed(0)} MiB` : `${Math.round(bytes / 1024)} KiB`;
}

export function formatSeconds(seconds) {
  if (!Number.isFinite(seconds)) return "-";
  const roundedSeconds = Math.round(seconds);
  const minutes = Math.floor(roundedSeconds / 60);
  const rest = roundedSeconds % 60;
  return minutes > 0 ? `${minutes}m${String(rest).padStart(2, "0")}s` : `${rest}s`;
}

export async function ghApi(path) {
  const result = spawnSync("gh", ["api", path], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`gh api ${path} が失敗しました:\n${result.stderr}`);
  return result.stdout;
}

export async function ghApiJson(path) {
  return JSON.parse(await ghApi(path));
}

export async function ghApiLog(path) {
  const result = spawnSync("gh", ["api", path, "--allow-escape-sequences"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`gh api ${path} が失敗しました:\n${result.stderr}`);
  return result.stdout;
}

export async function collectMetrics({ repo, workflow, runCount, branch = null, expectedJobCount = null, since = null, requireJobs = [], includeLogs, ghApiJsonImpl = ghApiJson, ghApiLogImpl = ghApiLog, log = () => {} }) {
  // 改善計画2 §10は同一系列でmedian/p75/p90/p95を蓄積する。branchだけでは
  // 同一branch内の構成変更（job数の違う旧run）を区別できず、`--runs 30`が
  // 旧構成の値を現行構成のpercentileへ混ぜてしまう。そのため構成境界
  // （--jobs＝期待job数、--since＝開始日時）でも絞り、要求run数に達しない場合は
  // 旧構成で穴埋めせず採用数を明示する。
  const sinceMs = since === null ? null : Date.parse(since);
  if (since !== null && Number.isNaN(sinceMs)) throw new Error("--sinceにはISO8601の日時（例: 2026-09-20T00:00:00Z）を指定してください");
  const branchQuery = branch === null ? "" : `&branch=${encodeURIComponent(branch)}`;
  const collected = [];
  const skippedByJobCount = [];
  const skippedByAttempt = [];
  const skippedByRequiredJob = [];
  // 構成フィルタで採用が少なくなるとき、1ページだけで探索を打ち切ると
  // 範囲外にある一致runを取りこぼす。採用数が要求へ達するか候補が尽きるまで
  // run一覧をページングする（上限に達した場合は未探索があることを報告する）。
  let runsPage = 1;
  let exploredRuns = 0;
  let exploration = "exhausted";
  for (; collected.length < runCount && runsPage <= MAX_RUN_PAGES; runsPage += 1) {
    const response = await ghApiJsonImpl(`repos/${repo}/actions/workflows/${workflow}/runs?per_page=${RUNS_PAGE_SIZE}&page=${runsPage}&status=completed${branchQuery}`);
    const pageRuns = response.workflow_runs ?? [];
    exploredRuns += pageRuns.length;
    if (pageRuns.length === 0) {
      exploration = "exhausted";
      break;
    }
    let reachedSince = false;
    for (const run of pageRuns) {
      if (collected.length >= runCount) break;
      // run一覧は新しい順なので、--sinceより古いrunに達したら以降も対象外。
      // 日時境界はrunの成功状態や部分再実行より先に判定する。成功runだけを見て
      // から境界を判定すると、境界より古いrunが失敗・キャンセルばかりのときに
      // 境界到達を認識できず、候補が尽きているのに探索上限（未探索あり）と
      // 誤って報告してしまう。
      if (sinceMs !== null && Date.parse(run.created_at) < sinceMs) {
        reachedSince = true;
        break;
      }
      if (run.conclusion !== "success") continue;
      // 部分再実行（run_attempt > 1）のrunは、再実行されなかったjobが前attemptの
      // started_at/completed_atのまま返り、job一覧がattempt間で混在する。一方
      // /timingのrun_duration_msは最新attemptしか指さないため、wall／runner
      // minutes／step統計が単一の実行区間にならず、jobがrunより長い観測になる
      // （実測: run 35472553438はwall 6m18s・最長job 17m26s）。再現できる観測では
      // ないため系列から除外する。
      if (Number.isSafeInteger(run.run_attempt) && run.run_attempt > 1) {
        skippedByAttempt.push({ id: run.id, attempt: run.run_attempt });
        continue;
      }
      const jobs = [];
      let jobsTotal = null;
      for (let page = 1; ; page += 1) {
        const jobsResponse = await ghApiJsonImpl(`repos/${repo}/actions/runs/${run.id}/jobs?per_page=100&page=${page}`);
        const pageJobs = jobsResponse.jobs ?? [];
        jobs.push(...pageJobs);
        jobsTotal = jobsResponse.total_count ?? jobsTotal;
        if (pageJobs.length === 0 || (Number.isSafeInteger(jobsTotal) && jobs.length >= jobsTotal)) break;
      }
      if (Number.isSafeInteger(jobsTotal) && jobsTotal > jobs.length) {
        // ページング後もjobs APIが宣言した件数へ届かないrunは、job一覧が不完全で
        // runner minutes／最長job／step統計が欠落分だけ過少になる。宣言値では
        // なく実際に取得できた件数で構成判定するため、ここで系列から除外する。
        log(`run ${run.id}: jobs ${jobs.length}/${jobsTotal}（ページング取得後も一部欠落のため除外）`);
        skippedByJobCount.push({ id: run.id, jobs: jobs.length });
        continue;
      }
      if (expectedJobCount !== null && jobs.length !== expectedJobCount) {
        skippedByJobCount.push({ id: run.id, jobs: jobs.length });
        continue;
      }
      // lightweight runはmatrixをskipしてもjob数がfullと変わらない（skipされた
      // jobも一覧へ出る）ため、job数だけではfull runと区別できない。fullでだけ
      // 実行されるsentinel job（例: `Verify native AOT artifacts`）を必須にし、
      // それがsuccessでないrunはfull実行ではないとして系列から除外する。
      if (requireJobs.length > 0) {
        const byName = new Map(jobs.map((job) => [job.name, job]));
        const missing = requireJobs.filter((name) => {
          const job = byName.get(name);
          return !job || job.conclusion !== "success";
        });
        if (missing.length > 0) {
          skippedByRequiredJob.push({ id: run.id, missing });
          continue;
        }
      }
      await adoptRun(run, jobs);
    }
    if (reachedSince) {
      exploration = "since";
      break;
    }
    if (pageRuns.length < RUNS_PAGE_SIZE) {
      exploration = "exhausted";
      break;
    }
  }
  if (collected.length < runCount && runsPage > MAX_RUN_PAGES) exploration = "page-limit";

  // 採用runの計測（job一覧は取得済み。ログ解析は必要時のみ）。
  async function adoptRun(run, jobs) {
    const timing = await ghApiJsonImpl(`repos/${repo}/actions/runs/${run.id}/timing`).catch(() => null);
    const toolchainByJob = new Map();
    const cacheByJob = new Map();
    if (includeLogs) {
      for (const job of jobs) {
        const stepNames = (job.steps ?? []).map((step) => step.name);
        const hasToolchain = stepNames.includes(LLVM_SETUP_STEP);
        const hasCache = stepNames.includes(SETUP_ZIG_STEP) ||
          stepNames.some((name) => name.startsWith(ACTIONS_CACHE_STEP_PREFIX) || name.startsWith(`Post ${ACTIONS_CACHE_STEP_PREFIX}`));
        if (!hasToolchain && !hasCache) continue;
        let text;
        try {
          text = await ghApiLogImpl(`repos/${repo}/actions/jobs/${job.id}/logs`);
        } catch (error) {
          log(`job ${job.id} (${job.name})のlog取得に失敗しました: ${error.message}`);
          continue;
        }
        if (hasToolchain) toolchainByJob.set(job.id, parseToolchainLog(text));
        if (hasCache) cacheByJob.set(job.id, parseCacheLog(text));
      }
    }
    collected.push(collectRunMetrics(run, jobs, toolchainByJob, { durationMs: timing?.run_duration_ms, cacheByJob }));
    log(`run ${run.id}: ${jobs.length} jobs`);
  }
  const selection = {
    branch,
    expectedJobCount,
    since,
    requested: runCount,
    adopted: collected.length,
    // 構成の異なるrunは採用しない（旧構成で要求数を穴埋めしない）。
    skippedByJobCount,
    // 部分再実行runはattempt混在で単一実行区間にならないため採用しない。
    skippedByAttempt,
    // full実行でないrun（lightweight等）はsentinel jobがsuccessでないため採用しない。
    skippedByRequiredJob,
    requireJobs,
    exploredRuns,
    // "since"=境界到達, "exhausted"=候補尽き, "page-limit"=探索上限で未探索あり。
    exploration,
    unexplored: exploration === "page-limit",
  };
  if (collected.length < runCount) {
    log(`要求${runCount} runに対し採用${collected.length} run（構成の異なるrunを除外: ${skippedByJobCount.length}件・部分再実行runを除外: ${skippedByAttempt.length}件・full実行でないrunを除外: ${skippedByRequiredJob.length}件${exploration === "page-limit" ? `・探索は${MAX_RUN_PAGES}ページ（${exploredRuns} run）で打ち切り` : ""}）`);
  }
  return { runs: collected, aggregate: aggregateRuns(collected), selection };
}

function parseArguments(argumentsList) {
  const options = { repo: "soramikan/lnako", workflow: "ci.yml", branch: null, jobs: null, since: null, requireJobs: [], runs: 5, output: null, logs: true };
  const takeValue = (index) => {
    const value = argumentsList[index + 1];
    if (value === undefined) throw new Error(`${argumentsList[index]}には値が必要です`);
    return value;
  };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--repo") options.repo = takeValue(index++);
    else if (argument === "--workflow") options.workflow = takeValue(index++);
    else if (argument === "--branch") options.branch = takeValue(index++);
    else if (argument === "--jobs") options.jobs = Number(takeValue(index++));
    else if (argument === "--since") options.since = takeValue(index++);
    // full実行でだけ走るsentinel job（複数指定可）。lightweight runはmatrixを
    // skipしてもjob数が変わらないため、これでfull実行を識別する。
    else if (argument === "--require-job") options.requireJobs.push(takeValue(index++));
    else if (argument === "--runs") options.runs = Number(takeValue(index++));
    else if (argument === "--output") options.output = takeValue(index++);
    else if (argument === "--no-logs") options.logs = false;
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/collect_ci_metrics.mjs [--repo owner/name] [--workflow ci.yml] [--branch <name>] [--jobs <期待job数>] [--since <ISO8601>] [--require-job <job名>] [--runs 5] [--output docs/ci-performance.md] [--no-logs]`);
  }
  if (!Number.isSafeInteger(options.runs) || options.runs < 1) throw new Error("--runsには正の整数を指定してください");
  if (options.jobs !== null && (!Number.isSafeInteger(options.jobs) || options.jobs < 1)) throw new Error("--jobsには正の整数を指定してください");
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const options = parseArguments(process.argv.slice(2));
  try {
    const { runs, aggregate, selection } = await collectMetrics({
      repo: options.repo,
      workflow: options.workflow,
      branch: options.branch,
      expectedJobCount: options.jobs,
      since: options.since,
      requireJobs: options.requireJobs,
      runCount: options.runs,
      includeLogs: options.logs,
      log: (message) => console.error(message),
    });
    const markdown = formatMarkdown({
      repo: options.repo,
      workflow: options.workflow,
      generatedAt: new Date().toISOString(),
      runs,
      aggregate,
      selection,
    });
    if (options.output) {
      await writeFile(resolve(dirname(fileURLToPath(import.meta.url)), "..", options.output), markdown);
      console.log(`CI metricsを${options.output}へ書き出しました: ${aggregate.runCount} runs`);
    } else {
      process.stdout.write(markdown);
    }
  } catch (error) {
    console.error(`collect_ci_metrics.mjs failed: ${error instanceof Error ? error.message : String(error)}`);
    if (error?.stack) console.error(error.stack);
    process.exitCode = 1;
  }
}
