import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/lexer-cases.json"), "utf8"));

const [{ NakoPrepare }, { NakoLexer }, { NakoLogger }] = await Promise.all([
  import(pathToFileURL(resolve(oracleRoot, "core/src/nako_prepare.mjs"))),
  import(pathToFileURL(resolve(oracleRoot, "core/src/nako_lexer.mjs"))),
  import(pathToFileURL(resolve(oracleRoot, "core/src/nako_logger.mjs"))),
]);

const probe = spawnSync("zig", ["build", "lexer-probe", "--", ...cases], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 16 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`lexer-probe失敗:\n${probe.stderr}`);
const actualCases = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

const kindMap = new Map([
  ["word", "identifier"], ["string", "string"], ["number", "number"], ["bigint", "bigint"],
  ["eol", "eol"], ["comma", "comma"], ["もし", "keyword_if"], ["ここから", "keyword_here_from"],
  ["ここまで", "keyword_here_end"], ["違えば", "keyword_else"], ["def_func", "def_func"], ["def_test", "def_test"],
  ["func", "function_ref"],
  ["eq", "equal"], ["===", "strict_equal"], ["noteq", "not_equal"], ["!==", "strict_not_equal"],
  ["gt", "greater"], ["gteq", "greater_equal"], ["lt", "less"], ["lteq", "less_equal"],
  ["and", "logical_and"], ["or", "logical_or"], ["not", "not"], ["+", "plus"], ["-", "minus"],
  ["*", "multiply"], ["**", "power"], ["÷", "divide"], ["÷÷", "integer_divide"], ["%", "modulo"],
  ["^", "bit_xor"], ["&", "bit_and"], ["@", "at"], ["$", "property"], ["??", "question_display"],
  ["…", "range"], ["(", "left_paren"], [")", "right_paren"], ["[", "left_bracket"], ["]", "right_bracket"],
  ["{", "left_brace"], ["}", "right_brace"], ["|", "pipe"], [":", "colon"], ["shift_r0", "shift_right_unsigned"],
  ["shift_r", "shift_right"], ["shift_l", "shift_left"], ["←", "assign_arrow"],
]);
const reservedMap = new Map([
  ["回", "keyword_repeat_count"], ["回繰返", "keyword_repeat_count"], ["間", "keyword_repeat_while"],
  ["間繰返", "keyword_repeat_while"], ["繰返", "keyword_repeat"], ["増繰返", "keyword_repeat"],
  ["減繰返", "keyword_repeat"], ["反復", "keyword_foreach"], ["抜", "keyword_break"],
  ["続", "keyword_continue"], ["戻", "keyword_return"], ["変数", "keyword_let"], ["定数", "keyword_const"],
  ["取込", "keyword_import"], ["エラー監視", "keyword_error_guard"], ["エラー", "keyword_error"],
  ["非同期モード", "keyword_async"], ["モード設定", "keyword_mode"], ["関数", "def_func"],
]);

function expectedToken(token) {
  const kind = token.type === "word" && reservedMap.has(String(token.value))
    ? reservedMap.get(String(token.value))
    : kindMap.get(token.type);
  if (!kind) throw new Error(`未対応の公式トークン種別: ${token.type}`);
  return {
    kind,
    value: token.type === "eol" ? "" : String(token.value),
    josi: token.josi ?? "",
  };
}

function expectedTokens(token) {
  if (token.type === "word" && token.josi === "" && String(token.value).endsWith("回") && String(token.value).length > 1) {
    return [
      { kind: "identifier", value: String(token.value).slice(0, -1), josi: "" },
      { kind: "keyword_repeat_count", value: "回", josi: "" },
    ];
  }
  return [expectedToken(token)];
}

function actualToken(token) {
  return {
    kind: token.kind,
    value: token.kind === "number" ? String(token.number_value) : token.value,
    josi: token.josi,
  };
}

let failures = 0;
for (const [index, source] of cases.entries()) {
  const prepared = NakoPrepare.getInstance().convert(source).map((part) => part.text).join("");
  const official = new NakoLexer(new NakoLogger()).tokenize(prepared, 0, "oracle.nako3")
    .filter((token) => token.type !== "line_comment" && token.type !== "range_comment" && token.type !== "_eol")
    .flatMap(expectedTokens);
  const actual = actualCases[index].filter((token) => token.kind !== "eof").map(actualToken);
  if (JSON.stringify(actual) !== JSON.stringify(official)) {
    failures += 1;
    console.error(`差分: ${JSON.stringify(source)}\nofficial=${JSON.stringify(official)}\nlnako  =${JSON.stringify(actual)}`);
  }
}
if (failures > 0) throw new Error(`字句解析の差分が${failures}件あります`);
console.log(`公式v3.7.24との字句解析差分テスト: ${cases.length}件成功`);
