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
  if (clean.length === 0) return { count: 0, min: null, median: null, p90: null, p95: null, max: null, mean: null };
  return {
    count: clean.length,
    min: Math.min(...clean),
    median: percentile(clean, 50),
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
  // GitHubのjob logは全行にtimestamp prefixが付くため、行跨ぎのpatternを
  // 評価する前に除去する。
  const clean = text
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "")
    .replace(/\r/g, "")
    .replace(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z /gm, "");
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

export function collectRunMetrics(run, jobs, toolchainByJob = new Map(), durationMs = null) {
  const jobMetrics = jobs.map((job) => {
    const steps = (job.steps ?? [])
      .filter((step) => step.started_at && step.completed_at)
      .map((step) => ({ name: step.name, seconds: secondsBetween(step.started_at, step.completed_at) }));
    return {
      name: job.name,
      os: osFromJobName(job.name),
      conclusion: job.conclusion,
      seconds: job.started_at && job.completed_at ? secondsBetween(job.started_at, job.completed_at) : null,
      queueSeconds: job.started_at && job.created_at ? secondsBetween(job.created_at, job.started_at) : null,
      steps,
      toolchain: toolchainByJob.get(job.id) ?? null,
    };
  });
  return {
    id: run.id,
    event: run.event,
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
  };
}

export function formatMarkdown({ repo, workflow, generatedAt, runs, aggregate }) {
  const lines = [
    "# CI performance metrics",
    "",
    `対象: ${repo} / workflow: ${workflow}`,
    `生成: ${generatedAt}`,
    `分析run数: ${aggregate.runCount}（成功した完了runのみ）`,
    "",
    "## 対象run",
    "",
    "| run id | event | branch | wall time | queue | jobs |",
    "| --- | --- | --- | ---: | ---: | ---: |",
    ...runs.map((run) => `| ${run.id} | ${run.event} | ${run.headBranch} | ${formatSeconds(run.wallSeconds)} | ${formatSeconds(run.queueSeconds)} | ${run.jobs.length} |`),
    "",
    "## Wall time",
    "",
    "| metric | median | p90 | p95 | min | max |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
    `| workflow wall time | ${formatSeconds(aggregate.wallTime.median)} | ${formatSeconds(aggregate.wallTime.p90)} | ${formatSeconds(aggregate.wallTime.p95)} | ${formatSeconds(aggregate.wallTime.min)} | ${formatSeconds(aggregate.wallTime.max)} |`,
    `| job queue time | ${formatSeconds(aggregate.queueTime.median)} | ${formatSeconds(aggregate.queueTime.p90)} | ${formatSeconds(aggregate.queueTime.p95)} | ${formatSeconds(aggregate.queueTime.min)} | ${formatSeconds(aggregate.queueTime.max)} |`,
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
    "| job | median | p95 |",
    "| --- | ---: | ---: |",
    ...aggregate.longestJobs.slice(0, 10).map((job) => `| ${job.name} | ${formatSeconds(job.median)} | ${formatSeconds(job.p95)} |`),
    "",
    "## 主要step（median上位15）",
    "",
    "| step | count | median | p95 |",
    "| --- | ---: | ---: | ---: |",
    ...aggregate.steps.slice(0, 15).map((step) => `| ${step.name} | ${step.count} | ${formatSeconds(step.median)} | ${formatSeconds(step.p95)} |`),
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
  ];
  return `${lines.join("\n")}\n`;
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

export async function collectMetrics({ repo, workflow, runCount, includeLogs, ghApiJsonImpl = ghApiJson, ghApiLogImpl = ghApiLog, log = () => {} }) {
  const response = await ghApiJsonImpl(`repos/${repo}/actions/workflows/${workflow}/runs?per_page=${Math.min(100, runCount * 4)}&status=completed`);
  const runs = (response.workflow_runs ?? []).filter((run) => run.conclusion === "success").slice(0, runCount);
  const collected = [];
  for (const run of runs) {
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
      log(`run ${run.id}: jobs ${jobs.length}/${jobsTotal}（ページング取得後も一部欠落）`);
    }
    const timing = await ghApiJsonImpl(`repos/${repo}/actions/runs/${run.id}/timing`).catch(() => null);
    const toolchainByJob = new Map();
    if (includeLogs) {
      for (const job of jobs) {
        if (!(job.steps ?? []).some((step) => step.name === LLVM_SETUP_STEP)) continue;
        try {
          toolchainByJob.set(job.id, parseToolchainLog(await ghApiLogImpl(`repos/${repo}/actions/jobs/${job.id}/logs`)));
        } catch (error) {
          log(`job ${job.id} (${job.name})のlog取得に失敗しました: ${error.message}`);
        }
      }
    }
    collected.push(collectRunMetrics(run, jobs, toolchainByJob, timing?.run_duration_ms));
    log(`run ${run.id}: ${jobs.length} jobs`);
  }
  return { runs: collected, aggregate: aggregateRuns(collected) };
}

function parseArguments(argumentsList) {
  const options = { repo: "soramikan/lnako", workflow: "ci.yml", runs: 5, output: null, logs: true };
  const takeValue = (index) => {
    const value = argumentsList[index + 1];
    if (value === undefined) throw new Error(`${argumentsList[index]}には値が必要です`);
    return value;
  };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--repo") options.repo = takeValue(index++);
    else if (argument === "--workflow") options.workflow = takeValue(index++);
    else if (argument === "--runs") options.runs = Number(takeValue(index++));
    else if (argument === "--output") options.output = takeValue(index++);
    else if (argument === "--no-logs") options.logs = false;
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/collect_ci_metrics.mjs [--repo owner/name] [--workflow ci.yml] [--runs 5] [--output docs/ci-performance.md] [--no-logs]`);
  }
  if (!Number.isSafeInteger(options.runs) || options.runs < 1) throw new Error("--runsには正の整数を指定してください");
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const options = parseArguments(process.argv.slice(2));
  try {
    const { runs, aggregate } = await collectMetrics({
      repo: options.repo,
      workflow: options.workflow,
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
