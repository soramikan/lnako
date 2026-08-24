import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const expected = await readFile(resolve(root, "compat/v3.7.24/summary.json"), "utf8");
const environment = {
  ...process.env,
  ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache"),
};

if (!process.argv.includes("--no-build")) {
  const build = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: environment });
  if (build.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${build.stderr}`);
}

const report = spawnSync(executable, ["compat", "report"], { cwd: root, encoding: "utf8", env: environment });
if (report.status !== 0 || report.stderr !== "") {
  throw new Error(`compat reportの実行に失敗しました: status=${report.status}\n${report.stderr}`);
}
if (report.stdout !== expected) {
  throw new Error(`compat reportが正本summary.jsonと一致しません\nexpected=${expected}\nactual=${report.stdout}`);
}

console.log("compat report正本一致テスト: 成功");
