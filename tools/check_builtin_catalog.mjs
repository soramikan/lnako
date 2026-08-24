import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const defaultPlugins = [
  "plugin_system",
  "plugin_math",
  "plugin_promise",
  "plugin_test",
  "plugin_csv",
  "plugin_toml",
  "plugin_node",
];
const defaultNames = [];
const seenDefaultNames = new Set();
for (const plugin of defaultPlugins) {
  const pluginNames = catalog.commands.filter((command) => command.plugin === plugin).map((command) => command.name);
  if (plugin === "plugin_test") pluginNames.push("ASSERT等", "テスト実行", "テスト等");
  if (plugin === "plugin_node") pluginNames.push("AJAX:ONERROR");
  for (const name of pluginNames) {
    if (name.startsWith("__") || name.startsWith("!") || name === "meta" || seenDefaultNames.has(name)) continue;
    seenDefaultNames.add(name);
    defaultNames.push({ name });
  }
}
const lines = [
  "/// なでしこ3 v3.7.24の標準cnako命令名。tools/sync_compat.mjsの固定データから生成。",
  "pub const names = [_][]const u8{",
  ...catalog.commands.map((command) => `    ${JSON.stringify(command.name)},`),
  "};",
  "",
  "/// 公式cnako3が既定で読み込む7プラグインの公開システム変数名。",
  "pub const default_names = [_][]const u8{",
  ...defaultNames.map((command) => `    ${JSON.stringify(command.name)},`),
  "};",
  "",
];
const expected = lines.join("\n");
const outputPath = resolve(root, "src/semantic/builtin_catalog.zig");
if (process.argv.includes("--generate")) {
  await writeFile(outputPath, expected);
} else {
  const actual = await readFile(outputPath, "utf8");
  if (actual !== expected) throw new Error("組み込み命令索引がstandard-cnako.jsonと一致しません");
}
if (catalog.commands.length !== 527) throw new Error(`組み込み命令数が527件ではありません: ${catalog.commands.length}`);
if (defaultNames.length !== 478) throw new Error(`既定システム変数名が478件ではありません: ${defaultNames.length}`);
console.log(`組み込み命令索引を${process.argv.includes("--generate") ? "生成" : "検証"}しました: 527件（既定478件）`);
