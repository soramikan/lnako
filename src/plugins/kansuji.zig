const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
const BigInt = value_mod.BigInt;

const basic_kanji = [_][]const u8{ "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" };
const axes = [_][]const u8{ "", "十", "百", "千" };
const units = [_][]const u8{
    "",
    "万",
    "億",
    "兆",
    "京",
    "垓",
    "𥝱",
    "穣",
    "溝",
    "澗",
    "正",
    "載",
    "極",
    "恒河沙",
    "阿僧祇",
    "那由他",
    "不可思議",
    "無量大数",
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    if (std.mem.eql(u8, name, "漢数字")) return @as(?Value, try toKanji(runtime, common.argument(arguments, 0)));
    if (std.mem.eql(u8, name, "算用数字")) return @as(?Value, try toArabic(runtime, common.argument(arguments, 0)));
    return null;
}

fn toKanji(runtime: *Runtime, input: Value) !Value {
    const raw = try common.toUtf8Alloc(runtime, input);
    defer runtime.allocator().free(raw);
    const ascii = try fullwidthDigits(runtime.allocator(), raw);
    defer runtime.allocator().free(ascii);
    const expanded = expandDecimal(runtime.allocator(), ascii) catch |err| blk: {
        if (err != error.InvalidKansujiInput or !isJsNumberString(ascii)) return err;
        break :blk try runtime.allocator().dupe(u8, ascii);
    };
    defer runtime.allocator().free(expanded);

    var source = expanded;
    var sign: []const u8 = "";
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        sign = source[0..1];
        source = source[1..];
    }
    const units_utf16 = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator(), source);
    defer runtime.allocator().free(units_utf16);
    const point = std.mem.indexOfScalar(u16, units_utf16, '.') orelse units_utf16.len;
    const integer = units_utf16[0..point];
    const fraction = if (point < units_utf16.len) units_utf16[point + 1 ..] else &.{};
    const magnitude = std.mem.trimStart(u16, integer, &.{@as(u16, '0')});
    if (allAsciiDigitUnits(integer) and allAsciiDigitUnits(fraction) and magnitude.len > 72 and (sign.len == 0 or sign[0] != '-')) return error.KansujiTooLarge;

    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    try output.writer.writeAll(sign);
    var wrote_integer = false;
    if (integer.len > 0) {
        const group_count = (integer.len + 3) / 4;
        var group_index: usize = 0;
        while (group_index < group_count) : (group_index += 1) {
            const start = if (group_index == 0) 0 else integer.len - (group_count - group_index) * 4;
            const end = integer.len - (group_count - group_index - 1) * 4;
            const group = integer[start..end];
            var wrote_group = false;
            for (group, 0..) |digit_unit, digit_index| {
                if (digit_unit == '0') continue;
                const axis_index = group.len - digit_index - 1;
                if (digit_unit != '1' or axis_index == 0) try output.writer.writeAll(kanjiDigit(digit_unit));
                try output.writer.writeAll(axes[axis_index]);
                wrote_group = true;
                wrote_integer = true;
            }
            const large_index = group_count - group_index - 1;
            if (wrote_group and large_index > 0) try output.writer.writeAll(if (large_index < units.len) units[large_index] else "undefined");
        }
    }
    if (!wrote_integer) try output.writer.writeAll("零");
    if (point < units_utf16.len) {
        try output.writer.writeAll("・");
        for (fraction) |digit| try output.writer.writeAll(kanjiDigit(digit));
    }
    return runtime.stringUtf8(output.written());
}

