import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const temporary = await mkdtemp(join(tmpdir(), "lnako-native-plugin-"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const pluginExtension = process.platform === "win32" ? ".dll" : process.platform === "darwin" ? ".dylib" : ".so";
const buildOptions = process.argv.includes("--release-safe") ? ["-Doptimize=ReleaseSafe"] : [];

try {
  run("zig", ["build", ...buildOptions, "native-plugin-fixture"]);
  run("zig", ["build", ...buildOptions]);
  const plugin = await findPlugin(resolve(root, "zig-out"), /lnako[_-]test[_-]plugin/i);
  const invalidPlugin = await findPlugin(resolve(root, "zig-out"), /lnako[_-]invalid[_-]plugin/i);
  const source = resolve(temporary, "native-plugin.nako3");
  const importPath = plugin.replaceAll("\\", "/");
  await writeFile(
    source,
    `!「${importPath}」を取り込む
ネイティブ加算(2,3)を表示
JSON変換(ネイティブ配列("x"))を表示
ネイティブホスト呼出(ネイティブ配列("y"))を表示
F=関数(V)それはV*2
ここまで
ネイティブ関数呼出(F,6)を表示
V=ネイティブ値生成()
V["big"]を表示
JSON変換(V["bytes"])を表示
P=ネイティブ非同期()
Pの成功した時には
対象を表示
ここまで
Q=ネイティブ即時非同期()
Qの成功した時には
対象を表示
ここまで
R=ネイティブ非同期失敗()
Rの失敗した時には
対象を表示
ここまで
`,
  );
  const result = spawnSync(executable, ["run", source], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  const expected = `5
["x","native"]
["y","native"]
12
123456789012345678901234567890
{"type":"Buffer","data":[65,66,67]}
43
native failure
42
`;
  const stdout = result.stdout.replaceAll("\r\n", "\n");
  if (result.status !== 0 || stdout !== expected) {
    throw new Error(`ネイティブプラグインABI差分\nstatus=${result.status}\nstdout=${JSON.stringify(stdout)}\nstderr=${result.stderr}`);
  }

  const aritySource = resolve(temporary, "native-plugin-arity.nako3");
  await writeFile(aritySource, `!「${importPath}」を取り込む\nネイティブ加算(1)を表示\n`);
  const arity = spawnSync(executable, ["run", aritySource], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (arity.status === 0 || !arity.stderr.includes("NativePluginArityMismatch")) {
    throw new Error(`ネイティブ命令の引数範囲を拒否しませんでした: status=${arity.status} stderr=${arity.stderr}`);
  }

  const missingSource = resolve(temporary, "native-plugin-missing.nako3");
  const missingPlugin = resolve(temporary, `missing${pluginExtension}`).replaceAll("\\", "/");
  await writeFile(missingSource, `!「${missingPlugin}」を取り込む\n`);
  const missing = spawnSync(executable, ["run", missingSource], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (missing.status === 0 || !missing.stderr.includes("NativePluginOpenFailed")) {
    throw new Error(`存在しないネイティブプラグインを拒否しませんでした: status=${missing.status} stderr=${missing.stderr}`);
  }
  const staticCheck = spawnSync(executable, ["check", missingSource], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (staticCheck.status !== 0) {
    throw new Error(`静的checkがネイティブ初期化を実行しました: status=${staticCheck.status} stderr=${staticCheck.stderr}`);
  }

  const invalidSource = resolve(temporary, "native-plugin-invalid-abi.nako3");
  await writeFile(invalidSource, `!「${invalidPlugin.replaceAll("\\", "/")}」を取り込む\n`);
  const invalid = spawnSync(executable, ["run", invalidSource], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (invalid.status === 0 || !invalid.stderr.includes("NativePluginAbiMismatch")) {
    throw new Error(`不一致のネイティブABIを拒否しませんでした: status=${invalid.status} stderr=${invalid.stderr}`);
  }

  const teardownSource = resolve(temporary, "native-plugin-teardown.nako3");
  await writeFile(teardownSource, `!「${importPath}」を取り込む\nネイティブ非同期()\nエラー発生("stop")\n`);
  const teardown = spawnSync(executable, ["run", teardownSource], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (teardown.status === 0 || !teardown.stderr.includes("NakoException") || /segmentation|illegal instruction|access violation/i.test(teardown.stderr)) {
    throw new Error(`非同期workerの終了順序が不正です: status=${teardown.status} stderr=${teardown.stderr}`);
  }

  const output = resolve(temporary, process.platform === "win32" ? "native-aot.exe" : "native-aot");
  const aot = spawnSync(executable, ["build", source, "-o", output], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (aot.status !== 2 || !aot.stderr.includes("LLVM AOTランタイム")) {
    throw new Error(`未対応のネイティブABI AOTを明示的に拒否しませんでした: status=${aot.status} stderr=${aot.stderr}`);
  }
  console.log("ネイティブプラグインABI: 8命令・opaque値・ホスト呼出・Promise・失敗境界成功");
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} が失敗しました\n${result.stderr}`);
}

async function findPlugin(directory, namePattern) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = await findPlugin(path, namePattern).catch(() => null);
      if (nested) return nested;
    } else if (namePattern.test(entry.name) && entry.name.toLowerCase().endsWith(pluginExtension)) {
      return path;
    }
  }
  throw new Error("ネイティブプラグインfixtureが見つかりません");
}
