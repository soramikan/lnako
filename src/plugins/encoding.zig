const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");
const tables = @import("../generated/legacy_encoding.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const Kind = enum { utf8, cesu8, utf7, utf7imap, utf16, utf16le, utf16be, utf32, utf32le, utf32be, ascii, latin1, binary, single_byte, legacy, hex, base64 };

pub fn supports(encoding: []const u8) bool {
    return parseKind(encoding) != null;
}

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    if (std.mem.eql(u8, name, "文字コード変換サポート判定")) {
        const encoding = try valueUtf8(runtime, common.argument(arguments, 0));
        defer runtime.allocator().free(encoding);
        return @as(?Value, .{ .boolean = supports(encoding) });
    }
    if (std.mem.eql(u8, name, "SJIS変換")) return @as(?Value, try encode(runtime, common.argument(arguments, 0), "shift_jis"));
    if (std.mem.eql(u8, name, "SJIS取得")) return @as(?Value, try decode(runtime, common.argument(arguments, 0), "shift_jis"));
    if (std.mem.eql(u8, name, "エンコーディング変換")) {
        const encoding = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(encoding);
        return @as(?Value, try encode(runtime, common.argument(arguments, 0), encoding));
    }
    if (std.mem.eql(u8, name, "エンコーディング取得")) {
        const encoding = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(encoding);
        return @as(?Value, try decode(runtime, common.argument(arguments, 0), encoding));
    }
    return null;
}

pub fn encode(runtime: *Runtime, source: Value, encoding: []const u8) !Value {
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var text = try runtime.valueToString(rooted_source);
    try roots.protect(&text);
    const bytes = try encodeUnits(runtime.allocator(), text.string.units, encoding);
    defer runtime.allocator().free(bytes);
    return runtime.createBytes(bytes);
}

/// Encodes UTF-16 code units without depending on the interpreter Value type.
/// The AOT runtime uses this shared codec so both execution engines consume
/// the same generated legacy tables and replacement rules.
pub fn encodeUnits(allocator: std.mem.Allocator, units: []const u16, encoding: []const u8) ![]u8 {
    const kind = parseKind(encoding) orelse return error.UnsupportedEncoding;
    if (kind == .utf8) {
        var text = try value_mod.String.fromCodeUnits(allocator, units);
        defer text.deinit();
        return text.toUtf8Lossy(allocator);
    }
    if (kind == .cesu8) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try encodeCesu8(allocator, &bytes, units);
        return bytes.toOwnedSlice(allocator);
    }
    if (kind == .utf7 or kind == .utf7imap) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try encodeUtf7(allocator, &bytes, units, kind == .utf7imap);
        return bytes.toOwnedSlice(allocator);
    }
    if (kind == .hex or kind == .base64) {
        if (kind == .hex) {
            return decodeHexAlloc(allocator, units);
        }
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(allocator);
        const complete = units.len - (units.len % 4);
        try appendBase64Decoded(allocator, &decoded, units[0..complete]);
        try appendBase64Decoded(allocator, &decoded, units[complete..]);
        return decoded.toOwnedSlice(allocator);
    }
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    switch (kind) {
        .utf16 => {
            try output.appendSlice(allocator, &.{ 0xff, 0xfe });
            try encodeUtf16(allocator, &output, units, true);
        },
        .utf16le, .utf16be => for (units) |unit| {
            const low: u8 = @truncate(unit);
            const high: u8 = @truncate(unit >> 8);
            if (kind == .utf16le) try output.appendSlice(allocator, &.{ low, high }) else try output.appendSlice(allocator, &.{ high, low });
        },
        .utf32 => {
            try output.appendSlice(allocator, &.{ 0xff, 0xfe, 0x00, 0x00 });
            try encodeUtf32(allocator, &output, units, true);
        },
        .utf32le => try encodeUtf32(allocator, &output, units, true),
        .utf32be => try encodeUtf32(allocator, &output, units, false),
        .ascii => for (units) |unit| try output.append(allocator, if (unit <= 0x7f) @intCast(unit) else '?'),
        .latin1 => for (units) |unit| try output.append(allocator, if (unit <= 0xff) @intCast(unit) else '?'),
        .binary => for (units) |unit| try output.append(allocator, @truncate(unit)),
        .single_byte => try encodeSingleByte(allocator, &output, units, findSingleByte(encoding).?),
        .legacy => try encodeLegacy(allocator, &output, units, findLegacy(encoding).?),
        else => unreachable,
    }
    return output.toOwnedSlice(allocator);
}

