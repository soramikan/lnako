import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const comparisonBenchmarkWorkflow = await readFile(resolve(root, ".github/workflows/comparison-benchmark.yml"), "utf8");
const floatingActions = [...workflow.matchAll(/uses: ([^\s@]+)@([^\s#]+)/g)]
  .filter((match) => !/^[0-9a-f]{40}$/.test(match[2]))
  .map((match) => `${match[1]}@${match[2]}`);
if (floatingActions.length > 0) throw new Error(`GitHub Actionをcommit SHAへ固定してください: ${floatingActions.join(", ")}`);
if (!workflow.includes("node tools/check_dispatch_attestation_security.mjs")) throw new Error("dispatch attestationの偽造拒否検査がCIにありません");
if (!workflow.includes("node tools/check_tracked_dispatch_attestation.mjs --offline") || !workflow.includes("node tools/check_tracked_dispatch_attestation.mjs\n") || !workflow.includes("node tools/check_tracked_dispatch_attestation_security.mjs")) throw new Error("tracked dispatch attestationの固定／改変検査がCIにありません");
const setupOracle = await readFile(resolve(root, "tools/setup_oracle.mjs"), "utf8");
const httpAotScript = await readFile(resolve(root, "tools/compare_http_server_aot_oracle.mjs"), "utf8");
const dispatchSecurityScript = await readFile(resolve(root, "tools/check_dispatch_trace_security.mjs"), "utf8");
const dispatchAuditsScript = await readFile(resolve(root, "tools/check_dispatch_audits_parallel.mjs"), "utf8");
const aotSuiteScript = await readFile(resolve(root, "tools/check_aot_suite_parallel.mjs"), "utf8");
const dispatchCoverageScript = await readFile(resolve(root, "tools/check_dispatch_coverage.mjs"), "utf8");
const dispatchCoverageShardsScript = await readFile(resolve(root, "tools/check_dispatch_coverage_shards.mjs"), "utf8");
const nativeOracleScript = await readFile(resolve(root, "tools/compare_native_oracle.mjs"), "utf8");
const nativeAotArtifactChecker = await readFile(resolve(root, "tools/check_native_aot_artifacts.mjs"), "utf8");
const nativeAotAttestationVerifier = await readFile(resolve(root, "tools/verify_native_aot_attestation.mjs"), "utf8");
const interpreterOracleScript = await readFile(resolve(root, "tools/compare_interpreter_oracle.mjs"), "utf8");
const compatJsEvidenceScript = await readFile(resolve(root, "tools/check_compat_js_evidence.mjs"), "utf8");
const pruneLlvmToolchainScript = await readFile(resolve(root, "tools/prune_llvm_toolchain.mjs"), "utf8");
const trackedAttestationChecker = await readFile(resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "utf8");
const syncEvidence = await readFile(resolve(root, "tools/sync_compat_evidence.mjs"), "utf8");
const verifyAttestation = await readFile(resolve(root, "tools/verify_dispatch_attestation.mjs"), "utf8");
if (!trackedAttestationChecker.includes("gh") || !trackedAttestationChecker.includes("--cert-oidc-issuer") || !trackedAttestationChecker.includes("--deny-self-hosted-runners") || !syncEvidence.includes("--historical-commit") || !syncEvidence.includes("canonical --output")) {
  throw new Error("tracked dispatch attestation checkerのhistorical commit／公式gh厳格検証が不完全です");
}
if (!verifyAttestation.includes('evidence.fixture?.id !== "native-dispatch-commands"') || verifyAttestation.includes('evidence.fixture?.id !== "native-cut-commands"')) {
  throw new Error("dispatch attestation verifierが現行dispatch fixtureを検証していません");
}
const upstreamLock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8"));
const oracleIdentity = upstreamLock.nadesiko3?.oracleIdentity;
const oracleArchiveSha256 = upstreamLock.nadesiko3?.archive?.sha256;
const treeHashes = oracleIdentity?.treeSha256ByPlatform;
const requiredTreePlatforms = ["darwin-arm64", "linux-x64", "win32-x64"];
if (!Number.isSafeInteger(oracleIdentity?.build) || oracleIdentity.treeHashAlgorithm !== "sha256-json-records-v3" ||
    !/^[0-9a-f]{64}$/.test(oracleIdentity?.cliSha256 ?? "") || !/^[0-9a-f]{64}$/.test(oracleIdentity?.markerSha256 ?? "") ||
    !/^[0-9a-f]{64}$/.test(oracleArchiveSha256 ?? "") ||
    treeHashes === null || typeof treeHashes !== "object" || Array.isArray(treeHashes) || Object.keys(treeHashes).length === 0 ||
    JSON.stringify(Object.keys(treeHashes).sort()) !== JSON.stringify(requiredTreePlatforms) ||
    Object.entries(treeHashes).some(([platform, hash]) => !/^(darwin|linux|win32)-(arm64|x64)$/.test(platform) || !/^[0-9a-f]{64}$/.test(hash))) {
  throw new Error("upstream.lock.jsonの公式オラクルidentityが不正です");
}

const platforms = new Map([
  ["Linux x86_64", "ubuntu-24.04"],
  ["macOS arm64", "macos-15"],
  ["Windows x86_64", "windows-2025"],
]);
const suites = ["core", "standard", "host", "compat-aot", "aot-native", "aot-support"];
const matrixEntries = [...workflow.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], suite: match[3] }));
const actualMatrix = new Set(matrixEntries.map((entry) => `${entry.name}\0${entry.os}\0${entry.suite}`));
const expectedMatrix = new Set();
for (const [name, os] of platforms) {
  const expectedSuites = name === "macOS arm64"
    ? ["mac-core-standard-support", "mac-host-compat", "aot-native"]
    : [...suites, "parser-fuzz"];
  for (const suite of expectedSuites) expectedMatrix.add(`${name}\0${os}\0${suite}`);
}
assertSetEqual(actualMatrix, expectedMatrix, "CI matrix");
const macosMatrixEntries = matrixEntries.filter((entry) => entry.name === "macOS arm64");
if (macosMatrixEntries.length !== 5 ||
    macosMatrixEntries.filter((entry) => entry.suite === "mac-core-standard-support").length !== 1 ||
    macosMatrixEntries.filter((entry) => entry.suite === "mac-host-compat").length !== 1 ||
    macosMatrixEntries.filter((entry) => entry.suite === "aot-native").length !== 3 ||
    macosMatrixEntries.some((entry) => entry.suite === "aot-support")) {
  throw new Error(`macOS同時実行上限5に合わせたjob構成が不正です: actual=${macosMatrixEntries.length}`);
}
const nativeAotMatrixEntries = matrixEntries.filter((entry) => entry.suite === "aot-native");
const supportAotMatrixEntries = matrixEntries.filter((entry) => entry.suite === "aot-support");
const nativeShardCounts = new Map([
  ["Linux x86_64", 3],
  ["macOS arm64", 1],
  ["Windows x86_64", 3],
]);
const nativeOptimizationGroups = new Map([
  ["Linux x86_64", [["O0", "O0"], ["O1", "O1"], ["O2", "O2"], ["O3", "O3"]]],
  ["macOS arm64", [["O0-O1", "O0,O1"], ["O2", "O2"], ["O3", "O3"]]],
  ["Windows x86_64", [["O0", "O0"], ["O1", "O1"], ["O2", "O2"], ["O3", "O3"]]],
]);
const expectedNativeRowCount = [...nativeShardCounts].reduce((total, [name, shardCount]) => total + shardCount * nativeOptimizationGroups.get(name).length, 0);
const expectedSupportTaskCounts = new Map([
  ["support-http", { count: 1, sharded: false, jobName: "AOT support HTTP" }],
  ["support-dispatch-evidence", { count: 1, sharded: false, jobName: "AOT support dispatch evidence" }],
  ["support-dispatch-coverage", { count: 3, sharded: true, jobName: "AOT support dispatch coverage shard" }],
  ["support-smoke", { count: 1, sharded: false, jobName: "AOT support smoke" }],
]);
const expectedSupportRowCount = [...expectedSupportTaskCounts.values()].reduce((total, task) => total + task.count, 0) * 2;
if (nativeAotMatrixEntries.length !== expectedNativeRowCount || supportAotMatrixEntries.length !== expectedSupportRowCount) {
  throw new Error(`AOT job分割数が不正です: native=${nativeAotMatrixEntries.length} support=${supportAotMatrixEntries.length}`);
}
if (matrixEntries.length !== 51) throw new Error(`CI matrixの実job数が不正です: actual=${matrixEntries.length}`);
const parserFuzzJob = workflow.match(/  parser_fuzz:[\s\S]*?(?=\n  aot:)/)?.[0];
if (!parserFuzzJob || !parserFuzzJob.includes("strategy:\n      fail-fast: false") ||
    !parserFuzzJob.includes("runs-on: ${{ matrix.os }}") || !parserFuzzJob.includes("timeout-minutes: 20") ||
    !parserFuzzJob.includes("suite: parser-fuzz") ||
    (parserFuzzJob.match(/^          - name: /gm) ?? []).length !== 2 ||
    !parserFuzzJob.includes("mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1") ||
    !parserFuzzJob.includes("version: 0.16.0") || !parserFuzzJob.includes("use-cache: false") ||
    !parserFuzzJob.includes("actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444 # v5.0.0") ||
    !parserFuzzJob.includes("node-version: 24.15.0") ||
    !parserFuzzJob.includes("actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0") ||
    !parserFuzzJob.includes("path: .cache/oracle") ||
    !parserFuzzJob.includes("node tools/setup_oracle.mjs") ||
    !parserFuzzJob.includes("node tools/fuzz_parser_oracle.mjs --iterations 1024 --seed 20260830")) {
  throw new Error("Linux／Windows専用parser fuzz jobの構成が不完全です");
}
if (parserFuzzJob.includes("macos-15") || parserFuzzJob.includes("macOS arm64")) {
  throw new Error("parser fuzz専用jobへmacOSを追加してrunner上限5を超えています");
}
const nativeAotJob = workflow.match(/  aot:[\s\S]*?(?=\n  (?:verify_dispatch_coverage|verify_native_aot_artifacts|attest-dispatch-evidence):)/)?.[0];
if (!nativeAotJob) throw new Error("分割AOT jobがありません");
const nativeShardRows = [...nativeAotJob.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: aot-native\n            task: native\n            fixtureShardIndex: (\d+)\n            fixtureShardCount: (\d+)\n            fixtureSharded: (true|false)\n            optimizationKey: (.+)\n            optimizations: (.+)\n            jobName: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], index: Number(match[3]), count: Number(match[4]), sharded: match[5] === "true", optimizationKey: match[6], optimizations: match[7], jobName: match[8] }));
const supportRows = [...nativeAotJob.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: aot-support\n            task: (.+)\n            fixtureShardIndex: (\d+)\n            fixtureShardCount: (\d+)\n            fixtureSharded: (true|false)\n            jobName: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], task: match[3], index: Number(match[4]), count: Number(match[5]), sharded: match[6] === "true", jobName: match[7] }));
const expectedNativeRows = new Set();
for (const [name, count] of nativeShardCounts) {
  const groups = nativeOptimizationGroups.get(name);
  for (let index = 0; index < count; index += 1) {
    for (const [optimizationKey, optimizations] of groups) {
      const sharded = count > 1;
      const jobName = sharded ? `AOT native shard ${index + 1}/${count} / ${optimizationKey}` : `AOT native routes ${optimizationKey.replace("-", "+")}`;
      expectedNativeRows.add(`${name}\0${platforms.get(name)}\0${index}\0${count}\0${sharded}\0${optimizationKey}\0${optimizations}\0${jobName}`);
    }
  }
}
const expectedSupportOS = new Map([
  ["Linux x86_64", "ubuntu-24.04"],
  ["Windows x86_64", "windows-2025"],
]);
const expectedSupportRows = new Set();
for (const [name, os] of expectedSupportOS) {
  for (const [task, definition] of expectedSupportTaskCounts) {
    for (let index = 0; index < definition.count; index += 1) {
      const jobName = definition.count === 1 ? definition.jobName : `${definition.jobName} ${index + 1}/${definition.count}`;
      expectedSupportRows.add(`${name}\0${os}\0${task}\0${index}\0${definition.count}\0${definition.sharded}\0${jobName}`);
    }
  }
}
if (nativeShardRows.length !== expectedNativeRowCount || supportRows.length !== expectedSupportRows.size || nativeShardRows.some((row) => {
  const expectedCount = nativeShardCounts.get(row.name);
  return expectedCount === undefined || !expectedNativeRows.has(`${row.name}\0${row.os}\0${row.index}\0${row.count}\0${row.sharded}\0${row.optimizationKey}\0${row.optimizations}\0${row.jobName}`);
}) ||
    new Set(nativeShardRows.map((row) => `${row.name}\0${row.os}\0${row.index}\0${row.optimizationKey}`)).size !== expectedNativeRowCount ||
    new Set(supportRows.map((row) => `${row.name}\0${row.os}\0${row.task}\0${row.index}\0${row.count}\0${row.sharded}\0${row.jobName}`)).size !== expectedSupportRows.size ||
    supportRows.some((row) => !expectedSupportOS.has(row.name) || row.os !== expectedSupportOS.get(row.name) ||
      !expectedSupportTaskCounts.has(row.task) ||
      !expectedSupportRows.has(`${row.name}\0${row.os}\0${row.task}\0${row.index}\0${row.count}\0${row.sharded}\0${row.jobName}`))) {
  throw new Error("AOT native/support jobのOS別fixture shard／optimization matrixが不正です");
}
const expectedMacCoverageRows = new Map([
  ["AOT native routes O0+O1", 1],
  ["AOT native routes O2", 0],
  ["AOT native routes O3", 2],
]);
for (const [jobName, index] of expectedMacCoverageRows) {
  const row = `jobName: ${jobName}\n            dispatchCoverageShardIndex: ${index}\n            dispatchCoverageShardCount: 3`;
  if (!nativeAotJob.includes(row)) throw new Error(`macOS ${jobName}のdispatch coverage shard割当が不正です`);
}

