import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");

function run(args, env = {}) {
  const result = spawnSync(executable, args, { encoding: "utf8", env: { ...process.env, ...env } });
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

function runWithToolchainDir(args, toolchainDir) {
  return run(args, { LNAKO_TOOLCHAIN_DIR: toolchainDir });
}

const temporary = await mkdtemp(join(tmpdir(), "lnako-toolchain-check-"));
try {
  const toolchainDir = join(temporary, "toolchains");
  const executableName = process.platform === "win32" ? "clang.exe" : "clang";
  const lldName = process.platform === "win32" ? "lld-link.exe" : process.platform === "darwin" ? "ld64.lld" : "ld.lld";
  const libraryRelative = process.platform === "win32" ? "bin/LLVM-C.dll" : process.platform === "darwin" ? "lib/libLLVM-C.dylib" : "lib/libLLVM-C.so";

  const fakeLlvm = join(temporary, "fake-llvm");
  await mkdir(join(fakeLlvm, "bin"), { recursive: true });
  await mkdir(join(fakeLlvm, "lib"), { recursive: true });
  await writeFile(join(fakeLlvm, "bin", executableName), "fake-clang");
  await writeFile(join(fakeLlvm, "bin", lldName), "fake-lld");
  await writeFile(join(fakeLlvm, libraryRelative), "fake-libllvm-c");

  // dir/status: 管理root解決。
  const dirResult = runWithToolchainDir(["toolchain", "dir"], toolchainDir);
  if (dirResult.status !== 0 || dirResult.stdout.trim() !== toolchainDir) throw new Error(`toolchain dirが管理rootを返しません: ${dirResult.stdout}`);
  const statusBefore = runWithToolchainDir(["toolchain", "status"], toolchainDir);
  if (statusBefore.status !== 0 || !statusBefore.stdout.includes("未導入")) throw new Error("toolchain statusが未導入を報告しません");

  // install --from-dir: 構造検証＋管理登録。
  const install = runWithToolchainDir(["toolchain", "install", "--from-dir", fakeLlvm], toolchainDir);
  if (install.status !== 0) throw new Error(`toolchain install --from-dirに失敗しました: ${install.stderr}`);
  const statusAfter = runWithToolchainDir(["toolchain", "status"], toolchainDir);
  if (statusAfter.status !== 0 || !statusAfter.stdout.includes("導入済み")) throw new Error("toolchain statusが導入済みを報告しません");

  // 再installはalready-presentを返す。
  const reinstall = runWithToolchainDir(["toolchain", "install", "--from-dir", fakeLlvm], toolchainDir);
  if (reinstall.status !== 0 || !reinstall.stdout.includes("既に導入済み")) throw new Error("再installで既導入判定になりません");

  // removeで削除される。
  const remove = runWithToolchainDir(["toolchain", "remove"], toolchainDir);
  if (remove.status !== 0) throw new Error(`toolchain removeに失敗しました: ${remove.stderr}`);
  const statusRemoved = runWithToolchainDir(["toolchain", "status"], toolchainDir);
  if (statusRemoved.status !== 0 || !statusRemoved.stdout.includes("未導入")) throw new Error("toolchain statusが削除後に未導入を報告しません");

  console.log("toolchainコマンド検証: dir・status・install --from-dir・remove成功");
} finally {
  await rm(temporary, { recursive: true, force: true });
}
