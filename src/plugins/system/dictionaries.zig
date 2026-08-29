const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");
const arrays = @import("arrays.zig");

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
    var rooted_source = source;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&result);
    switch (rooted_source) {
        .dictionary => |dictionary| {
            const order = try dictionaryOrder(runtime, dictionary);
            defer runtime.allocator().free(order);
            for (order) |index| _ = try result.array.push(.{ .string = dictionary.keys()[index] });
        },
        .array => |array| {
            for (0..array.len()) |index| {
                if (!array.isPresent(index)) continue;
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch return error.ArrayTooLarge;
                const key = try runtime.stringUtf8(text);
                _ = try result.array.push(key);
            }
            for (array.properties.items) |property| _ = try result.array.push(.{ .string = property.key });
        },
        .bytes => |bytes| {
            if (bytes.kind == .array_buffer) return result;
            for (0..bytes.bytes.len) |index| {
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
    var rooted_source = source;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&result);
    switch (rooted_source) {
        .dictionary => |dictionary| {
            const order = try dictionaryOrder(runtime, dictionary);
            defer runtime.allocator().free(order);
            for (order) |index| _ = try result.array.push(dictionary.values()[index]);
        },
        .array => |array| {
            for (0..array.len()) |index| {
                if (array.isPresent(index)) _ = try result.array.push(array.get(index));
            }
            for (array.properties.items) |property| _ = try result.array.push(property.value);
        },
        .bytes => |bytes| {
            if (bytes.kind == .array_buffer) return result;
            for (bytes.bytes) |byte| _ = try result.array.push(.{ .number = @floatFromInt(byte) });
        },
        .function => {},
        else => return error.DictionaryValuesReceiver,
    }
    return result;
}

fn remove(runtime: *Runtime, source: Value, key_value: Value) !Value {
    var rooted_source = source;
    var rooted_key_value = key_value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_key_value);

    if (rooted_source == .array) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthDelete;
        if (canonicalArrayIndex(key.string.units)) |index| {
            _ = try rooted_source.array.deleteIndex(index);
        } else _ = rooted_source.array.removeProperty(key.string);
        return rooted_source;
    }
    if (rooted_source == .function) return rooted_source;
    if (rooted_source == .bytes) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (rooted_source.bytes.kind != .array_buffer) if (canonicalArrayIndex(key.string.units)) |index| {
            if (index < rooted_source.bytes.bytes.len) {
                const key_utf8 = try key.string.toUtf8Lossy(runtime.allocator());
                defer runtime.allocator().free(key_utf8);
                const message = try std.fmt.allocPrint(runtime.allocator(), "Cannot delete property '{s}' of [object Uint8Array]", .{key_utf8});
                defer runtime.allocator().free(message);
                try runtime.setFailureMessage(message);
                return error.ByteBufferIndexDelete;
            }
        };
        return rooted_source;
    }
    if (rooted_source != .dictionary) return error.DictionaryRemoveReceiver;
    var key = try runtime.valueToString(rooted_key_value);
    try roots.protect(&key);
    _ = rooted_source.dictionary.remove(key.string);
    return rooted_source;
}

