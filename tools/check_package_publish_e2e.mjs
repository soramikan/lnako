#!/usr/bin/env node
// 参照パッケージ publish→取得 E2E（Issue #58）。
//
// `tests/fixtures/package-publish/` の参照パッケージ群を、このプロセス内の
// 127.0.0.1 fixture registry（PS01 layout の静的 registry + PUT 受理）へ
// `lnako package publish --no-dry-run` で公開し、別の空 project から
//
//   lnako lock → sync → run --compat-js
//
// を実際のバイナリで実行する。公開→取得の protocol 結合を 1 本のスクリプトで
// 検証する。追加の検証:
//
//   - sync --offline: registry を停止した状態で lock + cache だけから
//     環境を再構築できる（fresh 環境と cache 済み offline 環境で同じ成果）。
//   - 失敗経路: (a) npm 依存を持つ package の公開は E039 で拒否される、
//     (b) 未公開 version の取得は lock 解決で失敗する、
//     (c) integrity 不一致の取得は sync で hash 検証失敗となり環境を
//     公開しない、(d) 同一版・同一内容の再公開は冪等に成功する。
//
// 外部ネットワーク・実 registry・npm CLI は使わない。npm packument も
// fixture registry が 127.0.0.1 で配信する（LNAKO_NPM_REGISTRY で向ける）。
// `lnako package publish` は公開時に index.json を更新しない（nako-registry
// の範囲）ため、fixture registry が index を静的に配信する。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureRoot = path.join(root, "tests", "fixtures", "package-publish");
const executableSuffix = process.platform === "win32" ? ".exe" : "";

// fixture registry の Public ID（tests/fixtures/package-publish/README.md と対）。
const OWNER = "soramikan";
const LEFTPAD_ID = "pkg:11111111111111111111111111111111";
const GREETING_ID = "pkg:22222222222222222222222222222222";
const PACKAGE_IDS = { leftpad: LEFTPAD_ID, greeting: GREETING_ID };

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

// spawnSync は Node の event loop を止め、同一プロセスの fixture registry が
// accept できなくなる。子プロセスは必ず非同期 spawn で待つ。
function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? root,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...options.env },
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

