import { spawn } from "node:child_process";
import { isAbsolute, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const arguments_ = parseArguments();

// These audits use independent temporary directories and output files. Run
// them together only after the AOT job has built the compiler, so the job
// keeps every assertion while removing their serial wall-clock cost.
const checks = [
  {
    name: "dispatch evidence",
    script: "check_dispatch_trace.mjs",
    arguments: ["--no-build", "--evidence-output", arguments_.evidenceOutput],
  },
  {
    name: "dispatch coverage",
    script: "check_dispatch_coverage.mjs",
    arguments: ["--no-build", "--output", arguments_.coverageOutput],
  },
];

console.log("AOT dispatch evidence/coverage監査を並列開始します（各監査の全検査は維持）");
const results = await Promise.all(checks.map((check) => runCheck(check)));
for (const result of results) {
  if (result.stdout.length > 0) process.stdout.write(`[${result.name}]\n${result.stdout}`);
  if (result.stderr.length > 0) process.stderr.write(`[${result.name} stderr]\n${result.stderr}`);
}
const failures = results.filter((result) => result.status !== 0);
if (failures.length > 0) {
  throw new Error(`並列dispatch監査が${failures.length}件失敗しました: ${failures.map((result) => result.name).join(", ")}`);
}
console.log("AOT dispatch evidence/coverage監査: 2件成功");

function parseArguments() {
  const values = { evidenceOutput: null, coverageOutput: null };
  for (let index = 0; index < process.argv.length - 2; index += 1) {
    const argument = process.argv[index + 2];
    if (argument === "--evidence-output") {
      if (values.evidenceOutput !== null) throw new Error("--evidence-outputは1回だけ指定してください");
      values.evidenceOutput = process.argv[++index + 2] ?? null;
    } else if (argument === "--coverage-output") {
      if (values.coverageOutput !== null) throw new Error("--coverage-outputは1回だけ指定してください");
      values.coverageOutput = process.argv[++index + 2] ?? null;
    } else {
      throw new Error("usage: node tools/check_dispatch_audits_parallel.mjs --evidence-output /absolute/path --coverage-output /absolute/path");
    }
  }
  if (values.evidenceOutput === null || !isAbsolute(values.evidenceOutput) || values.evidenceOutput.length === 0 ||
      values.coverageOutput === null || !isAbsolute(values.coverageOutput) || values.coverageOutput.length === 0) {
    throw new Error("evidence/coverageの出力先には絶対pathを指定してください");
  }
  if (values.evidenceOutput === values.coverageOutput) throw new Error("evidenceとcoverageの出力先は分けてください");
  return values;
}

function runCheck(check) {
  return new Promise((resolveResult) => {
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
