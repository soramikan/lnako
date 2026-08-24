import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const implemented = JSON.parse(await readFile(implementationPath, "utf8"));
const sources = [
  ["tests/oracle/node-file-cases.json", "公式cnako3とのNodeホスト差分テストに成功"],
  ["tests/oracle/node-exit-cases.json", "独立プロセスで標準出力と終了コードの公式差分テストに成功"],
  ["tests/oracle/node-native-cases.json", "ZigネイティブZIPの作成・展開スモークテストに成功"],
];

for (const [path, reason] of sources) {
  const cases = JSON.parse(await readFile(resolve(root, path), "utf8"));
  for (const testCase of cases) for (const name of testCase.commands) register(name, testCase.id, reason);
}
const interrupt = JSON.parse(await readFile(resolve(root, "tests/oracle/node-interrupt-case.json"), "utf8"));
for (const name of interrupt.commands) register(name, interrupt.id, "SIGINTコールバックと終了結果の公式差分テストに成功");
register("ブラウザ起動", "plugin-node-host-open-external", "OS別外部起動をホスト抽象化へ委譲する単体テストに成功");
register("エクスプローラー起動", "plugin-node-host-open-external", "OS別ファイルマネージャー起動をホスト抽象化へ委譲する単体テストに成功");

const output = `${JSON.stringify(implemented, null, 2)}\n`;
if (process.argv.includes("--check")) {
  const current = await readFile(implementationPath, "utf8");
  if (current !== output) throw new Error("Node実装台帳が最新ではありません。node tools/update_node_implemented.mjs を実行してください");
} else {
  await writeFile(implementationPath, output);
  console.log("Node実装台帳を更新しました");
}

function register(name, testId, reason) {
  const current = implemented[name];
  const tests = new Set(current?.tests ?? []);
  tests.add(testId);
  implemented[name] = { status: "native", tests: [...tests], reason };
}
