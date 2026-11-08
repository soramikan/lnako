#!/usr/bin/env node
// `パッケージ:` / `pkg:` 取り込みの cnako/lnako 共通fixture比較（#210）。
//
// 同一のfixtureソースを、lnako Interpreterと公式cnako3 v3.7.24の両方で実行し、
// 観測stdoutが期待値と一致することを確認する。公式cnako3は `パッケージ:`
// 構文を持たないため、仕様 §7.3 の委譲契約（環境は `lnako sync --json`、
// cnakoはenvironment.jsonのalias対応だけを使う）を
// tools/lib/package/cnako_package_loader.mjs でadapter化して接続する。
// このadapterはfixtureソースを書き換えず、公式cnako3のresolvePathだけを
// 差し替える。cnako本体への実装（#61）と上流公開リリースは別ゲート。
//
// 拒否系は両処理系が同じfixtureを拒否することを確認する（診断文言の一致は
// 要求せず、処理系ごとの診断tokenをexpect.jsonで指定する）。
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureRoot = path.join(root, "tests", "fixtures", "package-common");
const loader = path.join(root, "tools", "lib", "package", "cnako_package_loader.mjs");
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const executable = path.join(root, "zig-out", "bin", `lnako${executableSuffix}`);
const ansiPattern = /\u001b\[[0-9;]*m/g;

function fail(message) {
  throw new Error(`package import共通fixture検査: ${message}`);
}

function takeFlag(name) {
  const index = process.argv.indexOf(name);
  if (index < 0) return false;
  process.argv.splice(index, 1);
  return true;
}

function takeValue(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index < 0) return fallback;
  const value = process.argv[index + 1];
  if (value === undefined || value.startsWith("--")) fail(`${name}には値を指定してください`);
  process.argv.splice(index, 2);
  return value;
}

function normalize(text) {
  return (text ?? "").replace(ansiPattern, "").replace(/\r\n/g, "\n");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
    timeout: 600_000,
    env: { ...process.env, ...options.env },
  });
  if (result.error) fail(`${command} を実行できません: ${result.error.message}`);
  if (result.status === null) fail(`${command} がtimeoutで終了しました（signal: ${result.signal ?? "unknown"}）`);
  return {
    status: result.status,
    stdout: normalize(result.stdout),
    stderr: normalize(result.stderr),
  };
}

// project信頼検証は配置dirのACLを見るため、CI workspace（WindowsのD:\a等）の
// 継承ACLで拒否され得る。package-aot検査と同じくuser privateなhome配下を
// 優先し、失敗時に切り分けられるよう診断を出す。
function createWorkDir() {
  for (const base of [os.homedir(), os.tmpdir()]) {
    try {
      return fs.mkdtempSync(path.join(base, ".lnako-package-common-"));
    } catch {
      // 次の候補へ
    }
  }
  fail("作業ディレクトリを作成できません");
}

function copyFixture(destination, options = {}) {
  fs.cpSync(fixtureRoot, destination, {
    recursive: true,
    filter: options.excludeRejects
      ? (source) => path.basename(source) !== "reject-symlink-escape" && !path.basename(source).startsWith("reject-")
      : undefined,
  });
}

// 委譲loaderがfixtureソースを書き換えていないことを、ツリー全体で固定する
// （準備物 `.nako/` と `nako.lock` は実行時の生成物なので除外）。
function snapshotTree(directory) {
  const snapshot = {};
  const walk = (current, prefix) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name === ".nako" || entry.name === "nako.lock") continue;
      const full = path.join(current, entry.name);
      const relative = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
      if (entry.isDirectory()) {
        walk(full, relative);
      } else if (entry.isFile()) {
        snapshot[relative] = createHash("sha256").update(fs.readFileSync(full)).digest("hex");
      }
    }
  };
  walk(directory, "");
  return snapshot;
}

function sameSnapshot(left, right) {
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length && leftKeys.every((key, index) => key === rightKeys[index] && left[key] === right[key]);
}

function readExpected() {
  const text = normalize(fs.readFileSync(path.join(fixtureRoot, "expected-stdout.txt"), "utf8"));
  if (text.length === 0) fail("expected-stdout.txtが空です");
  return text;
}

function runLoader(app, oracle) {
  return run(process.execPath, [
    loader,
    "--root", app,
    "--entry", "main.nako3",
    "--oracle", oracle,
    "--lnako", executable,
  ], { cwd: app });
}

function ensureExecutable() {
  if (!fs.existsSync(executable)) fail(`lnako実行ファイルがありません: ${executable}`);
}

