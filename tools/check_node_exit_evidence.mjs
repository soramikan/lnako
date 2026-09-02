import { access, link, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(import.meta.dirname, "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const catalogPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialHost = resolve(root, "tools/oracle/fixed_host.mjs");
const directCases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-exit-cases.json"), "utf8"));
const interruptCase = JSON.parse(await readFile(resolve(root, "tests/oracle/node-interrupt-case.json"), "utf8"));
const lock = JSON.parse(await readFile(lockPath, "utf8"));
const baseline = lock.nadesiko3;
const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const noBuild = process.argv.includes("--no-build");
const oracleArgument = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArgument >= 0 ? process.argv[oracleArgument + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const outputPath = parseOutputPath();
const selectedCases = [
  {
    id: "plugin-node-exit-code",
    fixtureFile: "node-exit-cases.json",
    command: "プロセス終",
    catalogId: "command-0746",
    source: directCases.find((testCase) => testCase.id === "plugin-node-exit-code")?.source,
    expectedExitCode: 7,
    terminalReason: "process-exit",
    interrupted: false,
  },
  {
    id: "plugin-node-interrupt",
    fixtureFile: "node-interrupt-case.json",
    command: "強制終了時",
    catalogId: "command-0747",
    source: interruptCase.source,
    expectedExitCode: 0,
    terminalReason: "interrupt-callback",
    interrupted: true,
  },
  {
    id: "plugin-node-exit-japanese-alias",
    fixtureFile: "node-exit-cases.json",
    command: "終了",
    catalogId: "command-0748",
    source: directCases.find((testCase) => testCase.id === "plugin-node-exit-japanese-alias")?.source,
    expectedExitCode: 0,
    terminalReason: "process-exit",
    interrupted: false,
  },
];
const routeNames = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0", "lnakoNativeO1", "lnakoNativeO2", "lnakoNativeO3"];
const optimizationNames = ["O0", "O1", "O2", "O3"];
const forbiddenFields = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address"]);
const hashPattern = /^[0-9a-f]{64}$/;
const siteIdPattern = /^0x[0-9a-f]{16}$/;
const commitPattern = /^[0-9a-f]{40}$/i;

if (outputPath === null) throw new Error("--outputには絶対パスを指定してください");
if (catalog.commandCount !== 527 || catalog.commands.length !== 527) throw new Error("標準cnakoカタログが527 entryではありません");
for (const testCase of selectedCases) validateSelectedCase(testCase);
await ensureOutputFree(outputPath);
if (process.platform === "win32") throw new Error("強制終了時の実SIGINT証拠はWindowsコンソール制御イベント実装後に有効化します");

const oracle = await readOracleIdentity();
if (!noBuild) buildCompiler();
await access(executable);
const git = gitState();
const temporary = await mkdtemp(join(root, ".tmp-lnako-node-exit-evidence-"));
try {
  const entries = [];
  for (const testCase of selectedCases) entries.push(await runSelectedCase(testCase, temporary, oracle));
  const artifact = {
    schema: "lnako.expected-exit-evidence.v1",
    generator: "tools/check_node_exit_evidence.mjs",
    baseline: { tag: baseline.tag, commit: baseline.commit },
    fixture: {
      id: "node-exit-evidence",
      files: ["tests/oracle/node-exit-cases.json", "tests/oracle/node-interrupt-case.json"],
      cases: entries.map((entry) => ({ id: entry.caseId, command: entry.name, catalogId: entry.catalogId, sourceSha256: entry.sourceSha256 })),
    },
    officialComparison: { routes: routeNames, equivalent: true },
    provenance: {
      environment: { platform: process.platform, arch: process.arch, node: process.version },
      oracle: oracleEvidence(oracle),
      lnako: { binarySha256: sha256(await readFile(executable)), commit: git.commit, dirty: git.dirty },
      raw: {
        traceSha256: Object.fromEntries(entries.map((entry) => [entry.caseId, {
          interpreter: entry.trace.interpreter.traceSha256,
          aot: Object.fromEntries(optimizationNames.map((optimization) => [optimization, entry.trace.aot[optimization].traceSha256])),
        }])),
      },
    },
    entries,
  };
  validateArtifact(artifact);
  await writeExclusive(outputPath, `${JSON.stringify(artifact, null, 2)}\n`);
  console.log(`Node終了expected-exit証拠: ${entries.length}ケース・公式source/generated・Interpreter・AOT O0〜O3・terminal trace成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function parseOutputPath() {
  const index = process.argv.indexOf("--output");
  if (index < 0) return null;
  const value = process.argv[index + 1];
  if (value === undefined || !isAbsolute(value)) throw new Error("--outputには絶対パスを指定してください");
  return resolve(value);
}

function validateSelectedCase(testCase) {
  if (typeof testCase.source !== "string" || testCase.source.length === 0) throw new Error(`終了fixture sourceがありません: ${testCase.id}`);
  if (typeof testCase.command !== "string" || testCase.command.length === 0) {
    throw new Error(`終了fixture commandが不正です: ${testCase.id}`);
  }
  const command = catalog.commands.find((candidate) => candidate.id === testCase.catalogId);
  if (command === undefined || command.name !== testCase.command || command.plugin !== "plugin_node" || command.status !== "native") {
    throw new Error(`終了fixtureのcatalog identityが不正です: ${testCase.id}`);
  }
}

async function ensureOutputFree(path) {
  try {
    await access(path);
    throw new Error(`expected-exit証拠の出力先は既に存在します: ${path}`);
  } catch (error) {
    if (error?.message?.startsWith("expected-exit証拠の出力先は既に存在します")) throw error;
    if (error?.code !== "ENOENT") throw error;
  }
}

async function runSelectedCase(testCase, temporary, oracle) {
  const caseDirectory = resolve(temporary, testCase.id);
  const directories = Object.fromEntries([
    "officialSource",
    "officialGenerated",
    "interpreterNoTrace",
    "interpreterTrace",
    "aotCompile",
    ...optimizationNames.flatMap((optimization) => [`aot${optimization}NoTrace`, `aot${optimization}Trace`]),
  ].map((name) => [name, resolve(caseDirectory, name)]));
  await Promise.all(Object.values(directories).map((directory) => mkdir(directory, { recursive: true })));
  const sourcePaths = {};
  for (const [name, directory] of Object.entries(directories)) {
    if (!name.startsWith("official") && !name.startsWith("interpreter") && !name.startsWith("aot")) continue;
    sourcePaths[name] = resolve(directory, "case.nako3");
    await writeFile(sourcePaths[name], testCase.source, "utf8");
  }
  const environment = fixedEnvironment();
  const oracleArguments = ["--import", pathToFileURL(officialHost).href];
  const run = (command, args, env, cwd) => testCase.interrupted
    ? runInterrupted(command, args, env, cwd)
    : Promise.resolve(runSync(command, args, env, cwd));

  const officialSource = await run(process.execPath, [...oracleArguments, oracle.cliPath, sourcePaths.officialSource], environment, directories.officialSource);
  const generatedPath = resolve(directories.officialGenerated, "case.mjs");
  const officialCompile = runSync(process.execPath, [...oracleArguments, oracle.cliPath, "--compile", "--silent", "--output", generatedPath, sourcePaths.officialGenerated], environment, directories.officialGenerated);
  if (officialCompile.status !== 0) throw new Error(`公式JavaScript生成に失敗しました: ${testCase.id}\n${officialCompile.stderr}`);
  await access(generatedPath);
  const officialGenerated = await run(process.execPath, [...oracleArguments, generatedPath], environment, directories.officialGenerated);
  assertExpectedRoute(testCase, "officialSource", officialSource);
  assertExpectedRoute(testCase, "officialGenerated", officialGenerated);
  assertProcessEquivalent(testCase, "公式source/generated", officialSource, officialGenerated);

  const interpreterNoTrace = await run(executable, ["run", sourcePaths.interpreterNoTrace], environment, directories.interpreterNoTrace);
  const interpreterTracePath = resolve(directories.interpreterTrace, "trace.jsonl");
  const interpreterWithTrace = await run(executable, ["run", sourcePaths.interpreterTrace], { ...environment, LNAKO_DISPATCH_TRACE: interpreterTracePath }, directories.interpreterTrace);
  assertExpectedRoute(testCase, "lnakoRun", interpreterNoTrace);
  assertProcessEquivalent(testCase, "Interpreter trace有無", interpreterNoTrace, interpreterWithTrace);
  const interpreterTrace = await readTerminalTrace(interpreterTracePath, "interpreter", testCase);

  const compileStatuses = {};
  const aotTraces = {};
  let manifest = null;
  let targetSite = null;
  const aotProcesses = {};
  for (const optimization of optimizationNames) {
    const nativePath = resolve(directories.aotCompile, `case-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
    const manifestPath = resolve(directories.aotCompile, "compile-manifest.jsonl");
    const compileEnvironment = optimization === "O0" ? { ...environment, LNAKO_COMPILE_MANIFEST: manifestPath } : environment;
    const compile = runSync(executable, ["build", sourcePaths.aotCompile, "-o", nativePath, `-${optimization}`], compileEnvironment, directories.aotCompile);
    compileStatuses[optimization] = compile.status;
    if (compile.status !== 0) throw new Error(`AOT ${optimization}コンパイルに失敗しました: ${testCase.id}\n${compile.stderr}`);
    if (optimization === "O0") {
      manifest = await readCompileManifest(manifestPath, sourcePaths.aotCompile, testCase);
      targetSite = manifest.entries.find((entry) => entry.sourceName === testCase.command) ?? null;
      if (targetSite === null) throw new Error(`AOT manifestに終了命令がありません: ${testCase.id}`);
    }
    const noTrace = await run(nativePath, [], environment, directories[`aot${optimization}NoTrace`]);
    const tracePath = resolve(directories[`aot${optimization}Trace`], "trace.jsonl");
    const withTrace = await run(nativePath, [], { ...environment, LNAKO_DISPATCH_TRACE: tracePath }, directories[`aot${optimization}Trace`]);
    assertExpectedRoute(testCase, `lnakoNative${optimization}`, noTrace);
    assertProcessEquivalent(testCase, `AOT ${optimization} trace有無`, noTrace, withTrace);
    aotProcesses[optimization] = noTrace;
    aotTraces[optimization] = await readTerminalTrace(tracePath, "aot", testCase, manifest.entries);
  }
  if (targetSite === null || targetSite.siteId !== interpreterTrace.target.siteId) {
    throw new Error(`終了命令のInterpreter/AOT siteIdが一致しません: ${testCase.id}`);
  }
  for (const optimization of optimizationNames) {
    const target = aotTraces[optimization].target;
    if (target.siteId !== targetSite.siteId || target.canonicalOpcode !== targetSite.canonicalOpcode || target.opcode !== targetSite.opcode || target.route !== targetSite.route) {
      throw new Error(`AOT ${optimization}の終了dispatchがO0 manifestと一致しません: ${testCase.id}`);
    }
  }
  const results = Object.fromEntries([
    ["officialSource", officialSource],
    ["officialGenerated", officialGenerated],
    ["lnakoRun", interpreterNoTrace],
    ...optimizationNames.map((optimization) => [`lnakoNative${optimization}`, aotProcesses[optimization]]),
  ].map(([route, result]) => [route, summarizeProcess(result)]));
  return {
    caseId: testCase.id,
    catalogId: testCase.catalogId,
    name: testCase.command,
    plugin: "plugin_node",
    sourceSha256: sha256(testCase.source),
    expectedExitCode: testCase.expectedExitCode,
    terminalReason: testCase.terminalReason,
    officialComparison: { oracle: "official-source", routes: routeNames, equivalent: true, results },
    site: {
      siteId: targetSite.siteId,
      sourceName: targetSite.sourceName,
      canonicalOpcode: targetSite.canonicalOpcode,
      opcode: targetSite.opcode,
      route: targetSite.route,
    },
    trace: {
      interpreter: interpreterTrace,
      aot: aotTraces,
      compileManifest: { complete: true, entries: manifest.entries, rawSha256: manifest.rawSha256 },
    },
    compileStatuses,
  };
}

function oracleEvidence(oracle) {
  return {
    build: oracle.build,
    archiveSha256: oracle.archiveSha256,
    cliSha256: oracle.cliSha256,
    markerSha256: oracle.markerSha256,
    treeHashAlgorithm: oracle.treeHashAlgorithm,
    treeSha256: oracle.treeSha256,
  };
}

function fixedEnvironment() {
  const environment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    LNAKO_TEST_NOW_MS: "1735689845678",
    LNAKO_TEST_MONOTONIC_MS: "123.5",
    LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
    LNAKO_NODE_TEST: "expected-exit-evidence",
    NAKO3_DISABLE_NEW_CONSOLE: "1",
  };
  const nodeDirectory = dirname(process.execPath);
  const separator = process.platform === "win32" ? ";" : ":";
  if (process.platform === "win32") {
    environment.Path = `${nodeDirectory}${separator}${environment.Path ?? environment.PATH ?? ""}`;
    delete environment.PATH;
  } else {
    environment.PATH = `${nodeDirectory}${separator}${environment.PATH ?? ""}`;
  }
  delete environment.LNAKO_DISPATCH_TRACE;
  delete environment.LNAKO_COMPILE_MANIFEST;
  return environment;
}

function runSync(command, args, env, cwd) {
  const result = spawnSync(command, args, { cwd, env, encoding: "utf8", maxBuffer: 32 * 1024 * 1024, windowsHide: true });
  return { status: result.status, signal: result.signal, stdout: result.stdout ?? "", stderr: result.stderr ?? (result.error?.message ?? "") };
}

function runInterrupted(command, args, env, cwd) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolveResult(result);
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const interrupt = setTimeout(() => child.kill("SIGINT"), 500);
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      if (!settled) reject(new Error(`${command} のSIGINT処理がタイムアウトしました`));
    }, 4000);
    child.on("error", (error) => { clearTimeout(interrupt); clearTimeout(timeout); reject(error); });
    child.on("close", (status, signal) => {
      clearTimeout(interrupt);
      clearTimeout(timeout);
      finish({ status, signal, stdout, stderr });
    });
  });
}

