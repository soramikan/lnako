import { readFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { coverageEnv as env } from "./coverage_env.mjs";
import * as evidence_common from "./evidence_common.mjs";

export function parseShardInteger(argument, value) {
  if (value === undefined || !/^\d+$/.test(value)) throw new Error(`${argument}には0以上の整数を指定してください`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${argument}の値が大きすぎます`);
  return parsed;
}


export function selectFixtureShard(fixtures, shard) {
  if (shard.index === null) return fixtures;
  const bins = Array.from({ length: shard.count }, (_, index) => ({ index, weight: 0, fixtures: [] }));
  const weightedFixtures = fixtures
    .map((fixture, index) => ({ fixture, index, weight: fixtureWeight(fixture) }))
    .sort((left, right) => right.weight - left.weight || left.index - right.index);
  for (const item of weightedFixtures) {
    const target = bins.reduce((left, right) =>
      right.weight < left.weight || (right.weight === left.weight && right.index < left.index) ? right : left);
    target.fixtures.push(item);
    target.weight += item.weight;
  }
  return bins[shard.index].fixtures
    .sort((left, right) => left.index - right.index)
    .map((item) => item.fixture);
}


export function fixtureWeight(fixture) {
  const sourceWeight = fixture.source.length;
  const commandWeight = (fixture.commands?.length ?? 0) * 8;
  return Math.max(1, sourceWeight) + commandWeight;
}


export async function loadSelectedFixtures() {
  const specifications = [
    { file: "plugin-system-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "system-runtime-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "standard-plugin-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "supplemental-plugin-cases.json", selection: (testCase) => testCase.commands?.length > 0 && testCase.expectedFailure !== true },
    { file: "node-file-cases.json", selection: (testCase) => testCase.aot === true && testCase.commands?.length > 0 && testCase.expectError !== true },
    { file: "node-native-cases.json", selection: (testCase) => testCase.aot === true && testCase.commands?.length > 0 && testCase.expectError !== true },
    { file: "node-http-cases.json", selection: (testCase) => ["plugin-node-http-callbacks", "plugin-node-http-onerror", "plugin-node-http-options-and-promises", "plugin-node-http-async-values", "plugin-node-http-discord", "plugin-node-http-discord-file", "plugin-node-http-discord-failure", "plugin-node-http-line-message-discontinued-captured", "plugin-node-http-line-image-discontinued-captured"].includes(testCase.id) },
    { file: "http-server-dispatch-cases.json", selection: (testCase) => testCase.id === "plugin-httpserver-dispatch" },
    { file: "plugin-route-cases.json", selection: (testCase) => testCase.commands?.length > 0 },
    { file: "native-cases.json", selection: (testCase) =>
      env.arguments_.includeNative
        ? testCase.commands?.length > 0 && testCase.expectedFailure !== true
        : testCase.id === "native-cut-commands" || testCase.id === "native-system-error-raise" || testCase.id === "native-system-debug" || testCase.id === "native-system-dynamic-execution" ||
          ["native-node-stdin-all", "native-node-stdin-lines", "native-node-stdin-callback", "native-node-network-addresses"].includes(testCase.id) },
  ];
  const fixtures = [];
  const fixtureKeys = new Set();
  for (const specification of specifications) {
    const path = resolve(env.root, "tests/oracle", specification.file);
    const parsed = JSON.parse(await readFile(path, "utf8"));
    const cases = Array.isArray(parsed) ? parsed : [parsed];
    if (!Array.isArray(cases)) throw new Error(`fixtureが配列ではありません: ${specification.file}`);
    for (const testCase of cases.filter(specification.selection)) {
      validateFixture(testCase, specification.file);
      if (env.excludedFixtures.has(`${specification.file}/${testCase.id}`)) continue;
      const fixtureKey = `${specification.file}/${testCase.id}`;
      if (fixtureKeys.has(fixtureKey)) throw new Error(`dispatch coverageのfixtureが重複しています: ${fixtureKey}`);
      fixtureKeys.add(fixtureKey);
      fixtures.push({ file: specification.file, ...testCase });
    }
  }
  const expectedFixtureCount = env.arguments_.includeNative ? 227 : 56;
  if (fixtures.length !== expectedFixtureCount) throw new Error(`dispatch coverageのfixture数が想定外です: ${fixtures.length}`);
  return fixtures;
}


export function validateFixture(testCase, file) {
  if (typeof testCase.id !== "string" || testCase.id.length === 0 || typeof testCase.source !== "string") {
    throw new Error(`fixtureのid/sourceが不正です: ${file}`);
  }
  if (!Array.isArray(testCase.commands) || testCase.commands.length === 0 ||
      testCase.commands.some((name) => typeof name !== "string" || name.length === 0 || !env.catalogByName.has(name)) ||
      new Set(testCase.commands).size !== testCase.commands.length) {
    throw new Error(`fixtureのcommandsが標準527命令と一致しません: ${file}/${testCase.id}`);
  }
  if (testCase.sourceFileName !== undefined &&
      (typeof testCase.sourceFileName !== "string" || testCase.sourceFileName.length === 0 || isAbsolute(testCase.sourceFileName) ||
        testCase.sourceFileName.includes("/") || testCase.sourceFileName.includes("\\") || testCase.sourceFileName === "." || testCase.sourceFileName === "..")) {
    throw new Error(`fixtureのsourceFileNameが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.stdin !== undefined && typeof testCase.stdin !== "string") throw new Error(`fixtureのstdinが不正です: ${file}/${testCase.id}`);
  if (testCase.networkTopology !== undefined && testCase.networkTopology !== "synthetic-v1") {
    throw new Error(`fixtureのnetworkTopologyが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.safeExternalMock !== undefined && typeof testCase.safeExternalMock !== "boolean") {
    throw new Error(`fixtureのsafeExternalMockが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.archiveHelper !== undefined && typeof testCase.archiveHelper !== "boolean") {
    throw new Error(`fixtureのarchiveHelperが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.httpServer !== undefined && typeof testCase.httpServer !== "boolean") {
    throw new Error(`fixtureのhttpServerが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.httpServer === true && testCase.aot !== true) {
    throw new Error(`httpServer fixtureはAOT対象である必要があります: ${file}/${testCase.id}`);
  }
  if (testCase.pluginRoute !== undefined && !["plugin_system", "plugin_node", "plugin_datetime"].includes(testCase.pluginRoute)) {
    throw new Error(`fixtureのpluginRouteが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.expectedDispatchRoute !== undefined &&
      (typeof testCase.expectedDispatchRoute !== "string" || testCase.expectedDispatchRoute !== "plugin_datetime" || testCase.pluginRoute !== "plugin_datetime")) {
    throw new Error(`fixtureのexpectedDispatchRouteが不正です: ${file}/${testCase.id}`);
  }
  if (testCase.officialSourceStderrIncludes !== undefined &&
      (testCase.pluginRoute !== "plugin_datetime" || typeof testCase.officialSourceStderrIncludes !== "string" || testCase.officialSourceStderrIncludes.length === 0)) {
    throw new Error(`officialSourceStderrIncludesはplugin_datetimeの空でない文字列で指定してください: ${file}/${testCase.id}`);
  }
  if (testCase.officialSourceStdoutIncludes !== undefined &&
      (testCase.oracle !== "official-generated" || typeof testCase.officialSourceStdoutIncludes !== "string" || testCase.officialSourceStdoutIncludes.length === 0)) {
    throw new Error(`officialSourceStdoutIncludesはoracle=official-generatedの空でない文字列で指定してください: ${file}/${testCase.id}`);
  }
  if (testCase.catalogIds !== undefined) {
    if (testCase.catalogIds === null || typeof testCase.catalogIds !== "object" || Array.isArray(testCase.catalogIds)) {
      throw new Error(`fixtureのcatalogIdsが不正です: ${file}/${testCase.id}`);
    }
    const catalogIds = new Set();
    for (const [name, catalogId] of Object.entries(testCase.catalogIds)) {
      const command = env.catalog.commands.find((candidate) => candidate.id === catalogId);
      if (!testCase.commands.includes(name) || typeof catalogId !== "string" || command === undefined || command.name !== name || catalogIds.has(catalogId)) {
        throw new Error(`fixtureのcatalogIdsがcommands/catalogと一致しません: ${file}/${testCase.id}/${name}`);
      }
      catalogIds.add(catalogId);
    }
  }
  if (testCase.dispatchExpectations !== undefined) {
    if (!Array.isArray(testCase.dispatchExpectations) || testCase.dispatchExpectations.length === 0) {
      throw new Error(`fixtureのdispatchExpectationsが不正です: ${file}/${testCase.id}`);
    }
    const expectedCommands = new Set();
    for (const expectation of testCase.dispatchExpectations) {
      if (expectation === null || typeof expectation !== "object" || Array.isArray(expectation) ||
          Object.keys(expectation).some((key) => !new Set(["command", "result", "count", "platforms"]).has(key)) ||
          typeof expectation.command !== "string" || !testCase.commands.includes(expectation.command) ||
          expectedCommands.has(expectation.command) || expectation.result !== "failure" ||
          !Number.isSafeInteger(expectation.count) || expectation.count < 1 || !evidence_common.validDispatchExpectationPlatforms(expectation.platforms)) {
        throw new Error(`fixtureのdispatchExpectationsが不正です: ${file}/${testCase.id}`);
      }
      expectedCommands.add(expectation.command);
    }
  }
  if (testCase.files !== undefined) {
    if (testCase.files === null || typeof testCase.files !== "object" || Array.isArray(testCase.files)) {
      throw new Error(`fixtureのfilesが不正です: ${file}/${testCase.id}`);
    }
    for (const [name, contents] of Object.entries(testCase.files)) {
      if (name.length === 0 || name === "." || name === ".." || name.includes("/") || name.includes("\\") ||
          typeof contents !== "string") {
        throw new Error(`fixtureのfilesが不正です: ${file}/${testCase.id}/${name}`);
      }
    }
  }
}


export function requiresIsolatedFixtureState(fixture) {
  // Path-observing fixtures must see the same cwd and source path on every
  // route. Only fixtures that create or mutate shared files need per-route
  // directories; each process already has isolated process-local state.
  if (Object.keys(fixture.files ?? {}).length > 0) return true;
  return fixture.commands.some((name) => env.fixtureStateMutationCommands.has(name));
}


export function isKnownGeneratedRouteUnavailable(fixture) {
  // Some fixtures use official plugin modules or the system async host. The
  // standalone generated file does not always carry the CLI's host/plugin
  // registration, so an execution failure on these explicit route families
  // is reported as unavailable. The official source CLI remains the oracle;
  // this must never be mistaken for generated-JavaScript coverage.
  return env.generatedRouteUnavailableFixtures.has(`${fixture.file}/${fixture.id}`);
}


export function fixedEnvironment() {
  const environment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    LNAKO_TEST_NOW_MS: "1735689845678",
    LNAKO_TEST_MONOTONIC_MS: "123.5",
    LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
    LNAKO_NODE_TEST: "fixed-value",
    NAKO3_DISABLE_NEW_CONSOLE: "1",
  };
  const nodeDirectory = dirname(process.execPath);
  const pathSeparator = process.platform === "win32" ? ";" : ":";
  if (process.platform === "win32") {
    // Windows runners commonly expose the search path as `Path`, not `PATH`.
    // Preserve that key so System32 remains available for cmd.exe and other
    // host commands used by the Node process fixtures.
    environment.Path = `${nodeDirectory}${pathSeparator}${environment.Path ?? environment.PATH ?? ""}`;
    delete environment.PATH;
  } else {
    environment.PATH = `${nodeDirectory}${pathSeparator}${environment.PATH ?? ""}`;
  }
  delete environment.LNAKO_DISPATCH_TRACE;
  delete environment.LNAKO_COMPILE_MANIFEST;
  return environment;
}


export function replacePluginPlaceholders(source, fixtureDirectory, loopbackBase, fixture, extraReplacements = {}) {
  const replacements = {
    "${PLUGIN_CANIUSE}": relative(fixtureDirectory, resolve(env.oracleRoot, "src/plugin_caniuse.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_KANSUJI}": relative(fixtureDirectory, resolve(env.oracleRoot, "src/plugin_kansuji.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_MARKUP}": relative(fixtureDirectory, resolve(env.oracleRoot, "src/plugin_markup.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_CSV}": relative(fixtureDirectory, resolve(env.oracleRoot, "core/src/plugin_csv.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_TOML}": relative(fixtureDirectory, resolve(env.oracleRoot, "core/src/plugin_toml.mjs")).replaceAll("\\", "/"),
    "${PLUGIN_DATETIME}": relative(fixtureDirectory, resolve(env.oracleRoot, "src/plugin_datetime.mjs")).replaceAll("\\", "/"),
    "${PLUGIN}": relative(fixtureDirectory, resolve(env.oracleRoot, "src/plugin_httpserver.mjs")).replaceAll("\\", "/"),
  };
  let replaced = Object.entries(replacements).reduce((result, [placeholder, path]) => result.replaceAll(placeholder, path), source);
  for (const [placeholder, value] of Object.entries(extraReplacements)) {
    replaced = replaced.replaceAll(placeholder, value);
  }
  if (replaced.includes("${BASE}")) {
    if (loopbackBase === null) throw new Error("HTTP fixtureにloopback baseがありません");
    replaced = replaced.replaceAll("${BASE}", loopbackBase);
  }
  if (replaced.includes("${FILE}")) {
    const fileNames = Object.keys(fixture.files ?? {});
    if (fileNames.length !== 1) throw new Error(`${fixture.id}の\${FILE}にはfixture.filesを1件だけ指定してください`);
    replaced = replaced.replaceAll("${FILE}", resolve(fixtureDirectory, fileNames[0]).replaceAll("\\", "/"));
  }
  return replaced;
}

