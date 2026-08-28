import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
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
  for (const optimization of ["O0", "O1", "O2", "O3"]) await runAotCase(cases[0].source, temporary, optimization);
  console.log(`NodeネイティブZIPスモークテスト: ${cases[0].commands.length}命令・Interpreter/AOT O0〜O3成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runAotCase(source, parent, optimization) {
  const directory = resolve(parent, `aot-${optimization}`);
  await mkdir(directory);
  const sourcePath = resolve(directory, "archive.nako3");
  const nativePath = resolve(directory, `archive-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
  await writeFile(sourcePath, source, "utf8");
  const compile = spawnSync(executable, ["build", sourcePath, "-o", nativePath, `-${optimization}`], {
    cwd: directory,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (compile.status !== 0) throw new Error(`Node ZIP AOT ${optimization}ビルドに失敗しました: ${compile.stderr}`);
  const result = spawnSync(nativePath, [], { cwd: directory, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  const stdout = result.stdout.replaceAll("\r\n", "\n");
  if (result.status !== 0 || stdout !== "7z\ntrue\ntrue\nABC\n2\nnative-tool\n") {
    throw new Error(`Node ZIP AOT ${optimization}実行に失敗しました: status=${result.status} stdout=${JSON.stringify(stdout)} stderr=${result.stderr}`);
  }
  if ((await readFile(resolve(directory, "second-output", "second.txt"), "utf8")) !== "XYZ") throw new Error(`Node ZIP AOT ${optimization}の展開内容が不正です`);
  if ((await stat(resolve(directory, "archive.zip"))).size <= 22) throw new Error(`Node ZIP AOT ${optimization}のZIPアーカイブが空です`);
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") } });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}
