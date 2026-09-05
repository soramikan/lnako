const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const string_mod = shared.string_mod;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const BigInt = aot_state.BigInt;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const staticStringValue = aot_state.staticStringValue;
const isString = aot_state.isString;

const kansujiBasicKanji = [_][]const u8{ "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" };
const kansujiAxes = [_][]const u8{ "", "十", "百", "千" };
const kansujiUnits = [_][]const u8{
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

pub fn kansujiBuiltin(runtime: *Runtime, command: aot_builtin.Command, input: Value) !Value {
    return switch (command) {
        .kansuji_to_kanji => kansujiToKanjiBuiltin(runtime, input),
        .kansuji_to_arabic => kansujiToArabicBuiltin(runtime, input),
        else => error.UnknownCommand,
    };
}

pub fn kansujiInputUtf8(runtime: *Runtime, input: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, input);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn kansujiToKanjiBuiltin(runtime: *Runtime, input: Value) !Value {
    const raw = try kansujiInputUtf8(runtime, input);
    defer runtime.allocator.free(raw);
    const ascii = try kansujiFullwidthDigits(runtime.allocator, raw);
    defer runtime.allocator.free(ascii);
    const expanded = kansujiExpandDecimal(runtime.allocator, ascii) catch |failure| blk: {
        if (failure != error.InvalidKansujiInput or !kansujiIsJsNumberString(ascii)) return failure;
        break :blk try runtime.allocator.dupe(u8, ascii);
    };
    defer runtime.allocator.free(expanded);

    var source = expanded;
    var sign: []const u8 = "";
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        sign = source[0..1];
        source = source[1..];
    }
    const units_utf16 = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, source);
    defer runtime.allocator.free(units_utf16);
    const point = std.mem.indexOfScalar(u16, units_utf16, '.') orelse units_utf16.len;
    const integer = units_utf16[0..point];
    const fraction = if (point < units_utf16.len) units_utf16[point + 1 ..] else &.{};
    const magnitude = std.mem.trimStart(u16, integer, &.{@as(u16, '0')});
    if (kansujiAllAsciiDigitUnits(integer) and kansujiAllAsciiDigitUnits(fraction) and magnitude.len > 72 and
        (sign.len == 0 or sign[0] != '-')) return error.KansujiTooLarge;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, sign);
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
                if (digit_unit != '1' or axis_index == 0) try output.appendSlice(runtime.allocator, kansujiKanjiDigit(digit_unit));
                try output.appendSlice(runtime.allocator, kansujiAxes[axis_index]);
                wrote_group = true;
                wrote_integer = true;
            }
            const large_index = group_count - group_index - 1;
            if (wrote_group and large_index > 0) {
                try output.appendSlice(runtime.allocator, if (large_index < kansujiUnits.len) kansujiUnits[large_index] else "undefined");
            }
        }
    }
    if (!wrote_integer) try output.appendSlice(runtime.allocator, "零");
    if (point < units_utf16.len) {
        try output.appendSlice(runtime.allocator, "・");
        for (fraction) |digit| try output.appendSlice(runtime.allocator, kansujiKanjiDigit(digit));
    }
    return runtimeUtf8String(runtime, output.items);
}

