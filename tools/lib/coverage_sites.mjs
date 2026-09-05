import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { coverageEnv as env } from "./coverage_env.mjs";
import * as evidence_common from "./evidence_common.mjs";

export function readJsonLines(text, label) {
  if (!text.endsWith("\n")) throw new Error(`${label}が改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${label} ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error(`${label}にdispatchと終端イベントがありません`);
  for (const [index, record] of records.entries()) {
    if (record.schema !== 2 || record.seq !== index) throw new Error(`${label} metadataが不正です: ${JSON.stringify(record)}`);
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(record, forbidden)) throw new Error(`${label}に禁止fieldがあります: ${forbidden}`);
    }
  }
  const end = records.at(-1);
  if (end.phase !== "trace-end" || end.dropped !== 0) throw new Error(`${label}が正常に完結していません`);
  return { records, rawSha256: evidence_common.sha256(text) };
}


export async function readInterpreterTrace(path, fixture) {
  const parsed = readJsonLines(await readFile(path, "utf8"), `${fixture.id} Interpreter trace`);
  if (parsed.records.some((event) => event.engine !== "interpreter")) throw new Error(`${fixture.id} Interpreter traceのengineが不正です`);
  const events = parsed.records.slice(0, -1);
  if (events.some((event) => event.phase !== "dispatch-result" || typeof event.command !== "string" || typeof event.route !== "string" ||
      (event.result !== "success" && event.result !== "failure"))) {
    throw new Error(`${fixture.id} Interpreter traceのdispatch metadataが不正です`);
  }
  for (const event of events) assertSiteId(event.siteId, `${fixture.id} Interpreter trace`);
  if (events.length === 0) throw new Error(`${fixture.id} Interpreter traceにdispatchがありません`);
  return { events, rawSha256: parsed.rawSha256 };
}


export async function readAotTrace(path, fixture, manifestEntries) {
  const parsed = readJsonLines(await readFile(path, "utf8"), `${fixture.id} AOT trace`);
  if (parsed.records.some((event) => event.engine !== "aot")) throw new Error(`${fixture.id} AOT traceのengineが不正です`);
  const events = parsed.records.slice(0, -1);
  const attempts = events.filter((event) => event.phase === "dispatch-attempt");
  const results = events.filter((event) => event.phase === "dispatch-result");
  if (attempts.length === 0 || attempts.length !== results.length) throw new Error(`${fixture.id} AOT traceのattempt/result件数が不一致です`);
  const manifestBySite = new Map(manifestEntries.map((entry) => [entry.siteId, entry]));
  const attemptsByCall = new Map();
  for (const attempt of attempts) {
    assertAotEvent(attempt, `${fixture.id} AOT attempt`, true);
    if (attempt.callId === null || !Number.isSafeInteger(attempt.callId) || attemptsByCall.has(attempt.callId)) {
      throw new Error(`${fixture.id} AOT attemptのcallIdが不正です`);
    }
    if (attempt.siteId !== null) {
      const manifest = manifestBySite.get(attempt.siteId);
      if (manifest === undefined || manifest.canonicalOpcode !== attempt.command || manifest.route !== attempt.route || manifest.opcode !== attempt.opcode) {
        throw new Error(`${fixture.id} AOT traceとmanifestのdispatchが一致しません: ${JSON.stringify({ attempt, manifest })}`);
      }
    }
    attemptsByCall.set(attempt.callId, attempt);
  }
  const resultsByCall = new Map();
  for (const result of results) {
    assertAotEvent(result, `${fixture.id} AOT result`, false);
    if (!Number.isSafeInteger(result.callId) || resultsByCall.has(result.callId) || typeof result.success !== "boolean") {
      throw new Error(`${fixture.id} AOT resultのcallId/successが不正です`);
    }
    const attempt = attemptsByCall.get(result.callId);
    if (attempt === undefined || result.siteId !== attempt.siteId || result.opcode !== attempt.opcode || result.command !== attempt.command || result.route !== attempt.route) {
      throw new Error(`${fixture.id} AOT traceのattempt/result対応が不正です`);
    }
    resultsByCall.set(result.callId, result);
  }
  if (resultsByCall.size !== attemptsByCall.size) throw new Error(`${fixture.id} AOT traceに対応しないattemptがあります`);
  const interpreterSiteIds = new Set();
  return { events, attempts, results, attemptsByCall, resultsByCall, manifestBySite, rawSha256: parsed.rawSha256, interpreterSiteIds };
}


export function assertAotEvent(event, label, requireNameSource) {
  if (event.engine !== "aot" || (event.phase !== "dispatch-attempt" && event.phase !== "dispatch-result") ||
      !Number.isInteger(event.opcode) || event.opcode < 0 || event.opcode > 0xffff || typeof event.command !== "string" ||
      typeof event.route !== "string" || (requireNameSource && event.name_source !== "canonical-opcode")) {
    throw new Error(`${label}のdispatch metadataが不正です`);
  }
  assertSiteId(event.siteId, label);
}


export function assertSiteId(siteId, label) {
  if (siteId !== null && (typeof siteId !== "string" || !/^0x[0-9a-f]{16}$/.test(siteId))) throw new Error(`${label}のsiteIdが不正です`);
}


export async function readCompileManifest(path, sourcePath, fixture) {
  const text = await readFile(path, "utf8");
  if (!text.endsWith("\n")) throw new Error(`${fixture.id} AOT compile manifestが改行で完結していません`);
  const records = text.trimEnd().split("\n").map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      throw new Error(`${fixture.id} AOT compile manifest ${index + 1}行目がJSONではありません: ${error.message}`);
    }
  });
  if (records.length < 2) throw new Error(`${fixture.id} AOT compile manifestにheaderと完了recordがありません`);
  for (const record of records) {
    for (const forbidden of ["arguments", "values", "value", "pointer", "address"]) {
      if (Object.hasOwn(record, forbidden)) throw new Error(`${fixture.id} AOT compile manifestに禁止fieldがあります: ${forbidden}`);
    }
  }
  const parsed = { records, rawSha256: evidence_common.sha256(text) };
  const header = parsed.records[0];
  const complete = parsed.records.at(-1);
  const entries = parsed.records.slice(1, -1);
  const schema = "lnako.aot.builtin-manifest.v1";
  if (header.schema !== schema || header.phase !== "pre-opt" || header.sourcePath !== sourcePath || header.siteIdEncoding !== "u64-hex16" ||
      complete.schema !== schema || complete.phase !== "pre-opt" || complete.kind !== "complete" || complete.complete !== true || complete.entryCount !== entries.length) {
    throw new Error(`${fixture.id} AOT compile manifest header/completeが不正です`);
  }
  const siteIds = new Set();
  const activeExpectations = activeDispatchExpectations(fixture);
  const expectedFailureCommands = new Set(activeExpectations.map((expectation) => expectation.command));
  for (const entry of entries) {
    const isBuiltinDispatch = entry.kind === "builtin-dispatch";
    const isThrowDispatch = entry.kind === "throw-dispatch" && entry.sourceName === "エラー発生" &&
      entry.canonicalOpcode === "throw_statement" && entry.route === "throw" && entry.opcode === env.throwStatementOpcode &&
      expectedFailureCommands.has(entry.sourceName);
    if (entry.schema !== schema || entry.phase !== "pre-opt" || (!isBuiltinDispatch && !isThrowDispatch) ||
        ![entry.sourceName, entry.canonicalOpcode, entry.route, entry.function].every((value) => typeof value === "string" && value.length > 0) ||
        !Number.isInteger(entry.opcode) || entry.opcode < 0 || entry.opcode > 0xffff || typeof entry.siteId !== "string" ||
        !/^0x[0-9a-f]{16}$/.test(entry.siteId) || siteIds.has(entry.siteId)) {
      throw new Error(`${fixture.id} AOT compile manifest entryが不正です`);
    }
    if (entry.source === null || !Number.isInteger(entry.source.line) || entry.source.line < 1 || !Number.isInteger(entry.source.column) || entry.source.column < 1 ||
        !Number.isInteger(entry.source.sourceStart) || !Number.isInteger(entry.source.sourceEnd) || entry.source.sourceStart < 0 || entry.source.sourceEnd < entry.source.sourceStart) {
      throw new Error(`${fixture.id} AOT compile manifestのsource位置が不正です`);
    }
    siteIds.add(entry.siteId);
  }
  return { entries, rawSha256: parsed.rawSha256 };
}


export function collectSites(fixture, interpreterEvents, aotTrace, manifestEntries) {
  const manifestSiteIds = new Set(manifestEntries.map((entry) => entry.siteId));
  const staticInterpreterEvents = interpreterEvents.filter((event) => event.siteId !== null);
  const interpreterSitesWithoutManifest = staticInterpreterEvents
    .filter((event) => !manifestSiteIds.has(event.siteId))
    .map((event) => ({ siteId: event.siteId, command: event.command, route: event.route, result: event.result }));
  const sites = [];
  const unresolvedSites = [];
  const staticSuccessNames = new Set();
  const observedCommandNames = new Set();
  const expectedFailureByCommand = new Map(activeDispatchExpectations(fixture).map((expectation) => [expectation.command, expectation]));
  const expectedFailureCounts = new Map();
  let staticSuccessSiteCount = 0;
  let expectedFailureSiteCount = 0;
  let expectedFailureDispatchCount = 0;
  for (const entry of manifestEntries) {
    const expectedFailure = expectedFailureByCommand.get(entry.sourceName);
    if ((entry.kind === "throw-dispatch" && expectedFailure === undefined) ||
        (expectedFailure !== undefined && entry.kind !== "builtin-dispatch" && entry.kind !== "throw-dispatch")) {
      throw new Error(`${fixture.id} 期待失敗dispatchの宣言が不一致です: ${entry.sourceName}/${entry.siteId}`);
    }
    if (expectedFailure !== undefined) {
      const failedAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === false);
      const successfulAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === true);
      const failedInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "failure");
      const successfulInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "success");
      if (successfulAot.length > 0 || successfulInterpreter.length > 0) {
        throw new Error(`${fixture.id} 明示した期待失敗siteに成功dispatchがあります: ${entry.sourceName}/${entry.siteId}`);
      }
      if (failedAot.length === 0 || failedInterpreter.length === 0 || failedAot.length !== failedInterpreter.length) {
        throw new Error(`${fixture.id} 明示した期待失敗siteのInterpreter/AOT件数が一致しません: ${entry.sourceName}/${entry.siteId}`);
      }
      expectedFailureSiteCount += 1;
      expectedFailureDispatchCount += failedAot.length;
      expectedFailureCounts.set(entry.sourceName, (expectedFailureCounts.get(entry.sourceName) ?? 0) + failedAot.length);
      observedCommandNames.add(entry.sourceName);
      const routes = [...new Set(failedInterpreter.map((event) => event.route))].sort();
      const common = {
        fixtureId: fixture.id,
        file: fixture.file,
        siteId: entry.siteId,
        sourceName: entry.sourceName,
        canonicalOpcode: entry.canonicalOpcode,
        opcode: entry.opcode,
        route: entry.route,
        runtimeRoutes: [...new Set(failedAot.map((event) => event.route))].sort(),
        interpreterRoutes: routes,
        interpreterCount: failedInterpreter.length,
        aotCount: failedAot.length,
        result: "failure",
      };
      assertExpectedDispatchRoute(fixture, common);
      const resolution = resolveCatalogCommand(fixture, entry.sourceName);
      if (resolution === null) {
        unresolvedSites.push({ ...common, candidateCatalogIds: (env.catalogByName.get(entry.sourceName) ?? []).map((command) => command.id) });
        continue;
      }
      sites.push({
        ...common,
        catalogId: resolution.command.id,
        name: resolution.command.name,
        plugin: resolution.command.plugin,
        catalogStatus: resolution.command.status,
        resolution: resolution.reason,
        selectedOracleEquivalent: true,
      });
      continue;
    }
    const successfulAot = aotTrace.results.filter((event) => event.siteId === entry.siteId && event.success === true);
    if (successfulAot.length === 0) continue;
    const successfulInterpreter = interpreterEvents.filter((event) => event.siteId === entry.siteId && event.command === entry.sourceName && event.result === "success");
    if (successfulInterpreter.length === 0) throw new Error(`${fixture.id} AOT成功siteに対応するInterpreter成功eventがありません`);
    staticSuccessSiteCount += 1;
    staticSuccessNames.add(entry.sourceName);
    observedCommandNames.add(entry.sourceName);
    const routes = [...new Set(successfulInterpreter.map((event) => event.route))].sort();
    const resolution = resolveCatalogCommand(fixture, entry.sourceName);
    const common = {
      fixtureId: fixture.id,
      file: fixture.file,
      siteId: entry.siteId,
      sourceName: entry.sourceName,
      canonicalOpcode: entry.canonicalOpcode,
      opcode: entry.opcode,
      route: entry.route,
      runtimeRoutes: [...new Set(successfulAot.map((event) => event.route))].sort(),
      interpreterRoutes: routes,
      interpreterCount: successfulInterpreter.length,
      aotCount: successfulAot.length,
      result: "success",
    };
    assertExpectedDispatchRoute(fixture, common);
    if (resolution === null) {
      unresolvedSites.push({ ...common, candidateCatalogIds: (env.catalogByName.get(entry.sourceName) ?? []).map((command) => command.id) });
      continue;
    }
    sites.push({
      ...common,
      catalogId: resolution.command.id,
      name: resolution.command.name,
      plugin: resolution.command.plugin,
      catalogStatus: resolution.command.status,
      resolution: resolution.reason,
      selectedOracleEquivalent: true,
    });
  }
  for (const expectation of activeDispatchExpectations(fixture)) {
    const observedCount = expectedFailureCounts.get(expectation.command) ?? 0;
    if (observedCount !== expectation.count) {
      throw new Error(`${fixture.id} 明示した期待失敗dispatch件数が一致しません: ${expectation.command} expected=${expectation.count} actual=${observedCount}`);
    }
  }
  return {
    sites,
    unresolvedSites,
    staticSuccessNames,
    observedCommandNames,
    staticSuccessSiteCount,
    expectedFailureSiteCount,
    expectedFailureDispatchCount,
    interpreterSitesWithoutManifest,
  };
}


export function assertExpectedDispatchRoute(fixture, site) {
  if (fixture.expectedDispatchRoute === undefined || !fixture.commands.includes(site.sourceName)) return;
  const expected = fixture.expectedDispatchRoute;
  if (site.route !== expected || JSON.stringify(site.runtimeRoutes) !== JSON.stringify([expected]) ||
      JSON.stringify(site.interpreterRoutes) !== JSON.stringify([expected])) {
    throw new Error(`${fixture.id}のdispatch route identityが不一致です: ${JSON.stringify({
      sourceName: site.sourceName,
      expected,
      route: site.route,
      runtimeRoutes: site.runtimeRoutes,
      interpreterRoutes: site.interpreterRoutes,
    })}`);
  }
}


export function activeDispatchExpectations(fixture, platform = process.platform) {
  return (fixture.dispatchExpectations ?? []).filter((expectation) =>
    expectation.platforms === undefined || expectation.platforms.includes(platform));
}


export function resolveCatalogCommand(fixture, name) {
  const configuredId = fixture.catalogIds?.[name];
  if (configuredId !== undefined) {
    const command = env.catalog.commands.find((candidate) => candidate.id === configuredId);
    if (command === undefined || command.name !== name) throw new Error(`${fixture.id}のcatalogIdsが標準カタログと一致しません: ${name}/${configuredId}`);
    return { command, reason: "explicit-catalog-id" };
  }
  const candidates = env.catalogByName.get(name) ?? [];
  if (candidates.length === 1) return { command: candidates[0], reason: "unique-name" };
  return null;
}


export function createReport({ fixtureReports, sites, unresolvedSites, oracle, git }) {
  const nativeCommands = env.catalog.commands.filter((command) => command.status === "native");
  const nativeIds = new Set(nativeCommands.map((command) => command.id));
  const nativeNames = new Set(nativeCommands.map((command) => command.name));
  const observedNativeSites = sites.filter((site) => nativeIds.has(site.catalogId));
  const observedNativeIds = new Set(observedNativeSites.map((site) => site.catalogId));
  const observedNativeNames = new Set(observedNativeSites.map((site) => site.name));
  const unresolvedByName = Map.groupBy(unresolvedSites, (site) => site.sourceName);
  const associationWithoutDispatch = fixtureReports.flatMap((fixture) => fixture.associationWithoutDispatch.map((association) => ({ fixtureId: fixture.id, file: fixture.file, ...association })));
  return {
    schema: "lnako.dispatch-coverage.v1",
    kind: env.arguments_.fixtureShard.index === null
      ? "sampled-unattested-dispatch-audit"
      : "sampled-unattested-dispatch-audit-shard",
    baseline: { tag: env.baseline.tag, commit: env.baseline.commit },
    scope: {
      catalogEntries: env.catalog.commands.length,
      nativeEntries: nativeCommands.length,
      nativeUniqueNames: nativeNames.size,
      fixtureSelection: env.arguments_.includeNative
        ? "the default command-bearing selection plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and all native-cases command-bearing fixtures, excluding explicit error/termination/host gaps"
        : "plugin-system/system-runtime/standard-plugin/supplemental-plugin command-bearing success fixtures plus the nine node-http callback/Promise/value/Discord/LINE-discontinued fixtures, one HTTP-server dispatch fixture, seven explicit plugin-route fixtures, and native-cut-commands, excluding explicit AOT gaps",
      fixtureCount: fixtureReports.length,
      ...(env.arguments_.fixtureShard.index === null
        ? {}
        : {
            fixtureShard: {
              mode: "weighted-source-command",
              index: env.arguments_.fixtureShard.index,
              count: env.arguments_.fixtureShard.count,
              totalFixtureCount: env.fixturePool.length,
              selectedFixtureCount: fixtureReports.length,
            },
          }),
      excludedFixtures: [...env.excludedFixtures].map(([key, reason]) => ({ key, reason })),
      commandAssociationIsNotExecutionEvidence: true,
    },
    provenance: {
      environment: { platform: process.platform, arch: process.arch, node: process.version },
      oracle,
      lnako: {
        binarySha256: evidence_common.sha256FileSync(env.compiler),
        commit: git.commit,
        dirty: git.dirty,
      },
      auditScriptSha256: evidence_common.sha256FileSync(resolve(env.root, "tools/check_dispatch_coverage.mjs")),
    },
    coverage: {
      unambiguousObservedNativeEntries: observedNativeIds.size,
      unambiguousObservedNativeUniqueNames: observedNativeNames.size,
      unambiguousObservedNativeEntryRatio: observedNativeIds.size / nativeCommands.length,
      unambiguousObservedNativeUniqueNameRatio: observedNativeNames.size / nativeNames.size,
      unobservedNativeEntryIds: nativeCommands.filter((command) => !observedNativeIds.has(command.id)).map((command) => command.id),
      unobservedNativeNames: nativeCommands.filter((command) => !observedNativeNames.has(command.name)).map((command) => command.name).filter((name, index, values) => values.indexOf(name) === index),
      unresolvedObservedSites: unresolvedSites,
      unresolvedObservedNames: [...unresolvedByName.keys()].sort(),
      associationWithoutDispatchCount: associationWithoutDispatch.length,
      associationWithoutDispatch,
    },
    fixtures: fixtureReports,
    sites: sites.sort(compareSites),
  };
}


export function compareSites(left, right) {
  return left.fixtureId.localeCompare(right.fixtureId) || left.siteId.localeCompare(right.siteId);
}

