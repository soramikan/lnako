#!/usr/bin/env node
// 参照 plugin+npm E2E（Issue #54）。
//
// `tests/fixtures/package-plugin-npm` の参照パッケージを一時ディレクトリへ
// 複製し、127.0.0.1 の fixture registry（packument + tarball）から
//
//   lnako lock → sync --offline → run --compat-js
//
// を実際のバイナリで実行する。ESM plugin 命令と npm bare import が同時に
// 動くことを stdout 全体で確認する。加えて `--backend aot` で同じ project を
// ビルドし、AOT runtime の ESM manifest 経由で npm bare import が解決できる
// ことを確認する（ESM plugin 命令の AOT dispatch は follow-up のため、AOT は
// `aot-main.nako3` = JS実行経由の entry を使う。この制約は出力に明記する）。
//
// 外部ネットワーク・npm CLI・Node lifecycle script は起動しない。registry は
// このプロセス内の HTTP server を 127.0.0.1 で listen する（#226 と同じ方針）。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureRoot = path.join(root, "tests", "fixtures", "package-plugin-npm");
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

function tarHeader(name, size) {
  const header = Buffer.alloc(512, 0);
  header.write(name, 0, 100, "utf8");
  header.write("0000644\0", 100, 8, "ascii");
  header.write("0000000\0", 108, 8, "ascii");
  header.write("0000000\0", 116, 8, "ascii");
  header.write(`${size.toString(8).padStart(11, "0")}\0`, 124, 12, "ascii");
  header.write("00000000000\0", 136, 12, "ascii");
  header.write("        ", 148, 8, "ascii"); // checksum placeholder
  header.write("0", 156, 1, "ascii");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  header.write(`${checksum.toString(8).padStart(6, "0")}\0 `, 148, 8, "ascii");
  return header;
}

/// `package/<path>` を持つ最小 ustar tar.gz を作る。lnako の npm cache は
/// tarball の `package/` 前置を strip して tree にする。
function tarball(files) {
  const parts = [];
  for (const [name, content] of files) {
    const data = Buffer.from(content, "utf8");
    parts.push(tarHeader(name, data.length), data);
    const padding = (512 - (data.length % 512)) % 512;
    if (padding > 0) parts.push(Buffer.alloc(padding, 0));
  }
  parts.push(Buffer.alloc(1024, 0)); // end-of-archive blocks
  return zlib.gzipSync(Buffer.concat(parts), { level: 9 });
}

