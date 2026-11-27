#!/usr/bin/env node
// 旧 npm/ESM plugin E2E の後継（v1 境界）。
//
// 旧形式の `nako.toml`（schema_version なし、[dependencies.npm] /
// [dependencies.path]、[[exports]]）は v1 の読み替え対象ではない。製品は
// 旧 manifest を旧 loader へ流さず、移行診断を出して拒否する（P10、Q12）。
// この検査は、その拒否がプロジェクトを書き換えないことと、v1 のローカル
// 実行および `--compat-js` の言語実行が維持されていることを実バイナリで
// 固定する。
//
// 旧 npm registry・npm 依存解決・旧 lock の移行は検査しない。これらは
// P10/P11 の対象外であり、旧 fixture の成功を期待する E2E をここへ
// 再実装しない。旧 package import の公式差分（tools/compare_package_import_*）
// は別担当で、ここでは変更しない。旧 package の非書換え拒否と publish の
// 送信なし終了は tools/check_package_publish_e2e.mjs が担当する。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const legacyFixtureRoot = path.join(root, "tests", "fixtures", "package-plugin-npm", "app");
const executableSuffix = process.platform === "win32" ? ".exe" : "";

function fail(message) {
  throw new Error(`参照 plugin+npm E2E: ${message}`);
}

function parseArguments() {
  const options = { compiler: path.join(root, "zig-out", "bin", `lnako${executableSuffix}`) };
  const args = process.argv.slice(2);
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--compiler") {
      const value = args[index + 1];
      if (value === undefined) fail("--compilerにはパスを指定してください");
      options.compiler = path.resolve(value);
      // Windows では明示パスにも .exe 補完を許す（既存の AOT 分離検査と同様）。
      if (!fs.existsSync(options.compiler) && fs.existsSync(`${options.compiler}.exe`)) {
        options.compiler = `${options.compiler}.exe`;
      }
      index += 1;
    } else if (args[index] === "--help" || args[index] === "-h") {
      console.log("usage: node tools/check_package_plugin_npm_e2e.mjs [--compiler <path>]");
      process.exit(0);
    } else {
      fail(`不明な引数です: ${args[index]}`);
    }
  }
  if (!fs.existsSync(options.compiler)) fail(`compilerがありません: ${options.compiler}`);
  return options;
}

