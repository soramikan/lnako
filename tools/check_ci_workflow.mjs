import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const setupOracle = await readFile(resolve(root, "tools/setup_oracle.mjs"), "utf8");
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
  ["Differential native AOT test", "aot"],
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

const nativeAotBlock = workflow.match(
  /      - name: Differential native AOT test[\s\S]*?(?=      - name:|$)/,
);
if (!nativeAotBlock) throw new Error("Differential native AOT testブロックがありません");
if (!nativeAotBlock[0].includes("if: matrix.suite == 'aot'")) throw new Error("Differential native AOT testのsuite条件がありません");
if (!nativeAotBlock[0].includes("LNAKO_NATIVE_ORACLE_ARTIFACT: ${{ runner.temp }}/lnako-native-oracle.json")) {
  throw new Error("AOT差分artifactの絶対出力先envがありません");
}
if ((nativeAotBlock[0].match(/node tools\/compare_native_oracle\.mjs/g) ?? []).length !== 1) {
  throw new Error("AOT差分比較は同一suite内で1回だけ実行してください");
}
const nativeAotBlockEnd = workflow.indexOf(nativeAotBlock[0]) + nativeAotBlock[0].length;
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
if (uploadActions.length !== 1) throw new Error(`actions/upload-artifactは1ステップだけ必要です: actual=${uploadActions.length}`);
if ((workflow.match(/name: lnako-native-oracle-\$\{\{ matrix\.os \}\}/g) ?? []).length !== 1) {
  throw new Error("AOT差分artifactのOS別保存名が一意に定義されていません");
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

for (const required of [
  "group: ci-${{ github.workflow }}-${{ github.ref }}",
  "cancel-in-progress: true",
  "cache-key: ${{ matrix.suite }}",
  "timeout-minutes: 50",
]) if (!workflow.includes(required)) throw new Error(`CI安全設定がありません: ${required}`);

const oracleSkipConditions = workflow.match(/^        if: matrix\.suite != 'compat-aot'$/gm) ?? [];
if (oracleSkipConditions.length !== 2) {
  throw new Error(`compat-aotのオラクル省略条件はcacheとsetupの2件必要です: actual=${oracleSkipConditions.length}`);
}

const cacheActions = [...workflow.matchAll(/^      - uses: actions\/cache@v6$/gm)];
if (cacheActions.length !== 2) throw new Error(`actions/cache@v6は2ステップ必要です: actual=${cacheActions.length}`);
const oracleBuild = setupOracle.match(/^const oracleBuild = (\d+);$/m)?.[1];
if (oracleBuild === undefined) throw new Error("setup_oracle.mjsのoracleBuildを取得できません");
if (Number(oracleBuild) !== oracleIdentity.build || !setupOracle.includes("oracleIdentity.cliSha256") || !setupOracle.includes("oracleIdentity.markerSha256") ||
    !setupOracle.includes("oracleTreeHash") || !setupOracle.includes("oracleTreeHashAlgorithm")) {
  throw new Error("公式オラクルのbuild／CLI／marker固定hash検証がsetup_oracle.mjsにありません");
}
const oracleCacheKey = `key: nadesiko3-oracle-3.7.24-\${{ runner.os }}-\${{ runner.arch }}-a${oracleArchiveSha256.slice(0, 12)}-v${oracleBuild}`;
if (!workflow.includes(oracleCacheKey)) throw new Error(`公式オラクルのキャッシュキーがoracleBuildと一致しません: ${oracleCacheKey}`);

console.log(`CI構成検査: ${actualMatrix.size}ジョブ・${stepSuites.size}条件付き検証ステップ成功`);

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不正です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
