import { readFile, mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import iconv from "../.cache/oracle/nadesiko3-3.7.24/node_modules/iconv-lite/lib/index.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputPath = resolve(root, "src/generated/legacy_encoding.zig");
const check = process.argv.includes("--check");

// 別名を解決させてから、同じcodecインスタンスを共有する名前を一つの表へまとめる。
iconv.encodingExists("utf8");
const dbcsGroups = new Map();
const singleByteGroups = new Map();
for (const name of Object.keys(iconv.encodings).toSorted()) {
  if (name.startsWith("_")) continue;
  let codec;
  try {
    codec = iconv.getCodec(name);
  } catch {
    continue;
  }
  const target = codec.encoder.name === "DBCSEncoder" && codec.decoder.name === "DBCSDecoder"
    ? dbcsGroups
    : codec.encoder.name === "SBCSEncoder" && codec.decoder.name === "SBCSDecoder"
      ? singleByteGroups
      : null;
  if (target === null) continue;
  const group = target.get(codec) ?? { codec, names: [], representative: name };
  group.names.push(name);
  target.set(codec, group);
}

const dbcsBlocks = [];
const dbcsAliases = [];
let dbcsIndex = 0;
for (const group of dbcsGroups.values()) {
  const iconvName = group.representative;
  const entries = [];
  const includeAstral = group.names.includes("big5hkscs");
  const lastCodepoint = includeAstral ? 0x10ffff : 0xffff;
  for (let codepoint = 0; codepoint <= lastCodepoint; codepoint += 1) {
    if (codepoint >= 0xd800 && codepoint <= 0xdfff) continue;
    const bytes = iconv.encode(String.fromCodePoint(codepoint), iconvName);
    // GB18030の4バイト領域は範囲表から算出するため静的表には含めない。
    if (bytes.length === 0 || bytes.length > 3) continue;
    if (bytes.length === 1 && bytes[0] === 0x3f && codepoint !== 0x3f) continue;
    entries.push({ codepoint, key: pack(bytes) });
  }
  const encode = entries.toSorted((left, right) => left.codepoint - right.codepoint);
  const decodeMap = new Map();
  for (const entry of entries) {
    if (!decodeMap.has(entry.key)) decodeMap.set(entry.key, utf16Units(String.fromCodePoint(entry.codepoint)));
  }

  // encode表からは得られない復号専用・重複マッピングも固定する。
  for (let byte = 0; byte <= 0xff; byte += 1) {
    const text = iconv.decode(Buffer.from([byte]), iconvName);
    if (text.length === 0 || text.includes("�")) continue;
    decodeMap.set(pack([byte]), utf16Units(text));
  }
  for (let first = 0; first <= 0xff; first += 1) {
    if (!iconv.decode(Buffer.from([first]), iconvName).includes("�")) continue;
    for (let second = 0; second <= 0xff; second += 1) {
      const bytes = [first, second];
      const text = iconv.decode(Buffer.from(bytes), iconvName);
      if (text.length === 0 || text.includes("�")) continue;
      decodeMap.set(pack(bytes), utf16Units(text));
    }
  }
  const threeByteLeads = new Set(entries.filter((entry) => keyLength(entry.key) === 3).map((entry) => keyFirstByte(entry.key)));
  for (const first of threeByteLeads) {
    for (let second = 0; second <= 0xff; second += 1) {
      for (let third = 0; third <= 0xff; third += 1) {
        const bytes = [first, second, third];
        const text = iconv.decode(Buffer.from(bytes), iconvName);
        if (text.length === 0 || text.includes("�")) continue;
        decodeMap.set(pack(bytes), utf16Units(text));
      }
    }
  }

  const decode = [...decodeMap].map(([key, units]) => ({ key, units })).toSorted((left, right) => left.key - right.key);
  const decodeOffsets = [0];
  const decodeUnits = [];
  for (const entry of decode) {
    decodeUnits.push(...entry.units);
    decodeOffsets.push(decodeUnits.length);
  }

  // Big5-HKSCSの結合文字列など、複数Unicode文字で一つの符号になる表も保持する。
  const sequenceMap = new Map();
  for (const entry of decode) {
    const text = String.fromCharCode(...entry.units);
    if ([...text].length <= 1) continue;
    const encoded = iconv.encode(text, iconvName);
    if (encoded.length === 0 || encoded.length > 3 || (encoded.length === 1 && encoded[0] === 0x3f)) continue;
    sequenceMap.set(entry.units.join(","), { units: entry.units, key: pack(encoded) });
  }
  const sequences = [...sequenceMap.values()].toSorted((left, right) => right.units.length - left.units.length || compareArrays(left.units, right.units));
  const sequenceOffsets = [0];
  const sequenceUnits = [];
  for (const sequence of sequences) {
    sequenceUnits.push(...sequence.units);
    sequenceOffsets.push(sequenceUnits.length);
  }

  dbcsBlocks.push(`    .{\n        .encode_codepoints = &.{${format(encode.map((entry) => entry.codepoint), 6)}\n        },\n        .encode_keys = &.{${format(encode.map((entry) => entry.key), 10)}\n        },\n        .decode_keys = &.{${format(decode.map((entry) => entry.key), 10)}\n        },\n        .decode_offsets = &.{${format(decodeOffsets, 6)}\n        },\n        .decode_units = &.{${format(decodeUnits, 4)}\n        },\n        .encode_sequence_offsets = &.{${format(sequenceOffsets, 6)}\n        },\n        .encode_sequence_units = ${formatFieldArray(sequenceUnits, 4)},\n        .encode_sequence_keys = ${formatFieldArray(sequences.map((entry) => entry.key), 10)},\n        .gb18030 = ${group.codec.gb18030 ? "true" : "false"},\n    },`);
  for (const name of group.names) dbcsAliases.push({ name, encoding: dbcsIndex });
  dbcsIndex += 1;
}
dbcsAliases.sort((left, right) => left.name.localeCompare(right.name));

const singleByteBlocks = [];
const singleByteAliases = [];
let singleByteIndex = 0;
for (const group of singleByteGroups.values()) {
  const allBytes = Buffer.from(Array.from({ length: 256 }, (_, index) => index));
  const decoded = iconv.decode(allBytes, group.representative);
  if (decoded.length !== 256) throw new Error(`${group.representative}の単バイト復号表が256文字ではありません`);
  const decodeUnits = Array.from({ length: 256 }, (_, index) => decoded.charCodeAt(index));
  const encodeEntries = [];
  for (let codepoint = 0; codepoint <= 0xffff; codepoint += 1) {
    if (codepoint >= 0xd800 && codepoint <= 0xdfff) continue;
    const bytes = iconv.encode(String.fromCharCode(codepoint), group.representative);
    if (bytes.length !== 1 || (bytes[0] === 0x3f && codepoint !== 0x3f)) continue;
    encodeEntries.push({ codepoint, byte: bytes[0] });
  }
  singleByteBlocks.push(`    .{\n        .decode_units = &.{${format(decodeUnits, 4)}\n        },\n        .encode_codepoints = &.{${format(encodeEntries.map((entry) => entry.codepoint), 4)}\n        },\n        .encode_bytes = &.{${format(encodeEntries.map((entry) => entry.byte), 2)}\n        },\n    },`);
  for (const name of group.names) singleByteAliases.push({ name, encoding: singleByteIndex });
  singleByteIndex += 1;
}
singleByteAliases.sort((left, right) => left.name.localeCompare(right.name));

const rangePath = resolve(root, ".cache/oracle/nadesiko3-3.7.24/node_modules/iconv-lite/encodings/tables/gb18030-ranges.json");
const gb18030Ranges = JSON.parse(await readFile(rangePath, "utf8"));

const generated = `// tools/generate_legacy_encoding.mjsで固定したiconv-lite互換表。手編集禁止。\n\nconst std = @import("std");\n\npub const Encoding = struct {\n    encode_codepoints: []const u32,\n    encode_keys: []const u64,\n    decode_keys: []const u64,\n    decode_offsets: []const u32,\n    decode_units: []const u16,\n    encode_sequence_offsets: []const u32,\n    encode_sequence_units: []const u16,\n    encode_sequence_keys: []const u64,\n    gb18030: bool,\n};\n\npub const legacy_encodings = [_]Encoding{\n${dbcsBlocks.join("\n")}\n};\n\npub const LegacyAlias = struct { name: []const u8, encoding: u8 };\n\npub const legacy_aliases = [_]LegacyAlias{\n${dbcsAliases.map((alias) => `    .{ .name = "${alias.name}", .encoding = ${alias.encoding} },`).join("\n")}\n};\n\npub const gb18030_unicode_ranges = [_]u32{${format(gb18030Ranges.uChars, 6, 4)}\n};\n\npub const gb18030_byte_ranges = [_]u32{${format(gb18030Ranges.gbChars, 6, 4)}\n};\n\npub const SingleByteEncoding = struct {\n    decode_units: []const u16,\n    encode_codepoints: []const u32,\n    encode_bytes: []const u8,\n};\n\npub const single_byte_encodings = [_]SingleByteEncoding{\n${singleByteBlocks.join("\n")}\n};\n\npub const SingleByteAlias = struct { name: []const u8, encoding: u16 };\n\npub const single_byte_aliases = [_]SingleByteAlias{\n${singleByteAliases.map((alias) => `    .{ .name = "${alias.name}", .encoding = ${alias.encoding} },`).join("\n")}\n};\n\npub fn findLegacy(name: []const u8) ?Encoding {\n    var low: usize = 0;\n    var high = legacy_aliases.len;\n    while (low < high) {\n        const middle = low + (high - low) / 2;\n        switch (std.mem.order(u8, legacy_aliases[middle].name, name)) {\n            .lt => low = middle + 1,\n            .gt => high = middle,\n            .eq => return legacy_encodings[legacy_aliases[middle].encoding],\n        }\n    }\n    return null;\n}\n\npub fn findSingleByte(name: []const u8) ?SingleByteEncoding {\n    var low: usize = 0;\n    var high = single_byte_aliases.len;\n    while (low < high) {\n        const middle = low + (high - low) / 2;\n        switch (std.mem.order(u8, single_byte_aliases[middle].name, name)) {\n            .lt => low = middle + 1,\n            .gt => high = middle,\n            .eq => return single_byte_encodings[single_byte_aliases[middle].encoding],\n        }\n    }\n    return null;\n}\n`;

if (check) {
  const current = await readFile(outputPath, "utf8");
  if (current !== generated) throw new Error(`旧来文字コード表が最新ではありません: ${outputPath}`);
  console.log(`多バイト${dbcsGroups.size}種・単バイト${singleByteGroups.size}種の変換表を検証しました`);
} else {
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, generated);
  console.log(`多バイト${dbcsGroups.size}種・単バイト${singleByteGroups.size}種の変換表を生成しました: ${outputPath}`);
}

function format(values, width, indentation = 12) {
  const lines = [];
  for (let index = 0; index < values.length; index += 12) {
    lines.push(`\n${" ".repeat(indentation)}${values.slice(index, index + 12).map((value) => `0x${value.toString(16).padStart(width, "0")}`).join(", ")},`);
  }
  return lines.join("");
}

function formatFieldArray(values, width) {
  return values.length === 0 ? "&.{}" : `&.{${format(values, width)}\n        }`;
}

function pack(bytes) {
  let packed = 0;
  for (const byte of bytes) packed = packed * 0x100 + byte;
  return bytes.length * 0x100000000 + packed;
}

function keyLength(key) {
  return Math.floor(key / 0x100000000);
}

function keyFirstByte(key) {
  const length = keyLength(key);
  return Math.floor((key % 0x100000000) / 0x100 ** (length - 1)) & 0xff;
}

function utf16Units(text) {
  return Array.from({ length: text.length }, (_, index) => text.charCodeAt(index));
}

function compareArrays(left, right) {
  for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return left.length - right.length;
}
