// `--compat-js` AOTの成果物分離を検査する。
//
// 通常AOT成果物にQuickJS/compat ABIが混入しないこと、compat AOT成果物には
// QuickJSとESM manifestが収録され、`JS実行` からESM moduleを呼べることを
// 実際の生成物（シンボルと実行結果）で確認する。Issue #55の最小スライス。
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = parseArguments(process.argv.slice(2));
const compiler = resolveCompiler(args.compiler ?? join(root, "zig-out", "bin", "lnako"));
const runtimeLib = resolveRuntimeLib(args["runtime-lib"]);
const nm = resolveNm(args.nm);
const work = mkdtempSync(join(tmpdir(), "lnako-aot-quickjs-"));
let failed = false;

try {
  const modulePath = join(work, "mod.mjs");
  writeFileSync(modulePath, "export function add(a, b) { return a + b; }\n");
  const normalSource = join(work, "normal.nako3");
  writeFileSync(normalSource, "1+2を表示\n");
  const compatSource = join(work, "compat.nako3");
  writeFileSync(
    compatSource,
    `!「mod.mjs」を取り込む\nJS実行("import('${modulePath.replaceAll("\\", "/")}').then(m => m.add(2,3))")を表示\n`,
  );

  const normalBinary = join(work, "normal");
  const compatBinary = join(work, "compat");
  runCompiler(normalSource, normalBinary, []);
  runCompiler(compatSource, compatBinary, ["--compat-js"]);

  const normalOutput = runBinary(normalBinary);
  expectEqual(normalOutput, "3", "通常AOTの実行結果");
  // 生成物の起動時ESM登録だけを検証するため、実行前にmoduleファイルを退避する。
  // QuickJSのmodule_loaderは未登録名をFSから読むfallbackを持つため、ファイルが
  // 残っているとmanifest登録が壊れていても通ってしまう。
  const parkedModule = `${modulePath}.parked`;
  renameSync(modulePath, parkedModule);
  try {
    const compatOutput = runBinary(compatBinary);
    expectEqual(compatOutput, "5", "compat AOTのESM呼出し結果（manifest登録経由）");
  } finally {
    renameSync(parkedModule, modulePath);
  }

  const normalSymbols = listSymbols(normalBinary);
  for (const forbidden of ["lnako_qjs_", "lnako_aot_compat_", "lnako.compat.esm.manifest"]) {
    if (normalSymbols.some((symbol) => symbol.includes(forbidden))) {
      fail(`通常AOT成果物に ${forbidden} が混入しています`);
    }
  }
  const compatSymbols = listSymbols(compatBinary);
  for (const required of ["lnako_qjs_", "lnako_aot_compat_js_eval", "lnako.compat.esm.manifest"]) {
    if (!compatSymbols.some((symbol) => symbol.includes(required))) {
      fail(`compat AOT成果物に ${required} がありません`);
    }
  }
  const compatBytes = readFileSync(compatBinary);
  if (!compatBytes.includes(Buffer.from("export function add"))) {
    fail("compat AOT成果物にESM sourceが収録されていません");
  }
  if (!compatBytes.includes(Buffer.from(modulePath))) {
    fail("compat AOT成果物にESM identity（path）が収録されていません");
  }
  checkDistributionLayout(work);

  if (failed) process.exitCode = 1;
  else console.log("AOT QuickJS分離検査: 通常AOTはQuickJS非依存、compat AOTはQuickJS＋ESMを収録しESM呼出しに成功");
} finally {
  rmSync(work, { recursive: true, force: true });
}

function parseArguments(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--compiler" || argument === "--nm" || argument === "--runtime-lib") {
      index += 1;
      if (index >= argv.length) throw new Error(`${argument} の値がありません`);
      parsed[argument.slice(2)] = argv[index];
    } else {
      throw new Error(`不明な引数です: ${argument}`);
    }
  }
  return parsed;
}

function resolveCompiler(path) {
  const resolved = resolve(path);
  const candidates = process.platform === "win32" ? [resolved, `${resolved}.exe`] : [resolved];
  for (const candidate of candidates) {
    try {
      readFileSync(candidate);
      return candidate;
    } catch {}
  }
  throw new Error(`コンパイラが見つかりません: ${path}`);
}

