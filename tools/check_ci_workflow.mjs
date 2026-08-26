import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const setupOracle = await readFile(resolve(root, "tools/setup_oracle.mjs"), "utf8");

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
const oracleCacheKey = `key: nadesiko3-oracle-3.7.24-\${{ runner.os }}-v${oracleBuild}`;
if (!workflow.includes(oracleCacheKey)) throw new Error(`公式オラクルのキャッシュキーがoracleBuildと一致しません: ${oracleCacheKey}`);

console.log(`CI構成検査: ${actualMatrix.size}ジョブ・${stepSuites.size}条件付き検証ステップ成功`);

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter((value) => !actual.has(value));
  const extra = [...actual].filter((value) => !expected.has(value));
  if (missing.length === 0 && extra.length === 0) return;
  throw new Error(`${label}が不正です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
