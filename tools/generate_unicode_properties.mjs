import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const outputPath = resolve(root, "src/generated/unicode_properties.zig");
const check = process.argv.includes("--check");

const scriptDefinitions = [
  { name: "Unknown", aliases: ["Zzzz"] },
  { name: "Adlam", aliases: ["Adlm"] },
  { name: "Ahom", aliases: ["Ahom"] },
  { name: "Anatolian_Hieroglyphs", aliases: ["Hluw"] },
  { name: "Arabic", aliases: ["Arab"] },
  { name: "Armenian", aliases: ["Armn"] },
  { name: "Avestan", aliases: ["Avst"] },
  { name: "Balinese", aliases: ["Bali"] },
  { name: "Bamum", aliases: ["Bamu"] },
  { name: "Bassa_Vah", aliases: ["Bass"] },
  { name: "Batak", aliases: ["Batk"] },
  { name: "Beria_Erfe", aliases: ["Berf"] },
  { name: "Bengali", aliases: ["Beng"] },
  { name: "Bhaiksuki", aliases: ["Bhks"] },
  { name: "Bopomofo", aliases: ["Bopo"] },
  { name: "Brahmi", aliases: ["Brah"] },
  { name: "Braille", aliases: ["Brai"] },
  { name: "Buginese", aliases: ["Bugi"] },
  { name: "Buhid", aliases: ["Buhd"] },
  { name: "Canadian_Aboriginal", aliases: ["Cans"] },
  { name: "Carian", aliases: ["Cari"] },
  { name: "Caucasian_Albanian", aliases: ["Aghb"] },
  { name: "Chakma", aliases: ["Cakm"] },
  { name: "Cham", aliases: ["Cham"] },
  { name: "Cherokee", aliases: ["Cher"] },
  { name: "Chorasmian", aliases: ["Chrs"] },
  { name: "Common", aliases: ["Zyyy"] },
  { name: "Coptic", aliases: ["Copt", "Qaac"] },
  { name: "Cuneiform", aliases: ["Xsux"] },
  { name: "Cypriot", aliases: ["Cprt"] },
  { name: "Cyrillic", aliases: ["Cyrl"] },
  { name: "Cypro_Minoan", aliases: ["Cpmn"] },
  { name: "Deseret", aliases: ["Dsrt"] },
  { name: "Devanagari", aliases: ["Deva"] },
  { name: "Dives_Akuru", aliases: ["Diak"] },
  { name: "Dogra", aliases: ["Dogr"] },
  { name: "Duployan", aliases: ["Dupl"] },
  { name: "Egyptian_Hieroglyphs", aliases: ["Egyp"] },
  { name: "Elbasan", aliases: ["Elba"] },
  { name: "Elymaic", aliases: ["Elym"] },
  { name: "Ethiopic", aliases: ["Ethi"] },
  { name: "Garay", aliases: ["Gara"] },
  { name: "Georgian", aliases: ["Geor"] },
  { name: "Glagolitic", aliases: ["Glag"] },
  { name: "Gothic", aliases: ["Goth"] },
  { name: "Grantha", aliases: ["Gran"] },
  { name: "Greek", aliases: ["Grek"] },
  { name: "Gujarati", aliases: ["Gujr"] },
  { name: "Gunjala_Gondi", aliases: ["Gong"] },
  { name: "Gurmukhi", aliases: ["Guru"] },
  { name: "Gurung_Khema", aliases: ["Gukh"] },
  { name: "Han", aliases: ["Hani"] },
  { name: "Hangul", aliases: ["Hang"] },
  { name: "Hanifi_Rohingya", aliases: ["Rohg"] },
  { name: "Hanunoo", aliases: ["Hano"] },
  { name: "Hatran", aliases: ["Hatr"] },
  { name: "Hebrew", aliases: ["Hebr"] },
  { name: "Hiragana", aliases: ["Hira"] },
  { name: "Imperial_Aramaic", aliases: ["Armi"] },
  { name: "Inherited", aliases: ["Zinh", "Qaai"] },
  { name: "Inscriptional_Pahlavi", aliases: ["Phli"] },
  { name: "Inscriptional_Parthian", aliases: ["Prti"] },
  { name: "Javanese", aliases: ["Java"] },
  { name: "Kaithi", aliases: ["Kthi"] },
  { name: "Kannada", aliases: ["Knda"] },
  { name: "Katakana", aliases: ["Kana"] },
  { name: "Kawi", aliases: ["Kawi"] },
  { name: "Kayah_Li", aliases: ["Kali"] },
  { name: "Kharoshthi", aliases: ["Khar"] },
  { name: "Khmer", aliases: ["Khmr"] },
  { name: "Khojki", aliases: ["Khoj"] },
  { name: "Khitan_Small_Script", aliases: ["Kits"] },
  { name: "Khudawadi", aliases: ["Sind"] },
  { name: "Kirat_Rai", aliases: ["Krai"] },
  { name: "Lao", aliases: ["Laoo"] },
  { name: "Latin", aliases: ["Latn"] },
  { name: "Lepcha", aliases: ["Lepc"] },
  { name: "Limbu", aliases: ["Limb"] },
  { name: "Linear_A", aliases: ["Lina"] },
  { name: "Linear_B", aliases: ["Linb"] },
  { name: "Lisu", aliases: ["Lisu"] },
  { name: "Lycian", aliases: ["Lyci"] },
  { name: "Lydian", aliases: ["Lydi"] },
  { name: "Makasar", aliases: ["Maka"] },
  { name: "Mahajani", aliases: ["Mahj"] },
  { name: "Malayalam", aliases: ["Mlym"] },
  { name: "Mandaic", aliases: ["Mand"] },
  { name: "Manichaean", aliases: ["Mani"] },
  { name: "Marchen", aliases: ["Marc"] },
  { name: "Masaram_Gondi", aliases: ["Gonm"] },
  { name: "Medefaidrin", aliases: ["Medf"] },
  { name: "Meetei_Mayek", aliases: ["Mtei"] },
  { name: "Mende_Kikakui", aliases: ["Mend"] },
  { name: "Meroitic_Cursive", aliases: ["Merc"] },
  { name: "Meroitic_Hieroglyphs", aliases: ["Mero"] },
  { name: "Miao", aliases: ["Plrd"] },
  { name: "Modi", aliases: ["Modi"] },
  { name: "Mongolian", aliases: ["Mong"] },
  { name: "Mro", aliases: ["Mroo"] },
  { name: "Multani", aliases: ["Mult"] },
  { name: "Myanmar", aliases: ["Mymr"] },
  { name: "Nabataean", aliases: ["Nbat"] },
  { name: "Nag_Mundari", aliases: ["Nagm"] },
  { name: "Nandinagari", aliases: ["Nand"] },
  { name: "New_Tai_Lue", aliases: ["Talu"] },
  { name: "Newa", aliases: ["Newa"] },
  { name: "Nko", aliases: ["Nkoo"] },
  { name: "Nushu", aliases: ["Nshu"] },
  { name: "Nyiakeng_Puachue_Hmong", aliases: ["Hmnp"] },
  { name: "Ogham", aliases: ["Ogam"] },
  { name: "Ol_Chiki", aliases: ["Olck"] },
  { name: "Ol_Onal", aliases: ["Onao"] },
  { name: "Old_Hungarian", aliases: ["Hung"] },
  { name: "Old_Italic", aliases: ["Ital"] },
  { name: "Old_North_Arabian", aliases: ["Narb"] },
  { name: "Old_Permic", aliases: ["Perm"] },
  { name: "Old_Persian", aliases: ["Xpeo"] },
  { name: "Old_Sogdian", aliases: ["Sogo"] },
  { name: "Old_South_Arabian", aliases: ["Sarb"] },
  { name: "Old_Turkic", aliases: ["Orkh"] },
  { name: "Old_Uyghur", aliases: ["Ougr"] },
  { name: "Oriya", aliases: ["Orya"] },
  { name: "Osage", aliases: ["Osge"] },
  { name: "Osmanya", aliases: ["Osma"] },
  { name: "Pahawh_Hmong", aliases: ["Hmng"] },
  { name: "Palmyrene", aliases: ["Palm"] },
  { name: "Pau_Cin_Hau", aliases: ["Pauc"] },
  { name: "Phags_Pa", aliases: ["Phag"] },
  { name: "Phoenician", aliases: ["Phnx"] },
  { name: "Psalter_Pahlavi", aliases: ["Phlp"] },
  { name: "Rejang", aliases: ["Rjng"] },
  { name: "Runic", aliases: ["Runr"] },
  { name: "Samaritan", aliases: ["Samr"] },
  { name: "Saurashtra", aliases: ["Saur"] },
  { name: "Sharada", aliases: ["Shrd"] },
  { name: "Shavian", aliases: ["Shaw"] },
  { name: "Siddham", aliases: ["Sidd"] },
  { name: "Sidetic", aliases: ["Sidt"] },
  { name: "SignWriting", aliases: ["Sgnw"] },
  { name: "Sinhala", aliases: ["Sinh"] },
  { name: "Sogdian", aliases: ["Sogd"] },
  { name: "Sora_Sompeng", aliases: ["Sora"] },
  { name: "Soyombo", aliases: ["Soyo"] },
  { name: "Sundanese", aliases: ["Sund"] },
  { name: "Sunuwar", aliases: ["Sunu"] },
  { name: "Syloti_Nagri", aliases: ["Sylo"] },
  { name: "Syriac", aliases: ["Syrc"] },
  { name: "Tagalog", aliases: ["Tglg"] },
  { name: "Tagbanwa", aliases: ["Tagb"] },
  { name: "Tai_Le", aliases: ["Tale"] },
  { name: "Tai_Tham", aliases: ["Lana"] },
  { name: "Tai_Viet", aliases: ["Tavt"] },
  { name: "Tai_Yo", aliases: ["Tayo"] },
  { name: "Takri", aliases: ["Takr"] },
  { name: "Tamil", aliases: ["Taml"] },
  { name: "Tangut", aliases: ["Tang"] },
  { name: "Telugu", aliases: ["Telu"] },
  { name: "Thaana", aliases: ["Thaa"] },
  { name: "Thai", aliases: ["Thai"] },
  { name: "Tibetan", aliases: ["Tibt"] },
  { name: "Tifinagh", aliases: ["Tfng"] },
  { name: "Tirhuta", aliases: ["Tirh"] },
  { name: "Tangsa", aliases: ["Tnsa"] },
  { name: "Todhri", aliases: ["Todr"] },
  { name: "Tolong_Siki", aliases: ["Tols"] },
  { name: "Toto", aliases: ["Toto"] },
  { name: "Tulu_Tigalari", aliases: ["Tutg"] },
  { name: "Ugaritic", aliases: ["Ugar"] },
  { name: "Vai", aliases: ["Vaii"] },
  { name: "Vithkuqi", aliases: ["Vith"] },
  { name: "Wancho", aliases: ["Wcho"] },
  { name: "Warang_Citi", aliases: ["Wara"] },
  { name: "Yezidi", aliases: ["Yezi"] },
  { name: "Yi", aliases: ["Yiii"] },
  { name: "Zanabazar_Square", aliases: ["Zanb"] },
];

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
  ...scriptDefinitions.flatMap(({ name }) => [
    { id: `script_${toSnake(name)}`, expression: `Script=${name}` },
    { id: `script_extensions_${toSnake(name)}`, expression: `Script_Extensions=${name}` },
  ]),
];

