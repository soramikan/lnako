import { createHash } from "node:crypto";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lockPath = resolve(root, "compat/upstream.lock.json");
const snapshotPath = resolve(root, "compat/v3.7.24/command_list.json");
const matrixPath = resolve(root, "compat/v3.7.24/matrix.json");
const targetsPath = resolve(root, "compat/v3.7.24/standard-cnako.json");
const summaryPath = resolve(root, "compat/v3.7.24/summary.json");
const licensePath = resolve(root, "compat/v3.7.24/UPSTREAM_LICENSE");
const mode = process.argv[2] ?? "--check";

if (!new Set(["--check", "--refresh"]).has(mode)) {
  throw new Error("usage: node tools/sync_compat.mjs [--check|--refresh]");
}

const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const json = (value) => `${JSON.stringify(value, null, 2)}\n`;
const lock = JSON.parse(await readFile(lockPath, "utf8"));
const baseline = lock.nadesiko3;

async function fetchPinned(url, expectedHash) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`取得失敗: ${response.status} ${url}`);
  }
  const data = Buffer.from(await response.arrayBuffer());
  const actualHash = sha256(data);
  if (actualHash !== expectedHash) {
    throw new Error(`SHA-256不一致: ${url}\nexpected=${expectedHash}\nactual=${actualHash}`);
  }
  return data;
}

async function readOrRefresh(path, remote) {
  if (mode === "--refresh") {
    return fetchPinned(remote.url, remote.sha256);
  }
  const data = await readFile(path);
  const actualHash = sha256(data);
  if (actualHash !== remote.sha256) {
    throw new Error(`固定スナップショットのSHA-256不一致: ${path}`);
  }
  return data;
}

const commandListData = await readOrRefresh(snapshotPath, baseline.commandList);
const licenseData = await readOrRefresh(licensePath, baseline.license);
const commands = JSON.parse(commandListData.toString("utf8"));

if (!Array.isArray(commands) || commands.length !== 1145) {
  throw new Error(`公式命令総数が想定外です: ${commands.length}`);
}

const compatJsNames = new Set(["JS実行", "JSオブジェクト取得", "JS関数実行", "JSメソッド実行"]);
const platforms = ["macos-aarch64", "linux-x86_64-gnu", "windows-x86_64-msvc"];

function classify(command, index) {
  const isBuiltin = command.group === "基本プラグイン";
  const isCnako = Array.isArray(command.target) && command.target.includes("cnako");
  const inScope = isBuiltin && isCnako;
  const plannedMode = inScope && compatJsNames.has(command.name) ? "compat-js" : inScope ? "native" : null;
  let status;
  let reason;

  if (inScope) {
    status = "blocked";
    reason = "実装および公式処理系との差分テストを待機中";
  } else if (!isBuiltin) {
    status = "excluded-extension";
    reason = "外部拡張プラグインはv1対象外";
  } else {
    status = "excluded-browser";
    reason = "公式カタログで標準cnako対象に指定されていないホスト専用命令";
  }

  return {
    id: `command-${String(index + 1).padStart(4, "0")}`,
    name: command.name,
    plugin: command.plugin,
    group: command.group,
    targets: command.target,
    type: command.type,
    args: command.args,
    category: command.category,
    scope: inScope ? "standard-cnako-v1" : "out-of-scope-v1",
    plannedMode,
    status,
    tests: [],
    platforms: inScope ? platforms : [],
    reason,
  };
}

const entries = commands.map(classify);
const standardCnako = entries.filter((entry) => entry.scope === "standard-cnako-v1");
if (standardCnako.length !== 527) {
  throw new Error(`標準cnako命令数が想定外です: ${standardCnako.length}`);
}

const countsByPlugin = Object.fromEntries(
  [...new Set(standardCnako.map((entry) => entry.plugin))]
    .sort()
    .map((plugin) => [plugin, standardCnako.filter((entry) => entry.plugin === plugin).length]),
);
const expectedByPlugin = {
  plugin_caniuse: 2,
  plugin_csv: 7,
  plugin_datetime: 28,
  plugin_httpserver: 10,
  plugin_kansuji: 2,
  plugin_markup: 2,
  plugin_math: 38,
  plugin_node: 107,
  plugin_promise: 7,
  plugin_system: 322,
  plugin_toml: 2,
};
if (json(countsByPlugin) !== json(expectedByPlugin)) {
  throw new Error(`プラグイン別命令数が想定外です:\n${json(countsByPlugin)}`);
}

const matrix = {
  schemaVersion: 1,
  baseline: { tag: baseline.tag, commit: baseline.commit },
  sourceSha256: baseline.commandList.sha256,
  entries,
};
const targets = {
  schemaVersion: 1,
  baseline: matrix.baseline,
  commandCount: standardCnako.length,
  commands: standardCnako,
};
const countStatuses = (items) =>
  Object.fromEntries(
    [...new Set(items.map((entry) => entry.status))]
      .sort()
      .map((status) => [status, items.filter((entry) => entry.status === status).length]),
  );
const summary = {
  schemaVersion: 1,
  baseline: matrix.baseline,
  catalogCommands: entries.length,
  standardCnakoCommands: standardCnako.length,
  outOfScopeCommands: entries.length - standardCnako.length,
  statuses: countStatuses(entries),
  standardCnakoStatuses: countStatuses(standardCnako),
  standardCnakoPlannedModes: {
    native: standardCnako.filter((entry) => entry.plannedMode === "native").length,
    "compat-js": standardCnako.filter((entry) => entry.plannedMode === "compat-js").length,
  },
  standardCnakoByPlugin: countsByPlugin,
};

const outputs = [
  [matrixPath, json(matrix)],
  [targetsPath, json(targets)],
  [summaryPath, json(summary)],
];

if (mode === "--refresh") {
  await mkdir(dirname(snapshotPath), { recursive: true });
  await writeFile(snapshotPath, commandListData);
  await writeFile(licensePath, licenseData);
  for (const [path, content] of outputs) await writeFile(path, content);
  console.log("互換性スナップショットと分類表を更新しました");
} else {
  for (const [path, expected] of outputs) {
    const actual = await readFile(path, "utf8");
    if (actual !== expected) throw new Error(`生成物が最新ではありません: ${path}`);
  }
  console.log(`互換性資料を検証しました: 全${entries.length}件、標準cnako ${standardCnako.length}件`);
}
