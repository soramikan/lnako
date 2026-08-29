import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const outputPath = resolve(root, "src/generated/unicode_properties.zig");
const check = process.argv.includes("--check");

// Keep the initial table deliberately explicit.  Each expression is evaluated
// by Node 24 only while generating the static table; the product runtime never
// embeds or invokes JavaScript for Unicode property matching.
const definitions = [
  { id: "ascii", expression: null, fixed: [0x0000, 0x007f] },
  { id: "any", expression: null, fixed: [0x0000, 0x10ffff] },
  { id: "ascii_hex_digit", expression: "ASCII_Hex_Digit" },
  { id: "assigned", expression: "Assigned" },
  { id: "alphabetic", expression: "Alphabetic" },
  { id: "letter", expression: "Letter" },
  { id: "lowercase_letter", expression: "Lowercase_Letter" },
  { id: "uppercase_letter", expression: "Uppercase_Letter" },
  { id: "mark", expression: "Mark" },
  { id: "number", expression: "Number" },
  { id: "decimal_number", expression: "Decimal_Number" },
  { id: "punctuation", expression: "Punctuation" },
  { id: "symbol", expression: "Symbol" },
  { id: "separator", expression: "Separator" },
  { id: "white_space", expression: "White_Space" },
  { id: "emoji", expression: "Emoji" },
  { id: "emoji_presentation", expression: "Emoji_Presentation" },
  { id: "extended_pictographic", expression: "Extended_Pictographic" },
  { id: "id_start", expression: "ID_Start" },
  { id: "id_continue", expression: "ID_Continue" },
  { id: "script_latin", expression: "Script=Latin" },
  { id: "script_greek", expression: "Script=Greek" },
  { id: "script_cyrillic", expression: "Script=Cyrillic" },
  { id: "script_hiragana", expression: "Script=Hiragana" },
  { id: "script_katakana", expression: "Script=Katakana" },
  { id: "script_han", expression: "Script=Han" },
  { id: "script_arabic", expression: "Script=Arabic" },
  { id: "script_hebrew", expression: "Script=Hebrew" },
  { id: "script_devanagari", expression: "Script=Devanagari" },
  { id: "script_thai", expression: "Script=Thai" },
  { id: "script_hangul", expression: "Script=Hangul" },
  { id: "script_common", expression: "Script=Common" },
  { id: "script_inherited", expression: "Script=Inherited" },
];

const ranges = definitions.map((definition) => ({
  ...definition,
  ranges: definition.fixed === undefined ? collectRanges(definition.expression) : [definition.fixed],
}));
const rendered = render(ranges);
const formatted = spawnSync("zig", ["fmt", "--stdin"], { input: rendered, encoding: "utf8" });
if (formatted.status !== 0) throw new Error(`Unicode property tableの整形に失敗しました:\n${formatted.stderr}`);
const output = formatted.stdout;

if (check) {
  const actual = await readFile(outputPath, "utf8");
  if (actual !== output) throw new Error("Unicode property tableがNode 24の生成結果と一致しません");
  console.log(`Unicode property tableを検証しました: ${ranges.length} properties`);
} else {
  await writeFile(outputPath, output);
  console.log(`Unicode property tableを生成しました: ${ranges.length} properties`);
}

function collectRanges(expression) {
  const pattern = new RegExp(`\\p{${expression}}`, "u");
  const result = [];
  let start = null;
  let previous = null;
  for (let codepoint = 0; codepoint <= 0x10ffff; codepoint += 1) {
    if (pattern.test(String.fromCodePoint(codepoint))) {
      if (start === null) start = codepoint;
      previous = codepoint;
    } else if (start !== null) {
      result.push([start, previous]);
      start = null;
    }
  }
  if (start !== null) result.push([start, previous]);
  return result;
}

function render(properties) {
  const header = "// Node.js 24.15.0のECMAScript Unicode property escapeから生成。tools/generate_unicode_properties.mjsで更新する。\n";
  const rangeType = "const Range = struct { first: u21, last: u21 };\n\n";
  const property = `pub const Property = enum {\n${properties.map(({ id }) => `    ${id},`).join("\n")}\n};\n\n`;
  const tables = properties.map(({ id, ranges }) => {
    const values = ranges.map(([first, last]) => `    .{ .first = 0x${first.toString(16)}, .last = 0x${last.toString(16)} },`).join("\n");
    return `const ranges_${id} = [_]Range{\n${values}\n};\n`;
  }).join("\n");
  const switchBody = properties.map(({ id }) => `        .${id} => inRanges(&ranges_${id}, codepoint),`).join("\n");
  return `${header}\n${rangeType}${property}${tables}\npub fn contains(property: Property, codepoint: u21) bool {\n    return switch (property) {\n${switchBody}\n    };\n}\n\nfn inRanges(ranges: []const Range, codepoint: u21) bool {\n    var first: usize = 0;\n    var last = ranges.len;\n    while (first < last) {\n        const middle = first + (last - first) / 2;\n        if (ranges[middle].last < codepoint) first = middle + 1 else last = middle;\n    }\n    return first < ranges.len and ranges[first].first <= codepoint;\n}\n`;
}
