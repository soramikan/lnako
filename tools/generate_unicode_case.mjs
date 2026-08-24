import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const outputPath = resolve(root, "src/generated/unicode_case.zig");
const check = process.argv.includes("--check");
const upper = collect((value) => value.toUpperCase());
const lower = collect((value) => value.toLowerCase());
const cased = collectRanges(/\p{Cased}/u);
const caseIgnorable = collectRanges(/\p{Case_Ignorable}/u);
const rendered = render(upper, lower, cased, caseIgnorable);
const formatted = spawnSync("zig", ["fmt", "--stdin"], { input: rendered, encoding: "utf8" });
if (formatted.status !== 0) throw new Error(`Unicode大小文字テーブルの整形に失敗しました:\n${formatted.stderr}`);
const output = formatted.stdout;

if (check) {
  const actual = await readFile(outputPath, "utf8");
  if (actual !== output) throw new Error("Unicode大小文字テーブルがNode 24の生成結果と一致しません");
  console.log(`Unicode大小文字テーブルを検証しました: upper=${upper.entries.length} lower=${lower.entries.length}`);
} else {
  await writeFile(outputPath, output);
  console.log(`Unicode大小文字テーブルを生成しました: upper=${upper.entries.length} lower=${lower.entries.length}`);
}

function collect(convert) {
  const entries = [];
  const values = [];
  for (let source = 0; source <= 0x10ffff; source += 1) {
    if (source >= 0xd800 && source <= 0xdfff) continue;
    const original = String.fromCodePoint(source);
    const converted = convert(original);
    if (converted === original) continue;
    const mapped = [...converted].map((character) => character.codePointAt(0));
    entries.push({ source, start: values.length, length: mapped.length });
    values.push(...mapped);
  }
  return { entries, values };
}

function collectRanges(pattern) {
  const ranges = [];
  let start = null;
  let previous = null;
  for (let codepoint = 0; codepoint <= 0x10ffff; codepoint += 1) {
    if (codepoint >= 0xd800 && codepoint <= 0xdfff) continue;
    if (pattern.test(String.fromCodePoint(codepoint))) {
      if (start === null) start = codepoint;
      previous = codepoint;
    } else if (start !== null) {
      ranges.push([start, previous]);
      start = null;
    }
  }
  if (start !== null) ranges.push([start, previous]);
  return ranges;
}

function render(upperData, lowerData, casedRanges, ignorableRanges) {
  return `// Node.js 24.15.0のECMAScript大小文字変換から生成。tools/generate_unicode_case.mjsで更新する。\n` +
    `const Mapping = struct { source: u21, start: u32, length: u8 };\n\n` +
    renderMappings("upper_mappings", upperData.entries) + "\n" +
    renderValues("upper_values", upperData.values) + "\n" +
    renderMappings("lower_mappings", lowerData.entries) + "\n" +
    renderValues("lower_values", lowerData.values) + "\n" +
    renderRanges("cased_ranges", casedRanges) + "\n" +
    renderRanges("case_ignorable_ranges", ignorableRanges) + "\n" +
    `pub fn upper(codepoint: u21) ?[]const u21 {\n    return find(&upper_mappings, &upper_values, codepoint);\n}\n\n` +
    `pub fn lower(codepoint: u21) ?[]const u21 {\n    return find(&lower_mappings, &lower_values, codepoint);\n}\n\n` +
    `pub fn isCased(codepoint: u21) bool {\n    return inRanges(&cased_ranges, codepoint);\n}\n\n` +
    `pub fn isCaseIgnorable(codepoint: u21) bool {\n    return inRanges(&case_ignorable_ranges, codepoint);\n}\n\n` +
    `fn find(mappings: []const Mapping, values: []const u21, codepoint: u21) ?[]const u21 {\n` +
    `    var first: usize = 0;\n    var last = mappings.len;\n    while (first < last) {\n` +
    `        const middle = first + (last - first) / 2;\n        const mapping = mappings[middle];\n` +
    `        if (mapping.source < codepoint) first = middle + 1 else last = middle;\n    }\n` +
    `    if (first >= mappings.len or mappings[first].source != codepoint) return null;\n` +
    `    const mapping = mappings[first];\n    return values[mapping.start .. mapping.start + mapping.length];\n}\n\n` +
    `fn inRanges(ranges: []const [2]u21, codepoint: u21) bool {\n` +
    `    var first: usize = 0;\n    var last = ranges.len;\n    while (first < last) {\n` +
    `        const middle = first + (last - first) / 2;\n        if (ranges[middle][1] < codepoint) first = middle + 1 else last = middle;\n` +
    `    }\n    return first < ranges.len and ranges[first][0] <= codepoint;\n}\n`;
}

function renderMappings(name, entries) {
  const lines = entries.map(({ source, start, length }) =>
    `    .{ .source = 0x${source.toString(16)}, .start = ${start}, .length = ${length} },`);
  return `const ${name} = [_]Mapping{\n${lines.join("\n")}\n};\n`;
}

function renderValues(name, values) {
  const lines = [];
  for (let index = 0; index < values.length; index += 12) {
    lines.push(`    ${values.slice(index, index + 12).map((value) => `0x${value.toString(16)}`).join(", ")},`);
  }
  return `const ${name} = [_]u21{\n${lines.join("\n")}\n};\n`;
}

function renderRanges(name, ranges) {
  const lines = ranges.map(([first, last]) => `    .{ 0x${first.toString(16)}, 0x${last.toString(16)} },`);
  return `const ${name} = [_][2]u21{\n${lines.join("\n")}\n};\n`;
}
