import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const implemented = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/implemented.json"), "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/compat-js-cases.json"), "utf8"));
const expected = catalog.commands.filter((command) => command.plannedMode === "compat-js").map((command) => command.name).sort();
const tested = cases.flatMap((testCase) => testCase.commands).sort();

if (new Set(tested).size !== tested.length || JSON.stringify(tested) !== JSON.stringify(expected)) {
  throw new Error(`QuickJS互換命令カバレッジが不一致です: expected=${JSON.stringify(expected)} tested=${JSON.stringify(tested)}`);
}
for (const testCase of cases) for (const name of testCase.commands) {
  const implementation = implemented[name];
  if (implementation?.status !== "compat-js" || !implementation.tests?.includes(testCase.id)) {
    throw new Error(`実装台帳にQuickJS公式差分テストIDがありません: ${name} -> ${testCase.id}`);
  }
}
for (const testCase of cases) for (const name of testCase.relatedCommands ?? []) {
  const implementation = implemented[name];
  if (implementation?.status !== "native" || !implementation.tests?.includes(testCase.id)) {
    throw new Error(`実装台帳にQuickJS境界テストIDがありません: ${name} -> ${testCase.id}`);
  }
}
console.log(`QuickJS互換命令カバレッジ: ${expected.length}/${expected.length}`);
