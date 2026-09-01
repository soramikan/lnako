import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
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
const fixtureId = argumentValue("--fixture") ?? "native-scalar-system-constants";
const staticConstantFixtureDefinitions = {
  "native-scalar-system-constants": {
    globalReadCount: 17,
    literalNames: new Set(["はい", "いいえ", "真", "偽", "オン", "オフ", "NULL"]),
    plugin: "plugin_system",
  },
  "native-string-system-constants": {
    globalReadCount: 24,
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  "native-array-system-constants": {
    globalReadCount: 2,
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  "native-datetime-era-data": {
    catalogIds: new Map([["元号データ", "command-0227"]]),
    globalReadCount: 1,
    globalTraceCount: 3,
    manifestGlobalReadNames: ["元号データ", "元号データ", "元号データ"],
    manifestExtraGlobalReadNames: ["scalar-constants__A"],
    literalNames: new Set(),
    plugin: "plugin_system",
  },
  "native-node-archive-constant": {
    globalReadCount: 1,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  "native-node-command-line-constants": {
    globalReadCount: 3,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  "native-node-mother-path": {
    constantNames: new Set(["母艦パス"]),
    globalReadCount: 1,
    literalNames: new Set(),
    plugin: "plugin_node",
  },
  "native-system-promise-reject": {
    constantNames: new Set(["そ"]),
    globalReadCount: 1,
    manifestExtraGlobalReadNames: ["対象", "scalar-constants__F"],
    literalNames: new Set(),
    plugin: "plugin_promise",
  },
  "native-caniuse-agents": {
    globalReadCount: 1,
    globalTraceCount: 3,
    literalNames: new Set(),
    manifestGlobalReadNames: ["ブラウザ名変換表", "ブラウザ名変換表", "ブラウザ名変換表"],
    manifestExtraGlobalReadNames: ["scalar-constants__A", "scalar-constants__B"],
    plugin: "plugin_caniuse",
    sourceReplacements: {
      "${PLUGIN_CANIUSE}": (temporary) => relative(temporary, resolve(oracleRoot, "src/plugin_caniuse.mjs")).replaceAll("\\", "/"),
    },
  },
  "native-node-http-initial-constants": {
    globalReadCount: 5,
    literalNames: new Set(),
    commandPlugins: {
      "AJAXオプション": "plugin_node",
      "HTTPメソッド": "plugin_httpserver",
      "GETデータ": "plugin_httpserver",
      "POSTデータ": "plugin_httpserver",
      "FILESデータ": "plugin_httpserver",
    },
  },
};
const fixtureDefinition = staticConstantFixtureDefinitions[fixtureId];
if (fixtureDefinition === undefined) throw new Error(`静的定数fixtureの定義がありません: ${fixtureId}`);
const literalConstantNames = fixtureDefinition.literalNames;

function expectedPluginFor(name) {
  return fixtureDefinition.commandPlugins?.[name] ?? fixtureDefinition.plugin;
}

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
const staticConstantNames = fixtureDefinition.constantNames === undefined ? fixture.commands : [...fixtureDefinition.constantNames];
if (staticConstantNames.length === 0 || new Set(staticConstantNames).size !== staticConstantNames.length || staticConstantNames.some((name) => !fixture.commands.includes(name))) {
  throw new Error("静的定数fixtureのconstantNamesが不正です");
}
const catalogByName = new Map();
for (const command of catalog.commands) {
  const commands = catalogByName.get(command.name) ?? [];
  commands.push(command);
  catalogByName.set(command.name, commands);
}
const catalogById = new Map(catalog.commands.map((command) => [command.id, command]));
const configuredCatalogIds = fixtureDefinition.catalogIds ?? new Map();
for (const [name, id] of configuredCatalogIds) {
  const command = catalogById.get(id);
  if (!staticConstantNames.includes(name) || command?.name !== name) {
    throw new Error(`静的定数fixtureのcatalog ID指定が不正です: ${name}/${id}`);
  }
}
function catalogCommandFor(name) {
  const commands = catalogByName.get(name) ?? [];
  const expectedId = configuredCatalogIds.get(name);
  return expectedId === undefined ? (commands.length === 1 ? commands[0] : undefined) : catalogById.get(expectedId);
}
for (const name of staticConstantNames) {
  const commands = catalogByName.get(name) ?? [];
  const command = catalogCommandFor(name);
  const identityIsUnambiguous = configuredCatalogIds.has(name) ? command?.id === configuredCatalogIds.get(name) : commands.length === 1;
  if (!identityIsUnambiguous || command?.name !== name || command.plugin !== expectedPluginFor(name) || command.type !== "定数") {
    throw new Error(`静的定数fixtureのcatalog identityが一意に解決できません: ${name}`);
  }
}
const globalReadNames = staticConstantNames.filter((name) => !literalConstantNames.has(name));
const literalNames = staticConstantNames.filter((name) => literalConstantNames.has(name));
if (globalReadNames.length !== fixtureDefinition.globalReadCount || literalNames.length !== fixtureDefinition.literalNames.size) {
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
  const interpreterLiteralTrace = resolve(temporary, "interpreter-literal.jsonl");
  const aotLiteralTrace = resolve(temporary, "aot-literal.jsonl");
  const literalManifest = resolve(temporary, "literal-manifest.jsonl");
  await writeFile(sourcePath, prepareFixtureSource(fixture.source, temporary), "utf8");

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
    {
      cwd: temporary,
      env: {
        ...baseEnvironment,
        LNAKO_GLOBAL_TRACE: interpreterTrace,
        LNAKO_LITERAL_TRACE: interpreterLiteralTrace,
      },
    },
  );
  const nativeCompile = await runProcess(
    compiler,
    ["build", sourcePath, "-o", native, "-O0"],
    {
      cwd: temporary,
      env: {
        ...baseEnvironment,
        LNAKO_GLOBAL_MANIFEST: globalManifest,
        LNAKO_LITERAL_MANIFEST: literalManifest,
      },
    },
  );
  const nativeResult = nativeCompile.status === 0
    ? await runProcess(compilerPath(native), [], {
      cwd: temporary,
      env: {
        ...baseEnvironment,
        LNAKO_GLOBAL_TRACE: aotTrace,
        LNAKO_LITERAL_TRACE: aotLiteralTrace,
      },
    })
    : nativeCompile;

  const results = {
    officialSource,
    officialGenerated,
    lnakoRun: interpreted,
    lnakoNativeO0: nativeResult,
  };
  const oracleSelection = fixture.oracle ?? "official-source";
  const oracleRoute = oracleSelection === "official-generated" ? "officialGenerated" : "officialSource";
  assertEquivalentResults(results, oracleRoute);
  const globalManifestData = await readGlobalManifest(
    globalManifest,
    sourcePath,
    fixtureDefinition.manifestGlobalReadNames ?? globalReadNames,
    fixtureDefinition.manifestExtraGlobalReadNames ?? [],
  );
  const literalManifestData = await readLiteralManifest(literalManifest, sourcePath, literalNames);
  const extraGlobalReadNames = fixtureDefinition.manifestExtraGlobalReadNames ?? [];
  const interpreterGlobalEvents = (await readGlobalTrace(interpreterTrace, "interpreter", globalManifestData, extraGlobalReadNames)).filter((event) => globalReadNames.includes(event.name));
  const aotGlobalEvents = (await readGlobalTrace(aotTrace, "aot", globalManifestData, extraGlobalReadNames)).filter((event) => globalManifestData.entries.some((entry) => entry.siteId === event.siteId && globalReadNames.includes(entry.name)));
  const interpreterLiteralEvents = await readLiteralTrace(interpreterLiteralTrace, "interpreter", literalManifestData);
  const aotLiteralEvents = await readLiteralTrace(aotLiteralTrace, "aot", literalManifestData);
  const manifestByKey = new Map([
    ...globalManifestData.entries.map((entry) => [`global-read:${entry.siteId}`, entry]),
    ...literalManifestData.entries.map((entry) => [`literal:${entry.siteId}`, entry]),
  ]);
  const interpreterGlobalBySiteId = new Map(interpreterGlobalEvents.map((event) => [event.siteId, event]));
  const aotGlobalBySiteId = new Map(aotGlobalEvents.map((event) => [event.siteId, event]));
  const interpreterLiteralBySiteId = new Map(interpreterLiteralEvents.map((event) => [event.siteId, event]));
  const aotLiteralBySiteId = new Map(aotLiteralEvents.map((event) => [event.siteId, event]));
  const manifestByName = new Map([
    ...globalManifestData.entries.map((entry) => [`global-read:${entry.name}`, entry]),
    ...literalManifestData.entries.map((entry) => [`literal:${entry.name}`, entry]),
  ]);
  const entries = staticConstantNames.map((name) => {
    const kind = literalConstantNames.has(name) ? "literal" : "global-read";
    const manifest = manifestByName.get(`${kind}:${name}`);
    const command = catalogCommandFor(name);
    const interpreterEvent = kind === "literal"
      ? interpreterLiteralBySiteId.get(manifest?.siteId)
      : interpreterGlobalBySiteId.get(manifest?.siteId);
    const aotEvent = kind === "literal"
      ? aotLiteralBySiteId.get(manifest?.siteId)
      : aotGlobalBySiteId.get(manifest?.siteId);
    if (command === undefined || manifest === undefined || interpreterEvent === undefined || aotEvent === undefined) {
      throw new Error(`静的定数の実行siteが不足しています: ${name}/${manifest?.siteId ?? "missing"}`);
    }
    if (interpreterEvent.name !== name || (kind === "global-read" && interpreterEvent.found !== true) || aotEvent.success !== true) {
      throw new Error(`静的定数のruntime証拠が不正です: ${name}/${manifest.siteId}`);
    }
    return {
      catalogId: command.id,
      name: command.name,
      plugin: command.plugin,
      kind,
      siteId: manifest.siteId,
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
    schema: "lnako.static-constant-evidence.v2",
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
      oracle: oracleSelection,
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
        literalInterpreterTraceSha256: sha256(await readFile(interpreterLiteralTrace)),
        literalAotTraceSha256: sha256(await readFile(aotLiteralTrace)),
        literalManifestSha256: sha256(await readFile(literalManifest)),
      },
    },
    trace: {
      global: {
        interpreter: { schema: 1, eventCount: interpreterGlobalEvents.length },
        aot: { schema: 1, eventCount: aotGlobalEvents.length },
      },
      literal: {
        interpreter: { schema: 1, eventCount: interpreterLiteralEvents.length },
        aot: { schema: 1, eventCount: aotLiteralEvents.length },
      },
    },
    entries,
  };
  const expectedCatalogIds = new Map(staticConstantNames.map((name) => [name, catalogCommandFor(name).id]));
  validateEvidence(evidence, lock, fixture, globalReadNames, literalNames, manifestByKey, interpreterGlobalEvents.length, expectedCatalogIds);
  if (evidenceOutput !== null) await writeFile(evidenceOutput, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  console.log(`静的定数のInterpreter/AOT証拠: global read ${globalReadNames.length}件 + literal ${literalNames.length}件 = ${entries.length}件成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function validateArguments() {
  const allowed = new Set(["--no-build", "--oracle", "--evidence-output", "--fixture"]);
  for (let index = 2; index < process.argv.length; index += 1) {
    const argument = process.argv[index];
    if (allowed.has(argument)) {
      if (argument === "--no-build") continue;
      if (process.argv[index + 1] === undefined || process.argv[index + 1].startsWith("--")) throw new Error(`${argument}の値がありません`);
      index += 1;
      continue;
    }
    if (argument.startsWith("--oracle=") || argument.startsWith("--evidence-output=") || argument.startsWith("--fixture=")) continue;
    throw new Error("usage: node tools/check_static_constant_evidence.mjs [--no-build] [--fixture fixture-id] [--oracle /absolute/path] [--evidence-output /absolute/path]");
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

function prepareFixtureSource(source, temporary) {
  let prepared = source;
  for (const [placeholder, replacement] of Object.entries(fixtureDefinition.sourceReplacements ?? {})) {
    prepared = prepared.replaceAll(placeholder, typeof replacement === "function" ? replacement(temporary) : replacement);
  }
  return prepared;
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

function assertEquivalentResults(results, oracleRoute) {
  const expected = normalizeResult(results[oracleRoute]);
  for (const [route, result] of Object.entries(results)) {
    if (route !== oracleRoute && ((oracleRoute === "officialSource" && route === "officialGenerated") || (oracleRoute === "officialGenerated" && route === "officialSource"))) continue;
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

async function readGlobalManifest(path, sourcePath, expectedNames, extraNames) {
  return readStaticManifest(path, sourcePath, expectedNames, "lnako.aot.global-manifest.v1", "global-load", "AOT global manifest", extraNames);
}

async function readLiteralManifest(path, sourcePath, expectedNames) {
  return readStaticManifest(path, sourcePath, expectedNames, "lnako.aot.literal-manifest.v1", "literal-constant", "AOT literal manifest");
}

async function readStaticManifest(path, sourcePath, expectedNames, schema, kind, label, extraNames = []) {
  const lines = await readJsonLines(path, label);
  if (lines.length < 2) throw new Error("AOT global manifestが完了レコードを含みません");
  const header = lines[0];
  assertKeys(header, ["schema", "phase", "sourcePath", "siteIdEncoding"], `${label} header`);
  if (header.schema !== schema || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16") {
    throw new Error(`${label}のheaderが不正です`);
  }
  const complete = lines.at(-1);
  assertKeys(complete, ["schema", "phase", "kind", "complete", "entryCount"], `${label} complete`);
  if (complete.schema !== header.schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || !Number.isSafeInteger(complete.entryCount)) {
    throw new Error(`${label}の完了レコードが不正です`);
  }
  const entries = lines.slice(1, -1);
  if (complete.entryCount !== entries.length || entries.length !== expectedNames.length + extraNames.length) throw new Error(`${label}のentryCountが不一致です`);
  const expected = new Set([...expectedNames, ...extraNames]);
  const siteIds = new Set();
  const nameCounts = new Map();
  for (const entry of entries) {
    assertKeys(entry, ["schema", "phase", "kind", "name", "siteId", "function", "source"], `${label} entry`);
    assertKeys(entry.source, ["line", "column", "sourceStart", "sourceEnd"], `${label} entry source`);
    if (entry.schema !== header.schema || entry.phase !== "pre-opt" || entry.kind !== kind || !expected.has(entry.name)) throw new Error(`${label}のnameが不正です: ${entry.name}`);
    if (!/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) throw new Error(`${label}のsiteIdが不正または重複しています: ${entry.siteId}`);
    if (!Number.isSafeInteger(entry.source.line) || entry.source.line < 1 || !Number.isSafeInteger(entry.source.column) || entry.source.column < 1 || !Number.isSafeInteger(entry.source.sourceStart) || !Number.isSafeInteger(entry.source.sourceEnd) || entry.source.sourceStart < 0 || entry.source.sourceEnd < entry.source.sourceStart) {
      throw new Error(`${label}のsource位置が不正です: ${entry.name}`);
    }
    siteIds.add(entry.siteId);
    nameCounts.set(entry.name, (nameCounts.get(entry.name) ?? 0) + 1);
  }
  const expectedCounts = new Map();
  for (const name of [...expectedNames, ...extraNames]) expectedCounts.set(name, (expectedCounts.get(name) ?? 0) + 1);
  if (entries.length !== expectedNames.length + extraNames.length || nameCounts.size !== expectedCounts.size || [...expectedCounts].some(([name, count]) => nameCounts.get(name) !== count)) throw new Error(`${label}のname集合または件数が不一致です`);
  return { entries: entries.map((entry) => ({ ...entry })) };
}

async function readGlobalTrace(path, engine, manifest, extraNames) {
  return readStaticTrace(path, engine, manifest, "global-read", "global trace", extraNames);
}

async function readLiteralTrace(path, engine, manifest) {
  return readStaticTrace(path, engine, manifest, "literal", "literal trace");
}

async function readStaticTrace(path, engine, manifest, phase, label, extraNames = []) {
  const lines = await readJsonLines(path, `${engine} ${label}`);
  if (lines.length < 1) throw new Error(`${engine} ${label}が空です`);
  const end = lines.at(-1);
  assertKeys(end, ["schema", "engine", "phase", "seq", "dropped"], `${engine} ${label} end`);
  if (end.schema !== 1 || end.engine !== engine || end.phase !== "trace-end" || !Number.isSafeInteger(end.seq) || end.dropped !== 0) throw new Error(`${engine} ${label}の終了レコードが不正です`);
  const events = lines.slice(0, -1);
  const siteIds = new Set();
  for (const [index, event] of events.entries()) {
    const allowed = engine === "interpreter"
      ? ["schema", "engine", "phase", "seq", "siteId", "name", ...(phase === "global-read" ? ["found"] : [])]
      : ["schema", "engine", "phase", "seq", "siteId", "success"];
    assertKeys(event, allowed, `${engine} ${label} event`);
    if (event.schema !== 1 || event.engine !== engine || event.phase !== phase || event.seq !== index || !/^0x[0-9a-f]{16}$/.test(event.siteId) || siteIds.has(event.siteId)) {
      throw new Error(`${engine} ${label} eventが不正です`);
    }
    const manifestEntry = manifest.entries.find((entry) => entry.siteId === event.siteId);
    if (manifestEntry === undefined) throw new Error(`${engine} ${label}がmanifest外のsiteを含みます: ${event.siteId}`);
    const nonCatalogExtra = engine === "interpreter" && extraNames.includes(manifestEntry.name) && event.name === "<non-catalog>";
    if (engine === "interpreter" && ((!nonCatalogExtra && event.name !== manifestEntry.name) || (phase === "global-read" && event.found !== true))) throw new Error(`Interpreter ${label}のname/foundが不正です`);
    if (engine === "aot" && event.success !== true) throw new Error(`AOT ${label}のsuccessが不正です`);
    siteIds.add(event.siteId);
  }
  if (siteIds.size !== manifest.entries.length || end.seq !== events.length) throw new Error(`${engine} ${label}の件数がmanifestと一致しません`);
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

function validateEvidence(evidence, lock, fixture, globalReadNames, literalNames, manifestByKey, globalTraceCount, expectedCatalogIds) {
  assertKeys(evidence, ["schema", "generator", "baseline", "fixture", "officialComparison", "attestation", "provenance", "trace", "entries"], "static constant evidence");
  if (evidence.schema !== "lnako.static-constant-evidence.v2" || evidence.generator !== "tools/check_static_constant_evidence.mjs" || evidence.baseline.tag !== lock.nadesiko3.tag || evidence.baseline.commit !== lock.nadesiko3.commit) throw new Error("静的定数証拠のidentityが不正です");
  assertKeys(evidence.fixture, ["id", "file", "sourceSha256", "globalReadNames", "literalNames"], "static constant evidence fixture");
  if (evidence.fixture.id !== fixture.id || evidence.fixture.file !== "native-cases.json" || evidence.fixture.sourceSha256 !== sha256(fixture.source) || JSON.stringify(evidence.fixture.globalReadNames) !== JSON.stringify(globalReadNames) || JSON.stringify(evidence.fixture.literalNames) !== JSON.stringify(literalNames)) throw new Error("静的定数証拠のfixtureが不一致です");
  assertKeys(evidence.officialComparison, ["oracle", "routes", "equivalent", "results"], "static constant comparison");
  const routes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  if (!new Set(["official-source", "official-generated"]).has(evidence.officialComparison.oracle) || JSON.stringify(evidence.officialComparison.routes) !== JSON.stringify(routes) || evidence.officialComparison.equivalent !== true) throw new Error("静的定数証拠の公式比較が不完全です");
  assertKeys(evidence.officialComparison.results, routes, "static constant comparison results");
  const oracleRoute = evidence.officialComparison.oracle === "official-generated" ? "officialGenerated" : "officialSource";
  const reference = evidence.officialComparison.results[oracleRoute];
  for (const route of routes) {
    assertKeys(evidence.officialComparison.results[route], ["status", "signal", "stdoutSha256", "stderrSha256"], `static constant result ${route}`);
    const result = evidence.officialComparison.results[route];
    const compared = route === oracleRoute || route === "lnakoRun" || route === "lnakoNativeO0";
    if (result.status !== 0 || result.signal !== null || (compared && (result.stdoutSha256 !== reference.stdoutSha256 || result.stderrSha256 !== reference.stderrSha256)) || !/^[0-9a-f]{64}$/.test(result.stdoutSha256) || !/^[0-9a-f]{64}$/.test(result.stderrSha256)) throw new Error(`静的定数証拠の公式比較結果が不正です: ${route}`);
  }
  if (evidence.attestation !== null) throw new Error("静的定数証拠に未対応のattestationがあります");
  assertKeys(evidence.trace, ["global", "literal"], "static constant trace");
  for (const [kind, names, expectedEventCount] of [["global", globalReadNames, globalTraceCount], ["literal", literalNames, literalNames.length]]) {
    assertKeys(evidence.trace[kind], ["interpreter", "aot"], `static constant trace ${kind}`);
    for (const engine of ["interpreter", "aot"]) {
      assertKeys(evidence.trace[kind][engine], ["schema", "eventCount"], `static constant trace ${kind}/${engine}`);
      if (evidence.trace[kind][engine].schema !== 1 || evidence.trace[kind][engine].eventCount !== expectedEventCount) throw new Error(`静的定数証拠のtrace件数が不正です: ${kind}/${engine}`);
    }
  }
  if (!Array.isArray(evidence.entries) || evidence.entries.length !== globalReadNames.length + literalNames.length) throw new Error("静的定数証拠のentry数が不正です");
  const names = { global: new Set(), literal: new Set() };
  for (const entry of evidence.entries) {
    assertKeys(entry, ["catalogId", "name", "plugin", "kind", "siteId", "runtime", "officialEquivalent"], "static constant evidence entry");
    assertKeys(entry.runtime, ["interpreter", "aot"], "static constant evidence runtime");
    assertKeys(entry.runtime.interpreter, ["success", "count"], "static constant evidence interpreter");
    assertKeys(entry.runtime.aot, ["success", "count"], "static constant evidence aot");
    const expectedNames = entry.kind === "global-read" ? globalReadNames : entry.kind === "literal" ? literalNames : null;
    const manifest = expectedNames === null ? undefined : manifestByKey.get(`${entry.kind}:${entry.siteId}`);
    const nameSet = entry.kind === "global-read" ? names.global : entry.kind === "literal" ? names.literal : null;
    if (manifest === undefined || manifest.name !== entry.name || entry.plugin !== expectedPluginFor(entry.name) || nameSet === null || nameSet.has(entry.name) || expectedNames === null || !expectedNames.includes(entry.name) || entry.catalogId !== expectedCatalogIds.get(entry.name) || !/^command-\d{4}$/.test(entry.catalogId) || entry.officialEquivalent !== true || entry.runtime.interpreter.success !== true || entry.runtime.interpreter.count !== 1 || entry.runtime.aot.success !== true || entry.runtime.aot.count !== 1) throw new Error(`静的定数証拠entryが不正です: ${entry.name}`);
    nameSet.add(entry.name);
  }
  if (names.global.size !== globalReadNames.length || names.literal.size !== literalNames.length || [...names.global].some((name) => !globalReadNames.includes(name)) || [...names.literal].some((name) => !literalNames.includes(name))) throw new Error("静的定数証拠のname集合が不一致です");
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
