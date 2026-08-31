import { access } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { spawn } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const arguments_ = parseArguments();
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
await access(compiler);

// These checks have separate temporary directories and output files. The
// compiler is built once by the preceding workflow step, so every assertion
// can run concurrently without sharing a build or truncating another audit's
// evidence.
const checks = [
  {
    name: "native oracle",
    script: "compare_native_oracle.mjs",
    arguments: ["--no-build", "--artifact", arguments_.artifact],
  },
  {
    name: "HTTP server AOT oracle",
    script: "compare_http_server_aot_oracle.mjs",
    arguments: ["--no-build"],
  },
  {
    name: "dispatch security",
    script: "check_dispatch_trace_security.mjs",
    arguments: ["--no-build"],
  },
  {
    name: "dispatch evidence/coverage audits",
    script: "check_dispatch_audits_parallel.mjs",
    arguments: [
      "--evidence-output",
      arguments_.evidence,
      "--coverage-output",
      arguments_.coverage,
    ],
  },
];

console.log("AOT全検査を並列開始します（native oracle・HTTP・security・dispatch evidence/coverage、検証範囲は維持）");
const startedAt = Date.now();
const results = await Promise.all(checks.map((check) => runCheck(check)));
for (const result of results) {
  if (result.stdout.length > 0) process.stdout.write(`[${result.name}]\n${result.stdout}`);
  if (result.stderr.length > 0) process.stderr.write(`[${result.name} stderr]\n${result.stderr}`);
}

const failures = results.filter((result) => result.status !== 0);
if (failures.length > 0) {
  throw new Error(`AOT並列検査が${failures.length}件失敗しました: ${failures.map((result) => result.name).join(", ")}`);
}
console.log(`AOT全検査: 4件成功（wall ${formatSeconds(Date.now() - startedAt)}）`);

function parseArguments() {
  const values = { artifact: null, evidence: null, coverage: null };
  for (let index = 0; index < process.argv.length - 2; index += 1) {
    const argument = process.argv[index + 2];
    if (argument === "--artifact" || argument === "--evidence-output" || argument === "--coverage-output") {
      const key = argument === "--artifact" ? "artifact" : argument === "--evidence-output" ? "evidence" : "coverage";
      if (values[key] !== null) throw new Error(`${argument}は1回だけ指定してください`);
      const value = process.argv[++index + 2] ?? null;
      if (value === null || !isAbsolute(value)) throw new Error(`${argument}には絶対パスを指定してください`);
      values[key] = value;
      continue;
    }
    throw new Error("usage: node tools/check_aot_suite_parallel.mjs --artifact /absolute/path --evidence-output /absolute/path --coverage-output /absolute/path");
  }
  if (values.artifact === null || values.evidence === null || values.coverage === null) {
    throw new Error("artifact・evidence・coverageの3出力先が必要です");
  }
  if (new Set([values.artifact, values.evidence, values.coverage]).size !== 3) {
    throw new Error("artifact・evidence・coverageの出力先は分けてください");
  }
  return values;
}

function runCheck(check) {
  return new Promise((resolveResult) => {
    const startedAt = Date.now();
    const child = spawn(process.execPath, [resolve(root, "tools", check.script), ...check.arguments], {
      cwd: root,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      console.log(`[${check.name}] 完了: status=${result.status ?? "spawn-error"} wall ${formatSeconds(Date.now() - startedAt)}`);
      resolveResult({ name: check.name, ...result });
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => finish({ status: null, signal: null, stdout, stderr: `${stderr}${error.message}\n` }));
    child.on("close", (status, signal) => finish({ status, signal, stdout, stderr }));
  });
}

function formatSeconds(milliseconds) {
  return `${(milliseconds / 1000).toFixed(2)}s`;
}