function assertExpectedRoute(testCase, route, result) {
  if (result.status !== testCase.expectedExitCode || result.signal !== null || normalizeLineEndings(result.stdout) !== expectedStdout(testCase)) {
    throw new Error(`${testCase.id} ${route}の終了結果が不一致です: ${JSON.stringify({ status: result.status, signal: result.signal, stdout: normalizeLineEndings(result.stdout), stderr: normalizeLineEndings(result.stderr) })}`);
  }
}

function expectedStdout(testCase) {
  return testCase.interrupted ? "READY\n" : "BEFORE\n";
}

function assertProcessEquivalent(testCase, label, left, right) {
  if (JSON.stringify(normalizeProcess(left)) !== JSON.stringify(normalizeProcess(right))) {
    throw new Error(`${testCase.id} ${label}の結果が変化しました: ${JSON.stringify({ left: normalizeProcess(left), right: normalizeProcess(right) })}`);
  }
}

function normalizeProcess(result) {
  return { status: result.status, signal: result.signal, stdout: normalizeLineEndings(result.stdout), stderr: normalizeLineEndings(result.stderr) };
}

function summarizeProcess(result) {
  return {
    status: result.status,
    signal: result.signal,
    stdoutSha256: sha256(normalizeLineEndings(result.stdout)),
    stderrSha256: sha256(normalizeLineEndings(result.stderr)),
  };
}

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

