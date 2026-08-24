import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const fixtureCases = JSON.parse(await readFile(resolve(root, "tests/oracle/value-cases.json"), "utf8"));
const operatorCases = JSON.parse(await readFile(resolve(root, "tests/oracle/operator-cases.json"), "utf8"));
const cases = [...fixtureCases, ...generatedNumberCases(256), ...operatorCases.map((value) => ({ kind: "operator", ...value }))];
const encoded = cases.map((testCase) => testCase.kind === "operator"
  ? `operator:${testCase.op}|${testCase.left}|${testCase.right}`
  : `${testCase.kind}:${testCase.input}`);
const probe = spawnSync("zig", ["build", "value-probe", "--", ...encoded], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 16 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`value-probe失敗:\n${probe.stderr}`);
const actual = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

function numberDescription(value) {
  return Object.is(value, -0) ? "-0" : String(value);
}

function generatedNumberCases(count) {
  let state = 0x6c6e616b;
  const next = () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state;
  };
  const buffer = new ArrayBuffer(8);
  const view = new DataView(buffer);
  const result = [];
  for (let index = 0; index < count; index += 1) {
    view.setUint32(0, next(), false);
    view.setUint32(4, next(), false);
    const number = view.getFloat64(0, false);
    const input = Number.isNaN(number)
      ? "NaN"
      : number === Infinity
        ? "Infinity"
        : number === -Infinity
          ? "-Infinity"
          : Object.is(number, -0)
            ? "-0"
            : number.toPrecision(17);
    result.push({ kind: "number-to-string", input });
  }
  return result;
}

function expectedValue({ kind, input }) {
  switch (kind) {
    case "number-to-string":
      return String(Number(input));
    case "string-to-number":
      return numberDescription(Number(input));
    case "string-units":
      return Array.from({ length: input.length }, (_, index) => input.charCodeAt(index)).join(",");
    case "bigint-normalize":
      try {
        return BigInt(input).toString();
      } catch {
        return "error";
      }
    case "operator":
      throw new Error("operatorはexpectedOperatorで処理します");
    default:
      throw new Error(`未知のケース: ${kind}`);
  }
}

function parseValue(encoded) {
  const separator = encoded.indexOf("=");
  const kind = separator >= 0 ? encoded.slice(0, separator) : encoded;
  const payload = separator >= 0 ? encoded.slice(separator + 1) : "";
  switch (kind) {
    case "number": return Number(payload);
    case "string": return payload;
    case "bigint": return BigInt(payload.slice(0, -1));
    case "boolean": return payload === "true";
    case "array": return payload === "" ? [] : payload.split(",").map(Number);
    case "dictionary": return {};
    case "null": return null;
    case "undefined": return undefined;
    default: throw new Error(`未知の値: ${encoded}`);
  }
}

function describeValue(value) {
  switch (typeof value) {
    case "number": return `number:${numberDescription(value)}`;
    case "bigint": return `bigint:${value}`;
    case "string": return `string:${value}`;
    case "boolean": return `boolean:${value}`;
    case "undefined": return "undefined";
    default: return value === null ? "null" : `unknown:${value}`;
  }
}

function expectedOperator({ op, left: leftEncoded, right: rightEncoded }) {
  const left = parseValue(leftEncoded);
  const right = parseValue(rightEncoded);
  try {
    const value = (() => {
      switch (op) {
        case "add": return left + right;
        case "subtract": return left - right;
        case "multiply": return left * right;
        case "divide": return left / right;
        case "remainder": return left % right;
        case "power": return left ** right;
        case "bit_and": return left & right;
        case "bit_or": return left | right;
        case "bit_xor": return left ^ right;
        case "shift_left": return left << right;
        case "shift_right": return left >> right;
        case "shift_right_unsigned": return left >>> right;
        default: throw new Error(`未知の演算子: ${op}`);
      }
    })();
    return describeValue(value);
  } catch {
    return "error";
  }
}

let failures = 0;
for (const [index, testCase] of cases.entries()) {
  const expected = testCase.kind === "operator" ? expectedOperator(testCase) : expectedValue(testCase);
  if (actual[index] !== expected) {
    failures += 1;
    console.error(`値差分 ${JSON.stringify(testCase)}: expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual[index])}`);
  }
}
if (failures > 0) throw new Error(`動的値の差分が${failures}件あります`);
console.log(`Node 24との動的値差分テスト: ${cases.length}件成功`);