fn toArabic(runtime: *Runtime, input: Value) !Value {
    const source = try common.toUtf8Alloc(runtime, input);
    defer runtime.allocator().free(source);
    var total = try BigInt.init(runtime.allocator(), 0);
    errdefer total.deinit();
    var unit_sum = try BigInt.init(runtime.allocator(), 0);
    defer unit_sum.deinit();
    var base: std.ArrayList(u64) = .empty;
    defer base.deinit(runtime.allocator());
    var fraction: std.ArrayList(u8) = .empty;
    defer fraction.deinit(runtime.allocator());
    var after_point = false;
    var index: usize = 0;
    while (index < source.len) {
        if (std.mem.startsWith(u8, source[index..], "・")) {
            if (after_point) return error.InvalidArabicNumeral;
            try addFinalBase(runtime.allocator(), &unit_sum, &base);
            try addBig(runtime.allocator(), &total, unit_sum);
            unit_sum.deinit();
            unit_sum = try BigInt.init(runtime.allocator(), 0);
            after_point = true;
            index += "・".len;
            continue;
        }
        if (matchAny(source[index..], units[1..])) |matched| {
            if (after_point) {
                var ten = try BigInt.init(runtime.allocator(), 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator(), @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const text = try factor.toString(runtime.allocator(), 10);
                defer runtime.allocator().free(text);
                try fraction.appendSlice(runtime.allocator(), text);
            } else {
                try addDefaultedBase(runtime.allocator(), &unit_sum, &base);
                var ten = try BigInt.init(runtime.allocator(), 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator(), @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const product = try unit_sum.mul(runtime.allocator(), factor);
                unit_sum.deinit();
                unit_sum = product;
                try addBig(runtime.allocator(), &total, unit_sum);
                unit_sum.deinit();
                unit_sum = try BigInt.init(runtime.allocator(), 0);
            }
            index += matched.text.len;
            continue;
        }
        if (matchAny(source[index..], axes[1..])) |matched| {
            const axis_value = std.math.pow(u64, 10, matched.index + 1);
            if (after_point) {
                var buffer: [4]u8 = undefined;
                try fraction.appendSlice(runtime.allocator(), try std.fmt.bufPrint(&buffer, "{d}", .{axis_value}));
            } else {
                if (base.items.len == 0) try base.append(runtime.allocator(), 1);
                try base.append(runtime.allocator(), axis_value);
                try addPair(runtime.allocator(), &unit_sum, base.items);
                base.clearRetainingCapacity();
            }
            index += matched.text.len;
            continue;
        }
        if (matchDigit(source[index..])) |digit| {
            if (after_point) {
                try fraction.append(runtime.allocator(), '0' + digit.value);
            } else try base.append(runtime.allocator(), digit.value);
            index += digit.length;
            continue;
        }
        if (std.mem.startsWith(u8, source[index..], "零")) {
            if (after_point) try fraction.append(runtime.allocator(), '0') else try base.append(runtime.allocator(), 0);
            index += "零".len;
            continue;
        }
        return error.InvalidArabicNumeral;
    }
    if (!after_point) {
        try addFinalBase(runtime.allocator(), &unit_sum, &base);
        try addBig(runtime.allocator(), &total, unit_sum);
    }
    if (after_point) {
        const integer_text = try total.toString(runtime.allocator(), 10);
        defer runtime.allocator().free(integer_text);
        const decimal = try std.fmt.allocPrint(runtime.allocator(), "{s}.{s}", .{ integer_text, fraction.items });
        defer runtime.allocator().free(decimal);
        total.deinit();
        return .{ .number = std.fmt.parseFloat(f64, decimal) catch return error.InvalidArabicNumeral };
    }
    const text = try total.toString(runtime.allocator(), 10);
    defer runtime.allocator().free(text);
    if (text.len < 16 or (text.len == 16 and std.mem.order(u8, text, "9007199254740991") != .gt)) {
        const number = std.fmt.parseFloat(f64, text) catch unreachable;
        total.deinit();
        return .{ .number = number };
    }
    const result = try runtime.bigIntLiteral(text);
    total.deinit();
    return result;
}

const Match = struct { index: usize, text: []const u8 };
fn matchAny(source: []const u8, options: []const []const u8) ?Match {
    var best: ?Match = null;
    for (options, 0..) |option, index| {
        if (!std.mem.startsWith(u8, source, option)) continue;
        if (best == null or option.len > best.?.text.len) best = .{ .index = index, .text = option };
    }
    return best;
}

const DigitMatch = struct { value: u8, length: usize };
fn matchDigit(source: []const u8) ?DigitMatch {
    for (basic_kanji, 0..) |digit, value| if (std.mem.startsWith(u8, source, digit)) return .{ .value = @intCast(value), .length = digit.len };
    return null;
}

fn addDefaultedBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 0) try base.appendSlice(allocator, &.{ 0, 1 }) else if (base.items.len == 1) try base.append(allocator, 1);
    try addPair(allocator, target, base.items);
    base.clearRetainingCapacity();
}

