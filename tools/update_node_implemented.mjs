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
register("ファイル情報取得", "native-node-file-info", "公式7経路のファイル情報とメソッド型差分テストに成功");
for (const name of ["開", "読", "バイナリ読", "保存"]) register(name, "native-node-file-io", "公式7経路のファイル読み書きとBuffer境界の差分テストに成功");
for (const name of ["SJISファイル読", "SJISファイル保存", "EUCファイル読", "EUCファイル保存", "SJIS変換", "SJIS取得", "エンコーディング変換", "エンコーディング取得"]) register(name, "native-node-encoding", "公式7経路の文字コード変換・SJIS/EUCファイルI/O差分テストに成功");
for (const name of ["ファイル列挙", "全ファイル列挙", "フォルダ作成", "ファイルコピー", "ファイル上書コピー", "ファイル移動", "ファイル上書移動", "ファイル削除"]) register(name, "native-node-file-operations", "公式7経路のファイル列挙・再帰コピー・移動・削除差分テストに成功");
register("コンソールクリア", "native-node-console-clear", "公式7経路の標準出力境界でコンソールクリア差分テストに成功");
register("ハッシュ値計算", "native-node-crypto", "公式7経路のSHA-256・Buffer境界とエンコード形式の差分テストに成功");
register("ランダムUUID生成", "native-node-crypto", "公式7経路のUUID version・variantと形式の差分テストに成功");
register("ランダム配列生成", "native-node-crypto", "公式7経路のUint8Array長さ・要素境界の差分テストに成功");
register("ホームディレクトリ取得", "native-node-directory-values", "公式7経路のホームディレクトリ差分テストに成功");
register("デスクトップ", "native-node-directory-values", "公式7経路のデスクトップパス差分テストに成功");
register("マイドキュメント", "native-node-directory-values", "公式7経路のドキュメントパス差分テストに成功");
register("テンポラリフォルダ", "native-node-directory-values", "公式7経路の一時フォルダパス差分テストに成功");
register("母艦パス", "native-node-mother-path", "公式7経路の母艦パス差分テストに成功");
register("母艦パス取得", "native-node-mother-path", "公式7経路の母艦パス取得差分テストに成功");
register("一時フォルダ作成", "native-node-temporary-directory", "公式7経路の一時フォルダ作成差分テストに成功");
register("文字コード変換サポート判定", "native-node-encoding-support", "公式7経路の文字コード名サポート判定差分テストに成功");
register("標準入力全取得", "native-node-stdin-all", "公式7経路の標準入力全取得差分テストに成功");
register("尋", "native-node-stdin-lines", "公式7経路の標準入力行取得と数値変換差分テストに成功");
register("文字尋", "native-node-stdin-lines", "公式7経路の標準入力行取得と文字列境界差分テストに成功");
register("POSTデータ生成", "native-node-http-post-data", "公式7経路のPOSTデータ生成差分テストに成功");
register("AJAXオプション設定", "native-node-http-options-set", "公式7経路のAJAXオプション設定差分テストに成功");
register("AJAX失敗時", "native-node-http-onerror-set", "公式7経路のAJAX失敗時設定差分テストに成功");
register("自分IPアドレス取得", "native-node-network-addresses", "公式7経路のIPv4ネットワークアドレス差分テストに成功");
register("自分IPV6アドレス取得", "native-node-network-addresses", "公式7経路のIPv6ネットワークアドレス差分テストに成功");

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