pub fn decode(runtime: *Runtime, source: Value, encoding: []const u8) !Value {
    const bytes = try valueBytes(runtime, source);
    defer runtime.allocator().free(bytes);
    const units = try decodeBytes(runtime.allocator(), bytes, encoding);
    defer runtime.allocator().free(units);
    return runtime.stringCodeUnits(units);
}

/// Decodes bytes to UTF-16 code units without depending on the interpreter
/// Value type. The returned slice is owned by the caller.
pub fn decodeBytes(allocator: std.mem.Allocator, bytes: []const u8, encoding: []const u8) ![]u16 {
    const kind = parseKind(encoding) orelse return error.UnsupportedEncoding;
    switch (kind) {
        .utf8 => {
            var decoded = try value_mod.String.fromUtf8Lossy(allocator, bytes);
            defer decoded.deinit();
            return allocator.dupe(u16, stripBom(decoded.units));
        },
        .cesu8 => {
            var output: std.ArrayList(u16) = .empty;
            defer output.deinit(allocator);
            try decodeCesu8(allocator, &output, bytes);
            return allocator.dupe(u16, stripBom(output.items));
        },
        .utf7, .utf7imap => {
            var output: std.ArrayList(u16) = .empty;
            defer output.deinit(allocator);
            try decodeUtf7(allocator, &output, bytes, kind == .utf7imap);
            return allocator.dupe(u16, stripBom(output.items));
        },
        .hex => {
            const encoded = try allocator.alloc(u8, bytes.len * 2);
            defer allocator.free(encoded);
            const alphabet = "0123456789abcdef";
            for (bytes, 0..) |byte, index| {
                encoded[index * 2] = alphabet[byte >> 4];
                encoded[index * 2 + 1] = alphabet[byte & 0x0f];
            }
            var decoded = try value_mod.String.fromUtf8(allocator, encoded);
            defer decoded.deinit();
            return allocator.dupe(u16, decoded.units);
        },
        .base64 => {
            const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            var decoded = try value_mod.String.fromUtf8(allocator, encoded);
            defer decoded.deinit();
            return allocator.dupe(u16, decoded.units);
        },
        else => {},
    }
    const actual_kind = switch (kind) {
        .utf16 => detectUtf16(bytes),
        .utf32 => detectUtf32(bytes),
        else => kind,
    };
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    switch (actual_kind) {
        .utf16le, .utf16be => {
            var index: usize = 0;
            while (index + 1 < bytes.len) : (index += 2) {
                const unit = if (actual_kind == .utf16le) @as(u16, bytes[index]) | @as(u16, bytes[index + 1]) << 8 else @as(u16, bytes[index]) << 8 | bytes[index + 1];
                try output.append(allocator, unit);
            }
            // NodeのStringDecoder(utf16le)とiconv-liteのUTF16BE decoderは
            // 末尾の片方だけのバイトを破棄する。
        },
        .utf32le, .utf32be => {
            var index: usize = 0;
            while (index + 3 < bytes.len) : (index += 4) {
                const codepoint = if (actual_kind == .utf32le)
                    @as(u32, bytes[index]) | @as(u32, bytes[index + 1]) << 8 | @as(u32, bytes[index + 2]) << 16 | @as(u32, bytes[index + 3]) << 24
                else
                    @as(u32, bytes[index]) << 24 | @as(u32, bytes[index + 1]) << 16 | @as(u32, bytes[index + 2]) << 8 | bytes[index + 3];
                try appendDecodedCodepoint(allocator, &output, codepoint);
            }
            if (index < bytes.len) try output.append(allocator, 0xfffd);
        },
        .ascii => for (bytes) |byte| try output.append(allocator, if (byte <= 0x7f) byte else 0xfffd),
        .latin1 => for (bytes) |byte| try output.append(allocator, byte),
        .binary => for (bytes) |byte| try output.append(allocator, byte),
        .single_byte => {
            const table = findSingleByte(encoding).?;
            for (bytes) |byte| try output.append(allocator, table.decode_units[byte]);
        },
        .legacy => try decodeLegacy(allocator, &output, bytes, findLegacy(encoding).?),
        else => unreachable,
    }
    return allocator.dupe(u16, if (actual_kind == .utf16le or actual_kind == .utf16be or actual_kind == .utf32le or actual_kind == .utf32be) stripBom(output.items) else output.items);
}

