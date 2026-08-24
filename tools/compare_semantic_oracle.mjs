import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/semantic-cases.json"), "utf8"));
const { NakoCompiler } = await import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs")));
const probe = spawnSync("zig", ["build", "semantic-probe", "--", ...cases], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 16 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`semantic-probe失敗:\n${probe.stderr}`);
const actualCases = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

function collectOfficial(node, output = []) {
  if (!node || typeof node !== "object") return output;
  if (["let", "let_array", "let_prop", "inc", "def_local_var", "def_func", "def_test"].includes(node.type)) {
    output.push({ kind: "declaration", name: String(node.name ?? "").replace(/^main__/, ""), resolved: String(node.name ?? "") });
  } else if (node.type === "word") {
    output.push({ kind: "reference", name: String(node.value ?? "").replace(/^main__/, ""), resolved: String(node.value ?? "") });
  } else if (node.type === "func") {
    output.push({ kind: "call", name: String(node.name ?? "").replace(/^main__/, ""), resolved: String(node.name ?? "") });
  } else if (["ref_array", "ref_prop"].includes(node.type) && node.name?.value) {
    output.push({ kind: "reference", name: String(node.name.value).replace(/^main__/, ""), resolved: String(node.name.value) });
  }
  if (Array.isArray(node.blocks)) for (const child of node.blocks) collectOfficial(child, output);
  if (Array.isArray(node.index)) for (const child of node.index) collectOfficial(child, output);
  return output;
}

let failures = 0;
for (const [index, source] of cases.entries()) {
  const actual = actualCases[index];
  const expected = collectOfficial(new NakoCompiler().parse(source, "main.nako3"));
  if (actual.diagnostics || actual.diagnosticCount !== 0 || JSON.stringify(actual.bindings) !== JSON.stringify(expected)) {
    failures += 1;
    console.error(`名前解決差分: ${JSON.stringify(source)}\nofficial=${JSON.stringify(expected)}\nlnako  =${JSON.stringify(actual)}`);
  }
}
if (failures > 0) throw new Error(`意味解析の差分が${failures}件あります`);
console.log(`公式v3.7.24との名前解決差分テスト: ${cases.length}件成功`);