function checkAccept(work, oracle, expected) {
  const fixture = path.join(work, "package-common");
  copyFixture(fixture, { excludeRejects: true });
  const app = path.join(fixture, "app");

  const lnako = run(executable, ["run", "main.nako3"], { cwd: app });
  if (lnako.status !== 0) fail(`lnako Interpreterが失敗しました\n${lnako.stderr}`);
  if (lnako.stdout !== expected) fail(`lnako Interpreterの観測結果が期待値と一致しません\n期待:\n${expected}\n実際:\n${lnako.stdout}`);

  const cnako = runLoader(app, oracle);
  if (cnako.status !== 0) fail(`公式cnako3（委譲loader経由）が失敗しました\n${cnako.stderr}`);
  if (cnako.stdout !== expected) fail(`公式cnako3（委譲loader経由）の観測結果が期待値と一致しません\n期待:\n${expected}\n実際:\n${cnako.stdout}`);
  if (lnako.stdout !== cnako.stdout) fail(`lnakoとcnakoのstdoutが一致しません\nlnako:\n${lnako.stdout}\ncnako:\n${cnako.stdout}`);

  // 委譲loaderはfixtureソースを書き換えない（公式cnako3が元のソースを
  // 構文解析し、指定子の解決だけを委譲する）ことをツリー全体で固定する。
  if (!sameSnapshot(snapshotTree(path.join(fixtureRoot, "app")), snapshotTree(app))) {
    fail("委譲loaderがfixtureソースを書き換えています");
  }

  // 仕様 §7.3 の `--no-sync`（準備済み環境の単独検証）でも同じ出力になること。
  const noSync = run(process.execPath, [
    loader,
    "--root", app,
    "--entry", "main.nako3",
    "--oracle", oracle,
    "--lnako", executable,
    "--no-sync",
  ], { cwd: app });
  if (noSync.status !== 0) fail(`公式cnako3（--no-sync）が失敗しました\n${noSync.stderr}`);
  if (noSync.stdout !== expected) fail(`公式cnako3（--no-sync）の観測結果が期待値と一致しません\n${noSync.stdout}`);

  // `--no-sync` は lnako を起動せず lockSha256 を検証する。lock だけを
  // 1バイト変えた環境で拒否されること（検証が実際に効いていること）を固定する。
  const lockPath = path.join(app, "nako.lock");
  const lockBytes = fs.readFileSync(lockPath);
  try {
    fs.appendFileSync(lockPath, "\n");
    const tampered = run(process.execPath, [
      loader,
      "--root", app,
      "--entry", "main.nako3",
      "--oracle", oracle,
      "--lnako", executable,
      "--no-sync",
    ], { cwd: app });
    if (tampered.status === 0) fail("lockを改変した--no-sync実行が成功しました（lockSha256検証が効いていません）");
    if (!tampered.stderr.includes("E034_INVALID_ENVIRONMENT_REFERENCE")) {
      fail(`lock改変時の--no-sync診断にE034_INVALID_ENVIRONMENT_REFERENCEが含まれません\n${tampered.stderr}`);
    }
  } finally {
    fs.writeFileSync(lockPath, lockBytes);
  }

  return { lnako: lnako.stdout, cnako: cnako.stdout, noSync: noSync.stdout };
}

// symlink fixtureはリポジトリへsymlinkをコミットせず、作業コピー上で作る。
// Windowsのcheckout設定やZIP配布に依存させないため。作成できない環境
// （symlink権限なし）ではこのケースだけskipし、理由を記録する。
function prepareSymlinkEscape(directory) {
  const link = path.join(directory, "demo", "src", "link.nako3");
  const target = path.join("..", "..", "secret.nako3");
  try {
    // `demo/src/` は空ディレクトリなのでgitに収録されない。clean checkoutでも
    // symlinkを作れるよう、親ディレクトリを先に作る。
    fs.mkdirSync(path.dirname(link), { recursive: true });
    fs.symlinkSync(target, link, "file");
    return { prepared: true };
  } catch (error) {
    if (error.code === "EPERM" || error.code === "EACCES" || error.code === "ENOSYS") {
      return { prepared: false, reason: `${error.code}（symlink作成権限なし）` };
    }
    throw error;
  }
}