fn encodeCesu8(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16) !void {
    for (units) |unit| {
        if (unit < 0x80) {
            try output.append(allocator, @intCast(unit));
        } else if (unit < 0x800) {
            try output.appendSlice(allocator, &.{ @intCast(0xc0 + (unit >> 6)), @intCast(0x80 + (unit & 0x3f)) });
        } else {
            try output.appendSlice(allocator, &.{ @intCast(0xe0 + (unit >> 12)), @intCast(0x80 + ((unit >> 6) & 0x3f)), @intCast(0x80 + (unit & 0x3f)) });
        }
    }
}

fn decodeCesu8(allocator: std.mem.Allocator, output: *std.ArrayList(u16), bytes: []const u8) !void {
    var accumulator: u16 = 0;
    var continuation_bytes: u8 = 0;
    var accumulated_bytes: u8 = 0;
    for (bytes) |byte| {
        if (byte & 0xc0 != 0x80) {
            if (continuation_bytes > 0) {
                try output.append(allocator, 0xfffd);
                continuation_bytes = 0;
            }
            if (byte < 0x80) {
                try output.append(allocator, byte);
            } else if (byte < 0xe0) {
                accumulator = byte & 0x1f;
                continuation_bytes = 1;
                accumulated_bytes = 1;
            } else if (byte < 0xf0) {
                accumulator = byte & 0x0f;
                continuation_bytes = 2;
                accumulated_bytes = 1;
            } else {
                try output.append(allocator, 0xfffd);
            }
        } else if (continuation_bytes > 0) {
            accumulator = (accumulator << 6) | (byte & 0x3f);
            continuation_bytes -= 1;
            accumulated_bytes += 1;
            if (continuation_bytes == 0) {
                if ((accumulated_bytes == 2 and accumulator < 0x80 and accumulator > 0) or (accumulated_bytes == 3 and accumulator < 0x800)) {
                    try output.append(allocator, 0xfffd);
                } else {
                    try output.append(allocator, accumulator);
                }
            }
        } else {
            try output.append(allocator, 0xfffd);
        }
    }
    if (continuation_bytes > 0) try output.append(allocator, 0xfffd);
}

fn encodeUtf7(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, imap: bool) !void {
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (isUtf7Direct(unit, imap)) {
            try output.append(allocator, @intCast(unit));
            if (imap and unit == '&') try output.append(allocator, '-');
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and !isUtf7Direct(units[index], imap)) : (index += 1) {}
        try output.append(allocator, if (imap) '&' else '+');
        if (!imap and index - start == 1 and units[start] == '+') {
            // 単独の非directチャンクとして現れた+だけが「+-」になる。
        } else {
            try appendUtf7Base64(allocator, output, units[start..index], imap);
        }
        try output.append(allocator, '-');
    }
}

