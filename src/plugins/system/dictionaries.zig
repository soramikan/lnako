const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const source = common.argument(arguments, 0);
    const key_value = common.argument(arguments, 1);
    if (isAny(name, &.{ "辞書キー列挙", "ハッシュキー列挙" })) return try keys(runtime, source);
    if (eql(name, "ハッシュ内容列挙")) return try values(runtime, source);
    if (isAny(name, &.{ "辞書キー削除", "ハッシュキー削除" })) return try remove(runtime, source, key_value);
    if (isAny(name, &.{ "辞書キー存在", "ハッシュキー存在" })) return .{ .boolean = try has(runtime, source, key_value) };
    return null;
}

fn keys(runtime: *Runtime, source: Value) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    switch (source) {
        .dictionary => |dictionary| {
            for (dictionary.keys()) |key| _ = try result.array.push(.{ .string = key });
        },
        .array => |array| {
            for (0..array.len()) |index| _ = try result.array.push(.{ .number = @floatFromInt(index) });
        },
        else => return error.DictionaryOrArrayExpected,
    }
    return result;
}

fn values(runtime: *Runtime, source: Value) !Value {
    if (source != .dictionary) return error.DictionaryExpected;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.dictionary.values()) |value| _ = try result.array.push(value);
    return result;
}

fn remove(runtime: *Runtime, source: Value, key_value: Value) !Value {
    if (source != .dictionary) return error.DictionaryExpected;
    const key = try runtime.valueToString(key_value);
    _ = source.dictionary.remove(key.string);
    return source;
}

fn has(runtime: *Runtime, source: Value, key_value: Value) !bool {
    if (source == .dictionary) {
        const key = try runtime.valueToString(key_value);
        return source.dictionary.has(key.string);
    }
    if (source == .array) {
        const number = try runtime.valueToNumber(key_value);
        return std.math.isFinite(number) and number >= 0 and @trunc(number) == number and number < @as(f64, @floatFromInt(source.array.len()));
    }
    return error.DictionaryOrArrayExpected;
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "辞書の挿入順キーと値を列挙しキーを削除する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "b", .{ .number = 2 });
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "a", .{ .number = 1 });
    const listed = (try call(&runtime, "辞書キー列挙", &.{dictionary})).?;
    try std.testing.expectEqual(@as(usize, 2), listed.array.len());
    _ = (try call(&runtime, "辞書キー削除", &.{ dictionary, try runtime.stringUtf8("b") })).?;
    try std.testing.expectEqual(@as(usize, 1), dictionary.dictionary.len());
}
