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
    var result: f64 = 0;
    var digits: usize = 0;
    while (index < units.len) : (index += 1) {
        const digit = digitValue(units[index]) orelse break;
        if (digit >= radix) break;
        result = result * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
        digits += 1;
    }
    if (digits == 0) return std.math.nan(f64);
    return if (negative) -result else result;
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