fn decodeUtf7(allocator: std.mem.Allocator, output: *std.ArrayList(u16), bytes: []const u8, imap: bool) !void {
    const marker: u8 = if (imap) '&' else '+';
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != marker) {
            try output.append(allocator, if (bytes[index] <= 0x7f) bytes[index] else 0xfffd);
            index += 1;
            continue;
        }
        index += 1;
        const start = index;
        while (index < bytes.len and isUtf7Base64Byte(bytes[index], imap)) : (index += 1) {}
        if (index == start and index < bytes.len and bytes[index] == '-') {
            try output.append(allocator, marker);
            index += 1;
            continue;
        }
        try appendUtf7Decoded(allocator, output, bytes[start..index], imap);
        if (index < bytes.len and bytes[index] == '-') index += 1;
    }
}

fn isUtf7Direct(unit: u16, imap: bool) bool {
    if (imap) return unit >= 0x20 and unit <= 0x7e;
    return std.ascii.isAlphanumeric(@truncate(unit)) and unit <= 0x7f or switch (unit) {
        '\'', '(', ')', ',', '-', '.', '/', ':', '?', ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

fn isUtf7Base64Byte(byte: u8, imap: bool) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/' or (imap and byte == ',');
}

fn appendUtf7Base64(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, imap: bool) !void {
    const source = try allocator.alloc(u8, units.len * 2);
    defer allocator.free(source);
    for (units, 0..) |unit, index| {
        source[index * 2] = @truncate(unit >> 8);
        source[index * 2 + 1] = @truncate(unit);
    }
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, source);
    var length = encoded.len;
    while (length > 0 and encoded[length - 1] == '=') length -= 1;
    for (encoded[0..length]) |byte| try output.append(allocator, if (imap and byte == '/') ',' else byte);
}

fn appendUtf7Decoded(allocator: std.mem.Allocator, output: *std.ArrayList(u16), encoded: []const u8, imap: bool) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var group: [4]u8 = undefined;
    var length: usize = 0;
    for (encoded) |byte| {
        const unit: u16 = if (imap and byte == ',') '/' else byte;
        const digit = base64Digit(unit) orelse continue;
        group[length] = digit;
        length += 1;
        if (length == 4) {
            try bytes.appendSlice(allocator, &.{ group[0] << 2 | group[1] >> 4, group[1] << 4 | group[2] >> 2, group[2] << 6 | group[3] });
            length = 0;
        }
    }
    if (length >= 2) try bytes.append(allocator, group[0] << 2 | group[1] >> 4);
    if (length >= 3) try bytes.append(allocator, group[1] << 4 | group[2] >> 2);
    var index: usize = 0;
    while (index + 1 < bytes.items.len) : (index += 2) try output.append(allocator, @as(u16, bytes.items[index]) << 8 | bytes.items[index + 1]);
}

fn encodeUtf16(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, little_endian: bool) !void {
    for (units) |unit| {
        const low: u8 = @truncate(unit);
        const high: u8 = @truncate(unit >> 8);
        if (little_endian) try output.appendSlice(allocator, &.{ low, high }) else try output.appendSlice(allocator, &.{ high, low });
    }
}

fn encodeUtf32(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, little_endian: bool) !void {
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u32 = first;
        index += 1;
        if (first >= 0xd800 and first <= 0xdbff and index < units.len and units[index] >= 0xdc00 and units[index] <= 0xdfff) {
            codepoint = 0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, units[index]) - 0xdc00);
            index += 1;
        }
        const bytes = [4]u8{ @truncate(codepoint), @truncate(codepoint >> 8), @truncate(codepoint >> 16), @truncate(codepoint >> 24) };
        if (little_endian) {
            try output.appendSlice(allocator, &bytes);
        } else {
            try output.appendSlice(allocator, &.{ bytes[3], bytes[2], bytes[1], bytes[0] });
        }
    }
}

