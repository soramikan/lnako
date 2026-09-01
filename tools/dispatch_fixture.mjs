import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const dispatchFixturePath = "tests/oracle/dispatch-cases.json";

export async function readDispatchFixture(root, cases) {
  const config = JSON.parse(await readFile(resolve(root, dispatchFixturePath), "utf8"));
  if (config?.schema !== "lnako.dispatch-fixture.v1" || config.fixture === null || typeof config.fixture !== "object") {
    throw new Error("dispatch専用fixture設定のschemaが不正です");
  }
  const definition = config.fixture;
  const sourcePrefix = definition.sourcePrefix ?? "";
  const postfixCommands = definition.postfixCommands ?? [];
  const sourcePostfix = definition.sourcePostfix ?? "";
  const catalogIds = definition.catalogIds ?? {};
  if (definition.baseFile !== "native-cases.json" || typeof definition.baseId !== "string" || definition.baseId.length === 0 ||
      typeof definition.id !== "string" || definition.id.length === 0 || typeof definition.sourceSuffix !== "string" ||
      !definition.sourceSuffix.endsWith("\n") || !Array.isArray(definition.commands) || definition.commands.length === 0 ||
      definition.commands.some((name) => typeof name !== "string" || name.length === 0) ||
      new Set(definition.commands).size !== definition.commands.length || !Array.isArray(postfixCommands) ||
      postfixCommands.some((name) => typeof name !== "string" || name.length === 0) ||
      new Set(postfixCommands).size !== postfixCommands.length || typeof sourcePostfix !== "string" ||
      (sourcePostfix.length > 0 && !sourcePostfix.endsWith("\n")) || typeof sourcePrefix !== "string" ||
      (sourcePrefix.length > 0 && !sourcePrefix.endsWith("\n")) || catalogIds === null || typeof catalogIds !== "object" ||
      Array.isArray(catalogIds) || Object.values(catalogIds).some((id) => typeof id !== "string" || id.length === 0) ||
      new Set(Object.values(catalogIds)).size !== Object.values(catalogIds).length) {
    throw new Error("dispatch専用fixture設定の定義が不正です");
  }
  const base = cases.find((candidate) => candidate.id === definition.baseId);
  if (base === undefined || !Array.isArray(base.commands) || typeof base.source !== "string") {
    throw new Error(`dispatch専用fixtureのbaseがありません: ${definition.baseId}`);
  }
  const commands = [...base.commands, ...definition.commands, ...postfixCommands];
  if (new Set(commands).size !== commands.length) throw new Error("dispatch専用fixtureのcommandsがbaseと重複しています");
  if (Object.keys(catalogIds).some((name) => !commands.includes(name))) throw new Error("dispatch専用fixtureのcatalog ID指定にないcommandsがあります");
  return {
    id: definition.id,
    file: definition.baseFile,
    source: `${sourcePrefix}${base.source}${base.source.endsWith("\n") ? "" : "\n"}${definition.sourceSuffix}${sourcePostfix}`,
    commands,
    catalogIds: new Map(Object.entries(catalogIds)),
  };
}
