import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const supplementalCases = JSON.parse(await readFile(resolve(root, "tests/oracle/parser-cases.json"), "utf8"));
const { NakoCompiler } = await import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs")));
const { PARSER_CORPUS } = await import(pathToFileURL(resolve(oracleRoot, "core/test/fixtures/parser_corpus.mjs")));
const cases = [...new Set([...Object.values(PARSER_CORPUS), ...supplementalCases])];

const probe = spawnSync("zig", ["build", "parser-probe", "--", ...cases], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 32 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`parser-probe失敗:\n${probe.stderr}`);
const actualCases = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

function cleanName(value) {
  return String(value ?? "").replace(/^main__/, "");
}

function normalizeOfficial(node) {
  if (!node || typeof node !== "object") return null;
  const children = [];
  if (Array.isArray(node.blocks)) children.push(...node.blocks);
  if (Array.isArray(node.index)) children.push(...node.index);
  return {
    type: node.type,
    name: cleanName(typeof node.name === "string" ? node.name : node.name?.value ?? node.word),
    value: cleanName(node.value),
    operator: String(node.operator ?? ""),
    josi: String(node.josi ?? ""),
    arguments: (Array.isArray(node.args) ? node.args : Array.isArray(node.names) ? node.names : [])
      .map((arg) => ({ name: cleanName(arg.value), josi: String(arg.josi ?? "") })),
    children: children.map(normalizeOfficial),
  };
}

function normalizeLnako(node) {
  let children = node.children;
  // lnako keeps the variable expression as the first internal child so HIR
  // lowering can evaluate it. The official AST stores that expression in
  // ref_array/ref_prop.name and exposes only the indexes as children.
  if ((node.type === "ref_array" || node.type === "ref_prop") &&
      children.length > 0 &&
      (children[0].type === "word" || children[0].type === "ref_array" || children[0].type === "ref_prop")) {
    children = children.slice(1);
  }
  // Boolean and NULL literals are represented as primitive nodes internally;
  // the official parser keeps these built-in names as word nodes and resolves
  // them through the standard catalog later.
  const type = node.type === "boolean" || node.type === "null_value" ? "word" : node.type;
  return {
    type,
    name: cleanName(node.name),
    value: cleanName(node.value),
    operator: node.operator,
    josi: node.josi,
    arguments: node.arguments.map((arg) => ({ name: cleanName(arg.name), josi: arg.josi })),
    children: children.map(normalizeLnako),
  };
}

// eol/nopはプリプロセッサのコメント保持方式に依存するので構文フィンガープリントから除く。
function fingerprint(node, output = []) {
  if (node.type !== "block" && node.type !== "eol" && node.type !== "nop") {
    output.push([node.type, node.name, String(node.value), node.operator, node.josi, node.arguments]);
  }
  for (const child of node.children) fingerprint(child, output);
  return output;
}

function canonicalize(node) {
  const children = node.children.map(canonicalize);
  if (node.type === "op" && node.operator === "*" && children.length === 2 &&
      children[0].type === "number" && children[0].value === "-1" && children[1].type === "number") {
    return {
      ...node,
      type: "number",
      value: String(-Number(children[1].value)),
      operator: "",
      children: [],
    };
  }
  return { ...node, children };
}

let failures = 0;
for (const [index, source] of cases.entries()) {
  const actual = actualCases[index];
  if (actual.diagnostics) {
    failures += 1;
    console.error(`lnako構文エラー: ${JSON.stringify(source)}\n${JSON.stringify(actual.diagnostics)}`);
    continue;
  }
  let official;
  try {
    official = new NakoCompiler().parse(source, "main.nako3");
  } catch (error) {
    failures += 1;
    console.error(`公式構文エラー: ${JSON.stringify(source)}\n${error}`);
    continue;
  }
  const expectedFingerprint = fingerprint(canonicalize(normalizeOfficial(official)));
  const actualFingerprint = fingerprint(canonicalize(normalizeLnako(actual)));
  if (JSON.stringify(actualFingerprint) !== JSON.stringify(expectedFingerprint)) {
    failures += 1;
    console.error(`AST差分: ${JSON.stringify(source)}\nofficial=${JSON.stringify(expectedFingerprint)}\nlnako  =${JSON.stringify(actualFingerprint)}`);
  }
}
if (failures > 0) throw new Error(`構文解析の差分が${failures}件あります`);
console.log(`公式v3.7.24とのAST差分テスト: ${cases.length}件成功`);