fn appendDecodedCodepoint(allocator: std.mem.Allocator, output: *std.ArrayList(u16), raw: u32) !void {
    const codepoint = if (raw <= 0x10ffff) raw else 0xfffd;
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const adjusted = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (adjusted >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
}

fn detectUtf16(bytes: []const u8) Kind {
    if (bytes.len >= 2) {
        if (bytes[0] == 0xff and bytes[1] == 0xfe) return .utf16le;
        if (bytes[0] == 0xfe and bytes[1] == 0xff) return .utf16be;
    }
    var le: usize = 0;
    var be: usize = 0;
    const pairs = @min(bytes.len / 2, 100);
    for (0..pairs) |index| {
        const first = bytes[index * 2];
        const second = bytes[index * 2 + 1];
        if (first == 0 and second != 0) be += 1;
        if (first != 0 and second == 0) le += 1;
    }
    return if (be > le) .utf16be else .utf16le;
}

fn detectUtf32(bytes: []const u8) Kind {
    if (bytes.len >= 4) {
        if (std.mem.eql(u8, bytes[0..4], &.{ 0xff, 0xfe, 0x00, 0x00 })) return .utf32le;
        if (std.mem.eql(u8, bytes[0..4], &.{ 0x00, 0x00, 0xfe, 0xff })) return .utf32be;
    }
    var invalid_le: i32 = 0;
    var invalid_be: i32 = 0;
    var bmp_le: i32 = 0;
    var bmp_be: i32 = 0;
    const groups = @min(bytes.len / 4, 100);
    for (0..groups) |index| {
        const group = bytes[index * 4 ..][0..4];
        if (group[0] != 0 or group[1] > 0x10) invalid_be += 1;
        if (group[3] != 0 or group[2] > 0x10) invalid_le += 1;
        if (group[0] == 0 and group[1] == 0 and (group[2] != 0 or group[3] != 0)) bmp_be += 1;
        if ((group[0] != 0 or group[1] != 0) and group[2] == 0 and group[3] == 0) bmp_le += 1;
    }
    return if (bmp_be - invalid_be > bmp_le - invalid_le) .utf32be else .utf32le;
}

fn encodeLegacy(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, table: tables.Encoding) !void {
    var index: usize = 0;
    while (index < units.len) {
        var sequence_matched = false;
        for (table.encode_sequence_keys, 0..) |key, sequence_index| {
            const start: usize = @intCast(table.encode_sequence_offsets[sequence_index]);
            const end: usize = @intCast(table.encode_sequence_offsets[sequence_index + 1]);
            const sequence = table.encode_sequence_units[start..end];
            if (index + sequence.len > units.len or !std.mem.eql(u16, units[index .. index + sequence.len], sequence)) continue;
            try appendPackedKey(allocator, output, key);
            index += sequence.len;
            sequence_matched = true;
            break;
        }
        if (sequence_matched) continue;

        var codepoint: u32 = units[index];
        index += 1;
        if (codepoint >= 0xd800 and codepoint <= 0xdbff and index < units.len and units[index] >= 0xdc00 and units[index] <= 0xdfff) {
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (@as(u32, units[index]) - 0xdc00);
            index += 1;
        }
        const position = binarySearch(table.encode_codepoints, codepoint) orelse {
            if (table.gb18030 and try encodeGb18030(allocator, output, codepoint)) continue;
            try output.append(allocator, '?');
            continue;
        };
        try appendPackedKey(allocator, output, table.encode_keys[position]);
    }
}

fn encodeSingleByte(allocator: std.mem.Allocator, output: *std.ArrayList(u8), units: []const u16, table: tables.SingleByteEncoding) !void {
    for (units) |unit| {
        const position = binarySearch(table.encode_codepoints, unit) orelse {
            try output.append(allocator, '?');
            continue;
        };
        try output.append(allocator, table.encode_bytes[position]);
    }
}

fn decodeLegacy(allocator: std.mem.Allocator, output: *std.ArrayList(u16), bytes: []const u8, table: tables.Encoding) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (table.gb18030 and index + 4 <= bytes.len) {
            if (decodeGb18030(bytes[index..][0..4])) |codepoint| {
                try appendCodepoint(allocator, output, @intCast(codepoint));
                index += 4;
                continue;
            }
        }
        var length: usize = @min(3, bytes.len - index);
        var matched = false;
        while (length > 0) : (length -= 1) {
            const key = packBytes(bytes[index .. index + length]);
            const position = binarySearchU64(table.decode_keys, key) orelse continue;
            const start: usize = @intCast(table.decode_offsets[position]);
            const end: usize = @intCast(table.decode_offsets[position + 1]);
            try output.appendSlice(allocator, table.decode_units[start..end]);
            index += length;
            matched = true;
            break;
        }
        if (!matched) {
            try output.append(allocator, 0xfffd);
            index += 1;
        }
    }
}