fn addFinalBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 1) {
        try base.append(allocator, 1);
        try addPair(allocator, target, base.items);
    }
    base.clearRetainingCapacity();
}

fn addPair(allocator: std.mem.Allocator, target: *BigInt, pair: []const u64) !void {
    if (pair.len < 2) return;
    var value = try BigInt.init(allocator, pair[0] * pair[1]);
    defer value.deinit();
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

fn addBig(allocator: std.mem.Allocator, target: *BigInt, value: BigInt) !void {
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

fn fullwidthDigits(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(source[index]) catch return error.InvalidKansujiInput;
        const codepoint = std.unicode.utf8Decode(source[index..][0..sequence_length]) catch return error.InvalidKansujiInput;
        if (codepoint >= 0xff10 and codepoint <= 0xff19) {
            try output.append(allocator, @intCast('0' + codepoint - 0xff10));
        } else try output.appendSlice(allocator, source[index .. index + sequence_length]);
        index += sequence_length;
    }
    return output.toOwnedSlice(allocator);
}

fn expandDecimal(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        if (!validDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    }
    const exponent_marker = std.mem.indexOfAny(u8, source, "eE") orelse {
        if (!validDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    };
    const mantissa = source[0..exponent_marker];
    const exponent_text = source[exponent_marker + 1 ..];
    if (!validExponentMantissa(mantissa) or exponent_text.len == 0) return error.InvalidKansujiInput;
    var exponent_digits = exponent_text;
    const negative = exponent_digits[0] == '-';
    if (exponent_digits[0] == '+' or exponent_digits[0] == '-') exponent_digits = exponent_digits[1..];
    if (exponent_digits.len == 0 or !allAsciiDigits(exponent_digits)) return error.InvalidKansujiInput;
    const exponent = std.fmt.parseInt(i64, exponent_digits, 10) catch return error.KansujiTooLarge;
    const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    const moved = if (negative)
        @as(i64, @intCast(point)) - exponent
    else
        @as(i64, @intCast(point)) + exponent;
    if (moved > 1_000_000 or moved < -1_000_000) return error.KansujiTooLarge;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (moved <= 0) {
        try output.appendSlice(allocator, "0.");
        try output.appendNTimes(allocator, '0', @intCast(-moved));
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
    } else if (@as(i64, @intCast(mantissa.len - point)) > moved) {
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
        try output.insert(allocator, @intCast(moved), '.');
    } else if (std.mem.indexOfScalar(u8, mantissa, '.') != null) {
        for (mantissa) |byte| if (byte != '.') try output.append(allocator, byte);
        try output.appendNTimes(allocator, '0', @intCast(moved - @as(i64, @intCast(mantissa.len)) + @as(i64, @intCast(point))));
    } else {
        try output.appendSlice(allocator, mantissa);
        try output.appendNTimes(allocator, '0', @intCast(moved - @as(i64, @intCast(mantissa.len)) + @as(i64, @intCast(point)) - 1));
    }
    return output.toOwnedSlice(allocator);
}

fn validExponentMantissa(source: []const u8) bool {
    if (source.len == 0) return false;
    var index: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    const whole_digits = index;
    if (index == source.len) return whole_digits > 0;
    if (source[index] != '.') return false;
    index += 1;
    const fraction_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    return index == source.len and index > fraction_start;
}

fn validDecimal(source: []const u8) bool {
    if (source.len == 0) return false;
    var index: usize = 0;
    if (source[index] == '+' or source[index] == '-') index += 1;
    var digits: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) digits += 1;
    if (index < source.len and source[index] == '.') {
        index += 1;
        while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) digits += 1;
    }
    return digits > 0 and index == source.len;
}

