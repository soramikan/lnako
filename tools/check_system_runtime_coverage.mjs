import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/system-runtime-cases.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const categories = new Set(["敬語", "特殊命令", "デバッグ支援", "プラグイン管理"]);
// `終`はプロセス終了の専用ハーネスで、実プロセスの終了コードまで検証する。
const externallyCovered = new Set(["終"]);
const expected = catalog.commands
  .filter(
    (command) =>
      command.plugin === "plugin_system" &&
      categories.has(command.category) &&
      implemented[command.name]?.status === "native" &&
      !externallyCovered.has(command.name),
  )
  .map((command) => command.name)
  .sort();
const catalogByName = new Map(catalog.commands.map((command) => [command.name, command]));
const tested = cases
  .flatMap((testCase) => testCase.commands)
  .filter((name) => catalogByName.get(name)?.plugin === "plugin_system")
  .sort();

if (new Set(tested).size !== tested.length) throw new Error("system runtime差分テストの命令名が重複しています");
if (JSON.stringify(tested) !== JSON.stringify(expected)) {
  const testedSet = new Set(tested);
  const expectedSet = new Set(expected);
  const missing = expected.filter((name) => !testedSet.has(name));
  const extra = tested.filter((name) => !expectedSet.has(name));
  throw new Error(`system runtime命令カバレッジが不一致です: missing=${JSON.stringify(missing)} extra=${JSON.stringify(extra)}`);
}
for (const testCase of cases) {
  for (const name of testCase.commands) {
    const implementation = implemented[name];
    if (implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) {
      throw new Error(`実装台帳に公式差分テストIDがありません: ${name} -> ${testCase.id}`);
    }
  }
}
console.log(`system runtime公式命令カバレッジ: ${expected.length}/${expected.length}`);