fn appendPackedKey(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: u64) !void {
    const length: usize = @intCast(key >> 32);
    const packed_bytes = key & 0xffffffff;
    for (0..length) |offset| {
        const shift: u6 = @intCast((length - offset - 1) * 8);
        try output.append(allocator, @truncate(packed_bytes >> shift));
    }
}

fn packBytes(bytes: []const u8) u64 {
    var packed_value: u64 = 0;
    for (bytes) |byte| packed_value = packed_value << 8 | byte;
    return @as(u64, bytes.len) << 32 | packed_value;
}

fn encodeGb18030(allocator: std.mem.Allocator, output: *std.ArrayList(u8), codepoint: u32) !bool {
    const range_index = rangeFloor(&tables.gb18030_unicode_ranges, codepoint) orelse return false;
    var pointer = tables.gb18030_byte_ranges[range_index] + (codepoint - tables.gb18030_unicode_ranges[range_index]);
    const first = 0x81 + pointer / 12600;
    if (first > 0xfe) return false;
    pointer %= 12600;
    const second = 0x30 + pointer / 1260;
    pointer %= 1260;
    const third = 0x81 + pointer / 10;
    const fourth = 0x30 + pointer % 10;
    try output.appendSlice(allocator, &.{ @intCast(first), @intCast(second), @intCast(third), @intCast(fourth) });
    return true;
}

fn decodeGb18030(bytes: *const [4]u8) ?u32 {
    if (bytes[0] < 0x81 or bytes[0] > 0xfe or bytes[1] < 0x30 or bytes[1] > 0x39 or bytes[2] < 0x81 or bytes[2] > 0xfe or bytes[3] < 0x30 or bytes[3] > 0x39) return null;
    const pointer = (@as(u32, bytes[0]) - 0x81) * 12600 + (@as(u32, bytes[1]) - 0x30) * 1260 + (@as(u32, bytes[2]) - 0x81) * 10 + (@as(u32, bytes[3]) - 0x30);
    const range_index = rangeFloor(&tables.gb18030_byte_ranges, pointer) orelse return null;
    const codepoint = tables.gb18030_unicode_ranges[range_index] + pointer - tables.gb18030_byte_ranges[range_index];
    return if (codepoint <= 0x10ffff) codepoint else null;
}

fn rangeFloor(values: []const u32, needle: u32) ?usize {
    if (values.len == 0 or values[0] > needle) return null;
    var low: usize = 0;
    var high = values.len;
    while (low < high - 1) {
        const middle = low + (high - low + 1) / 2;
        if (values[middle] <= needle) low = middle else high = middle;
    }
    return low;
}

fn appendCodepoint(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const adjusted = @as(u32, codepoint) - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (adjusted >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
}

fn binarySearch(values: []const u32, needle: u32) ?usize {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (values[middle] < needle) low = middle + 1 else high = middle;
    }
    return if (low < values.len and values[low] == needle) low else null;
}

fn binarySearchU64(values: []const u64, needle: u64) ?usize {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (values[middle] < needle) low = middle + 1 else high = middle;
    }
    return if (low < values.len and values[low] == needle) low else null;
}

