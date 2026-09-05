import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { coverageEnv as env } from "./coverage_env.mjs";
import * as evidence_common from "./evidence_common.mjs";

export async function startLoopbackServer() {
  const child = spawn(process.execPath, [resolve(env.root, "tools/oracle/http_loopback_server.mjs")], {
    cwd: env.root,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stderr.resume();
  try {
    const port = await firstLine(child.stdout);
    if (!/^\d+$/.test(port)) throw new Error(`loopback HTTPサーバのportが不正です: ${port}`);
    return { process: child, base: `http://127.0.0.1:${port}` };
  } catch (error) {
    if (child.exitCode === null) child.kill("SIGTERM");
    throw error;
  }
}


export async function stopLoopbackServer(child) {
  if (child.exitCode !== null) return;
  const exited = new Promise((resolveExit) => child.once("exit", resolveExit));
  child.kill("SIGTERM");
  await Promise.race([exited, new Promise((resolveTimeout) => setTimeout(resolveTimeout, 2000))]);
  if (child.exitCode === null) child.kill("SIGKILL");
}


export async function firstLine(stream) {
  let buffered = "";
  for await (const chunk of stream) {
    buffered += chunk.toString("utf8");
    const newline = buffered.indexOf("\n");
    if (newline >= 0) return buffered.slice(0, newline).trim();
  }
  throw new Error("loopback HTTPサーバがポートを通知せず終了しました");
}


export function run(command, arguments_, environment, cwd, extraOptions = {}) {
  const result = spawnSync(command, arguments_, {
    cwd,
    env: environment,
    encoding: "utf8",
    maxBuffer: env.maxBuffer,
    input: extraOptions.input,
    windowsHide: true,
  });
  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? (result.error?.message ?? ""),
  };
}


export function unavailableProcess(reason) {
  return { status: 1, signal: null, stdout: "", stderr: `${reason ?? "公式生成routeを実行できません"}\n` };
}


export function buildCompiler() {
  const result = spawnSync("zig", ["build"], {
    cwd: env.root,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(env.root, ".zig-global-cache") },
    encoding: "utf8",
    maxBuffer: env.maxBuffer,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました: ${result.stderr ?? result.error?.message ?? "unknown"}`);
}


export function assertSuccess(label, result) {
  if (result.status !== 0) {
    const detail = result.stderr.length > 0 ? `: ${result.stderr.slice(-2000)}` : "";
    throw new Error(`${label}に失敗しました (status=${result.status}, signal=${result.signal})${detail}`);
  }
}


export function assertEquivalent(label, left, right) {
  const leftNormalized = normalizeProcess(left);
  const rightNormalized = normalizeProcess(right);
  if (JSON.stringify(leftNormalized) !== JSON.stringify(rightNormalized)) {
    throw new Error(`${label}でtrace有無の結果が変化しました`);
  }
}


export function assertOfficialEquivalent(label, left, right) {
  const leftNormalized = normalizeProcess(left);
  const rightNormalized = normalizeProcess(right);
  if (JSON.stringify(leftNormalized) !== JSON.stringify(rightNormalized)) {
    throw new Error(
      `${label}で公式・lnakoの結果が一致しません: official=${JSON.stringify(leftNormalized)} lnako=${JSON.stringify(rightNormalized)}`,
    );
  }
}


export function normalizeProcess(result) {
  return {
    stdout: evidence_common.normalizeLineEndings(result.stdout),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}


export function summarizeProcess(result) {
  return {
    status: result.status,
    signal: result.signal,
    stdoutSha256: evidence_common.sha256(evidence_common.normalizeLineEndings(result.stdout)),
    stderrSha256: evidence_common.sha256(evidence_common.normalizeLineEndings(result.stderr)),
  };
}

