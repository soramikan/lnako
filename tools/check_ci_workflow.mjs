import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const comparisonBenchmarkWorkflow = await readFile(resolve(root, ".github/workflows/comparison-benchmark.yml"), "utf8");
const floatingActions = [workflow, comparisonBenchmarkWorkflow]
  .flatMap((text) => [...text.matchAll(/uses: ([^\s@]+)@([^\s#]+)/g)])
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
const dispatchCoverageScript = await readFile(resolve(root, "tools/check_dispatch_coverage.mjs"), "utf8") +
  (await readFile(resolve(root, "tools/lib/coverage_fixtures.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/coverage_http.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/coverage_process.mjs"), "utf8"));
const dispatchCoverageShardsScript = await readFile(resolve(root, "tools/check_dispatch_coverage_shards.mjs"), "utf8");
const nativeOracleScript = await readFile(resolve(root, "tools/compare_native_oracle.mjs"), "utf8");
const nativeTimingScript = await readFile(resolve(root, "tools/native_oracle_timing.mjs"), "utf8");
const timingAggregateScript = await readFile(resolve(root, "tools/aggregate_native_timing.mjs"), "utf8");
const nativeAotArtifactChecker = await readFile(resolve(root, "tools/check_native_aot_artifacts.mjs"), "utf8");
const nativeAotAttestationVerifier = await readFile(resolve(root, "tools/verify_native_aot_attestation.mjs"), "utf8");
const interpreterOracleScript = await readFile(resolve(root, "tools/compare_interpreter_oracle.mjs"), "utf8");
const compatJsEvidenceScript = await readFile(resolve(root, "tools/check_compat_js_evidence.mjs"), "utf8");
const pruneLlvmToolchainScript = await readFile(resolve(root, "tools/prune_llvm_toolchain.mjs"), "utf8");
const setupLlvmScript = await readFile(resolve(root, "tools/setup_llvm.mjs"), "utf8");
const aotCompilerArtifactScript = await readFile(resolve(root, "tools/aot_compiler_artifact.mjs"), "utf8");
const classifyChangesScript = await readFile(resolve(root, "tools/classify_changes.mjs"), "utf8");
const trackedAttestationChecker = await readFile(resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "utf8");
const syncScript = await readFile(resolve(root, "tools/sync_compat_evidence.mjs"), "utf8");
const syncEvidence = syncScript +
  (await readFile(resolve(root, "tools/lib/evidence/validators.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/evidence/records.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/evidence/constants.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/evidence/attested_files.mjs"), "utf8")) +
  (await readFile(resolve(root, "tools/lib/evidence/promotion.mjs"), "utf8"));
const verifyAttestation = await readFile(resolve(root, "tools/verify_dispatch_attestation.mjs"), "utf8");
const evidenceFreshness = await readFile(resolve(root, "tools/check_evidence_freshness.mjs"), "utf8");
const evidenceUpdate = await readFile(resolve(root, "tools/update_current_evidence.mjs"), "utf8") +
  (await readFile(resolve(root, "tools/lib/evidence/generators.mjs"), "utf8"));
const evidenceProvenance = await readFile(resolve(root, "tools/lib/evidence/provenance.mjs"), "utf8");
if (!trackedAttestationChecker.includes("gh") || !trackedAttestationChecker.includes("--cert-oidc-issuer") || !trackedAttestationChecker.includes("--deny-self-hosted-runners") || !syncEvidence.includes("--historical-commit") || !syncEvidence.includes("canonical --output")) {
  throw new Error("tracked dispatch attestation checkerのhistorical commit／公式gh厳格検証が不完全です");
}
// canonical tracked evidence（揮発provenanceを持たない内容クレーム）の契約を固定する。
if (!syncEvidence.includes('form !== "measured" && form !== "canonical"') ||
    !syncEvidence.includes('isCanonicalEnvironment') ||
    !evidenceProvenance.includes("canonicalizeEvidenceDocument") ||
    !evidenceProvenance.includes("manifestContentSha256") ||
    !evidenceProvenance.includes("processOutputSha256") ||
    !evidenceProvenance.includes("freshnessBytes") ||
    !evidenceProvenance.includes("$1:<col>") ||
    !evidenceProvenance.includes("official-generated") ||
    !dispatchCoverageScript.includes("coverageFixtureStem") ||
    !dispatchCoverageScript.includes("coverageHttpPort") ||
    !dispatchCoverageScript.includes("coverageLoopbackPort") ||
    !dispatchCoverageScript.includes("allocateCoveragePorts") ||
    !dispatchCoverageScript.includes("resetCoveragePorts") ||
    !dispatchCoverageScript.includes("coverageHttpPortCandidates") ||
    !dispatchCoverageScript.includes('"${STATIC}": "static"') ||
    !dispatchCoverageScript.includes('replaced.replaceAll("${FILE}", fileNames[0])') ||
    !evidenceFreshness.includes('from "./lib/evidence/generators.mjs"') ||
    !evidenceFreshness.includes("freshnessBytes") ||
    !evidenceFreshness.includes("stageは差分診断用") ||
    !evidenceFreshness.includes("--dispatch-evidence") ||
    !evidenceFreshness.includes("--compat-js-evidence") ||
    !evidenceUpdate.includes('from "./lib/evidence/generators.mjs"') ||
    !evidenceUpdate.includes("canonicalizeEvidenceDocument")) {
  throw new Error("canonical evidence形・揮発値正規化・共有generator・freshness checkerの実装が不完全です");
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

// 変更分類jobは重いmatrixの前段として必須。allow-list方式で、判定不能は
// すべてfullへ倒す設計をtool側の実装とworkflowの両方から検査する。
const changesJob = workflow.match(/  changes:[\s\S]*?(?=\n  lightweight:)/)?.[0];
if (!changesJob || !changesJob.includes("name: Classify changes") ||
    !changesJob.includes("runs-on: ubuntu-24.04") || !changesJob.includes("timeout-minutes: 5") ||
    !changesJob.includes("level: ${{ steps.classify.outputs.level }}") ||
    !changesJob.includes("reason: ${{ steps.classify.outputs.reason }}") ||
    !changesJob.includes("fetch-depth: 0") ||
    !changesJob.includes("id: classify") ||
    !changesJob.includes("EVENT_NAME: ${{ github.event_name }}") ||
    !changesJob.includes("BASE_SHA: ${{ github.event.pull_request.base.sha || github.event.before }}") ||
    // 分類器はbase側の信頼済み版を実行する（PR側改変で軽量CIを騙せない）。
    !changesJob.includes('git show "$BASE_SHA:tools/classify_changes.mjs"') ||
    !changesJob.includes("reason=no-base-classifier") ||
    !changesJob.includes('node "$classifier" --event "$EVENT_NAME" --base "$BASE_SHA" --output "$GITHUB_OUTPUT"') ||
    // level出力欠落は全job静黙skipを招くためgrep検査でfailにする。
    !changesJob.includes("grep -qE '^level=(full|light)$' \"$GITHUB_OUTPUT\"")) {
  throw new Error("変更分類jobの構成（base版classifier実行・出力検証）が不完全です");
}
if (!classifyChangesScript.includes("export function isLightPath") ||
    !classifyChangesScript.includes("export function classify") ||
    !classifyChangesScript.includes("export function decide") ||
    !classifyChangesScript.includes("/^docs\\//") ||
    !classifyChangesScript.includes("/^[^/]+\\.md$/") ||
    !classifyChangesScript.includes("/^compat\\/[^/]+\\/attestations\\//") ||
    !classifyChangesScript.includes('"empty-diff"') ||
    !classifyChangesScript.includes('"no-base"') ||
    !classifyChangesScript.includes('"diff-error"') ||
    !classifyChangesScript.includes('"allow-list"') ||
    !classifyChangesScript.includes('"heavy-paths"') ||
    !classifyChangesScript.includes('event !== "pull_request" && event !== "push"') ||
    !classifyChangesScript.includes("realpathSync") ||
    // renameをdelete+addへ分解し、heavy→light移動を取りこぼさない。
    !classifyChangesScript.includes('"--no-renames"') ||
    !classifyChangesScript.includes("git") || !classifyChangesScript.includes("diff") ||
    !workflow.includes("run: node --test tools/classify_changes_test.mjs")) {
  throw new Error("変更分類toolのallow-list／安全側判定／rename分解・単体テストが不完全です");
}
// 軽量検証jobはlight相当の変更でもworkflow schema・追跡attestation・docs表・
// canonical evidenceの整合性を必ず検査する。buildを要する検査は含めない。
const lightweightJob = workflow.match(/  lightweight:[\s\S]*?(?=\n  test:)/)?.[0];
if (!lightweightJob || !lightweightJob.includes("if: needs.changes.outputs.level == 'light'") ||
    !lightweightJob.includes("needs: [changes]") ||
    !lightweightJob.includes("runs-on: ubuntu-24.04") ||
    !lightweightJob.includes("node tools/check_ci_workflow.mjs") ||
    !lightweightJob.includes("node tools/check_release_workflow.mjs") ||
    !lightweightJob.includes("node tools/check_dispatch_attestation_security.mjs") ||
    !lightweightJob.includes("node tools/check_tracked_dispatch_attestation.mjs --offline") ||
    !lightweightJob.includes("node tools/check_tracked_dispatch_attestation_security.mjs") ||
    !lightweightJob.includes("node tools/check_docs_current.mjs") ||
    !lightweightJob.includes("node tools/sync_compat.mjs --check") ||
    !lightweightJob.includes("node tools/sync_compat_evidence.mjs --check") ||
    !lightweightJob.includes("node tools/check_interpreter_only_classification.mjs --check") ||
    !lightweightJob.includes("node tools/check_builtin_catalog.mjs") ||
    !lightweightJob.includes("node tools/check_low_level_spec.mjs") ||
    !lightweightJob.includes("node tools/check_low_level_cases.mjs") ||
    !lightweightJob.includes("node tools/check_source_structure.mjs") ||
    !lightweightJob.includes("node tools/check_benchmark_result.mjs") ||
    !lightweightJob.includes("node tools/check_native_aot_artifacts.mjs --self-test") ||
    !lightweightJob.includes("node tools/check_distribution.mjs --self-test") ||
    !lightweightJob.includes("GITHUB_STEP_SUMMARY= node --test tools/macos_signing.test.mjs") ||
    !lightweightJob.includes("node --test tools/classify_changes_test.mjs")) {
  throw new Error("軽量検証jobの発動条件または整合性検査が不完全です");
}
// check_package_isolation.mjsはconsumer packageを実際にzig fetch・zig build
// するためzigが必要。軽量jobにはtoolchain setupが無いので含められない
// （full相当では引き続き実行される）。
if (lightweightJob.includes("zig build") || lightweightJob.includes("setup_llvm.mjs") ||
    lightweightJob.includes("setup_oracle.mjs") || lightweightJob.includes("compare_") ||
    lightweightJob.includes("setup_quickjs.mjs") || lightweightJob.includes("actions/cache@") ||
    lightweightJob.includes("mlugg/setup-zig@") ||
    lightweightJob.includes("check_package_isolation.mjs")) {
  throw new Error("軽量検証jobへbuild・oracle・toolchain setupを混入させないでください");
}
// 重いjobはすべてfull相当でのみ起動する。列挙ではなく全jobを走査して、
// changes／lightweight以外がneeds.changes.outputs.levelを参照しない追加を
// 将来も許さない構造にする。
const fullGate = "needs.changes.outputs.level == 'full'";
const jobsSection = workflow.slice(workflow.indexOf("\njobs:"));
const jobBlocks = [...jobsSection.matchAll(/^  ([a-zA-Z_-]+):\n(?=    )/gm)]
  .map((match, index, all) => {
    const end = index + 1 < all.length ? all[index + 1].index : jobsSection.length;
    return { name: match[1], block: jobsSection.slice(match.index, end) };
  });
const gatedJobs = jobBlocks.filter(({ name }) => name !== "changes" && name !== "lightweight");
if (jobBlocks.length !== 10 || gatedJobs.length !== 8 ||
    gatedJobs.some(({ block }) => !block.includes(fullGate) || !block.includes("needs: [changes"))) {
  throw new Error(`変更分類のfull gateを持たないjobがあります: ${gatedJobs.filter(({ block }) => !block.includes(fullGate) || !block.includes("needs: [changes")).map(({ name }) => name).join(",")}`);
}
const parserFuzzJob = workflow.match(/  parser_fuzz:[\s\S]*?(?=\n  aot_compiler:)/)?.[0];
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
const nativeAotJob = workflow.match(/  aot:[\s\S]*?(?=\n  (?:aot_windows|verify_dispatch_coverage|verify_native_aot_artifacts|attest-dispatch-evidence):)/)?.[0];
const windowsAotJob = workflow.match(/  aot_windows:[\s\S]*?(?=\n  (?:verify_dispatch_coverage|verify_native_aot_artifacts|attest-dispatch-evidence):)/)?.[0];
if (!nativeAotJob || !windowsAotJob) throw new Error("分割AOT jobがありません");
// Windows native行は専用consumer job（aot_windows）へ分離され、残りはaotへ残る。
// 行の期待集合は両jobをまたいで検証する。
const nativeShardRows = [...(nativeAotJob + windowsAotJob).matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: aot-native\n            task: native\n            fixtureShardIndex: (\d+)\n            fixtureShardCount: (\d+)\n            fixtureSharded: (true|false)\n            optimizationKey: (.+)\n            optimizations: (.+)\n            jobName: (.+)$/gm)]
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
  ["Differential Node host test", "host"],
  ["Distribution package self-test", "core"],
  ["Toolchain cache regression tests", "core"],
  ["Change classifier tests", "core"],
  ["Toolchain command check", "core"],
  ["Zig package isolation check", "core"],
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
        : "matrix.suite == 'compat-aot' || matrix.suite == 'mac-host-compat'";
  const pattern = new RegExp(`^      - name: ${escaped}\\n        if: ${condition.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m");
  if (!pattern.test(workflow)) throw new Error(`${name}のsuite条件が${suite}ではありません`);
}

const testJob = workflow.match(/  test:[\s\S]*?(?=\n  parser_fuzz:|\n  aot:)/)?.[0];
if (!testJob) throw new Error("通常test jobがありません");
if (!testJob.includes("name: Clear generated Zig install outputs\n        shell: bash\n        run: rm -rf -- zig-out")) {
  throw new Error("差分test前に生成Zig install出力を消去する再発防止策がありません");
}
// Zigのtest serverはテスト間で60秒無応答のrunnerを失敗扱いする。負荷の高い
// Windows runnerではtestプロセスがスケジュールされず60秒を超えることがある
// ため、両単体テストstepで上限を5分へ引き上げる。
if (!testJob.includes("run: zig build test --test-timeout 5m") ||
    !testJob.includes("run: zig build -Dcompat-js=true test --test-timeout 5m")) {
  throw new Error("単体テストstepの--test-timeout 5mがありません（Windows runnerのスケジューラ遅延でtest runnerが60s無応答扱いになるflake対策）");
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
  ["Build macOS normal ReleaseSafe compiler", ["matrix.suite == 'mac-host-compat'", "run: zig build -Doptimize=ReleaseSafe"]],
  ["Build macOS AOT verification compiler", ["matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat'", "run: zig build"]],
  ["macOS AOT HTTP server oracle", ["matrix.suite == 'mac-core-standard-support'", "node tools/compare_http_server_aot_oracle.mjs --no-build"]],
  ["macOS dispatch evidence audit", ["matrix.suite == 'mac-host-compat'", "node tools/check_dispatch_trace.mjs --no-build"]],
  ["macOS dispatch trace security audit", ["matrix.suite == 'mac-host-compat'", "node tools/check_dispatch_trace_security.mjs --no-build"]],
  ["Upload macOS native dispatch evidence", ["matrix.suite == 'mac-host-compat' && always()", "name: lnako-dispatch-evidence-macos-15"]],
  ["macOS compat-js evidence audit", ["matrix.suite == 'mac-host-compat'", "node tools/check_compat_js_evidence.mjs --no-build"]],
  ["Canonical evidence freshness", ["matrix.suite == 'mac-host-compat'", "node tools/check_evidence_freshness.mjs"]],
  ["Build macOS ReleaseSafe compiler", ["matrix.suite == 'mac-core-standard-support'", "run: zig build -Doptimize=ReleaseSafe"]],
  ["macOS normal smoke test", ["matrix.suite == 'mac-core-standard-support'", "./zig-out/bin/lnako test tests/fixtures/run-tests.nako3"]],
  ["Differential Node host test", ["matrix.suite == 'host' || matrix.suite == 'mac-host-compat'", "node tools/compare_node_http_oracle.mjs"]],
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
// canonical freshness は正本と同じ ReleaseSafe で測るため、mac-host-compat は
// normal ReleaseSafe → dispatch 生成 → QuickJS ReleaseSafe → compat-js 生成 →
// freshness（残りの生成＋比較）→ Debug build → Node host差分の順でなければ
// ならない。Debug 出力は比較しない。Node host差分はmac-core-standard-supportの
// クリティカルパスを外すため証拠生成の最後尾に置く。
const macHostCompatOrder = [
  "      - name: Build macOS normal ReleaseSafe compiler",
  "      - name: macOS dispatch evidence audit",
  "      - name: Test QuickJS build",
  "      - name: Build QuickJS compiler",
  "      - name: macOS compat-js evidence audit",
  "      - name: Canonical evidence freshness",
  "      - name: Build macOS AOT verification compiler",
  "      - name: Differential Node host test",
];
const macHostCompatPositions = macHostCompatOrder.map((marker) => testJob.indexOf(marker));
if (macHostCompatPositions.some((position) => position < 0) ||
    !macHostCompatPositions.every((position, index) => index === 0 || macHostCompatPositions[index - 1] < position)) {
  throw new Error("mac-host-compatのReleaseSafe証拠生成順が不正です（normal RS→dispatch→QuickJS RS→compat-js→freshness の順である必要があります）");
}
const freshnessBlock = testJob.slice(testJob.indexOf("      - name: Canonical evidence freshness"));
if (!freshnessBlock.includes('--dispatch-evidence "${{ runner.temp }}/dispatch-evidence-macos-15.json"') ||
    !freshnessBlock.includes('--compat-js-evidence "${{ runner.temp }}/compat-js-evidence.json"')) {
  throw new Error("Canonical evidence freshnessが既存のdispatch/compat-js生成物を転用していません");
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
if (!nativeAotBuildBlock || !nativeAotBuildBlock.includes("if: matrix.task != 'support-smoke' && !(matrix.task == 'support-dispatch-coverage' && matrix.os == 'ubuntu-24.04')") ||
    !nativeAotBuildBlock.includes("run: zig build")) {
  throw new Error("AOT検証用compilerの先行buildがありません");
}
// Windows native shardはproducerが1回buildしたDebug compilerを共有する。
// commit・platform・Zig version・SHA-256を照合してからinstallするため、
// 誤commitや別構成のcompilerを誤用する経路はない。consumerは専用jobへ分離し、
// 他OS・support shardがproducer失敗へ巻き込まれないようにする。
const aotCompilerJob = workflow.match(/  aot_compiler:[\s\S]*?(?=\n  aot:)/)?.[0];
if (!aotCompilerJob || !aotCompilerJob.includes("name: Windows x86_64 / AOT verification compiler") ||
    !aotCompilerJob.includes("runs-on: windows-2025") ||
    !aotCompilerJob.includes("key: toolchains-${{ runner.os }}-${{ runner.arch }}-v3-") ||
    !aotCompilerJob.includes("run: zig build") ||
    !aotCompilerJob.includes("Smoke test AOT verification compiler") ||
    !aotCompilerJob.includes("zig-out/bin/lnako.exe run") ||
    !aotCompilerJob.includes("node tools/aot_compiler_artifact.mjs create --binary zig-out/bin/lnako.exe --runtime-lib zig-out/lib/lnako_runtime.lib --out-dir") ||
    !aotCompilerJob.includes("name: lnako-aot-compiler-windows-x64") ||
    !aotCompilerJob.includes("if-no-files-found: error")) {
  throw new Error("Windows AOT compiler producer jobが不完全です");
}
// needsはjob全体に効くため、producer依存はconsumer job側のみに限定する。
// aotがaot_compilerへ依存するとLinux・macOS・support shardまで直列化され、
// producer失敗でmatrix全体がskipされる。
if (!nativeAotJob.includes("needs: [changes]\n") || nativeAotJob.includes("aot_compiler")) {
  throw new Error("aot jobがcompiler producerへ依存しています（直列化防止のためchangesのみへ依存させてください）");
}
if (!windowsAotJob.includes("needs: [changes, aot_compiler]") ||
    windowsAotJob.includes("run: zig build\n") ||
    (windowsAotJob.match(/suite: aot-native\n            task: native/g) ?? []).length !== 12 ||
    (windowsAotJob.match(/os: windows-2025/g) ?? []).length !== 12) {
  throw new Error("Windows AOT consumer jobがproducer・12 shard構成・build省略のいずれかを満たしていません");
}
const windowsAotStep = (name) => {
  const marker = "      - name: " + name;
  const start = windowsAotJob.indexOf(marker);
  if (start < 0) return null;
  const next = windowsAotJob.indexOf("\n      - name:", start + marker.length);
  return windowsAotJob.slice(start, next < 0 ? windowsAotJob.length : next);
};
const downloadCompilerBlock = windowsAotStep("Download shared AOT compiler artifact");
const installCompilerBlock = windowsAotStep("Verify and install shared AOT compiler");
if (!downloadCompilerBlock || !downloadCompilerBlock.includes("if: matrix.task == 'native' && matrix.os == 'windows-2025'") ||
    !downloadCompilerBlock.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") ||
    !downloadCompilerBlock.includes("name: lnako-aot-compiler-windows-x64") ||
    !installCompilerBlock || !installCompilerBlock.includes("if: matrix.task == 'native' && matrix.os == 'windows-2025'") ||
    !installCompilerBlock.includes("node tools/aot_compiler_artifact.mjs verify") ||
    !installCompilerBlock.includes("--install-to zig-out/bin")) {
  throw new Error("Windows native shardの共有compiler download／検証・install stepが不完全です");
}
// consumerでも差分テストとshard artifact uploadは維持する。
const windowsDifferentialBlock = windowsAotStep("Differential native AOT verification (fixture/route shard)");
const windowsUploadBlock = windowsAotStep("Upload native AOT oracle artifact");
if (!windowsDifferentialBlock || !windowsDifferentialBlock.includes("node tools/compare_native_oracle.mjs") ||
    !windowsDifferentialBlock.includes("--no-build") ||
    !windowsUploadBlock || !windowsUploadBlock.includes("if: matrix.task == 'native' && always()") ||
    !windowsUploadBlock.includes("name: lnako-native-oracle-${{ matrix.os }}-shard-${{ matrix.fixtureShardIndex }}-${{ matrix.optimizationKey }}")) {
  throw new Error("Windows AOT consumer jobの差分テストまたはshard artifact uploadがありません");
}
if (!aotCompilerArtifactScript.includes('"lnako.aot-compiler-artifact.v1"') ||
    !aotCompilerArtifactScript.includes("binarySha256") || !aotCompilerArtifactScript.includes("runtimeLibSha256") ||
    !aotCompilerArtifactScript.includes("buildMode") ||
    !aotCompilerArtifactScript.includes("compatJs") || !aotCompilerArtifactScript.includes("basename(name) !== name") ||
    !aotCompilerArtifactScript.includes('"..", "lib"') ||
    !aotCompilerArtifactScript.includes("rev-parse") || !aotCompilerArtifactScript.includes("toolchain.lock.json") ||
    !workflow.includes("node --test tools/setup_llvm_test.mjs tools/collect_ci_metrics_test.mjs tools/aot_compiler_artifact_test.mjs")) {
  throw new Error("AOT compiler artifactのmetadata照合または単体テストが不完全です");
}
// canonical正本（231件）のfreshnessは正本生成と同じReleaseSafeで測るため、
// それを供給するLinux coverage shardのbuildもReleaseSafeでなければならない。
const linuxCoverageBuildBlock = aotStep("Build AOT verification compiler (ReleaseSafe)");
if (!linuxCoverageBuildBlock || !linuxCoverageBuildBlock.includes("if: matrix.task == 'support-dispatch-coverage' && matrix.os == 'ubuntu-24.04'") ||
    !linuxCoverageBuildBlock.includes("run: zig build -Doptimize=ReleaseSafe")) {
  throw new Error("Linux dedicated dispatch coverage shardのReleaseSafe buildがありません");
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
// timing telemetryはcanonical artifactと別document・別artifactで扱い、
// median weight table（shard再配分）の入力にのみ使う。互換性evidenceの
// 契約へ性能値を混ぜないことをここで固定する。
if (!nativeOracleScript.includes("import { createTimingDocument, parseTimingPath, platformKey, roundMs, writeTimingDocument }") ||
    !nativeOracleScript.includes("const timingPath = parseTimingPath(process.argv, process.env);") ||
    !nativeOracleScript.includes("await writeTiming(") ||
    !nativeTimingScript.includes('"lnako.native-oracle-timing.v1"') ||
    !nativeTimingScript.includes("export function buildTimingAggregate") ||
    !nativeTimingScript.includes("export function medianOf") ||
    !nativeTimingScript.includes("LNAKO_NATIVE_ORACLE_TIMING") ||
    !timingAggregateScript.includes("buildTimingAggregate") ||
    !timingAggregateScript.includes("lnako-native-timing-*") ||
    !workflow.includes("node --test tools/native_oracle_timing_test.mjs")) {
  throw new Error("AOT fixture timing telemetryの分離実装または単体テストが不完全です");
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
// canonical正本（231件）のfreshnessはLinux dedicated shardのみが供給する。
// Linuxのcoverage shardにだけ--include-nativeがあり、他OSには無いことを確認する。
if (!dispatchCoverageBlock.includes("matrix.os != 'ubuntu-24.04'") || dispatchCoverageBlock.includes("--include-native")) {
  throw new Error("Linux以外のdispatch coverage shardに--include-nativeが混入しています");
}
const linuxCoverageBlock = aotStep("Dispatch coverage audit (native fixtures)");
if (!linuxCoverageBlock || !linuxCoverageBlock.includes("if: matrix.task == 'support-dispatch-coverage' && matrix.os == 'ubuntu-24.04'") ||
    !linuxCoverageBlock.includes("node tools/check_dispatch_coverage.mjs --no-build --include-native") ||
    !linuxCoverageBlock.includes("--fixture-shard-index") || !linuxCoverageBlock.includes("--fixture-shard-count") ||
    !linuxCoverageBlock.includes("--output")) {
  throw new Error("Linux dedicated dispatch coverage shardの--include-native監査が不完全です");
}
if (macCoverageBlock.includes("--include-native")) {
  throw new Error("macOS native相乗りdispatch coverage shardは既定56件のままにしてください");
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
if (uploadActions.length !== 10 || (testJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 1 ||
    (nativeAotJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 5 ||
    (windowsAotJob.match(/^        uses: actions\/upload-artifact@/gm) ?? []).length !== 2) {
  throw new Error(`actions/upload-artifactはmacOS dispatch evidence 1＋AOT artifact 4＋timing telemetry 4＋Windows consumer 2＋aggregate 1＋attestation 1ステップ必要です: actual=${uploadActions.length}`);
}
// timing telemetryは互換性evidenceとは別artifact名で分離する。集約検証は
// `lnako-native-oracle-*` globでpartitionを検査するため、名前が被ると
// 検証対象へ混入してしまう。
const nativeTimingUpload = aotStep("Upload native AOT timing telemetry");
if (!nativeTimingUpload || !nativeTimingUpload.includes("if: matrix.task == 'native' && always()") ||
    !nativeTimingUpload.includes("name: lnako-native-timing-${{ matrix.os }}-shard-${{ matrix.fixtureShardIndex }}-${{ matrix.optimizationKey }}") ||
    !nativeTimingUpload.includes("path: ${{ runner.temp }}/lnako-native-timing-${{ matrix.fixtureShardIndex }}-${{ matrix.optimizationKey }}.json") ||
    !nativeTimingUpload.includes("if-no-files-found: ignore") || !nativeTimingUpload.includes("retention-days: 30") ||
    nativeTimingUpload.includes("lnako-native-oracle-")) {
  throw new Error("AOT timing telemetry artifactの分離設定が不正です");
}
if (nativeTimingUpload.includes("run:")) throw new Error("AOT timing telemetry uploadで追加の検証コマンドを実行しないでください");
const windowsTimingUpload = windowsAotStep("Upload native AOT timing telemetry");
if (!windowsTimingUpload || !windowsTimingUpload.includes("name: lnako-native-timing-") || windowsTimingUpload.includes("lnako-native-oracle-")) {
  throw new Error("Windows AOT consumerのtiming telemetry artifact分離が不正です");
}
const nativeTimingVerificationBlock = aotStep("Differential native AOT verification (fixture/route shard)");
if (!nativeTimingVerificationBlock || !nativeTimingVerificationBlock.includes("LNAKO_NATIVE_ORACLE_TIMING: ${{ runner.temp }}/lnako-native-timing-") ||
    !windowsDifferentialBlock.includes("LNAKO_NATIVE_ORACLE_TIMING: ${{ runner.temp }}/lnako-native-timing-")) {
  throw new Error("AOT fixture／route shardのtiming telemetry出力先が未設定です");
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
if (!coverageVerificationJob || !coverageVerificationJob.includes("if: needs.changes.outputs.level == 'full' && needs.test.result == 'success' && needs.aot.result == 'success'") ||
    !coverageVerificationJob.includes("needs: [changes, test, aot]") ||
    !coverageVerificationJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") ||
    !coverageVerificationJob.includes("pattern: lnako-dispatch-coverage-*") ||
    !coverageVerificationJob.includes("merge-multiple: true") ||
    !coverageVerificationJob.includes("node tools/check_dispatch_coverage_shards.mjs") ||
    !coverageVerificationJob.includes("--shard-count 3") ||
    !dispatchCoverageShardsScript.includes("sampled-unattested-dispatch-audit-shard") ||
    !dispatchCoverageShardsScript.includes("assertSubset(darwinUnion, linuxUnion") ||
    !dispatchCoverageShardsScript.includes("mergeCoverageShards") ||
    !dispatchCoverageShardsScript.includes("freshnessBytes") ||
    !dispatchCoverageShardsScript.includes("diffLeafPaths") ||
    !dispatchCoverageShardsScript.includes("fixtureCount: 231") ||
    !dispatchCoverageShardsScript.includes("fixtureCount: 56") ||
    !dispatchCoverageScript.includes("const weightedFixtures = fixtures") ||
    !dispatchCoverageScript.includes(".sort((left, right) => right.weight - left.weight || left.index - right.index)") ||
    !dispatchCoverageScript.includes("--fixture-shard-index") || !dispatchCoverageScript.includes("--fixture-shard-count")) {
  throw new Error("dispatch coverage shardのdownload／重複・欠落検査jobが不完全です");
}
const nativeAotVerificationJob = workflow.match(/  verify_native_aot_artifacts:[\s\S]*?(?=\n  attest-dispatch-evidence:)/)?.[0];
if (!nativeAotVerificationJob || !nativeAotVerificationJob.includes("if: always() && needs.changes.outputs.level == 'full'") ||
    !nativeAotVerificationJob.includes("needs: [changes, aot, aot_windows]") ||
    !nativeAotVerificationJob.includes("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1") ||
    !nativeAotVerificationJob.includes("pattern: lnako-native-oracle-*") ||
    !nativeAotVerificationJob.includes("merge-multiple: false") ||
    !nativeAotVerificationJob.includes("node tools/check_native_aot_artifacts.mjs") ||
    !nativeAotVerificationJob.includes("--directory") || !nativeAotVerificationJob.includes("--commit \"${{ github.sha }}\"") ||
    !nativeAotVerificationJob.includes("--output") || !nativeAotVerificationJob.includes("Reject failed native AOT matrix") ||
    !nativeAotVerificationJob.includes("if: needs.aot.result == 'success' && needs.aot_windows.result == 'success'") ||
    !nativeAotVerificationJob.includes("if: needs.aot.result != 'success' || needs.aot_windows.result != 'success'") ||
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
    !attestJob.includes("needs: [changes, test, parser_fuzz, aot, aot_windows, verify_dispatch_coverage, verify_native_aot_artifacts]") || !attestJob.includes("needs.changes.outputs.level == 'full'") || !attestJob.includes("needs.test.result == 'success'") || !attestJob.includes("needs.parser_fuzz.result == 'success'") || !attestJob.includes("needs.aot.result == 'success'") || !attestJob.includes("needs.aot_windows.result == 'success'") || !attestJob.includes("needs.verify_dispatch_coverage.result == 'success'") || !attestJob.includes("needs.verify_native_aot_artifacts.result == 'success'") || !attestJob.includes("id-token: write") || !attestJob.includes("attestations: write") || !attestJob.includes("artifact-metadata: write") ||
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
// The attestation signs every canonical evidence file so that all proof
// namespaces can be promoted to verified, and the tracked current snapshot is
// validated instead of trusting any local artifact.
const trackedSubjectPaths = attestJob.match(/            compat\/v3\.7\.24\/[a-z-]+\.json/g) ?? [];
if (trackedSubjectPaths.length !== 17) throw new Error(`attestationがcanonical証拠17件をsubjectに含みません: actual=${trackedSubjectPaths.length}`);
for (const required of [
  "compat/v3.7.24/dispatch-evidence.json",
  "compat/v3.7.24/dispatch-coverage-evidence.json",
  "compat/v3.7.24/expected-exit-evidence.json",
  "compat/v3.7.24/compat-js-evidence.json",
  "compat/v3.7.24/global-binding-evidence.json",
  "compat/v3.7.24/directory-binding-evidence.json",
  "compat/v3.7.24/static-constant-evidence.json",
  "compat/v3.7.24/static-node-http-initial-constant-evidence.json",
]) {
  if (!attestJob.includes(`            ${required}\n`)) throw new Error(`attestation subject-pathに${required}がありません`);
}
if (!verifyAttestation.includes("dispatchAttestationSchemaV3") || !verifyAttestation.includes("trackedSubjects") ||
    !verifyAttestation.includes("trackedAttestationSubjects") || !verifyAttestation.includes("verifyWithGh(trackedPath, trackedSha256)") ||
    !verifyAttestation.includes("--source-manifest") || !verifyAttestation.includes("validateSourceManifestDeclarationBytes") ||
    !verifyAttestation.includes("verifyWithGh(sourceManifestDeclaration, declarationSha256)") ||
    !verifyAttestation.includes("sourceManifest: { name: sourceManifestDeclarationBasename, sha256: declarationSha256 }")) {
  throw new Error("dispatch attestation生成toolがv3のtracked subjects／source manifest宣言を検証・記録していません");
}
// source manifest宣言は canonical byte列として共有libが生成し、CI attestation
// jobが署名subjectへ含める。宣言生成stepはattest実行より前に必要。
const sourceManifestLib = await readFile(resolve(root, "tools/lib/evidence/source_manifest.mjs"), "utf8");
const emitDeclaration = await readFile(resolve(root, "tools/emit_source_manifest_declaration.mjs"), "utf8");
if (!sourceManifestLib.includes('"lnako.source-manifest.v1"') || !sourceManifestLib.includes("sourceManifestDeclarationBytes") ||
    !sourceManifestLib.includes("validateSourceManifestDeclarationBytes") ||
    !emitDeclaration.includes("computeSourceManifestSha256Sync") || !emitDeclaration.includes("sourceManifestDeclarationBytes") ||
    !attestJob.includes("node tools/emit_source_manifest_declaration.mjs") ||
    !attestJob.includes('${{ runner.temp }}/lnako-source-manifest.json') ||
    !attestJob.includes('--source-manifest "${{ runner.temp }}/lnako-source-manifest.json"') ||
    attestJob.indexOf("Generate source manifest declaration") > attestJob.indexOf("Generate artifact attestation")) {
  throw new Error("source manifest宣言の生成・署名subject・attestation検証が不完全です");
}
if (!syncEvidence.includes("signedEvidenceDigests") || !syncEvidence.includes("backingDigestByProof") ||
    !syncEvidence.includes("proofKeyForEvidenceDocument") || !syncEvidence.includes("deriveVerifiedCatalog") ||
    syncScript.includes("loadCurrentAttestation") || !syncScript.includes("--attestation")) {
  throw new Error("catalog証拠syncが導出verified viewまたは全証拠種別のverified昇格を実装していません");
}
// 現行のverified判定はGitHub Attestations。pointerファイルは廃止済み。
// --require-currentは履歴snapshot検査用に残し、Releaseは check_github_attestation.mjs を使う。
// CI workflow自体へは --require-current を付けない。
if (trackedAttestationChecker.includes("current.json") || trackedAttestationChecker.includes("--current-pointer") ||
    trackedAttestationChecker.includes("currentAttestationPointer") ||
    !trackedAttestationChecker.includes("loadCurrentAttestation") || !trackedAttestationChecker.includes("loadAttestationSnapshot") ||
    !trackedAttestationChecker.includes("--attestations-root") || !trackedAttestationChecker.includes("--snapshot") ||
    !trackedAttestationChecker.includes("--require-current") || !trackedAttestationChecker.includes("canonicalAttestationSchemaV2") ||
    !trackedAttestationChecker.includes("dispatchAttestationSchemaV3") || !trackedAttestationChecker.includes("validateSourceManifestDeclarationBytes") ||
    !trackedAttestationChecker.includes("deriveVerifiedCatalog") ||
    !trackedAttestationChecker.includes("verifyCurrentGithubAttestation") ||
    !trackedAttestationChecker.includes("GitHub Attestationsのオンライン検証が必要") ||
    !trackedAttestationChecker.includes("computeBackingDigestByProof") || !trackedAttestationChecker.includes("canonical catalog verified count")) {
  throw new Error("追跡attestation checkerが走査型current解決・宣言digest必須・導出view検証・GitHub attestationゲートに対応していません");
}
if (attestJob.includes("--require-current") || workflow.includes("attestations/current.json")) {
  throw new Error("CI workflowに廃止されたcurrent pointerまたは--require-currentが混入しています");
}
if (!syncEvidence.includes('"lnako.canonical-attestation.v1"') || !syncEvidence.includes('"lnako.canonical-attestation.v2"') ||
    !syncEvidence.includes('"lnako.dispatch-attestation.v3"') || !syncEvidence.includes("attestationsDirectory") ||
    !syncEvidence.includes("loadCurrentAttestation") ||
    !syncEvidence.includes("manifest.schema !== canonicalAttestationSchemaV2")) {
  throw new Error("canonical attestation schema識別子または走査型snapshot解決（v2候補限定）が共有libにありません");
}
// docs表はcanonical正本の常時unattestedを表示する。verified確認はGitHub Attestations。
const docsChecker = await readFile(resolve(root, "tools/check_docs_current.mjs"), "utf8");
if (docsChecker.includes("loadCurrentAttestation") || docsChecker.includes("deriveVerifiedCatalog") ||
    docsChecker.includes("--require-current") || docsChecker.includes("current.json")) {
  throw new Error("check_docs_currentが廃止したgit snapshot導出viewを検証しています");
}
if (!docsChecker.includes("GitHub Attestations") || !docsChecker.includes("attestation snapshotから導出したview")) {
  throw new Error("check_docs_currentがcanonical unattested表とsnapshot導出の廃止を検証していません");
}
const githubAttestationChecker = await readFile(resolve(root, "tools/check_github_attestation.mjs"), "utf8") +
  (await readFile(resolve(root, "tools/lib/evidence/github_attestation.mjs"), "utf8"));
if (!githubAttestationChecker.includes("verifyCurrentGithubAttestation") ||
    !githubAttestationChecker.includes("--deny-self-hosted-runners") ||
    !githubAttestationChecker.includes("trackedAttestationSubjects") ||
    !githubAttestationChecker.includes("deriveVerifiedCatalog") ||
    !githubAttestationChecker.includes("sourceManifestDeclarationBytes") ||
    !githubAttestationChecker.includes("attestationIdentity") ||
    !githubAttestationChecker.includes("同一bundleではありません")) {
  throw new Error("GitHub attestation検証toolが現行commitの公式gh verify・同一bundle・導出527に対応していません");
}
const snapshotCreator = await readFile(resolve(root, "tools/create_attestation_snapshot.mjs"), "utf8");
if (snapshotCreator.includes("current.json") || snapshotCreator.includes("currentAttestationPointer") ||
    !snapshotCreator.includes("canonicalAttestationSchemaV2") || !snapshotCreator.includes("sourceManifest: \"source-manifest.json\"") ||
    !snapshotCreator.includes("validateSourceManifestDeclarationBytes") ||
    !snapshotCreator.includes('else if (name === sourceManifestDeclarationBasename) files.set("sourceManifest", path)') ||
    !snapshotCreator.includes("catalog-evidence-verified.json") ||
    snapshotCreator.includes("updateCompatibilityDocs") || snapshotCreator.includes("<!-- attestation:verified -->") ||
    snapshotCreator.includes("gh pr create") || snapshotCreator.includes("publishGeneratedSnapshot") ||
    snapshotCreator.includes("--force-with-lease") || snapshotCreator.includes("attestation/run-") ||
    !snapshotCreator.includes("ローカル生成") ||
    !snapshotCreator.includes('"--snapshot"') || !snapshotCreator.includes('"--require-current"')) {
  throw new Error("snapshot作成toolがローカル生成のみ（git commit/PRなし）・manifest v2・pointer廃止に対応していません");
}
try {
  await readFile(resolve(root, ".github/workflows/update-attestation.yml"), "utf8");
  throw new Error("update-attestation workflowは廃止済みです");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}
if (!workflow.includes("tools/create_attestation_snapshot_test.mjs") ||
    !workflow.includes("tools/check_github_attestation_test.mjs")) {
  throw new Error("CIがattestation関連単体テストを実行していません");
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
// AOT native shardのZig cache identityはsuiteだけでなくfixture shardと
// optimizationまで含める（v2世代）。setup-zigは保存keyへrunId-attemptを付けて
// prefix一致で復元するため、同一prefixのshardが並行すると先行shardの未完成
// cacheを復元し、後続の保存がreservation競合で失敗する。
const nativeAotCacheKey = "cache-key: ${{ matrix.task == 'native' && format('aot-native-v2-s{0}of{1}-{2}', matrix.fixtureShardIndex, matrix.fixtureShardCount, matrix.optimizationKey) || matrix.suite }}";
if (setupZigBlocks.length !== 5 ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'mac-core-standard-support' || matrix.suite == 'mac-host-compat' }}") && block.includes("cache-key: ${{ matrix.suite }}")) ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: ${{ matrix.task == 'native' }}") && block.includes("matrix.fixtureShardIndex") && block.includes("matrix.optimizationKey")) ||
    countOccurrences(workflow, nativeAotCacheKey) !== 2 ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: true") && block.includes("cache-key: aot-compiler")) ||
    !setupZigBlocks.some((block) => block.includes("version: 0.16.0") && block.includes("use-cache: false")) ||
    (workflow.match(/cache-size-limit:/g) ?? []).length !== 4) {
  throw new Error(`setup-zigのcache保存対象、AOT shard／optimization単位のcache identity分離、または${setupZigCacheSizeLimitMiB} MiB上限が不正です`);
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
  nativeAotCacheKey,
  `cache-size-limit: ${setupZigCacheSizeLimitMiB}`,
  "timeout-minutes: 50",
]) if (!workflow.includes(required)) throw new Error(`CI安全設定がありません: ${required}`);

const oracleSkipConditions = workflow.match(/^        if: matrix\.suite != 'compat-aot'$/gm) ?? [];
if (oracleSkipConditions.length !== 3) {
  throw new Error(`compat-aotのオラクル／Node省略条件はcache・setup・Nodeの3件必要です: actual=${oracleSkipConditions.length}`);
}

const cacheActions = [...workflow.matchAll(/^      - uses: actions\/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0$/gm)];
if (cacheActions.length !== 8) throw new Error(`actions/cache v6.1.0固定SHAは8ステップ必要です: actual=${cacheActions.length}`);
// toolchain cache世代v3。keyにtoolchain定義とsetup scriptのhashを含め、
// marker欠落でpoisonedな旧世代cacheを復元しないようrestore-keysは付けない。
const toolchainCacheKey = "key: toolchains-${{ runner.os }}-${{ runner.arch }}-v3-${{ hashFiles('toolchain.lock.json', 'tools/setup_llvm.mjs', 'tools/setup_quickjs.mjs', 'tools/prune_llvm_toolchain.mjs') }}";
const toolchainCacheBlocks = [...workflow.matchAll(
  /      - uses: actions\/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0\n        with:\n          path: \.cache\/toolchains\n[\s\S]*?(?=\n      - |\n  [a-z_]+:|$)/g,
)].map((match) => match[0]);
if (countOccurrences(workflow, toolchainCacheKey) !== 4 ||
    toolchainCacheBlocks.length !== 4 || toolchainCacheBlocks.some((block) => block.includes("restore-keys:")) ||
    workflow.includes("-v2-minimal") ||
    countOccurrences(workflow, "run: node tools/prune_llvm_toolchain.mjs") !== 4) {
  throw new Error("LLVM toolchain cacheのv3世代key、旧世代restore-key排除、またはprune stepがtest／producer／AOT jobへ設定されていません");
}
// cache無効理由の分類出力と、prune→restore後もvalidと判定される回帰テストが
// cache再利用を壊す変更を防ぐ。理由文字列はCI計測がparseするため固定する。
if (!setupLlvmScript.includes("export async function cacheStatus") ||
    !setupLlvmScript.includes('"marker-missing"') || !setupLlvmScript.includes('"marker-invalid"') ||
    !setupLlvmScript.includes('"clang-missing"') || !setupLlvmScript.includes('"lld-missing"') ||
    !setupLlvmScript.includes('"version-mismatch"') || !setupLlvmScript.includes('"platform-mismatch"') ||
    !setupLlvmScript.includes('"sha256-mismatch"') ||
    !setupLlvmScript.includes("LLVM cache invalid:") || !setupLlvmScript.includes("LLVM cache valid:") ||
    !setupLlvmScript.includes("reason=") ||
    !workflow.includes("run: node --test tools/setup_llvm_test.mjs tools/collect_ci_metrics_test.mjs")) {
  throw new Error("LLVM cache無効理由の分類出力またはcache再利用回帰テストが不完全です");
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
for (const required of ["  pull_request:", "  push:", "  schedule:", "node tools/setup_oracle.mjs", "node tools/create_benchmark_oracle_shim.mjs", "--suite benchmarks/suites/v2.json", "node tools/setup_benchmark_gonako.mjs", "toolchain: 1.98.0", "--runtimes lnako,cnako,gonako,c,rust", '--profile "$BENCHMARK_PROFILE"', "retention-days: 90"]) {
  if (!comparisonBenchmarkWorkflow.includes(required)) throw new Error(`比較benchmarkの必須条件がありません: ${required}`);
}
if (comparisonBenchmarkWorkflow.includes("continue-on-error: true")) throw new Error("比較benchmarkの正しさ検証をcontinue-on-errorにできません");

checkBashFailFastBehavior();

console.log(`CI構成検査: 変更分類＋軽量検証＋${matrixEntries.length} matrixジョブ＋Windows AOT compiler producer＋coverage shard検証＋native AOT集約検証＋1 attestationジョブ・${stepSuites.size}条件付き検証ステップ成功`);

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
