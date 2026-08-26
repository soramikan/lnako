import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const requiredBoundaryCaseIds = new Set(["plugin-system-json-ecmascript-boundaries"]);
const categories = new Set([
  "システム定数",
  "四則演算",
  "論理演算",
  "ビット演算",
  "文字列処理",
  "置換・トリム",
  "文字変換",
  "指定形式",
  "文字種類",
  "型変換",
  "JSON",
  "正規表現",
  "配列操作",
  "二次元配列処理",
  "日時処理(簡易)",
  "URLエンコードとパラメータ",
  "BASE64",
  "辞書型変数の操作",
  "ハッシュ",
  "標準出力",
]);
const additionalNames = new Set(["拡張子抽出", "拡張子変更", "終端パス追加", "終端パス除去", "終端パス削除"]);
const expected = catalog.commands
  .filter((command) => command.plugin === "plugin_system" && (categories.has(command.category) || additionalNames.has(command.name)))
  .map((command) => command.name)
  .sort();
const tested = cases.flatMap((testCase) => testCase.commands).sort();
const catalogByName = new Map(catalog.commands.map((command) => [command.name, command]));
const caseIds = new Set(cases.map((testCase) => testCase.id));

for (const id of requiredBoundaryCaseIds) {
  if (!caseIds.has(id)) throw new Error(`必須plugin_system境界fixtureがありません: ${id}`);
}

if (new Set(tested).size !== tested.length) throw new Error("plugin_system差分テストの命令名が重複しています");
if (JSON.stringify(tested) !== JSON.stringify(expected)) {
  const testedSet = new Set(tested);
  const expectedSet = new Set(expected);
  const missing = expected.filter((name) => !testedSet.has(name));
  const extra = tested.filter((name) => !expectedSet.has(name));
  throw new Error(`plugin_system命令カバレッジが不一致です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
let nativeCount = 0;
let blockedCount = 0;
for (const testCase of cases) {
  for (const name of testCase.commands) {
    const command = catalogByName.get(name);
    const implementation = implemented[name];
    if (command?.status === "blocked") {
      if (implementation !== undefined) throw new Error(`blocked命令が実装台帳に残っています: ${name}`);
      blockedCount += 1;
      continue;
    }
    if (command?.status !== "native" || implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) {
      throw new Error(`実装台帳に公式差分テストIDがありません: ${name} -> ${testCase.id}`);
    }
    nativeCount += 1;
  }
}
console.log(
  `plugin_system対象${categories.size}カテゴリと追加${additionalNames.size}命令のインタープリタ公式差分カバレッジ: ${expected.length}/${expected.length}（台帳native ${nativeCount}、blocked ${blockedCount}）`,
);