const stepSuites = new Map([
  ["Verify compatibility baseline", "core"],
  ["Differential lexer test", "core"],
  ["Differential syntax transform test", "core"],
  ["Differential parser test", "core"],
  ["Grammar-generating parser fuzz test (macOS)", "macos-fuzz"],
  ["Differential parser diagnostic test", "core"],
  ["Differential semantic test", "core"],
  ["Differential semantic diagnostic test", "core"],
  ["Differential dynamic value test", "core"],
  ["Differential interpreter test", "core"],
  ["Differential plugin_system test", "core"],
  ["Differential standard plugin test", "standard"],
  ["Differential QuickJS compatibility test", "host"],
  ["Native plugin ABI test", "host"],
  ["Differential Node host test", "mac-core-host"],
  ["Distribution package self-test", "core"],
  ["Format", "core"],
  ["Test", "core"],
  ["Test QuickJS build", "compat-aot"],
  ["Build QuickJS compiler", "compat-aot"],
  ["Compatibility smoke test", "compat-aot"],
]);
for (const [name, suite] of stepSuites) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const condition = suite === "core"
    ? "matrix.suite == 'core' || matrix.suite == 'mac-core-standard-support'"
    : suite === "macos-fuzz"
      ? "matrix.suite == 'mac-core-standard-support'"
      : suite === "standard"
      ? "matrix.suite == 'standard' || matrix.suite == 'mac-core-standard-support'"
      : suite === "host"
        ? "matrix.suite == 'host' || matrix.suite == 'mac-host-compat'"
        : suite === "mac-core-host"
        ? "matrix.suite == 'host' || matrix.suite == 'mac-core-standard-support'"
        : "matrix.suite == 'compat-aot' || matrix.suite == 'mac-host-compat'";
  const pattern = new RegExp(`^      - name: ${escaped}\\n        if: ${condition.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m");
  if (!pattern.test(workflow)) throw new Error(`${name}のsuite条件が${suite}ではありません`);
}

const testJob = workflow.match(/  test:[\s\S]*?(?=\n  parser_fuzz:|\n  aot:)/)?.[0];
if (!testJob) throw new Error("通常test jobがありません");
if (!testJob.includes("name: Clear generated Zig install outputs\n        shell: bash\n        run: rm -rf -- zig-out")) {
  throw new Error("差分test前に生成Zig install出力を消去する再発防止策がありません");
}
if (testJob.includes("Grammar-generating parser fuzz test\n")) {
  throw new Error("Linux／Windowsのparser fuzzを通常core jobへ残さないでください");
}
if (!interpreterOracleScript.includes("sanity.error?.code !== \"ENOEXEC\"") ||
    !interpreterOracleScript.includes("rmSync(resolve(root, \"zig-out\")") ||
    !interpreterOracleScript.includes("rmSync(resolve(root, \".zig-cache\")")) {
  throw new Error("Interpreter差分のENOEXEC cache再構築処理がありません");
}
const macSupportSteps = new Map([
  ["Build macOS AOT verification compiler", ["matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat'", "run: zig build"]],
  ["macOS AOT HTTP server oracle", ["matrix.suite == 'mac-core-standard-support'", "node tools/compare_http_server_aot_oracle.mjs --no-build"]],
  ["macOS dispatch evidence audit", ["matrix.suite == 'mac-host-compat'", "node tools/check_dispatch_trace.mjs --no-build"]],
  ["macOS dispatch trace security audit", ["matrix.suite == 'mac-host-compat'", "node tools/check_dispatch_trace_security.mjs --no-build"]],
  ["Upload macOS native dispatch evidence", ["matrix.suite == 'mac-host-compat' && always()", "name: lnako-dispatch-evidence-macos-15"]],
  ["Build macOS ReleaseSafe compiler", ["matrix.suite == 'mac-core-standard-support'", "run: zig build -Doptimize=ReleaseSafe"]],
  ["macOS normal smoke test", ["matrix.suite == 'mac-core-standard-support'", "./zig-out/bin/lnako test tests/fixtures/run-tests.nako3"]],
]);
for (const [name, [condition, required]] of macSupportSteps) {
  const marker = "      - name: " + name;
  const start = testJob.indexOf(marker);
  const next = testJob.indexOf("\n      - name:", start + marker.length);
  const block = start < 0 ? null : testJob.slice(start, next < 0 ? testJob.length : next);
  if (!block || !block.includes(`if: ${condition}`) || !block.includes(required)) {
    throw new Error(`macOS分割jobの${name}が不完全です`);
  }
}
if ((testJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 1) {
  throw new Error("macOSのdispatch evidence artifact uploadが1件ありません");
}

const aotStep = (name) => {
  const marker = "      - name: " + name;
  const start = nativeAotJob.indexOf(marker);
  if (start < 0) return null;
  const next = nativeAotJob.indexOf("\n      - name:", start + marker.length);
  return nativeAotJob.slice(start, next < 0 ? nativeAotJob.length : next);
};
if (!nativeAotJob.includes("strategy:\n      fail-fast: false") || !nativeAotJob.includes("runs-on: ${{ matrix.os }}") || !nativeAotJob.includes("timeout-minutes: 50")) {
  throw new Error("分割AOT jobの実行条件が不正です");
}
const nativeAotBuildBlock = aotStep("Build AOT verification compiler");
if (!nativeAotBuildBlock || !nativeAotBuildBlock.includes("if: matrix.task != 'support-smoke'") || !nativeAotBuildBlock.includes("run: zig build")) {
  throw new Error("AOT検証用compilerの先行buildがありません");
}
const macCoverageBlock = aotStep("macOS dispatch coverage audit");
if (!macCoverageBlock || !macCoverageBlock.includes("if: matrix.name == 'macOS arm64' && matrix.task == 'native'") ||
    !macCoverageBlock.includes("node tools/check_dispatch_coverage.mjs --no-build") ||
    !macCoverageBlock.includes('--fixture-shard-index "${{ matrix.dispatchCoverageShardIndex }}"') ||
    !macCoverageBlock.includes('--fixture-shard-count "${{ matrix.dispatchCoverageShardCount }}"') ||
    !macCoverageBlock.includes("--output") || !macCoverageBlock.includes("dispatch-coverage-${{ matrix.os }}-${{ matrix.dispatchCoverageShardIndex }}.json")) {
  throw new Error("macOS native routeへ分散したdispatch coverage shardの設定が不完全です");
}
const macCoverageUploadBlock = aotStep("Upload macOS native dispatch coverage audit");
if (!macCoverageUploadBlock || !macCoverageUploadBlock.includes("if: matrix.name == 'macOS arm64' && matrix.task == 'native' && always()") ||
    !macCoverageUploadBlock.includes("name: lnako-dispatch-coverage-${{ matrix.os }}-shard-${{ matrix.dispatchCoverageShardIndex }}") ||
    !macCoverageUploadBlock.includes("path: ${{ runner.temp }}/dispatch-coverage-${{ matrix.os }}-${{ matrix.dispatchCoverageShardIndex }}.json") ||
    !macCoverageUploadBlock.includes("if-no-files-found: ignore")) {
  throw new Error("macOS native routeのdispatch coverage artifact uploadが不完全です");
}
const nativeAotVerificationBlock = aotStep("Differential native AOT verification (fixture/route shard)");
if (!nativeAotVerificationBlock || !nativeAotVerificationBlock.includes("if: matrix.task == 'native'") ||
    !nativeAotVerificationBlock.includes('LNAKO_NATIVE_ORACLE_JOBS: "1"') ||
    (nativeAotVerificationBlock.match(/node tools\/compare_native_oracle\.mjs/g) ?? []).length !== 1 ||
    !nativeAotVerificationBlock.includes("--no-build") || !nativeAotVerificationBlock.includes("--optimizations") || !nativeAotVerificationBlock.includes("--shard-index") ||
    !nativeAotVerificationBlock.includes("--shard-count") || !nativeAotVerificationBlock.includes("--artifact")) {
  throw new Error("AOT fixture／route shardのworker、shard指定、またはartifact出力が不正です");
}
if (nativeAotJob.includes("check_aot_suite_parallel.mjs")) throw new Error("旧AOT全検査runnerを分割jobへ再導入しないでください");
if (!nativeOracleScript.includes("const shard = parseShard();") || !nativeOracleScript.includes("selectedCases = selectCases(cases, shard);") ||
    !nativeOracleScript.includes("const selectedOptimizations = parseOptimizations();") || !nativeOracleScript.includes("weighted-source-command") || !nativeOracleScript.includes("--shard-index") ||
    !nativeOracleScript.includes("--optimizations") || !nativeOracleScript.includes('schema: "lnako.native-oracle-artifact.v3"')) {
  throw new Error("native oracleのfixture／route shard実装がありません");
}
const supportStepConditions = new Map([
  ["Differential HTTP server AOT oracle", "support-http"],
  ["Dispatch evidence audit", "support-dispatch-evidence"],
  ["Dispatch coverage audit", "support-dispatch-coverage"],
  ["Dispatch trace security audit", "support-dispatch-evidence"],
  ["Build ReleaseSafe compiler", "support-smoke"],
  ["Normal smoke test", "support-smoke"],
]);
for (const [name, task] of supportStepConditions) {
  const block = aotStep(name);
  if (!block || !block.includes(`if: matrix.task == '${task}'`)) throw new Error(`${name}のsupport条件がありません`);
}
const httpAotBlock = aotStep("Differential HTTP server AOT oracle");
if (!httpAotBlock.includes("node tools/compare_http_server_aot_oracle.mjs --no-build")) throw new Error("AOT HTTP server比較のno-build実装がありません");
const dispatchEvidenceBlock = aotStep("Dispatch evidence audit");
const dispatchCoverageBlock = aotStep("Dispatch coverage audit");
const dispatchSecurityBlock = aotStep("Dispatch trace security audit");
if (!dispatchEvidenceBlock.includes("node tools/check_dispatch_trace.mjs --no-build") || !dispatchEvidenceBlock.includes("--evidence-output") ||
    !dispatchCoverageBlock.includes("node tools/check_dispatch_coverage.mjs --no-build") || !dispatchCoverageBlock.includes("--fixture-shard-index") ||
    !dispatchCoverageBlock.includes("--fixture-shard-count") || !dispatchCoverageBlock.includes("--output") ||
    !dispatchSecurityBlock.includes("node tools/check_dispatch_trace_security.mjs --no-build")) {
  throw new Error("dispatch evidence/coverageの分割監査、fixture shard、またはsecurity検査が不完全です");
}
if (!httpAotScript.includes("if (!noBuild) buildLnako();") || !httpAotScript.includes("else await access(executable);")) {
  throw new Error("AOT HTTPサーバー比較のno-build実装がありません");
}
if (!dispatchSecurityScript.includes("tests/fixtures/dispatch-security.nako3") || !dispatchSecurityScript.includes("assertExistingManifestPreserved") ||
    !dispatchSecurityScript.includes("assertFailedManifestRemoved") || !dispatchSecurityScript.includes("assertRepeatedSite")) {
  throw new Error("AOT dispatch securityのtiny fixture実装または不変条件検査が不完全です");
}
if (!compatJsEvidenceScript.includes('schema: "lnako.compat-js-evidence.v1"') ||
    !compatJsEvidenceScript.includes("only successful direct root sites select catalog evidence") ||
    !compatJsEvidenceScript.includes("--evidence-output") ||
    !workflow.includes("node tools/check_compat_js_evidence.mjs --no-build")) {
  throw new Error("compat-js専用実行証拠のschema、direct site選択、またはCI検査が不完全です");
}
if (!dispatchAuditsScript.includes('"check_dispatch_trace.mjs"') || !dispatchAuditsScript.includes('"check_dispatch_coverage.mjs"') ||
    !dispatchAuditsScript.includes('"--no-build"') || !dispatchAuditsScript.includes("Promise.all") ||
    !dispatchAuditsScript.includes("values.evidenceOutput === values.coverageOutput")) {
  throw new Error("AOT dispatch evidence/coverageの並列監査実装または出力分離検査が不完全です");
}
if (!aotSuiteScript.includes('"compare_native_oracle.mjs"') || !aotSuiteScript.includes('"--no-build"') ||
    !aotSuiteScript.includes('"compare_http_server_aot_oracle.mjs"') || !aotSuiteScript.includes('"check_dispatch_trace_security.mjs"') ||
    !aotSuiteScript.includes('"check_dispatch_audits_parallel.mjs"') || !aotSuiteScript.includes("Promise.all") ||
    !aotSuiteScript.includes("values.artifact, values.evidence, values.coverage") ||
    !aotSuiteScript.includes("child.on(\"close\"") ) {
  throw new Error("AOT全検査の並列runner、no-build、出力分離、全子検査待機の実装が不完全です");
}
const nativeUpload = aotStep("Upload native AOT oracle artifact");
if (!nativeUpload || !nativeUpload.includes("if: matrix.task == 'native' && always()") ||
    !nativeUpload.includes("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a") ||
    !nativeUpload.includes("matrix.os") || !nativeUpload.includes("matrix.fixtureShardIndex") || !nativeUpload.includes("matrix.optimizationKey") ||
    !nativeUpload.includes("if-no-files-found: ignore") || !nativeUpload.includes("retention-days: 30")) {
  throw new Error("AOT shard artifact uploadの設定が不正です");
}
if (nativeUpload.includes("run:")) throw new Error("AOT shard artifact uploadで追加の検証コマンドを実行しないでください");
const uploadActions = workflow.match(/^        uses: actions\/upload-artifact@/gm) ?? [];
if (uploadActions.length !== 7 || (testJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 1 ||
    (nativeAotJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 4) {
  throw new Error(`actions/upload-artifactはmacOS dispatch evidence 1＋AOT artifact 4＋aggregate 1＋attestation 1ステップ必要です: actual=${uploadActions.length}`);
}
const dispatchUploadBlock = aotStep("Upload native dispatch evidence");
if (!dispatchUploadBlock || !dispatchUploadBlock.includes("if: matrix.task == 'support-dispatch-evidence' && always()") ||
    !dispatchUploadBlock.includes("name: lnako-dispatch-evidence-") || !dispatchUploadBlock.includes("dispatch-evidence-") ||
    !dispatchUploadBlock.includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch evidence artifactの設定が不正です");
}
const coverageUploadBlock = aotStep("Upload native dispatch coverage audit");
if (!coverageUploadBlock || !coverageUploadBlock.includes("if: matrix.task == 'support-dispatch-coverage' && always()") ||
    !coverageUploadBlock.includes("name: lnako-dispatch-coverage-") || !coverageUploadBlock.includes("matrix.fixtureShardIndex") ||
    !coverageUploadBlock.includes("dispatch-coverage-") ||
    !coverageUploadBlock.includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch coverage artifactの設定が不正です");
}
if (!workflow.includes("if: matrix.suite == 'core' || matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat'\n        with:\n          fetch-depth: 0") ||
    !workflow.includes("if: matrix.suite != 'core' && matrix.suite != 'mac-core-standard-support' && matrix.suite != 'mac-host-compat'\n      - uses: mlugg/setup-zig")) {
  throw new Error("coreの証拠追従検査に必要なfull checkout条件がありません");
}
const coverageVerificationJob = workflow.match(/  verify_dispatch_coverage:[\s\S]*?(?=\n  verify_native_aot_artifacts:)/)?.[0];
if (!coverageVerificationJob || !coverageVerificationJob.includes("if: needs.test.result == 'success' && needs.aot.result == 'success'") ||
    !coverageVerificationJob.includes("needs: [test, aot]") ||
    !coverageVerificationJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") ||
    !coverageVerificationJob.includes("pattern: lnako-dispatch-coverage-*") ||
    !coverageVerificationJob.includes("merge-multiple: true") ||
    !coverageVerificationJob.includes("node tools/check_dispatch_coverage_shards.mjs") ||
    !coverageVerificationJob.includes("--shard-count 3") ||
    !dispatchCoverageShardsScript.includes("sampled-unattested-dispatch-audit-shard") ||
    !dispatchCoverageShardsScript.includes("assertSetEqual(union, referenceKeys") ||
    !dispatchCoverageScript.includes("const weightedFixtures = fixtures") ||
    !dispatchCoverageScript.includes(".sort((left, right) => right.weight - left.weight || left.index - right.index)") ||
    !dispatchCoverageScript.includes("--fixture-shard-index") || !dispatchCoverageScript.includes("--fixture-shard-count")) {
  throw new Error("dispatch coverage shardのdownload／重複・欠落検査jobが不完全です");
}
const nativeAotVerificationJob = workflow.match(/  verify_native_aot_artifacts:[\s\S]*?(?=\n  attest-dispatch-evidence:)/)?.[0];
if (!nativeAotVerificationJob || !nativeAotVerificationJob.includes("if: always()") ||
    !nativeAotVerificationJob.includes("needs: [aot]") ||
    !nativeAotVerificationJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") ||
    !nativeAotVerificationJob.includes("pattern: lnako-native-oracle-*") ||
    !nativeAotVerificationJob.includes("merge-multiple: false") ||
    !nativeAotVerificationJob.includes("node tools/check_native_aot_artifacts.mjs") ||
    !nativeAotVerificationJob.includes("--directory") || !nativeAotVerificationJob.includes("--commit \"${{ github.sha }}\"") ||
    !nativeAotVerificationJob.includes("--output") || !nativeAotVerificationJob.includes("Reject failed native AOT matrix") ||
    !nativeAotVerificationJob.includes("if: needs.aot.result != 'success'") ||
    !nativeAotVerificationJob.includes("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1") ||
    !nativeAotVerificationJob.includes("name: lnako-native-aot-aggregate") ||
    !nativeAotVerificationJob.includes("if-no-files-found: error") || !nativeAotVerificationJob.includes("retention-days: 30")) {
  throw new Error("native AOT artifactの全OS／全optimization集約検証jobが不完全です");
}
if (!nativeAotArtifactChecker.includes('schema: "lnako.native-aot-aggregate-evidence.v1"') ||
    !nativeAotArtifactChecker.includes("native-cases.json") || !nativeAotArtifactChecker.includes("expectedArtifactCount") ||
    !nativeAotArtifactChecker.includes("weighted-source-command") || !nativeAotArtifactChecker.includes("O0-O1") || !nativeAotArtifactChecker.includes("commands ?? []") ||
    !nativeAotArtifactChecker.includes("rejectForbidden") || !nativeAotArtifactChecker.includes("--self-test")) {
  throw new Error("native AOT artifact集約checkerのschema／全OS matrix／secret除外検査が不完全です");
}
if (!workflow.includes("node tools/check_native_aot_artifacts.mjs --self-test")) throw new Error("native AOT artifact集約checkerのself-testがCIにありません");
const attestJob = workflow.match(/  attest-dispatch-evidence:[\s\S]*$/)?.[0];
if (!attestJob || !attestJob.includes("github.event_name == 'push'") || !attestJob.includes("github.ref == 'refs/heads/main'") ||
    !attestJob.includes("needs: [test, parser_fuzz, aot, verify_dispatch_coverage, verify_native_aot_artifacts]") || !attestJob.includes("needs.test.result == 'success'") || !attestJob.includes("needs.parser_fuzz.result == 'success'") || !attestJob.includes("needs.aot.result == 'success'") || !attestJob.includes("needs.verify_dispatch_coverage.result == 'success'") || !attestJob.includes("needs.verify_native_aot_artifacts.result == 'success'") || !attestJob.includes("id-token: write") || !attestJob.includes("attestations: write") || !attestJob.includes("artifact-metadata: write") ||
    !attestJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") || !attestJob.includes("merge-multiple: true") ||
    !attestJob.includes("actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2") || !attestJob.includes("node tools/verify_dispatch_attestation.mjs") ||
    !attestJob.includes("id: attest-dispatch") || !attestJob.includes("--bundle \"${{ steps.attest-dispatch.outputs.bundle-path }}\"") ||
    !attestJob.includes("${{ runner.temp }}/dispatch-attestation.json") || !attestJob.includes("${{ steps.attest-dispatch.outputs.bundle-path }}") ||
    !attestJob.includes("--commit \"${{ github.sha }}\"") || !attestJob.includes("--workflow \"${{ github.repository }}/.github/workflows/ci.yml\"") || !attestJob.includes("node tools/check_tracked_dispatch_attestation.mjs") ||
    !attestJob.includes("name: Download native AOT aggregate evidence") || !attestJob.includes("name: lnako-native-aot-aggregate") ||
    !attestJob.includes("native-aot-evidence/lnako-native-aot-aggregate-evidence.json") ||
    !attestJob.includes("node tools/verify_native_aot_attestation.mjs") || !attestJob.includes("${{ runner.temp }}/native-aot-attestation.json") ||
    !nativeAotAttestationVerifier.includes('schema: "lnako.native-aot-attestation.v1"') ||
    !nativeAotAttestationVerifier.includes('"gh", [') || !nativeAotAttestationVerifier.includes("--deny-self-hosted-runners") ||
    !nativeAotAttestationVerifier.includes("--predicate-type") || !nativeAotAttestationVerifier.includes("subject digest")) {
  throw new Error("dispatch evidenceのattestation／検証job設定が不正です");
}
if (!syncEvidence.includes('extras[0].name !== "lnako-native-aot-aggregate-evidence.json"') ||
    !syncEvidence.includes("expectedDigests.some((digest) => !digests.includes(digest))")) {
  throw new Error("dispatch attestation verifierがnative AOT aggregateの追加subjectを安全に扱っていません");
}

const smokeCommands = {
  "Normal smoke test": [
    "./zig-out/bin/lnako --version",
    "node tools/check_compat_report.mjs --no-build",
    "./zig-out/bin/lnako check tests/fixtures/check-valid.nako3",
    "./zig-out/bin/lnako check tests/fixtures/module/main.nako3",
    "./zig-out/bin/lnako run tests/fixtures/run-control.nako3",
    "./zig-out/bin/lnako test tests/fixtures/run-tests.nako3",
  ],
  "Compatibility smoke test": ["./zig-out/bin/lnako run tests/fixtures/compat-js-basic.nako3 --compat-js"],
};
const smokeBlock = workflow.match(
  /      - name: Normal smoke test[\s\S]*?(?=      - name: Compatibility smoke test|$)/,
);
if (!smokeBlock) throw new Error("Normal smoke testブロックがありません");
const compatSmokeBlock = workflow.match(/      - name: Compatibility smoke test[\s\S]*$/);
if (!compatSmokeBlock) throw new Error("Compatibility smoke testブロックがありません");
for (const [name, commands] of Object.entries(smokeCommands)) {
  const block = name === "Normal smoke test" ? smokeBlock[0] : compatSmokeBlock[0];
  for (const command of commands) if (!block.includes(command)) throw new Error(`${name}のコマンドがありません: ${command}`);
}
const legacySmokeCommands = [
  ...smokeCommands["Normal smoke test"],
  ...smokeCommands["Compatibility smoke test"],
];
if (new Set(legacySmokeCommands).size !== legacySmokeCommands.length) throw new Error("smokeコマンドが重複しています");
if (legacySmokeCommands.length !== 7) throw new Error(`smokeコマンド数が従来の7件ではありません: ${legacySmokeCommands.length}`);
if ((workflow.match(/\.\/zig-out\/bin\/lnako/g) ?? []).length !== 11) throw new Error("lnako smokeコマンドの合計が通常support＋macOS分割jobの11件ではありません");
if (!pruneLlvmToolchainScript.includes("lib/clang/") || !pruneLlvmToolchainScript.includes("libLLVM-C") ||
    !pruneLlvmToolchainScript.includes("bin/clang")) {
  throw new Error("LLVM toolchain cache pruneがAOTに必要なclang／LLVM C API／resourceを保持していません");
}

const setupZigBlocks = [...workflow.matchAll(
  /      - uses: mlugg\/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2\.2\.1[\s\S]*?(?=      - uses: actions\/setup-node@)/g,
)].map((match) => match[0]);
const setupZigCacheSizeLimitMiB = 1536;
if (setupZigBlocks.length !== 3 ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat' }}") && block.includes("cache-key: ${{ matrix.suite }}")) ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.task == 'native' }}") && block.includes("cache-key: ${{ matrix.suite }}")) ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: false")) ||
    (workflow.match(/cache-size-limit:/g) ?? []).length !== 2) {
  throw new Error(`setup-zigのcache保存対象または${setupZigCacheSizeLimitMiB} MiB上限が不正です`);
}

const setupNodeBlock = workflow.match(
  /      - uses: actions\/setup-node@a0853c24544627f65ddf259abe73b1d18a591444 # v5\.0\.0[\s\S]*?(?=      - uses: actions\/cache@)/,
)?.[0];
if (setupNodeBlock === undefined || !setupNodeBlock.includes("if: matrix.suite != 'compat-aot'") ||
    !setupNodeBlock.includes("node-version: 24.15.0")) {
  throw new Error("compat-aotが不要なNode取得を行わないsetup-node条件またはNode固定版が不正です");
}

for (const required of [
  "group: ci-${{ github.workflow }}-${{ github.ref }}",
  "cancel-in-progress: true",
  "use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat' }}",
  "use-cache: ${{ matrix.task == 'native' }}",
  "cache-key: ${{ matrix.suite }}",
  `cache-size-limit: ${setupZigCacheSizeLimitMiB}`,
  "timeout-minutes: 50",
]) if (!workflow.includes(required)) throw new Error(`CI安全設定がありません: ${required}`);

const oracleSkipConditions = workflow.match(/^        if: matrix\.suite != 'compat-aot'$/gm) ?? [];
if (oracleSkipConditions.length !== 3) {
  throw new Error(`compat-aotのオラクル／Node省略条件はcache・setup・Nodeの3件必要です: actual=${oracleSkipConditions.length}`);
}

const cacheActions = [...workflow.matchAll(/^      - uses: actions\/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0$/gm)];
if (cacheActions.length !== 5) throw new Error(`actions/cache v6.1.0固定SHAは5ステップ必要です: actual=${cacheActions.length}`);
const toolchainCacheKey = "toolchains-llvm-22.1.8-quickjs-2026-06-04-${{ runner.os }}-${{ runner.arch }}-v2-minimal";
const legacyToolchainCacheKey = "toolchains-llvm-22.1.8-quickjs-2026-06-04-${{ runner.os }}-${{ runner.arch }}-v1";
if (countOccurrences(workflow, `key: ${toolchainCacheKey}`) !== 2 ||
    countOccurrences(workflow, `restore-keys: |\n            ${legacyToolchainCacheKey}`) !== 2 ||
    countOccurrences(workflow, "run: node tools/prune_llvm_toolchain.mjs") !== 2) {
  throw new Error("LLVM toolchain cacheのv2-minimal移行またはprune stepがtest／AOT jobへ設定されていません");
}
const oracleBuild = setupOracle.match(/^const oracleBuild = (\d+);$/m)?.[1];
if (oracleBuild === undefined) throw new Error("setup_oracle.mjsのoracleBuildを取得できません");
if (Number(oracleBuild) !== oracleIdentity.build || !setupOracle.includes("oracleIdentity.cliSha256") || !setupOracle.includes("oracleIdentity.markerSha256") ||
    !setupOracle.includes("oracleTreeHash") || !setupOracle.includes("oracleTreeHashAlgorithm")) {
  throw new Error("公式オラクルのbuild／CLI／marker固定hash検証がsetup_oracle.mjsにありません");
}
const oracleCacheKey = `key: nadesiko3-oracle-3.7.24-\${{ runner.os }}-\${{ runner.arch }}-a${oracleArchiveSha256.slice(0, 12)}-v${oracleBuild}`;
if (!workflow.includes(oracleCacheKey)) throw new Error(`公式オラクルのキャッシュキーがoracleBuildと一致しません: ${oracleCacheKey}`);

checkFailFastShell(workflow, ".github/workflows/ci.yml");
checkFailFastShell(comparisonBenchmarkWorkflow, ".github/workflows/comparison-benchmark.yml");
checkBashFailFastBehavior();

console.log(`CI構成検査: ${matrixEntries.length} matrixジョブ＋coverage shard検証＋native AOT集約検証＋1 attestationジョブ・${stepSuites.size}条件付き検証ステップ成功`);

function checkFailFastShell(workflowText, filename) {
  const stepHeaders = [...workflowText.matchAll(/^      - name: .*$/gm)];
  for (let index = 0; index < stepHeaders.length; index += 1) {
    const start = stepHeaders[index].index;
    const end = stepHeaders[index + 1]?.index ?? workflowText.length;
    const block = workflowText.slice(start, end);
    if (!block.includes("run: |\n")) continue;
    const name = block.match(/^      - name: (.+)$/m)?.[1] ?? "unknown";
    if (!block.includes("shell: bash\n")) {
      throw new Error(`${filename}の「${name}」ステップは複数行runにshell: bashがありません`);
    }
    const runMatch = block.match(/ {8}run: \|\n([\s\S]*?)(?= {6}- |$)/);
    if (!runMatch) {
      throw new Error(`${filename}の「${name}」ステップのrun内容を解析できません`);
    }
    const firstRunLine = runMatch[1].split("\n")[0].trim();
    if (firstRunLine !== "set -euo pipefail") {
      throw new Error(`${filename}の「${name}」ステップはset -euo pipefailでは始まっていません`);
    }
  }
}

function checkBashFailFastBehavior() {
  const result = spawnSync("bash", ["-c", "set -euo pipefail; false; true"], { encoding: "utf8" });
  if (result.status === 0) {
    throw new Error("fail-fastなbashで最初の失敗が検出されません（'false; true'が成功しました）");
  }
}

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不正です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}

function countOccurrences(text, fragment) {
  return text.split(fragment).length - 1;
}
