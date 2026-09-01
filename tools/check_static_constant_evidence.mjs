import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const oracleRoot = resolve(
  argumentValue("--oracle") ?? process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const evidenceOutput = optionValue("--evidence-output");
const noBuild = process.argv.includes("--no-build");
const literalConstantNames = new Set(["はい", "いいえ", "真", "偽", "オン", "オフ", "NULL"]);
const fixtureId = "native-scalar-system-constants";
const maxBuffer = 16 * 1024 * 1024;

validateArguments();
if (evidenceOutput !== null) await ensureDestinationFree(evidenceOutput);

const [lock, catalog, cases] = await Promise.all([
  readJson(resolve(root, "compat/upstream.lock.json")),
  readJson(resolve(root, "compat/v3.7.24/standard-cnako.json")),
  readJson(resolve(root, "tests/oracle/native-cases.json")),
]);
if (catalog.commandCount !== 527 || !Array.isArray(catalog.commands) || catalog.commands.length !== 527) {
  throw new Error("標準cnakoカタログが527 entryではありません");
}
const fixture = cases.find((candidate) => candidate.id === fixtureId);
if (fixture === undefined) throw new Error(`静的定数fixtureがありません: ${fixtureId}`);
if (!Array.isArray(fixture.commands) || fixture.commands.length === 0 || new Set(fixture.commands).size !== fixture.commands.length) {
  throw new Error("静的定数fixtureのcommandsが不正です");
}
const catalogByName = new Map();
for (const command of catalog.commands) {
  const commands = catalogByName.get(command.name) ?? [];
  commands.push(command);
  catalogByName.set(command.name, commands);
}
for (const name of fixture.commands) {
  const commands = catalogByName.get(name) ?? [];
  if (commands.length !== 1 || commands[0].plugin !== "plugin_system" || commands[0].type !== "定数") {
    throw new Error(`静的定数fixtureのcatalog identityが一意に解決できません: ${name}`);
  }
}
const globalReadNames = fixture.commands.filter((name) => !literalConstantNames.has(name));
const literalNames = fixture.commands.filter((name) => literalConstantNames.has(name));
if (globalReadNames.length !== 17 || literalNames.length !== 7) {
  throw new Error(`静的定数fixtureのliteral/global分類が想定外です: ${literalNames.length}/${globalReadNames.length}`);
}

if (!noBuild) buildLnako();
await access(compiler);
const temporary = await mkdtemp(join(tmpdir(), "lnako-static-constant-"));
try {
  const sourcePath = resolve(temporary, "scalar-constants.nako3");
  const generatedJavaScript = resolve(temporary, "scalar-constants.mjs");
  const native = resolve(temporary, process.platform === "win32" ? "scalar-constants.exe" : "scalar-constants");
  const interpreterTrace = resolve(temporary, "interpreter-global.jsonl");
  const aotTrace = resolve(temporary, "aot-global.jsonl");
  const globalManifest = resolve(temporary, "global-manifest.jsonl");
  await writeFile(sourcePath, fixture.source, "utf8");

  const baseEnvironment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    LNAKO_TEST_NOW_MS: "1735689845678",
    LNAKO_TEST_MONOTONIC_MS: "123.5",
    LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
    LNAKO_LLVM_TRACE: "1",
  };
  const options = { cwd: temporary, env: baseEnvironment };
  const hostArguments = ["--import", pathToFileURL(fixedHost).href];
  const officialSource = await runProcess(process.execPath, [...hostArguments, officialCli, sourcePath], options);
  const officialCompile = await runProcess(
    process.execPath,
    [...hostArguments, officialCli, "--compile", "--silent", "--output", generatedJavaScript, sourcePath],
    options,
  );
  if (officialCompile.status !== 0) throw new Error(`公式JavaScript生成に失敗しました: ${officialCompile.stderr}`);
  const officialGenerated = await runProcess(process.execPath, [...hostArguments, generatedJavaScript], options);
  const interpreted = await runProcess(
    compiler,
    ["run", sourcePath],
    { cwd: temporary, env: { ...baseEnvironment, LNAKO_GLOBAL_TRACE: interpreterTrace } },
  );
  const nativeCompile = await runProcess(
    compiler,
    ["build", sourcePath, "-o", native, "-O0"],
    { cwd: temporary, env: { ...baseEnvironment, LNAKO_GLOBAL_MANIFEST: globalManifest } },
  );
  const nativeResult = nativeCompile.status === 0
    ? await runProcess(compilerPath(native), [], { cwd: temporary, env: { ...baseEnvironment, LNAKO_GLOBAL_TRACE: aotTrace } })
    : nativeCompile;

  const results = {
    officialSource,
    officialGenerated,
    lnakoRun: interpreted,
    lnakoNativeO0: nativeResult,
  };
  assertEquivalentResults(results);
  const manifest = await readGlobalManifest(globalManifest, sourcePath, globalReadNames);
  const interpreterEvents = await readGlobalTrace(interpreterTrace, "interpreter", manifest);
  const aotEvents = await readGlobalTrace(aotTrace, "aot", manifest);
  const manifestBySiteId = new Map(manifest.entries.map((entry) => [entry.siteId, entry]));
  const interpreterBySiteId = new Map(interpreterEvents.map((event) => [event.siteId, event]));
  const aotBySiteId = new Map(aotEvents.map((event) => [event.siteId, event]));
  const entries = manifest.entries.map((entry) => {
    const command = catalogByName.get(entry.name)?.[0];
    const interpreterEvent = interpreterBySiteId.get(entry.siteId);
    const aotEvent = aotBySiteId.get(entry.siteId);
    if (command === undefined || interpreterEvent === undefined || aotEvent === undefined) {
      throw new Error(`静的定数の実行siteが不足しています: ${entry.name}/${entry.siteId}`);
    }
    if (interpreterEvent.name !== entry.name || interpreterEvent.found !== true || aotEvent.success !== true) {
      throw new Error(`静的定数のruntime証拠が不正です: ${entry.name}/${entry.siteId}`);
    }
    return {
      catalogId: command.id,
      name: command.name,
      plugin: command.plugin,
      siteId: entry.siteId,
      runtime: {
        interpreter: { success: true, count: 1 },
        aot: { success: true, count: 1 },
      },
      officialEquivalent: true,
    };
  });
  if (new Set(entries.map((entry) => entry.catalogId)).size !== entries.length) throw new Error("静的定数のcatalog IDが重複しています");

  const git = readGitState();
  const evidence = {
    schema: "lnako.static-constant-evidence.v1",
    generator: "tools/check_static_constant_evidence.mjs",
    baseline: { tag: lock.nadesiko3.tag, commit: lock.nadesiko3.commit },
    fixture: {
      id: fixture.id,
      file: "native-cases.json",
      sourceSha256: sha256(fixture.source),
      globalReadNames,
      literalNames,
    },
    officialComparison: {
      oracle: "official-source",
      routes: Object.keys(results),
      equivalent: true,
      results: Object.fromEntries(Object.entries(results).map(([route, result]) => [route, {
        status: result.status,
        signal: result.signal,
        stdoutSha256: sha256(normalizeLineEndings(result.stdout)),
        stderrSha256: sha256(normalizeLineEndings(result.stderr)),
      }])),
    },
    attestation: null,
    provenance: {
      environment: { platform: process.platform, arch: process.arch, node: process.version },
      oracle: await readOracleIdentity(oracleRoot, officialCli, lock.nadesiko3),
      lnako: { binarySha256: sha256(await readFile(compiler)), commit: git.commit, dirty: git.dirty },
      raw: {
        interpreterTraceSha256: sha256(await readFile(interpreterTrace)),
        aotTraceSha256: sha256(await readFile(aotTrace)),
        globalManifestSha256: sha256(await readFile(globalManifest)),
      },
    },
    trace: {
      interpreter: { schema: 1, eventCount: interpreterEvents.length },
      aot: { schema: 1, eventCount: aotEvents.length },
    },
    entries,
  };
  validateEvidence(evidence, lock, fixture, globalReadNames, literalNames, manifestBySiteId);
  if (evidenceOutput !== null) await writeFile(evidenceOutput, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  console.log(`静的定数のInterpreter/AOT global-read証拠: ${entries.length}件成功（literal lowering ${literalNames.length}件はglobal-read対象外）`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function validateArguments() {
  const allowed = new Set(["--no-build", "--oracle", "--evidence-output"]);
  for (let index = 2; index < process.argv.length; index += 1) {
    const argument = process.argv[index];
    if (allowed.has(argument)) {
      if (argument === "--no-build") continue;
      if (process.argv[index + 1] === undefined || process.argv[index + 1].startsWith("--")) throw new Error(`${argument}の値がありません`);
      index += 1;
      continue;
    }
    if (argument.startsWith("--oracle=") || argument.startsWith("--evidence-output=")) continue;
    throw new Error("usage: node tools/check_static_constant_evidence.mjs [--no-build] [--oracle /absolute/path] [--evidence-output /absolute/path]");
  }
}

function argumentValue(name) {
  const inline = process.argv.find((argument) => argument.startsWith(`${name}=`));
  if (inline !== undefined) return inline.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] ?? null : null;
}

function optionValue(name) {
  const value = argumentValue(name);
  if (value === null) return null;
  if (!isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
  return resolve(value);
}

async function ensureDestinationFree(path) {
  try {
    await access(path);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw new Error(`静的定数証拠の出力先を確認できません: ${path}`);
  }
  throw new Error(`静的定数証拠の出力先は既に存在します: ${path}`);
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function compilerPath(path) {
  return path;
}

function runProcess(command, arguments_, options) {
  return new Promise((resolveProcess) => {
    execFile(command, arguments_, { ...options, maxBuffer, windowsHide: true }, (error, stdout, stderr) => {
      resolveProcess({
        status: error === null ? 0 : typeof error.code === "number" ? error.code : null,
        signal: error?.signal ?? null,
        stdout: stdout ?? "",
        stderr: stderr || (error?.message ?? ""),
      });
    });
  });
}

function assertEquivalentResults(results) {
  const expected = normalizeResult(results.officialSource);
  for (const [route, result] of Object.entries(results)) {
    const actual = normalizeResult(result);
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(`静的定数の公式差分に失敗しました: ${route}: ${JSON.stringify(actual)}`);
    }
  }
}

function normalizeResult(result) {
  return {
    stdout: normalizeLineEndings(result.stdout),
    stderr: normalizeLineEndings(result.stderr),
    status: result.status,
    signal: result.signal,
  };
}

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

async function readGlobalManifest(path, sourcePath, expectedNames) {
  const lines = await readJsonLines(path, "AOT global manifest");
  if (lines.length < 2) throw new Error("AOT global manifestが完了レコードを含みません");
  const header = lines[0];
  assertKeys(header, ["schema", "phase", "sourcePath", "siteIdEncoding"], "global manifest header");
  if (header.schema !== "lnako.aot.global-manifest.v1" || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16") {
    throw new Error("AOT global manifestのheaderが不正です");
  }
  const complete = lines.at(-1);
  assertKeys(complete, ["schema", "phase", "kind", "complete", "entryCount"], "global manifest complete");
  if (complete.schema !== header.schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || !Number.isSafeInteger(complete.entryCount)) {
    throw new Error("AOT global manifestの完了レコードが不正です");
  }
  const entries = lines.slice(1, -1);
  if (complete.entryCount !== entries.length || entries.length !== expectedNames.length) throw new Error("AOT global manifestのentryCountが不一致です");
  const expected = new Set(expectedNames);
  const siteIds = new Set();
  for (const entry of entries) {
    assertKeys(entry, ["schema", "phase", "kind", "name", "siteId", "function", "source"], "global manifest entry");
    assertKeys(entry.source, ["line", "column", "sourceStart", "sourceEnd"], "global manifest entry source");
    if (entry.schema !== header.schema || entry.phase !== "pre-opt" || entry.kind !== "global-load" || !expected.has(entry.name)) throw new Error(`AOT global manifestのnameが不正です: ${entry.name}`);
    if (!/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) throw new Error(`AOT global manifestのsiteIdが不正または重複しています: ${entry.siteId}`);
    if (!Number.isSafeInteger(entry.source.line) || entry.source.line < 1 || !Number.isSafeInteger(entry.source.column) || entry.source.column < 1 || !Number.isSafeInteger(entry.source.sourceStart) || !Number.isSafeInteger(entry.source.sourceEnd) || entry.source.sourceStart < 0 || entry.source.sourceEnd < entry.source.sourceStart) {
      throw new Error(`AOT global manifestのsource位置が不正です: ${entry.name}`);
    }
    siteIds.add(entry.siteId);
  }
  if (new Set(entries.map((entry) => entry.name)).size !== expectedNames.length) throw new Error("AOT global manifestのnameが不足または重複しています");
  return { entries: entries.map((entry) => ({ ...entry })) };
}

async function readGlobalTrace(path, engine, manifest) {
  const lines = await readJsonLines(path, `${engine} global trace`);
  if (lines.length < 2) throw new Error(`${engine} global traceが空です`);
  const end = lines.at(-1);
  assertKeys(end, ["schema", "engine", "phase", "seq", "dropped"], `${engine} global trace end`);
  if (end.schema !== 1 || end.engine !== engine || end.phase !== "trace-end" || !Number.isSafeInteger(end.seq) || end.dropped !== 0) throw new Error(`${engine} global traceの終了レコードが不正です`);
  const events = lines.slice(0, -1);
  const siteIds = new Set();
  for (const event of events) {
    const allowed = engine === "interpreter"
      ? ["schema", "engine", "phase", "seq", "siteId", "name", "found"]
      : ["schema", "engine", "phase", "seq", "siteId", "success"];
    assertKeys(event, allowed, `${engine} global trace event`);
    if (event.schema !== 1 || event.engine !== engine || event.phase !== "global-read" || !Number.isSafeInteger(event.seq) || !/^0x[0-9a-f]{16}$/.test(event.siteId) || siteIds.has(event.siteId)) {
      throw new Error(`${engine} global trace eventが不正です`);
    }
    if (!manifest.entries.some((entry) => entry.siteId === event.siteId)) throw new Error(`${engine} global traceがmanifest外のsiteを含みます: ${event.siteId}`);
    if (engine === "interpreter" && (typeof event.name !== "string" || event.found !== true)) throw new Error("Interpreter global traceのname/foundが不正です");
    if (engine === "aot" && event.success !== true) throw new Error("AOT global traceのsuccessが不正です");
    siteIds.add(event.siteId);
  }
  if (siteIds.size !== manifest.entries.length || end.seq !== events.length) throw new Error(`${engine} global traceの件数がmanifestと一致しません`);
  return events;
}

async function readJsonLines(path, label) {
  const text = await readFile(path, "utf8");
  const lines = text.trimEnd().split(/\r?\n/).filter((line) => line.length > 0);
  return lines.map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new Error(`${label}のJSONLが不正です（${index + 1}行目）`);
    }
  });
}

