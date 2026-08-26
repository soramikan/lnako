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
            const order = try dictionaryOrder(runtime, dictionary);
            defer runtime.allocator().free(order);
            for (order) |index| _ = try result.array.push(.{ .string = dictionary.keys()[index] });
        },
        .array => |array| {
            for (0..array.len()) |index| {
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch return error.ArrayTooLarge;
                const key = try runtime.stringUtf8(text);
                _ = try result.array.push(key);
            }
        },
        .function => {},
        else => return error.DictionaryKeysReceiver,
    }
    return result;
}

fn values(runtime: *Runtime, source: Value) !Value {
    if (source == .function) return try runtime.createArray();
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    switch (source) {
        .dictionary => |dictionary| {
            const order = try dictionaryOrder(runtime, dictionary);
            defer runtime.allocator().free(order);
            for (order) |index| _ = try result.array.push(dictionary.values()[index]);
        },
        .array => |array| {
            for (0..array.len()) |index| _ = try result.array.push(array.get(index));
        },
        else => return error.DictionaryValuesReceiver,
    }
    return result;
}

fn remove(runtime: *Runtime, source: Value, key_value: Value) !Value {
    if (source == .array) {
        const key = try runtime.valueToString(key_value);
        if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthDelete;
        const index = canonicalArrayIndex(key.string.units) orelse return source;
        if (index < source.array.len()) source.array.items.items[index] = .undefined;
        return source;
    }
    if (source == .function) return source;
    if (source != .dictionary) return error.DictionaryRemoveReceiver;
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
        const key = try runtime.valueToString(key_value);
        if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
        const index = canonicalArrayIndex(key.string.units) orelse return false;
        return index < source.array.len();
    }
    if (source == .function) {
        const key = try runtime.valueToString(key_value);
        return std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key.string.units, &.{ 'n', 'a', 'm', 'e' });
    }
    var key = try runtime.valueToString(key_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&key);
    var receiver = try runtime.valueToString(source);
    try roots.protect(&receiver);
    const key_utf8 = try key.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(key_utf8);
    const receiver_utf8 = try receiver.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(receiver_utf8);
    const message = try std.fmt.allocPrint(runtime.allocator(), "Cannot use 'in' operator to search for '{s}' in {s}", .{ key_utf8, receiver_utf8 });
    defer runtime.allocator().free(message);
    try runtime.setFailureMessage(message);
    return error.DictionaryHasReceiver;
}

fn canonicalArrayIndex(units: []const u16) ?usize {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var index: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        index = std.math.mul(usize, index, 10) catch return null;
        index = std.math.add(usize, index, unit - '0') catch return null;
    }
    return if (index <= 4_294_967_294) index else null;
}

fn dictionaryKeyIndex(key: *value_mod.String) ?usize {
    return canonicalArrayIndex(key.units);
}

fn dictionaryOrder(runtime: *Runtime, dictionary: *value_mod.Dictionary) ![]usize {
    const order = try runtime.allocator().alloc(usize, dictionary.len());
    for (order, 0..) |*entry, index| entry.* = index;
    // ECMAScript own-key order: canonical array indexes ascending, followed
    // by the remaining string keys in insertion order.  The comparator uses
    // an insertion index tie-break so pdq sort preserves that latter order.
    std.sort.pdq(usize, order, dictionary, dictionaryOrderBefore);
    return order;
}

fn dictionaryOrderBefore(dictionary: *value_mod.Dictionary, left_index: usize, right_index: usize) bool {
    const left = dictionaryKeyIndex(dictionary.keys()[left_index]);
    const right = dictionaryKeyIndex(dictionary.keys()[right_index]);
    return if (left) |left_number| if (right) |right_number| left_number < right_number else true else if (right != null) false else left_index < right_index;
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

test "辞書・配列のプロパティ順と型変換を公式規則で扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var dictionary = try runtime.createDictionary();
    var array = try runtime.createArray();
    var bigint_key = try runtime.bigIntLiteral("1n");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try roots.protect(&array);
    try roots.protect(&bigint_key);
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "b", .{ .number = 1 });
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "2", .{ .number = 2 });
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "1", .{ .number = 3 });
    const listed = (try call(&runtime, "辞書キー列挙", &.{dictionary})).?;
    try std.testing.expectEqualSlices(u16, &.{'1'}, listed.array.get(0).string.units);
    try std.testing.expectEqualSlices(u16, &.{'2'}, listed.array.get(1).string.units);
    try std.testing.expectEqualSlices(u16, &.{'b'}, listed.array.get(2).string.units);
    _ = try array.array.push(.{ .number = 10 });
    _ = try array.array.push(.{ .number = 20 });
    const array_keys = (try call(&runtime, "辞書キー列挙", &.{array})).?;
    try std.testing.expectEqualSlices(u16, &.{'0'}, array_keys.array.get(0).string.units);
    try std.testing.expectEqualSlices(u16, &.{'1'}, array_keys.array.get(1).string.units);
    try std.testing.expect((try call(&runtime, "辞書キー存在", &.{ array, try runtime.stringUtf8("length") })).?.boolean);
    try std.testing.expect((try call(&runtime, "辞書キー存在", &.{ array, bigint_key })).?.boolean);
    try std.testing.expectError(error.ArrayLengthDelete, call(&runtime, "辞書キー削除", &.{ array, try runtime.stringUtf8("length") }));
    try std.testing.expectError(error.DictionaryKeysReceiver, call(&runtime, "辞書キー列挙", &.{numberValueForTest(3)}));
    try std.testing.expectError(error.DictionaryHasReceiver, call(&runtime, "辞書キー存在", &.{ .null_value, try runtime.stringUtf8("x") }));
    try std.testing.expectEqualStrings("Cannot use 'in' operator to search for 'x' in null", runtime.failureMessage().?);
}

fn dictionaryHasErrorAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    _ = call(&runtime, "辞書キー存在", &.{ .null_value, .{ .boolean = true } }) catch |failure| switch (failure) {
        error.DictionaryHasReceiver => {
            try std.testing.expectEqualStrings("Cannot use 'in' operator to search for 'true' in null", runtime.failureMessage().?);
            return;
        },
        else => return failure,
    };
    return error.ExpectedDictionaryHasReceiver;
}

test "辞書キー存在の動的エラー文生成はGCストレスでも変換済みキーを保持する" {
    try dictionaryHasErrorAllocationTest(std.testing.allocator);
}

test "辞書キー存在の動的エラー文生成は割当失敗を安全に処理する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dictionaryHasErrorAllocationTest, .{});
}

fn numberValueForTest(value: f64) Value {
    return .{ .number = value };
}
