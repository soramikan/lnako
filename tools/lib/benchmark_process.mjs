import { spawnSync } from "node:child_process";

import { outputsMatch } from "./benchmark_statistics.mjs";

export class BenchmarkProcessError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "BenchmarkProcessError";
    this.code = details.code ?? "process_failed";
    this.details = details;
  }
}

export function runProcess(command, args = [], options = {}) {
  const started = process.hrtime.bigint();
  let result;
  try {
    result = spawnSync(command, args, {
      cwd: options.cwd,
      env: options.env,
      shell: options.shell ?? false,
      encoding: "utf8",
      timeout: options.timeoutMs,
      maxBuffer: options.maxBuffer ?? 64 * 1024 * 1024,
      windowsHide: true,
    });
  } catch (error) {
    const finished = process.hrtime.bigint();
    return {
      ok: false,
      timed_out: false,
      elapsed_ns: Number(finished - started),
      status: null,
      signal: null,
      stdout: "",
      stderr: "",
      error: error instanceof Error ? error.message : String(error),
      error_code: error?.code ?? null,
    };
  }
  const finished = process.hrtime.bigint();
  const timedOut = isTimeoutResult(result, options.timeoutMs);
  if (timedOut) terminateWindowsProcessTree(result);
  const error = result.error ?? null;
  return {
    ok: !timedOut && error === null && result.status === 0,
    timed_out: timedOut,
    elapsed_ns: Number(finished - started),
    status: result.status ?? null,
    signal: result.signal ?? null,
    stdout: typeof result.stdout === "string" ? result.stdout : String(result.stdout ?? ""),
    stderr: typeof result.stderr === "string" ? result.stderr : String(result.stderr ?? ""),
    error: error ? error.message : null,
    error_code: error?.code ?? null,
  };
}

function terminateWindowsProcessTree(result) {
  if (process.platform !== "win32" || !Number.isInteger(result?.pid) || result.pid <= 0) return;
  // A .cmd runtime is launched through cmd.exe. Node's synchronous timeout
  // stops the shell, but a child Node/compiler can otherwise outlive it.
  // taskkill's tree mode is best effort because the timeout already ended the
  // process in the common case.
  try {
    spawnSync("taskkill", ["/PID", String(result.pid), "/T", "/F"], {
      encoding: "utf8",
      shell: false,
      windowsHide: true,
      timeout: 5_000,
    });
  } catch {
    // Preserve the original timeout result even if cleanup is unavailable.
  }
}

function isTimeoutResult(result, timeoutMs) {
  if (timeoutMs === undefined || timeoutMs === null) return false;
  return result?.error?.code === "ETIMEDOUT" || (result?.status === null && result?.signal !== null && result?.error !== undefined);
}

export function runMeasuredSamples({
  command,
  args = [],
  expectedStdout = null,
  warmup = 0,
  samples = 1,
  timeoutMs,
  cwd,
  env,
  shell = false,
  maxBuffer,
  onObservation,
} = {}) {
  if (typeof command !== "string" || command.length === 0) throw new Error("benchmark commandが空です");
  if (!Number.isSafeInteger(warmup) || warmup < 0) throw new Error("benchmark warmupが不正です");
  if (!Number.isSafeInteger(samples) || samples <= 0) throw new Error("benchmark samplesが不正です");
  if (timeoutMs !== undefined && (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0)) {
    throw new Error("benchmark timeoutが不正です");
  }
  const observed = [];
  const observations = [];
  for (let index = 0; index < warmup + samples; index += 1) {
    const result = runProcess(command, args, { cwd, env, shell, timeoutMs, maxBuffer });
    const observation = {
      index,
      measured: index >= warmup,
      ...result,
    };
    observations.push(observation);
    if (typeof onObservation === "function") onObservation(observation);
    assertSuccessfulProcess(command, args, result);
    if (expectedStdout !== null && !outputsMatch(result.stdout, expectedStdout)) {
      throw new BenchmarkProcessError(
        `出力が一致しません: ${formatCommand(command, args)}\n期待値: ${JSON.stringify(expectedStdout)}\n実際: ${JSON.stringify(result.stdout)}`,
        {
          code: "output_mismatch",
          command,
          args: [...args],
          expected_stdout: expectedStdout,
          actual_stdout: result.stdout,
          observation,
        },
      );
    }
    if (index >= warmup) observed.push(result.elapsed_ns);
  }
  return { samples_ns: observed, observations };
}

export function assertSuccessfulProcess(command, args, result) {
  if (result.timed_out) {
    throw new BenchmarkProcessError(
      `プロセスがタイムアウトしました (${result.elapsed_ns} ns): ${formatCommand(command, args)}`,
      {
        code: "timeout",
        command,
        args: [...args],
        observation: result,
      },
    );
  }
  if (result.error !== null || result.status !== 0) {
    throw new BenchmarkProcessError(
      `プロセスが正常終了しませんでした: ${formatCommand(command, args)}\nstatus: ${result.status}\nsignal: ${result.signal ?? ""}\nstdout: ${result.stdout}\nstderr: ${result.stderr}\nerror: ${result.error ?? ""}`,
      {
        code: result.error_code === "ENOENT" ? "runtime_unavailable" : "process_failed",
        command,
        args: [...args],
        observation: result,
      },
    );
  }
}

function formatCommand(command, args) {
  return [command, ...args].map((part) => JSON.stringify(String(part))).join(" ");
}