function assertKeys(value, allowedKeys, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label}がobjectではありません`);
  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new Error(`${label}に未知fieldがあります: ${key}`);
}

function validateEvidence(evidence, lock, fixture, globalReadNames, literalNames, manifestBySiteId) {
  assertKeys(evidence, ["schema", "generator", "baseline", "fixture", "officialComparison", "attestation", "provenance", "trace", "entries"], "static constant evidence");
  if (evidence.schema !== "lnako.static-constant-evidence.v1" || evidence.generator !== "tools/check_static_constant_evidence.mjs" || evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) throw new Error("静的定数証拠のidentityが不正です");
  assertKeys(evidence.fixture, ["id", "file", "sourceSha256", "globalReadNames", "literalNames"], "static constant evidence fixture");
  if (evidence.fixture.id !== fixture.id || evidence.fixture.file !== "native-cases.json" || evidence.fixture.sourceSha256 !== sha256(fixture.source) || JSON.stringify(evidence.fixture.globalReadNames) !== JSON.stringify(globalReadNames) || JSON.stringify(evidence.fixture.literalNames) !== JSON.stringify(literalNames)) throw new Error("静的定数証拠のfixtureが不一致です");
  assertKeys(evidence.officialComparison, ["oracle", "routes", "equivalent", "results"], "static constant comparison");
  const routes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  if (evidence.officialComparison.oracle !== "official-source" || JSON.stringify(evidence.officialComparison.routes) !== JSON.stringify(routes) || evidence.officialComparison.equivalent !== true) throw new Error("静的定数証拠の公式比較が不完全です");
  assertKeys(evidence.officialComparison.results, routes, "static constant comparison results");
  const reference = evidence.officialComparison.results.officialSource;
  for (const route of routes) {
    assertKeys(evidence.officialComparison.results[route], ["status", "signal", "stdoutSha256", "stderrSha256"], `static constant result ${route}`);
    const result = evidence.officialComparison.results[route];
    if (result.status !== 0 || result.signal !== null || result.stdoutSha256 !== reference.stdoutSha256 || result.stderrSha256 !== reference.stderrSha256 || !/^[0-9a-f]{64}$/.test(result.stdoutSha256) || !/^[0-9a-f]{64}$/.test(result.stderrSha256)) throw new Error(`静的定数証拠の公式比較結果が不正です: ${route}`);
  }
  if (evidence.attestation !== null) throw new Error("静的定数証拠に未対応のattestationがあります");
  assertKeys(evidence.trace, ["interpreter", "aot"], "static constant trace");
  for (const engine of ["interpreter", "aot"]) {
    assertKeys(evidence.trace[engine], ["schema", "eventCount"], `static constant trace ${engine}`);
    if (evidence.trace[engine].schema !== 1 || evidence.trace[engine].eventCount !== globalReadNames.length) throw new Error(`静的定数証拠のtrace件数が不正です: ${engine}`);
  }
  if (!Array.isArray(evidence.entries) || evidence.entries.length !== globalReadNames.length) throw new Error("静的定数証拠のentry数が不正です");
  const names = new Set();
  for (const entry of evidence.entries) {
    assertKeys(entry, ["catalogId", "name", "plugin", "siteId", "runtime", "officialEquivalent"], "static constant evidence entry");
    assertKeys(entry.runtime, ["interpreter", "aot"], "static constant evidence runtime");
    assertKeys(entry.runtime.interpreter, ["success", "count"], "static constant evidence interpreter");
    assertKeys(entry.runtime.aot, ["success", "count"], "static constant evidence aot");
    const manifest = manifestBySiteId.get(entry.siteId);
    if (manifest === undefined || manifest.name !== entry.name || entry.plugin !== "plugin_system" || names.has(entry.name) || !/^command-\d{4}$/.test(entry.catalogId) || entry.officialEquivalent !== true || entry.runtime.interpreter.success !== true || entry.runtime.interpreter.count !== 1 || entry.runtime.aot.success !== true || entry.runtime.aot.count !== 1) throw new Error(`静的定数証拠entryが不正です: ${entry.name}`);
    names.add(entry.name);
  }
  if (names.size !== globalReadNames.length || [...names].some((name) => !globalReadNames.includes(name))) throw new Error("静的定数証拠のname集合が不一致です");
}

function readGitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (commit.status !== 0 || status.status !== 0) throw new Error("lnakoのGit状態を取得できません");
  return { commit: commit.stdout.trim(), dirty: status.stdout.length > 0 };
}

async function readOracleIdentity(directory, cli, baseline) {
  const markerBytes = await readFile(resolve(directory, ".lnako-oracle.json"));
  const marker = JSON.parse(markerBytes.toString("utf8"));
  if (marker.tag !== baseline.tag || marker.commit !== baseline.commit || marker.archiveSha256 !== baseline.archive.sha256) throw new Error("公式オラクルが固定baselineと一致しません");
  const actualCliSha256 = sha256(await readFile(cli));
  const actualMarkerSha256 = sha256(markerBytes);
  const platform = `${process.platform}-${process.arch}`;
  const expected = baseline.oracleIdentity;
  const actualTreeSha256 = await oracleTreeHash(directory);
  if (!Number.isSafeInteger(marker.oracleBuild) || marker.oracleBuild < 1 || expected.treeHashAlgorithm !== oracleTreeHashAlgorithm || marker.oracleBuild !== expected.build || expected.cliSha256 !== actualCliSha256 || expected.markerSha256 !== actualMarkerSha256 || marker.treeSha256 !== actualTreeSha256 || marker.treeSha256 !== expected.treeSha256ByPlatform?.[platform]) throw new Error("公式オラクルの固定情報が一致しません");
  return {
    build: marker.oracleBuild,
    archiveSha256: baseline.archive.sha256,
    cliSha256: actualCliSha256,
    markerSha256: actualMarkerSha256,
    treeHashAlgorithm: oracleTreeHashAlgorithm,
    treeSha256: actualTreeSha256,
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
