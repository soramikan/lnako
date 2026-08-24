const std = @import("std");

/// ECMAScript互換のUTF-16コード単位列。添字と長さはUnicode scalar数ではなくu16単位で扱う。
pub const String = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    units: []u16,

    pub fn fromUtf8(allocator: std.mem.Allocator, utf8: []const u8) !String {
        var units = try allocator.alloc(u16, utf8.len);
        errdefer allocator.free(units);
        var source_index: usize = 0;
        var output_index: usize = 0;
        while (source_index < utf8.len) {
            const length = try std.unicode.utf8ByteSequenceLength(utf8[source_index]);
            if (source_index + length > utf8.len) return error.InvalidUtf8;
            const codepoint = try std.unicode.utf8Decode(utf8[source_index .. source_index + length]);
            source_index += length;
            if (codepoint <= 0xffff) {
                units[output_index] = @intCast(codepoint);
                output_index += 1;
            } else {
                const offset = codepoint - 0x10000;
                units[output_index] = @intCast(0xd800 + (offset >> 10));
                units[output_index + 1] = @intCast(0xdc00 + (offset & 0x3ff));
                output_index += 2;
            }
        }
        units = try allocator.realloc(units, output_index);
        return .{ .allocator = allocator, .units = units };
    }

    /// Node.jsのBuffer.toString()と同じWHATWG UTF-8 decoderの置換規則で、
    /// 不正な入力をU+FFFDへ置き換える。
    pub fn fromUtf8Lossy(allocator: std.mem.Allocator, utf8: []const u8) !String {
        var units = try allocator.alloc(u16, utf8.len);
        errdefer allocator.free(units);
        var source_index: usize = 0;
        var output_index: usize = 0;
        var codepoint: u32 = 0;
        var bytes_seen: u3 = 0;
        var bytes_needed: u3 = 0;
        var lower_boundary: u8 = 0x80;
        var upper_boundary: u8 = 0xbf;

        while (source_index < utf8.len) {
            const byte = utf8[source_index];
            if (bytes_needed == 0) {
                if (byte <= 0x7f) {
                    units[output_index] = byte;
                    output_index += 1;
                    source_index += 1;
                } else if (byte >= 0xc2 and byte <= 0xdf) {
                    codepoint = byte & 0x1f;
                    bytes_needed = 1;
                    source_index += 1;
                } else if (byte >= 0xe0 and byte <= 0xef) {
                    codepoint = byte & 0x0f;
                    bytes_needed = 2;
                    lower_boundary = if (byte == 0xe0) 0xa0 else 0x80;
                    upper_boundary = if (byte == 0xed) 0x9f else 0xbf;
                    source_index += 1;
                } else if (byte >= 0xf0 and byte <= 0xf4) {
                    codepoint = byte & 0x07;
                    bytes_needed = 3;
                    lower_boundary = if (byte == 0xf0) 0x90 else 0x80;
                    upper_boundary = if (byte == 0xf4) 0x8f else 0xbf;
                    source_index += 1;
                } else {
                    units[output_index] = 0xfffd;
                    output_index += 1;
                    source_index += 1;
                }
                continue;
            }

            if (byte < lower_boundary or byte > upper_boundary) {
                units[output_index] = 0xfffd;
                output_index += 1;
                codepoint = 0;
                bytes_seen = 0;
                bytes_needed = 0;
                lower_boundary = 0x80;
                upper_boundary = 0xbf;
                continue;
            }

            lower_boundary = 0x80;
            upper_boundary = 0xbf;
            codepoint = (codepoint << 6) | (byte & 0x3f);
            bytes_seen += 1;
            source_index += 1;
            if (bytes_seen != bytes_needed) continue;

            if (codepoint <= 0xffff) {
                units[output_index] = @intCast(codepoint);
                output_index += 1;
            } else {
                const offset = codepoint - 0x10000;
                units[output_index] = @intCast(0xd800 + (offset >> 10));
                units[output_index + 1] = @intCast(0xdc00 + (offset & 0x3ff));
                output_index += 2;
            }
            codepoint = 0;
            bytes_seen = 0;
            bytes_needed = 0;
        }
        if (bytes_needed != 0) {
            units[output_index] = 0xfffd;
            output_index += 1;
        }
        units = try allocator.realloc(units, output_index);
        return .{ .allocator = allocator, .units = units };
    }

    pub fn fromCodeUnits(allocator: std.mem.Allocator, units: []const u16) !String {
        return .{ .allocator = allocator, .units = try allocator.dupe(u16, units) };
    }

    pub fn deinit(self: *String) void {
        self.allocator.free(self.units);
        self.* = undefined;
    }

    pub fn clone(self: String, allocator: std.mem.Allocator) !String {
        return fromCodeUnits(allocator, self.units);
    }

    pub fn len(self: String) usize {
        return self.units.len;
    }

    pub fn eql(left: String, right: String) bool {
        return std.mem.eql(u16, left.units, right.units);
    }

    pub fn order(left: String, right: String) std.math.Order {
        const common = @min(left.units.len, right.units.len);
        for (left.units[0..common], right.units[0..common]) |a, b| {
            if (a < b) return .lt;
            if (a > b) return .gt;
        }
        return std.math.order(left.units.len, right.units.len);
    }

    pub fn codeUnitAt(self: String, index: usize) ?u16 {
        if (index >= self.units.len) return null;
        return self.units[index];
    }

    pub fn codePointAt(self: String, index: usize) ?u21 {
        const first = self.codeUnitAt(index) orelse return null;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < self.units.len) {
            const second = self.units[index + 1];
            if (second >= 0xdc00 and second <= 0xdfff) {
                return @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            }
        }
        return @intCast(first);
    }

    pub fn at(self: String, allocator: std.mem.Allocator, index: usize) !?String {
        const unit = self.codeUnitAt(index) orelse return null;
        return try fromCodeUnits(allocator, &.{unit});
    }

    pub fn concat(left: String, allocator: std.mem.Allocator, right: String) !String {
        const units = try allocator.alloc(u16, left.units.len + right.units.len);
        @memcpy(units[0..left.units.len], left.units);
        @memcpy(units[left.units.len..], right.units);
        return .{ .allocator = allocator, .units = units };
    }

    pub fn slice(self: String, allocator: std.mem.Allocator, start_value: i64, end_value: ?i64) !String {
        const start = normalizeSliceIndex(start_value, self.units.len);
        const end = normalizeSliceIndex(end_value orelse @intCast(self.units.len), self.units.len);
        if (end <= start) return fromCodeUnits(allocator, &.{});
        return fromCodeUnits(allocator, self.units[start..end]);
    }

    pub fn substring(self: String, allocator: std.mem.Allocator, start_value: i64, end_value: ?i64) !String {
        var start = clampIndex(start_value, self.units.len);
        var end = clampIndex(end_value orelse @intCast(self.units.len), self.units.len);
        if (start > end) std.mem.swap(usize, &start, &end);
        return fromCodeUnits(allocator, self.units[start..end]);
    }

    pub fn indexOf(self: String, needle: String, from_index: usize) ?usize {
        const start = @min(from_index, self.units.len);
        if (needle.units.len == 0) return start;
        if (needle.units.len > self.units.len - start) return null;
        var index = start;
        while (index + needle.units.len <= self.units.len) : (index += 1) {
            if (std.mem.eql(u16, self.units[index .. index + needle.units.len], needle.units)) return index;
        }
        return null;
    }

    /// 孤立サロゲートはU+FFFDへ置換する。JS文字列をUTF-8の標準出力へ書く場合と同じ境界処理に使う。
    pub fn toUtf8Lossy(self: String, allocator: std.mem.Allocator) ![]u8 {
        var output = try allocator.alloc(u8, self.units.len * 3);
        errdefer allocator.free(output);
        var unit_index: usize = 0;
        var output_index: usize = 0;
        while (unit_index < self.units.len) {
            const first = self.units[unit_index];
            var codepoint: u21 = undefined;
            if (first >= 0xd800 and first <= 0xdbff and unit_index + 1 < self.units.len and self.units[unit_index + 1] >= 0xdc00 and self.units[unit_index + 1] <= 0xdfff) {
                const second = self.units[unit_index + 1];
                codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
                unit_index += 2;
            } else {
                codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
                unit_index += 1;
            }
            var encoded: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(codepoint, &encoded);
            @memcpy(output[output_index .. output_index + length], encoded[0..length]);
            output_index += length;
        }
        return allocator.realloc(output, output_index);
    }

    pub fn hash(self: String) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (self.units) |unit| {
            const little = std.mem.nativeToLittle(u16, unit);
            hasher.update(std.mem.asBytes(&little));
        }
        return hasher.final();
    }
};

