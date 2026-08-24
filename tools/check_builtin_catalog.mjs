import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const lines = [
  "/// なでしこ3 v3.7.24の標準cnako命令名。tools/sync_compat.mjsの固定データから生成。",
  "pub const names = [_][]const u8{",
  ...catalog.commands.map((command) => `    ${JSON.stringify(command.name)},`),
  "};",
  "",
];
const expected = lines.join("\n");
const actual = await readFile(resolve(root, "src/semantic/builtin_catalog.zig"), "utf8");
if (actual !== expected) throw new Error("組み込み命令索引がstandard-cnako.jsonと一致しません");
if (catalog.commands.length !== 527) throw new Error(`組み込み命令数が527件ではありません: ${catalog.commands.length}`);
console.log("組み込み命令索引を検証しました: 527件");