function createRegistry(packageName, version, entry) {
  // license は SBOM（--sbom）の licenseDeclared 検証対象。
  const packageJson = JSON.stringify({ name: packageName, version, main: "index.js", license: "MIT" });
  const archive = tarball([
    ["package/package.json", packageJson],
    ["package/index.js", entry],
  ]);
  const integrity = `sha512-${createHash("sha512").update(archive).digest("base64")}`;
  const requests = [];
  let origin = null;
  const server = http.createServer((request, response) => {
    requests.push(request.url);
    if (request.url === `/${packageName}`) {
      const body = JSON.stringify({
        name: packageName,
        "dist-tags": { latest: version },
        versions: {
          [version]: {
            name: packageName,
            version,
            dist: { tarball: `${origin}/${packageName}/-/${packageName}-${version}.tgz`, integrity },
          },
        },
      });
      response.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
      response.end(body);
      return;
    }
    if (request.url === `/${packageName}/-/${packageName}-${version}.tgz`) {
      response.writeHead(200, { "content-type": "application/octet-stream", "content-length": archive.length });
      response.end(archive);
      return;
    }
    response.writeHead(404);
    response.end();
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

/// SBOM（SPDX 2.3 風）を読み、同梱 package の license と purl を検査する。
function validateSbom(sbomPath, expectedPackages) {
  if (!fs.existsSync(sbomPath)) fail(`SBOM が生成されていません: ${sbomPath}`);
  let sbom;
  try {
    sbom = JSON.parse(fs.readFileSync(sbomPath, "utf8"));
  } catch (error) {
    fail(`SBOM が JSON として読めません: ${error.message}`);
  }
  if (sbom.spdxVersion !== "SPDX-2.3" || sbom.SPDXID !== "SPDXRef-DOCUMENT") {
    fail("SBOM の SPDX 2.3 ヘッダが不正です");
  }
  if (!Array.isArray(sbom.packages) || !Array.isArray(sbom.files) || !Array.isArray(sbom.relationships)) {
    fail("SBOM の packages/files/relationships が配列ではありません");
  }
  for (const expected of expectedPackages) {
    const record = sbom.packages.find((item) => item.name === expected.name && item.versionInfo === expected.version);
    if (!record) fail(`SBOM に同梱 package ${expected.name}@${expected.version} がありません`);
    if (record.licenseDeclared !== expected.license) {
      fail(`SBOM の ${expected.name} の licenseDeclared が ${expected.license} ではありません: ${record.licenseDeclared}`);
    }
    if (!record.externalRefs?.some((ref) => ref.referenceLocator === expected.purl)) {
      fail(`SBOM の ${expected.name} に purl ${expected.purl} がありません`);
    }
  }
  return sbom;
}

function readFixture(relativePath) {
  return fs.readFileSync(path.join(fixtureRoot, relativePath), "utf8");
}

/// materialize された npm instance の entry を返す。instance を 1 件に固定し、
/// 「どれか 1 つが一致」ではなく「唯一の instance の内容が一致」を要求する。
function findMaterialized(envRoot) {
  if (!fs.existsSync(envRoot)) fail(`sync が .nako/env を生成していません: ${envRoot}`);
  const candidates = [];
  const generations = fs.readdirSync(envRoot, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  for (const generation of generations) {
    const deps = path.join(envRoot, generation.name, "deps");
    if (!fs.existsSync(deps)) continue;
    for (const entry of fs.readdirSync(deps, { withFileTypes: true })) {
      if (!entry.isDirectory() || !entry.name.startsWith("npm_")) continue;
      const candidate = path.join(deps, entry.name, "index.js");
      if (fs.existsSync(candidate)) candidates.push(fs.readFileSync(candidate, "utf8"));
    }
  }
  return { count: candidates.length, content: candidates[0] ?? null };
}

async function main() {
  const options = parseArguments();
  const expectedStdout = readFixture("expected-stdout.txt");
  const expectedAotStdout = readFixture("expected-aot-stdout.txt");
  const registryEntry = readFixture("registry/left-pad/index.js");
  const work = createWorkDir();
  const app = path.join(work, "app");
  const cache = path.join(work, "cache");
  const registry = createRegistry("left-pad", "1.0.0", registryEntry);
  try {
    fs.cpSync(path.join(fixtureRoot, "app"), app, { recursive: true });
    fs.mkdirSync(cache);
    const origin = await registry.listen();
    const env = { LNAKO_NPM_REGISTRY: origin };
    console.log(`参照 plugin+npm E2E: registry ${origin}`);

    // --- lock: packument/tarball 取得 → integrity 検証 → cache 格納 ---
    await runChecked(options.compiler, ["lock", "--package-cache-dir", cache], { cwd: app, env }, "lock");
    if (registry.requests.length !== 2) {
      fail(`lock の registry 要求数が 2 ではありません: ${registry.requests.length} (${registry.requests.join(", ")})`);
    }
    const lock = fs.readFileSync(path.join(app, "nako.lock"), "utf8");
    if (!lock.includes('"left-pad@1.0.0"')) fail("nako.lock に npm instance left-pad@1.0.0 がありません");
    if (!lock.includes('"implementation": "ESM"')) fail("nako.lock に ESM 実装の plugin package がありません");
    console.log("参照 plugin+npm E2E: lock OK（npm instance と ESM plugin を記録）");

    // --- sync --offline: lock と cache だけで materialize する ---
    const before = registry.requests.length;
    await runChecked(options.compiler, ["sync", "--offline", "--package-cache-dir", cache], { cwd: app }, "sync --offline");
    if (registry.requests.length !== before) {
      fail(`sync --offline が registry へ要求しました: ${registry.requests.slice(before).join(", ")}`);
    }
    const materialized = findMaterialized(path.join(app, ".nako", "env"));
    if (materialized.count !== 1) {
      fail(`materialize された npm instance が 1 件ではありません: ${materialized.count}`);
    }
    if (materialized.content !== registryEntry) fail("sync が npm tree を materialize していません");
    console.log("参照 plugin+npm E2E: sync --offline OK（cache から npm tree を materialize）");

    // --- run --compat-js: plugin 命令と npm bare import の同時実行 ---
    // `--offline` で auto-prep の再取得を禁じ、要求数も増えないことを固定する
    // （環境が stale なら fail し、実 registry へフォールバックしない）。
    const beforeRun = registry.requests.length;
    const executed = await runChecked(options.compiler, ["run", "main.nako3", "--compat-js", "--offline"], { cwd: app, env }, "run --compat-js");
    if (registry.requests.length !== beforeRun) {
      fail(`run --compat-js が registry へ要求しました: ${registry.requests.slice(beforeRun).join(", ")}`);
    }
    if (executed.stdout !== expectedStdout) {
      fail(`run --compat-js の stdout が期待値と異なります:\n--- expected ---\n${expectedStdout}\n--- actual ---\n${executed.stdout}`);
    }
    // 通常モード分離: --compat-js なしでは JS/ESM を取り込まない。
    const normal = await run(options.compiler, ["run", "main.nako3", "--offline"], { cwd: app, env });
    if (normal.status === 0 || !`${normal.stdout}${normal.stderr}`.includes("--compat-js")) {
      fail("--compat-js なしの run が JS/ESM を拒否していません");
    }
    console.log("参照 plugin+npm E2E: run --compat-js OK（plugin 命令 + npm bare import、通常モードは拒否）");

    if (process.platform === "win32") {
      console.log("参照 plugin+npm E2E: AOT は Windows 対象外のため skip しました");
      return;
    }

    // --- AOT: npm resolver / ESM manifest を生成物で確認する ---
    // ESM plugin 命令の AOT dispatch は follow-up。同じ project のまま、
    // npm bare import を `JS実行` から解決する entry で AOT runtime を検証する。
    const binary = path.join(work, `lnako-plugin-npm-aot${executableSuffix}`);
    const sbomPath = path.join(work, "lnako-plugin-npm-aot.spdx.json");
    const beforeBuild = registry.requests.length;
    await runChecked(options.compiler, ["build", "aot-main.nako3", "--compat-js", "--backend", "aot", "--offline", "-o", binary, "--sbom", sbomPath], { cwd: app, env }, "build --compat-js --backend aot --sbom");
    if (registry.requests.length !== beforeBuild) {
      fail(`AOT build が registry へ要求しました: ${registry.requests.slice(beforeBuild).join(", ")}`);
    }
    // 同梱した npm instance と path 依存 ESM plugin の license が SBOM に載る。
    validateSbom(sbomPath, [
      { name: "left-pad", version: "1.0.0", license: "MIT", purl: "pkg:npm/left-pad@1.0.0" },
      { name: "leftpad", version: "1.0.0", license: "MIT", purl: "pkg:nako/leftpad@1.0.0" },
    ]);
    // `--sbom` は同梱を行う compat AOT 専用。通常 AOT / embedded では拒否する。
    const rejectedSbom = await run(options.compiler, ["build", "main.nako3", "--sbom", "rejected.spdx.json", "-o", binary], { cwd: app, env });
    if (rejectedSbom.status === 0 || !`${rejectedSbom.stdout}${rejectedSbom.stderr}`.includes("--compat-js")) {
      fail("--sbom が compat AOT 以外で拒否されません");
    }
    // 生成物・入力 source を SBOM で上書きする指定は拒否する。
    const overwrittenSbom = await run(options.compiler, ["build", "aot-main.nako3", "--compat-js", "--backend", "aot", "-o", binary, "--sbom", binary], { cwd: app, env });
    if (overwrittenSbom.status === 0 || !`${overwrittenSbom.stdout}${overwrittenSbom.stderr}`.includes("異なるパス")) {
      fail("--sbom が出力ファイルと同じパスを受け付けました");
    }
    const overwrittenInput = await run(options.compiler, ["build", "aot-main.nako3", "--compat-js", "--backend", "aot", "-o", binary, "--sbom", "aot-main.nako3"], { cwd: app, env });
    if (overwrittenInput.status === 0 || !`${overwrittenInput.stdout}${overwrittenInput.stderr}`.includes("異なるパス")) {
      fail("--sbom が入力ファイルと同じパスを受け付けました");
    }
    // embedded（同梱を行わない backend）との組み合わせも拒否する。
    const embeddedSbom = await run(options.compiler, ["build", "aot-main.nako3", "--compat-js", "--sbom", "embedded.spdx.json", "-o", binary], { cwd: app, env });
    if (embeddedSbom.status === 0 || !`${embeddedSbom.stdout}${embeddedSbom.stderr}`.includes("--compat-js")) {
      fail("--sbom が --backend embedded で拒否されません");
    }
    console.log("参照 plugin+npm E2E: SBOM OK（同梱 npm/ESM package の license を記録）");
    // QuickJS の module_loader は未登録名を FS から読む fallback を持つため、
    // 同期済み tree が残っていると manifest 登録が壊れていても import が成功し
    // 得る（`check_aot_quickjs_separation.mjs` と同じ理由）。実行前に `.nako`・
    // lock・cache を退避し、cwd も project 外にして manifest 登録だけで解決
    // できることを固定する。
    // path 依存 plugin の source も bundling 済みであることを固定するため、
    // `packages/` と project manifest も退避する。残るのは AOT binary だけ。
    const parked = path.join(work, "parked-project-state");
    fs.mkdirSync(parked);
    fs.renameSync(path.join(app, ".nako"), path.join(parked, "nako-env"));
    fs.renameSync(path.join(app, "nako.lock"), path.join(parked, "nako.lock"));
    fs.renameSync(path.join(app, "packages"), path.join(parked, "packages"));
    fs.renameSync(path.join(app, "nako.toml"), path.join(parked, "nako.toml"));
    fs.renameSync(cache, path.join(parked, "cache"));
    const aot = await runChecked(binary, [], { cwd: work }, "AOT 実行");
    if (aot.stdout !== expectedAotStdout) {
      fail(`AOT の stdout が期待値と異なります:\n--- expected ---\n${expectedAotStdout}\n--- actual ---\n${aot.stdout}`);
    }
    const image = fs.readFileSync(binary);
    if (!image.includes(Buffer.from("leftpad_reference"))) {
      fail("AOT 生成物に ESM plugin の source が収録されていません");
    }
    // `import("left-pad")` の文字列自体は JS source として必ず収録されるため、
    // alias の有無は ESM manifest の bare_aliases フィールドで検査する。
    if (!image.includes(Buffer.from('"bare_aliases":["left-pad"]'))) {
      fail("AOT 生成物の ESM manifest に npm bare alias が収録されていません");
    }
    if (!image.includes(Buffer.from('"is_plugin":true'))) {
      fail("AOT 生成物の ESM manifest に plugin 識別（is_plugin）が収録されていません");
    }
    if (!image.includes(Buffer.from("function leftPad(text, length, ch)"))) {
      fail("AOT 生成物に npm ESM library の source が収録されていません");
    }
    // 同梱 package の metadata（name/version/license）も生成物に収録される。
    if (!image.includes(Buffer.from('"schema":2'))) {
      fail("AOT 生成物の ESM manifest が schema 2 ではありません");
    }
    if (!image.includes(Buffer.from('"license":"MIT"'))) {
      fail("AOT 生成物の ESM manifest に同梱 package の license が収録されていません");
    }
    console.log("参照 plugin+npm E2E: AOT OK（npm bare import 解決・plugin source 収録。plugin 命令の AOT dispatch は follow-up）");
  } finally {
    await registry.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

await main();
