#!/usr/bin/env node
// 旧 publish→取得 E2E の後継（v1 境界）。
//
// v1 は旧 static PUT・PS01 registry・.npkg publish を公開経路に使わない
// （P07/P11 の対象外）。この検査は、旧 `package publish` がローカルで
// 対象外を診断し、ネットワークへ送信せず終了すること、旧 .npkg が入力
// バイトを書き換えずに拒否されること、新 v1 の package build → verify と
// ローカル実行が成立することを実バイナリで固定する。
//
// registry の再実装、publish protocol、npm 依存解決、旧 lock/環境の移行は
// 行わない。loopback の HTTP listener は「送信が無い」ことの検出だけに使い、
// 要求へは応答しない。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const legacyFixtureRoot = path.join(root, "tests", "fixtures", "package-publish", "leftpad");
const executableSuffix = process.platform === "win32" ? ".exe" : "";

function fail(message) {
  throw new Error(`参照 publish E2E: ${message}`);
}

function parseArguments() {
  const options = { compiler: path.join(root, "zig-out", "bin", `lnako${executableSuffix}`) };
  const args = process.argv.slice(2);
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--compiler") {
      const value = args[index + 1];
      if (value === undefined) fail("--compilerにはパスを指定してください");
      options.compiler = path.resolve(value);
      // Windows では明示パスにも .exe 補完を許す（既存の package E2E と同様）。
      if (!fs.existsSync(options.compiler) && fs.existsSync(`${options.compiler}.exe`)) {
        options.compiler = `${options.compiler}.exe`;
      }
      index += 1;
    } else if (args[index] === "--help" || args[index] === "-h") {
      console.log("usage: node tools/check_package_publish_e2e.mjs [--compiler <path>]");
      process.exit(0);
    } else {
      fail(`不明な引数です: ${args[index]}`);
    }
  }
  if (!fs.existsSync(options.compiler)) fail(`compilerがありません: ${options.compiler}`);
  return options;
}

// 環境変数は検査で明示した値だけを渡す。CI/ローカルのシェルに残存する
// LNAKO_*（実 registry の URL・token 等）を子プロセスへ引き継がない。
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
// 拒否され得る。package plugin+npm E2E と同じく user private な home 配下を
// 優先して作業 dir を作る。
function createWorkDir() {
  for (const base of [os.homedir(), os.tmpdir()]) {
    try {
      return fs.mkdtempSync(path.join(base, ".lnako-publish-e2e-"));
    } catch {
      // 次の候補へ
    }
  }
  fail("作業ディレクトリを作成できません");
}

function sha256(file) {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function copyLegacyPackage(destination) {
  fs.cpSync(legacyFixtureRoot, destination, { recursive: true });
}

// 旧 .npkg（NAKO-PKG/ 制御ファイル）を最小の store ZIP として作る。
// v1 の verify は構造検証より先に旧制御ファイル名を検出し、移行診断を出す。
function createLegacyArchive(destination) {
  const files = [
    ["NAKO-PKG/FILES.toml", Buffer.from("schema_version = 1\n[[files]]\npath = \"main.nako3\"\n", "utf8")],
    ["NAKO-PKG/commands.json", Buffer.from("{\"commands\":[]}\n", "utf8")],
    ["main.nako3", Buffer.from("「legacy」を表示\n", "utf8")],
  ];
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const [name, data] of files) {
    const nameBytes = Buffer.from(name, "utf8");
    const crc = zlib.crc32(data) >>> 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6); // EFS: UTF-8
    local.writeUInt16LE(0, 8); // store
    local.writeUInt16LE(0, 10); // 00:00:00
    local.writeUInt16LE(0x0021, 12); // 1980-01-01
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, nameBytes, data);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x0021, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(0, 38);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, nameBytes);
    offset += local.length + nameBytes.length + data.length;
  }
  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  fs.writeFileSync(destination, Buffer.concat([...localParts, centralDirectory, end]));
}

