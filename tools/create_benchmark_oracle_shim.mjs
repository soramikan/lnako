import { appendFile, chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const defaultOutputDirectory = process.env.RUNNER_TEMP && isAbsolute(process.env.RUNNER_TEMP)
  ? resolve(process.env.RUNNER_TEMP)
  : resolve(root, ".cache/benchmark-oracle");
const outputDirectory = parseOutputDirectory(process.argv.slice(2));
const lock = await readJson(lockPath, "upstream.lock.json");
const baseline = lock.nadesiko3;
const oracle = await validateOracle(baseline);
const shimPath = resolve(outputDirectory, process.platform === "win32" ? "cnako3.cmd" : "cnako3");

await mkdir(outputDirectory, { recursive: true });
const shim = process.platform === "win32"
  ? windowsShim(process.execPath, oracle.cliPath)
  : posixShim(process.execPath, oracle.cliPath);
await writeFile(shimPath, shim, { encoding: "utf8", mode: 0o755 });
if (process.platform !== "win32") await chmod(shimPath, 0o755);

if (process.env.GITHUB_ENV) {
  await appendFile(process.env.GITHUB_ENV, `LNAKO_BENCHMARK_CNAKO=${shimPath}\n`, "utf8");
}

console.log(shimPath);

function parseOutputDirectory(arguments_) {
  let output = defaultOutputDirectory;
  let seenOutput = false;
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--output-dir") {
      if (seenOutput) throw new Error("--output-dirは1回だけ指定してください");
      const value = arguments_[++index];
      if (value === undefined || !isAbsolute(value)) throw new Error("--output-dirには絶対パスを指定してください");
      output = resolve(value);
      seenOutput = true;
      continue;
    }
    if (argument.startsWith("--output-dir=")) {
      if (seenOutput) throw new Error("--output-dirは1回だけ指定してください");
      const value = argument.slice("--output-dir=".length);
      if (!isAbsolute(value)) throw new Error("--output-dirには絶対パスを指定してください");
      output = resolve(value);
      seenOutput = true;
      continue;
    }
    if (argument === "--help" || argument === "-h") {
      console.log("使い方: node tools/create_benchmark_oracle_shim.mjs [--output-dir /absolute/path]");
      process.exit(0);
    }
    throw new Error(`未知の引数です: ${argument}`);
  }
  return output;
}

async function validateOracle(baseline) {
  if (!baseline || typeof baseline !== "object" || typeof baseline.tag !== "string" || typeof baseline.commit !== "string" ||
      !/^[0-9a-f]{40}$/i.test(baseline.commit) || !baseline.oracleIdentity || typeof baseline.oracleIdentity.cliSha256 !== "string" ||
      !/^[0-9a-f]{64}$/.test(baseline.oracleIdentity.cliSha256)) {
    throw new Error("upstream.lock.jsonの公式オラクル情報が不正です");
  }
  const oracleDirectory = resolve(root, ".cache/oracle", `nadesiko3-${baseline.tag}`);
  const markerPath = resolve(oracleDirectory, ".lnako-oracle.json");
  const cliPath = resolve(oracleDirectory, "src/cnako3.mjs");
  const [markerBytes, cliBytes] = await Promise.all([
    readFile(markerPath),
    readFile(cliPath),
  ]).catch((error) => {
    throw new Error(`固定公式オラクルがありません。先に tools/setup_oracle.mjs を実行してください: ${error.message}`);
  });
  let marker;
  try {
    marker = JSON.parse(markerBytes.toString("utf8"));
  } catch (error) {
    throw new Error(`固定公式オラクルのmarker JSONが不正です: ${error.message}`);
  }
  const identity = baseline.oracleIdentity;
  if (marker.tag !== baseline.tag || marker.commit !== baseline.commit || marker.archiveSha256 !== baseline.archive?.sha256 ||
      sha256(markerBytes) !== identity.markerSha256 || sha256(cliBytes) !== identity.cliSha256) {
    throw new Error("固定公式オラクルのlockまたはsource checksumが一致しません");
  }
  const version = spawnSync(process.execPath, [cliPath, "-v"], { cwd: root, encoding: "utf8" });
  if (version.error || version.status !== 0 || version.stdout.trim() !== `v${baseline.tag}`) {
    throw new Error(`固定公式オラクルのversionが一致しません: ${version.stdout?.trim() ?? ""}`);
  }
  return { cliPath };
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new Error(`${label}を読み込めません: ${error.message}`);
  }
}

function posixShim(nodePath, cliPath) {
  return `#!/bin/sh\nset -eu\nexec ${shellQuote(nodePath)} ${shellQuote(cliPath)} "$@"\n`;
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function windowsShim(nodePath, cliPath) {
  return `@echo off\r\n"${nodePath}" "${cliPath}" %*\r\nexit /b %ERRORLEVEL%\r\n`;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