function readExpectation(directory) {
  const file = path.join(directory, "expect.json");
  if (!fs.existsSync(file)) fail(`expect.jsonがありません: ${directory}`);
  const expectation = JSON.parse(fs.readFileSync(file, "utf8"));
  const lnakoDiagnostic = expectation.lnakoDiagnostic ?? expectation.diagnostic;
  const cnakoDiagnostic = expectation.cnakoDiagnostic ?? expectation.diagnostic;
  if (typeof lnakoDiagnostic !== "string" || typeof cnakoDiagnostic !== "string") {
    fail(`診断tokenを文字列で指定してください: ${directory}`);
  }
  return {
    lnakoDiagnostic,
    cnakoDiagnostic,
    lnakoDetail: expectation.lnakoDetail ?? null,
    cnakoDetail: expectation.cnakoDetail ?? null,
    reason: expectation.reason ?? "",
  };
}

function checkRejections(work, oracle, reported) {
  const names = fs.readdirSync(fixtureRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("reject-"))
    .map((entry) => entry.name)
    .sort();
  if (names.length === 0) fail("拒否系fixtureがありません");
  const skipped = [];
  for (const name of names) {
    const source = path.join(fixtureRoot, name);
    const expectation = readExpectation(source);
    const directory = path.join(work, "rejects", name);
    fs.cpSync(source, directory, { recursive: true });
    if (name === "reject-symlink-escape") {
      const prepared = prepareSymlinkEscape(directory);
      if (!prepared.prepared) {
        skipped.push(`${name}(${prepared.reason})`);
        continue;
      }
    }

    const label = expectation.reason.length === 0 ? name : `${name}（${expectation.reason}）`;
    const lnako = run(executable, ["run", "main.nako3"], { cwd: directory });
    if (lnako.status === 0) fail(`拒否されるべきfixtureがlnako Interpreterで成功しました: ${label}`);
    if (!lnako.stderr.includes(expectation.lnakoDiagnostic)) {
      fail(`lnakoの診断に${expectation.lnakoDiagnostic}が含まれません: ${label}\n${lnako.stderr}`);
    }
    if (expectation.lnakoDetail !== null && !lnako.stderr.includes(expectation.lnakoDetail)) {
      fail(`lnakoの診断に${expectation.lnakoDetail}が含まれません: ${label}\n${lnako.stderr}`);
    }

    const cnako = runLoader(directory, oracle);
    if (cnako.status === 0) fail(`拒否されるべきfixtureが公式cnako3（委譲loader経由）で成功しました: ${label}`);
    if (!cnako.stderr.includes(expectation.cnakoDiagnostic)) {
      fail(`cnako側の診断に${expectation.cnakoDiagnostic}が含まれません: ${label}\n${cnako.stderr}`);
    }
    if (expectation.cnakoDetail !== null && !cnako.stderr.includes(expectation.cnakoDetail)) {
      fail(`cnako側の診断が${expectation.cnakoDetail}を含みません: ${label}\n${cnako.stderr}`);
    }
    reported.push(`${name}(${expectation.lnakoDiagnostic}/${expectation.cnakoDiagnostic})`);
  }
  return skipped;
}

function main() {
  const noBuild = takeFlag("--no-build");
  const oracle = path.resolve(takeValue("--oracle", process.env.NADESIKO3_ORACLE ?? path.join(root, ".cache", "oracle", "nadesiko3-3.7.24")));
  if (!fs.existsSync(path.join(oracle, "src", "cnako3mod.mjs"))) {
    fail(`公式cnako3がありません: ${oracle}（tools/setup_oracle.mjsで展開してください）`);
  }
  if (!noBuild) {
    const build = spawnSync("zig", ["build"], { cwd: root, stdio: "inherit", timeout: 1_800_000 });
    if (build.error) fail(`zig build を実行できません: ${build.error.message}`);
    if (build.status === null) fail(`zig build がtimeoutで終了しました（signal: ${build.signal ?? "unknown"}）`);
    if (build.status !== 0) fail("zig buildに失敗しました");
  }
  ensureExecutable();
  const expected = readExpected();

  const work = createWorkDir();
  console.log(`package import共通fixture検査: 作業ディレクトリ ${work}`);
  try {
    const outputs = checkAccept(work, oracle, expected);
    console.log(`package import共通fixture検査: 受理系 ${outputs.lnako.split("\n").filter(Boolean).length}行がlnako/cnako(--no-sync含む)で一致 (${path.basename(oracle)})`);
    const rejections = [];
    const skipped = checkRejections(work, oracle, rejections);
    console.log(`package import共通fixture検査: 拒否${rejections.length}件が両処理系で拒否 (${rejections.join(" / ")})`);
    for (const name of skipped) console.log(`package import共通fixture検査: skip ${name}`);
    console.log("package import共通fixture検査: 成功");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
