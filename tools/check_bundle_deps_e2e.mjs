#!/usr/bin/env node
// `build --bundle-deps` E2E（Issue #56）。
//
// path 依存の source-only package と native plugin export を持つ参照
// project を `--bundle-deps` でビルドし、生成物 + `<out>.deps/` payload を
// 空白・日本語入りの別ディレクトリへコピーしてから実行する。元 project の
// `.nako`（依存環境）・`packages/` を退避し、cwd も変えることで、payload
// と生成物だけで動くこと（cwd 非依存・cache 非依存）を確認する。
// `--sbom` の package 集合が payload（bundle.json）と厳密一致することも
// 検証する。native plugin fixture は `zig build native-plugin-fixture` の
// 成果物を流用する。
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const pluginExtension = process.platform === "win32" ? ".dll" : process.platform === "darwin" ? ".dylib" : ".so";

function fail(message) {
  throw new Error(`bundle-deps E2E: ${message}`);
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
  return {
    status: result.status,
    stdout: (result.stdout ?? "").replaceAll("\r\n", "\n"),
    stderr: (result.stderr ?? "").replaceAll("\r\n", "\n"),
  };
}

function runChecked(command, args, label, options = {}) {
  const result = run(command, args, options);
  if (result.status !== 0) fail(`${label}が失敗しました（exit=${result.status}）\n${result.stdout}${result.stderr}`);
  return result;
}

// project 信頼検証は配置 dir の ACL を見るため、CI workspace の継承 ACL で
// 拒否され得る。user private な home 配下を優先する（package AOT 検査と同方針）。
function createWorkDir() {
  for (const base of [os.homedir(), os.tmpdir()]) {
    try {
      return fs.mkdtempSync(path.join(base, ".lnako-bundle-deps-"));
    } catch {
      // 次の候補へ
    }
  }
  fail("作業ディレクトリを作成できません");
}

function findPlugin(namePattern) {
  const found = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (namePattern.test(entry.name) && entry.name.toLowerCase().endsWith(pluginExtension)) found.push(full);
    }
  };
  walk(path.join(root, "zig-out"));
  if (found.length === 0) {
    fail(`native plugin fixtureが見つかりません（先に zig build native-plugin-fixture を実行してください）`);
  }
  return found[0];
}

function readManifest(payloadRoot) {
  const manifestPath = path.join(payloadRoot, "bundle.json");
  if (!fs.existsSync(manifestPath)) fail(`bundle.json がありません: ${manifestPath}`);
  return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
}

function validateBundleMatchesSbom(payloadRoot, sbomPath) {
  const manifest = readManifest(payloadRoot);
  if (manifest.schema !== 1) fail(`bundle.json の schema が 1 ではありません: ${manifest.schema}`);
  if (!Array.isArray(manifest.packages)) fail("bundle.json の packages が配列ではありません");
  if (!fs.existsSync(sbomPath)) fail(`SBOM が生成されていません: ${sbomPath}`);
  const sbom = JSON.parse(fs.readFileSync(sbomPath, "utf8"));
  if (sbom.spdxVersion !== "SPDX-2.3") fail("SBOM の SPDX バージョンが 2.3 ではありません");

  // bundle.json の package 集合 ⇔ SBOM の package 集合（厳密一致）。
  const bundleNames = manifest.packages.map((item) => item.name).sort();
  const sbomNames = sbom.packages.map((item) => item.name).sort();
  if (JSON.stringify(bundleNames) !== JSON.stringify(sbomNames)) {
    fail(`bundle.json と SBOM の package 集合が一致しません\nbundle: ${bundleNames.join(",")}\nsbom:   ${sbomNames.join(",")}`);
  }
  // license も一致させる（SBOM 正規化前の宣言値）。
  for (const item of manifest.packages) {
    const record = sbom.packages.find((candidate) => candidate.name === item.name);
    if (!record) fail(`SBOM に ${item.name} がありません`);
    if (record.licenseDeclared !== item.license) {
      fail(`${item.name} の licenseDeclared が一致しません: bundle=${item.license} sbom=${record.licenseDeclared}`);
    }
    // payload 内の実 file が bundle.json の file 一覧と一致する。
    const directory = path.join(payloadRoot, item.directory);
    for (const relative of item.files) {
      if (!fs.existsSync(path.join(payloadRoot, relative))) {
        fail(`payload に同梱 file がありません: ${relative}`);
      }
    }
    if (!fs.existsSync(directory)) fail(`payload の package directory がありません: ${item.directory}`);
  }
  return manifest;
}

