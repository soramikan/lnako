import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const inputPath = resolve(root, "tools/data/EastAsianWidth-16.0.0.txt");
const outputPath = resolve(root, "src/generated/unicode_width.zig");
const check = process.argv.includes("--check");

// Issue #38: 端末表示セル幅の East_Asian_Width 側テーブル。Emoji幅は
// src/generated/unicode_properties.zig の emoji_presentation /
// extended_pictographic を使うため、ここでは F/W のみを扱う。
// 入力はUnicode Character Databaseの EastAsianWidth.txt で、
// tools/data/EastAsianWidth-16.0.0.txt に固定する（NodeのUnicode版と揃える
// ため16.0.0。JavaScript実行は生成時のみで、製品ランタイムには混入しない）。
const source = await readFile(inputPath, "utf8");

const wideRanges = [];
for (const rawLine of source.split("\n")) {
  const line = rawLine.replace(/#.*$/, "").trim();
  if (line.length === 0) continue;
  const [codesField, propertyField] = line.split(";").map((field) => field.trim());
  if (propertyField !== "W" && propertyField !== "F") continue;
  const [firstText, lastText] = codesField.split("..").map((text) => text.trim());
  const first = parseInt(firstText, 16);
  const last = lastText === undefined ? first : parseInt(lastText, 16);
  wideRanges.push([first, last]);
}
if (wideRanges.length === 0) throw new Error("EastAsianWidth.txtからW/F範囲を抽出できませんでした");
wideRanges.sort((a, b) => a[0] - b[0]);

// 隣接・重複する範囲を畳む（UCD側の更新で分割されても出力を安定させる）。
const merged = [];
for (const [first, last] of wideRanges) {
  const tail = merged[merged.length - 1];
  if (tail !== undefined && first <= tail[1] + 1) {
    tail[1] = Math.max(tail[1], last);
  } else {
    merged.push([first, last]);
  }
}

const rendered = `// Unicode Character Database 16.0.0の EastAsianWidth.txt から生成。
// tools/generate_unicode_width.mjsで更新する。入力: tools/data/EastAsianWidth-16.0.0.txt

const Range = struct { first: u21, last: u21 };

pub const unicode_version = "16.0.0";

/// East_Asian_Width が Fullwidth または Wide のコードポイント範囲（端末2セル）。
const ranges_east_asian_wide = [_]Range{
${merged.map(([first, last]) => `    .{ .first = 0x${first.toString(16)}, .last = 0x${last.toString(16)} },`).join("\n")}
};

pub fn eastAsianWide(codepoint: u21) bool {
    var first: usize = 0;
    var last = ranges_east_asian_wide.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        if (ranges_east_asian_wide[middle].last < codepoint) first = middle + 1 else last = middle;
    }
    return first < ranges_east_asian_wide.len and ranges_east_asian_wide[first].first <= codepoint;
}
`;

const formatted = spawnSync("zig", ["fmt", "--stdin"], { input: rendered, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
if (formatted.status !== 0) {
  throw new Error(`Unicode width tableの整形に失敗しました:\n${formatted.stderr}`);
}
const output = formatted.stdout;

if (check) {
  const actual = await readFile(outputPath, "utf8");
  if (actual !== output) throw new Error("Unicode width tableが生成結果と一致しません");
  console.log(`Unicode width tableを検証しました: ${merged.length} ranges (Unicode 16.0.0)`);
} else {
  await writeFile(outputPath, output);
  console.log(`Unicode width tableを生成しました: ${merged.length} ranges (Unicode 16.0.0)`);
}
