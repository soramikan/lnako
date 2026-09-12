import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");

async function readJson(relativePath) {
  return JSON.parse(await readFile(resolve(root, relativePath), "utf8"));
}

function fail(message) {
  throw new Error(`低レイヤーoracle検査: ${message}`);
}

const cases = await readJson("tests/oracle/low-level-cases.json");
const catalog = await readJson("docs/low-level-api/catalog.json");

if (cases.schema !== "lnako.low-level-cases.v1") fail(`schemaが不正です: ${cases.schema}`);
if (!Array.isArray(cases.cases)) fail("casesが配列ではありません");

const commandIdByName = new Map(catalog.commands.map((command) => [command.name, command.id]));
const ids = new Set();
for (const entry of cases.cases) {
  if (typeof entry.id !== "string" || entry.id.length === 0) fail("caseのidが不正です");
  if (ids.has(entry.id)) fail(`caseのidが重複しています: ${entry.id}`);
  ids.add(entry.id);
  if (typeof entry.source !== "string" || entry.source.length === 0) fail(`${entry.id}のsourceがありません`);
  if (!["official-source", "official-generated"].includes(entry.oracle)) fail(`${entry.id}のoracle指定が不正です`);
  if (!Array.isArray(entry.commands) || entry.commands.length === 0) fail(`${entry.id}のcommandsが空です`);
  if (new Set(entry.commands).size !== entry.commands.length) fail(`${entry.id}のcommandsが重複しています`);
  for (const name of entry.commands) {
    if (!commandIdByName.has(name)) fail(`${entry.id}がカタログにない命令を参照しています: ${name}`);
  }
  if (typeof entry.catalogIds !== "object" || entry.catalogIds === null) fail(`${entry.id}のcatalogIdsがありません`);
  const covered = Object.keys(entry.catalogIds);
  if (covered.length !== entry.commands.length || !entry.commands.every((name) => covered.includes(name))) {
    fail(`${entry.id}のcatalogIdsがcommandsを網羅していません`);
  }
  for (const [name, id] of Object.entries(entry.catalogIds)) {
    if (commandIdByName.get(name) !== id) fail(`${entry.id}のcatalogIdsがカタログと一致しません: ${name} -> ${id}`);
  }
}

console.log(`低レイヤーoracle検査: 成功 (cases=${cases.cases.length}, 未実装命令のfixtureは#27〜#36で追加する)`);