fn has(runtime: *Runtime, source: Value, key_value: Value) !bool {
    var rooted_source = source;
    var rooted_key_value = key_value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_key_value);

    if (rooted_source == .dictionary) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (rooted_source.dictionary.has(key.string)) return true;
        return arrays.hasStandardInheritedProperty(runtime, rooted_source, key.string.units);
    }
    if (rooted_source == .array) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
        if (canonicalArrayIndex(key.string.units)) |index| return rooted_source.array.isPresent(index);
        if (rooted_source.array.hasProperty(key.string)) return true;
        return arrays.hasStandardInheritedProperty(runtime, rooted_source, key.string.units);
    }
    if (rooted_source == .function) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key.string.units, &.{ 'n', 'a', 'm', 'e' })) return true;
        return arrays.hasStandardInheritedProperty(runtime, rooted_source, key.string.units);
    }
    if (rooted_source == .bytes) {
        var key = try runtime.valueToString(rooted_key_value);
        try roots.protect(&key);
        if (rooted_source.bytes.kind != .array_buffer) {
            if (std.mem.eql(u16, key.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
            if (canonicalArrayIndex(key.string.units)) |index| return index < rooted_source.bytes.bytes.len;
        }
        return arrays.hasStandardInheritedProperty(runtime, rooted_source, key.string.units);
    }
    var key = try runtime.valueToString(rooted_key_value);
    try roots.protect(&key);
    var receiver = try runtime.valueToString(rooted_source);
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

test "配列の非index own propertyをキーと内容の列挙・削除へ含める" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var array = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    _ = try array.array.push(.{ .number = 10 });
    var foo = try runtime.stringUtf8("foo");
    try roots.protect(&foo);
    var leading_zero = try runtime.stringUtf8("01");
    try roots.protect(&leading_zero);
    try array.array.setProperty(foo.string, .{ .number = 7 });
    try array.array.setProperty(leading_zero.string, .{ .number = 8 });
    const keys_result = (try call(&runtime, "辞書キー列挙", &.{array})).?;
    try std.testing.expectEqual(@as(usize, 3), keys_result.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 'f', 'o', 'o' }, keys_result.array.get(1).string.units);
    const values_result = (try call(&runtime, "ハッシュ内容列挙", &.{array})).?;
    try std.testing.expectEqual(@as(f64, 7), values_result.array.get(1).number);
    try std.testing.expect((try call(&runtime, "辞書キー存在", &.{ array, foo })).?.boolean);
    _ = (try call(&runtime, "辞書キー削除", &.{ array, foo })).?;
    try std.testing.expect(!(try call(&runtime, "辞書キー存在", &.{ array, foo })).?.boolean);
    try std.testing.expectEqual(@as(usize, 1), array.array.properties.items.len);
}

test "辞書キー存在は標準prototype propertyを含む" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    var array = try runtime.createArray();
    try roots.protect(&array);
    var function_name = try runtime.stringUtf8("利用者関数");
    try roots.protect(&function_name);
    var function = try runtime.createIrFunction(function_name.string, 1, 0, &.{});
    try roots.protect(&function);

    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);
    var constructor_key = try runtime.stringUtf8("constructor");
    try roots.protect(&constructor_key);
    var proto_key = try runtime.stringUtf8("__proto__");
    try roots.protect(&proto_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);
    var prototype_key = try runtime.stringUtf8("prototype");
    try roots.protect(&prototype_key);
    var missing_key = try runtime.stringUtf8("missing");
    try roots.protect(&missing_key);

    const probes = [_]struct { source: Value, key: Value, expected: bool }{
        .{ .source = dictionary, .key = to_string_key, .expected = true },
        .{ .source = dictionary, .key = constructor_key, .expected = true },
        .{ .source = dictionary, .key = proto_key, .expected = true },
        .{ .source = array, .key = map_key, .expected = true },
        .{ .source = array, .key = to_string_key, .expected = true },
        .{ .source = function, .key = to_string_key, .expected = true },
        .{ .source = function, .key = prototype_key, .expected = true },
        .{ .source = dictionary, .key = missing_key, .expected = false },
    };
    for (probes) |probe| {
        const result = (try call(&runtime, "辞書キー存在", &.{ probe.source, probe.key })).?;
        try std.testing.expectEqual(probe.expected, result.boolean);
    }
}

