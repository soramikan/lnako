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
const trackedAttestationChecker = await readFile(resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "utf8");
const syncEvidence = await readFile(resolve(root, "tools/sync_compat_evidence.mjs"), "utf8");
if (!trackedAttestationChecker.includes("gh") || !trackedAttestationChecker.includes("--cert-oidc-issuer") || !trackedAttestationChecker.includes("--deny-self-hosted-runners") || !syncEvidence.includes("--historical-commit") || !syncEvidence.includes("canonical --output")) {
  throw new Error("tracked dispatch attestation checkerのhistorical commit／公式gh厳格検証が不完全です");
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
const suites = ["core", "standard", "host", "aot", "compat-aot"];
const matrixEntries = [...workflow.matchAll(/^          - name: (.+)\n            os: (.+)\n            suite: (.+)$/gm)]
  .map((match) => ({ name: match[1], os: match[2], suite: match[3] }));
const actualMatrix = new Set(matrixEntries.map((entry) => `${entry.name}\0${entry.os}\0${entry.suite}`));
const expectedMatrix = new Set();
for (const [name, os] of platforms) for (const suite of suites) expectedMatrix.add(`${name}\0${os}\0${suite}`);
assertSetEqual(actualMatrix, expectedMatrix, "CI matrix");

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
  ["Differential native AOT oracle test", "aot"],
  ["Differential native AOT HTTP server test", "aot"],
  ["Differential native AOT dispatch security test", "aot"],
  ["Differential native AOT dispatch evidence", "aot"],
  ["Differential native AOT dispatch coverage", "aot"],
  ["Format", "core"],
  ["Test", "core"],
  ["Test QuickJS build", "compat-aot"],
  ["Build", "aot"],
  ["Build QuickJS compiler", "compat-aot"],
  ["Normal smoke test", "aot"],
  ["Compatibility smoke test", "compat-aot"],
]);
for (const [name, suite] of stepSuites) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^      - name: ${escaped}\\n        if: matrix\\.suite == '${suite}'$`, "m");
  if (!pattern.test(workflow)) throw new Error(`${name}のsuite条件が${suite}ではありません`);
}

const nativeAotStepNames = [
  "Differential native AOT oracle test",
  "Differential native AOT HTTP server test",
  "Differential native AOT dispatch security test",
  "Differential native AOT dispatch evidence",
  "Differential native AOT dispatch coverage",
];
const nativeAotBlocks = new Map();
let previousNativeAotBlockEnd = -1;
for (const name of nativeAotStepNames) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const block = workflow.match(new RegExp(`      - name: ${escaped}[\\s\\S]*?(?=      - name:|$)`))?.[0];
  if (!block) throw new Error(`${name}ブロックがありません`);
  if (!block.includes("if: matrix.suite == 'aot'")) throw new Error(`${name}のsuite条件がありません`);
  const blockStart = workflow.indexOf(block);
  if (blockStart < previousNativeAotBlockEnd) throw new Error(`AOT stepの順序が不正です: ${name}`);
  previousNativeAotBlockEnd = blockStart + block.length;
  nativeAotBlocks.set(name, block);
}
const nativeAotOracleBlock = nativeAotBlocks.get("Differential native AOT oracle test");
if (!nativeAotOracleBlock.includes("LNAKO_NATIVE_ORACLE_ARTIFACT: ${{ runner.temp }}/lnako-native-oracle.json") ||
    (nativeAotOracleBlock.match(/node tools\/compare_native_oracle\.mjs/g) ?? []).length !== 1) {
  throw new Error("AOT差分artifactまたはnative oracle比較stepが不正です");
}
const nativeAotHttpBlock = nativeAotBlocks.get("Differential native AOT HTTP server test");
if ((nativeAotHttpBlock.match(/node tools\/compare_http_server_aot_oracle\.mjs --no-build/g) ?? []).length !== 1) {
  throw new Error("AOT HTTPサーバー差分比較のno-build stepがありません");
}
if (!httpAotScript.includes("if (!noBuild) buildLnako();") || !httpAotScript.includes("else await access(executable);")) {
  throw new Error("AOT HTTPサーバー比較のno-build実装がありません");
}
const nativeAotSecurityBlock = nativeAotBlocks.get("Differential native AOT dispatch security test");
if ((nativeAotSecurityBlock.match(/node tools\/check_dispatch_trace_security\.mjs --no-build/g) ?? []).length !== 1) {
  throw new Error("AOT dispatch securityのtiny fixture stepがありません");
}
if (!dispatchSecurityScript.includes("tests/fixtures/dispatch-security.nako3") || !dispatchSecurityScript.includes("assertExistingManifestPreserved") ||
    !dispatchSecurityScript.includes("assertFailedManifestRemoved") || !dispatchSecurityScript.includes("assertRepeatedSite")) {
  throw new Error("AOT dispatch securityのtiny fixture実装または不変条件検査が不完全です");
}
const nativeAotEvidenceBlock = nativeAotBlocks.get("Differential native AOT dispatch evidence");
if (!nativeAotEvidenceBlock.includes("node tools/check_dispatch_trace.mjs --no-build --evidence-output")) {
  throw new Error("AOT dispatch evidenceの生成stepがありません");
}
const nativeAotCoverageBlock = nativeAotBlocks.get("Differential native AOT dispatch coverage");
if (!nativeAotCoverageBlock.includes("node tools/check_dispatch_coverage.mjs --no-build --output")) {
  throw new Error("AOT dispatch coverage auditの生成stepがありません");
}
const nativeAotBlockEnd = workflow.indexOf(nativeAotCoverageBlock) + nativeAotCoverageBlock.length;
const uploadName = "Upload native AOT oracle artifact";
const uploadStart = workflow.indexOf(`      - name: ${uploadName}`);
if (uploadStart !== nativeAotBlockEnd) throw new Error("AOT artifact uploadは差分比較の直後に配置してください");
const uploadBlock = workflow.match(
  /      - name: Upload native AOT oracle artifact[\s\S]*?(?=      - name:|$)/,
);
if (!uploadBlock) throw new Error("AOT差分artifact uploadブロックがありません");
const upload = uploadBlock[0];
for (const required of [
  "if: matrix.suite == 'aot' && always()",
  "continue-on-error: true",
  "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
  "name: lnako-native-oracle-${{ matrix.os }}",
  "path: ${{ runner.temp }}/lnako-native-oracle.json",
  "if-no-files-found: ignore",
  "retention-days: 30",
]) if (!upload.includes(required)) throw new Error(`AOT差分artifact uploadの設定がありません: ${required}`);
if (upload.includes("run:")) throw new Error("AOT差分artifact uploadで追加の検証コマンドを実行しないでください");
const uploadActions = workflow.match(/^        uses: actions\/upload-artifact@/gm) ?? [];
if (uploadActions.length !== 4) throw new Error(`actions/upload-artifactは4ステップ必要です: actual=${uploadActions.length}`);
if ((workflow.match(/name: lnako-native-oracle-\$\{\{ matrix\.os \}\}/g) ?? []).length !== 1) {
  throw new Error("AOT差分artifactのOS別保存名が一意に定義されていません");
}
const dispatchUploadBlock = workflow.match(/      - name: Upload native dispatch evidence[\s\S]*?(?=      - name:|$)/);
if (!dispatchUploadBlock || !dispatchUploadBlock[0].includes("matrix.suite == 'aot' && always()") ||
    !dispatchUploadBlock[0].includes("name: lnako-dispatch-evidence-${{ matrix.os }}") ||
    !dispatchUploadBlock[0].includes("dispatch-evidence-${{ matrix.os }}.json") ||
    !dispatchUploadBlock[0].includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch evidence artifactの設定が不正です");
}
const coverageUploadBlock = workflow.match(/      - name: Upload native dispatch coverage audit[\s\S]*?(?=      - name:|$)/);
if (!coverageUploadBlock || !coverageUploadBlock[0].includes("matrix.suite == 'aot' && always()") ||
    !coverageUploadBlock[0].includes("name: lnako-dispatch-coverage-${{ matrix.os }}") ||
    !coverageUploadBlock[0].includes("dispatch-coverage-${{ matrix.os }}.json") ||
    !coverageUploadBlock[0].includes("if-no-files-found: ignore")) {
  throw new Error("OS別dispatch coverage audit artifactの設定が不正です");
}
if ((workflow.match(/name: lnako-dispatch-coverage-\$\{\{ matrix\.os \}\}/g) ?? []).length !== 1) {
  throw new Error("dispatch coverage audit artifactのOS別保存名が一意に定義されていません");
}
const attestJob = workflow.match(/  attest-dispatch-evidence:[\s\S]*$/)?.[0];
if (!attestJob || !attestJob.includes("github.event_name == 'push'") || !attestJob.includes("github.ref == 'refs/heads/main'") ||
    !attestJob.includes("needs: test") || !attestJob.includes("id-token: write") || !attestJob.includes("attestations: write") || !attestJob.includes("artifact-metadata: write") ||
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
if ((workflow.match(/\.\/zig-out\/bin\/lnako/g) ?? []).length !== 6) throw new Error("lnako smokeコマンドの合計が従来の6件ではありません");

const setupZigBlock = workflow.match(
  /      - uses: mlugg\/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2\.2\.1[\s\S]*?(?=      - uses: actions\/setup-node@)/,
)?.[0];
const setupZigCacheSizeLimitMiB = 1536;
if (setupZigBlock === undefined ||
    !setupZigBlock.includes("version: 0.16.0") ||
    !setupZigBlock.includes("use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'aot' }}") ||
    !setupZigBlock.includes("cache-key: ${{ matrix.suite }}") ||
    !setupZigBlock.includes(`cache-size-limit: ${setupZigCacheSizeLimitMiB}`) ||
    (workflow.match(/use-cache:/g) ?? []).length !== 1 ||
    (workflow.match(/cache-size-limit:/g) ?? []).length !== 1) {
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
  "use-cache: ${{ matrix.suite == 'host' || matrix.suite == 'aot' }}",
  "cache-key: ${{ matrix.suite }}",
  `cache-size-limit: ${setupZigCacheSizeLimitMiB}`,
  "timeout-minutes: 50",
]) if (!workflow.includes(required)) throw new Error(`CI安全設定がありません: ${required}`);

const oracleSkipConditions = workflow.match(/^        if: matrix\.suite != 'compat-aot'$/gm) ?? [];
if (oracleSkipConditions.length !== 3) {
  throw new Error(`compat-aotのオラクル／Node省略条件はcache・setup・Nodeの3件必要です: actual=${oracleSkipConditions.length}`);
}

const cacheActions = [...workflow.matchAll(/^      - uses: actions\/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0$/gm)];
if (cacheActions.length !== 2) throw new Error(`actions/cache v6.1.0固定SHAは2ステップ必要です: actual=${cacheActions.length}`);
const oracleBuild = setupOracle.match(/^const oracleBuild = (\d+);$/m)?.[1];
if (oracleBuild === undefined) throw new Error("setup_oracle.mjsのoracleBuildを取得できません");
if (Number(oracleBuild) !== oracleIdentity.build || !setupOracle.includes("oracleIdentity.cliSha256") || !setupOracle.includes("oracleIdentity.markerSha256") ||
    !setupOracle.includes("oracleTreeHash") || !setupOracle.includes("oracleTreeHashAlgorithm")) {
  throw new Error("公式オラクルのbuild／CLI／marker固定hash検証がsetup_oracle.mjsにありません");
}
const oracleCacheKey = `key: nadesiko3-oracle-3.7.24-\${{ runner.os }}-\${{ runner.arch }}-a${oracleArchiveSha256.slice(0, 12)}-v${oracleBuild}`;
if (!workflow.includes(oracleCacheKey)) throw new Error(`公式オラクルのキャッシュキーがoracleBuildと一致しません: ${oracleCacheKey}`);

console.log(`CI構成検査: ${actualMatrix.size}テストジョブ＋1 attestationジョブ・${stepSuites.size}条件付き検証ステップ成功`);

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不正です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
