import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-archive-"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-native-cases.json"), "utf8"));

try {
  buildLnako();
  const sourcePath = resolve(temporary, "archive.nako3");
  await writeFile(sourcePath, cases[0].source, "utf8");
  const result = spawnSync(executable, ["run", sourcePath], { cwd: temporary, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  const stdout = result.stdout.replaceAll("\r\n", "\n");
  if (result.status !== 0 || stdout !== "7z\ntrue\ntrue\nABC\n2\nnative-tool\n") {
    throw new Error(`Node ZIPスモークテストに失敗しました: status=${result.status} stdout=${JSON.stringify(stdout)} stderr=${result.stderr}`);
  }
  if ((await readFile(resolve(temporary, "second-output", "second.txt"), "utf8")) !== "XYZ") throw new Error("コールバック版ZIPの展開内容が不正です");
  if ((await stat(resolve(temporary, "archive.zip"))).size <= 22) throw new Error("ZIPアーカイブが空です");
  console.log(`NodeネイティブZIPスモークテスト: ${cases[0].commands.length}命令成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") } });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}
