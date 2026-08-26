import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
if (arguments_.some((argument) => argument !== "--no-build")) throw new Error("usage: node tools/check_dispatch_trace.mjs [--no-build]");
const noBuild = arguments_.includes("--no-build");
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const fixture = cases.find((candidate) => candidate.id === "native-cut-commands");
if (fixture === undefined) throw new Error("dispatch trace用fixtureがありません: native-cut-commands");

const temporary = await mkdtemp(join(tmpdir(), "lnako-dispatch-trace-"));
try {
  if (!noBuild) buildCompiler();
  const source = resolve(temporary, "trace.nako3");
  const native = resolve(temporary, process.platform === "win32" ? "trace.exe" : "trace");
  const interpreterTrace = resolve(temporary, "interpreter.jsonl");
  const aotTrace = resolve(temporary, "aot.jsonl");
  await writeFile(source, fixture.source, "utf8");

  const baseEnvironment = { ...process.env, TZ: "Asia/Tokyo" };
  const interpretedWithoutTrace = run(compiler, ["run", source], baseEnvironment, temporary);
  assertSuccess("trace無効Interpreter", interpretedWithoutTrace);
  assertNoJsonl(await readdir(temporary));

  const interpretedWithTrace = run(
    compiler,
    ["run", source],
    { ...baseEnvironment, LNAKO_DISPATCH_TRACE: interpreterTrace },
    temporary,
  );
  assertEquivalent("Interpreter", interpretedWithoutTrace, interpretedWithTrace);
  const interpreterEvents = await readTrace(interpreterTrace, "interpreter", "dispatch-result");
  assertCommand(interpreterEvents, "切取", "success");
  assertCommand(interpreterEvents, "範囲切取", "success");
  assertOnlyCommands(interpreterEvents, new Set(["切取", "範囲切取", "表示", "CHR"]));
  await assertExistingTracePreserved("Interpreter", compiler, ["run", source], interpretedWithoutTrace, resolve(temporary, "interpreter-existing.jsonl"), baseEnvironment, temporary);

  const compiled = run(compiler, ["build", source, "-o", native, "-O0"], baseEnvironment, temporary);
  assertSuccess("AOTコンパイル", compiled);
  const aotWithoutTrace = run(native, [], baseEnvironment, temporary);
  assertSuccess("trace無効AOT", aotWithoutTrace);
  if ((await readdir(temporary)).some((name) => name === "aot.jsonl")) throw new Error("trace無効AOTがtraceファイルを生成しました");

  const aotWithTrace = run(native, [], { ...baseEnvironment, LNAKO_DISPATCH_TRACE: aotTrace }, temporary);
  assertEquivalent("AOT", aotWithoutTrace, aotWithTrace);
  const aotEvents = await readTrace(aotTrace, "aot", "dispatch-attempt");
  assertCanonicalCommand(aotEvents, "cut", "cut");
  assertCanonicalCommand(aotEvents, "cut_range", "cut");
  assertOnlyCommands(aotEvents, new Set(["cut", "cut_range", "chr"]));
  await assertExistingTracePreserved("AOT", native, [], aotWithoutTrace, resolve(temporary, "aot-existing.jsonl"), baseEnvironment, temporary);

  console.log(`dispatch traceスモークテスト: Interpreter ${interpreterEvents.length}イベント / AOT ${aotEvents.length}イベント成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
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

function run(command, arguments_, env, cwd) {
  return spawnSync(command, arguments_, { cwd, env, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
}

function assertSuccess(label, result) {
  if (result.status !== 0) throw new Error(`${label}に失敗しました (status=${result.status}, signal=${result.signal}):\n${result.stderr}`);
}

function assertEquivalent(label, withoutTrace, withTrace) {
  assertSuccess(`${label} trace有効実行`, withTrace);
  for (const field of ["status", "signal", "stdout", "stderr"]) {
    if (withoutTrace[field] !== withTrace[field]) {
      throw new Error(`${label}のtrace有無で${field}が変化しました:\n${JSON.stringify({ withoutTrace, withTrace }, null, 2)}`);
    }
  }
}

function assertNoJsonl(names) {
  if (names.some((name) => name.endsWith(".jsonl"))) throw new Error("trace無効Interpreterがtraceファイルを生成しました");
}

async function readTrace(path, engine, phase) {
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
    if (event.schema !== 1 || event.engine !== engine || event.seq !== index) {
      throw new Error(`${engine} trace metadataが不正です: ${JSON.stringify(event)}`);
    }
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(event, forbidden)) throw new Error(`${engine} traceに禁止フィールドがあります: ${forbidden}`);
    }
  }
  const end = events.at(-1);
  if (end.phase !== "trace-end" || end.dropped !== 0) throw new Error(`${engine} traceが正常に完結していません`);
  const dispatchEvents = events.slice(0, -1);
  if (dispatchEvents.some((event) => event.phase !== phase)) throw new Error(`${engine} traceのdispatch phaseが不正です`);
  return dispatchEvents;
}

function assertCommand(events, command, result) {
  if (!events.some((event) => event.command === command && event.result === result)) {
    throw new Error(`Interpreter traceに${command}/${result}がありません`);
  }
}

function assertCanonicalCommand(events, command, route) {
  if (!events.some((event) => event.command === command && event.route === route && event.name_source === "canonical-opcode")) {
    throw new Error(`AOT traceに${command}/${route}がありません`);
  }
}

function assertOnlyCommands(events, allowed) {
  const unexpected = events.filter((event) => !allowed.has(event.command));
  if (unexpected.length > 0) throw new Error(`dispatch traceに予期しない命令があります: ${JSON.stringify(unexpected)}`);
}

async function assertExistingTracePreserved(label, command, arguments_, expected, path, environment, cwd) {
  const sentinel = "既存traceは上書きしない\n";
  await writeFile(path, sentinel, "utf8");
  const result = run(command, arguments_, { ...environment, LNAKO_DISPATCH_TRACE: path }, cwd);
  assertEquivalent(`${label}既存trace`, expected, result);
  if (await readFile(path, "utf8") !== sentinel) throw new Error(`${label}が既存traceを上書きしました`);
}
