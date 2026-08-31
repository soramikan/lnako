import { link, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
let evidenceOutput = null;
for (let index = 0; index < arguments_.length; index += 1) {
  const argument = arguments_[index];
  if (argument === "--no-build") continue;
  if (argument === "--evidence-output" && evidenceOutput === null) {
    evidenceOutput = arguments_[index + 1] ?? null;
    if (evidenceOutput === null || !isAbsolute(evidenceOutput)) throw new Error("--evidence-outputには絶対パスを指定してください");
    index += 1;
    continue;
  }
  throw new Error("usage: node tools/check_dispatch_trace.mjs [--no-build] [--evidence-output /absolute/path]");
}
const noBuild = arguments_.includes("--no-build");
if (evidenceOutput !== null) {
  try {
    await readFile(evidenceOutput);
    throw new Error(`dispatch証拠の出力先は既に存在します: ${evidenceOutput}`);
  } catch (error) {
    if (error?.message?.startsWith("dispatch証拠の出力先は既に存在します")) throw error;
    if (error?.code !== "ENOENT") throw error;
  }
}
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
if (catalog.commandCount !== 527 || catalog.commands.length !== 527) throw new Error("標準cnakoカタログが527 entryではありません");
const catalogByName = Map.groupBy(catalog.commands, (command) => command.name);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const fixtureBase = cases.find((candidate) => candidate.id === "native-cut-commands");
if (fixtureBase === undefined) throw new Error("dispatch trace用fixtureがありません: native-cut-commands");
const dispatchFixtureIds = fixtureBase.dispatchFixtureIds ?? [fixtureBase.id];
if (!Array.isArray(dispatchFixtureIds) || dispatchFixtureIds.length === 0 || dispatchFixtureIds[0] !== fixtureBase.id || new Set(dispatchFixtureIds).size !== dispatchFixtureIds.length || dispatchFixtureIds.some((id) => typeof id !== "string" || id.length === 0)) {
  throw new Error("dispatch trace用fixtureのdispatchFixtureIdsが不正です");
}
const dispatchFixtures = dispatchFixtureIds.map((id) => {
  const candidate = cases.find((fixture) => fixture.id === id);
  if (candidate === undefined || typeof candidate.source !== "string") throw new Error(`dispatch trace用fixtureがありません: ${id}`);
  if (id !== fixtureBase.id && !Array.isArray(candidate.commands)) throw new Error(`dispatch trace用fixtureにcommandsがありません: ${id}`);
  return candidate;
});
const fixture = {
  ...fixtureBase,
  commands: [...new Set(dispatchFixtures.flatMap((candidate) => candidate.commands ?? []))],
  source: dispatchFixtures.map((candidate) => candidate.source).join("\n"),
};
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
  await writeFile(source, expandPluginImports(fixture.source, temporary), "utf8");
  await writeFile(nodeSource, nodeFixture.source, "utf8");

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
  assertFixtureInterpreterCoverage(interpreterEvents, fixture.commands);

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
  assertFixtureManifestCoverage(manifestEntries, fixture.commands);
  const aotWithoutTrace = run(native, [], baseEnvironment, temporary);
  assertSuccess("trace無効AOT", aotWithoutTrace);
  if ((await readdir(temporary)).some((name) => name === "aot.jsonl")) throw new Error("trace無効AOTがtraceファイルを生成しました");

  const aotWithTrace = run(native, [], { ...baseEnvironment, LNAKO_DISPATCH_TRACE: aotTrace }, temporary);
  assertEquivalent("AOT", aotWithoutTrace, aotWithTrace);
  const aotEvents = await readTrace(aotTrace, "aot");
  assertAotTrace(aotEvents, manifestEntries);
  if (!aotEvents.some((event) => event.phase === "dispatch-result" && event.success === false)) throw new Error("AOT traceにfailure resultがありません");
  assertFixtureAotCoverage(aotEvents, manifestEntries, fixture.commands);
  assertTraceSitesContained(aotEvents, manifestEntries);
  assertTraceSitesContained(interpreterEvents, manifestEntries);
  assertSameStaticSiteSet(interpreterEvents, aotEvents);

  if (evidenceOutput !== null) {
    const oracle = await readOracleIdentity();
    const officialSource = run(
      process.execPath,
      [oracle.cliPath, source],
      baseEnvironment,
      temporary,
    );
    assertSuccess("公式cnako3 source", officialSource);
    const officialGeneratedPath = resolve(temporary, "official-generated.mjs");
    const officialCompile = run(
      process.execPath,
      [oracle.cliPath, "--compile", "--silent", "--output", officialGeneratedPath, source],
      baseEnvironment,
      temporary,
    );
    assertSuccess("公式cnako3 JavaScript生成", officialCompile);
    const officialGenerated = run(process.execPath, [officialGeneratedPath], baseEnvironment, temporary);
    assertSuccess("公式生成JavaScript", officialGenerated);
    for (const [label, result] of [
      ["公式生成JavaScript", officialGenerated],
      ["lnako Interpreter", interpretedWithoutTrace],
      ["lnako AOT O0", aotWithoutTrace],
    ]) assertOfficialProcessEquivalent(`公式cnako3 source/${label}`, officialSource, result);
    await writeDispatchEvidence(evidenceOutput, fixture, interpreterEvents, aotEvents, manifestEntries, {
      officialSource,
      officialGenerated,
      interpretedWithoutTrace,
      aotWithoutTrace,
      oracle,
      compiler,
    });
  }

  console.log(`dispatch証拠スモークテスト: Interpreter ${interpreterEvents.length}イベント / Node ${nodeEvents.length}イベント / AOT manifest ${manifestEntries.length}件・runtime ${aotEvents.length}イベント成功`);
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

function expandPluginImports(source, fixtureDirectory) {
  const oracleRoot = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
  const replacements = {
    "${PLUGIN_CANIUSE}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_caniuse.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_KANSUJI}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_kansuji.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_MARKUP}": relative(fixtureDirectory, resolve(oracleRoot, "src/plugin_markup.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_CSV}": relative(fixtureDirectory, resolve(oracleRoot, "core/src/plugin_csv.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_TOML}": relative(fixtureDirectory, resolve(oracleRoot, "core/src/plugin_toml.mjs")).replaceAll("\\", "/"),
  };
  return Object.entries(replacements).reduce((expanded, [placeholder, path]) => expanded.replaceAll(placeholder, path), source);
}

function assertSuccess(label, result) {
  if (result.status !== 0) throw new Error(`${label}に失敗しました (status=${result.status}, signal=${result.signal}):\n${result.stderr}`);
}

function assertEquivalent(label, withoutTrace, withTrace) {
  assertSuccess(`${label} trace有効実行`, withTrace);
  assertProcessEquivalent(`${label}のtrace有無`, withoutTrace, withTrace);
}

function assertProcessEquivalent(label, left, right) {
  for (const field of ["status", "signal", "stdout", "stderr"]) {
    if (left[field] !== right[field]) throw new Error(`${label}で${field}が変化しました:\n${JSON.stringify({ left, right }, null, 2)}`);
  }
}

function assertOfficialProcessEquivalent(label, left, right) {
  for (const field of ["status", "signal"]) {
    if (left[field] !== right[field]) throw new Error(`${label}で${field}が変化しました:\n${JSON.stringify({ left, right }, null, 2)}`);
  }
  for (const field of ["stdout", "stderr"]) {
    if (normalizeLineEndings(left[field]) !== normalizeLineEndings(right[field])) {
      throw new Error(`${label}で正規化${field}が変化しました:\n${JSON.stringify({ left, right }, null, 2)}`);
    }
  }
}

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n");
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
  Object.defineProperty(dispatchEvents, "rawSha256", { value: sha256(text), enumerable: false });
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
  Object.defineProperty(entries, "rawSha256", { value: sha256(text), enumerable: false });
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

function assertFixtureInterpreterCoverage(events, commands) {
  const expected = new Set(commands);
  if (expected.size !== commands.length) throw new Error("dispatch証拠fixtureのcommandsに重複があります");
  assertOnlyCommands(events, expected);
  assertStaticCommandsHaveSites(events, expected);
  for (const name of expected) {
    const event = events.find((candidate) => candidate.command === name && candidate.result === "success");
    if (event === undefined) throw new Error(`dispatch証拠fixtureの${name}に成功したInterpreter eventがありません`);
    const catalogRoute = event.route === "plugin_node" ? "plugin_node" : "plugin_system";
    const resolution = resolveCatalogCommand(name, catalogRoute);
    if (resolution === null || resolution.reason !== "unique-name") {
      throw new Error(`dispatch証拠fixtureの${name}を一意なcatalog IDへ解決できません: ${JSON.stringify({ event, resolution })}`);
    }
  }
}

function assertFixtureManifestCoverage(entries, commands) {
  const expected = new Set(commands);
  assertOnlyManifestCommands(entries, expected);
  for (const name of expected) {
    const entry = entries.find((candidate) => candidate.sourceName === name);
    if (entry === undefined) throw new Error(`AOT compile manifestにdispatch証拠fixtureの${name}がありません`);
    const resolution = resolveCatalogCommand(name, "plugin_system");
    if (resolution === null || resolution.reason !== "unique-name") {
      throw new Error(`AOT compile manifestの${name}を一意なcatalog IDへ解決できません: ${JSON.stringify({ entry, resolution })}`);
    }
  }
}

function assertFixtureAotCoverage(events, entries, commands) {
  const expected = new Set(commands);
  assertOnlyCommands(events, new Set(entries.map((entry) => entry.canonicalOpcode)));
  for (const entry of entries) {
    if (!expected.has(entry.sourceName)) continue;
    assertCanonicalCommand(events, entry.canonicalOpcode, entry.route);
  }
  for (const name of expected) {
    const entriesForName = entries.filter((entry) => entry.sourceName === name);
    if (entriesForName.length === 0 || !entriesForName.some((entry) => hasSuccessfulAotSite(events, entry.siteId))) {
      throw new Error(`dispatch証拠fixtureの${name}に成功したAOT siteがありません`);
    }
  }
}

function hasSuccessfulAotSite(events, siteId) {
  const attempts = new Map(events.filter((event) => event.phase === "dispatch-attempt").map((event) => [event.callId, event]));
  return events.some((event) => event.phase === "dispatch-result" && event.siteId === siteId && event.success === true && attempts.has(event.callId));
}

function assertSameStaticSiteSet(left, right) {
  const leftSites = new Set(left.filter((event) => event.siteId !== null).map((event) => event.siteId));
  const rightSites = new Set(right.filter((event) => event.siteId !== null).map((event) => event.siteId));
  if (leftSites.size !== rightSites.size || [...leftSites].some((site) => !rightSites.has(site))) {
    throw new Error(`Interpreter/AOTの静的dispatch site集合が一致しません: ${JSON.stringify({ interpreter: [...leftSites], aot: [...rightSites] })}`);
  }
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

async function writeDispatchEvidence(output, fixture, interpreterEvents, aotEvents, manifestEntries, processes) {
  if (!Array.isArray(fixture.commands) || fixture.commands.length === 0) throw new Error("dispatch証拠fixtureには明示commandsが必要です");
  const git = gitState();
  const attempts = new Map(aotEvents.filter((event) => event.phase === "dispatch-attempt").map((event) => [event.callId, event]));
  const results = new Map(aotEvents.filter((event) => event.phase === "dispatch-result").map((event) => [event.callId, event]));
  const sites = [];
  const commandSiteCounts = new Map();
  const seenSites = new Set();
  for (const entry of manifestEntries) {
    const resolution = resolveCatalogCommand(entry.sourceName, entry.route);
    if (resolution === null || resolution.command.name !== entry.sourceName) {
      throw new Error(`dispatch証拠のcatalog IDを一意に解決できません: ${entry.sourceName}/${entry.route}`);
    }
    const interpreterSiteEvents = interpreterEvents.filter((event) => event.siteId === entry.siteId);
    if (interpreterSiteEvents.some((event) => event.command !== entry.sourceName)) {
      throw new Error(`dispatch証拠のsiteIdに異なるInterpreter命令があります: ${entry.siteId}`);
    }
    const interpreterRoutes = new Set(interpreterSiteEvents.map((event) => event.route).filter((route) => typeof route === "string" && route.length > 0));
    if (interpreterSiteEvents.length > 0 && interpreterRoutes.size !== 1) {
      throw new Error(`dispatch証拠のInterpreter routeが一意ではありません: ${entry.siteId}`);
    }
    const interpreterMatches = interpreterSiteEvents.filter((event) => event.command === entry.sourceName && event.result === "success");
    const aotMatches = aotEvents
      .filter((event) => event.phase === "dispatch-attempt" && event.siteId === entry.siteId)
      .map((attempt) => ({ attempt, result: results.get(attempt.callId) }))
      .filter(({ result }) => result?.success === true);
    if (interpreterMatches.length === 0 || aotMatches.length === 0) continue;
    if (seenSites.has(entry.siteId)) throw new Error(`dispatch証拠のsiteIdが重複しています: ${entry.siteId}`);
    seenSites.add(entry.siteId);
    const aotMatch = aotMatches[0];
    sites.push({
      catalogId: resolution.command.id,
      name: resolution.command.name,
      plugin: resolution.command.plugin,
      siteId: entry.siteId,
      sourceName: entry.sourceName,
      canonicalOpcode: entry.canonicalOpcode,
      opcode: entry.opcode,
      route: entry.route,
      runtime: {
        interpreter: { result: "success", route: [...interpreterRoutes][0], count: interpreterMatches.length },
        aot: { success: true, callId: aotMatch.attempt.callId, count: aotMatches.length },
      },
      officialEquivalent: true,
    });
    commandSiteCounts.set(resolution.command.id, (commandSiteCounts.get(resolution.command.id) ?? 0) + 1);
  }
  const expectedCommands = new Set(fixture.commands);
  for (const name of expectedCommands) {
    const resolution = resolveCatalogCommand(name, "cut");
    if (resolution === null || (commandSiteCounts.get(resolution.command.id) ?? 0) === 0) {
      const candidate = manifestEntries.find((entry) => entry.sourceName === name);
      const actualResolution = candidate === undefined ? null : resolveCatalogCommand(name, candidate.route);
      if (actualResolution === null || (commandSiteCounts.get(actualResolution.command.id) ?? 0) === 0) {
        throw new Error(`dispatch証拠fixtureの${name}に成功した同一siteがありません`);
      }
    }
  }
  const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
  const routeResults = Object.fromEntries(Object.entries({
    officialSource: processes.officialSource,
    officialGenerated: processes.officialGenerated,
    lnakoRun: processes.interpretedWithoutTrace,
    lnakoNativeO0: processes.aotWithoutTrace,
  }).map(([route, result]) => [route, {
    status: result.status,
    signal: result.signal,
    stdoutSha256: sha256(normalizeLineEndings(result.stdout)),
    stderrSha256: sha256(normalizeLineEndings(result.stderr)),
  }]));
  const evidence = {
    schema: "lnako.dispatch-evidence.v2",
    generator: "tools/check_dispatch_trace.mjs",
    baseline: { tag: lock.nadesiko3.tag, commit: lock.nadesiko3.commit },
    fixture: {
      id: fixture.id,
      file: "native-cases.json",
      sourceSha256: sha256(fixture.source),
    },
    officialComparison: {
      oracle: "official-source",
      routes: Object.keys(routeResults),
      equivalent: true,
      results: routeResults,
    },
    attestation: null,
    provenance: {
      environment: {
        platform: process.platform,
        arch: process.arch,
        node: process.version,
      },
      oracle: {
        build: processes.oracle.build,
        archiveSha256: processes.oracle.archiveSha256,
        cliSha256: processes.oracle.cliSha256,
        markerSha256: processes.oracle.markerSha256,
        treeHashAlgorithm: processes.oracle.treeHashAlgorithm,
        treeSha256: processes.oracle.treeSha256,
      },
      lnako: {
        binarySha256: sha256(await readFile(processes.compiler)),
        commit: git.commit,
        dirty: git.dirty,
      },
      raw: {
        interpreterTraceSha256: interpreterEvents.rawSha256,
        aotTraceSha256: aotEvents.rawSha256,
        compileManifestSha256: manifestEntries.rawSha256,
      },
    },
    trace: {
      interpreter: { schema: 2, eventCount: interpreterEvents.length },
      aot: { schema: 2, eventCount: aotEvents.length },
    },
    sites,
  };
  const temporaryPath = join(dirname(output), `.lnako-dispatch-evidence-${process.pid}-${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, `${JSON.stringify(evidence, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
    try {
      await link(temporaryPath, output);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error(`dispatch証拠の出力先は既に存在します: ${output}`);
      throw new Error("dispatch証拠を原子的に出力できません", { cause: error });
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function gitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (commit.status !== 0) throw new Error("lnakoのcommitを取得できません");
  const commitHash = commit.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(commitHash)) throw new Error("lnakoのcommit形式が不正です");
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (status.status !== 0) throw new Error("lnakoのdirty状態を取得できません");
  return { commit: commitHash, dirty: status.stdout.length > 0 };
}

async function readOracleIdentity() {
  const directory = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
  const baseline = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8")).nadesiko3;
  const cliPath = resolve(directory, "src/cnako3.mjs");
  let markerBytes;
  let marker;
  try {
    markerBytes = await readFile(resolve(directory, ".lnako-oracle.json"));
    marker = JSON.parse(markerBytes.toString("utf8"));
  } catch {
    throw new Error("公式オラクルの固定情報を取得できません");
  }
  if (marker.tag !== baseline.tag || marker.commit !== baseline.commit || marker.archiveSha256 !== baseline.archive.sha256) {
    throw new Error("公式オラクルが固定baselineと一致しません");
  }
  if (!Number.isSafeInteger(marker.oracleBuild) || marker.oracleBuild < 1) throw new Error("公式オラクルのbuild番号が不正です");
  const expected = baseline.oracleIdentity;
  const actualCliSha256 = sha256(await readFile(cliPath));
  const actualMarkerSha256 = sha256(markerBytes);
  const platform = `${process.platform}-${process.arch}`;
  const expectedTreeSha256 = expected?.treeSha256ByPlatform?.[platform];
  if (expected?.treeHashAlgorithm !== oracleTreeHashAlgorithm || !/^[0-9a-f]{64}$/.test(expectedTreeSha256 ?? "")) {
    throw new Error(`公式オラクルのtree hashが未登録です: ${platform}`);
  }
  const actualTreeSha256 = await oracleTreeHash(directory);
  if (expected?.build !== marker.oracleBuild || expected.cliSha256 !== actualCliSha256 || expected.markerSha256 !== actualMarkerSha256 ||
      marker.treeSha256 !== actualTreeSha256 || marker.treeSha256 !== expectedTreeSha256) {
    throw new Error("公式オラクルの固定buildまたはCLI／marker SHA-256が一致しません");
  }
  return {
    cliPath,
    build: marker.oracleBuild,
    archiveSha256: baseline.archive.sha256,
    cliSha256: actualCliSha256,
    markerSha256: actualMarkerSha256,
    treeHashAlgorithm: oracleTreeHashAlgorithm,
    treeSha256: actualTreeSha256,
  };
}