// 送信の有無だけを見る listener。registry の GET/PUT や .npkg は解釈しない。
function createRequestDetector() {
  const requests = [];
  let origin = null;
  const server = http.createServer((request, response) => {
    requests.push(`${request.method} ${request.url}`);
    response.writeHead(500, { "content-type": "text/plain" });
    response.end("unexpected request");
  });
  return {
    server,
    requests,
    listen: () => new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
      origin = `http://127.0.0.1:${server.address().port}`;
      resolve(origin);
    })),
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function writeV1Package(projectDir) {
  fs.mkdirSync(path.join(projectDir, "src"), { recursive: true });
  fs.writeFileSync(path.join(projectDir, "nako.toml"), [
    "schema_version = 1",
    "",
    "[package]",
    'id = "@example/local"',
    'version = "1.0.0"',
    'license = "MIT"',
    'capabilities = ["pure-nako"]',
    "",
    "[exports]",
    '"." = { entry = "src/main.nako3", binding = "scoped" }',
    "",
    "[artifacts.universal]",
    'include = ["src/**/*.nako3"]',
    "",
  ].join("\n"));
  fs.writeFileSync(path.join(projectDir, "src", "main.nako3"), "「v1-package」を表示\n");
}

async function main() {
  const options = parseArguments();
  const work = createWorkDir();
  const legacy = path.join(work, "legacy");
  const v1 = path.join(work, "v1");
  const detector = createRequestDetector();
  let origin = null;
  try {
    origin = await detector.listen();
    console.log(`参照 publish E2E: 送信検出 listener ${origin}`);

    // --- 旧 publish CLI: 旧 manifest を持っていても送信せずローカルで終了 ---
    copyLegacyPackage(legacy);
    const publish = await runFailure(
      options.compiler,
      ["package", "publish", "--no-dry-run", "--registry", origin, "--owner", "soramikan"],
      {
        cwd: legacy,
        env: cleanEnv({
          LNAKO_REGISTRY: origin,
          LNAKO_REGISTRY_TOKEN: "fixture-token",
          LNAKO_NPM_REGISTRY: origin,
        }),
      },
      "旧 publish CLI",
      ["対象外", "POST /v1/packages/{scope}/{name}/releases"],
    );
    if (publish.status !== 2) fail(`旧 publish CLI の exit が 2 ではありません: ${publish.status}`);
    if (detector.requests.length !== 0) {
      fail(`旧 publish CLI が送信しました: ${detector.requests.join(", ")}`);
    }
    console.log("参照 publish E2E: 旧 publish CLI はローカル診断のみで送信なし");

    // --- 旧 .npkg: 移行診断で拒否し、入力を書き換えない ---
    const legacyArchive = path.join(work, "legacy.npkg");
    createLegacyArchive(legacyArchive);
    const archiveBefore = sha256(legacyArchive);
    await runFailure(
      options.compiler,
      ["package", "verify", legacyArchive],
      { cwd: work, env: cleanEnv() },
      "旧 .npkg の verify",
      ["旧制御ファイル", "再作成"],
    );
    if (sha256(legacyArchive) !== archiveBefore) fail("旧 .npkg の verify が入力ファイルを書き換えました");
    console.log("参照 publish E2E: 旧 .npkg は非書換えで拒否");

    // --- 新 v1: ローカルで build → verify → run が完結する ---
    writeV1Package(v1);
    const archive = path.join(v1, "local.npkg");
    const built = await runChecked(
      options.compiler,
      ["package", "build", ".", "--kind", "universal", "-o", archive],
      { cwd: v1, env: cleanEnv() },
      "v1 package build",
    );
    if (!fs.existsSync(archive)) fail("v1 package build が .npkg を生成しませんでした");
    if (!built.stdout.includes("@example/local") || !built.stdout.includes("universal")) {
      fail(`v1 package build の出力が package を識別していません: ${built.stdout}`);
    }
    const verified = await runChecked(
      options.compiler,
      ["package", "verify", archive],
      { cwd: v1, env: cleanEnv() },
      "v1 package verify",
    );
    if (!verified.stdout.includes("@example/local 1.0.0") || !verified.stdout.includes("検証 OK")) {
      fail(`v1 package verify の出力が期待値と異なります: ${verified.stdout}`);
    }
    const executed = await runChecked(
      options.compiler,
      ["run", "src/main.nako3"],
      { cwd: v1, env: cleanEnv() },
      "v1 ローカル実行",
    );
    if (executed.stdout !== "v1-package\n") {
      fail(`v1 ローカル実行の stdout が期待値と異なります: ${JSON.stringify(executed.stdout)}`);
    }
    if (detector.requests.length !== 0) {
      fail(`v1 のローカル処理が外部へ送信しました: ${detector.requests.join(", ")}`);
    }
    console.log("参照 publish E2E: v1 の build/verify/ローカル実行 OK（送信なし）");

    console.log("参照 publish E2E: 成功（旧 registry/公開経路は v1 対象外）");
  } finally {
    await detector.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

await main();
