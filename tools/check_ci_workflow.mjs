import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
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
const nativeOracleScript = await readFile(resolve(root, "tools/compare_native_oracle.mjs"), "utf8");
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
    : suites;
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
if (nativeAotMatrixEntries.length !== expectedNativeRowCount || supportAotMatrixEntries.length !== 2) {
  throw new Error(`AOT job分割数が不正です: native=${nativeAotMatrixEntries.length} support=${supportAotMatrixEntries.length}`);
}
if (matrixEntries.length !== 39) throw new Error(`CI matrixの実job数が不正です: actual=${matrixEntries.length}`);
const nativeAotJob = workflow.match(/  aot:[\s\S]*?(?=\n  attest-dispatch-evidence:)/)?.[0];
if (!nativeAotJob) throw new Error("分割AOT jobがありません");
const nativeShardRows = [...nativeAotJob.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: aot-native\n            task: native\n            fixtureShardIndex: (\d+)\n            fixtureShardCount: (\d+)\n            fixtureSharded: (true|false)\n            optimizationKey: (.+)\n            optimizations: (.+)\n            jobName: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], index: Number(match[3]), count: Number(match[4]), sharded: match[5] === "true", optimizationKey: match[6], optimizations: match[7], jobName: match[8] }));
const supportRows = [...nativeAotJob.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: aot-support\n            task: support\n            jobName: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], jobName: match[3] }));
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
const expectedSupportOS = new Set(["Linux x86_64", "Windows x86_64"]);
if (nativeShardRows.length !== expectedNativeRowCount || supportRows.length !== expectedSupportOS.size || nativeShardRows.some((row) => {
  const expectedCount = nativeShardCounts.get(row.name);
  return expectedCount === undefined || !expectedNativeRows.has(`${row.name}\0${row.os}\0${row.index}\0${row.count}\0${row.sharded}\0${row.optimizationKey}\0${row.optimizations}\0${row.jobName}`);
}) ||
    new Set(nativeShardRows.map((row) => `${row.name}\0${row.os}\0${row.index}\0${row.optimizationKey}`)).size !== expectedNativeRowCount ||
    new Set(supportRows.map((row) => `${row.name}\0${row.os}`)).size !== expectedSupportOS.size ||
    supportRows.some((row) => !expectedSupportOS.has(row.name) || row.os !== platforms.get(row.name))) {
  throw new Error("AOT native/support jobのOS別fixture shard／optimization matrixが不正です");
}