async function main() {
  const compiler = path.join(root, "zig-out", "bin", `lnako${executableSuffix}`);
  if (!fs.existsSync(compiler)) fail(`compilerがありません: ${compiler}（先に zig build を実行してください）`);
  const plugin = findPlugin(/lnako[_-]test[_-]plugin/i);

  const work = createWorkDir();
  const app = path.join(work, "app");
  try {
    fs.mkdirSync(path.join(app, "packages", "puremath", "src"), { recursive: true });
    fs.mkdirSync(path.join(app, "packages", "fastmath"), { recursive: true });
    fs.writeFileSync(path.join(app, "nako.toml"), `# 参照 fixture: source-only 依存と native plugin export を同時に持つ。
[package]
name = "bundle-app"
version = "0.1.0"
license = "MIT"

[dependencies.path]
puremath = { path = "packages/puremath" }
fastmath = { path = "packages/fastmath" }
`);
    fs.writeFileSync(path.join(app, "packages", "puremath", "nako.toml"), `# source-only 依存（.nako3 のみ）。license 宣言あり。
[package]
name = "puremath"
version = "1.0.0"
license = "MIT"

[[exports]]
name = "main"
path = "src/index.nako3"
`);
    fs.writeFileSync(path.join(app, "packages", "puremath", "src", "index.nako3"), `●(AとBの)足し算とは
R=A+B
「pure:{R}」を表示
ここまで
`);
    // license 未宣言 package → SBOM は NOASSERTION になる。manifest schema
    // は SPDX 式を要求するため、「未主張」は NOASSERTION で宣言する。
    fs.writeFileSync(path.join(app, "packages", "fastmath", "nako.toml"), `# native export を持つ依存。license 未宣言（NOASSERTION の検証対象）。
[package]
name = "fastmath"
version = "2.0.0"
license = "NOASSERTION"

[[exports]]
name = "plugin"
native = "libfastmath.${pluginExtension.slice(1)}"
`);
    fs.copyFileSync(plugin, path.join(app, "packages", "fastmath", `libfastmath.${pluginExtension.slice(1)}`));
    fs.writeFileSync(path.join(app, "main.nako3"), `!「パッケージ:puremath」を取り込む
!「pkg:fastmath/plugin」を取り込む
1と2の足し算
fastmath__plugin__ネイティブ加算(2,3)を表示
`);

    const output = path.join(work, "app-bin");
    const sbomPath = path.join(work, "app-bin.spdx.json");
    runChecked(compiler, ["build", "main.nako3", "-o", output, "--bundle-deps", "--sbom", sbomPath], "build --bundle-deps --sbom", { cwd: app });
    const payloadRoot = `${output}.deps`;
    if (!fs.existsSync(payloadRoot)) fail(`payload directoryがありません: ${payloadRoot}`);
    const manifest = validateBundleMatchesSbom(payloadRoot, sbomPath);
    const fastmath = manifest.packages.find((item) => item.name === "fastmath");
    if (fastmath.license !== "NOASSERTION") fail(`fastmath の license が NOASSERTION ではありません: ${fastmath.license}`);
    console.log(`bundle-deps E2E: build + bundle.json/SBOM 一致 OK（packages: ${manifest.packages.map((item) => item.name).join(", ")}）`);

    // native plugin path が marker 化されていること（build 機の絶対 path を
    // 埋め込まない = 移動可能の前提）。
    const image = fs.readFileSync(output);
    if (!image.includes(Buffer.from("@self/"))) fail("生成物に @self/ marker がありません");
    if (image.includes(Buffer.from(path.join(work, "app", "packages")))) {
      fail("生成物に build 機の絶対 path が残っています");
    }

    // --- 移動 E2E: 空白・日本語入りの別ディレクトリへ生成物と payload だけ
    // コピーし、元 project 状態（.nako・packages・manifest）を退避してから
    // 別 cwd で実行する。
    const moved = path.join(work, "移動 先", "prog");
    fs.mkdirSync(path.dirname(moved), { recursive: true });
    fs.copyFileSync(output, moved);
    fs.cpSync(payloadRoot, `${moved}.deps`, { recursive: true });
    const parked = path.join(work, "parked-project-state");
    fs.mkdirSync(parked);
    fs.renameSync(path.join(app, ".nako"), path.join(parked, "nako-env"));
    fs.renameSync(path.join(app, "packages"), path.join(parked, "packages"));
    fs.renameSync(path.join(app, "nako.toml"), path.join(parked, "nako.toml"));
    fs.renameSync(path.join(app, "nako.lock"), path.join(parked, "nako.lock"));

    const movedResult = run(moved, [], { cwd: work });
    if (movedResult.status !== 0) fail(`移動後の生成物が失敗しました: ${movedResult.stderr}`);
    if (movedResult.stdout !== "pure:3\n5\n") {
      fail(`移動後の実行結果が期待値と異なります:\n${movedResult.stdout}`);
    }
    console.log("bundle-deps E2E: 移動後（cache なし・別 cwd・空白/日本語 path）の実行 OK");

    // payload の plugin artifact を消すと明示エラーになる（marker 解決が
    // 実際に payload を使っている証拠。build 機の path へ fallback しない）。
    const dylib = manifest.packages.map((item) => item.name === "fastmath" ? path.join(payloadRoot, item.directory) : null)
      .filter(Boolean)[0];
    const pluginArtifact = fs.readdirSync(path.join(`${moved}.deps`, path.basename(dylib)))
      .find((name) => name.endsWith(pluginExtension));
    fs.rmSync(path.join(`${moved}.deps`, path.basename(dylib), pluginArtifact));
    const broken = run(moved, [], { cwd: work });
    if (broken.status === 0 || !`${broken.stdout}${broken.stderr}`.includes("NativePluginOpenFailed")) {
      fail(`payload から plugin を消しても明示エラーになりません: ${broken.stdout}${broken.stderr}`);
    }
    console.log("bundle-deps E2E: payload 欠落時の明示エラー OK");
    console.log("bundle-deps E2E: 成功");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