fn parseKind(name: []const u8) ?Kind {
    var normalized: [32]u8 = undefined;
    const key = normalizeName(name, &normalized) orelse return null;
    if (isAny(key, &.{ "utf8", "unicode11utf8" })) return .utf8;
    if (std.mem.eql(u8, key, "cesu8")) return .cesu8;
    if (isAny(key, &.{ "utf7", "unicode11utf7" })) return .utf7;
    if (std.mem.eql(u8, key, "utf7imap")) return .utf7imap;
    if (std.mem.eql(u8, key, "utf16")) return .utf16;
    if (isAny(key, &.{ "utf16le", "ucs2" })) return .utf16le;
    if (std.mem.eql(u8, key, "utf16be")) return .utf16be;
    if (isAny(key, &.{ "utf32", "ucs4" })) return .utf32;
    if (std.mem.eql(u8, key, "utf32le") or std.mem.eql(u8, key, "ucs4le")) return .utf32le;
    if (std.mem.eql(u8, key, "utf32be") or std.mem.eql(u8, key, "ucs4be")) return .utf32be;
    if (std.mem.eql(u8, key, "ascii")) return .ascii;
    if (isAny(key, &.{ "latin1", "iso88591" })) return .latin1;
    if (std.mem.eql(u8, key, "binary")) return .binary;
    if (std.mem.eql(u8, key, "hex")) return .hex;
    if (std.mem.eql(u8, key, "base64")) return .base64;
    if (tables.findLegacy(key) != null) return .legacy;
    if (tables.findSingleByte(key) != null) return .single_byte;
    return null;
}

fn findSingleByte(name: []const u8) ?tables.SingleByteEncoding {
    var normalized: [32]u8 = undefined;
    const key = normalizeName(name, &normalized) orelse return null;
    return tables.findSingleByte(key);
}

fn findLegacy(name: []const u8) ?tables.Encoding {
    var normalized: [32]u8 = undefined;
    const key = normalizeName(name, &normalized) orelse return null;
    return tables.findLegacy(key);
}

fn normalizeName(name: []const u8, output: *[32]u8) ?[]const u8 {
    var source = name;
    if (source.len >= 5 and source[source.len - 5] == ':') {
        var year = true;
        for (source[source.len - 4 ..]) |byte| year = year and std.ascii.isDigit(byte);
        if (year) source = source[0 .. source.len - 5];
    }
    var length: usize = 0;
    for (source) |byte| {
        const lower = std.ascii.toLower(byte);
        if (!std.ascii.isAlphanumeric(lower)) continue;
        if (length >= output.len) return null;
        output[length] = lower;
        length += 1;
    }
    return output[0..length];
}

fn valueBytes(runtime: *Runtime, value: Value) ![]u8 {
    if (value == .bytes) return runtime.allocator().dupe(u8, value.bytes.bytes);
    if (value == .array) {
        var bytes = try runtime.allocator().alloc(u8, value.array.len());
        errdefer runtime.allocator().free(bytes);
        for (value.array.items.items, 0..) |item, index| {
            const number = try runtime.valueToNumber(item);
            bytes[index] = if (!std.math.isFinite(number)) 0 else @intFromFloat(@mod(@trunc(number), 256.0));
        }
        return bytes;
    }
    return valueUtf8(runtime, value);
}

fn valueUtf8(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

fn decodeHexAlloc(allocator: std.mem.Allocator, source: []const u16) ![]u8 {
    var length: usize = 0;
    while ((length + 1) * 2 <= source.len) : (length += 1) {
        if (hexDigit(source[length * 2]) == null or hexDigit(source[length * 2 + 1]) == null) break;
    }
    const result = try allocator.alloc(u8, length);
    errdefer allocator.free(result);
    for (result, 0..) |*byte, index| byte.* = hexDigit(source[index * 2]).? << 4 | hexDigit(source[index * 2 + 1]).?;
    return result;
}

fn appendBase64Decoded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), source: []const u16) !void {
    var group: [4]u8 = undefined;
    var length: usize = 0;
    for (source) |unit| {
        if (unit == '=') break;
        const value = base64Digit(unit) orelse continue;
        group[length] = value;
        length += 1;
        if (length == 4) {
            try output.appendSlice(allocator, &.{
                group[0] << 2 | group[1] >> 4,
                group[1] << 4 | group[2] >> 2,
                group[2] << 6 | group[3],
            });
            length = 0;
        }
    }
    if (length >= 2) try output.append(allocator, group[0] << 2 | group[1] >> 4);
    if (length >= 3) try output.append(allocator, group[1] << 4 | group[2] >> 2);
}

