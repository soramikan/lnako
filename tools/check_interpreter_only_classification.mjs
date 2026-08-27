import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const evidencePath = resolve(root, "compat/v3.7.24/evidence.json");
const standardPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const outputPath = resolve(root, "compat/v3.7.24/interpreter-only-classification.json");
const mode = process.argv[2] ?? "--check";

if (mode !== "--check" && mode !== "--generate") {
  throw new Error("usage: node tools/check_interpreter_only_classification.mjs [--check|--generate]");
}

const evidenceBytes = await readFile(evidencePath);
const evidence = JSON.parse(evidenceBytes.toString("utf8"));
const standard = JSON.parse(await readFile(standardPath, "utf8"));
if (evidence.schemaVersion !== 2 || evidence.commandCount !== 527 || !Array.isArray(evidence.entries) || evidence.entries.length !== 527) {
  throw new Error("evidence.jsonが標準cnako 527 entryのschema v2ではありません");
}
if (standard.schemaVersion !== 1 || standard.commandCount !== 527 || !Array.isArray(standard.commands) || standard.commands.length !== 527) {
  throw new Error("standard-cnako.jsonが527 entryではありません");
}

const standardById = new Map(standard.commands.map((command) => [command.id, command]));
const entries = evidence.entries
  .filter((entry) => entry.fixtureCoverageState === "interpreter-only")
  .map((entry) => {
    const command = standardById.get(entry.id);
    if (command === undefined) throw new Error(`標準カタログにentryがありません: ${entry.id}`);
    if (entry.aotFixtureIds.length !== 0) throw new Error(`interpreter-only entryにAOT fixtureがあります: ${entry.id}`);
    if (entry.executionEvidenceState !== "unverified") throw new Error(`interpreter-only entryがunverifiedではありません: ${entry.id}`);
    return {
      id: entry.id,
      name: entry.name,
      plugin: entry.plugin,
      group: command.group,
      category: command.category,
      type: command.type,
      plannedMode: command.plannedMode,
      status: entry.status,
      identityResolution: entry.identityResolution,
      fixtureCoverageState: entry.fixtureCoverageState,
      executionEvidenceState: entry.executionEvidenceState,
      interpreterFixtureIds: [...entry.interpreterFixtureIds],
      aotFixtureIds: [...entry.aotFixtureIds],
    };
  });

const groups = new Map();
for (const entry of entries) {
  const key = JSON.stringify([entry.plugin, entry.group, entry.category, entry.type]);
  const group = groups.get(key) ?? {
    plugin: entry.plugin,
    group: entry.group,
    category: entry.category,
    type: entry.type,
    count: 0,
    executionEvidenceStates: {},
    commandIds: [],
    names: [],
  };
  group.count += 1;
  group.executionEvidenceStates[entry.executionEvidenceState] = (group.executionEvidenceStates[entry.executionEvidenceState] ?? 0) + 1;
  group.commandIds.push(entry.id);
  group.names.push(entry.name);
  groups.set(key, group);
}

const report = {
  schemaVersion: 1,
  baseline: evidence.baseline,
  source: {
    path: "compat/v3.7.24/evidence.json",
    schemaVersion: evidence.schemaVersion,
    sha256: createHash("sha256").update(evidenceBytes).digest("hex"),
  },
  interpretation: "fixtureCoverageState=interpreter-onlyはinterpreter fixtureだけが明示関連付けされた状態であり、実装完了・AOT実行・公式等価性・verified証拠を意味しない",
  scope: {
    commandCount: evidence.commandCount,
    fixtureCoverageState: "interpreter-only",
    count: entries.length,
    executionEvidenceStates: Object.fromEntries(
      ["verified", "trace-confirmed-unattested", "unverified"].map((state) => [state, entries.filter((entry) => entry.executionEvidenceState === state).length]),
    ),
  },
  groups: [...groups.values()].sort((left, right) =>
    left.plugin.localeCompare(right.plugin) ||
    left.category.localeCompare(right.category) ||
    left.type.localeCompare(right.type) ||
    left.group.localeCompare(right.group),
  ),
  entries,
};

const expected = `${JSON.stringify(report, null, 2)}\n`;
if (mode === "--generate") {
  await writeFile(outputPath, expected);
  console.log(`interpreter-only分類を生成しました: ${entries.length}件、${report.groups.length}系統`);
} else {
  const actual = await readFile(outputPath, "utf8");
  if (actual !== expected) throw new Error(`interpreter-only分類が最新ではありません: ${outputPath}`);
  console.log(`interpreter-only分類を検証しました: ${entries.length}件、${report.groups.length}系統`);
}
