import { constants as fsConstants } from "node:fs";
import { access, link, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { execFile, spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/native-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const artifactPath = parseArtifactPath();
if (artifactPath !== null) await ensureArtifactDestinationFree(artifactPath);
const artifactBaseline = artifactPath === null ? null : JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8")).nadesiko3;
const artifactToolchain = artifactPath === null ? null : JSON.parse(await readFile(resolve(root, "toolchain.lock.json"), "utf8"));
const artifactGitState = artifactPath === null ? null : gitState();
const artifactCompareScriptSha256 = artifactPath === null ? null : sha256(await readFile(resolve(root, "tools/compare_native_oracle.mjs")));
const artifactOracleIdentity = artifactPath === null ? null : await readOracleIdentity(oracleRoot, officialCli, artifactBaseline);
const temporary = await mkdtemp(join(tmpdir(), "lnako-native-"));
const maxBuffer = 16 * 1024 * 1024;
const knownCaseFields = new Set(["id", "source", "oracle", "stderrIncludes"]);
const routeNames = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0", "lnakoNativeO1", "lnakoNativeO2", "lnakoNativeO3"];
let artifactLnakoBinarySha256 = null;

try {
  buildLnako();
  if (artifactPath !== null) artifactLnakoBinarySha256 = sha256(await readFile(executable));
  let failures = 0;
  let generatedOracleCases = 0;
  let sourceOracleCases = 0;
  for (const testCase of cases) {
    for (const field of Object.keys(testCase)) {
      if (!knownCaseFields.has(field)) throw new Error(`未知のAOTオラクルfixtureフィールドです: ${testCase.id}: ${field}`);
    }
    if (testCase.oracle !== undefined && testCase.oracle !== "official-source" && testCase.oracle !== "official-generated") {
      throw new Error(`未知のAOTオラクル指定です: ${testCase.id}: ${testCase.oracle}`);
    }
    if (testCase.stderrIncludes !== undefined && (typeof testCase.stderrIncludes !== "string" || testCase.stderrIncludes.length === 0)) {
      throw new Error(`stderrIncludesは空でない文字列を指定してください: ${testCase.id}`);
    }
  }
  let completed;
  try {
    completed = await runCases(cases, temporary, executable, officialCli, nativeOracleConcurrency());
  } catch (error) {
    if (artifactPath !== null) {
      const artifact = createArtifact([], 1, cases.length, artifactBaseline, artifactToolchain, artifactGitState, artifactCompareScriptSha256, artifactLnakoBinarySha256, artifactOracleIdentity, "infrastructure-failure");
      validateArtifact(artifact);
      await writeArtifactExclusive(artifactPath, artifact);
    }
    throw error;
  }
  const artifactFixtures = [];
  for (const { testCase, results, stderrResults, officialCompile, compileErrors, manifestSummary, generatedJavaScriptSha256, compileStatuses } of completed) {
    if (testCase.oracle === "official-generated") generatedOracleCases += 1;
    if (testCase.oracle === "official-source") sourceOracleCases += 1;
    const oracleKey = testCase.oracle === "official-generated" ? "officialGenerated" : "officialSource";
    const expected = JSON.stringify(results[oracleKey]);
    const compared = Object.entries(results).filter(([key]) =>
      (testCase.oracle !== "official-generated" || key !== "officialSource") &&
      (testCase.oracle !== "official-source" || key !== "officialGenerated")
    );
    const resultMismatch = compared.some(([, result]) => JSON.stringify(result) !== expected);
    const failureKinds = [];
    if (resultMismatch) {
      failures += 1;
      failureKinds.push("result-mismatch");
      console.error(`AOT実行差分 ${testCase.id}:\n${JSON.stringify(results, null, 2)}`);
      if (officialCompile.status !== 0) console.error(`公式JavaScript生成エラー:\n${officialCompile.stderr}`);
      if (compileErrors.length > 0) console.error(`lnakoネイティブ生成エラー:\n${compileErrors.join("\n")}`);
    }
    let stderrMismatch = false;
    if (testCase.stderrIncludes !== undefined) {
      const stderrCompared = Object.entries(stderrResults).filter(([key]) =>
        key === oracleKey ||
        (testCase.oracle !== "official-generated" || key !== "officialSource") &&
        (testCase.oracle !== "official-source" || key !== "officialGenerated"),
      );
      const missing = stderrCompared.filter(([key, stderr]) => results[key].exitCode !== 0 && !stderr.includes(testCase.stderrIncludes));
      if (missing.length > 0) {
        failures += 1;
        stderrMismatch = true;
        failureKinds.push("stderr-mismatch");
        console.error(`非成功stderr本文差分 ${testCase.id}: ${testCase.stderrIncludes}`);
        for (const [key, stderr] of missing) console.error(`${key}: ${JSON.stringify(stderr)}`);
      }
    }
    if (artifactPath !== null) {
      artifactFixtures.push({
        id: testCase.id,
        knownOracleSelection: testCase.oracle ?? null,
        oracleRoute: oracleKey,
        comparedRoutes: compared.map(([key]) => key),
        equivalent: !resultMismatch && !stderrMismatch,
        failureKinds,
        sourceSha256: sha256(testCase.source),
        generatedJavaScriptSha256,
        results: summarizeResults(results, stderrResults),
        compileStatuses,
        compileManifest: manifestSummary,
      });
    }
  }
  if (artifactPath !== null) {
    const artifact = createArtifact(
      artifactFixtures,
      failures,
      cases.length,
      artifactBaseline,
      artifactToolchain,
      artifactGitState,
      artifactCompareScriptSha256,
      artifactLnakoBinarySha256,
      artifactOracleIdentity,
      failures === 0 ? "success" : "comparison-failure",
    );
    validateArtifact(artifact);
    await writeArtifactExclusive(artifactPath, artifact);
  }
  if (failures > 0) throw new Error(`AOT実行結果の差分が${failures}件あります`);
  console.log(
    `公式cnako3・公式生成JavaScript・lnako run・LLVM AOT O0/O1/O2/O3の7経路実行差分テスト: ${cases.length}件成功` +
      (generatedOracleCases + sourceOracleCases > 0
        ? `（既知の公式経路差: CLI基準${sourceOracleCases}件、生成JavaScript基準${generatedOracleCases}件）`
        : ""),
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runCases(cases, temporary, executable, officialCli, concurrency) {
  const completed = new Array(cases.length);
  const infrastructureErrors = new Array(cases.length);
  let nextIndex = 0;
  async function worker() {
    while (true) {
      const index = nextIndex++;
      if (index >= cases.length) return;
      try {
        completed[index] = await runCase(cases[index], index, temporary, executable, officialCli, artifactPath !== null);
      } catch (error) {
        infrastructureErrors[index] = error;
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, cases.length) }, worker));
  const firstError = infrastructureErrors.find((error) => error !== undefined);
  if (firstError) throw firstError;
  return completed;
}

async function runCase(testCase, index, temporary, executable, officialCli, collectManifest) {
  // The ordinal makes temporary paths unique even if a future fixture list
  // accidentally contains duplicate IDs. Each worker owns one fixture, and
  // all commands within that fixture remain sequential. A private cwd also
  // prevents future fixtures that use relative files from racing each other.
  const stem = `${String(index).padStart(3, "0")}-${testCase.id}`;
  const fixtureDirectory = resolve(temporary, stem);
  await mkdir(fixtureDirectory);
  const sourcePath = resolve(fixtureDirectory, `${stem}.nako3`);
  const generatedJavaScript = resolve(fixtureDirectory, `${stem}.mjs`);
  await writeFile(sourcePath, testCase.source, "utf8");
  const options = {
    cwd: fixtureDirectory,
    env: { ...process.env, TZ: "Asia/Tokyo", LNAKO_LLVM_TRACE: "1" },
    maxBuffer,
  };
  const officialSource = await runProcess(process.execPath, [officialCli, sourcePath], options);
  const officialCompile = await runProcess(process.execPath, [officialCli, "--compile", "--silent", "--output", generatedJavaScript, sourcePath], options);
  const officialGenerated = officialCompile.status === 0 ? await runProcess(process.execPath, [generatedJavaScript], options) : officialCompile;
  const generatedJavaScriptSha256 = collectManifest && officialCompile.status === 0 ? sha256(await readFile(generatedJavaScript)) : null;
  const interpreted = await runProcess(executable, ["run", sourcePath], options);
  const results = {
    officialSource: normalize(officialSource),
    officialGenerated: normalize(officialGenerated),
    lnakoRun: normalize(interpreted),
  };
  const stderrResults = {
    officialSource: normalizeStderr(officialSource),
    officialGenerated: normalizeStderr(officialGenerated),
    lnakoRun: normalizeStderr(interpreted),
  };
  const compileErrors = [];
  const manifestPath = collectManifest ? resolve(fixtureDirectory, `${stem}-manifest.jsonl`) : null;
  let manifestSummary = null;
  const compileStatuses = collectManifest ? {} : null;
  for (const optimization of ["O0", "O1", "O2", "O3"]) {
    const nativeExecutable = resolve(fixtureDirectory, `${stem}-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
    const compileOptions = manifestPath !== null && optimization === "O0"
      ? { ...options, env: { ...options.env, LNAKO_COMPILE_MANIFEST: manifestPath } }
      : options;
    const nativeCompile = await runProcess(executable, ["build", sourcePath, "-o", nativeExecutable, `-${optimization}`], compileOptions);
    if (compileStatuses !== null) compileStatuses[optimization] = nativeCompile.status;
    if (manifestPath !== null && optimization === "O0" && nativeCompile.status === 0) {
      manifestSummary = await readManifestSummary(manifestPath);
    }
    const nativeResult = nativeCompile.status === 0 ? await runProcess(nativeExecutable, [], options) : nativeCompile;
    results[`lnakoNative${optimization}`] = normalize(nativeResult);
    stderrResults[`lnakoNative${optimization}`] = normalizeStderr(nativeResult);
    if (nativeCompile.status !== 0) compileErrors.push(`${optimization}:\n${nativeCompile.stderr}`);
  }
  if (manifestPath !== null) await rm(manifestPath, { force: true });
  return { testCase, results, stderrResults, officialCompile, compileErrors, manifestSummary, generatedJavaScriptSha256, compileStatuses };
}

function runProcess(command, arguments_, options) {
  return new Promise((resolveProcess) => {
    execFile(command, arguments_, options, (error, stdout, stderr) => {
      resolveProcess({
        status: error === null ? 0 : typeof error.code === "number" ? error.code : null,
        signal: error?.signal ?? null,
        stdout: stdout ?? "",
        stderr: stderr || (error?.message ?? ""),
      });
    });
  });
}

function nativeOracleConcurrency() {
  const configured = process.env.LNAKO_NATIVE_ORACLE_JOBS;
  if (configured === undefined || configured === "2") return 2;
  if (configured === "1") return 1;
  throw new Error("LNAKO_NATIVE_ORACLE_JOBSは1または2を指定してください");
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return {
    stdout: result.stdout.replaceAll("\r\n", "\n"),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}

function normalizeStderr(result) {
  return result.stderr.replaceAll("\r\n", "\n");
}

function parseArtifactPath() {
  const artifactArguments = process.argv.filter((argument) => argument === "--artifact" || argument.startsWith("--artifact="));
  if (artifactArguments.length > 1) throw new Error("--artifactは1回だけ指定してください");
  const flagIndex = process.argv.indexOf("--artifact");
  const inline = process.argv.find((argument) => argument.startsWith("--artifact="));
  if (flagIndex >= 0 && process.argv[flagIndex + 1] === undefined) throw new Error("--artifactには出力先を指定してください");
  const argumentPath = flagIndex >= 0 ? process.argv[flagIndex + 1] : inline?.slice("--artifact=".length);
  const environmentPath = process.env.LNAKO_NATIVE_ORACLE_ARTIFACT;
  if (argumentPath !== undefined && argumentPath.length === 0) throw new Error("--artifactの出力先が空です");
  if (environmentPath !== undefined && environmentPath.length === 0) throw new Error("LNAKO_NATIVE_ORACLE_ARTIFACTの出力先が空です");
  if (argumentPath !== undefined && !isAbsolute(argumentPath)) throw new Error("--artifactには絶対パスを指定してください");
  if (environmentPath !== undefined && !isAbsolute(environmentPath)) throw new Error("LNAKO_NATIVE_ORACLE_ARTIFACTには絶対パスを指定してください");
  if (argumentPath !== undefined && environmentPath !== undefined && argumentPath !== environmentPath) {
    throw new Error("--artifactとLNAKO_NATIVE_ORACLE_ARTIFACTの出力先が一致しません");
  }
  if (argumentPath !== undefined) return argumentPath;
  if (environmentPath !== undefined) return environmentPath;
  return null;
}

async function ensureArtifactDestinationFree(path) {
  try {
    await lstat(path);
  } catch (error) {
    if (error?.code === "ENOENT") {
      try {
        await access(dirname(path), fsConstants.W_OK);
      } catch {
        throw new Error("AOT差分artifactの出力先ディレクトリへ書き込めません");
      }
      return;
    }
    throw new Error("AOT差分artifactの出力先を確認できません");
  }
  throw new Error("AOT差分artifactの出力先は既に存在します");
}

function gitState() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error("lnakoのcommitを取得できません");
  const commit = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("lnakoのcommit形式が不正です");
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
  if (status.status !== 0) throw new Error("lnakoのdirty状態を取得できません");
  return { commit, dirty: status.stdout.length > 0 };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function readOracleIdentity(directory, cli, baseline) {
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
  return {
    build: marker.oracleBuild,
    cliSha256: sha256(await readFile(cli)),
    markerSha256: sha256(markerBytes),
  };
}

async function readManifestSummary(path) {
  let lines;
  try {
    lines = (await readFile(path, "utf8")).trimEnd().split("\n").map((line, index) => {
      try {
        return JSON.parse(line);
      } catch {
        throw new Error(`AOT compile manifestのJSONLが不正です（${index + 1}行目）`);
      }
    });
  } finally {
    await rm(path, { force: true });
  }
  if (lines.length < 2) throw new Error("AOT compile manifestが完了レコードを含みません");
  const header = lines[0];
  if (header.schema !== "lnako.aot.builtin-manifest.v1" || header.phase !== "pre-opt") {
    throw new Error("AOT compile manifestのschemaまたはphaseが不正です");
  }
  const complete = lines.at(-1);
  if (complete.kind !== "complete" || complete.complete !== true || !Number.isSafeInteger(complete.entryCount) || complete.entryCount < 0) {
    throw new Error("AOT compile manifestが完了レコードを含みません");
  }
  const entries = lines.slice(1, -1);
  if (complete.entryCount !== entries.length) throw new Error("AOT compile manifestのentryCountが一致しません");
  return {
    complete: true,
    entries: entries.map((entry, index) => {
      if (entry.kind !== "builtin-dispatch" || entry.schema !== header.schema || entry.phase !== "pre-opt") {
        throw new Error(`AOT compile manifestのdispatchレコードが不正です（${index + 2}行目）`);
      }
      for (const field of ["sourceName", "canonicalOpcode", "route"]) {
        if (typeof entry[field] !== "string" || entry[field].length === 0) throw new Error(`AOT compile manifestの${field}が不正です`);
      }
      return {
        sourceName: entry.sourceName,
        canonicalOpcode: entry.canonicalOpcode,
        route: entry.route,
      };
    }),
  };
}

function summarizeResults(results, stderrResults) {
  return Object.fromEntries(routeNames.map((route) => {
    const result = results[route];
    return [route, {
      exitCode: result.exitCode,
      signal: result.signal,
      stderrClass: result.stderrClass,
      stdoutSha256: sha256(result.stdout),
      stderrSha256: sha256(stderrResults[route]),
    }];
  }));
}

function createArtifact(fixtures, failureCount, fixtureCount, baseline, toolchain, git, compareScriptSha256, lnakoBinarySha256, oracleIdentity, status) {
  const knownOracleSelections = {
    defaultOfficialSource: fixtures.filter((fixture) => fixture.knownOracleSelection === null).length,
    officialSource: fixtures.filter((fixture) => fixture.knownOracleSelection === "official-source").length,
    officialGenerated: fixtures.filter((fixture) => fixture.knownOracleSelection === "official-generated").length,
  };
  return {
    schema: "lnako.native-oracle-artifact.v1",
    generatedAt: new Date().toISOString(),
    baseline: {
      repository: baseline.repository,
      tag: baseline.tag,
      commit: baseline.commit,
      archiveSha256: baseline.archive.sha256,
    },
    oracle: oracleIdentity,
    lnako: {
      commit: git.commit,
      dirty: git.dirty,
    },
    toolchain: {
      zig: toolchain.zig.version,
      llvm: toolchain.llvm.version,
      node: toolchain.node.version,
    },
    artifactSha256: {
      compareScript: compareScriptSha256,
      lnakoBinary: lnakoBinarySha256,
    },
    environment: {
      platform: process.platform,
      arch: process.arch,
      node: process.version,
    },
    fixtureCount,
    routeCount: routeNames.length,
    routes: routeNames,
    knownOracleSelections,
    status,
    comparisonSucceeded: failureCount === 0,
    failureCount,
    fixtures,
  };
}

function validateArtifact(artifact) {
  if (artifact.schema !== "lnako.native-oracle-artifact.v1" || artifact.routeCount !== routeNames.length) {
    throw new Error("AOT差分artifactのschemaまたはrouteCountが不正です");
  }
  if (!["success", "comparison-failure", "infrastructure-failure"].includes(artifact.status)) throw new Error("AOT差分artifactのstatusが不正です");
  if (artifact.comparisonSucceeded !== (artifact.status === "success") || (artifact.failureCount === 0) !== (artifact.status === "success")) {
    throw new Error("AOT差分artifactのstatusとcomparisonSucceededが一致しません");
  }
  if (artifact.status === "infrastructure-failure" && artifact.fixtures.length !== 0) throw new Error("インフラ失敗artifactにfixture結果があります");
  if (artifact.status !== "infrastructure-failure" && artifact.fixtureCount !== artifact.fixtures.length) throw new Error("AOT差分artifactのfixtureCountが一致しません");
  if (JSON.stringify(artifact.routes) !== JSON.stringify(routeNames)) throw new Error("AOT差分artifactのroute一覧が不正です");
  const hashPattern = /^[0-9a-f]{64}$/;
  const commitPattern = /^[0-9a-f]{40}$/i;
  if (!commitPattern.test(artifact.baseline.commit) || !commitPattern.test(artifact.lnako.commit)) throw new Error("AOT差分artifactのcommitが不正です");
  if (typeof artifact.lnako.dirty !== "boolean") throw new Error("AOT差分artifactのdirty状態が不正です");
  if (!Number.isSafeInteger(artifact.oracle.build) || artifact.oracle.build < 1 || !hashPattern.test(artifact.baseline.archiveSha256) ||
      !hashPattern.test(artifact.oracle.cliSha256) || !hashPattern.test(artifact.oracle.markerSha256)) {
    throw new Error("AOT差分artifactの公式オラクルhashが不正です");
  }
  if (!hashPattern.test(artifact.artifactSha256.compareScript) || !hashPattern.test(artifact.artifactSha256.lnakoBinary)) throw new Error("AOT差分artifactの実行物ハッシュが不正です");
  const forbiddenFields = new Set(["stdout", "stderr", "arguments", "args", "value", "values", "pointer", "address"]);
  function visit(value) {
    if (Array.isArray(value)) {
      for (const item of value) visit(item);
      return;
    }
    if (value === null || typeof value !== "object") return;
    for (const [key, item] of Object.entries(value)) {
      if (forbiddenFields.has(key)) throw new Error(`AOT差分artifactに禁止フィールドがあります: ${key}`);
      visit(item);
    }
  }
  visit(artifact);
  for (const fixture of artifact.fixtures) {
    if (fixture.id.length === 0 || typeof fixture.equivalent !== "boolean" || !Array.isArray(fixture.failureKinds)) throw new Error("AOT差分artifactのfixtureが不正です");
    if (fixture.equivalent !== (fixture.failureKinds.length === 0)) throw new Error(`AOT差分artifactのfixture statusが不正です: ${fixture.id}`);
    if (!hashPattern.test(fixture.sourceSha256) || (fixture.generatedJavaScriptSha256 !== null && !hashPattern.test(fixture.generatedJavaScriptSha256))) {
      throw new Error(`AOT差分artifactのfixture hashが不正です: ${fixture.id}`);
    }
    if (JSON.stringify(fixture.results && Object.keys(fixture.results)) !== JSON.stringify(routeNames)) {
      throw new Error(`AOT差分artifactのroute結果が不正です: ${fixture.id}`);
    }
    if (!Array.isArray(fixture.comparedRoutes) || fixture.comparedRoutes.some((route) => !routeNames.includes(route))) {
      throw new Error(`AOT差分artifactの比較routeが不正です: ${fixture.id}`);
    }
    if (JSON.stringify(Object.keys(fixture.compileStatuses ?? {})) !== JSON.stringify(["O0", "O1", "O2", "O3"])) {
      throw new Error(`AOT差分artifactのcompile statusが不正です: ${fixture.id}`);
    }
    if ((fixture.compileManifest === null) !== (fixture.compileStatuses.O0 !== 0)) {
      throw new Error(`AOT差分artifactのcompile manifest有無がO0結果と一致しません: ${fixture.id}`);
    }
    for (const result of Object.values(fixture.results)) {
      if (!hashPattern.test(result.stdoutSha256) || !hashPattern.test(result.stderrSha256)) throw new Error(`AOT差分artifactのroute hashが不正です: ${fixture.id}`);
    }
    if (fixture.compileManifest !== null) {
      if (fixture.compileManifest.complete !== true || !Array.isArray(fixture.compileManifest.entries)) {
        throw new Error(`AOT差分artifactのcompile manifest要約が不正です: ${fixture.id}`);
      }
      for (const entry of fixture.compileManifest.entries) {
        if (Object.keys(entry).sort().join(",") !== "canonicalOpcode,route,sourceName") throw new Error(`AOT差分artifactのmanifest要約に余分な情報があります: ${fixture.id}`);
      }
    }
  }
}

async function writeArtifactExclusive(path, artifact) {
  const directory = dirname(path);
  const temporaryDirectory = await mkdtemp(join(directory, `.lnako-native-artifact-${process.pid}-`));
  try {
    const temporaryPath = join(temporaryDirectory, "result.json");
    await writeFile(temporaryPath, `${JSON.stringify(artifact, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
    try {
      await link(temporaryPath, path);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error("AOT差分artifactの出力先は既に存在します");
      throw new Error("AOT差分artifactを原子的に出力できません");
    }
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}
