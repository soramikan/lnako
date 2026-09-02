import { access, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const throwStatementOpcode = 0xffff;
const arguments_ = process.argv.slice(2);
let noBuild = false;
for (const argument of arguments_) {
  if (argument === "--no-build") {
    if (noBuild) throw new Error("--no-buildは1回だけ指定してください");
    noBuild = true;
    continue;
  }
  throw new Error("usage: node tools/check_dispatch_trace_security.mjs [--no-build]");
}

const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const source = resolve(root, "tests/fixtures/dispatch-security.nako3");
if (!noBuild) buildCompiler();
await access(compiler);
await access(source);

const temporary = await mkdtemp(join(root, ".tmp-lnako-dispatch-security-"));
try {
  const environment = { ...process.env, TZ: "Asia/Tokyo" };
  const interpreterTracePath = resolve(temporary, "interpreter.jsonl");
  const interpreterWithoutTrace = run(compiler, ["run", source], environment, temporary);
  assertSuccess("security fixture Interpreter", interpreterWithoutTrace);
  if ((await readdir(temporary)).some((name) => name.endsWith(".jsonl"))) {
    throw new Error("trace無効security fixture Interpreterがtraceファイルを生成しました");
  }

  const interpreterWithTrace = run(compiler, ["run", source], { ...environment, LNAKO_DISPATCH_TRACE: interpreterTracePath }, temporary);
  assertEquivalent("security fixture Interpreterのtrace有無", interpreterWithoutTrace, interpreterWithTrace);
  const interpreterEvents = await readTrace(interpreterTracePath, "interpreter", "dispatch-result");
  if (interpreterEvents.length === 0 || interpreterEvents.some((event) => event.result !== "success")) {
    throw new Error("security fixture Interpreter traceに成功dispatchがありません");
  }
  await assertExistingTracePreserved(
    "security fixture Interpreter",
    compiler,
    ["run", source],
    interpreterWithoutTrace,
    resolve(temporary, "interpreter-existing.jsonl"),
    environment,
    temporary,
  );

  const native = resolve(temporary, process.platform === "win32" ? "security.exe" : "security");
  const compileManifest = resolve(temporary, "security-manifest.jsonl");
  const compiled = run(
    compiler,
    ["build", source, "-o", native, "-O0"],
    { ...environment, LNAKO_COMPILE_MANIFEST: compileManifest },
    temporary,
  );
  assertSuccess("security fixture AOTコンパイル", compiled);
  const manifestEntries = await readCompileManifest(compileManifest, source);
  await assertExistingManifestPreserved(compiler, source, environment, temporary);
  await assertFailedManifestRemoved(compiler, source, environment, temporary);

  const aotTracePath = resolve(temporary, "aot.jsonl");
  const aotWithoutTrace = run(native, [], environment, temporary);
  assertSuccess("trace無効security fixture AOT", aotWithoutTrace);
  if ((await readdir(temporary)).includes("aot.jsonl")) throw new Error("trace無効security fixture AOTがtraceを生成しました");
  const aotWithTrace = run(native, [], { ...environment, LNAKO_DISPATCH_TRACE: aotTracePath }, temporary);
  assertEquivalent("security fixture AOTのtrace有無", aotWithoutTrace, aotWithTrace);
  const aotEvents = await readTrace(aotTracePath, "aot");
  assertAotTrace(aotEvents, manifestEntries);
  assertTraceSitesContained(aotEvents, manifestEntries);
  assertRepeatedSite(aotEvents);
  await assertExistingTracePreserved(
    "security fixture AOT",
    native,
    [],
    aotWithoutTrace,
    resolve(temporary, "aot-existing.jsonl"),
    environment,
    temporary,
  );

  console.log(`dispatch trace security検査: tiny fixture / Interpreter ${interpreterEvents.length}イベント / AOT manifest ${manifestEntries.length}件・runtime ${aotEvents.length}イベント / 既存ファイル保護・失敗cleanup・loop成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function run(command, arguments_, environment, cwd) {
  return spawnSync(command, arguments_, { cwd, env: environment, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
}

function assertSuccess(label, result) {
  if (result.status !== 0) throw new Error(`${label}に失敗しました (status=${result.status}, signal=${result.signal}):\n${result.stderr}`);
}

function assertEquivalent(label, withoutTrace, withTrace) {
  assertSuccess(`${label} trace有効実行`, withTrace);
  for (const field of ["status", "signal", "stdout", "stderr"]) {
    if (withoutTrace[field] !== withTrace[field]) throw new Error(`${label}で${field}が変化しました`);
  }
}

async function assertExistingTracePreserved(label, command, arguments_, expected, path, environment, cwd) {
  const sentinel = "既存traceは上書きしない\n";
  await writeFile(path, sentinel, "utf8");
  const result = run(command, arguments_, { ...environment, LNAKO_DISPATCH_TRACE: path }, cwd);
  assertEquivalent(`${label}既存trace`, expected, result);
  if (await readFile(path, "utf8") !== sentinel) throw new Error(`${label}が既存traceを上書きしました`);
}

async function assertExistingManifestPreserved(command, sourcePath, environment, cwd) {
  const path = resolve(cwd, "manifest-existing.jsonl");
  const output = resolve(cwd, process.platform === "win32" ? "manifest-existing.exe" : "manifest-existing");
  const sentinel = "既存manifestは上書きしない\n";
  await writeFile(path, sentinel, "utf8");
  const result = run(command, ["build", sourcePath, "-o", output, "-O0"], { ...environment, LNAKO_COMPILE_MANIFEST: path }, cwd);
  if (result.status === 0) throw new Error("既存AOT compile manifestを指定したbuildが成功しました");
  if (await readFile(path, "utf8") !== sentinel) throw new Error("AOT compile manifestが既存ファイルを上書きしました");
}

async function assertFailedManifestRemoved(command, sourcePath, environment, cwd) {
  const path = resolve(cwd, "manifest-failed.jsonl");
  const output = resolve(cwd, process.platform === "win32" ? "failed.exe" : "failed");
  const missingLlvm = resolve(cwd, process.platform === "win32" ? "missing-LLVM-C.dll" : "missing-libLLVM");
  const result = run(
    command,
    ["build", sourcePath, "-o", output, "-O0"],
    { ...environment, LNAKO_COMPILE_MANIFEST: path, LNAKO_LLVM_LIBRARY: missingLlvm },
    cwd,
  );
  if (result.status === 0) throw new Error("存在しないLLVMライブラリを指定したAOT buildが成功しました");
  try {
    await readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  throw new Error("失敗したAOT buildが部分manifestを残しました");
}

async function readTrace(path, engine, phase = undefined) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error(`${engine} traceが改行で完結していません`);
  const events = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${engine} trace ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (events.length < 2) throw new Error(`${engine} traceにdispatchと終端イベントがありません`);
  for (const [index, event] of events.entries()) {
    if (event.schema !== 2 || event.engine !== engine || event.seq !== index) throw new Error(`${engine} trace metadataが不正です`);
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(event, forbidden)) throw new Error(`${engine} traceに禁止フィールドがあります: ${forbidden}`);
    }
  }
  const end = events.at(-1);
  if (end.phase !== "trace-end" || end.dropped !== 0) throw new Error(`${engine} traceが正常に完結していません`);
  const dispatchEvents = events.slice(0, -1);
  if (phase !== undefined && dispatchEvents.some((event) => event.phase !== phase)) throw new Error(`${engine} traceのdispatch phaseが不正です`);
  for (const event of dispatchEvents) {
    if (event.siteId !== null && (typeof event.siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(event.siteId))) throw new Error(`${engine} traceのsiteIdが不正です`);
  }
  return dispatchEvents;
}

async function readCompileManifest(path, sourcePath) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error("AOT compile manifestが改行で完結していません");
  const records = text.trimEnd().split("\n").map((line) => JSON.parse(line));
  if (records.length < 2) throw new Error("AOT compile manifestにheaderと完了recordがありません");
  const schema = "lnako.aot.builtin-manifest.v1";
  const header = records[0];
  const complete = records.at(-1);
  if (header.schema !== schema || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16") throw new Error("AOT compile manifest headerが不正です");
  const entries = records.slice(1, -1);
  if (complete.schema !== schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== entries.length) throw new Error("AOT compile manifest完了recordが不正です");
  const sites = new Set();
  for (const entry of entries) {
    const validKind = entry.kind === "builtin-dispatch" ||
      (entry.kind === "throw-dispatch" && entry.sourceName === "エラー発生" && entry.canonicalOpcode === "throw_statement" &&
        entry.route === "throw" && entry.opcode === throwStatementOpcode);
    if (entry.schema !== schema || entry.phase !== "pre-opt" || !validKind || typeof entry.sourceName !== "string" || typeof entry.canonicalOpcode !== "string" || typeof entry.route !== "string" || !Number.isInteger(entry.opcode) || typeof entry.siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(entry.siteId) || sites.has(entry.siteId)) throw new Error("AOT compile manifest entryが不正です");
    sites.add(entry.siteId);
  }
  return entries;
}

function assertAotTrace(events, manifestEntries) {
  const attempts = events.filter((event) => event.phase === "dispatch-attempt");
  const results = events.filter((event) => event.phase === "dispatch-result");
  if (attempts.length === 0 || attempts.length !== results.length) throw new Error(`AOT traceのattempt/result件数が一致しません: ${attempts.length}/${results.length}`);
  const manifestBySite = new Map(manifestEntries.map((entry) => [entry.siteId, entry]));
  const attemptsByCall = new Map();
  for (const attempt of attempts) {
    if (!Number.isSafeInteger(attempt.callId) || attemptsByCall.has(attempt.callId) || attempt.siteId === null || !manifestBySite.has(attempt.siteId)) throw new Error("AOT trace attemptが不正です");
    const manifestEntry = manifestBySite.get(attempt.siteId);
    if (manifestEntry.canonicalOpcode !== attempt.command || manifestEntry.route !== attempt.route || manifestEntry.opcode !== attempt.opcode || attempt.name_source !== "canonical-opcode") throw new Error("AOT traceとmanifestのdispatchが一致しません");
    attemptsByCall.set(attempt.callId, attempt);
  }
  const resultCalls = new Set();
  for (const result of results) {
    const attempt = attemptsByCall.get(result.callId);
    if (!Number.isSafeInteger(result.callId) || resultCalls.has(result.callId) || attempt === undefined || result.siteId !== attempt.siteId || result.opcode !== attempt.opcode || result.command !== attempt.command || result.route !== attempt.route || typeof result.success !== "boolean") throw new Error("AOT trace resultがattemptと一致しません");
    resultCalls.add(result.callId);
  }
  if (resultCalls.size !== attemptsByCall.size) throw new Error("AOT traceに対応しないattemptがあります");
}

function assertTraceSitesContained(events, manifestEntries) {
  const sites = new Set(manifestEntries.map((entry) => entry.siteId));
  for (const event of events) if (event.siteId !== null && !sites.has(event.siteId)) throw new Error("trace siteIdがmanifestにありません");
}

function assertRepeatedSite(events) {
  const counts = new Map();
  for (const event of events.filter((candidate) => candidate.phase === "dispatch-attempt")) {
    if (event.siteId !== null) counts.set(event.siteId, (counts.get(event.siteId) ?? 0) + 1);
  }
  if (![...counts.values()].some((count) => count > 1)) throw new Error("同一siteの複数callId実行を検証できません");
}

function buildCompiler() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  assertSuccess("lnakoビルド", result);
}
