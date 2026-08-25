const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const string_mod = @import("../../runtime/string.zig");
const number_mod = @import("../../runtime/number.zig");

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
    return number_mod.parseFloatPrefix(runtime.allocator(), text_value.string.units);
}

pub fn parseIntValue(runtime: *Runtime, value: Value, radix_value: ?Value) !f64 {
    const text_value = try runtime.valueToString(value);
    var radix: ?f64 = null;
    if (radix_value) |specified| {
        radix = try runtime.valueToNumber(specified);
    }
    return number_mod.parseIntPrefix(text_value.string.units, radix);
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

test "parseFloatとparseIntのJavaScript接頭辞規則を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(f64, 12.5), try parseFloatValue(&runtime, try runtime.stringUtf8("  12.5xyz")));
    try std.testing.expectEqual(@as(f64, -16), try parseIntValue(&runtime, try runtime.stringUtf8(" -0x10rest"), null));
    try std.testing.expect(std.math.isNan(try parseIntValue(&runtime, try runtime.stringUtf8("xyz"), null)));
}
