const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const string_mod = @import("../../runtime/string.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn argument(arguments: []const Value, index: usize) Value {
    return if (index < arguments.len) arguments[index] else .undefined;
}

pub fn toString(runtime: *Runtime, value: Value) !Value {
    return runtime.valueToString(value);
}

pub fn toUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    const text = try runtime.valueToString(value);
    return text.string.toUtf8Lossy(runtime.allocator());
}

pub fn parseFloatValue(runtime: *Runtime, value: Value) !f64 {
    if (value == .number) return value.number;
    if (value == .bigint) return value.bigint.toF64();
    const text_value = try runtime.valueToString(value);
    const units = trimEcma(text_value.string.units);
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
    var ascii = try runtime.allocator().alloc(u8, index);
    defer runtime.allocator().free(ascii);
    for (units[0..index], 0..) |unit, output_index| ascii[output_index] = @intCast(unit);
    return std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64);
}

pub fn parseIntValue(runtime: *Runtime, value: Value, radix_value: ?Value) !f64 {
    const text_value = try runtime.valueToString(value);
    const units = trimEcma(text_value.string.units);
    if (units.len == 0) return std.math.nan(f64);
    var index: usize = 0;
    var negative = false;
    if (units[index] == '+' or units[index] == '-') {
        negative = units[index] == '-';
        index += 1;
    }
    var radix: u8 = 0;
    if (radix_value) |specified| {
        const number = try runtime.valueToNumber(specified);
        if (std.math.isFinite(number)) {
            const integer = @trunc(number);
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

pub fn integerToRadix(runtime: *Runtime, number: f64, radix: u8) !Value {
    if (radix < 2 or radix > 36) return error.InvalidRadix;
    if (std.math.isNan(number)) return runtime.stringUtf8("NaN");
    if (number == std.math.inf(f64)) return runtime.stringUtf8("Infinity");
    if (number == -std.math.inf(f64)) return runtime.stringUtf8("-Infinity");
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
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    if (number < 0) try output.writer.writeByte('-');
    var index = count;
    while (index > 0) {
        index -= 1;
        try output.writer.writeByte(reversed[index]);
    }
    return runtime.stringUtf8(output.written());
}

pub fn arrayFromValues(runtime: *Runtime, values: []const Value) !Value {
    var array = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    for (values) |value| _ = try array.array.push(value);
    return array;
}

pub fn stringFromUnits(runtime: *Runtime, units: []const u16) !Value {
    return runtime.stringCodeUnits(units);
}

pub fn dictionarySetUtf8(runtime: *Runtime, dictionary: *value_mod.Dictionary, key: []const u8, value: Value) !void {
    var value_root = value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value_root);
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    try dictionary.set(key_value.string, value_root);
}

pub fn trimEcma(units: []const u16) []const u16 {
    return string_mod.trimWhitespace(units);
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

test "parseFloatとparseIntのJavaScript接頭辞規則を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(f64, 12.5), try parseFloatValue(&runtime, try runtime.stringUtf8("  12.5xyz")));
    try std.testing.expectEqual(@as(f64, -16), try parseIntValue(&runtime, try runtime.stringUtf8(" -0x10rest"), null));
    try std.testing.expect(std.math.isNan(try parseIntValue(&runtime, try runtime.stringUtf8("xyz"), null)));
}
