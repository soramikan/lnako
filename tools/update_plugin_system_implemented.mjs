import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const implemented = JSON.parse(await readFile(implementationPath, "utf8"));
const pluginCases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));
const runtimeCases = JSON.parse(await readFile(resolve(root, "tests/oracle/system-runtime-cases.json"), "utf8"));
const compatCases = JSON.parse(await readFile(resolve(root, "tests/oracle/compat-js-cases.json"), "utf8"));
const cases = [...pluginCases, ...runtimeCases];

for (const testCase of cases) for (const name of testCase.commands) {
  const current = implemented[name];
  // The plugin-system fixtures exercise the interpreter.  They are not, by
  // themselves, evidence that the command is connected to the pure LLVM AOT
  // path.  Only enrich an entry which was explicitly promoted to native after
  // its AOT differential fixture succeeded.
  if (current?.status !== "native") continue;
  const tests = new Set(current?.tests ?? []);
  tests.add(testCase.id);
  implemented[name] = {
    status: "native",
    tests: [...tests],
    reason: current.reason,
  };
}

for (const testCase of compatCases) for (const name of testCase.relatedCommands ?? []) {
  const current = implemented[name];
  if (current?.status !== "native") throw new Error(`QuickJS境界を追加するnative命令が未実装です: ${name}`);
  const tests = new Set(current.tests ?? []);
  tests.add(testCase.id);
  implemented[name] = { ...current, tests: [...tests] };
}

register("秒後", "native-system-timers", "公式7経路の単発タイマー順序・停止・終了時ドレイン差分テストに成功");
register("秒毎", "native-system-timers", "公式7経路の周期タイマーとコールバック内停止差分テストに成功");
register("秒タイマー開始時", "native-system-timers", "公式7経路の秒毎別名とコールバック内停止差分テストに成功");
register("タイマー停止", "native-system-timers", "公式7経路の個別タイマー停止差分テストに成功");
register("全タイマー停止", "native-system-timers", "公式7経路の一括タイマー停止差分テストに成功");
register("動時", "native-system-promise-success", "公式7経路のPromise生成と解決差分テストに成功");
register("成功時", "native-system-promise-success", "公式7経路の成功連鎖差分テストに成功");
register("処理時", "native-system-promise-reject-process-finally", "公式7経路の成功・失敗処理連鎖差分テストに成功");
register("失敗時", "native-system-promise-reject", "公式7経路の失敗連鎖差分テストに成功");
register("終了時", "native-system-promise-reject-process-finally", "公式7経路のfinally連鎖差分テストに成功");
register("束", "native-system-promise-bundle", "公式7経路の入力順・空入力・失敗束ね差分テストに成功");

function register(name, testId, reason) {
  const current = implemented[name];
  const tests = new Set(current?.tests ?? []);
  tests.add(testId);
  implemented[name] = { status: "native", tests: [...tests], reason };
}

const output = `${JSON.stringify(implemented, null, 2)}\n`;
if (process.argv.includes("--check")) {
  if (await readFile(implementationPath, "utf8") !== output) throw new Error("plugin_system実装台帳が最新ではありません");
} else {
  await writeFile(implementationPath, output);
  console.log("plugin_system実装台帳を更新しました");
}