const ranges = definitions.map((definition) => ({
  ...definition,
  ranges: definition.fixed === undefined ? collectRanges(definition.expression) : [definition.fixed],
}));
const rendered = render(ranges, scriptDefinitions);
const formatted = spawnSync("zig", ["fmt", "--stdin"], { input: rendered, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
if (formatted.status !== 0) {
  throw new Error(`Unicode property tableの整形に失敗しました:\n${formatted.stderr}`);
}
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

function render(properties, scripts) {
  const header = "// Node.js 24.15.0のECMAScript Unicode property escapeから生成。tools/generate_unicode_properties.mjsで更新する。\n";
  const rangeType = "const Range = struct { first: u21, last: u21 };\n\n";
  const property = `pub const Property = enum {\n${properties.map(({ id }) => `    ${id},`).join("\n")}\n};\n\n`;
  const tables = properties.map(({ id, ranges }) => {
    const values = ranges.map(([first, last]) => `    .{ .first = 0x${first.toString(16)}, .last = 0x${last.toString(16)} },`).join("\n");
    return `const ranges_${id} = [_]Range{\n${values}\n};\n`;
  }).join("\n");
  const switchBody = properties.map(({ id }) => `        .${id} => inRanges(&ranges_${id}, codepoint),`).join("\n");
  const scriptLookup = renderScriptLookup(scripts);
  return `${header}\n${rangeType}${property}${tables}\npub fn contains(property: Property, codepoint: u21) bool {\n    return switch (property) {\n${switchBody}\n    };\n}\n\n${scriptLookup}fn asciiEquals(units: []const u16, text: []const u8) bool {\n    if (units.len != text.len) return false;\n    for (text, 0..) |unit, index| if (units[index] != unit) return false;\n    return true;\n}\n\nfn inRanges(ranges: []const Range, codepoint: u21) bool {\n    var first: usize = 0;\n    var last = ranges.len;\n    while (first < last) {\n        const middle = first + (last - first) / 2;\n        if (ranges[middle].last < codepoint) first = middle + 1 else last = middle;\n    }\n    return first < ranges.len and ranges[first].first <= codepoint;\n}\n`;
}

function renderScriptLookup(scripts) {
  const lines = [];
  for (const { name, aliases } of scripts) {
    const id = toSnake(name);
    const values = [name, ...aliases];
    const scriptNames = values.flatMap((value) => [`Script=${value}`, `sc=${value}`]);
    const extensionNames = values.flatMap((value) => [`Script_Extensions=${value}`, `scx=${value}`]);
    lines.push(`    if (${scriptNames.map((value) => `asciiEquals(name, ${JSON.stringify(value)})`).join(" or ")}) return .script_${id};`);
    lines.push(`    if (${extensionNames.map((value) => `asciiEquals(name, ${JSON.stringify(value)})`).join(" or ")}) return .script_extensions_${id};`);
  }
  return `pub fn lookupScript(name: []const u16) ?Property {\n${lines.join("\n")}\n    return null;\n}\n\n`;
}

function toSnake(name) {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}
