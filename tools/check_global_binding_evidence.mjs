import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { oracleTreeHash } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const compiler = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const oracleRoot = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const profiles = {
  "file-copy": {
    schema: "lnako.global-binding-evidence.v1",
    fixtureId: "native-node-file-copy-default",
    bindings: [
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node" },
    ],
    accesses: [
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node", kind: "global-store", phase: "global-write" },
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node", kind: "global-store", phase: "global-write" },
      { catalogId: "command-0709", name: "ファイルコピーデフォルト動作", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
    ],
  },
  "node-directory": {
    schema: "lnako.global-binding-evidence.v2",
    fixtureId: "native-node-directory-values",
    bindings: [
      { catalogId: "command-0731", name: "デスクトップ", plugin: "plugin_node" },
      { catalogId: "command-0732", name: "マイドキュメント", plugin: "plugin_node" },
      { catalogId: "command-0735", name: "テンポラリフォルダ", plugin: "plugin_node" },
    ],
    accesses: [
      { catalogId: "command-0731", name: "デスクトップ", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0732", name: "マイドキュメント", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
      { catalogId: "command-0735", name: "テンポラリフォルダ", plugin: "plugin_node", kind: "global-load", phase: "global-read" },
    ],
  },
};
const profileName = argumentValue("--profile") ?? "file-copy";
const profile = profiles[profileName];
if (profile === undefined) throw new Error(`未知のglobal binding profileです: ${profileName}`);
const fixtureId = profile.fixtureId;
const expectedAccesses = profile.accesses;
const evidenceOutput = optionValue("--evidence-output");
const noBuild = process.argv.includes("--no-build");
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
if (fixture === undefined || !Array.isArray(fixture.commands) || !profile.bindings.every((binding) => fixture.commands.includes(binding.name)) || fixture.aot === false) {
  throw new Error(`global binding fixtureが不正です: ${fixtureId}`);
}
const commands = profile.bindings.map((binding) => catalog.commands.find((candidate) => candidate.id === binding.catalogId));
if (commands.some((command, index) => command === undefined || command.name !== profile.bindings[index].name || command.plugin !== profile.bindings[index].plugin || command.status !== "native" || command.type !== "変数")) {
  throw new Error("global bindingのcatalog identityが不正です");
}

if (!noBuild) buildLnako();
await access(compiler);
const temporary = await mkdtemp(join(tmpdir(), "lnako-global-binding-"));
try {
  const sourcePath = resolve(temporary, "global-binding.nako3");
  const generatedJavaScript = resolve(temporary, "global-binding.mjs");
  const native = resolve(temporary, process.platform === "win32" ? "global-binding.exe" : "global-binding");
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
  const results = { officialSource, officialGenerated, lnakoRun: interpreted, lnakoNativeO0: nativeResult };
  assertEquivalentResults(results);

  const manifest = await readBindingManifest(globalManifest, sourcePath);
  const interpreterEvents = await readBindingTrace(interpreterTrace, "interpreter", manifest);
  const aotEvents = await readBindingTrace(aotTrace, "aot", manifest);
  const git = readGitState();
  const manifestSites = manifest.entries.map((entry, index) => ({
    catalogId: expectedAccesses[index].catalogId,
    name: expectedAccesses[index].name,
    plugin: expectedAccesses[index].plugin,
    kind: entry.kind,
    siteId: entry.siteId,
  }));
  const bindingRecords = profile.bindings.map((binding) => {
    const sites = manifestSites.filter((site) => site.catalogId === binding.catalogId);
    return {
      ...binding,
      accessSequence: sites.map((site) => site.kind),
      sites,
    };
  });
  const evidence = {
    schema: profile.schema,
    generator: "tools/check_global_binding_evidence.mjs",
    baseline: { tag: lock.nadesiko3.tag, commit: lock.nadesiko3.commit },
    fixture: { id: fixture.id, file: "native-cases.json", sourceSha256: sha256(fixture.source) },
    ...(profile.bindings.length === 1 ? { binding: bindingRecords[0] } : { bindings: bindingRecords }),
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
  };
  validateEvidence(evidence, lock, fixture, manifest);
  if (evidenceOutput !== null) await writeFile(evidenceOutput, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  console.log(`global bindingのInterpreter/AOT証拠: ${profileName} ${manifest.entries.length} access成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function validateArguments() {
  const allowed = new Set(["--no-build", "--oracle", "--profile", "--evidence-output"]);
  for (let index = 2; index < process.argv.length; index += 1) {
    const argument = process.argv[index];
    if (allowed.has(argument)) {
      if (argument === "--no-build") continue;
      if (process.argv[index + 1] === undefined || process.argv[index + 1].startsWith("--")) throw new Error(`${argument}の値がありません`);
      index += 1;
      continue;
    }
    if (argument.startsWith("--oracle=") || argument.startsWith("--profile=") || argument.startsWith("--evidence-output=")) continue;
    throw new Error("usage: node tools/check_global_binding_evidence.mjs [--no-build] [--profile file-copy|node-directory] [--oracle /absolute/path] [--evidence-output /absolute/path]");
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
    throw new Error(`global binding証拠の出力先を確認できません: ${path}`);
  }
  throw new Error(`global binding証拠の出力先は既に存在します: ${path}`);
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

function runProcess(command_, arguments_, options) {
  return new Promise((resolveProcess) => {
    execFile(command_, arguments_, { ...options, maxBuffer, windowsHide: true }, (error, stdout, stderr) => {
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
    if (JSON.stringify(normalizeResult(result)) !== JSON.stringify(expected)) {
      throw new Error(`global bindingの公式差分に失敗しました: ${route}`);
    }
  }
}

function normalizeResult(result) {
  return { stdout: normalizeLineEndings(result.stdout), stderr: normalizeLineEndings(result.stderr), status: result.status, signal: result.signal };
}

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

async function readBindingManifest(path, sourcePath) {
  const lines = await readJsonLines(path, "AOT global binding manifest");
  if (lines.length < 2) throw new Error("AOT global binding manifestが完了レコードを含みません");
  const header = lines[0];
  assertKeys(header, ["schema", "phase", "sourcePath", "siteIdEncoding"], "global binding manifest header");
  if (header.schema !== "lnako.aot.global-manifest.v1" || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16") throw new Error("global binding manifest headerが不正です");
  const complete = lines.at(-1);
  assertKeys(complete, ["schema", "phase", "kind", "complete", "entryCount"], "global binding manifest complete");
  if (complete.schema !== header.schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== expectedAccesses.length) throw new Error("global binding manifest completeが不正です");
  const entries = lines.slice(1, -1);
  if (entries.length !== expectedAccesses.length) throw new Error(`global binding manifestのentry数が不一致です: ${entries.length}`);
  const siteIds = new Set();
  entries.forEach((entry, index) => {
    assertKeys(entry, ["schema", "phase", "kind", "name", "siteId", "function", "source"], "global binding manifest entry");
    assertKeys(entry.source, ["line", "column", "sourceStart", "sourceEnd"], "global binding manifest source");
    const expected = expectedAccesses[index];
    if (entry.schema !== header.schema || entry.phase !== "pre-opt" || entry.kind !== expected.kind || entry.name !== expected.name || !/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) throw new Error(`global binding manifest entryが不正です: ${index}`);
    if (!Number.isSafeInteger(entry.source.line) || entry.source.line < 1 || !Number.isSafeInteger(entry.source.column) || entry.source.column < 1 || !Number.isSafeInteger(entry.source.sourceStart) || !Number.isSafeInteger(entry.source.sourceEnd) || entry.source.sourceStart < 0 || entry.source.sourceEnd < entry.source.sourceStart) throw new Error(`global binding manifestのsource位置が不正です: ${index}`);
    siteIds.add(entry.siteId);
  });
  return { entries };
}

async function readBindingTrace(path, engine, manifest) {
  const lines = await readJsonLines(path, `${engine} global binding trace`);
  const end = lines.at(-1);
  assertKeys(end, ["schema", "engine", "phase", "seq", "dropped"], `${engine} global binding trace end`);
  if (end.schema !== 1 || end.engine !== engine || end.phase !== "trace-end" || end.seq !== expectedAccesses.length || end.dropped !== 0) throw new Error(`${engine} global binding trace endが不正です`);
  const events = lines.slice(0, -1);
  if (events.length !== manifest.entries.length) throw new Error(`${engine} global binding traceの件数が不一致です`);
  const siteIds = new Set();
  events.forEach((event, index) => {
    const expected = expectedAccesses[index];
    const entry = manifest.entries[index];
    const keys = engine === "interpreter"
      ? ["schema", "engine", "phase", "seq", "siteId", "name", ...(expected.phase === "global-read" ? ["found"] : [])]
      : ["schema", "engine", "phase", "seq", "siteId", "success"];
    assertKeys(event, keys, `${engine} global binding trace event`);
    if (event.schema !== 1 || event.engine !== engine || event.phase !== expected.phase || event.seq !== index || event.siteId !== entry.siteId || siteIds.has(event.siteId)) throw new Error(`${engine} global binding trace eventが不正です: ${index}`);
    if (engine === "interpreter" && (event.name !== expected.name || (expected.phase === "global-read" && event.found !== true))) throw new Error(`Interpreter global binding traceのname/foundが不正です: ${index}`);
    if (engine === "aot" && event.success !== true) throw new Error(`AOT global binding traceのsuccessが不正です: ${index}`);
    siteIds.add(event.siteId);
  });
  return events;
}

async function readJsonLines(path, label) {
  const text = await readFile(path, "utf8");
  return text.trimEnd().split(/\r?\n/).filter((line) => line.length > 0).map((line, index) => {
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

function validateEvidence(evidence, lock_, fixture_, manifest) {
  const bindingField = profile.bindings.length === 1 ? "binding" : "bindings";
  assertKeys(evidence, ["schema", "generator", "baseline", "fixture", bindingField, "officialComparison", "attestation", "provenance", "trace"], "global binding evidence");
  if (evidence.schema !== profile.schema || evidence.generator !== "tools/check_global_binding_evidence.mjs" || evidence.baseline.tag !== lock_.nadesiko3.tag || evidence.baseline.commit !== lock_.nadesiko3.commit) throw new Error("global binding evidenceのidentityが不正です");
  assertKeys(evidence.fixture, ["id", "file", "sourceSha256"], "global binding evidence fixture");
  if (evidence.fixture.id !== fixture_.id || evidence.fixture.file !== "native-cases.json" || evidence.fixture.sourceSha256 !== sha256(fixture_.source)) throw new Error("global binding evidenceのfixtureが不一致です");
  const bindingRecords = evidence[bindingField];
  if (!Array.isArray(bindingRecords) && profile.bindings.length > 1) throw new Error("global binding evidenceのbindingsが配列ではありません");
  const actualBindings = profile.bindings.length === 1 ? [bindingRecords] : bindingRecords;
  if (actualBindings.length !== profile.bindings.length) throw new Error("global binding evidenceのbinding数が不一致です");
  const manifestSites = manifest.entries.map((entry, index) => ({ ...expectedAccesses[index], siteId: entry.siteId }));
  for (const [bindingIndex, expectedBinding] of profile.bindings.entries()) {
    const actualBinding = actualBindings[bindingIndex];
    const expectedSites = manifestSites.filter((site) => site.catalogId === expectedBinding.catalogId);
    assertKeys(actualBinding, ["catalogId", "name", "plugin", "accessSequence", "sites"], "global binding evidence binding");
    if (actualBinding.catalogId !== expectedBinding.catalogId || actualBinding.name !== expectedBinding.name || actualBinding.plugin !== expectedBinding.plugin || JSON.stringify(actualBinding.accessSequence) !== JSON.stringify(expectedSites.map((site) => site.kind)) || actualBinding.sites.length !== expectedSites.length) throw new Error("global binding evidenceのbindingが不一致です");
    actualBinding.sites.forEach((site, index) => {
      assertKeys(site, ["catalogId", "name", "plugin", "kind", "siteId"], "global binding evidence site");
      const expected = expectedSites[index];
      if (site.catalogId !== expected.catalogId || site.name !== expected.name || site.plugin !== expected.plugin || site.kind !== expected.kind || site.siteId !== expected.siteId) throw new Error(`global binding evidence siteが不一致です: ${bindingIndex}/${index}`);
    });
  }
  const routes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  assertKeys(evidence.officialComparison, ["oracle", "routes", "equivalent", "results"], "global binding comparison");
  if (evidence.officialComparison.oracle !== "official-source" || JSON.stringify(evidence.officialComparison.routes) !== JSON.stringify(routes) || evidence.officialComparison.equivalent !== true) throw new Error("global binding comparisonが不完全です");
  assertKeys(evidence.officialComparison.results, routes, "global binding comparison results");
  const reference = evidence.officialComparison.results.officialSource;
  for (const route of routes) {
    const result = evidence.officialComparison.results[route];
    assertKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"], `global binding comparison result ${route}`);
    if (result.status !== 0 || result.signal !== null || !/^[0-9a-f]{64}$/.test(result.stdoutSha256) || !/^[0-9a-f]{64}$/.test(result.stderrSha256) || result.stdoutSha256 !== reference.stdoutSha256 || result.stderrSha256 !== reference.stderrSha256) throw new Error(`global binding comparison resultが不正です: ${route}`);
  }
  if (evidence.attestation !== null) throw new Error("global binding evidenceに未対応のattestationがあります");
  assertKeys(evidence.trace, ["interpreter", "aot"], "global binding trace");
  for (const engine of ["interpreter", "aot"]) {
    assertKeys(evidence.trace[engine], ["schema", "eventCount"], `global binding trace ${engine}`);
    if (evidence.trace[engine].schema !== 1 || evidence.trace[engine].eventCount !== expectedAccesses.length) throw new Error(`global binding trace件数が不正です: ${engine}`);
  }
  assertKeys(evidence.provenance, ["environment", "oracle", "lnako", "raw"], "global binding provenance");
  assertKeys(evidence.provenance.environment, ["platform", "arch", "node"], "global binding provenance environment");
  assertKeys(evidence.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"], "global binding provenance oracle");
  assertKeys(evidence.provenance.lnako, ["binarySha256", "commit", "dirty"], "global binding provenance lnako");
  assertKeys(evidence.provenance.raw, ["interpreterTraceSha256", "aotTraceSha256", "globalManifestSha256"], "global binding provenance raw");
  const hashPattern = /^[0-9a-f]{64}$/;
  if (![evidence.provenance.environment.platform, evidence.provenance.environment.arch, evidence.provenance.environment.node].every((value) => typeof value === "string" && value.length > 0) || !Number.isSafeInteger(evidence.provenance.oracle.build) || !hashPattern.test(evidence.provenance.oracle.archiveSha256) || !hashPattern.test(evidence.provenance.oracle.cliSha256) || !hashPattern.test(evidence.provenance.oracle.markerSha256) || !hashPattern.test(evidence.provenance.oracle.treeSha256) || !hashPattern.test(evidence.provenance.lnako.binarySha256) || !/^[0-9a-f]{40}$/.test(evidence.provenance.lnako.commit) || evidence.provenance.lnako.dirty !== false || !hashPattern.test(evidence.provenance.raw.interpreterTraceSha256) || !hashPattern.test(evidence.provenance.raw.aotTraceSha256) || !hashPattern.test(evidence.provenance.raw.globalManifestSha256)) throw new Error("global binding provenanceが不正です");
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
  const expected = baseline.oracleIdentity;
  const platform = `${process.platform}-${process.arch}`;
  const actualTreeSha256 = await oracleTreeHash(directory);
  if (!Number.isSafeInteger(marker.oracleBuild) || marker.oracleBuild !== expected.build || expected.cliSha256 !== actualCliSha256 || expected.markerSha256 !== actualMarkerSha256 || marker.treeSha256 !== actualTreeSha256 || marker.treeSha256 !== expected.treeSha256ByPlatform?.[platform]) throw new Error("公式オラクルの固定情報が一致しません");
  return { build: marker.oracleBuild, archiveSha256: baseline.archive.sha256, cliSha256: actualCliSha256, markerSha256: actualMarkerSha256, treeHashAlgorithm: expected.treeHashAlgorithm, treeSha256: actualTreeSha256 };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