async function readTerminalTrace(path, engine, testCase, manifestEntries = []) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error(`${testCase.id} ${engine} terminal traceが改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${testCase.id} ${engine} terminal trace ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error(`${testCase.id} ${engine} terminal traceが短すぎます`);
  for (const [index, record] of records.entries()) {
    if (record.schema !== 2 || record.engine !== engine || record.seq !== index) throw new Error(`${testCase.id} ${engine} terminal trace metadataが不正です`);
    for (const field of forbiddenFields) if (Object.hasOwn(record, field)) throw new Error(`${testCase.id} ${engine} terminal traceに禁止fieldがあります: ${field}`);
  }
  const end = records.at(-1);
  if (JSON.stringify(Object.keys(end).sort()) !== JSON.stringify(["dropped", "engine", "exitCode", "phase", "schema", "seq", "signal", "terminalReason"].sort()) ||
      end.phase !== "trace-end" || end.dropped !== 0 || end.terminalReason !== testCase.terminalReason || end.exitCode !== testCase.expectedExitCode || end.signal !== null) {
    throw new Error(`${testCase.id} ${engine} terminal trace終端が不正です: ${JSON.stringify(end)}`);
  }
  const events = records.slice(0, -1);
  const target = engine === "interpreter"
    ? readInterpreterTarget(events, testCase)
    : readAotTarget(events, manifestEntries, testCase);
  return {
    eventCount: events.length,
    terminalReason: end.terminalReason,
    exitCode: end.exitCode,
    signal: end.signal,
    target,
    traceSha256: sha256(text),
  };
}

function readInterpreterTarget(events, testCase) {
  for (const event of events) {
    if (event.phase !== "dispatch-result" || typeof event.command !== "string" || typeof event.route !== "string" ||
        !["success", "failure"].includes(event.result) || (event.siteId !== null && !siteIdPattern.test(event.siteId))) {
      throw new Error(`${testCase.id} Interpreter terminal traceのdispatch metadataが不正です`);
    }
  }
  const target = events.find((event) => event.command === testCase.command && event.result === "success" && event.siteId !== null);
  if (target === undefined) throw new Error(`${testCase.id} Interpreter terminal traceに終了命令の成功siteがありません`);
  return { siteId: target.siteId, sourceName: target.command, route: target.route, result: target.result, count: events.filter((event) => event.siteId === target.siteId).length };
}

function readAotTarget(events, manifestEntries, testCase) {
  const manifestBySite = new Map(manifestEntries.map((entry) => [entry.siteId, entry]));
  const attempts = events.filter((event) => event.phase === "dispatch-attempt");
  const results = events.filter((event) => event.phase === "dispatch-result");
  if (attempts.length === 0 || results.length === 0) throw new Error(`${testCase.id} AOT terminal traceにdispatchがありません`);
  const attemptsByCall = new Map();
  for (const attempt of attempts) {
    if (!Number.isSafeInteger(attempt.callId) || attemptsByCall.has(attempt.callId) || attempt.name_source !== "canonical-opcode" ||
        !Number.isInteger(attempt.opcode) || typeof attempt.command !== "string" || typeof attempt.route !== "string" ||
        (attempt.siteId !== null && !siteIdPattern.test(attempt.siteId))) {
      throw new Error(`${testCase.id} AOT terminal traceのattemptが不正です`);
    }
    if (attempt.siteId !== null) {
      const manifest = manifestBySite.get(attempt.siteId);
      if (manifest === undefined || manifest.canonicalOpcode !== attempt.command || manifest.opcode !== attempt.opcode || manifest.route !== attempt.route) {
        throw new Error(`${testCase.id} AOT terminal traceとmanifestが不一致です`);
      }
    }
    attemptsByCall.set(attempt.callId, attempt);
  }
  const resultsByCall = new Map();
  for (const result of results) {
    if (!Number.isSafeInteger(result.callId) || resultsByCall.has(result.callId) || typeof result.success !== "boolean" ||
        !Number.isInteger(result.opcode) || typeof result.command !== "string" || typeof result.route !== "string" ||
        (result.siteId !== null && !siteIdPattern.test(result.siteId))) {
      throw new Error(`${testCase.id} AOT terminal traceのresultが不正です`);
    }
    const attempt = attemptsByCall.get(result.callId);
    if (attempt === undefined || attempt.siteId !== result.siteId || attempt.command !== result.command || attempt.opcode !== result.opcode || attempt.route !== result.route) {
      throw new Error(`${testCase.id} AOT terminal traceのattempt/result対応が不正です`);
    }
    resultsByCall.set(result.callId, result);
  }
  const unmatched = [...attemptsByCall.keys()].filter((callId) => !resultsByCall.has(callId));
  if (testCase.terminalReason === "process-exit" && unmatched.length !== 0) throw new Error(`${testCase.id} process-exit前に未完了AOT dispatchがあります`);
  if (testCase.terminalReason === "interrupt-callback" && unmatched.length > 1) throw new Error(`${testCase.id} interrupt terminal前の未完了AOT dispatchが多すぎます`);
  const manifestTarget = manifestEntries.find((entry) => entry.sourceName === testCase.command);
  if (manifestTarget === undefined) throw new Error(`${testCase.id} AOT manifestに対象命令がありません`);
  const targetResult = [...resultsByCall.values()].find((result) => result.siteId === manifestTarget.siteId && result.success === true);
  if (targetResult === undefined) throw new Error(`${testCase.id} AOT terminal traceに終了命令の成功resultがありません`);
  return {
    siteId: manifestTarget.siteId,
    sourceName: manifestTarget.sourceName,
    canonicalOpcode: manifestTarget.canonicalOpcode,
    opcode: manifestTarget.opcode,
    route: manifestTarget.route,
    result: targetResult.success,
    callId: targetResult.callId,
    count: [...resultsByCall.values()].filter((result) => result.siteId === manifestTarget.siteId).length,
    unmatchedCallCount: unmatched.length,
  };
}

async function readCompileManifest(path, sourcePath, testCase) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error(`${testCase.id} AOT manifestが改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line) => JSON.parse(line));
  const header = records[0];
  const complete = records.at(-1);
  const entries = records.slice(1, -1);
  if (records.length < 3 || header.schema !== "lnako.aot.builtin-manifest.v1" || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16" ||
      complete.schema !== header.schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== entries.length) throw new Error(`${testCase.id} AOT manifest header/completeが不正です`);
  const siteIds = new Set();
  const summaries = entries.map((entry) => {
    if (entry.schema !== header.schema || entry.phase !== "pre-opt" || entry.kind !== "builtin-dispatch" ||
        ![entry.sourceName, entry.canonicalOpcode, entry.route].every((value) => typeof value === "string" && value.length > 0) ||
        !Number.isInteger(entry.opcode) || entry.opcode < 0 || entry.opcode > 0xffff || typeof entry.siteId !== "string" || !siteIdPattern.test(entry.siteId) || siteIds.has(entry.siteId)) {
      throw new Error(`${testCase.id} AOT manifest entryが不正です`);
    }
    for (const field of ["arguments", "values", "value", "pointer", "address"]) if (Object.hasOwn(entry, field)) throw new Error(`${testCase.id} AOT manifestに禁止fieldがあります: ${field}`);
    siteIds.add(entry.siteId);
    return { sourceName: entry.sourceName, canonicalOpcode: entry.canonicalOpcode, opcode: entry.opcode, route: entry.route, siteId: entry.siteId };
  });
  return { entries: summaries, rawSha256: sha256(text) };
}