async function runExpectFailure(command, args, options, label, expectedText) {
  const result = await run(command, args, options);
  const combined = `${result.stdout}${result.stderr}`;
  if (result.status === 0) fail(`${label}は失敗するべきでした\n${combined}`);
  if (!combined.includes(expectedText)) {
    fail(`${label}の診断に ${expectedText} が含まれません\n${combined}`);
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

function copyFixture(name, destination) {
  fs.cpSync(path.join(fixtureRoot, name), destination, { recursive: true });
}

function readFixture(relativePath) {
  return fs.readFileSync(path.join(fixtureRoot, relativePath), "utf8");
}

// ustar header（plugin+npm E2E と同じ最小 packer）。
function tarHeader(name, size) {
  const header = Buffer.alloc(512, 0);
  header.write(name, 0, 100, "utf8");
  header.write("0000644\0", 100, 8, "ascii");
  header.write("0000000\0", 108, 8, "ascii");
  header.write("0000000\0", 116, 8, "ascii");
  header.write(`${size.toString(8).padStart(11, "0")}\0`, 124, 12, "ascii");
  header.write("00000000000\0", 136, 12, "ascii");
  header.write("        ", 148, 8, "ascii");
  header.write("0", 156, 1, "ascii");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  header.write(`${checksum.toString(8).padStart(6, "0")}\0 `, 148, 8, "ascii");
  return header;
}

/// `package/<path>` を持つ最小 ustar tar.gz を作る（npm cache は `package/`
/// 前置を strip して tree にする）。
function tarball(files) {
  const parts = [];
  for (const [name, content] of files) {
    const data = Buffer.from(content, "utf8");
    parts.push(tarHeader(name, data.length), data);
    const padding = (512 - (data.length % 512)) % 512;
    if (padding > 0) parts.push(Buffer.alloc(padding, 0));
  }
  parts.push(Buffer.alloc(1024, 0));
  return zlib.gzipSync(Buffer.concat(parts), { level: 9 });
}

/// `lnako lock` が npm 依存を解決できるよう、fixture registry が
/// left-pad の packument と tarball を配信する（外部 npm registry を
/// 使わない）。tarball は npm 依存を持つ package の公開が E039 で拒否される
/// までの lock 通過にだけ必要。
const npmTarballArchive = tarball([
  ["package/package.json", JSON.stringify({ name: "left-pad", version: "1.0.0", main: "index.js", license: "MIT" })],
  ["package/index.js", "export default (text) => String(text);\n"],
]);
const npmTarballIntegrity = `sha512-${createHash("sha512").update(npmTarballArchive).digest("base64")}`;

/// PS01 静的 registry + PUT 受理の fixture。
/// - GET `/index.json` / `/<owner>/<name>.json` / `/<owner>/<name>/<ver>.json`
///   / artifact URL: 公開済み状態を返す（publish は index を更新しないため
///   index は fixture が静的に配信する）。
/// - PUT `/<owner>/<name>/<ver>.json` / `/<owner>/<name>/<ver>/<name>-<ver>.npkg`:
///   lnako package publish の送信を記録する。
/// - `tamper` を設定すると leftpad の version record の sha256 を差し替える
///   （integrity 不一致の再現用）。
function createRegistry() {
  const published = new Map(); // name -> version record
  const artifacts = new Map(); // name -> Buffer
  // integrity 不一致の再現用。true のとき leftpad の artifact bytes を別内容
  // に差し替えて配信する（lock の sha256 は本物のまま → hash 検証失敗）。
  let tamperArtifact = false;
  let requestCount = 0;

  function versionRecord(name) {
    return published.get(name) ?? null;
  }

  function indexDoc() {
    return {
      schemaVersion: 1,
      packages: Object.entries(PACKAGE_IDS).map(([name, id]) => {
        const record = versionRecord(name);
        return {
          schemaVersion: 1,
          id,
          name,
          owner: OWNER,
          humanId: `@${OWNER}/${name}`,
          versions: record ? [record] : [],
        };
      }),
    };
  }

  function sendJson(response, body, status = 200) {
    const bytes = Buffer.from(JSON.stringify(body), "utf8");
    response.writeHead(status, { "content-type": "application/json", "content-length": bytes.length });
    response.end(bytes);
  }

  let origin = null;
  const server = http.createServer((request, response) => {
    requestCount += 1;
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks);
      const url = request.url.split("?")[0];
      const segments = url.replace(/^\//, "").split("/");
      if (request.method === "GET") {
        if (url === "/index.json") return sendJson(response, indexDoc());
        if (url === "/left-pad") {
          return sendJson(response, {
            name: "left-pad",
            "dist-tags": { latest: "1.0.0" },
            versions: {
              "1.0.0": {
                name: "left-pad",
                version: "1.0.0",
                dist: { tarball: `${origin}/left-pad/-/left-pad-1.0.0.tgz`, integrity: npmTarballIntegrity },
              },
            },
          });
        }
        if (url === "/left-pad/-/left-pad-1.0.0.tgz") {
          response.writeHead(200, { "content-type": "application/octet-stream", "content-length": npmTarballArchive.length });
          return response.end(npmTarballArchive);
        }
        if (segments.length === 2 && segments[0] === OWNER) {
          const name = segments[1].replace(/\.json$/, "");
          const id = PACKAGE_IDS[name];
          if (!id) { response.writeHead(404); return response.end(); }
          const record = versionRecord(name);
          if (!record) { response.writeHead(404); return response.end(); }
          return sendJson(response, { schemaVersion: 1, id, name, owner: OWNER, humanId: `@${OWNER}/${name}`, versions: [record] });
        }
        if (segments.length === 3 && segments[0] === OWNER) {
          const name = segments[1];
          const version = segments[2].replace(/\.json$/, "");
          const record = versionRecord(name);
          if (!record || record.version !== version) { response.writeHead(404); return response.end(); }
          return sendJson(response, record);
        }
        if (segments.length === 4 && segments[0] === OWNER) {
          const name = segments[1];
          const record = versionRecord(name);
          if (record && record.artifacts.source.url.endsWith(url)) {
            let archive = artifacts.get(name);
            if (!archive) { response.writeHead(404); return response.end(); }
            if (tamperArtifact && name === "leftpad") {
              archive = Buffer.from(archive.toString("latin1").replace("plugin.mjs", "plugin.MJS"), "latin1");
            }
            response.writeHead(200, { "content-type": "application/octet-stream", "content-length": archive.length });
            return response.end(archive);
          }
        }
        response.writeHead(404);
        response.end();
        return;
      }
      if (request.method === "PUT") {
        const segments = url.replace(/^\//, "").split("/");
        // `/<owner>/<name>/<ver>.json` = version record、
        // `/<owner>/<name>/<ver>/<name>-<ver>.npkg` = artifact。
        if (segments.length === 3) {
          const name = segments[1];
          published.set(name, JSON.parse(body.toString("utf8")));
          response.writeHead(201);
          return response.end();
        }
        if (segments.length === 4) {
          artifacts.set(segments[1], body);
          response.writeHead(201);
          return response.end();
        }
      }
      response.writeHead(404);
      response.end();
    });
  });

  return {
    server,
    listen: () => new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
      origin = `http://127.0.0.1:${server.address().port}`;
      resolve(origin);
    })),
    close: () => new Promise((resolve) => server.close(() => resolve())),
    set tamperArtifact(value) { tamperArtifact = value; },
    get requestCount() { return requestCount; },
    publishedRecord(name) { return published.get(name) ?? null; },
    putCount() { return published.size; },
  };
}