pub fn kansujiToArabicBuiltin(runtime: *Runtime, input: Value) !Value {
    const source = try kansujiInputUtf8(runtime, input);
    defer runtime.allocator.free(source);
    var total = try BigInt.init(runtime.allocator, 0);
    errdefer total.deinit();
    var unit_sum = try BigInt.init(runtime.allocator, 0);
    defer unit_sum.deinit();
    var base: std.ArrayList(u64) = .empty;
    defer base.deinit(runtime.allocator);
    var fraction: std.ArrayList(u8) = .empty;
    defer fraction.deinit(runtime.allocator);
    var after_point = false;
    var index: usize = 0;
    while (index < source.len) {
        if (std.mem.startsWith(u8, source[index..], "・")) {
            if (after_point) return error.InvalidArabicNumeral;
            try kansujiAddFinalBase(runtime.allocator, &unit_sum, &base);
            try kansujiAddBig(runtime.allocator, &total, unit_sum);
            unit_sum.deinit();
            unit_sum = try BigInt.init(runtime.allocator, 0);
            after_point = true;
            index += "・".len;
            continue;
        }
        if (kansujiMatchAny(source[index..], kansujiUnits[1..])) |matched| {
            if (after_point) {
                var ten = try BigInt.init(runtime.allocator, 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator, @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const text = try factor.toString(runtime.allocator, 10);
                defer runtime.allocator.free(text);
                try fraction.appendSlice(runtime.allocator, text);
            } else {
                try kansujiAddDefaultedBase(runtime.allocator, &unit_sum, &base);
                var ten = try BigInt.init(runtime.allocator, 10);
                defer ten.deinit();
                var factor = try ten.pow(runtime.allocator, @intCast(4 * (matched.index + 1)));
                defer factor.deinit();
                const product = try unit_sum.mul(runtime.allocator, factor);
                unit_sum.deinit();
                unit_sum = product;
                try kansujiAddBig(runtime.allocator, &total, unit_sum);
                unit_sum.deinit();
                unit_sum = try BigInt.init(runtime.allocator, 0);
            }
            index += matched.text.len;
            continue;
        }
        if (kansujiMatchAny(source[index..], kansujiAxes[1..])) |matched| {
            const axis_value = std.math.pow(u64, 10, matched.index + 1);
            if (after_point) {
                var buffer: [4]u8 = undefined;
                try fraction.appendSlice(runtime.allocator, try std.fmt.bufPrint(&buffer, "{d}", .{axis_value}));
            } else {
                if (base.items.len == 0) try base.append(runtime.allocator, 1);
                try base.append(runtime.allocator, axis_value);
                try kansujiAddPair(runtime.allocator, &unit_sum, base.items);
                base.clearRetainingCapacity();
            }
            index += matched.text.len;
            continue;
        }
        if (kansujiMatchDigit(source[index..])) |digit| {
            if (after_point) {
                try fraction.append(runtime.allocator, '0' + digit.value);
            } else try base.append(runtime.allocator, digit.value);
            index += digit.length;
            continue;
        }
        if (std.mem.startsWith(u8, source[index..], "零")) {
            if (after_point) try fraction.append(runtime.allocator, '0') else try base.append(runtime.allocator, 0);
            index += "零".len;
            continue;
        }
        return error.InvalidArabicNumeral;
    }
    if (!after_point) {
        try kansujiAddFinalBase(runtime.allocator, &unit_sum, &base);
        try kansujiAddBig(runtime.allocator, &total, unit_sum);
    }
    if (after_point) {
        const integer_text = try total.toString(runtime.allocator, 10);
        defer runtime.allocator.free(integer_text);
        const decimal = try std.fmt.allocPrint(runtime.allocator, "{s}.{s}", .{ integer_text, fraction.items });
        defer runtime.allocator.free(decimal);
        const number = std.fmt.parseFloat(f64, decimal) catch return error.InvalidArabicNumeral;
        total.deinit();
        return numberValue(number);
    }
    const text = try total.toString(runtime.allocator, 10);
    defer runtime.allocator.free(text);
    if (text.len < 16 or (text.len == 16 and std.mem.order(u8, text, "9007199254740991") != .gt)) {
        const number = std.fmt.parseFloat(f64, text) catch unreachable;
        total.deinit();
        return numberValue(number);
    }
    const result = try runtime.createBigInt(text);
    total.deinit();
    return result;
}

const KansujiMatch = struct { index: usize, text: []const u8 };

pub fn kansujiMatchAny(source: []const u8, options: []const []const u8) ?KansujiMatch {
    var best: ?KansujiMatch = null;
    for (options, 0..) |option, index| {
        if (!std.mem.startsWith(u8, source, option)) continue;
        if (best == null or option.len > best.?.text.len) best = .{ .index = index, .text = option };
    }
    return best;
}

const KansujiDigitMatch = struct { value: u8, length: usize };

pub fn kansujiMatchDigit(source: []const u8) ?KansujiDigitMatch {
    for (kansujiBasicKanji, 0..) |digit, value| if (std.mem.startsWith(u8, source, digit)) {
        return .{ .value = @intCast(value), .length = digit.len };
    };
    return null;
}

pub fn kansujiAddDefaultedBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 0) try base.appendSlice(allocator, &.{ 0, 1 }) else if (base.items.len == 1) try base.append(allocator, 1);
    try kansujiAddPair(allocator, target, base.items);
    base.clearRetainingCapacity();
}

