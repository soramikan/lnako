const std = @import("std");

pub const NormalizedSource = struct {
    text: []const u8,
    /// 正規化後の各バイト位置から、入力UTF-8のバイト位置への対応。
    source_offsets: []const usize,

    pub fn sourceOffset(self: NormalizedSource, normalized_offset: usize) usize {
        return self.source_offsets[@min(normalized_offset, self.source_offsets.len - 1)];
    }
};

const State = enum { code, literal, line_comment, block_comment };

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) !NormalizedSource {
    var output: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    errdefer output.deinit(allocator);
    errdefer offsets.deinit(allocator);

    var state: State = .code;
    var literal_close: []const u8 = "";
    var literal_output_close: []const u8 = "";
    var i: usize = 0;
    while (i < input.len) {
        switch (state) {
            .literal => {
                if (std.mem.startsWith(u8, input[i..], literal_close)) {
                    try appendMapped(&output, &offsets, allocator, literal_output_close, i);
                    i += literal_close.len;
                    state = .code;
                    continue;
                }
                const decoded = try decodeAt(input, i);
                try appendMapped(&output, &offsets, allocator, input[i .. i + decoded.len], i);
                i += decoded.len;
            },
            .line_comment => {
                if (input[i] == '\r' or input[i] == '\n') {
                    const consumed: usize = if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
                    try appendMapped(&output, &offsets, allocator, "\n", i);
                    i += consumed;
                    state = .code;
                    continue;
                }
                const decoded = try decodeAt(input, i);
                try appendMapped(&output, &offsets, allocator, input[i .. i + decoded.len], i);
                i += decoded.len;
            },
            .block_comment => {
                if (std.mem.startsWith(u8, input[i..], "*/")) {
                    try appendMapped(&output, &offsets, allocator, "*/", i);
                    i += 2;
                    state = .code;
                    continue;
                }
                if (std.mem.startsWith(u8, input[i..], "＊／")) {
                    try appendMapped(&output, &offsets, allocator, "*/", i);
                    i += "＊／".len;
                    state = .code;
                    continue;
                }
                if (input[i] == '\r') {
                    const consumed: usize = if (i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
                    try appendMapped(&output, &offsets, allocator, "\n", i);
                    i += consumed;
                    continue;
                }
                const decoded = try decodeAt(input, i);
                try appendMapped(&output, &offsets, allocator, input[i .. i + decoded.len], i);
                i += decoded.len;
            },
            .code => {
                if (input[i] == '\r') {
                    const consumed: usize = if (i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
                    try appendMapped(&output, &offsets, allocator, "\n", i);
                    i += consumed;
                    continue;
                }
                if (std.mem.startsWith(u8, input[i..], "//") or std.mem.startsWith(u8, input[i..], "／／")) {
                    const consumed: usize = if (std.mem.startsWith(u8, input[i..], "//")) 2 else "／／".len;
                    try appendMapped(&output, &offsets, allocator, "//", i);
                    i += consumed;
                    state = .line_comment;
                    continue;
                }
                if (std.mem.startsWith(u8, input[i..], "/*") or std.mem.startsWith(u8, input[i..], "／＊")) {
                    const consumed: usize = if (std.mem.startsWith(u8, input[i..], "/*")) 2 else "／＊".len;
                    try appendMapped(&output, &offsets, allocator, "/*", i);
                    i += consumed;
                    state = .block_comment;
                    continue;
                }
                if (std.mem.startsWith(u8, input[i..], "※")) {
                    try appendMapped(&output, &offsets, allocator, "#", i);
                    i += "※".len;
                    state = .line_comment;
                    continue;
                }
                if (input[i] == '#') {
                    try appendMapped(&output, &offsets, allocator, "#", i);
                    i += 1;
                    state = .line_comment;
                    continue;
                }

                const string_delimiters = [_]struct { open: []const u8, close: []const u8, normalized: []const u8 }{
                    .{ .open = "🌴", .close = "🌴", .normalized = "🌴" },
                    .{ .open = "🌿", .close = "🌿", .normalized = "🌿" },
                    .{ .open = "「", .close = "」", .normalized = "「" },
                    .{ .open = "『", .close = "』", .normalized = "『" },
                    .{ .open = "“", .close = "”", .normalized = "“" },
                    .{ .open = "\"", .close = "\"", .normalized = "\"" },
                    .{ .open = "'", .close = "'", .normalized = "'" },
                };
                var found_literal = false;
                for (string_delimiters) |delimiter| {
                    if (std.mem.startsWith(u8, input[i..], delimiter.open)) {
                        try appendMapped(&output, &offsets, allocator, delimiter.normalized, i);
                        i += delimiter.open.len;
                        literal_close = delimiter.close;
                        literal_output_close = delimiter.close;
                        state = .literal;
                        found_literal = true;
                        break;
                    }
                }
                if (found_literal) continue;

                const decoded = try decodeAt(input, i);
                var encoded: [4]u8 = undefined;
                const replacement = replacementFor(decoded.codepoint);
                if (replacement) |ascii| {
                    encoded[0] = ascii;
                    try appendMapped(&output, &offsets, allocator, encoded[0..1], i);
                    if (ascii == '#') state = .line_comment;
                } else if (decoded.codepoint >= 0xFF01 and decoded.codepoint <= 0xFF5E) {
                    encoded[0] = @intCast(decoded.codepoint - 0xFEE0);
                    try appendMapped(&output, &offsets, allocator, encoded[0..1], i);
                    if (encoded[0] == '#') state = .line_comment;
                } else {
                    try appendMapped(&output, &offsets, allocator, input[i .. i + decoded.len], i);
                }
                i += decoded.len;
            },
        }
    }

    if (state == .line_comment) {
        try appendMapped(&output, &offsets, allocator, "\n", input.len);
    } else if (state == .block_comment) {
        try appendMapped(&output, &offsets, allocator, "*/", input.len);
    }
    try offsets.append(allocator, input.len);
    return .{
        .text = try output.toOwnedSlice(allocator),
        .source_offsets = try offsets.toOwnedSlice(allocator),
    };
}

const Decoded = struct { codepoint: u21, len: usize };

pub fn decodeAt(input: []const u8, offset: usize) !Decoded {
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return error.InvalidUtf8;
    if (offset + len > input.len) return error.InvalidUtf8;
    const codepoint = std.unicode.utf8Decode(input[offset .. offset + len]) catch return error.InvalidUtf8;
    return .{ .codepoint = codepoint, .len = len };
}

fn appendMapped(
    output: *std.ArrayList(u8),
    offsets: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    source_offset: usize,
) !void {
    try output.appendSlice(allocator, bytes);
    try offsets.appendNTimes(allocator, source_offset, bytes.len);
}

fn replacementFor(codepoint: u21) ?u8 {
    return switch (codepoint) {
        0x2010, 0x2011, 0x2013, 0x2014, 0x2015, 0x2212, 0x2796 => '-',
        0x02DC, 0x02F7, 0x2053, 0x223C, 0x301C, 0xFF5E => '~',
        0x2000, 0x2002...0x2007, 0x2009, 0x200A, 0x200B, 0x202F, 0x205F, 0x3164 => ' ',
        0x203B => '#',
        0x3002 => ';',
        0x3010 => '[',
        0x3011 => ']',
        0x3001, 0xFF0C => ',',
        0x2715...0x2718, 0x274C => '*',
        0x2795 => '+',
        0x1F7F0 => '=',
        else => null,
    };
}

test "コードだけを半角へ正規化する" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "Ａ＝１。『Ａ＝１』\r\n※ コメントＡ");
    defer allocator.free(normalized.text);
    defer allocator.free(normalized.source_offsets);

    try std.testing.expectEqualStrings("A=1;『Ａ＝１』\n# コメントＡ\n", normalized.text);
    try std.testing.expectEqual(@as(usize, 0), normalized.sourceOffset(0));
    try std.testing.expectEqual("Ａ＝１。『Ａ＝１』\r\n※ コメントＡ".len, normalized.sourceOffset(normalized.text.len));
}

test "全角ブロックコメントの区切りを正規化する" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "A／＊ Ｂ＝１ ＊／＝2");
    defer allocator.free(normalized.text);
    defer allocator.free(normalized.source_offsets);
    try std.testing.expectEqualStrings("A/* Ｂ＝１ */=2", normalized.text);
}

test "公式前処理の全角記号と改行規則に合わせる" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "１２３「１２３」", .expected = "123「１２３」" },
        .{ .input = "１２３🌴１２３🌴１２３", .expected = "123🌴１２３🌴123" },
        .{ .input = "123\r\n456\r789", .expected = "123\n456\n789" },
        .{ .input = "！＄１２３４５＃", .expected = "!$12345#\n" },
        .{ .input = "123、456。", .expected = "123,456;" },
        .{ .input = "３．１４", .expected = "3.14" },
        .{ .input = "/* \"Ａ＝１\" */", .expected = "/* \"Ａ＝１\" */" },
    };
    for (cases) |case| {
        const normalized = try normalize(allocator, case.input);
        defer allocator.free(normalized.text);
        defer allocator.free(normalized.source_offsets);
        try std.testing.expectEqualStrings(case.expected, normalized.text);
    }
}
