import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
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
]);
const expected = catalog.commands
  .filter((command) => command.plugin === "plugin_system" && categories.has(command.category))
  .map((command) => command.name)
  .sort();
const tested = cases.flatMap((testCase) => testCase.commands).sort();

if (new Set(tested).size !== tested.length) throw new Error("plugin_system差分テストの命令名が重複しています");
if (JSON.stringify(tested) !== JSON.stringify(expected)) {
  const testedSet = new Set(tested);
  const expectedSet = new Set(expected);
  const missing = expected.filter((name) => !testedSet.has(name));
  const extra = tested.filter((name) => !expectedSet.has(name));
  throw new Error(`plugin_system命令カバレッジが不一致です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
for (const testCase of cases) {
  for (const name of testCase.commands) {
    const implementation = implemented[name];
    if (implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) {
      throw new Error(`実装台帳に公式差分テストIDがありません: ${name} -> ${testCase.id}`);
    }
  }
}
console.log(`plugin_system対象12カテゴリの公式命令カバレッジ: ${expected.length}/${expected.length}`);
