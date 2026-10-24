#!/usr/bin/env node
// `パッケージ:` / `pkg:` import のAOT実行検証。Interpreter と AOT O0〜O3 の
// 生成物を実際に走らせ、観測stdoutが期待値と一致することを確認する。
// 拒否系（未公開export・version指定・path traversal）は Interpreter と AOT
// build が同じ診断行で失敗し、生成物を残さないことを確認する。
// fixtureは作業treeの汚染を避けるため一時ディレクトリへ複製してから実行する。
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureRoot = path.join(root, "tests", "fixtures", "package-aot");
const allOptimizations = ["O0", "O1", "O2", "O3"];
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const executable = path.join(root, "zig-out", "bin", `lnako${executableSuffix}`);

function fail(message) {
  throw new Error(`package import AOT検査: ${message}`);
}

function parseNoBuild() {
  const index = process.argv.indexOf("--no-build");
  if (index < 0) return false;
  process.argv.splice(index, 1);
  return true;
}

function parseOptimizations() {
  const index = process.argv.indexOf("--optimizations");
  if (index < 0) return allOptimizations;
  const value = process.argv[index + 1];
  if (value === undefined) fail("--optimizationsにはO0,O1のような値を指定してください");
  process.argv.splice(index, 2);
  const selected = value.split(",").map((item) => item.trim()).filter((item) => item.length > 0);
  if (selected.length === 0) fail("--optimizationsが空です");
  for (const optimization of selected) {
    if (!allOptimizations.includes(optimization)) fail(`未知の最適化レベルです: ${optimization}`);
  }
  return selected;
}

function normalize(text) {
  return text.replace(/\r\n/g, "\n");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
    timeout: 900_000,
    env: { ...process.env, ...options.env },
  });
  if (result.error) fail(`${command} を実行できません: ${result.error.message}`);
  return {
    status: result.status,
    stdout: normalize(result.stdout ?? ""),
    stderr: normalize(result.stderr ?? ""),
  };
}

// 診断の一致判定に使う行。絶対pathを含む前置き行は同一fixture・同一作業
// ディレクトリなのでInterpreterとAOTで一致する。
function diagnosticLine(stderr, token) {
  return stderr.split("\n").find((line) => line.includes(token)) ?? null;
}

function copyFixture(destination) {
  fs.cpSync(fixtureRoot, destination, { recursive: true });
}

// project 信頼検証（書き込み権限）は配置 dir の ACL を見るため、CI の
// workspace（Windows の D:\a 等）では継承 ACL で拒否され得る。user private な
// home 配下に作業コピーを作り、失敗時は配置場所を変えて切り分けられるようにする。
function createWorkDir() {
  for (const base of [os.homedir(), os.tmpdir()]) {
    try {
      return fs.mkdtempSync(path.join(base, ".lnako-package-aot-"));
    } catch {
      // 次の候補へ
    }
  }
  fail("作業ディレクトリを作成できません");
}

// 失敗時だけ配置場所ごとに Interpreter を走らせ、信頼検証の拒否が配置に
// 依存するか（ACL か）を 1 回の CI で判定できるようにする。
function probeLocations(expected) {
  const candidates = [
    ["repo", path.join(root, ".tmp-lnako-package-aot-probe")],
    ["home", path.join(os.homedir(), ".lnako-package-aot-probe")],
    ["tmp", path.join(os.tmpdir(), "lnako-package-aot-probe")],
  ];
  for (const [label, base] of candidates) {
    try {
      fs.mkdirSync(base, { recursive: true });
    } catch (error) {
      console.error(`package import AOT検査: 配置 ${label} (${base}) → 作成できません: ${error.message}`);
      continue;
    }
    const fixture = path.join(base, "package-aot");
    copyFixture(fixture);
    const result = run(executable, ["run", "main.nako3"], { cwd: path.join(fixture, "app") });
    const matched = result.status === 0 && result.stdout === expected;
    console.log(`package import AOT検査: 配置 ${label} (${base}) → ${matched ? "成功" : "失敗"}`);
    if (!matched) {
      for (const line of result.stderr.split("\n")) {
        if (line.includes("パッケージ環境") || line.includes("invalid_import")) console.error(`   ${line}`);
      }
    }
    fs.rmSync(base, { recursive: true, force: true });
  }
}

// 失敗時だけ同期済み環境の実体を出す。OS 固有の同期・環境検証の食い違いを
// CI ログだけで切り分けられるようにする（内容は fixture の path と hash のみ）。
function dumpFailureDiagnostics(cwd) {
  const files = [
    ["environment.json", path.join(cwd, ".nako", "environment.json")],
    ["nako.lock", path.join(cwd, "nako.lock")],
  ];
  console.error(`package import AOT検査: 診断 (${cwd})`);
  for (const [label, file] of files) {
    if (!fs.existsSync(file)) {
      console.error(`${label}: ありません`);
      continue;
    }
    console.error(`${label}:\n${fs.readFileSync(file, "utf8").slice(0, 4000)}`);
  }
  const check = run(executable, ["check"], { cwd });
  console.error(`check: exit=${check.status}\n${check.stdout}${check.stderr}`);
}

