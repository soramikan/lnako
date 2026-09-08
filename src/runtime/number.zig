const std = @import("std");
const string_mod = @import("string.zig");

pub fn toStringAlloc(allocator: std.mem.Allocator, value: f64) ![]u8 {
    if (std.math.isNan(value)) return allocator.dupe(u8, "NaN");
    if (value == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (value == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    if (value == 0) return allocator.dupe(u8, "0");
    var fixed_output: std.Io.Writer.Allocating = .init(allocator);
    defer fixed_output.deinit();
    try fixed_output.writer.print("{d}", .{value});
    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) return fixedToScientific(allocator, fixed_output.written());
    return allocator.dupe(u8, fixed_output.written());
}

pub fn parseFloatPrefix(allocator: std.mem.Allocator, source: []const u16) !f64 {
    const units = string_mod.trimWhitespace(source);
    if (units.len == 0) return std.math.nan(f64);
    var index: usize = 0;
    if (units[index] == '+' or units[index] == '-') index += 1;
    if (startsWithAscii(units[index..], "Infinity")) return if (units[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    const integer_start = index;
    while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
    var has_digits = index > integer_start;
    if (index < units.len and units[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        has_digits = has_digits or index > fraction_start;
    }
    if (!has_digits) return std.math.nan(f64);
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        const exponent_marker = index;
        index += 1;
        if (index < units.len and (units[index] == '+' or units[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        if (index == exponent_start) index = exponent_marker;
    }
    var ascii = try allocator.alloc(u8, index);
    defer allocator.free(ascii);
    for (units[0..index], 0..) |unit, output_index| ascii[output_index] = @intCast(unit);
    return std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64);
}

/// ECMAScriptのMath.round相当（同位は+∞側）。`floor(value + 0.5)` は中間の
/// 加算で先にbinary64丸めが起きるため、整数部分と小数部分を分けて0.5と
/// 正確に比較する。NaN・±Infinity・±0は保持し、(-0.5, 0]の結果は負のゼロを維持する。
pub fn roundHalfPositive(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const lower = @floor(value);
    const fraction = value - lower;
    const result = if (fraction >= 0.5) lower + 1 else lower;
    if (result == 0) return if (std.math.signbit(value)) -0.0 else 0.0;
    return result;
}

pub fn parseIntPrefix(source: []const u16, radix_value: ?f64) f64 {
    const units = string_mod.trimWhitespace(source);
    if (units.len == 0) return std.math.nan(f64);
    var index: usize = 0;
    var negative = false;
    if (units[index] == '+' or units[index] == '-') {
        negative = units[index] == '-';
        index += 1;
    }
    var radix: u8 = 0;
    if (radix_value) |specified| {
        if (std.math.isFinite(specified)) {
            const integer = @trunc(specified);
            if (integer != 0) {
                if (integer < 2 or integer > 36) return std.math.nan(f64);
                radix = @intFromFloat(integer);
            }
        }
    }
    if ((radix == 0 or radix == 16) and index + 1 < units.len and units[index] == '0' and (units[index + 1] == 'x' or units[index + 1] == 'X')) {
        radix = 16;
        index += 2;
    }
    if (radix == 0) radix = 10;
    // 桁をf64で逐次蓄積すると各stepでbinary64丸めが起き、公式の一度だけの
    // 丸めと一致しない。u1024で正確に蓄積し、最後にnearest/ties-to-evenで
    // 一度だけ丸める。u1024はbinary64の有限範囲全体を覆う。
    var magnitude: u1024 = 0;
    var overflowed = false;
    var digits: usize = 0;
    while (index < units.len) : (index += 1) {
        const digit = digitValue(units[index]) orelse break;
        if (digit >= radix) break;
        if (!overflowed) {
            if (magnitude > (std.math.maxInt(u1024) - @as(u1024, digit)) / radix) {
                overflowed = true;
            } else {
                magnitude = magnitude * radix + digit;
            }
        }
        digits += 1;
    }
    if (digits == 0) return std.math.nan(f64);
    const result: f64 = if (overflowed) std.math.inf(f64) else integerMagnitudeToF64(magnitude);
    return if (negative) -result else result;
}

/// 正確な整数の絶対値をbinary64のnearest/ties-to-evenで一度だけ丸める。
/// `@floatFromInt(u1024)` はこのLLVM環境で未対応のため、上位53bitへの
/// 切出し＋half/sticky判定＋2のべき乗算で組み立てる。
fn integerMagnitudeToF64(magnitude: u1024) f64 {
    if (magnitude == 0) return 0;
    const bit_count = 1024 - @clz(magnitude);
    if (bit_count <= 53) return @floatFromInt(@as(u64, @truncate(magnitude)));
    var shift: u10 = @intCast(bit_count - 53);
    var top: u64 = @truncate(magnitude >> shift);
    const remainder = magnitude & ((@as(u1024, 1) << shift) - 1);
    const half = @as(u1024, 1) << @as(u10, @intCast(shift - 1));
    if (remainder > half or (remainder == half and (top & 1) == 1)) {
        top += 1;
        if (top == (@as(u64, 1) << 53)) {
            top >>= 1;
            shift += 1;
        }
    }
    const mantissa: f64 = @floatFromInt(top);
    return mantissa * std.math.pow(f64, 2, @floatFromInt(shift));
}

pub fn integerToRadixAlloc(allocator: std.mem.Allocator, number: f64, radix: u8) ![]u8 {
    if (radix < 2 or radix > 36) return error.InvalidRadix;
    if (std.math.isNan(number)) return allocator.dupe(u8, "NaN");
    if (number == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (number == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    var magnitude = @abs(@trunc(number));
    var reversed: [1200]u8 = undefined;
    var count: usize = 0;
    if (magnitude == 0) {
        reversed[0] = '0';
        count = 1;
    } else while (magnitude >= 1 and count < reversed.len) {
        const quotient = @floor(magnitude / @as(f64, @floatFromInt(radix)));
        const remainder: u8 = @intFromFloat(magnitude - quotient * @as(f64, @floatFromInt(radix)));
        reversed[count] = if (remainder < 10) '0' + remainder else 'a' + (remainder - 10);
        count += 1;
        magnitude = quotient;
    }
    const sign_length: usize = @intFromBool(number < 0);
    const output = try allocator.alloc(u8, sign_length + count);
    if (number < 0) output[0] = '-';
    for (0..count) |index| output[sign_length + index] = reversed[count - index - 1];
    return output;
}

pub fn rgbAlloc(allocator: std.mem.Allocator, components: [3]f64) ![]u8 {
    const output = try allocator.dupe(u8, "#000000");
    errdefer allocator.free(output);
    for (components, 0..) |component, index| {
        const text = try integerToRadixAlloc(allocator, component, 16);
        defer allocator.free(text);
        if (text.len >= 2) {
            output[1 + index * 2] = text[text.len - 2];
            output[2 + index * 2] = text[text.len - 1];
        } else {
            output[2 + index * 2] = text[0];
        }
    }
    return output;
}

fn startsWithAscii(units: []const u16, ascii: []const u8) bool {
    if (units.len < ascii.len) return false;
    for (ascii, 0..) |byte, index| if (units[index] != byte) return false;
    return true;
}

fn digitValue(unit: u16) ?u8 {
    if (unit >= '0' and unit <= '9') return @intCast(unit - '0');
    if (unit >= 'a' and unit <= 'z') return @intCast(unit - 'a' + 10);
    if (unit >= 'A' and unit <= 'Z') return @intCast(unit - 'A' + 10);
    return null;
}

fn fixedToScientific(allocator: std.mem.Allocator, fixed: []const u8) ![]u8 {
    const negative = fixed.len > 0 and fixed[0] == '-';
    const digits_start: usize = @intFromBool(negative);
    const dot = std.mem.indexOfScalarPos(u8, fixed, digits_start, '.') orelse fixed.len;
    var first_nonzero = digits_start;
    while (first_nonzero < fixed.len and (fixed[first_nonzero] == '0' or fixed[first_nonzero] == '.')) first_nonzero += 1;
    if (first_nonzero == fixed.len) return allocator.dupe(u8, "0");
    const exponent: i64 = if (dot < first_nonzero)
        -@as(i64, @intCast(first_nonzero - dot))
    else
        @as(i64, @intCast(dot - first_nonzero - 1));
    var significant = try allocator.alloc(u8, fixed.len - first_nonzero);
    defer allocator.free(significant);
    var length: usize = 0;
    for (fixed[first_nonzero..]) |character| if (character != '.') {
        significant[length] = character;
        length += 1;
    };
    while (length > 1 and significant[length - 1] == '0') length -= 1;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (negative) try output.writer.writeByte('-');
    try output.writer.writeByte(significant[0]);
    if (length > 1) {
        try output.writer.writeByte('.');
        try output.writer.writeAll(significant[1..length]);
    }
    try output.writer.writeByte('e');
    if (exponent >= 0) try output.writer.writeByte('+');
    try output.writer.print("{d}", .{exponent});
    return output.toOwnedSlice();
}

test "binary64をJavaScript互換の最短文字列へ変換する" {
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = -0.0, .expected = "0" },
        .{ .value = std.math.pi, .expected = "3.141592653589793" },
        .{ .value = 0.000001, .expected = "0.000001" },
        .{ .value = 0.0000001, .expected = "1e-7" },
        .{ .value = 1e20, .expected = "100000000000000000000" },
        .{ .value = 1e21, .expected = "1e+21" },
    };
    for (cases) |case| {
        const actual = try toStringAlloc(std.testing.allocator, case.value);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "parseIntとparseFloatのJavaScript接頭辞規則を再現する" {
    try std.testing.expectEqual(@as(f64, 12.5), try parseFloatPrefix(std.testing.allocator, &.{ ' ', '1', '2', '.', '5', 'x' }));
    try std.testing.expectEqual(@as(f64, -16), parseIntPrefix(&.{ ' ', '-', '0', 'x', '1', '0', 'r' }, null));
    try std.testing.expect(std.math.isNan(parseIntPrefix(&.{ 'x', 'y', 'z' }, null)));
}

test "整数を2進数から36進数の小文字表現へ変換する" {
    const binary = try integerToRadixAlloc(std.testing.allocator, -10.9, 2);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqualStrings("-1010", binary);
    const hexadecimal = try integerToRadixAlloc(std.testing.allocator, 255, 16);
    defer std.testing.allocator.free(hexadecimal);
    try std.testing.expectEqualStrings("ff", hexadecimal);
    const base36 = try integerToRadixAlloc(std.testing.allocator, 35, 36);
    defer std.testing.allocator.free(base36);
    try std.testing.expectEqualStrings("z", base36);
    try std.testing.expectError(error.InvalidRadix, integerToRadixAlloc(std.testing.allocator, 1, 1));
}

test "RGBは各parseInt結果の16進表現から末尾2文字を取る" {
    const edge = try rgbAlloc(std.testing.allocator, .{ -1, std.math.nan(f64), std.math.nan(f64) });
    defer std.testing.allocator.free(edge);
    try std.testing.expectEqualStrings("#-1aNaN", edge);
    const wrapped = try rgbAlloc(std.testing.allocator, .{ 256, 257, 15 });
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("#00010f", wrapped);
}

fn testUnits(comptime text: []const u8) [text.len]u16 {
    var units: [text.len]u16 = undefined;
    for (text, 0..) |character, index| units[index] = character;
    return units;
}

test "roundHalfPositiveはbinary64の中間丸めを避け境界を保つ" {
    // 0.5直前の最大有限値は切り捨て側のまま（floor(value+0.5)では1になる）。
    try std.testing.expectEqual(@as(f64, 0), roundHalfPositive(0.49999999999999994));
    try std.testing.expectEqual(@as(f64, 0), roundHalfPositive(-0.49999999999999994));
    // 0.5以降と同位は+∞側へ。
    try std.testing.expectEqual(@as(f64, 1), roundHalfPositive(0.5));
    try std.testing.expectEqual(@as(f64, 2), roundHalfPositive(1.5));
    try std.testing.expectEqual(@as(f64, 3), roundHalfPositive(2.5));
    try std.testing.expectEqual(@as(f64, -1), roundHalfPositive(-0.6));
    try std.testing.expectEqual(@as(f64, -1), roundHalfPositive(-1.5));
    try std.testing.expectEqual(@as(f64, -2), roundHalfPositive(-2.5));
    // (-0.5, 0)と負のsubnormalは負のゼロを維持する。
    try std.testing.expect(std.math.signbit(roundHalfPositive(-0.4)));
    try std.testing.expect(std.math.signbit(roundHalfPositive(-0.5)));
    try std.testing.expect(std.math.signbit(roundHalfPositive(-5e-324)));
    try std.testing.expect(!std.math.signbit(roundHalfPositive(0.4)));
    try std.testing.expect(!std.math.signbit(roundHalfPositive(0)));
    try std.testing.expect(std.math.signbit(roundHalfPositive(-0.0)));
    // 安全整数範囲内の正確な整数は変更しない（floor(value+0.5)では+1される）。
    try std.testing.expectEqual(@as(f64, 4503599627370497), roundHalfPositive(4503599627370497));
    try std.testing.expectEqual(@as(f64, -4503599627370497), roundHalfPositive(-4503599627370497));
    try std.testing.expectEqual(@as(f64, 4503599627370496), roundHalfPositive(4503599627370495.5));
    // subnormal・最大有限値・非有限を保持する。
    try std.testing.expectEqual(@as(f64, 0), roundHalfPositive(5e-324));
    try std.testing.expectEqual(@as(f64, 1.7976931348623157e308), roundHalfPositive(1.7976931348623157e308));
    try std.testing.expectEqual(std.math.inf(f64), roundHalfPositive(std.math.inf(f64)));
    try std.testing.expectEqual(-std.math.inf(f64), roundHalfPositive(-std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(roundHalfPositive(std.math.nan(f64))));
}

test "parseIntPrefixは整数文字列を一度だけbinary64へ丸める" {
    const expect_bits = struct {
        fn call(expected: u64, source: []const u16, radix: ?f64) !void {
            try std.testing.expectEqual(expected, @as(u64, @bitCast(parseIntPrefix(source, radix))));
        }
    }.call;
    // f64逐次蓄積では0x43a9000000000000になるが、一度だけ丸めると0x...01。
    try expect_bits(0x43a9000000000001, &testUnits("900719925474099267"), null);
    try expect_bits(0xc3a9000000000001, &testUnits("-900719925474099267"), null);
    // 2^53直前・tieの偶数側。
    try expect_bits(0x4340000000000000, &testUnits("9007199254740993"), null);
    try expect_bits(0x4340000000000002, &testUnits("9007199254740995"), null);
    // 16進・36進の長い文字列。
    try expect_bits(0x43b234567890abce, &testUnits("0x1234567890abcdef"), null);
    try expect_bits(0x466517168a4523fd, &testUnits("zzzzzzzzzzzzzzzzzzzz"), 36);
    // 有限最大値の境界と、超過時のInfinity。
    try expect_bits(0x7fefffffffffffff, &testUnits("17976931348623157" ++ "0" ** 292), null);
    try expect_bits(0x7ff0000000000000, &testUnits("2" ++ "0" ** 308), null);
    try expect_bits(0x7ff0000000000000, &testUnits("f" ** 400), 16);
    // 任意長の先頭ゼロ・末尾無効文字・負のゼロを維持する。
    try expect_bits(0x43a9000000000001, &testUnits("0000000000900719925474099267tail"), null);
    try expect_bits(0x8000000000000000, &testUnits("  -0abc"), null);
    try std.testing.expect(std.math.isNan(parseIntPrefix(&testUnits("xyz"), null)));
}