fn isJsNumberString(source: []const u8) bool {
    const trimmed = trimJsWhitespace(source);
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity") or std.mem.eql(u8, trimmed, "-Infinity")) return true;
    if (validDecimal(trimmed)) return true;
    if (std.mem.indexOfAny(u8, trimmed, "eE")) |marker| {
        if (!validDecimal(trimmed[0..marker])) return false;
        var rest = trimmed[marker + 1 ..];
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
        return rest.len > 0 and allAsciiDigits(rest);
    }
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => return false,
        };
        for (trimmed[2..]) |byte| {
            const digit = std.fmt.charToDigit(byte, radix) catch return false;
            if (digit >= radix) return false;
        }
        return true;
    }
    return false;
}

fn trimJsWhitespace(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[start]) catch break;
        if (start + length > source.len) break;
        const codepoint = std.unicode.utf8Decode(source[start .. start + length]) catch break;
        if (!isJsWhitespace(codepoint)) break;
        start += length;
    }
    var end = source.len;
    while (end > start) {
        var codepoint_start = end - 1;
        while (codepoint_start > start and source[codepoint_start] & 0xc0 == 0x80) codepoint_start -= 1;
        const codepoint = std.unicode.utf8Decode(source[codepoint_start..end]) catch break;
        if (!isJsWhitespace(codepoint)) break;
        end = codepoint_start;
    }
    return source[start..end];
}

fn isJsWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn kanjiDigit(unit: u16) []const u8 {
    return if (unit >= '0' and unit <= '9') basic_kanji[unit - '0'] else "undefined";
}

fn allAsciiDigits(source: []const u8) bool {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn allAsciiDigitUnits(source: []const u16) bool {
    for (source) |unit| if (unit < '0' or unit > '9') return false;
    return true;
}

test "漢数字変換は小数・指数・全角・大きな数を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "10001", .expected = "一万一" },
        .{ .input = "0.01", .expected = "零・〇一" },
        .{ .input = "-12", .expected = "-十二" },
        .{ .input = "1e-3", .expected = "零・〇〇一" },
        .{ .input = "１２３", .expected = "百二十三" },
        .{ .input = ".5", .expected = "零・五" },
        .{ .input = "-.5", .expected = "-零・五" },
        .{ .input = "1.", .expected = "一・" },
        .{ .input = "+0.", .expected = "+零・" },
        .{ .input = "000.50", .expected = "零・五〇" },
        .{ .input = "", .expected = "零" },
        .{ .input = " 1 ", .expected = "undefined百十undefined" },
        .{ .input = "Infinity", .expected = "undefined千undefined百undefined十undefined万undefined千undefined百undefined十undefined" },
        .{ .input = "0x10", .expected = "undefined百十" },
        .{ .input = "10e1", .expected = "千" },
        .{ .input = "01e2", .expected = "千" },
        .{ .input = ".5e1", .expected = "五・" },
        .{ .input = "-1e3", .expected = "-百undefined十三" },
        .{ .input = "　1　", .expected = "undefined百十undefined" },
    };
    for (cases) |case| {
        const result = try toKanji(&runtime, try runtime.stringUtf8(case.input));
        const utf8 = try result.string.toUtf8Lossy(std.testing.allocator);
        defer std.testing.allocator.free(utf8);
        try std.testing.expectEqualStrings(case.expected, utf8);
    }
}

test "算用数字変換は公式の組み合わせ規則とBigInt境界を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(f64, 20_001), (try toArabic(&runtime, try runtime.stringUtf8("二万一"))).number);
    try std.testing.expectEqual(@as(f64, 20_000), (try toArabic(&runtime, try runtime.stringUtf8("一二万"))).number);
    try std.testing.expectEqual(@as(f64, 0), (try toArabic(&runtime, try runtime.stringUtf8("無量大数"))).number);
    try std.testing.expectEqual(@as(f64, 1.2), (try toArabic(&runtime, try runtime.stringUtf8("一・二"))).number);
    const huge = try toArabic(&runtime, try runtime.stringUtf8("一無量大数"));
    try std.testing.expect(huge == .bigint);
    const jo = try toArabic(&runtime, try runtime.stringUtf8("一𥝱"));
    try std.testing.expect(jo == .bigint);
}
