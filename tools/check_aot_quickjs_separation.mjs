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
const runtimeLib = resolveRuntimeLib(args["runtime-lib"], "lnako_runtime.lib", "liblnako_runtime.a", "通常AOT runtime library");
const runtimeCompatLib = resolveRuntimeLib(args["runtime-compat-lib"], "lnako_runtime_compat.lib", "liblnako_runtime_compat.a", "compat AOT runtime library");
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
  runCompiler(compatSource, compatBinary, ["--compat-js", "--backend", "aot"]);

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

  // `JS関数実行`: AOTとインタプリタが同じfixtureで同じstdoutを返すこと。
  // 引数（プリミティブと浅い配列/辞書）と戻り値の最小変換を固定する。
  const functionCallFixture = join(root, "tests", "fixtures", "compat-js-function-call.nako3");
  const interpreterCall = spawnSync(compiler, ["run", functionCallFixture, "--compat-js"], { encoding: "utf8" });
  if (interpreterCall.status !== 0) {
    fail(`JS関数実行fixtureのインタプリタ実行が失敗しました: ${interpreterCall.stdout}${interpreterCall.stderr}`);
  }
  const functionCallBinary = join(work, "compat-js-function-call");
  runCompiler(functionCallFixture, functionCallBinary, ["--compat-js", "--backend", "aot"]);
  const functionCallSymbols = listSymbols(functionCallBinary);
  if (!functionCallSymbols.some((symbol) => symbol.includes("lnako_aot_compat_js_call"))) {
    fail("JS関数実行のcompat AOT成果物に lnako_aot_compat_js_call がありません");
  }
  const functionCallOutput = runBinary(functionCallBinary);
  expectEqual(functionCallOutput, interpreterCall.stdout.trim(), "JS関数実行のAOT/インタプリタ一致");
  expectEqual(
    functionCallOutput,
    "0\n3\n5\n3\nx!\n1\n0\n1\n1\n3\n0\n30\n0\n5\n1,2\n\n[object Object]\n[object Object]\na,true,",
    "JS関数実行の最小変換結果（戻り値の配列・辞書を含む）",
  );

  // 浅い配列・辞書だけを引数に許可する。ネストした配列/辞書・関数値・
  // バイト列は、QuickJSへ渡す前に AOT/インタプリタが同じ文言で明示エラーに
  // すること。BigIntはAOT側に値の生成経路がまだ無いためinterpreterだけで
  // 確認し、AOT側の判定は src/runtime/aot/compat_js.zig の単体テストで固定する。
  const unsupportedArgumentCases = [
    ["ネストした配列", 'JS関数実行("x => x", [[[1,2]]])を表示\n'],
    ["配列要素の辞書", 'JS関数実行("x => x", [[{x:1}]])を表示\n'],
    ["辞書の値の配列", 'JS関数実行("x => x", {x:[1,2]})を表示\n'],
    ["辞書の値の辞書", 'JS関数実行("x => x", {x:{y:1}})を表示\n'],
    ["関数値", "F=関数(A)それはA;ここまで\nJS関数実行(\"x => x\", F)を表示\n"],
    ["bytes", "B=3のランダム配列生成\nJS関数実行(\"x => x\", B)を表示\n"],
  ];
  const unsupportedArgumentMessage =
    "JS関数実行 does not support nested arrays or dictionaries, functions, bigint, or bytes arguments yet";
  for (const [index, [label, source]] of unsupportedArgumentCases.entries()) {
    const unsupportedArgumentSource = join(work, `compat-js-unsupported-argument-${index}.nako3`);
    writeFileSync(unsupportedArgumentSource, source);
    const unsupportedArgumentBinary = join(work, `compat-js-unsupported-argument-${index}`);
    runCompiler(unsupportedArgumentSource, unsupportedArgumentBinary, ["--compat-js", "--backend", "aot"]);
    const aot = spawnSync(unsupportedArgumentBinary, [], { encoding: "utf8" });
    const interpreter = spawnSync(compiler, ["run", unsupportedArgumentSource, "--compat-js"], { encoding: "utf8" });
    for (const [kind, result] of [["AOT", aot], ["インタプリタ", interpreter]]) {
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      if (result.status === 0 || !output.includes(unsupportedArgumentMessage)) {
        fail(`${label}の未対応引数が${kind}で明示エラーになりません: status=${result.status}\n${output}`);
      }
    }
  }

  // 戻り値もプリミティブと浅い配列・辞書だけを許可する。ネストした配列/辞書・
  // 関数・Promise・BigInt・bytesは、QuickJSへ渡す前ではなく戻り値変換時に
  // AOT/interpreterが同じ文言で明示エラーにすること。
  const unsupportedResultCases = [
    ["ネストした配列の戻り値", 'JS関数実行("()=>[1,[2]]", [])を表示\n'],
    ["ネストした辞書の戻り値", 'JS関数実行(『()=>({x:{y:1}})』, [])を表示\n'],
    ["関数の戻り値", 'JS関数実行("()=>()=>1", [])を表示\n'],
    ["Promiseの戻り値", 'JS関数実行("()=>Promise.resolve(1)", [])を表示\n'],
    ["BigIntの戻り値", 'JS関数実行("()=>1n", [])を表示\n'],
    ["bytesの戻り値（TypedArray）", 'JS関数実行("()=>new Uint8Array([1,2])", [])を表示\n'],
    ["bytesの戻り値（ArrayBuffer）", 'JS関数実行("()=>new ArrayBuffer(4)", [])を表示\n'],
    ["bytesの戻り値（SharedArrayBuffer）", 'JS関数実行("()=>new SharedArrayBuffer(4)", [])を表示\n'],
    ["bytesの戻り値（DataView）", 'JS関数実行("()=>new DataView(new ArrayBuffer(4))", [])を表示\n'],
    ["配列要素のbytes", 'JS関数実行("()=>[new Uint8Array([1])]", [])を表示\n'],
    ["辞書値のbytes", 'JS関数実行(『()=>({x:new Uint8Array([1])})』, [])を表示\n'],
  ];
  const unsupportedResultMessage =
    "JS関数実行 does not support nested arrays or dictionaries, functions, promises, bigint, or bytes results yet";
  for (const [index, [label, source]] of unsupportedResultCases.entries()) {
    const unsupportedResultSource = join(work, `compat-js-unsupported-result-${index}.nako3`);
    writeFileSync(unsupportedResultSource, source);
    const unsupportedResultBinary = join(work, `compat-js-unsupported-result-${index}`);
    runCompiler(unsupportedResultSource, unsupportedResultBinary, ["--compat-js", "--backend", "aot"]);
    const aot = spawnSync(unsupportedResultBinary, [], { encoding: "utf8" });
    const interpreter = spawnSync(compiler, ["run", unsupportedResultSource, "--compat-js"], { encoding: "utf8" });
    for (const [kind, result] of [["AOT", aot], ["インタプリタ", interpreter]]) {
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      if (result.status === 0 || !output.includes(unsupportedResultMessage)) {
        fail(`${label}の未対応戻り値が${kind}で明示エラーになりません: status=${result.status}\n${output}`);
      }
    }
  }

  // BigIntはAOT側に値の生成経路がまだ無いため、interpreterで同じ明示エラーに
  // なることだけを固定する（AOTの判定はcompat_js.zigの単体テスト）。
  const bigintSource = join(work, "compat-js-unsupported-argument-bigint.nako3");
  writeFileSync(bigintSource, 'B=JS実行("1n")\nJS関数実行("x => x", B)を表示\n');
  const bigint = spawnSync(compiler, ["run", bigintSource, "--compat-js"], { encoding: "utf8" });
  const bigintOutput = `${bigint.stdout ?? ""}${bigint.stderr ?? ""}`;
  if (bigint.status === 0 || !bigintOutput.includes(unsupportedArgumentMessage)) {
    fail(`BigIntの未対応引数がインタプリタで明示エラーになりません: status=${bigint.status}\n${bigintOutput}`);
  }

  // 既定の `--compat-js` は従来の同梱実行ファイル方式（embedded）へ戻っている。
  // AOT+QuickJSは `--backend aot` の明示opt-inであることを実行で固定する。
  const defaultCompatSource = join(work, "default-compat.nako3");
  writeFileSync(defaultCompatSource, 'JS実行("1+2")を表示\n');
  const defaultCompatBinary = join(work, "default-compat");
  runCompiler(defaultCompatSource, defaultCompatBinary, ["--compat-js"]);
  expectEqual(runBinary(defaultCompatBinary), "3", "既定compat-js（embedded）の実行結果");
  // 既定がAOTへ戻ると実行結果だけでは区別できないため、compat AOT専用ABIを
  // 持たないことも固定する。
  const defaultSymbols = listSymbols(defaultCompatBinary);
  for (const forbidden of ["lnako_aot_compat_js_eval", "lnako.compat.esm.manifest"]) {
    if (defaultSymbols.some((symbol) => symbol.includes(forbidden))) {
      fail(`既定compat-js（embedded）成果物に ${forbidden} が混入しています`);
    }
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
    if (argument === "--compiler" || argument === "--nm" || argument === "--runtime-lib" || argument === "--runtime-compat-lib") {
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

function resolveRuntimeLib(explicit, windowsName, unixName, label) {
  const path = explicit ?? join(root, "zig-out", "lib", process.platform === "win32" ? windowsName : unixName);
  const resolved = resolve(path);
  try {
    readFileSync(resolved);
    return resolved;
  } catch {
    throw new Error(`${label}が見つかりません: ${path}`);
  }
}

/// 配布アーカイブを再現し、compat runtimeを同梱したレイアウトでは
/// `--compat-js --backend aot` が動き、同梱しないレイアウトでは明確なエラーに
/// なること、既定の `--compat-js`（embedded）がどちらでも動くことを固定する。
function checkDistributionLayout(work) {
  const compatSource = join(work, "distribution-compat.nako3");
  writeFileSync(compatSource, 'JS実行("1+2")を表示\n');
  const cleanEnv = { ...process.env };
  // 配布利用者と同じ探索（実行ファイル隣接の ../lib）を再現する。
  delete cleanEnv.LNAKO_AOT_RUNTIME_LIBRARY;
  delete cleanEnv.LNAKO_AOT_RUNTIME_LIBRARY_COMPAT;

  const withCompat = join(work, "distribution-with-compat");
  stageDistribution(withCompat, true);
  const compatOutput = join(work, "distribution-compat-aot");
  const aot = spawnSync(join(withCompat, "bin", compilerName()), ["build", compatSource, "-o", compatOutput, "--compat-js", "--backend", "aot"], { encoding: "utf8", env: cleanEnv });
  if (aot.status !== 0) fail(`compat runtime同梱レイアウトのAOTが失敗しました: ${aot.stdout}${aot.stderr}`);
  expectEqual(runBinary(compatOutput), "3", "配布レイアウト（compat runtime同梱）のAOT実行結果");

  const withoutCompat = join(work, "distribution-without-compat");
  stageDistribution(withoutCompat, false);
  const missingOutput = join(work, "distribution-compat-missing");
  const missing = spawnSync(join(withoutCompat, "bin", compilerName()), ["build", compatSource, "-o", missingOutput, "--compat-js", "--backend", "aot"], { encoding: "utf8", env: cleanEnv });
  if (missing.status === 0 || !missing.stderr.includes("AOTランタイム静的ライブラリを読み込めません")) {
    fail(`compat runtime非同梱レイアウトのAOTが明確なエラーになりません: ${missing.stdout}${missing.stderr}`);
  }

  for (const [label, staging] of [["同梱", withCompat], ["非同梱", withoutCompat]]) {
    const embeddedOutput = join(work, `distribution-embedded-${label}`);
    const embedded = spawnSync(join(staging, "bin", compilerName()), ["build", compatSource, "-o", embeddedOutput, "--compat-js"], { encoding: "utf8", env: cleanEnv });
    if (embedded.status !== 0) fail(`配布レイアウト（${label}）の既定compat-jsが失敗しました: ${embedded.stdout}${embedded.stderr}`);
    expectEqual(runBinary(embeddedOutput), "3", `配布レイアウト（${label}）の既定compat-js実行結果`);
  }
}

function compilerName() {
  return process.platform === "win32" ? "lnako.exe" : "lnako";
}

function stageDistribution(staging, includeCompat) {
  const binDir = join(staging, "bin");
  const libDir = join(staging, "lib");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(libDir, { recursive: true });
  copyFileSync(compiler, join(binDir, compilerName()));
  copyFileSync(runtimeLib, join(libDir, process.platform === "win32" ? "lnako_runtime.lib" : "liblnako_runtime.a"));
  if (includeCompat) copyFileSync(runtimeCompatLib, join(libDir, process.platform === "win32" ? "lnako_runtime_compat.lib" : "liblnako_runtime_compat.a"));
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
  if (result.status !== 0 || typeof result.stdout !== "string") {
    fail(`実行に失敗しました: ${path}\n${result.stdout ?? ""}${result.stderr ?? ""}`);
    return "";
  }
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
