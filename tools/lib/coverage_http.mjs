import http from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { coverageEnv as env } from "./coverage_env.mjs";
import * as evidence_common from "./evidence_common.mjs";
import * as coverage_process from "./coverage_process.mjs";
import * as coverage_fixtures from "./coverage_fixtures.mjs";
import * as coverage_sites from "./coverage_sites.mjs";

export async function runHttpServerFixture(fixture, index, temporary) {
  const fixtureDirectory = resolve(temporary, `${String(index).padStart(2, "0")}-${fixture.id}`);
  await mkdir(fixtureDirectory);
  const stem = `${String(index).padStart(2, "0")}-${fixture.id}`;
  const sourceName = fixture.sourceFileName ?? `${stem}.nako3`;
  const sourceSha256 = evidence_common.sha256(fixture.source);
  const directories = {
    officialSource: resolve(fixtureDirectory, "official-source"),
    officialGenerated: resolve(fixtureDirectory, "official-generated"),
    interpreterTrace: resolve(fixtureDirectory, "interpreter-trace"),
    aotTrace: resolve(fixtureDirectory, "aot-trace"),
  };
  await Promise.all(Object.values(directories).map((directory) => mkdir(directory, { recursive: true })));

  const prepare = async (directory) => {
    const staticDirectory = resolve(directory, "static");
    await mkdir(staticDirectory, { recursive: true });
    await writeFile(resolve(staticDirectory, "hello.txt"), "STATIC", "utf8");
    const port = await reserveHttpServerPort();
    const source = coverage_fixtures.replacePluginPlaceholders(fixture.source, directory, null, fixture, {
      "${PORT}": String(port),
      "${STATIC}": staticDirectory.replaceAll("\\", "/"),
    });
    const sourcePath = resolve(directory, sourceName);
    await writeFile(sourcePath, source, "utf8");
    return { directory, port, sourcePath };
  };

  const oracleHostArguments = ["--import", pathToFileURL(env.fixedHost).href];
  const fixedEnvironmentForHttp = () => coverage_fixtures.fixedEnvironment();
  const officialSourceSetup = await prepare(directories.officialSource);
  const officialSource = await runHttpServerSuite(
    `${fixture.id} 公式source`,
    [process.execPath, ...oracleHostArguments, resolve(env.oracleRoot, "src/cnako3.mjs"), officialSourceSetup.sourcePath],
    officialSourceSetup.port,
    fixedEnvironmentForHttp(),
    officialSourceSetup.directory,
  );

  const officialGeneratedSetup = await prepare(directories.officialGenerated);
  const generatedPath = resolve(officialGeneratedSetup.directory, `${stem}.mjs`);
  const officialCompile = coverage_process.run(
    process.execPath,
    [...oracleHostArguments, resolve(env.oracleRoot, "src/cnako3.mjs"), "--compile", "--silent", "--output", generatedPath, officialGeneratedSetup.sourcePath],
    fixedEnvironmentForHttp(),
    officialGeneratedSetup.directory,
  );
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} 公式JavaScript生成`, officialCompile);
  const officialGenerated = await runHttpServerSuite(
    `${fixture.id} 公式生成JavaScript`,
    [process.execPath, ...oracleHostArguments, generatedPath],
    officialGeneratedSetup.port,
    fixedEnvironmentForHttp(),
    officialGeneratedSetup.directory,
    { allowUnavailable: coverage_fixtures.isKnownGeneratedRouteUnavailable(fixture) },
  );
  if (officialGenerated.responses !== null) assertHttpSuiteEquivalent(`${fixture.file}/${fixture.id} 公式source/公式生成JavaScript`, officialSource, officialGenerated);

  const interpreterSetup = await prepare(directories.interpreterTrace);
  const interpreterTracePath = resolve(interpreterSetup.directory, "interpreter.jsonl");
  const interpreter = await runHttpServerSuite(
    `${fixture.file}/${fixture.id} Interpreter`,
    [env.compiler, "run", interpreterSetup.sourcePath],
    interpreterSetup.port,
    { ...fixedEnvironmentForHttp(), LNAKO_DISPATCH_TRACE: interpreterTracePath },
    interpreterSetup.directory,
  );
  const interpreterWithoutTrace = await runHttpServerSuite(
    `${fixture.file}/${fixture.id} Interpreter trace無効`,
    [env.compiler, "run", interpreterSetup.sourcePath],
    interpreterSetup.port,
    fixedEnvironmentForHttp(),
    interpreterSetup.directory,
  );
  assertHttpSuiteEquivalent(`${fixture.file}/${fixture.id} Interpreter trace`, interpreterWithoutTrace, interpreter);
  assertHttpSuiteEquivalent(`${fixture.file}/${fixture.id} 公式source/Interpreter`, officialSource, interpreterWithoutTrace);
  const interpreterTrace = await coverage_sites.readInterpreterTrace(interpreterTracePath, fixture);

  const aotSetup = await prepare(directories.aotTrace);
  const nativePath = resolve(aotSetup.directory, `${stem}${process.platform === "win32" ? ".exe" : ""}`);
  const manifestPath = resolve(aotSetup.directory, "compile-manifest.jsonl");
  const compile = coverage_process.run(
    env.compiler,
    ["build", aotSetup.sourcePath, "-o", nativePath, "-O0"],
    { ...fixedEnvironmentForHttp(), LNAKO_COMPILE_MANIFEST: manifestPath },
    aotSetup.directory,
  );
  coverage_process.assertSuccess(`${fixture.file}/${fixture.id} AOT O0コンパイル`, compile);
  const manifest = await coverage_sites.readCompileManifest(manifestPath, aotSetup.sourcePath, fixture);
  const aot = await runHttpServerSuite(
    `${fixture.file}/${fixture.id} AOT O0`,
    [nativePath],
    aotSetup.port,
    { ...fixedEnvironmentForHttp(), LNAKO_DISPATCH_TRACE: resolve(aotSetup.directory, "aot.jsonl") },
    aotSetup.directory,
  );
  const aotWithoutTrace = await runHttpServerSuite(
    `${fixture.file}/${fixture.id} AOT O0 trace無効`,
    [nativePath],
    aotSetup.port,
    fixedEnvironmentForHttp(),
    aotSetup.directory,
  );
  assertHttpSuiteEquivalent(`${fixture.file}/${fixture.id} AOT trace`, aotWithoutTrace, aot);
  assertHttpSuiteEquivalent(`${fixture.file}/${fixture.id} 公式source/AOT O0`, officialSource, aotWithoutTrace);
  const aotTrace = await coverage_sites.readAotTrace(resolve(aotSetup.directory, "aot.jsonl"), fixture, manifest.entries);
  const coverage = coverage_sites.collectSites(fixture, interpreterTrace.events, aotTrace, manifest.entries);
  const observedCommandNames = new Set(coverage.observedCommandNames);
  const associationWithoutDispatch = fixture.commands
    .filter((name) => !observedCommandNames.has(name))
    .map((name) => ({ name, catalogIds: (env.catalogByName.get(name) ?? []).map((command) => command.id) }));
  const generatedAvailable = officialGenerated.responses !== null;
  return {
    report: {
      id: fixture.id,
      file: fixture.file,
      sourceSha256,
      associatedCommandNames: [...fixture.commands],
      associationWithoutDispatch,
      observedStaticCommandNames: [...coverage.staticSuccessNames].sort(),
      observedDispatchCommandNames: [...coverage.observedCommandNames].sort(),
      dispatchExpectations: fixture.dispatchExpectations ?? [],
      officialComparison: {
        oracle: "officialSource",
        routes: ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"],
        selectedOracleEquivalent: true,
        officialGeneratedAvailable: generatedAvailable,
        officialGeneratedRouteUnavailableReason: generatedAvailable
          ? null
          : env.generatedRouteUnavailableFixtures.get(`${fixture.file}/${fixture.id}`),
        officialRoutesEquivalent: generatedAvailable && JSON.stringify(officialSource.responses) === JSON.stringify(officialGenerated.responses),
        officialSourceStderrIncludes: null,
        results: Object.fromEntries([
          ["officialSource", summarizeHttpSuite(officialSource)],
          ["officialGenerated", summarizeHttpSuite(officialGenerated)],
          ["lnakoRun", summarizeHttpSuite(interpreterWithoutTrace)],
          ["lnakoNativeO0", summarizeHttpSuite(aotWithoutTrace)],
        ]),
      },
      interpreter: {
        dispatchEventCount: interpreterTrace.events.length,
        staticSuccessSiteCount: coverage.staticSuccessSiteCount,
        expectedFailureSiteCount: coverage.expectedFailureSiteCount,
        expectedFailureDispatchCount: coverage.expectedFailureDispatchCount,
        staticSiteWithoutAotManifestCount: coverage.interpreterSitesWithoutManifest.length,
        traceSha256: interpreterTrace.rawSha256,
      },
      aot: {
        manifestEntryCount: manifest.entries.length,
        dispatchAttemptCount: aotTrace.attempts.length,
        dispatchResultCount: aotTrace.results.length,
        staticSuccessSiteCount: coverage.staticSuccessSiteCount,
        expectedFailureSiteCount: coverage.expectedFailureSiteCount,
        expectedFailureDispatchCount: coverage.expectedFailureDispatchCount,
        failedDispatchCount: aotTrace.results.filter((event) => event.success === false).length,
        traceSha256: aotTrace.rawSha256,
        compileManifestSha256: manifest.rawSha256,
      },
    },
    sites: coverage.sites,
    unresolvedSites: coverage.unresolvedSites,
  };
}


export async function reserveHttpServerPort() {
  return new Promise((resolvePort, reject) => {
    const server = http.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address !== null ? address.port : null;
      server.close((error) => error ? reject(error) : resolvePort(port));
    });
  });
}


export async function runHttpServerSuite(label, command, port, environment, cwd, options = {}) {
  const child = spawn(command[0], command.slice(1), {
    cwd,
    stdio: ["ignore", "pipe", "pipe"],
    env: environment,
    windowsHide: true,
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
  try {
    await waitForHttpServerReady(port, child, () => `stdout=${stdout}\nstderr=${stderr}`);
    const responses = [];
    for (const requestCase of httpServerDispatchRequests()) responses.push(await requestHttpServer(port, ...requestCase));
    responses.push(await requestHttpServer(port, "/shutdown", "GET"));
    const exit = await waitForHttpServerExit(child, 5000);
    if (exit.status !== 0 || exit.signal !== null) {
      throw new Error(`${label}が異常終了しました: status=${exit.status} signal=${exit.signal}\nstdout=${stdout}\nstderr=${stderr}`);
    }
    return { status: exit.status, signal: exit.signal, stdout, stderr, responses: responses.map(normalizeHttpServerResponse) };
  } catch (error) {
    if (options.allowUnavailable === true && child.exitCode !== null && child.exitCode !== 0) {
      return { status: child.exitCode, signal: child.signalCode, stdout, stderr, responses: null };
    }
    if (child.exitCode === null) await terminateHttpServerChild(child);
    throw new Error(`${label}に失敗しました: ${error.message}\nstdout=${stdout}\nstderr=${stderr}`, { cause: error });
  } finally {
    if (child.exitCode === null) await terminateHttpServerChild(child);
  }
}


export function httpServerDispatchRequests() {
  return [
    ["/echo?probe=1", "GET"],
    ["/headers", "GET"],
    ["/redirect", "GET"],
    ["/route/long/test", "GET"],
    ["/api2", "GET"],
    ["/static/hello.txt?x=1", "GET"],
  ];
}


export async function waitForHttpServerReady(port, child, diagnostics) {
  for (let attempt = 0; attempt < 250; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`HTTPサーバが起動前に終了しました: ${child.exitCode}\n${diagnostics()}`);
    if (diagnostics().includes(`ポート番号(${port})で監視開始`) || diagnostics().includes("ポート番号(0)で監視開始")) return;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 20));
  }
  throw new Error(`HTTPサーバが5秒以内に起動しませんでした\n${diagnostics()}`);
}


export async function waitForHttpServerExit(child, timeoutMs) {
  if (child.exitCode === null && !(await waitForHttpServerChildExit(child, timeoutMs))) await terminateHttpServerChild(child);
  return { status: child.exitCode, signal: child.signalCode };
}


export function waitForHttpServerChildExit(child, timeoutMs) {
  if (child.exitCode !== null) return Promise.resolve(true);
  return new Promise((resolveExit) => {
    let timer = null;
    const onExit = () => {
      if (timer !== null) clearTimeout(timer);
      resolveExit(true);
    };
    child.once("exit", onExit);
    timer = setTimeout(() => {
      child.removeListener("exit", onExit);
      resolveExit(child.exitCode !== null);
    }, timeoutMs);
  });
}


export async function terminateHttpServerChild(child) {
  if (child.exitCode !== null) return;
  child.kill("SIGTERM");
  if (await waitForHttpServerChildExit(child, 1500)) return;
  child.kill("SIGKILL");
  if (!(await waitForHttpServerChildExit(child, 1500))) throw new Error("HTTPサーバ子プロセスを終了できませんでした");
}


export async function requestHttpServer(port, path, method) {
  return new Promise((resolveResponse, reject) => {
    const request = http.request({ hostname: "127.0.0.1", port, path, method }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolveResponse({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    request.setTimeout(5000, () => request.destroy(new Error("HTTP request timed out")));
    request.on("error", reject);
    request.end();
  });
}


export function normalizeHttpServerResponse(response) {
  return {
    status: response.status,
    contentType: response.headers["content-type"] ?? "",
    location: response.headers.location ?? "",
    custom: response.headers["x-lnako"] ?? "",
    body: response.body.toString("utf8"),
  };
}


export function summarizeHttpSuite(result) {
  return {
    status: result.status,
    signal: result.signal,
    stdoutSha256: evidence_common.sha256(evidence_common.normalizeLineEndings(result.stdout)),
    stderrSha256: evidence_common.sha256(evidence_common.normalizeLineEndings(result.stderr)),
    responseCount: result.responses === null ? 0 : result.responses.length,
    responseSha256: result.responses === null ? null : evidence_common.sha256(JSON.stringify(result.responses)),
  };
}


export function assertHttpSuiteEquivalent(label, left, right) {
  if (left.status !== right.status || left.signal !== right.signal || JSON.stringify(left.responses) !== JSON.stringify(right.responses)) {
    throw new Error(`${label}でHTTP応答または終了結果が一致しません: left=${JSON.stringify({ status: left.status, signal: left.signal, responses: left.responses })} right=${JSON.stringify({ status: right.status, signal: right.signal, responses: right.responses })}`);
  }
}

