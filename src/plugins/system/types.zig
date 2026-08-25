const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const value = common.argument(arguments, 0);
    if (isAny(name, &.{ "変数型確認", "TYPEOF" })) return try runtime.stringUtf8(typeOf(value));
    if (isAny(name, &.{ "文字列変換", "TOSTR" })) return try runtime.valueToString(value);
    if (isAny(name, &.{ "整数変換", "TOINT", "INT" })) return .{ .number = try common.parseIntValue(runtime, value, null) };
    if (isAny(name, &.{ "実数変換", "TOFLOAT", "FLOAT" })) return .{ .number = try common.parseFloatValue(runtime, value) };
    if (std.mem.eql(u8, name, "NAN判定")) return .{ .boolean = std.math.isNan(try runtime.valueToNumber(value)) };
    if (std.mem.eql(u8, name, "非数判定")) return .{ .boolean = value == .number and std.math.isNan(value.number) };
    if (std.mem.eql(u8, name, "HEX")) return try radix(runtime, value, .{ .number = 16 });
    if (std.mem.eql(u8, name, "進数変換")) return try radix(runtime, value, common.argument(arguments, 1));
    if (isAny(name, &.{ "二進", "二進表示" })) return try radix(runtime, value, .{ .number = 2 });
    if (std.mem.eql(u8, name, "RGB")) return try rgb(runtime, arguments);
    return null;
}

fn typeOf(value: Value) []const u8 {
    return switch (value) {
        .undefined => "undefined",
        .null_value, .bytes, .array, .dictionary, .promise => "object",
        .boolean => "boolean",
        .number => "number",
        .bigint => "bigint",
        .string => "string",
        .function => "function",
    };
}

fn radix(runtime: *Runtime, value: Value, radix_value: Value) !Value {
    const number = try common.parseIntValue(runtime, value, null);
    const radix_number: f64 = if (radix_value == .undefined) 10 else try runtime.valueToNumber(radix_value);
    if (!std.math.isFinite(radix_number) or @trunc(radix_number) < 2 or @trunc(radix_number) > 36) return error.InvalidRadix;
    return common.integerToRadix(runtime, number, @intFromFloat(@trunc(radix_number)));
}

fn rgb(runtime: *Runtime, arguments: []const Value) !Value {
    var output: [7]u8 = "#000000".*;
    for (0..3) |index| {
        const number = try common.parseIntValue(runtime, common.argument(arguments, index), null);
        const int: i64 = if (std.math.isNan(number) or !std.math.isFinite(number) or number < @as(f64, @floatFromInt(std.math.minInt(i64))) or number > @as(f64, @floatFromInt(std.math.maxInt(i64)))) 0 else @intFromFloat(@trunc(number));
        const low: u8 = @truncate(@as(u64, @bitCast(int)));
        output[1 + index * 2] = hexDigit(low >> 4);
        output[2 + index * 2] = hexDigit(low & 0x0f);
    }
    return runtime.stringUtf8(&output);
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn isAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

test "型名・数値変換・進数変換を公式命令名で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const type_name = (try call(&runtime, "TYPEOF", &.{.{ .number = 1 }})).?;
    const type_utf8 = try type_name.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(type_utf8);
    try std.testing.expectEqualStrings("number", type_utf8);
    try std.testing.expectEqual(@as(f64, 16), (try call(&runtime, "TOINT", &.{try runtime.stringUtf8("16px")})).?.number);
    const binary = (try call(&runtime, "二進", &.{.{ .number = 10 }})).?;
    const binary_utf8 = try binary.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(binary_utf8);
    try std.testing.expectEqualStrings("1010", binary_utf8);
    const decimal = (try call(&runtime, "進数変換", &.{ .{ .number = 31 }, .undefined })).?;
    const decimal_utf8 = try decimal.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(decimal_utf8);
    try std.testing.expectEqualStrings("31", decimal_utf8);
}