function validateArtifact(artifact) {
  assertExactKeys(artifact, ["schema", "generator", "baseline", "fixture", "officialComparison", "provenance", "entries"]);
  if (artifact.schema !== "lnako.expected-exit-evidence.v1" || artifact.generator !== "tools/check_node_exit_evidence.mjs" || artifact.baseline.tag !== baseline.tag || artifact.baseline.commit !== baseline.commit || !Array.isArray(artifact.entries) || artifact.entries.length !== 3) throw new Error("expected-exit証拠artifactのidentityが不正です");
  rejectForbidden(artifact);
  assertExactKeys(artifact.baseline, ["tag", "commit"]);
  assertExactKeys(artifact.fixture, ["id", "files", "cases"]);
  if (artifact.fixture.id !== "node-exit-evidence" || JSON.stringify(artifact.fixture.files) !== JSON.stringify(["tests/oracle/node-exit-cases.json", "tests/oracle/node-interrupt-case.json"]) || !Array.isArray(artifact.fixture.cases) || artifact.fixture.cases.length !== selectedCases.length) throw new Error("expected-exit証拠のfixture identityが不正です");
  const fixtureCasesById = new Map();
  for (const fixtureCase of artifact.fixture.cases) {
    assertExactKeys(fixtureCase, ["id", "command", "catalogId", "sourceSha256"]);
    if (fixtureCasesById.has(fixtureCase.id) || !hashPattern.test(fixtureCase.sourceSha256)) throw new Error(`expected-exit証拠のfixture caseが不正です: ${fixtureCase.id}`);
    const selectedCase = selectedCases.find((candidate) => candidate.id === fixtureCase.id);
    if (selectedCase === undefined || fixtureCase.command !== selectedCase.command || fixtureCase.catalogId !== selectedCase.catalogId || fixtureCase.sourceSha256 !== sha256(selectedCase.source)) throw new Error(`expected-exit証拠のfixture caseが選択対象と不一致です: ${fixtureCase.id}`);
    fixtureCasesById.set(fixtureCase.id, fixtureCase);
  }
  assertExactKeys(artifact.officialComparison, ["routes", "equivalent"]);
  if (JSON.stringify(artifact.officialComparison.routes) !== JSON.stringify(routeNames) || artifact.officialComparison.equivalent !== true) throw new Error("expected-exit証拠の比較routeが不正です");
  assertExactKeys(artifact.provenance, ["environment", "oracle", "lnako", "raw"]);
  assertExactKeys(artifact.provenance.environment, ["platform", "arch", "node"]);
  assertExactKeys(artifact.provenance.oracle, ["build", "archiveSha256", "cliSha256", "markerSha256", "treeHashAlgorithm", "treeSha256"]);
  assertExactKeys(artifact.provenance.lnako, ["binarySha256", "commit", "dirty"]);
  assertExactKeys(artifact.provenance.raw, ["traceSha256"]);
  if (!hashPattern.test(artifact.provenance.oracle.archiveSha256) || !hashPattern.test(artifact.provenance.oracle.cliSha256) || !hashPattern.test(artifact.provenance.oracle.markerSha256) || !hashPattern.test(artifact.provenance.oracle.treeSha256) ||
      !hashPattern.test(artifact.provenance.lnako.binarySha256) || !commitPattern.test(artifact.provenance.lnako.commit) || artifact.provenance.lnako.dirty !== false) throw new Error("expected-exit証拠のprovenanceが不正です");
  assertExactKeys(artifact.provenance.raw.traceSha256, selectedCases.map((testCase) => testCase.id));
  for (const traces of Object.values(artifact.provenance.raw.traceSha256)) {
    assertExactKeys(traces, ["interpreter", "aot"]);
    if (!hashPattern.test(traces.interpreter)) throw new Error("expected-exit証拠のInterpreter raw trace hashが不正です");
    assertExactKeys(traces.aot, optimizationNames);
    if (Object.values(traces.aot).some((trace) => !hashPattern.test(trace))) throw new Error("expected-exit証拠のAOT raw trace hashが不正です");
  }
  const entriesByCaseId = new Map();
  for (const entry of artifact.entries) {
    assertExactKeys(entry, ["caseId", "catalogId", "name", "plugin", "sourceSha256", "expectedExitCode", "terminalReason", "officialComparison", "site", "trace", "compileStatuses"]);
    const selectedCase = selectedCases.find((candidate) => candidate.id === entry.caseId);
    if (selectedCase === undefined || entriesByCaseId.has(entry.caseId) || entry.catalogId !== selectedCase.catalogId || entry.name !== selectedCase.command || entry.plugin !== "plugin_node" || entry.sourceSha256 !== sha256(selectedCase.source) || entry.expectedExitCode !== selectedCase.expectedExitCode || entry.terminalReason !== selectedCase.terminalReason) throw new Error(`expected-exit証拠entryが不正です: ${entry.caseId}`);
    entriesByCaseId.set(entry.caseId, entry);
    assertExactKeys(entry.officialComparison, ["oracle", "routes", "equivalent", "results"]);
    if (entry.officialComparison.oracle !== "official-source" || JSON.stringify(entry.officialComparison.routes) !== JSON.stringify(routeNames) || entry.officialComparison.equivalent !== true) throw new Error(`expected-exit証拠の公式比較が不正です: ${entry.caseId}`);
    assertExactKeys(entry.officialComparison.results, routeNames);
    const officialResult = entry.officialComparison.results.officialSource;
    for (const result of Object.values(entry.officialComparison.results)) {
      assertExactKeys(result, ["status", "signal", "stdoutSha256", "stderrSha256"]);
      if (result.status !== entry.expectedExitCode || result.signal !== null || !hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256) || result.stdoutSha256 !== officialResult.stdoutSha256 || result.stderrSha256 !== officialResult.stderrSha256) throw new Error(`expected-exit証拠のroute結果が不正です: ${entry.caseId}`);
    }
    assertExactKeys(entry.site, ["siteId", "sourceName", "canonicalOpcode", "opcode", "route"]);
    const expectedCanonicalOpcode = entry.terminalReason === "interrupt-callback" ? "node_interrupt_callback" : entry.expectedExitCode === 7 ? "node_process_exit" : "node_exit";
    const expectedRoute = entry.terminalReason === "interrupt-callback" ? "node-interrupt" : "builtin";
    if (entry.site.sourceName !== entry.name || !siteIdPattern.test(entry.site.siteId) || entry.site.canonicalOpcode !== expectedCanonicalOpcode || !Number.isInteger(entry.site.opcode) || entry.site.opcode < 0 || entry.site.opcode > 0xffff || entry.site.route !== expectedRoute) throw new Error(`expected-exit証拠のsiteが不正です: ${entry.caseId}`);
    assertExactKeys(entry.trace, ["interpreter", "aot", "compileManifest"]);
    validateTraceSummary(entry.trace.interpreter, entry, "interpreter");
    assertExactKeys(entry.trace.aot, optimizationNames);
    for (const optimization of optimizationNames) validateTraceSummary(entry.trace.aot[optimization], entry, `aot-${optimization}`);
    assertExactKeys(entry.compileStatuses, optimizationNames);
    if (Object.values(entry.compileStatuses).some((status) => status !== 0)) throw new Error(`expected-exit証拠のcompile statusが不正です: ${entry.caseId}`);
    assertExactKeys(entry.trace.compileManifest, ["complete", "entries", "rawSha256"]);
    if (entry.trace.compileManifest.complete !== true || !Array.isArray(entry.trace.compileManifest.entries) || !hashPattern.test(entry.trace.compileManifest.rawSha256)) throw new Error(`expected-exit証拠のmanifest要約が不正です: ${entry.caseId}`);
    const manifestTarget = entry.trace.compileManifest.entries.find((candidate) => candidate.sourceName === entry.name);
    if (manifestTarget === undefined || manifestTarget.siteId !== entry.site.siteId || manifestTarget.sourceName !== entry.site.sourceName || manifestTarget.canonicalOpcode !== entry.site.canonicalOpcode || manifestTarget.opcode !== entry.site.opcode || manifestTarget.route !== entry.site.route) throw new Error(`expected-exit証拠のmanifest targetがsiteと不一致です: ${entry.caseId}`);
  }
  if (entriesByCaseId.size !== selectedCases.length || [...fixtureCasesById.keys()].some((caseId) => !entriesByCaseId.has(caseId))) throw new Error("expected-exit証拠のentry集合がfixtureと一致しません");
}

