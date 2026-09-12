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
if (catalog.issue !== 37) fail("issueが37ではありません");

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

const classByCapability = new Map();
for (const capability of catalog.capabilities) {
  if (!["portable_core", "posix_extension", "lnako_native"].includes(capability.class)) {
    fail(`${capability.id}のclassが不正です`);
  }
  classByCapability.set(capability.id, capability.class);
  const osValues = ["linux", "macos", "windows"].map((key) => capability.os?.[key]);
  const runtimeValues = ["lnako_interpreter", "lnako_aot", "cnako_node"].map((key) => capability.runtimes?.[key]);
  for (const key of ["linux", "macos", "windows"]) {
    const value = capability.os?.[key];
    if (value !== true && value !== false && value !== "conditional") {
      fail(`${capability.id}.os.${key}の値が不正です: ${value}`);
    }
  }
  for (const key of ["lnako_interpreter", "lnako_aot", "cnako_node"]) {
    const value = capability.runtimes?.[key];
    if (value !== true && value !== false && value !== "conditional") {
      fail(`${capability.id}.runtimes.${key}の値が不正です: ${value}`);
    }
  }
  if (JSON.stringify(Object.keys(capability.os).sort()) !== JSON.stringify(["linux", "macos", "windows"])) {
    fail(`${capability.id}.osのキーが不正です`);
  }
  if (JSON.stringify(Object.keys(capability.runtimes).sort()) !== JSON.stringify(["cnako_node", "lnako_aot", "lnako_interpreter"])) {
    fail(`${capability.id}.runtimesのキーが不正です`);
  }
  if (capability.class === "portable_core" && (osValues.some((value) => value !== true) || runtimeValues.some((value) => value !== true))) {
    fail(`${capability.id}はportable_coreだが、osまたはruntimesにtrue以外があります`);
  }
  if (capability.class === "lnako_native" && capability.runtimes.cnako_node !== false) {
    fail(`${capability.id}はlnako_nativeだが、cnako_nodeがfalseではありません`);
  }
  if (capability.class === "posix_extension" && capability.os.windows === true) {
    fail(`${capability.id}はposix_extensionだが、os.windowsがtrueです`);
  }
}
if (typeof catalog.matrixRule !== "string" || catalog.matrixRule.length === 0) fail("matrixRuleがありません");

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
  if (command.issue < 27 || command.issue > 37) fail(`${command.id}のissueが範囲外です`);
  if (command.maxArgs < command.minArgs || command.minArgs < 0) fail(`${command.id}のarityが不正です`);
  if (!typeSet.has(command.returns)) fail(`${command.id}のreturns型がtypesにありません: ${command.returns}`);
  if (command.capability !== null && !catalogCapabilityIds.has(command.capability)) {
    fail(`${command.id}が未知のcapabilityを参照しています: ${command.capability}`);
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