test "辞書キー存在はbyte bufferのown indexとprototype propertyを含む" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 66 });
    try roots.protect(&buffer);
    var uint8 = try runtime.createUint8Array(&.{ 85, 66 });
    try roots.protect(&uint8);
    var array_buffer = try runtime.createArrayBuffer(&.{ 85, 66 });
    try roots.protect(&array_buffer);

    var zero_key = try runtime.stringUtf8("0");
    try roots.protect(&zero_key);
    var length_key = try runtime.stringUtf8("length");
    try roots.protect(&length_key);
    var byte_length_key = try runtime.stringUtf8("byteLength");
    try roots.protect(&byte_length_key);
    var buffer_key = try runtime.stringUtf8("buffer");
    try roots.protect(&buffer_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);
    var max_byte_length_key = try runtime.stringUtf8("maxByteLength");
    try roots.protect(&max_byte_length_key);
    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);
    var missing_key = try runtime.stringUtf8("missing");
    try roots.protect(&missing_key);

    const probes = [_]struct { source: Value, key: Value, expected: bool }{
        .{ .source = buffer, .key = zero_key, .expected = true },
        .{ .source = buffer, .key = length_key, .expected = true },
        .{ .source = buffer, .key = byte_length_key, .expected = true },
        .{ .source = buffer, .key = buffer_key, .expected = true },
        .{ .source = uint8, .key = zero_key, .expected = true },
        .{ .source = uint8, .key = map_key, .expected = true },
        .{ .source = array_buffer, .key = byte_length_key, .expected = true },
        .{ .source = array_buffer, .key = max_byte_length_key, .expected = true },
        .{ .source = array_buffer, .key = to_string_key, .expected = true },
        .{ .source = array_buffer, .key = zero_key, .expected = false },
        .{ .source = array_buffer, .key = length_key, .expected = false },
        .{ .source = array_buffer, .key = buffer_key, .expected = false },
        .{ .source = buffer, .key = missing_key, .expected = false },
    };
    for (probes) |probe| {
        const result = (try call(&runtime, "ハッシュキー存在", &.{ probe.source, probe.key })).?;
        try std.testing.expectEqual(probe.expected, result.boolean);
    }
}

test "辞書キー列挙とハッシュ内容列挙はbyte bufferのown要素を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 66 });
    try roots.protect(&buffer);
    var uint8 = try runtime.createUint8Array(&.{ 85, 66 });
    try roots.protect(&uint8);
    var array_buffer = try runtime.createArrayBuffer(&.{ 85, 66 });
    try roots.protect(&array_buffer);

    var buffer_keys = (try call(&runtime, "辞書キー列挙", &.{buffer})).?;
    try roots.protect(&buffer_keys);
    try std.testing.expectEqual(@as(usize, 2), buffer_keys.array.len());
    try std.testing.expectEqualSlices(u16, &.{'0'}, buffer_keys.array.get(0).string.units);
    try std.testing.expectEqualSlices(u16, &.{'1'}, buffer_keys.array.get(1).string.units);

    var uint8_values = (try call(&runtime, "ハッシュ内容列挙", &.{uint8})).?;
    try roots.protect(&uint8_values);
    try std.testing.expectEqual(@as(usize, 2), uint8_values.array.len());
    try std.testing.expectEqual(@as(f64, 85), uint8_values.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 66), uint8_values.array.get(1).number);

    var array_buffer_keys = (try call(&runtime, "辞書キー列挙", &.{array_buffer})).?;
    try roots.protect(&array_buffer_keys);
    try std.testing.expectEqual(@as(usize, 0), array_buffer_keys.array.len());
    var array_buffer_values = (try call(&runtime, "ハッシュ内容列挙", &.{array_buffer})).?;
    try roots.protect(&array_buffer_values);
    try std.testing.expectEqual(@as(usize, 0), array_buffer_values.array.len());

    var zero_key = try runtime.stringUtf8("0");
    try roots.protect(&zero_key);
    try std.testing.expectError(error.ByteBufferIndexDelete, call(&runtime, "辞書キー削除", &.{ buffer, zero_key }));
    try std.testing.expectEqualStrings("Cannot delete property '0' of [object Uint8Array]", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    try std.testing.expectError(error.ByteBufferIndexDelete, call(&runtime, "ハッシュキー削除", &.{ uint8, zero_key }));
    try std.testing.expectEqualStrings("Cannot delete property '0' of [object Uint8Array]", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    try std.testing.expect((try call(&runtime, "辞書キー存在", &.{ buffer, zero_key })).?.boolean);
    try std.testing.expect((try call(&runtime, "ハッシュキー存在", &.{ uint8, zero_key })).?.boolean);
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
