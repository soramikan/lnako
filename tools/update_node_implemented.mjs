import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const implemented = JSON.parse(await readFile(implementationPath, "utf8"));
const sources = [
  ["tests/oracle/node-file-cases.json", "公式cnako3とのNodeホスト差分テストに成功"],
  ["tests/oracle/node-exit-cases.json", "独立プロセスで標準出力と終了コードの公式差分テストに成功"],
  ["tests/oracle/node-native-cases.json", "ZigネイティブZIPの作成・展開スモークテストに成功"],
  ["tests/oracle/node-crypto-cases.json", "Node 24との全ハッシュ別名・乱数境界の公式差分テストに成功"],
  ["tests/oracle/node-http-cases.json", "公式cnako3とのHTTP・ネットワーク差分テストに成功"],
  ["tests/oracle/http-server-cases.json", "公式cnako3との簡易HTTPサーバ実通信差分テストに成功"],
];

for (const [path, reason] of sources) {
  const loaded = JSON.parse(await readFile(resolve(root, path), "utf8"));
  const cases = Array.isArray(loaded) ? loaded : [loaded];
  for (const testCase of cases) for (const name of testCase.commands) register(name, testCase.id, reason);
}
const interrupt = JSON.parse(await readFile(resolve(root, "tests/oracle/node-interrupt-case.json"), "utf8"));
for (const name of interrupt.commands) register(name, interrupt.id, "SIGINTコールバックと終了結果の公式差分テストに成功");

register(
  "LINE送信",
  "native-node-line-message-discontinued",
  "公式生成JavaScript・lnako Interpreter/AOTの廃止エラー差分テストに成功（公式CLIは既知の経路差）",
);
register(
  "LINE画像送信",
  "native-node-line-image-discontinued",
  "公式生成JavaScript・lnako Interpreter/AOTの廃止エラー差分テストに成功（公式CLIは既知の経路差）",
);
register("終", "native-node-exit-alias", "公式7経路の終了処理差分テストに成功");
register("終了", "native-node-exit-japanese-alias", "公式7経路の終了処理差分テストに成功");
register("プロセス終", "native-node-exit-code", "公式7経路の終了処理差分テストに成功");
register("存在", "native-node-file-existence", "公式7経路のファイル存在判定差分テストに成功");
register("フォルダ存在", "native-node-file-existence", "公式7経路のフォルダ存在判定差分テストに成功");
register("ホームディレクトリ取得", "native-node-directory-values", "公式7経路のホームディレクトリ差分テストに成功");
register("デスクトップ", "native-node-directory-values", "公式7経路のデスクトップパス差分テストに成功");
register("マイドキュメント", "native-node-directory-values", "公式7経路のドキュメントパス差分テストに成功");
register("テンポラリフォルダ", "native-node-directory-values", "公式7経路の一時フォルダパス差分テストに成功");
register("母艦パス", "native-node-mother-path", "公式7経路の母艦パス差分テストに成功");
register("母艦パス取得", "native-node-mother-path", "公式7経路の母艦パス取得差分テストに成功");
register("一時フォルダ作成", "native-node-temporary-directory", "公式7経路の一時フォルダ作成差分テストに成功");

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
