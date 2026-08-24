import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/supplemental-plugin-cases.json"), "utf8"));
const plugins = new Set(["plugin_markup", "plugin_caniuse", "plugin_kansuji"]);
const expected = catalog.commands.filter((command) => plugins.has(command.plugin)).map((command) => command.name).sort();
const tested = cases.flatMap((testCase) => testCase.commands).sort();

if (new Set(tested).size !== tested.length || JSON.stringify(tested) !== JSON.stringify(expected)) {
  throw new Error(`追加標準プラグイン命令カバレッジが不一致です: expected=${JSON.stringify(expected)} tested=${JSON.stringify(tested)}`);
}
for (const testCase of cases) for (const name of testCase.commands) {
  const implementation = implemented[name];
  if (implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) throw new Error(`実装台帳に公式差分テストIDがありません: ${name} -> ${testCase.id}`);
}
console.log(`markup・caniuse・kansuji命令カバレッジ: ${expected.length}/${expected.length}`);
