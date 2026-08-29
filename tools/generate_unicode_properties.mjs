import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const outputPath = resolve(root, "src/generated/unicode_properties.zig");
const check = process.argv.includes("--check");

// Keep the property inventory deliberately explicit.  Each expression is evaluated
// by Node 24 only while generating the static table; the product runtime never
// embeds or invokes JavaScript for Unicode property matching.
const definitions = [
  { id: "ascii", expression: null, fixed: [0x0000, 0x007f] },
  { id: "any", expression: null, fixed: [0x0000, 0x10ffff] },
  { id: "ascii_hex_digit", expression: "ASCII_Hex_Digit" },
  { id: "assigned", expression: "Assigned" },
  { id: "alphabetic", expression: "Alphabetic" },
  { id: "bidi_control", expression: "Bidi_Control" },
  { id: "bidi_mirrored", expression: "Bidi_Mirrored" },
  { id: "case_ignorable", expression: "Case_Ignorable" },
  { id: "cased", expression: "Cased" },
  { id: "changes_when_casefolded", expression: "Changes_When_Casefolded" },
  { id: "changes_when_casemapped", expression: "Changes_When_Casemapped" },
  { id: "changes_when_lowercased", expression: "Changes_When_Lowercased" },
  { id: "changes_when_nfkc_casefolded", expression: "Changes_When_NFKC_Casefolded" },
  { id: "changes_when_titlecased", expression: "Changes_When_Titlecased" },
  { id: "changes_when_uppercased", expression: "Changes_When_Uppercased" },
  { id: "dash", expression: "Dash" },
  { id: "default_ignorable_code_point", expression: "Default_Ignorable_Code_Point" },
  { id: "deprecated", expression: "Deprecated" },
  { id: "diacritic", expression: "Diacritic" },
  { id: "emoji_component", expression: "Emoji_Component" },
  { id: "emoji_modifier", expression: "Emoji_Modifier" },
  { id: "emoji_modifier_base", expression: "Emoji_Modifier_Base" },
  { id: "extender", expression: "Extender" },
  { id: "grapheme_base", expression: "Grapheme_Base" },
  { id: "grapheme_extend", expression: "Grapheme_Extend" },
  { id: "hex_digit", expression: "Hex_Digit" },
  { id: "ideographic", expression: "Ideographic" },
  { id: "ids_binary_operator", expression: "IDS_Binary_Operator" },
  { id: "ids_trinary_operator", expression: "IDS_Trinary_Operator" },
  { id: "join_control", expression: "Join_Control" },
  { id: "logical_order_exception", expression: "Logical_Order_Exception" },
  { id: "lowercase", expression: "Lowercase" },
  { id: "math", expression: "Math" },
  { id: "noncharacter_code_point", expression: "Noncharacter_Code_Point" },
  { id: "pattern_syntax", expression: "Pattern_Syntax" },
  { id: "pattern_white_space", expression: "Pattern_White_Space" },
  { id: "quotation_mark", expression: "Quotation_Mark" },
  { id: "radical", expression: "Radical" },
  { id: "regional_indicator", expression: "Regional_Indicator" },
  { id: "sentence_terminal", expression: "Sentence_Terminal" },
  { id: "soft_dotted", expression: "Soft_Dotted" },
  { id: "terminal_punctuation", expression: "Terminal_Punctuation" },
  { id: "unified_ideograph", expression: "Unified_Ideograph" },
  { id: "uppercase", expression: "Uppercase" },
  { id: "variation_selector", expression: "Variation_Selector" },
  { id: "xid_continue", expression: "XID_Continue" },
  { id: "xid_start", expression: "XID_Start" },
  { id: "cased_letter", expression: "Cased_Letter" },
  { id: "close_punctuation", expression: "Close_Punctuation" },
  { id: "connector_punctuation", expression: "Connector_Punctuation" },
  { id: "control", expression: "Control" },
  { id: "currency_symbol", expression: "Currency_Symbol" },
  { id: "dash_punctuation", expression: "Dash_Punctuation" },
  { id: "enclosing_mark", expression: "Enclosing_Mark" },
  { id: "final_punctuation", expression: "Final_Punctuation" },
  { id: "format", expression: "Format" },
  { id: "initial_punctuation", expression: "Initial_Punctuation" },
  { id: "letter_number", expression: "Letter_Number" },
  { id: "line_separator", expression: "Line_Separator" },
  { id: "math_symbol", expression: "Math_Symbol" },
  { id: "modifier_letter", expression: "Modifier_Letter" },
  { id: "modifier_symbol", expression: "Modifier_Symbol" },
  { id: "nonspacing_mark", expression: "Nonspacing_Mark" },
  { id: "open_punctuation", expression: "Open_Punctuation" },
  { id: "other", expression: "Other" },
  { id: "other_letter", expression: "Other_Letter" },
  { id: "other_number", expression: "Other_Number" },
  { id: "other_punctuation", expression: "Other_Punctuation" },
  { id: "other_symbol", expression: "Other_Symbol" },
  { id: "paragraph_separator", expression: "Paragraph_Separator" },
  { id: "private_use", expression: "Private_Use" },
  { id: "space_separator", expression: "Space_Separator" },
  { id: "spacing_mark", expression: "Spacing_Mark" },
  { id: "surrogate", expression: "Surrogate" },
  { id: "titlecase_letter", expression: "Titlecase_Letter" },
  { id: "unassigned", expression: "Unassigned" },
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
  { id: "script_extensions_latin", expression: "Script_Extensions=Latin" },
  { id: "script_extensions_greek", expression: "Script_Extensions=Greek" },
  { id: "script_extensions_cyrillic", expression: "Script_Extensions=Cyrillic" },
  { id: "script_extensions_hiragana", expression: "Script_Extensions=Hiragana" },
  { id: "script_extensions_katakana", expression: "Script_Extensions=Katakana" },
  { id: "script_extensions_han", expression: "Script_Extensions=Han" },
  { id: "script_extensions_arabic", expression: "Script_Extensions=Arabic" },
  { id: "script_extensions_hebrew", expression: "Script_Extensions=Hebrew" },
  { id: "script_extensions_devanagari", expression: "Script_Extensions=Devanagari" },
  { id: "script_extensions_thai", expression: "Script_Extensions=Thai" },
  { id: "script_extensions_hangul", expression: "Script_Extensions=Hangul" },
  { id: "script_extensions_common", expression: "Script_Extensions=Common" },
  { id: "script_extensions_inherited", expression: "Script_Extensions=Inherited" },
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