fn hexDigit(unit: u16) ?u8 {
    return switch (unit) {
        '0'...'9' => @intCast(unit - '0'),
        'a'...'f' => @intCast(unit - 'a' + 10),
        'A'...'F' => @intCast(unit - 'A' + 10),
        else => null,
    };
}

fn base64Digit(unit: u16) ?u8 {
    return switch (unit) {
        'A'...'Z' => @intCast(unit - 'A'),
        'a'...'z' => @intCast(unit - 'a' + 26),
        '0'...'9' => @intCast(unit - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

fn stripBom(units: []const u16) []const u16 {
    return if (units.len > 0 and units[0] == 0xfeff) units[1..] else units;
}

fn isAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

test "Shift_JISとEUC-JPをBufferへ相互変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var source = try runtime.stringUtf8("日本語ABC");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var encoded = try encode(&runtime, source, "Shift_JIS");
    try roots.protect(&encoded);
    const decoded = try decode(&runtime, encoded, "sjis");
    const utf8 = try decoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("日本語ABC", utf8);
}

test "Node内部エンコーディングの境界値を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var invalid_utf8 = try runtime.createBytes(&.{ 0xe3, 0x81 });
    try roots.protect(&invalid_utf8);
    const decoded_utf8 = try decode(&runtime, invalid_utf8, "utf8");
    const decoded_utf8_text = try decoded_utf8.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(decoded_utf8_text);
    try std.testing.expectEqualStrings("�", decoded_utf8_text);

    var base64_source = try runtime.stringUtf8("QUI=xx");
    try roots.protect(&base64_source);
    var base64 = try encode(&runtime, base64_source, "base64");
    try roots.protect(&base64);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x42, 0xc7 }, base64.bytes.bytes);

    var hex_source = try runtime.stringUtf8("4142zz");
    try roots.protect(&hex_source);
    const hex = try encode(&runtime, hex_source, "hex");
    try std.testing.expectEqualSlices(u8, "AB", hex.bytes.bytes);
}

test "エンコーディング名のサポート判定は別名と年指定を正規化する" {
    for ([_][]const u8{ "Shift_JIS", "utf16", "windows-1252:2000", "gb18030", "euc-kr", "big5", "cesu8", "utf7-imap" }) |name| {
        try std.testing.expect(supports(name));
    }
    for ([_][]const u8{ "utf", "ucs2le", "x-lnako-unknown" }) |name| {
        try std.testing.expect(!supports(name));
    }
}

test "CESU-8とUTF-7をUTF-16コード単位のまま往復する" {
    var cesu_units: std.ArrayList(u16) = .empty;
    defer cesu_units.deinit(std.testing.allocator);
    try decodeCesu8(std.testing.allocator, &cesu_units, &.{ 0xe6, 0x97, 0xa5, 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80 });
    try std.testing.expectEqualSlices(u16, &.{ 0x65e5, 0xd83d, 0xde00 }, cesu_units.items);

    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("A+&日本😀");
    try roots.protect(&source);
    for ([_][]const u8{ "cesu8", "utf7", "utf7-imap" }) |name| {
        var encoded = try encode(&runtime, source, name);
        try roots.protect(&encoded);
        const decoded = try decode(&runtime, encoded, name);
        try std.testing.expectEqualSlices(u16, source.string.units, decoded.string.units);
    }
}