function validateTraceSummary(trace, entry, label) {
  assertExactKeys(trace, ["eventCount", "terminalReason", "exitCode", "signal", "target", "traceSha256"]);
  if (!Number.isSafeInteger(trace.eventCount) || trace.eventCount < 1 || trace.terminalReason !== entry.terminalReason || trace.exitCode !== entry.expectedExitCode || trace.signal !== null || !hashPattern.test(trace.traceSha256)) throw new Error(`expected-exit証拠の${label} trace要約が不正です: ${entry.caseId}`);
  if (label === "interpreter") {
    assertExactKeys(trace.target, ["siteId", "sourceName", "route", "result", "count"]);
  } else {
    assertExactKeys(trace.target, ["siteId", "sourceName", "canonicalOpcode", "opcode", "route", "result", "callId", "count", "unmatchedCallCount"]);
  }
  const targetInvalid = trace.target.siteId !== entry.site.siteId || trace.target.sourceName !== entry.name || trace.target.result !== (label === "interpreter" ? "success" : true) || !Number.isSafeInteger(trace.target.count) || trace.target.count < 1;
  const aotTargetInvalid = label !== "interpreter" && (
    trace.target.canonicalOpcode !== entry.site.canonicalOpcode ||
    trace.target.opcode !== entry.site.opcode ||
    trace.target.route !== entry.site.route ||
    !Number.isSafeInteger(trace.target.callId) ||
    !Number.isSafeInteger(trace.target.unmatchedCallCount) ||
    trace.target.unmatchedCallCount < 0 ||
    (entry.terminalReason === "process-exit" && trace.target.unmatchedCallCount !== 0) ||
    (entry.terminalReason === "interrupt-callback" && trace.target.unmatchedCallCount > 1)
  );
  if (targetInvalid || aotTargetInvalid) {
    throw new Error(`expected-exit証拠の${label} targetが不正です: ${entry.caseId}`);
  }
}

