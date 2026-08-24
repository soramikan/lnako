import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const implemented = JSON.parse(await readFile(implementationPath, "utf8"));
const pluginCases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));
const runtimeCases = JSON.parse(await readFile(resolve(root, "tests/oracle/system-runtime-cases.json"), "utf8"));
const compatCases = JSON.parse(await readFile(resolve(root, "tests/oracle/compat-js-cases.json"), "utf8"));
const cases = [...pluginCases, ...runtimeCases];
const runtimeCaseIds = new Set(runtimeCases.map((testCase) => testCase.id));

for (const testCase of cases) for (const name of testCase.commands) {
  const current = implemented[name];
  const tests = new Set(current?.tests ?? []);
  tests.add(testCase.id);
  implemented[name] = {
    status: "native",
    tests: [...tests],
    reason:
      current?.status === "native"
        ? current.reason
        : runtimeCaseIds.has(testCase.id)
          ? "Zig製実行時システム命令で公式cnako3との差分テストに成功"
          : "Zig製plugin_system実装で公式cnako3との差分テストに成功",
  };
}

for (const testCase of compatCases) for (const name of testCase.relatedCommands ?? []) {
  const current = implemented[name];
  if (current?.status !== "native") throw new Error(`QuickJS境界を追加するnative命令が未実装です: ${name}`);
  const tests = new Set(current.tests ?? []);
  tests.add(testCase.id);
  implemented[name] = { ...current, tests: [...tests] };
}

const output = `${JSON.stringify(implemented, null, 2)}\n`;
if (process.argv.includes("--check")) {
  if (await readFile(implementationPath, "utf8") !== output) throw new Error("plugin_system実装台帳が最新ではありません");
} else {
  await writeFile(implementationPath, output);
  console.log("plugin_system実装台帳を更新しました");
}
