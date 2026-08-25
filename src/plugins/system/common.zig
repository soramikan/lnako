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
    const output = try number_mod.integerToRadixAlloc(runtime.allocator(), number, radix);
    defer runtime.allocator().free(output);
    return runtime.stringUtf8(output);
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
