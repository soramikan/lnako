import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/standard-plugin-cases.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const plugins = new Set(["plugin_math", "plugin_csv", "plugin_toml"]);
const expected = catalog.commands
  .filter((command) => plugins.has(command.plugin) || (command.plugin === "plugin_promise" && command.name === "束"))
  .map((command) => command.name)
  .sort();
const tested = cases.flatMap((testCase) => testCase.commands).sort();

if (new Set(tested).size !== tested.length) throw new Error("標準プラグイン差分テストの命令名が重複しています");
if (JSON.stringify(tested) !== JSON.stringify(expected)) {
  const testedSet = new Set(tested);
  const expectedSet = new Set(expected);
  throw new Error(`標準プラグイン命令カバレッジが不一致です: missing=${JSON.stringify(expected.filter((name) => !testedSet.has(name)))} extra=${JSON.stringify(tested.filter((name) => !expectedSet.has(name)))}`);
}
for (const testCase of cases) {
  for (const name of testCase.commands) {
    const implementation = implemented[name];
    if (implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) {
      throw new Error(`実装台帳に公式差分テストIDがありません: ${name} -> ${testCase.id}`);
    }
  }
}
console.log(`数学・CSV・TOML・Promise束の公式命令カバレッジ: ${expected.length}/${expected.length}`);