pub fn isEcmaWhitespace(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

pub fn trimWhitespace(units: []const u16) []const u16 {
    var start: usize = 0;
    while (start < units.len and isEcmaWhitespace(units[start])) start += 1;
    var end = units.len;
    while (end > start and isEcmaWhitespace(units[end - 1])) end -= 1;
    return units[start..end];
}

fn normalizeSliceIndex(value: i64, length: usize) usize {
    if (value < 0) {
        const magnitude = @as(u64, @intCast(-(value + 1))) + 1;
        if (magnitude >= length) return 0;
        return length - @as(usize, @intCast(magnitude));
    }
    return @min(@as(usize, @intCast(value)), length);
}

fn clampIndex(value: i64, length: usize) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), length);
}

test "UTF-16コード単位で長さと添字を扱う" {
    var value = try String.fromUtf8(std.testing.allocator, "A😀B");
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 4), value.len());
    try std.testing.expectEqual(@as(?u16, 0xd83d), value.codeUnitAt(1));
    try std.testing.expectEqual(@as(?u21, 0x1f600), value.codePointAt(1));
    var half = (try value.at(std.testing.allocator, 1)).?;
    defer half.deinit();
    const lossy = try half.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(lossy);
    try std.testing.expectEqualStrings("�", lossy);
}