function resolveRuntimeLib(explicit) {
  const path = explicit ?? join(root, "zig-out", "lib", process.platform === "win32" ? "lnako_runtime.lib" : "liblnako_runtime.a");
  const resolved = resolve(path);
  try {
    readFileSync(resolved);
    return resolved;
  } catch {
    throw new Error(`通常AOT runtime libraryが見つかりません: ${path}`);
  }
}

/// 配布アーカイブは現時点で通常AOT runtimeだけを同梱する。配布レイアウトを
/// 再現し、compat AOTが明確なエラーで止まることと、embedded経路が動くことを
/// 固定する（compat runtime同梱はfollow-up）。
function checkDistributionLayout(work) {
  const compatSource = join(work, "distribution-compat.nako3");
  writeFileSync(compatSource, 'JS実行("1+2")を表示\n');
  const staging = join(work, "distribution");
  const binDir = join(staging, "bin");
  const libDir = join(staging, "lib");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(libDir, { recursive: true });
  const stagedCompiler = join(binDir, process.platform === "win32" ? "lnako.exe" : "lnako");
  copyFileSync(compiler, stagedCompiler);
  copyFileSync(runtimeLib, join(libDir, process.platform === "win32" ? "lnako_runtime.lib" : "liblnako_runtime.a"));
  const output = join(work, "distribution-compat");
  const aot = spawnSync(stagedCompiler, ["build", compatSource, "-o", output, "--compat-js"], { encoding: "utf8" });
  if (aot.status === 0 || !aot.stderr.includes("AOTランタイム静的ライブラリを読み込めません")) {
    fail(`配布レイアウトのcompat AOTが明確なエラーになりません: ${aot.stdout}${aot.stderr}`);
  }
  const embedded = spawnSync(stagedCompiler, ["build", compatSource, "-o", output, "--compat-js", "--backend", "embedded"], { encoding: "utf8" });
  if (embedded.status !== 0) fail(`配布レイアウトのembedded経路が失敗しました: ${embedded.stdout}${embedded.stderr}`);
  expectEqual(runBinary(output), "3", "配布レイアウトのembedded実行結果");
}

function resolveNm(explicit) {
  if (explicit) return explicit;
  const candidates = [];
  if (process.env.LNAKO_LLVM_DIR) candidates.push(join(process.env.LNAKO_LLVM_DIR, "bin", "llvm-nm"));
  const toolchains = join(root, ".cache", "toolchains");
  try {
    for (const entry of readdirSync(toolchains)) {
      if (entry.startsWith("llvm-")) candidates.push(join(toolchains, entry, "bin", "llvm-nm"));
    }
  } catch {}
  candidates.push("llvm-nm", "nm");
  for (const candidate of candidates) {
    const probe = spawnSync(candidate, ["--version"], { encoding: "utf8" });
    if (probe.status === 0) return candidate;
  }
  throw new Error("nm/llvm-nmが見つかりません（--nmで指定してください）");
}

function runCompiler(source, output, extra) {
  const result = spawnSync(compiler, ["build", source, "-o", output, ...extra], { encoding: "utf8" });
  if (result.status !== 0) fail(`コンパイルに失敗しました: ${source}\n${result.stdout}${result.stderr}`);
}

function runBinary(path) {
  const result = spawnSync(path, [], { encoding: "utf8" });
  if (result.status !== 0) fail(`実行に失敗しました: ${path}\n${result.stdout}${result.stderr}`);
  return result.stdout.trim();
}

function listSymbols(path) {
  const result = spawnSync(nm, ["-g", path], { encoding: "utf8" });
  if (result.status !== 0) fail(`シンボル一覧の取得に失敗しました: ${path}\n${result.stderr}`);
  return result.stdout.split("\n").map((line) => line.trim()).filter(Boolean);
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label}が一致しません: expected=${expected} actual=${actual}`);
}

function fail(message) {
  failed = true;
  console.error(`AOT QuickJS分離検査: ${message}`);
}
