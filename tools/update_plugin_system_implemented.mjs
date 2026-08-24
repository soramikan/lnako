import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const implementationPath = resolve(root, "compat/v3.7.24/implemented.json");
const implemented = JSON.parse(await readFile(implementationPath, "utf8"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/plugin-system-cases.json"), "utf8"));

for (const testCase of cases) for (const name of testCase.commands) {
  const current = implemented[name];
  const tests = new Set(current?.tests ?? []);
  tests.add(testCase.id);
  implemented[name] = {
    status: "native",
    tests: [...tests],
    reason: current?.status === "native" ? current.reason : "Zig製plugin_system実装で公式cnako3との差分テストに成功",
  };
}

const output = `${JSON.stringify(implemented, null, 2)}\n`;
if (process.argv.includes("--check")) {
  if (await readFile(implementationPath, "utf8") !== output) throw new Error("plugin_system実装台帳が最新ではありません");
} else {
  await writeFile(implementationPath, output);
  console.log("plugin_system実装台帳を更新しました");
}
