import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
if (arguments_.some((argument) => argument !== "--no-build")) throw new Error("usage: node tools/check_dispatch_trace.mjs [--no-build]");
const noBuild = arguments_.includes("--no-build");
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
if (catalog.commandCount !== 527 || catalog.commands.length !== 527) throw new Error("標準cnakoカタログが527 entryではありません");
const catalogByName = Map.groupBy(catalog.commands, (command) => command.name);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const fixture = cases.find((candidate) => candidate.id === "native-cut-commands");
if (fixture === undefined) throw new Error("dispatch trace用fixtureがありません: native-cut-commands");
const nodeCases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-file-cases.json"), "utf8"));
const nodeFixture = nodeCases.find((candidate) => candidate.id === "plugin-node-path-host");
if (nodeFixture === undefined) throw new Error("Node route trace用fixtureがありません: plugin-node-path-host");

const temporary = await mkdtemp(join(tmpdir(), "lnako-dispatch-trace-"));
try {
  if (!noBuild) buildCompiler();
  const source = resolve(temporary, "trace.nako3");
  const native = resolve(temporary, process.platform === "win32" ? "trace.exe" : "trace");
  const interpreterTrace = resolve(temporary, "interpreter.jsonl");
  const aotTrace = resolve(temporary, "aot.jsonl");
  const compileManifest = resolve(temporary, "compile-manifest.jsonl");
  const nodeSource = resolve(temporary, "node-route.nako3");
  const nodeTrace = resolve(temporary, "node-route.jsonl");
  const loopSource = resolve(temporary, "loop.nako3");
  const loopNative = resolve(temporary, process.platform === "win32" ? "loop.exe" : "loop");
  const loopTrace = resolve(temporary, "loop.jsonl");
  const loopManifest = resolve(temporary, "loop-manifest.jsonl");
  await writeFile(source, fixture.source, "utf8");
  await writeFile(nodeSource, nodeFixture.source, "utf8");
  await writeFile(loopSource, "N=2\n(N>0)の間、繰り返す\nNを表示\nN=N-1\nここまで\n", "utf8");

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
  assertCommand(interpreterEvents, "切取", "plugin_system", "success");
  assertCommand(interpreterEvents, "範囲切取", "plugin_system", "success");
  assertCommand(interpreterEvents, "表示", "interpreter-core", "success");
  assertCatalogResolution("切取", "plugin_system", "command-0141", "unique-name");
  assertCatalogResolution("範囲切取", "plugin_system", "command-0142", "unique-name");
  assertCatalogResolution("表示", "interpreter-core", "command-0307", "unique-name");
  assertOnlyCommands(interpreterEvents, new Set(["切取", "範囲切取", "表示", "CHR"]));
  assertStaticCommandsHaveSites(interpreterEvents, new Set(["切取", "範囲切取", "表示", "CHR"]));
  await assertExistingTracePreserved("Interpreter", compiler, ["run", source], interpretedWithoutTrace, resolve(temporary, "interpreter-existing.jsonl"), baseEnvironment, temporary);

  const nodeEnvironment = { ...baseEnvironment, LNAKO_NODE_TEST: "dispatch-trace" };
  const nodeWithoutTrace = run(compiler, ["run", nodeSource], nodeEnvironment, temporary);
  assertSuccess("trace無効Node route", nodeWithoutTrace);
  const nodeWithTrace = run(compiler, ["run", nodeSource], { ...nodeEnvironment, LNAKO_DISPATCH_TRACE: nodeTrace }, temporary);
  assertEquivalent("Node route", nodeWithoutTrace, nodeWithTrace);
  const nodeEvents = await readTrace(nodeTrace, "interpreter", "dispatch-result");
  assertCommand(nodeEvents, "ファイル名抽出", "plugin_node", "success");
  assertCommand(nodeEvents, "パス抽出", "plugin_node", "success");
  assertStaticCommandsHaveSites(nodeEvents, new Set(["ファイル名抽出", "パス抽出"]));
  assertCatalogResolution("ファイル名抽出", "plugin_node", "command-0722", "node-route-priority");
  assertCatalogResolution("パス抽出", "plugin_node", "command-0723", "node-route-priority");
  assertCatalogUnresolved("ファイル名抽出", "plugin_system");
  assertCatalogUnresolved("パス抽出", "plugin_system");

  const compiled = run(
    compiler,
    ["build", source, "-o", native, "-O0"],
    { ...baseEnvironment, LNAKO_COMPILE_MANIFEST: compileManifest },
    temporary,
  );
  assertSuccess("AOTコンパイル", compiled);
  const manifestEntries = await readCompileManifest(compileManifest, source);
  assertManifestCommand(manifestEntries, "切取", "cut", "cut", "command-0141");
  assertManifestCommand(manifestEntries, "範囲切取", "cut_range", "cut", "command-0142");
  assertManifestCommand(manifestEntries, "CHR", "chr", "builtin", "command-0122");
  assertManifestCommand(manifestEntries, "表示", "display", "direct-display", "command-0307");
  assertOnlyManifestCommands(manifestEntries, new Set(["切取", "範囲切取", "CHR", "表示"]));
  await assertExistingManifestPreserved(compiler, source, baseEnvironment, temporary);
  await assertFailedManifestRemoved(compiler, source, baseEnvironment, temporary);
  const aotWithoutTrace = run(native, [], baseEnvironment, temporary);
  assertSuccess("trace無効AOT", aotWithoutTrace);
  if ((await readdir(temporary)).some((name) => name === "aot.jsonl")) throw new Error("trace無効AOTがtraceファイルを生成しました");

  const aotWithTrace = run(native, [], { ...baseEnvironment, LNAKO_DISPATCH_TRACE: aotTrace }, temporary);
  assertEquivalent("AOT", aotWithoutTrace, aotWithTrace);
  const aotEvents = await readTrace(aotTrace, "aot");
  assertAotTrace(aotEvents, manifestEntries);
  if (!aotEvents.some((event) => event.phase === "dispatch-result" && event.success === false)) throw new Error("AOT traceにfailure resultがありません");
  assertCanonicalCommand(aotEvents, "cut", "cut");
  assertCanonicalCommand(aotEvents, "cut_range", "cut");
  assertCanonicalCommand(aotEvents, "display", "direct-display");
  assertOnlyCommands(aotEvents, new Set(["cut", "cut_range", "chr", "display"]));
  assertTraceSitesContained(aotEvents, manifestEntries);
  assertTraceSitesContained(interpreterEvents, manifestEntries);
  assertSameStaticSiteSet(interpreterEvents, aotEvents);

  const loopCompiled = run(
    compiler,
    ["build", loopSource, "-o", loopNative, "-O0"],
    { ...baseEnvironment, LNAKO_COMPILE_MANIFEST: loopManifest },
    temporary,
  );
  assertSuccess("ループAOTコンパイル", loopCompiled);
  const loopManifestEntries = await readCompileManifest(loopManifest, loopSource);
  const loopWithTrace = run(loopNative, [], { ...baseEnvironment, LNAKO_DISPATCH_TRACE: loopTrace }, temporary);
  assertSuccess("ループAOT trace実行", loopWithTrace);
  const loopEvents = await readTrace(loopTrace, "aot");
  assertAotTrace(loopEvents, loopManifestEntries);
  assertRepeatedSite(loopEvents);
  await assertExistingTracePreserved("AOT", native, [], aotWithoutTrace, resolve(temporary, "aot-existing.jsonl"), baseEnvironment, temporary);

  console.log(`dispatch証拠スモークテスト: Interpreter ${interpreterEvents.length}イベント / Node ${nodeEvents.length}イベント / AOT manifest ${manifestEntries.length}件・runtime ${aotEvents.length}イベント / loop ${loopEvents.length}イベント成功`);
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
    if (event.schema !== 2 || event.engine !== engine || event.seq !== index) {
      throw new Error(`${engine} trace metadataが不正です: ${JSON.stringify(event)}`);
    }
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(event, forbidden)) throw new Error(`${engine} traceに禁止フィールドがあります: ${forbidden}`);
    }
  }
  const end = events.at(-1);
  if (end.phase !== "trace-end" || end.dropped !== 0) throw new Error(`${engine} traceが正常に完結していません`);
  const dispatchEvents = events.slice(0, -1);
  if (phase !== undefined && dispatchEvents.some((event) => event.phase !== phase)) throw new Error(`${engine} traceのdispatch phaseが不正です`);
  for (const event of dispatchEvents) {
    if (event.siteId !== null && (typeof event.siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(event.siteId))) {
      throw new Error(`${engine} traceのsiteIdが不正です: ${JSON.stringify(event)}`);
    }
  }
  return dispatchEvents;
}