test "不正UTF-8をNode Bufferの最大部分列規則で置換する" {
    const cases = [_]struct { bytes: []const u8, expected: []const u8 }{
        .{ .bytes = &.{0x80}, .expected = "�" },
        .{ .bytes = &.{ 0xe3, 0x81 }, .expected = "�" },
        .{ .bytes = &.{ 0xe3, 0x81, 0x41 }, .expected = "�A" },
        .{ .bytes = &.{ 0xe0, 0x80, 0x80 }, .expected = "���" },
        .{ .bytes = &.{ 0xf0, 0x9f, 0x92, 0xa9 }, .expected = "💩" },
    };
    for (cases) |case| {
        var value = try String.fromUtf8Lossy(std.testing.allocator, case.bytes);
        defer value.deinit();
        const encoded = try value.toUtf8Lossy(std.testing.allocator);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualStrings(case.expected, encoded);
    }
}

test "sliceとsubstringをJSの添字規則で処理する" {
    var value = try String.fromUtf8(std.testing.allocator, "abcdef");
    defer value.deinit();
    var sliced = try value.slice(std.testing.allocator, -3, -1);
    defer sliced.deinit();
    var substring_value = try value.substring(std.testing.allocator, 4, 1);
    defer substring_value.deinit();
    const sliced_utf8 = try sliced.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(sliced_utf8);
    const substring_utf8 = try substring_value.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(substring_utf8);
    try std.testing.expectEqualStrings("de", sliced_utf8);
    try std.testing.expectEqualStrings("bcd", substring_utf8);
}