// 取得先の環境変数を継承しない。この検査はネットワークを使わない。
function cleanEnv(extra = {}) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.startsWith("LNAKO_")) delete env[key];
  }
  return { ...env, ...extra };
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? root,
      stdio: ["ignore", "pipe", "pipe"],
      env: options.env ?? cleanEnv(),
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${command} ${args.join(" ")}: timeout`));
    }, 900_000);
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (status) => {
      clearTimeout(timer);
      resolve({ status, stdout: stdout.replace(/\r\n/g, "\n"), stderr: stderr.replace(/\r\n/g, "\n") });
    });
  });
}

async function runChecked(command, args, options, label) {
  const result = await run(command, args, options);
  if (result.status !== 0) {
    fail(`${label}が失敗しました（exit=${result.status}）\n${result.stdout}${result.stderr}`);
  }
  return result;
}

async function runFailure(command, args, options, label, expectedTexts) {
  const expectedList = Array.isArray(expectedTexts) ? expectedTexts : [expectedTexts];
  const result = await run(command, args, options);
  const combined = `${result.stdout}${result.stderr}`;
  if (result.status === 0) fail(`${label}は失敗するべきでした\n${combined}`);
  for (const expected of expectedList) {
    if (!combined.includes(expected)) fail(`${label}の診断に ${expected} が含まれません\n${combined}`);
  }
  return result;
}

// project 信頼検証は配置 dir の ACL を見るため、CI の workspace 継承 ACL で
// 拒否され得る。package import AOT 検査と同じく user private な home 配下を
// 優先して作業 dir を作る。
function createWorkDir() {
  for (const base of [os.homedir(), os.tmpdir()]) {
    try {
      return fs.mkdtempSync(path.join(base, ".lnako-plugin-npm-e2e-"));
    } catch {
      // 次の候補へ
    }
  }
  fail("作業ディレクトリを作成できません");
}

function sha256(file) {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function assertNotRewritten(file, before, label) {
  if (sha256(file) !== before) fail(`${label}が入力ファイルを書き換えました: ${file}`);
}

// 旧 manifest の実 fixture を負例として使う。旧 npm/ESM 経路の成功を
// 再現するのではなく、v1 の通常入口が読み替えず拒否することを見る。
function copyLegacyProject(destination) {
  fs.cpSync(legacyFixtureRoot, destination, { recursive: true });
}

function assertNoEnvironmentWrites(projectDir) {
  const forbidden = ["nako.lock", path.join(".nako", "v1"), path.join(".nako", "environment.json")];
  for (const relative of forbidden) {
    if (fs.existsSync(path.join(projectDir, relative))) {
      fail(`旧 manifest の拒否時に ${relative} が生成されました: ${projectDir}`);
    }
  }
}

function writeV1Project(projectDir) {
  fs.mkdirSync(projectDir, { recursive: true });
  fs.writeFileSync(path.join(projectDir, "nako.toml"), [
    "schema_version = 1",
    "",
    "[package]",
    'id = "@example/local"',
    'version = "1.0.0"',
    'license = "MIT"',
    'capabilities = ["pure-nako"]',
    "",
  ].join("\n"));
  fs.writeFileSync(path.join(projectDir, "main.nako3"), "「v1-local」を表示\n");
  fs.writeFileSync(path.join(projectDir, "compat.nako3"), "JS実行(\"1+2\")を表示\n");
}

async function main() {
  const options = parseArguments();
  const work = createWorkDir();
  const legacy = path.join(work, "legacy");
  const v1 = path.join(work, "v1");
  try {
    copyLegacyProject(legacy);
    const manifestPath = path.join(legacy, "nako.toml");
    const manifestBefore = sha256(manifestPath);

    // 旧 manifest は sync でも run でも、旧 loader・旧 lock へ分岐せず
    // 再作成を案内して終了する。manifest はバイト単位で不変。
    await runFailure(options.compiler, ["sync"], { cwd: legacy }, "旧 manifest の sync", ["旧形式", "再作成"]);
    await runFailure(options.compiler, ["run", "main.nako3"], { cwd: legacy }, "旧 manifest の run", ["旧形式", "再作成"]);
    // `package build` も旧形式を読み替えない。出力ファイルは作られない。
    const legacyArchive = path.join(legacy, "legacy.npkg");
    await runFailure(
      options.compiler,
      ["package", "build", ".", "--kind", "universal", "-o", legacyArchive],
      { cwd: legacy },
      "旧 manifest の package build",
      ["旧形式", "再作成"],
    );
    if (fs.existsSync(legacyArchive)) fail("旧 manifest から .npkg が生成されました");
    assertNotRewritten(manifestPath, manifestBefore, "旧 manifest の sync/build");
    assertNoEnvironmentWrites(legacy);
    console.log("参照 plugin+npm E2E: 旧 manifest は移行診断で拒否し、書換え・環境生成なし");

    // 新 v1 の依存なしローカルプロジェクトは、旧 lock/環境なしで実行できる。
    // 通常モードでは QuickJS を要求し、--compat-js のときだけ JS を実行する。
    writeV1Project(v1);
    const normal = await runChecked(options.compiler, ["run", "main.nako3"], { cwd: v1 }, "v1 ローカル実行");
    if (normal.stdout !== "v1-local\n") {
      fail(`v1 ローカル実行の stdout が期待値と異なります: ${JSON.stringify(normal.stdout)}`);
    }
    const compat = await runChecked(options.compiler, ["run", "compat.nako3", "--compat-js"], { cwd: v1 }, "v1 compat-js 実行");
    if (compat.stdout !== "3\n") {
      fail(`v1 compat-js 実行の stdout が期待値と異なります: ${JSON.stringify(compat.stdout)}`);
    }
    const normalCompat = await runFailure(
      options.compiler,
      ["run", "compat.nako3"],
      { cwd: v1 },
      "v1 compat-js なし実行",
      ["QuickJsCompatibilityRequired"],
    );
    if (normalCompat.stdout.includes("3")) {
      fail("--compat-js なしの実行が JS を実行しました");
    }
    assertNoEnvironmentWrites(v1);
    console.log("参照 plugin+npm E2E: v1 ローカル実行 OK（通常モードと --compat-js を分離）");

    console.log("参照 plugin+npm E2E: 成功（旧 npm/ESM package 経路は v1 対象外）");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

await main();