function checkRejections(fixture, work, reported) {
  const names = fs.readdirSync(fixture, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("reject-"))
    .map((entry) => entry.name)
    .sort();
  if (names.length === 0) fail("拒否系fixtureがありません");
  for (const name of names) {
    const directory = path.join(fixture, name);
    const expectation = JSON.parse(fs.readFileSync(path.join(directory, "expect.json"), "utf8"));
    const token = expectation.diagnostic;
    if (typeof token !== "string" || token.length === 0) fail(`diagnosticを文字列で指定してください: ${name}`);

    const interpreter = run(executable, ["run", "main.nako3"], { cwd: directory });
    if (interpreter.status === 0) fail(`拒否されるべきfixtureがInterpreterで成功しました: ${name}`);
    const interpreterLine = diagnosticLine(interpreter.stderr, token);
    if (interpreterLine === null) fail(`Interpreterの診断に${token}が含まれません: ${name}\n${interpreter.stderr}`);

    const output = path.join(work, `${name}-aot${executableSuffix}`);
    const aot = run(executable, ["build", "main.nako3", "-o", output, "-O0"], { cwd: directory });
    if (aot.status === 0) fail(`拒否されるべきfixtureがAOT buildで成功しました: ${name}`);
    const aotLine = diagnosticLine(aot.stderr, token);
    if (aotLine === null) fail(`AOTの診断に${token}が含まれません: ${name}\n${aot.stderr}`);
    if (aotLine !== interpreterLine) fail(`診断がInterpreterとAOTで一致しません: ${name}\nInterpreter: ${interpreterLine}\nAOT: ${aotLine}`);
    if (fs.existsSync(output)) fail(`拒否されたbuildが生成物を残しました: ${name}`);
    reported.push(`${name}(${token})`);
  }
}

async function main() {
  const optimizations = parseOptimizations();
  const noBuild = parseNoBuild();
  const expected = normalize(fs.readFileSync(path.join(fixtureRoot, "expected-stdout.txt"), "utf8"));
  if (expected.length === 0) fail("expected-stdout.txtが空です");
  if (!noBuild) {
    const build = spawnSync("zig", ["build"], { cwd: root, stdio: "inherit" });
    if (build.status !== 0) fail("zig buildに失敗しました");
  }
  if (!fs.existsSync(executable)) fail(`lnako実行ファイルがありません: ${executable}`);

  const work = createWorkDir();
  console.log(`package import AOT検査: 作業ディレクトリ ${work}`);
  try {
    const fixture = path.join(work, "package-aot");
    copyFixture(fixture);
    const app = path.join(fixture, "app");

    const routes = [];
    const startedAt = Date.now();
    const interpreter = run(executable, ["run", "main.nako3"], { cwd: app });
    if (interpreter.status !== 0) {
      dumpFailureDiagnostics(app);
      probeLocations(expected);
      fail(`Interpreter実行が失敗しました\n${interpreter.stderr}`);
    }
    if (interpreter.stdout !== expected) fail(`Interpreterの観測結果が期待値と一致しません\n期待:\n${expected}\n実際:\n${interpreter.stdout}`);
    routes.push(`interpreter ${Date.now() - startedAt}ms`);

    for (const optimization of optimizations) {
      const routeStartedAt = Date.now();
      const output = path.join(work, `app-${optimization}${executableSuffix}`);
      const built = run(executable, ["build", "main.nako3", "-o", output, `-${optimization}`], { cwd: app });
      if (built.status !== 0) {
        dumpFailureDiagnostics(app);
        fail(`${optimization}のAOT buildが失敗しました\n${built.stderr}`);
      }
      if (!fs.existsSync(output)) fail(`${optimization}の生成物がありません: ${output}`);
      const executed = run(output, [], { cwd: app });
      if (executed.status !== 0) fail(`${optimization}の生成物が異常終了しました\n${executed.stderr}`);
      if (executed.stdout !== expected) fail(`${optimization}の観測結果が期待値と一致しません\n期待:\n${expected}\n実際:\n${executed.stdout}`);
      routes.push(`${optimization} ${Date.now() - routeStartedAt}ms`);
    }

    console.log(`package import AOT検査: ${routes.length}経路が一致 (${routes.join(" / ")})`);

    const rejections = [];
    checkRejections(fixture, work, rejections);
    console.log(`package import AOT検査: 拒否${rejections.length}件がInterpreterと同じ診断でAOT buildを失敗 (${rejections.join(" / ")})`);
    console.log("package import AOT検査: 成功");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