function assertExactKeys(value, expected) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) throw new Error("expected-exit証拠artifactのkey一覧が不正です");
}

function rejectForbidden(value) {
  if (value === null || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) rejectForbidden(item);
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    if (forbiddenFields.has(key)) throw new Error(`expected-exit証拠artifactに禁止fieldがあります: ${key}`);
    rejectForbidden(child);
  }
}

async function readOracleIdentity() {
  const markerPath = resolve(oracleRoot, ".lnako-oracle.json");
  const markerBytes = await readFile(markerPath);
  const marker = JSON.parse(markerBytes.toString("utf8"));
  const platform = `${process.platform}-${process.arch}`;
  const expectedTree = baseline.oracleIdentity?.treeSha256ByPlatform?.[platform];
  if (marker.tag !== baseline.tag || marker.commit !== baseline.commit || marker.archiveSha256 !== baseline.archive.sha256 || marker.treeSha256 !== expectedTree || baseline.oracleIdentity.treeHashAlgorithm !== oracleTreeHashAlgorithm || !Number.isSafeInteger(marker.oracleBuild) || marker.oracleBuild < 1) throw new Error("公式オラクルの固定identityが不正です");
  const cliPath = resolve(oracleRoot, "src/cnako3.mjs");
  const treeSha256 = await oracleTreeHash(oracleRoot);
  if (treeSha256 !== marker.treeSha256 || sha256(await readFile(cliPath)) !== baseline.oracleIdentity.cliSha256 || sha256(markerBytes) !== baseline.oracleIdentity.markerSha256) throw new Error("公式オラクルのSHA-256またはtree hashが不一致です");
  return {
    build: marker.oracleBuild,
    archiveSha256: baseline.archive.sha256,
    cliSha256: sha256(await readFile(cliPath)),
    markerSha256: sha256(markerBytes),
    treeHashAlgorithm: oracleTreeHashAlgorithm,
    treeSha256,
    cliPath,
  };
}

function buildCompiler() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") }, maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`lnakoビルドに失敗しました:\n${result.stderr}`);
}

function gitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (commit.status !== 0 || status.status !== 0 || !commit.stdout.trim().match(commitPattern)) throw new Error("lnako git stateを取得できません");
  return { commit: commit.stdout.trim(), dirty: status.stdout.length > 0 };
}

async function writeExclusive(path, contents) {
  const directory = dirname(path);
  const temporaryDirectory = await mkdtemp(join(directory, `.lnako-expected-exit-${process.pid}-`));
  try {
    const temporaryPath = join(temporaryDirectory, "evidence.json");
    await writeFile(temporaryPath, contents, { encoding: "utf8", flag: "wx" });
    await link(temporaryPath, path);
  } catch (error) {
    if (error?.code === "EEXIST") throw new Error(`expected-exit証拠の出力先は既に存在します: ${path}`);
    throw error;
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