/// 同一版・同一内容の再公開（冪等性）を確認する。lnako は公開前照会
/// （GET version record）で同一 artifact hash を検出して PUT を省略するため、
/// PUT 総数が増えずに成功する。
async function checkRepublishIsIdempotent(compiler, registry, appDir, env, name) {
  const putsBefore = registry.putCount();
  await runChecked(compiler, ["package", "publish", "--no-dry-run", "--registry", registry.origin, "--owner", OWNER], { cwd: appDir, env }, `${name} 再公開`);
  if (registry.putCount() !== putsBefore) fail("再公開が新しい PUT を発生させました");
  const record = registry.publishedRecord(name);
  if (!record) fail(`${name} の version record がありません`);
}

async function main() {
  const options = parseArguments();
  const compiler = options.compiler;
  const expectedStdout = readFixture("expected-stdout.txt");
  const work = createWorkDir();
  const registry = createRegistry();
  const origin = await registry.listen();
  registry.origin = origin;
  const publishEnv = { LNAKO_REGISTRY: origin, LNAKO_REGISTRY_TOKEN: "fixture-token", LNAKO_NPM_REGISTRY: origin };
  console.log(`参照 publish E2E: registry ${origin}`);

  try {
    // --- publish: leftpad（ESM plugin）→ greeting（pkg 依存）→ bundled（path 依存同梱） ---
    const leftpad = path.join(work, "leftpad");
    copyFixture("leftpad", leftpad);
    await runChecked(compiler, ["lock"], { cwd: leftpad, env: publishEnv }, "leftpad lock");
    await runChecked(compiler, ["package", "publish", "--no-dry-run", "--registry", origin, "--owner", OWNER], { cwd: leftpad, env: publishEnv }, "leftpad publish");
    const leftpadRecord = registry.publishedRecord("leftpad");
    if (!leftpadRecord || leftpadRecord.version !== "1.0.0") fail("leftpad の version record が不正です");
    if (!leftpadRecord.artifacts.source.sha256.startsWith("sha256:")) fail("leftpad record の artifact hash がありません");
    console.log("参照 publish E2E: leftpad publish OK（ESM plugin、compat-js profile で検証）");

    // greeting の lock は fixture registry から leftpad を解決する。
    const greeting = path.join(work, "greeting");
    copyFixture("greeting", greeting);
    await runChecked(compiler, ["lock"], { cwd: greeting, env: publishEnv }, "greeting lock");
    await runChecked(compiler, ["package", "publish", "--no-dry-run", "--registry", origin, "--owner", OWNER], { cwd: greeting, env: publishEnv }, "greeting publish");
    const greetingRecord = registry.publishedRecord("greeting");
    if (!greetingRecord) fail("greeting の version record がありません");
    if (JSON.stringify(greetingRecord.dependencies) !== JSON.stringify([LEFTPAD_ID])) {
      fail(`greeting record の dependencies が leftpad の Public ID ではありません: ${JSON.stringify(greetingRecord.dependencies)}`);
    }
    console.log("参照 publish E2E: greeting publish OK（pkg 依存 edge を record へ記録）");

    // path 依存を payload へ同梱する package の公開（consumer sync はしない。
    // 同梱 path 依存の registry 取得は現行未対応のため、公開側の検証だけを行う）。
    const bundled = path.join(work, "bundled");
    copyFixture("bundled", bundled);
    await runChecked(compiler, ["lock"], { cwd: bundled, env: publishEnv }, "bundled lock");
    await runChecked(compiler, ["package", "publish", "--no-dry-run", "--registry", origin, "--owner", OWNER], { cwd: bundled, env: publishEnv }, "bundled publish");
    console.log("参照 publish E2E: bundled publish OK（path 依存を payload へ同梱）");

    // --- 冪等性: 同一版・同一内容の再公開は PUT 無しで成功する ---
    await checkRepublishIsIdempotent(compiler, registry, leftpad, publishEnv, "leftpad");
    console.log("参照 publish E2E: 再公開 OK（同一版・同一 hash はスキップ）");

    // --- 失敗経路 (a): npm 依存を持つ package の公開は拒否される ---
    const npmDep = path.join(work, "npmdep");
    fs.mkdirSync(path.join(npmDep, "src"), { recursive: true });
    fs.writeFileSync(path.join(npmDep, "nako.toml"), [
      "[package]",
      'name = "npm-dep-package"',
      'version = "1.0.0"',
      'license = "MIT"',
      "",
      "[dependencies.npm]",
      'left-pad = "^1.0.0"',
      "",
      "[[exports]]",
      'name = "main"',
      'path = "src/main.nako3"',
      "",
    ].join("\n"));
    fs.writeFileSync(path.join(npmDep, "src", "main.nako3"), "「hi」を表示。\n");
    await runChecked(compiler, ["lock"], { cwd: npmDep, env: publishEnv }, "npm依存 package lock");
    await runExpectFailure(
      compiler,
      ["package", "publish", "--dry-run", "--registry", origin, "--owner", OWNER],
      { cwd: npmDep, env: publishEnv },
      "npm依存 package publish",
      "E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY",
    );
    console.log("参照 publish E2E: npm 依存の公開拒否 OK（E039）");

    // --- consumer: 別の空 project から取得して lock/sync/run ---
    const consumer = path.join(work, "consumer");
    fs.mkdirSync(consumer, { recursive: true });
    fs.writeFileSync(path.join(consumer, "nako.toml"), [
      "[package]",
      'name = "greeting-consumer"',
      'version = "0.1.0"',
      'license = "MIT"',
      "",
      "[profiles.compat]",
      'runtime = "lnako"',
      'os = "linux"',
      'cpu = "x86_64"',
      'abi = "gnu"',
      "compat-js = true",
      "",
      "[dependencies.pkg]",
      `greeting = { version = ">=1.0.0 <2.0.0", public-id = "${GREETING_ID}" }`,
      `leftpad = { version = ">=1.0.0 <2.0.0", public-id = "${LEFTPAD_ID}" }`,
      "",
    ].join("\n"));
    fs.writeFileSync(path.join(consumer, "main.nako3"), [
      "!「pkg:greeting」を取り込む",
      "!「pkg:leftpad」を取り込む",
      "greeting__挨拶",
      "leftpad__整形(「ab」)を表示",
      "",
    ].join("\n"));
    const consumerEnv = { LNAKO_REGISTRY: origin };
    const cacheDir = path.join(consumer, "cache");
    await runChecked(compiler, ["lock", "--package-cache-dir", cacheDir], { cwd: consumer, env: consumerEnv }, "consumer lock");
    await runChecked(compiler, ["sync", "--package-cache-dir", cacheDir], { cwd: consumer, env: consumerEnv }, "consumer sync");
    const executed = await runChecked(compiler, ["run", "main.nako3", "--compat-js"], { cwd: consumer, env: consumerEnv }, "consumer run --compat-js");
    if (executed.stdout !== expectedStdout) {
      fail(`consumer run の stdout が期待値と異なります:\n--- expected ---\n${expectedStdout}\n--- actual ---\n${executed.stdout}`);
    }
    console.log("参照 publish E2E: consumer lock/sync/run OK（registry 取得→実行）");

    // --- offline: lock + cache だけから再構築する ---
    // `--offline` は取得を fail-closed するため、通信が発生しないこと
    // （request 数が増えない）を含めて検査する。fixture server は起動した
    // ままでも、offline 実行がそれへ到達しないことを request 数で固定する。
    const requestsBeforeOffline = registry.requestCount;
    await runChecked(compiler, ["sync", "--offline", "--package-cache-dir", cacheDir], { cwd: consumer, env: consumerEnv }, "consumer sync --offline");
    if (registry.requestCount !== requestsBeforeOffline) {
      fail("sync --offline が fixture registry へ要求しました");
    }
    const reExecuted = await runChecked(compiler, ["run", "main.nako3", "--compat-js", "--offline"], { cwd: consumer, env: consumerEnv }, "consumer run --compat-js --offline");
    if (reExecuted.stdout !== expectedStdout) {
      fail(`offline run の stdout が期待値と異なります:\n--- expected ---\n${expectedStdout}\n--- actual ---\n${reExecuted.stdout}`);
    }
    console.log("参照 publish E2E: sync --offline OK（cache 済み環境で同じ成果）");

    // --- 失敗経路 (b): 未公開 version の取得は lock 解決で失敗する ---
    const badVersion = path.join(work, "badver");
    fs.mkdirSync(badVersion, { recursive: true });
    fs.writeFileSync(path.join(badVersion, "nako.toml"), [
      "[package]",
      'name = "greeting-consumer-badver"',
      'version = "0.1.0"',
      'license = "MIT"',
      "",
      "[profiles.compat]",
      'runtime = "lnako"',
      'os = "linux"',
      'cpu = "x86_64"',
      'abi = "gnu"',
      "compat-js = true",
      "",
      "[dependencies.pkg]",
      `greeting = { version = ">=2.0.0 <3.0.0", public-id = "${GREETING_ID}" }`,
      "",
    ].join("\n"));
    const badVersionCache = path.join(badVersion, "cache");
    await runExpectFailure(
      compiler,
      ["lock", "--package-cache-dir", badVersionCache],
      { cwd: badVersion, env: { LNAKO_REGISTRY: origin } },
      "未公開 version の lock",
      "E003_CONFLICTING_VERSIONS",
    );
    console.log("参照 publish E2E: 未公開 version の取得拒否 OK（E003）");

    // --- 失敗経路 (c): integrity 不一致は sync で拒否され環境を公開しない ---
    // leftpad の artifact bytes を別内容に差し替えて配信する。lock に記録
    // された sha256 は本物のままなので、cache 欠落の consumer 副本が
    // artifact を再取得した時点で hash 検証に失敗する。検証後は tamper を
    // 解除する（以降の観測に影響しない）。
    registry.tamperArtifact = true;
    const tampered = tamperedConsumerDir(work);
    try {
      await runExpectFailure(
        compiler,
        ["sync", "--package-cache-dir", path.join(tampered, "cache")],
        { cwd: tampered, env: { LNAKO_REGISTRY: origin } },
        "integrity 不一致の sync",
        "E009_HASH_MISMATCH",
      );
    } finally {
      registry.tamperArtifact = false;
    }
    if (fs.existsSync(path.join(tampered, ".nako", "environment.json"))) {
      fail("integrity 不一致の sync が環境を公開しました");
    }
    console.log("参照 publish E2E: integrity 不一致の拒否 OK");

    console.log("参照 publish E2E: 成功");
  } finally {
    await registry.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

/// integrity 不一致検証専用の consumer 副本を作る（本体 consumer の成功状態を
/// 汚さない）。`work/consumer-tampered` は consumer と同じ manifest・entry・
/// lock を持ち、cache・環境を持たないため sync が artifact を再取得する。
function tamperedConsumerDir(work) {
  const dir = path.join(work, "consumer-tampered");
  if (!fs.existsSync(dir)) {
    fs.cpSync(path.join(work, "consumer"), dir, { recursive: true });
    fs.rmSync(path.join(dir, "cache"), { recursive: true, force: true });
    fs.rmSync(path.join(dir, ".nako"), { recursive: true, force: true });
  }
  return dir;
}

await main();
