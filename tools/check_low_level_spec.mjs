import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");

async function read(relativePath) {
  return readFile(resolve(root, relativePath), "utf8");
}

async function readJson(relativePath) {
  return JSON.parse(await read(relativePath));
}

function fail(message) {
  throw new Error(`低レイヤー仕様検査: ${message}`);
}

const foundation = await read("src/runtime/low_level_foundation.zig");
const doc = await read("docs/low-level-api/catalog.json");
const mirror = await read("src/runtime/low_level_catalog.json");
if (doc !== mirror) fail("docs/low-level-api/catalog.jsonとsrc/runtime/low_level_catalog.jsonが一致しません");

const catalog = JSON.parse(doc);
const standard = await readJson("compat/v3.7.24/standard-cnako.json");

if (catalog.schema !== "lnako.low-level-catalog.v1") fail(`schemaが不正です: ${catalog.schema}`);
if (catalog.issue !== 38) fail("issueが38ではありません");

const capabilityEnum = /pub const Capability = enum \{([\s\S]*?)\n\s+pub fn/.exec(foundation)?.[1];
if (capabilityEnum === undefined) fail("low_level_foundation.zigからCapability enumを抽出できません");
const capabilityTags = [...capabilityEnum.matchAll(/^\s{4}([a-z][a-z0-9_]*),/gm)].map((match) => match[1]);
if (capabilityTags.length === 0) fail("Capability enumの抽出に失敗しました（タグが0件）");
const foundationCapabilityIds = new Set(capabilityTags);

const errorEnum = /pub const PortableErrorCode = enum \{([\s\S]*?)\n\s+pub fn/.exec(foundation)?.[1];
if (errorEnum === undefined) fail("low_level_foundation.zigからPortableErrorCode enumを抽出できません");
const errorTags = [...errorEnum.matchAll(/^\s{4}([A-Z][A-Z0-9_]*),/gm)].map((match) => match[1]);
if (errorTags.length === 0) fail("PortableErrorCode enumの抽出に失敗しました（タグが0件）");
const portableErrorCodes = new Set(errorTags);

if (catalog.capabilityCount !== catalog.capabilities.length) fail("capabilityCountがcapabilities件数と一致しません");
if (catalog.commandCount !== catalog.commands.length) fail("commandCountがcommands件数と一致しません");
const catalogCapabilityIds = new Set(catalog.capabilities.map((capability) => capability.id));
if (JSON.stringify([...catalogCapabilityIds].sort()) !== JSON.stringify([...foundationCapabilityIds].sort())) {
  fail("catalog.capabilitiesのid集合がfoundationのCapability enumと一致しません");
}

// foundationのcapabilityImplementedがtrueを返すcapability集合を抽出する。
// 正本のos/runtimesはこの実装状況と一致しなければならない。
const implementedSwitch = /pub fn capabilityImplemented[\s\S]*?=>\s*true/.exec(foundation)?.[0];
if (implementedSwitch === undefined) fail("capabilityImplementedの実装済みアームを抽出できません");
const implementedCapabilityIds = new Set([...implementedSwitch.matchAll(/\.([a-z][a-z0-9_]*)/g)].map((match) => match[1]));

function checkMatrix(matrix, keys, label) {
  if (typeof matrix !== "object" || matrix === null) fail(`${label}がありません`);
  if (JSON.stringify(Object.keys(matrix).sort()) !== JSON.stringify([...keys].sort())) {
    fail(`${label}のキーが不正です`);
  }
  for (const key of keys) {
    const value = matrix[key];
    if (value !== true && value !== false && value !== "conditional") {
      fail(`${label}.${key}の値が不正です: ${value}`);
    }
  }
  return keys.map((key) => matrix[key]);
}

const osKeys = ["linux", "macos", "windows"];
const runtimeKeys = ["lnako_interpreter", "lnako_aot", "cnako_node"];
const classByCapability = new Map();
for (const capability of catalog.capabilities) {
  if (!["portable_core", "posix_extension", "lnako_native"].includes(capability.class)) {
    fail(`${capability.id}のclassが不正です`);
  }
  classByCapability.set(capability.id, capability.class);
  // `os`/`runtimes` は現在の実装状況、`planned` は将来計画値。class別の
  // 成立条件は計画値へ適用し、実装状況はcapabilityImplementedと照合する。
  const osValues = checkMatrix(capability.os, osKeys, `${capability.id}.os`);
  const runtimeValues = checkMatrix(capability.runtimes, runtimeKeys, `${capability.id}.runtimes`);
  const planned = capability.planned;
  if (typeof planned !== "object" || planned === null) fail(`${capability.id}.plannedがありません`);
  const plannedOsValues = checkMatrix(planned.os, osKeys, `${capability.id}.planned.os`);
  const plannedRuntimeValues = checkMatrix(planned.runtimes, runtimeKeys, `${capability.id}.planned.runtimes`);
  // 低レイヤー命令はlnako独自拡張でありcnako側に命令が存在しないため、
  // 実装状況のcnako_nodeは常にfalse。
  if (capability.runtimes.cnako_node !== false) {
    fail(`${capability.id}.runtimes.cnako_nodeがfalseではありません（lnako独自拡張）`);
  }
  if (implementedCapabilityIds.has(capability.id)) {
    // InterpreterはホストのI/O提供有無に依存するためtrue/conditional。
    // AOTはpluginContextが常に全関数を提供するため恒にtrue。
    if (capability.runtimes.lnako_interpreter === false) {
      fail(`${capability.id}は実装済みだが、runtimes.lnako_interpreterがfalseです`);
    }
    if (capability.runtimes.lnako_aot !== true) {
      fail(`${capability.id}は実装済みだが、runtimes.lnako_aotがtrueではありません（AOTは常に提供）`);
    }
    if (osValues.every((value) => value === false)) {
      fail(`${capability.id}は実装済みだが、osが全てfalseです`);
    }
  } else if (osValues.some((value) => value !== false) || runtimeValues.some((value) => value !== false)) {
    fail(`${capability.id}は未実装だが、osまたはruntimesにfalse以外があります`);
  }
  if (capability.class === "portable_core" && (plannedOsValues.some((value) => value !== true) || plannedRuntimeValues.some((value) => value !== true))) {
    fail(`${capability.id}はportable_coreだが、plannedのosまたはruntimesにtrue以外があります`);
  }
  if (capability.class === "lnako_native" && planned.runtimes.cnako_node !== false) {
    fail(`${capability.id}はlnako_nativeだが、planned.runtimes.cnako_nodeがfalseではありません`);
  }
  if (capability.class === "posix_extension" && planned.os.windows === true) {
    fail(`${capability.id}はposix_extensionだが、planned.os.windowsがtrueです`);
  }
}
if (typeof catalog.matrixRule !== "string" || catalog.matrixRule.length === 0) fail("matrixRuleがありません");

// catalog_commandsの `implemented = true` 集合を抽出し、JSON側の
// `implemented` と照合する（正本は実行時の登録・dispatch実装と一致させる）。
const implementedCommandIds = new Set(
  [...foundation.matchAll(/\.\{[^}]*\.id = "([^"]+)"[^}]*\.implemented = true/g)].map((match) => match[1]),
);

const standardNames = new Set(standard.commands.map((command) => command.name));
const commandIds = new Set();
const commandNames = new Set();
const typeSet = new Set(Object.keys(catalog.types));
const parameterTypeSet = new Set(Object.keys(catalog.parameterTypes));
for (const command of catalog.commands) {
  if (typeof command.id !== "string" || command.id.length === 0) fail("command.idが不正です");
  if (commandIds.has(command.id)) fail(`command.idが重複しています: ${command.id}`);
  commandIds.add(command.id);
  if (commandNames.has(command.name)) fail(`command.nameが重複しています: ${command.name}`);
  commandNames.add(command.name);
  if (standardNames.has(command.name)) fail(`標準cnako 527件と衝突する名前があります: ${command.name}`);
  if (command.issue < 27 || command.issue > 38) fail(`${command.id}のissueが範囲外です`);
  if (command.maxArgs < command.minArgs || command.minArgs < 0) fail(`${command.id}のarityが不正です`);
  if (!typeSet.has(command.returns)) fail(`${command.id}のreturns型がtypesにありません: ${command.returns}`);
  if (command.capability !== null && !catalogCapabilityIds.has(command.capability)) {
    fail(`${command.id}が未知のcapabilityを参照しています: ${command.capability}`);
  }
  if (typeof command.implemented !== "boolean") fail(`${command.id}のimplementedがbooleanではありません`);
  if (command.implemented !== implementedCommandIds.has(command.id)) {
    fail(`${command.id}のimplemented(${command.implemented})がfoundationのcatalog_commandsと一致しません`);
  }
  if (typeof command.operation !== "string" || !/^[\x21-\x7e]+$/.test(command.operation)) {
    fail(`${command.id}のoperationが不正です（空白を含まないASCII可視文字の非空文字列が必須）: ${command.operation}`);
  }
  for (const errorCode of command.errors) {
    if (!portableErrorCodes.has(errorCode)) fail(`${command.id}が未知のerror codeを参照しています: ${errorCode}`);
  }
  const placeholders = [...new Set([...command.particles.matchAll(/[A-Z][A-Z0-9_]*/g)].map((match) => match[0]))];
  if (command.particles !== "") {
    if (placeholders.length === 0) fail(`${command.id}の助詞にプレースホルダがありません`);
    if (placeholders.length !== command.maxArgs) {
      fail(`${command.id}の助詞プレースホルダ数(${placeholders.length})とmaxArgs(${command.maxArgs})が一致しません`);
    }
    const alternativeCounts = command.particles.split("/").map((alternative) => {
      return new Set([...alternative.matchAll(/[A-Z][A-Z0-9_]*/g)].map((match) => match[0])).size;
    });
    const minimumAlternative = Math.min(...alternativeCounts);
    const maximumAlternative = Math.max(...alternativeCounts);
    if (minimumAlternative !== command.minArgs || maximumAlternative !== command.maxArgs) {
      fail(`${command.id}の助詞形の最小(${minimumAlternative})・最大(${maximumAlternative})がarity(${command.minArgs}..${command.maxArgs})と一致しません`);
    }
  }
  const overrides = command.paramTypes ?? {};
  for (const [name, typeName] of Object.entries(overrides)) {
    if (!typeSet.has(typeName)) fail(`${command.id}のparamTypes ${name}->${typeName}がtypesにありません`);
  }
  for (const placeholder of placeholders) {
    const resolved = overrides[placeholder] ?? catalog.parameterTypes[placeholder];
    if (resolved === undefined) fail(`${command.id}のプレースホルダ ${placeholder} がparameterTypesにもparamTypesにもありません`);
  }
  for (const [name, typeName] of Object.entries(overrides)) {
    if (!placeholders.includes(name)) fail(`${command.id}のparamTypes ${name}は助詞にありません`);
  }
}

for (const [typeName, schema] of Object.entries(catalog.typeSchemas ?? {})) {
  if (!typeSet.has(typeName)) fail(`typeSchemasの型 ${typeName} がtypesにありません`);
  for (const fieldType of Object.values(schema.fields)) {
    if (!typeSet.has(fieldType)) fail(`typeSchemas.${typeName} のフィールド型 ${fieldType} がtypesにありません`);
  }
}

for (const coreUtility of catalog.coreUtilities) {
  if (typeof coreUtility.utility !== "string" || coreUtility.utility.length === 0) fail("coreUtilityのutilityが不正です");
  for (const commandId of coreUtility.commands) {
    if (!commandIds.has(commandId)) fail(`${coreUtility.utility}が未知の命令IDを参照しています: ${commandId}`);
  }
  for (const capabilityId of coreUtility.capabilities) {
    if (!catalogCapabilityIds.has(capabilityId)) fail(`${coreUtility.utility}が未知のcapabilityを参照しています: ${capabilityId}`);
  }
}

for (const relativePath of [
  "docs/low-level-api/G0_FOUNDATION.md",
  "docs/low-level-api/COMMAND_CONTRACTS.md",
  "docs/low-level-api/CAPABILITY_MATRIX.md",
  "docs/low-level-api/PLUGIN_NODE_COMPAT.md",
  "docs/low-level-api/CORE_UTILITIES.md",
  "docs/low-level-api/TEST_HARNESS.md",
]) {
  const text = await read(relativePath).catch(() => null);
  if (text === null) fail(`必要な仕様文書がありません: ${relativePath}`);
  if (!text.includes("catalog.json")) fail(`${relativePath}がcatalog.jsonを参照していません`);
}

console.log(`低レイヤー仕様検査: 成功 (commands=${catalog.commandCount}, capabilities=${catalog.capabilityCount}, coreUtilities=${catalog.coreUtilities.length}, 527衝突なし)`);