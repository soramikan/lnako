import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const categories = new Set(["ファイル入出力", "パス操作", "フォルダ取得", "環境変数", "圧縮・解凍", "Nodeプロセス", "コマンドラインと標準入出力", "文字コード", "ネットワーク", "Ajax", "新AJAX", "LINE", "ハッシュ関数"]);
const expected = catalog.commands.filter((command) => (command.plugin === "plugin_node" && categories.has(command.category)) || command.plugin === "plugin_httpserver").map((command) => command.name).sort();
const mappings = new Map();

for (const path of ["tests/oracle/node-file-cases.json", "tests/oracle/node-exit-cases.json", "tests/oracle/node-native-cases.json", "tests/oracle/node-crypto-cases.json", "tests/oracle/node-http-cases.json", "tests/oracle/http-server-cases.json"]) {
  const loaded = JSON.parse(await readFile(resolve(root, path), "utf8"));
  for (const testCase of Array.isArray(loaded) ? loaded : [loaded]) for (const name of testCase.commands) add(name, testCase.id);
}
const interrupt = JSON.parse(await readFile(resolve(root, "tests/oracle/node-interrupt-case.json"), "utf8"));
for (const name of interrupt.commands) add(name, interrupt.id);
add("ブラウザ起動", "plugin-node-host-open-external");
add("エクスプローラー起動", "plugin-node-host-open-external");

const tested = [...mappings.keys()].sort();
if (JSON.stringify(expected) !== JSON.stringify(tested)) {
  const testedSet = new Set(tested);
  const expectedSet = new Set(expected);
  throw new Error(`Nodeマイルストーン命令カバレッジが不一致です: missing=${JSON.stringify(expected.filter((name) => !testedSet.has(name)))} extra=${JSON.stringify(tested.filter((name) => !expectedSet.has(name)))}`);
}
for (const [name, testIds] of mappings) {
  const implementation = implemented[name];
  for (const testId of testIds) {
    if (implementation?.status !== "native" || !implementation.tests?.includes(testId)) throw new Error(`実装台帳にテストIDがありません: ${name} -> ${testId}`);
  }
}
console.log(`Nodeホスト・HTTP・暗号・簡易HTTPサーバ命令カバレッジ: ${expected.length}/${expected.length}`);

function add(name, testId) {
  const testIds = mappings.get(name) ?? new Set();
  testIds.add(testId);
  mappings.set(name, testIds);
}