const stepSuites = new Map([
  ["Verify compatibility baseline", "core"],
  ["Differential lexer test", "core"],
  ["Differential syntax transform test", "core"],
  ["Differential parser test", "core"],
  ["Grammar-generating parser fuzz test", "core"],
  ["Differential parser diagnostic test", "core"],
  ["Differential semantic test", "core"],
  ["Differential semantic diagnostic test", "core"],
  ["Differential dynamic value test", "core"],
  ["Differential interpreter test", "core"],
  ["Differential plugin_system test", "core"],
  ["Differential standard plugin test", "standard"],
  ["Differential QuickJS compatibility test", "host"],
  ["Native plugin ABI test", "host"],
  ["Differential Node host test", "host"],
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
    : suite === "standard"
      ? "matrix.suite == 'standard' || matrix.suite == 'mac-core-standard-support'"
      : suite === "host"
        ? "matrix.suite == 'host' || matrix.suite == 'mac-host-compat'"
        : "matrix.suite == 'compat-aot' || matrix.suite == 'mac-host-compat'";
  const pattern = new RegExp(`^      - name: ${escaped}\\n        if: ${condition.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m");
  if (!pattern.test(workflow)) throw new Error(`${name}のsuite条件が${suite}ではありません`);
}

const testJob = workflow.match(/  test:[\s\S]*?(?=\n  aot:)/)?.[0];
if (!testJob) throw new Error("通常test jobがありません");
const macSupportSteps = new Map([
  ["Build macOS AOT verification compiler", "run: zig build"],
  ["macOS AOT HTTP server oracle", "node tools/compare_http_server_aot_oracle.mjs --no-build"],
  ["macOS dispatch evidence/coverage audit", "node tools/check_dispatch_audits_parallel.mjs"],
  ["macOS dispatch trace security audit", "node tools/check_dispatch_trace_security.mjs --no-build"],
  ["Upload macOS native dispatch evidence", "name: lnako-dispatch-evidence-macos-15"],
  ["Upload macOS native dispatch coverage audit", "name: lnako-dispatch-coverage-macos-15"],
  ["Build macOS ReleaseSafe compiler", "run: zig build -Doptimize=ReleaseSafe"],
  ["macOS normal smoke test", "./zig-out/bin/lnako test tests/fixtures/run-tests.nako3"],
]);
for (const [name, required] of macSupportSteps) {
  const marker = "      - name: " + name;
  const start = testJob.indexOf(marker);
  const next = testJob.indexOf("\n      - name:", start + marker.length);
  const block = start < 0 ? null : testJob.slice(start, next < 0 ? testJob.length : next);
  if (!block || !block.includes("if: matrix.suite == 'mac-core-standard-support'") || !block.includes(required)) {
    throw new Error(`macOS分割jobの${name}が不完全です`);
  }
}
if ((testJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 2) {
  throw new Error("macOS分割jobのdispatch artifact uploadが2件ありません");
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
if (!nativeAotBuildBlock || !nativeAotBuildBlock.includes("run: zig build")) {
  throw new Error("AOT検証用compilerの先行buildがありません");
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
const supportStepNames = [
  "Differential HTTP server AOT oracle",
  "Dispatch evidence/coverage audit",
  "Dispatch trace security audit",
  "Build ReleaseSafe compiler",
  "Normal smoke test",
];
for (const name of supportStepNames) {
  const block = aotStep(name);
  if (!block || !block.includes("if: matrix.task == 'support'")) throw new Error(`${name}のsupport条件がありません`);
}
const httpAotBlock = aotStep("Differential HTTP server AOT oracle");
if (!httpAotBlock.includes("node tools/compare_http_server_aot_oracle.mjs --no-build")) throw new Error("AOT HTTP server比較のno-build実装がありません");
const dispatchAuditsBlock = aotStep("Dispatch evidence/coverage audit");
const dispatchSecurityBlock = aotStep("Dispatch trace security audit");
if (!dispatchAuditsBlock.includes("node tools/check_dispatch_audits_parallel.mjs") || !dispatchAuditsBlock.includes("--evidence-output") ||
    !dispatchAuditsBlock.includes("--coverage-output") ||
    !dispatchSecurityBlock.includes("node tools/check_dispatch_trace_security.mjs --no-build")) {
  throw new Error("dispatch evidence/coverageの並列監査またはsecurity検査が不完全です");
}
if (!httpAotScript.includes("if (!noBuild) buildLnako();") || !httpAotScript.includes("else await access(executable);")) {
  throw new Error("AOT HTTPサーバー比較のno-build実装がありません");
}
if (!dispatchSecurityScript.includes("tests/fixtures/dispatch-security.nako3") || !dispatchSecurityScript.includes("assertExistingManifestPreserved") ||
    !dispatchSecurityScript.includes("assertFailedManifestRemoved") || !dispatchSecurityScript.includes("assertRepeatedSite")) {
  throw new Error("AOT dispatch securityのtiny fixture実装または不変条件検査が不完全です");
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
if (uploadActions.length !== 6 || (testJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 2 ||
    (nativeAotJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 3) {
  throw new Error(`actions/upload-artifactはmacOS dispatch 2＋AOT artifact 3＋attestation 1ステップ必要です: actual=${uploadActions.length}`);
}
const dispatchUploadBlock = aotStep("Upload native dispatch evidence");
if (!dispatchUploadBlock || !dispatchUploadBlock.includes("if: matrix.task == 'support' && always()") ||
    !dispatchUploadBlock.includes("name: lnako-dispatch-evidence-") || !dispatchUploadBlock.includes("dispatch-evidence-") ||
    !dispatchUploadBlock.includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch evidence artifactの設定が不正です");
}
const coverageUploadBlock = aotStep("Upload native dispatch coverage audit");
if (!coverageUploadBlock || !coverageUploadBlock.includes("if: matrix.task == 'support' && always()") ||
    !coverageUploadBlock.includes("name: lnako-dispatch-coverage-") || !coverageUploadBlock.includes("dispatch-coverage-") ||
    !coverageUploadBlock.includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch coverage artifactの設定が不正です");
}
if (!workflow.includes("if: matrix.suite == 'core' || matrix.suite == 'mac-core-standard-support'\n        with:\n          fetch-depth: 0") ||
    !workflow.includes("if: matrix.suite != 'core' && matrix.suite != 'mac-core-standard-support'\n      - uses: mlugg/setup-zig")) {
  throw new Error("coreの証拠追従検査に必要なfull checkout条件がありません");
}
const attestJob = workflow.match(/  attest-dispatch-evidence:[\s\S]*$/)?.[0];
if (!attestJob || !attestJob.includes("github.event_name == 'push'") || !attestJob.includes("github.ref == 'refs/heads/main'") ||
    !attestJob.includes("needs: [test, aot]") || !attestJob.includes("needs.test.result == 'success'") || !attestJob.includes("needs.aot.result == 'success'") || !attestJob.includes("id-token: write") || !attestJob.includes("attestations: write") || !attestJob.includes("artifact-metadata: write") ||
    !attestJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") || !attestJob.includes("merge-multiple: true") ||
    !attestJob.includes("actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2") || !attestJob.includes("node tools/verify_dispatch_attestation.mjs") ||
    !attestJob.includes("id: attest-dispatch") || !attestJob.includes("--bundle \"${{ steps.attest-dispatch.outputs.bundle-path }}\"") ||
    !attestJob.includes("${{ runner.temp }}/dispatch-attestation.json") || !attestJob.includes("${{ steps.attest-dispatch.outputs.bundle-path }}") ||
    !attestJob.includes("--commit \"${{ github.sha }}\"") || !attestJob.includes("--workflow \"${{ github.repository }}/.github/workflows/ci.yml\"") || !attestJob.includes("node tools/check_tracked_dispatch_attestation.mjs")) {
  throw new Error("dispatch evidenceのattestation／検証job設定が不正です");
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

const setupZigBlocks = [...workflow.matchAll(
  /      - uses: mlugg\/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2\.2\.1[\s\S]*?(?=      - uses: actions\/setup-node@)/g,
)].map((match) => match[0]);
const setupZigCacheSizeLimitMiB = 1536;
if (setupZigBlocks.length !== 2 ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat' }}") && block.includes("cache-key: ${{ matrix.suite }}")) ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.task == 'native' }}") && block.includes("cache-key: ${{ matrix.suite }}")) ||
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
if (cacheActions.length !== 4) throw new Error(`actions/cache v6.1.0固定SHAは4ステップ必要です: actual=${cacheActions.length}`);
const oracleBuild = setupOracle.match(/^const oracleBuild = (\d+);$/m)?.[1];
if (oracleBuild === undefined) throw new Error("setup_oracle.mjsのoracleBuildを取得できません");
if (Number(oracleBuild) !== oracleIdentity.build || !setupOracle.includes("oracleIdentity.cliSha256") || !setupOracle.includes("oracleIdentity.markerSha256") ||
    !setupOracle.includes("oracleTreeHash") || !setupOracle.includes("oracleTreeHashAlgorithm")) {
  throw new Error("公式オラクルのbuild／CLI／marker固定hash検証がsetup_oracle.mjsにありません");
}
const oracleCacheKey = `key: nadesiko3-oracle-3.7.24-\${{ runner.os }}-\${{ runner.arch }}-a${oracleArchiveSha256.slice(0, 12)}-v${oracleBuild}`;
if (!workflow.includes(oracleCacheKey)) throw new Error(`公式オラクルのキャッシュキーがoracleBuildと一致しません: ${oracleCacheKey}`);

console.log(`CI構成検査: ${matrixEntries.length}テストジョブ＋1 attestationジョブ・${stepSuites.size}条件付き検証ステップ成功`);

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不正です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
