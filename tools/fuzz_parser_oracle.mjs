import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleValue = oracleArg >= 0 ? process.argv[oracleArg + 1] : null;
if (oracleArg >= 0 && !oracleValue) throw new Error("--oracleにはディレクトリを指定してください");
const oracleRoot = resolve(
  oracleValue ?? process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const regressionPath = resolve(root, "tests/oracle/fuzz-regressions.json");
const iterations = parsePositiveOption("--iterations", 128);
const seed = parseSeed(process.argv.includes("--seed") ? process.argv[process.argv.indexOf("--seed") + 1] : "20260829");
const recordArg = process.argv.indexOf("--record");
const recordValue = recordArg >= 0 ? process.argv[recordArg + 1] : null;
if (recordArg >= 0 && !recordValue) throw new Error("--recordには出力先を指定してください");
const recordPath = recordValue === null ? null : resolve(recordValue);

if (process.argv.includes("--seed") && !process.argv[process.argv.indexOf("--seed") + 1]) throw new Error("--seedには数値を指定してください");

const [{ NakoCompiler }] = await Promise.all([
  import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs"))),
]);
const regressions = JSON.parse(await readFile(regressionPath, "utf8"));
if (!Array.isArray(regressions) || regressions.some((source) => typeof source !== "string")) {
  throw new Error("文法fuzz回帰fixtureは文字列配列で指定してください");
}

class Rng {
  constructor(value) {
    this.state = value >>> 0 || 1;
  }

  next() {
    let value = this.state;
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    this.state = value >>> 0;
    return this.state;
  }

  int(maximum) {
    return this.next() % maximum;
  }

  pick(values) {
    return values[this.int(values.length)];
  }
}

function parsePositiveOption(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index < 0) return fallback;
  const value = Number(process.argv[index + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name}には正の整数を指定してください`);
  return value;
}

function parseSeed(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 0xffffffff) throw new Error("seedには1以上4294967295以下の整数を指定してください");
  return parsed;
}

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
      .map((argument) => ({ name: cleanName(argument.value), josi: String(argument.josi ?? "") })),
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
    arguments: node.arguments.map((argument) => ({ name: cleanName(argument.name), josi: argument.josi })),
    children: children.map(normalizeLnako),
  };
}

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

function runProbe(sources) {
  const results = [];
  let batch = [];
  let batchLength = 0;
  const flush = () => {
    if (batch.length === 0) return;
    const probe = spawnSync("zig", ["build", "parser-probe", "--", ...batch], {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
      maxBuffer: 32 * 1024 * 1024,
    });
    if (probe.status !== 0) throw new Error(`parser-probe失敗:\n${probe.stderr}`);
    const output = probe.stdout.trimEnd();
    const lines = output === "" ? [] : output.split("\n");
    if (lines.length !== batch.length) throw new Error(`parser-probeの結果件数が不正です: expected=${batch.length} actual=${lines.length}`);
    results.push(...lines.map((line) => JSON.parse(line)));
    batch = [];
    batchLength = 0;
  };
  for (const source of sources) {
    // Keep CreateProcess command lines below Windows' limit while retaining
    // one parser build for several cases on every platform.
    if (batch.length > 0 && batchLength + source.length + 1 > 12_000) flush();
    batch.push(source);
    batchLength += source.length + 1;
  }
  flush();
  return results;
}

function compareSource(source, actual) {
  let official;
  let officialError = null;
  try {
    official = new NakoCompiler().parse(source, "main.nako3");
  } catch (error) {
    officialError = error;
  }
  const actualError = Array.isArray(actual.diagnostics) && actual.diagnostics.length > 0 ? actual.diagnostics[0] : null;
  const officialAccepted = officialError === null;
  const actualAccepted = actualError === null;
  if (officialAccepted !== actualAccepted) {
    return {
      kind: "acceptance-mismatch",
      officialAccepted,
      actualAccepted,
      officialError: officialError ? String(officialError) : null,
      actualError,
    };
  }
  if (!officialAccepted) return null;
  const expected = fingerprint(canonicalize(normalizeOfficial(official)));
  const received = fingerprint(canonicalize(normalizeLnako(actual)));
  if (JSON.stringify(received) === JSON.stringify(expected)) return null;
  return { kind: "ast-mismatch", expected, received };
}

const identifiers = ["A", "B", "C", "N", "X"];
const numericLiterals = ["0", "1", "2", "3", "2.5", "-1", "1n"];
const stringLiterals = ["\"\"", "\"a\"", "\"あ\"", "\"😀\"", "『固定値』"];
const binaryOperators = ["+", "-", "*", "**", "÷", "%", "==", "===", "!=", "!==", ">", ">=", "<", "<=", "かつ", "または"];

function expression(rng, depth = 0) {
  if (depth >= 2) return leafExpression(rng);
  switch (rng.int(10)) {
    case 0:
    case 1:
      return leafExpression(rng);
    case 2:
      return `[${expression(rng, depth + 1)},${expression(rng, depth + 1)}]`;
    case 3:
      return `{"a":${expression(rng, depth + 1)},"1":${expression(rng, depth + 1)}}`;
    case 4:
      return `(${expression(rng, depth + 1)}${rng.pick(binaryOperators)}${expression(rng, depth + 1)})`;
    case 5:
      return `${rng.pick(identifiers)}[${rng.int(3)}]`;
    case 6:
      return `LEN(${expression(rng, depth + 1)})`;
    case 7:
      return `文字数(${expression(rng, depth + 1)})`;
    case 8:
      return `JSON変換(${expression(rng, depth + 1)})`;
    default:
      return `(${expression(rng, depth + 1)})`;
  }
}

function leafExpression(rng) {
  switch (rng.int(6)) {
    case 0: return rng.pick(numericLiterals);
    case 1: return rng.pick(stringLiterals);
    case 2: return rng.pick(["はい", "いいえ", "NULL", "undefined"]);
    case 3:
    case 4: return rng.pick(identifiers);
    default: return `(${rng.pick(numericLiterals)})`;
  }
}

function statement(rng, depth = 0) {
  if (depth >= 2) return simpleStatement(rng);
  switch (rng.int(9)) {
    case 0:
    case 1:
      return simpleStatement(rng);
    case 2:
      return `もし${expression(rng)}ならば\n${statement(rng, depth + 1)}\n違えば\n${statement(rng, depth + 1)}\nここまで`;
    case 3:
      return `${1 + rng.int(3)}回\n${statement(rng, depth + 1)}\nここまで`;
    case 4:
      return `${rng.pick(identifiers)}<3の間\n${statement(rng, depth + 1)}\nここまで`;
    case 5:
      return `${expression(rng)}を反復\n対象を表示\nここまで`;
    case 6:
      return `エラー監視\n${statement(rng, depth + 1)}\nエラーならば\n${statement(rng, depth + 1)}\nここまで`;
    case 7:
      return "●(AとBを)足すとは\nA+Bで戻る\nここまで";
    default:
      return `変数 ${rng.pick(identifiers)}=${expression(rng)}`;
  }
}

function simpleStatement(rng) {
  switch (rng.int(4)) {
    case 0: return `${rng.pick(identifiers)}=${expression(rng)}`;
    case 1: return `${expression(rng)}を表示`;
    case 2: return `${rng.pick(identifiers)}[${rng.int(3)}]=${expression(rng)}`;
    default: return `JSON変換(${expression(rng)})を表示`;
  }
}

function generatedSource(rng) {
  const count = 1 + rng.int(4);
  const lines = [];
  for (let index = 0; index < count; index += 1) lines.push(statement(rng));
  let source = `${lines.join("\n")}\n`;
  if (rng.int(7) === 0) source += rng.pick(["(", "[", "もし", "A="]);
  if (source.length > 4096) return `${rng.pick(identifiers)}=${leafExpression(rng)}\n${leafExpression(rng)}を表示\n`;
  return source;
}

function shrinkMismatch(source, mismatchKind) {
  let current = source;
  let attempts = 0;
  const maxAttempts = 256;
  const remainsMismatch = (candidate) => {
    if (attempts >= maxAttempts) return false;
    attempts += 1;
    return compareSource(candidate, runProbe([candidate])[0])?.kind === mismatchKind;
  };
  let changed = true;
  while (changed && attempts < maxAttempts) {
    changed = false;
    const lines = current.split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const candidate = lines.slice(0, index).concat(lines.slice(index + 1)).join("\n");
      if (candidate.length === 0) continue;
      if (remainsMismatch(candidate)) {
        current = candidate;
        changed = true;
        break;
      }
    }
    if (changed) continue;
    const codePoints = Array.from(current);
    for (let index = 0; index < codePoints.length; index += 1) {
      const candidate = codePoints.slice(0, index).concat(codePoints.slice(index + 1)).join("");
      if (candidate.length === 0) continue;
      if (remainsMismatch(candidate)) {
        current = candidate;
        changed = true;
        break;
      }
    }
  }
  return current;
}

async function recordRegression(source) {
  if (recordPath === null) return;
  let existing = [];
  try {
    existing = JSON.parse(await readFile(recordPath, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (!Array.isArray(existing)) throw new Error("--recordの既存ファイルは文字列配列で指定してください");
  if (!existing.includes(source)) existing.push(source);
  await writeFile(recordPath, `${JSON.stringify(existing, null, 2)}\n`, { encoding: "utf8", flag: "w" });
}

const rng = new Rng(seed);
const sources = [...regressions];
const seen = new Set(sources);
while (sources.length < regressions.length + iterations) {
  const source = generatedSource(rng);
  if (seen.has(source)) continue;
  seen.add(source);
  sources.push(source);
}
const actualCases = runProbe(sources);
for (const [index, source] of sources.entries()) {
  const mismatch = compareSource(source, actualCases[index]);
  if (!mismatch) continue;
  const shrunk = shrinkMismatch(source, mismatch.kind);
  const finalMismatch = compareSource(shrunk, runProbe([shrunk])[0]);
  await recordRegression(shrunk);
  console.error(`文法fuzz差分: index=${index} seed=${seed}`);
  console.error(JSON.stringify({ source, shrunk, mismatch: finalMismatch }, null, 2));
  process.exitCode = 1;
  break;
}

if (process.exitCode !== 1) {
  console.log(`公式v3.7.24との文法生成fuzz差分テスト: ${sources.length}件成功 (seed=${seed}, generated=${iterations})`);
}