pub fn kansujiAddFinalBase(allocator: std.mem.Allocator, target: *BigInt, base: *std.ArrayList(u64)) !void {
    if (base.items.len == 1) {
        try base.append(allocator, 1);
        try kansujiAddPair(allocator, target, base.items);
    }
    base.clearRetainingCapacity();
}

pub fn kansujiAddPair(allocator: std.mem.Allocator, target: *BigInt, pair: []const u64) !void {
    if (pair.len < 2) return;
    var value = try BigInt.init(allocator, pair[0] * pair[1]);
    defer value.deinit();
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

pub fn kansujiAddBig(allocator: std.mem.Allocator, target: *BigInt, value: BigInt) !void {
    const sum = try target.add(allocator, value);
    target.deinit();
    target.* = sum;
}

pub fn kansujiFullwidthDigits(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
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

pub fn kansujiExpandDecimal(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len > 0 and (source[0] == '+' or source[0] == '-')) {
        if (!kansujiValidDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    }
    const exponent_marker = std.mem.indexOfAny(u8, source, "eE") orelse {
        if (!kansujiValidDecimal(source)) return error.InvalidKansujiInput;
        return allocator.dupe(u8, source);
    };
    const mantissa = source[0..exponent_marker];
    const exponent_text = source[exponent_marker + 1 ..];
    if (!kansujiValidExponentMantissa(mantissa) or exponent_text.len == 0) return error.InvalidKansujiInput;
    var exponent_digits = exponent_text;
    const negative = exponent_digits[0] == '-';
    if (exponent_digits[0] == '+' or exponent_digits[0] == '-') exponent_digits = exponent_digits[1..];
    if (exponent_digits.len == 0 or !kansujiAllAsciiDigits(exponent_digits)) return error.InvalidKansujiInput;
    const exponent = std.fmt.parseInt(i64, exponent_digits, 10) catch return error.KansujiTooLarge;
    const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    const moved = if (negative) @as(i64, @intCast(point)) - exponent else @as(i64, @intCast(point)) + exponent;
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

pub fn kansujiValidExponentMantissa(source: []const u8) bool {
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

pub fn kansujiValidDecimal(source: []const u8) bool {
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

pub fn kansujiIsJsNumberString(source: []const u8) bool {
    const trimmed = kansujiTrimJsWhitespace(source);
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity") or std.mem.eql(u8, trimmed, "-Infinity")) return true;
    if (kansujiValidDecimal(trimmed)) return true;
    if (std.mem.indexOfAny(u8, trimmed, "eE")) |marker| {
        if (!kansujiValidDecimal(trimmed[0..marker])) return false;
        var rest = trimmed[marker + 1 ..];
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
        return rest.len > 0 and kansujiAllAsciiDigits(rest);
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

pub fn kansujiTrimJsWhitespace(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[start]) catch break;
        if (start + length > source.len) break;
        const codepoint = std.unicode.utf8Decode(source[start .. start + length]) catch break;
        if (!kansujiIsJsWhitespace(codepoint)) break;
        start += length;
    }
    var end = source.len;
    while (end > start) {
        var codepoint_start = end - 1;
        while (codepoint_start > start and source[codepoint_start] & 0xc0 == 0x80) codepoint_start -= 1;
        const codepoint = std.unicode.utf8Decode(source[codepoint_start..end]) catch break;
        if (!kansujiIsJsWhitespace(codepoint)) break;
        end = codepoint_start;
    }
    return source[start..end];
}

pub fn kansujiIsJsWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

pub fn kansujiKanjiDigit(unit: u16) []const u8 {
    return if (unit >= '0' and unit <= '9') kansujiBasicKanji[unit - '0'] else "undefined";
}

pub fn kansujiAllAsciiDigits(source: []const u8) bool {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn kansujiAllAsciiDigitUnits(source: []const u16) bool {
    for (source) |unit| if (unit < '0' or unit > '9') return false;
    return true;
}
