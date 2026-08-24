import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const testCase = JSON.parse(await readFile(resolve(root, "tests/oracle/node-interrupt-case.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-interrupt-"));

try {
  buildLnako();
  const source = resolve(temporary, "interrupt.nako3");
  await writeFile(source, testCase.source, "utf8");
  const environment = { ...process.env, TZ: "Asia/Tokyo", LNAKO_TEST_NOW_MS: "1735689845678", LNAKO_TEST_RANDOM_SEED: "5573589319906701683" };
  if (process.platform === "win32") {
    console.log("Node強制終了公式差分テスト: WindowsはCIのコンソール制御イベントテストで検証");
  } else {
    const official = await runInterrupted(process.execPath, ["--import", pathToFileURL(fixedHost).href, officialCli, source], environment);
    const actual = await runInterrupted(executable, ["run", source], environment);
    if (JSON.stringify(official) !== JSON.stringify(actual) || actual.stdout !== "READY\n" || actual.exitCode !== 0) {
      throw new Error(`Node強制終了差分: official=${JSON.stringify(official)} lnako=${JSON.stringify(actual)}`);
    }
    console.log(`Node強制終了公式差分テスト: 1ケース・${testCase.commands.length}命令成功`);
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") } });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function runInterrupted(command, args, environment) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { cwd: temporary, env: environment, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const interrupt = setTimeout(() => child.kill("SIGINT"), 500);
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${command} のSIGINT処理がタイムアウトしました`));
    }, 4000);
    child.on("error", reject);
    child.on("close", (code, signal) => {
      clearTimeout(interrupt);
      clearTimeout(timeout);
      resolveResult({ stdout: stdout.replaceAll("\r\n", "\n"), stderr: stderr.replaceAll("\r\n", "\n"), exitCode: code, signal });
    });
  });
}