async function readCompileManifest(path, sourcePath) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error("AOT compile manifestが改行で完結していません");
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`AOT compile manifest ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error("AOT compile manifestにheaderと完了recordがありません");
  const schema = "lnako.aot.builtin-manifest.v1";
  const header = records[0];
  if (header.schema !== schema || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16") {
    throw new Error(`AOT compile manifest headerが不正です: ${JSON.stringify(header)}`);
  }
  const complete = records.at(-1);
  const entries = records.slice(1, -1);
  if (complete.schema !== schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== entries.length) {
    throw new Error(`AOT compile manifest完了recordが不正です: ${JSON.stringify(complete)}`);
  }
  const siteIds = new Set();
  for (const entry of entries) {
    if (entry.schema !== schema || entry.phase !== "pre-opt" || entry.kind !== "builtin-dispatch") {
      throw new Error(`AOT compile manifest entryが不正です: ${JSON.stringify(entry)}`);
    }
    if (![entry.sourceName, entry.canonicalOpcode, entry.route, entry.function].every((value) => typeof value === "string" && value.length > 0)) {
      throw new Error(`AOT compile manifestの文字列fieldが不正です: ${JSON.stringify(entry)}`);
    }
    if (!Number.isInteger(entry.opcode) || entry.opcode < 0 || entry.opcode > 0xffff) {
      throw new Error(`AOT compile manifestのopcodeが不正です: ${JSON.stringify(entry)}`);
    }
    if (typeof entry.siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) {
      throw new Error(`AOT compile manifestのsiteIdが不正または重複しています: ${JSON.stringify(entry)}`);
    }
    siteIds.add(entry.siteId);
    const location = entry.source;
    if (location === null || !Number.isInteger(location.line) || location.line < 1 || !Number.isInteger(location.column) || location.column < 1 || !Number.isInteger(location.sourceStart) || !Number.isInteger(location.sourceEnd) || location.sourceStart < 0 || location.sourceEnd < location.sourceStart) {
      throw new Error(`AOT compile manifestのsource位置が不正です: ${JSON.stringify(entry)}`);
    }
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(entry, forbidden)) throw new Error(`AOT compile manifestに禁止フィールドがあります: ${forbidden}`);
    }
  }
  return entries;
}

function assertCommand(events, command, route, result) {
  if (!events.some((event) => event.command === command && event.route === route && event.result === result)) {
    throw new Error(`Interpreter traceに${command}/${route}/${result}がありません`);
  }
}

function assertCanonicalCommand(events, command, route) {
  if (!events.some((event) => event.command === command && event.route === route && event.name_source === "canonical-opcode" && (event.phase === "dispatch-attempt" || event.phase === "dispatch-result"))) {
    throw new Error(`AOT traceに${command}/${route}がありません`);
  }
}

function assertAotTrace(events, manifestEntries) {
  const attempts = events.filter((event) => event.phase === "dispatch-attempt");
  const results = events.filter((event) => event.phase === "dispatch-result");
  if (attempts.length === 0 || attempts.length !== results.length) throw new Error(`AOT traceのattempt/result件数が一致しません: ${attempts.length}/${results.length}`);
  const manifestBySite = new Map(manifestEntries.map((entry) => [entry.siteId, entry]));
  const attemptsByCall = new Map();
  const resultsByCall = new Map();
  for (const attempt of attempts) {
    if (!Number.isSafeInteger(attempt.callId) || attemptsByCall.has(attempt.callId)) throw new Error(`AOT traceのcallIdが不正または重複しています: ${JSON.stringify(attempt)}`);
    if (!Number.isInteger(attempt.opcode) || typeof attempt.command !== "string" || typeof attempt.route !== "string" || attempt.name_source !== "canonical-opcode") throw new Error(`AOT trace attemptのdispatch metadataが不正です: ${JSON.stringify(attempt)}`);
    if (attempt.siteId === null || !manifestBySite.has(attempt.siteId)) throw new Error(`runtime traceの静的siteIdがmanifestにありません: ${JSON.stringify(attempt)}`);
    const manifestEntry = manifestBySite.get(attempt.siteId);
    if (manifestEntry.canonicalOpcode !== attempt.command || manifestEntry.route !== attempt.route || manifestEntry.opcode !== attempt.opcode) throw new Error(`runtime traceとmanifestのdispatchが一致しません: ${JSON.stringify({ attempt, manifestEntry })}`);
    attemptsByCall.set(attempt.callId, attempt);
  }
  for (const result of results) {
    if (!Number.isSafeInteger(result.callId) || resultsByCall.has(result.callId)) throw new Error(`AOT resultのcallIdが不正または重複しています: ${JSON.stringify(result)}`);
    if (!Number.isInteger(result.opcode) || typeof result.command !== "string" || typeof result.route !== "string") throw new Error(`AOT trace resultのdispatch metadataが不正です: ${JSON.stringify(result)}`);
    const attempt = attemptsByCall.get(result.callId);
    if (attempt === undefined || result.siteId !== attempt.siteId || result.opcode !== attempt.opcode || result.command !== attempt.command || result.route !== attempt.route || typeof result.success !== "boolean") {
      throw new Error(`AOT traceのattempt/result対応が不正です: ${JSON.stringify({ attempt, result })}`);
    }
    resultsByCall.set(result.callId, result);
  }
  if (resultsByCall.size !== attemptsByCall.size) throw new Error("AOT traceに対応しないattemptがあります");
}

function assertRepeatedSite(events) {
  const siteCallCounts = new Map();
  for (const attempt of events.filter((event) => event.phase === "dispatch-attempt")) {
    if (attempt.siteId !== null) siteCallCounts.set(attempt.siteId, (siteCallCounts.get(attempt.siteId) ?? 0) + 1);
  }
  if (!Array.from(siteCallCounts.values()).some((count) => count > 1)) throw new Error("同一siteの複数callId実行を検証できません");
}

function assertTraceSitesContained(events, manifestEntries) {
  const sites = new Set(manifestEntries.map((entry) => entry.siteId));
  for (const event of events) if (event.siteId !== null && !sites.has(event.siteId)) throw new Error(`trace siteIdがmanifestにありません: ${JSON.stringify(event)}`);
}

function assertStaticCommandsHaveSites(events, commands) {
  for (const command of commands) {
    const matches = events.filter((event) => event.command === command);
    if (matches.length === 0 || matches.some((event) => event.siteId === null)) throw new Error(`静的命令${command}のsiteIdがnullです`);
  }
}

function assertSameStaticSiteSet(left, right) {
  const leftSites = new Set(left.filter((event) => event.siteId !== null).map((event) => event.siteId));
  const rightSites = new Set(right.filter((event) => event.siteId !== null).map((event) => event.siteId));
  if (leftSites.size !== rightSites.size || [...leftSites].some((site) => !rightSites.has(site))) {
    throw new Error(`Interpreter/AOTの静的dispatch site集合が一致しません: ${JSON.stringify({ interpreter: [...leftSites], aot: [...rightSites] })}`);
  }
}

function assertManifestCommand(entries, sourceName, canonicalOpcode, route, catalogId) {
  if (!entries.some((entry) => entry.sourceName === sourceName && entry.canonicalOpcode === canonicalOpcode && entry.route === route)) {
    throw new Error(`AOT compile manifestに${sourceName}/${canonicalOpcode}/${route}がありません`);
  }
  assertCatalogResolution(sourceName, route, catalogId, "unique-name");
}

function assertOnlyManifestCommands(entries, allowed) {
  const unexpected = entries.filter((entry) => !allowed.has(entry.sourceName));
  if (unexpected.length > 0) throw new Error(`AOT compile manifestに予期しない命令があります: ${JSON.stringify(unexpected)}`);
}

function resolveCatalogCommand(name, route) {
  const candidates = catalogByName.get(name) ?? [];
  if (candidates.length === 1) return { command: candidates[0], reason: "unique-name" };
  if (route === "plugin_node") {
    const nodeCandidates = candidates.filter((command) => command.plugin === "plugin_node");
    if (nodeCandidates.length === 1) return { command: nodeCandidates[0], reason: "node-route-priority" };
  }
  return null;
}

function assertCatalogResolution(name, route, id, reason) {
  const resolved = resolveCatalogCommand(name, route);
  if (resolved === null || resolved.command.id !== id || resolved.reason !== reason) {
    throw new Error(`catalog ID解決が不正です: ${JSON.stringify({ name, route, expected: { id, reason }, resolved })}`);
  }
}

function assertCatalogUnresolved(name, route) {
  const resolved = resolveCatalogCommand(name, route);
  if (resolved !== null) throw new Error(`同名命令を過大にcatalog IDへ解決しました: ${JSON.stringify({ name, route, resolved })}`);
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

async function assertExistingManifestPreserved(command, source, environment, cwd) {
  const path = resolve(cwd, "manifest-existing.jsonl");
  const output = resolve(cwd, process.platform === "win32" ? "manifest-existing.exe" : "manifest-existing");
  const sentinel = "既存manifestは上書きしない\n";
  await writeFile(path, sentinel, "utf8");
  const result = run(command, ["build", source, "-o", output, "-O0"], { ...environment, LNAKO_COMPILE_MANIFEST: path }, cwd);
  if (result.status === 0) throw new Error("既存AOT compile manifestを指定したbuildが成功しました");
  if (await readFile(path, "utf8") !== sentinel) throw new Error("AOT compile manifestが既存ファイルを上書きしました");
}

async function assertFailedManifestRemoved(command, source, environment, cwd) {
  const path = resolve(cwd, "manifest-failed.jsonl");
  const output = resolve(cwd, process.platform === "win32" ? "failed.exe" : "failed");
  const missingLlvm = resolve(cwd, process.platform === "win32" ? "missing-LLVM-C.dll" : "missing-libLLVM");
  const result = run(
    command,
    ["build", source, "-o", output, "-O0"],
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
