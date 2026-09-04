const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const ByteKind = value_mod.ByteKind;

const prototype_mod = @import("prototype.zig");
const byteBufferAllowsStandardPrototype = prototype_mod.byteBufferAllowsStandardPrototype;
const byteBufferSlice = prototype_mod.byteBufferSlice;
const tableInheritedProperty = prototype_mod.tableInheritedProperty;

pub const safe_array_element_limit: usize = 1_000_000;

pub const Context = struct {
    context: *anyopaque,
    randomFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,
    callFn: ?*const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value = null,
    resolveFn: ?*const fn (context: *anyopaque, name: []const u8) anyerror!Value = null,

    pub fn random(self: ?Context) !f64 {
        const actual = self orelse return error.RandomSourceUnavailable;
        const function = actual.randomFn orelse return error.RandomSourceUnavailable;
        const result = try function(actual.context);
        if (!std.math.isFinite(result) or result < 0 or result >= 1) return error.InvalidRandomValue;
        return result;
    }

    pub fn invoke(self: ?Context, callable: Value, arguments: []const Value) !Value {
        const actual = self orelse return error.CallbackExecutionUnavailable;
        const function = actual.callFn orelse return error.CallbackExecutionUnavailable;
        return function(actual.context, callable, arguments);
    }

    pub fn resolve(self: ?Context, runtime: *Runtime, value: Value) !Value {
        if (value == .function) return value;
        if (value != .string) return error.NotCallable;
        const actual = self orelse return error.CallbackExecutionUnavailable;
        const function = actual.resolveFn orelse return error.CallbackExecutionUnavailable;
        const name = try value.string.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(name);
        return function(actual.context, name);
    }
};

pub fn testElementCountFunction(_: *Runtime, _: []const Value) !Value {
    return .undefined;
}

pub fn appendArraySlot(array: *value_mod.Array, value: Value, present: bool) !void {
    const length = try array.push(value);
    if (!present) _ = try array.deleteIndex(length - 1);
}

pub fn bigIntPropertyIndex(value: *value_mod.BigInt, length: usize) ?usize {
    const integer = value.toI64() catch return null;
    if (integer < 0) return null;
    const index = std.math.cast(usize, integer) orelse return null;
    return if (index < length) index else null;
}

test "表行propertyはown値を優先して標準prototypeを解決する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    var array = try runtime.createArray();
    try roots.protect(&array);
    var text = try runtime.stringUtf8("x");
    try roots.protect(&text);
    var function_name = try runtime.stringUtf8("利用者関数");
    try roots.protect(&function_name);
    var function = try runtime.createIrFunction(function_name.string, 1, 0, &.{});
    try roots.protect(&function);

    var constructor_key = try runtime.stringUtf8("constructor");
    try roots.protect(&constructor_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);
    var upper_key = try runtime.stringUtf8("toUpperCase");
    try roots.protect(&upper_key);
    var prototype_key = try runtime.stringUtf8("prototype");
    try roots.protect(&prototype_key);
    var proto_key = try runtime.stringUtf8("__proto__");
    try roots.protect(&proto_key);
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);
    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);

    try dictionary.dictionary.set(to_string_key.string, .{ .number = 7 });
    var own_value = try indexed(&runtime, dictionary, to_string_key);
    try roots.protect(&own_value);
    try std.testing.expectEqual(@as(f64, 7), own_value.number);

    var dictionary_constructor = try indexed(&runtime, dictionary, constructor_key);
    try roots.protect(&dictionary_constructor);
    var dictionary_constructor_name = try indexed(&runtime, dictionary_constructor, name_key);
    try roots.protect(&dictionary_constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'O', 'b', 'j', 'e', 'c', 't' }, dictionary_constructor_name.string.units);

    var array_method = try indexed(&runtime, array, map_key);
    try roots.protect(&array_method);
    var array_method_name = try indexed(&runtime, array_method, name_key);
    try roots.protect(&array_method_name);
    try std.testing.expectEqualSlices(u16, &.{ 'm', 'a', 'p' }, array_method_name.string.units);
    var array_proto = try indexed(&runtime, array, proto_key);
    try roots.protect(&array_proto);
    try std.testing.expect(array_proto == .array);

    var string_method = try indexed(&runtime, text, upper_key);
    try roots.protect(&string_method);
    var string_method_name = try indexed(&runtime, string_method, name_key);
    try roots.protect(&string_method_name);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'o', 'U', 'p', 'p', 'e', 'r', 'C', 'a', 's', 'e' }, string_method_name.string.units);

    var function_proto = try indexed(&runtime, function, prototype_key);
    try roots.protect(&function_proto);
    try std.testing.expect(function_proto == .dictionary);
    var function_proto_again = try indexed(&runtime, function, prototype_key);
    try roots.protect(&function_proto_again);
    try std.testing.expect(Value.strictEqual(function_proto, function_proto_again));
    var function_constructor = try indexed(&runtime, function_proto, constructor_key);
    try roots.protect(&function_constructor);
    try std.testing.expect(Value.strictEqual(function, function_constructor));

    var number_constructor = try indexed(&runtime, .{ .number = 1 }, constructor_key);
    try roots.protect(&number_constructor);
    var number_constructor_name = try indexed(&runtime, number_constructor, name_key);
    try roots.protect(&number_constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'N', 'u', 'm', 'b', 'e', 'r' }, number_constructor_name.string.units);
}

pub fn arrayPropertyGet(array: *value_mod.Array, key: *value_mod.String, index: ?usize) Value {
    if (index) |position| return array.get(position);
    if (std.mem.eql(u16, key.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(array.len()) };
    return array.getProperty(key) orelse .undefined;
}

pub fn arrayPropertySet(array: *value_mod.Array, key: *value_mod.String, index: ?usize, value: Value) !void {
    if (index) |position| return array.set(position, value);
    if (std.mem.eql(u16, key.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    return array.setProperty(key, value);
}

pub fn indexed(runtime: *Runtime, source: Value, key: Value) !Value {
    var rooted = [3]Value{ source, key, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    if (rooted[0] == .null_value or rooted[0] == .undefined) {
        try setTableRowPropertyFailure(runtime, rooted[0], rooted[1]);
        return error.TableRowMissing;
    }
    rooted[2] = try runtime.valueToString(rooted[1]);
    if (rooted[0] == .array) {
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].array.len()) };
        const index = propertyIndexUnits(rooted[2].string.units);
        if (index == null) if (rooted[0].array.getProperty(rooted[2].string)) |value| return value;
        if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return arrayPropertyGet(rooted[0].array, rooted[2].string, index);
    }
    if (rooted[0] == .dictionary) {
        if (rooted[0].dictionary.get(rooted[2].string)) |value| return value;
        if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (rooted[0] == .string) {
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].string.len()) };
        const index = propertyIndexUnits(rooted[2].string.units) orelse {
            if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
            return .undefined;
        };
        if (index >= rooted[0].string.len()) return .undefined;
        return try runtime.stringCodeUnits(&.{rooted[0].string.units[index]});
    }
    if (rooted[0] == .bytes) {
        const allows_standard_prototype = byteBufferAllowsStandardPrototype(rooted[0].bytes);
        if (propertyIndexUnits(rooted[2].string.units) == null) {
            if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
        }
        if (allows_standard_prototype and rooted[0].bytes.kind != .array_buffer and std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].bytes.bytes.len) };
        if (rooted[0].bytes.kind != .array_buffer) if (propertyIndexUnits(rooted[2].string.units)) |index| return rooted[0].bytes.get(index);
        if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (rooted[0] == .function) {
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = 0 };
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'n', 'a', 'm', 'e' })) {
            // An anonymous Nadesiko function is lowered to an internal
            // __lambda$ name, but JavaScript Function.name remains empty.
            const lambda_marker = [_]u16{ '_', '_', 'l', 'a', 'm', 'b', 'd', 'a', '$' };
            const name = if (std.mem.indexOf(u16, rooted[0].function.name.units, &lambda_marker) != null) &.{} else rooted[0].function.name.units;
            return runtime.stringCodeUnits(name);
        }
    }
    if (try tableInheritedProperty(runtime, rooted[0], rooted[2].string.units)) |value| return value;
    return .undefined;
}

pub fn setTableRowPropertyFailure(runtime: *Runtime, row: Value, column: Value) !void {
    var rooted = [3]Value{ row, column, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.valueToString(rooted[1]);
    const column_utf8 = try rooted[2].string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(column_utf8);
    const receiver = if (rooted[0] == .null_value) "null" else "undefined";
    const message = try std.fmt.allocPrint(runtime.allocator(), "Cannot read properties of {s} (reading '{s}')", .{ receiver, column_utf8 });
    defer runtime.allocator().free(message);
    try runtime.setFailureMessage(message);
}

pub fn propertyIndexUnits(units: []const u16) ?usize {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, unit - '0') catch return null;
    }
    // ECMAScript array-index property names are in [0, 2^32 - 2].  2^32 - 1
    // is the non-index length sentinel and must not address a dense array.
    const max_array_index: usize = @as(usize, std.math.maxInt(u32)) - 1;
    if (result > max_array_index) return null;
    return result;
}

pub const Range = struct { start: usize, count: usize };

pub fn rangeBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
    if (value == .null_value) return error.ArrayCutNullIndex;
    if (value != .dictionary) return null;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    const first_value = value.dictionary.get(first_key.string) orelse return null;
    const last_value = value.dictionary.get(last_key.string) orelse .undefined;
    if (first_value != .number) return null;
    const first = spliceIndex(first_value.number, length);
    const last_number = try runtime.valueToExplicitRangeNumber(last_value);
    const end = spliceIndex(last_number + 1, length);
    if (end <= first) return .{ .start = first, .count = 0 };
    return .{ .start = first, .count = end - first };
}

pub fn spliceRangeBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
    if (value == .null_value) return error.ArrayCutNullIndex;
    if (value != .dictionary) return null;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    const first_value = value.dictionary.get(first_key.string) orelse return null;
    if (first_value != .number) return null;
    const last_value = value.dictionary.get(last_key.string) orelse .undefined;
    const start = spliceIndex(first_value.number, length);
    const count_number = try runtime.valueToNumber(last_value) - first_value.number + 1;
    return .{ .start = start, .count = positiveLength(count_number, length - start) };
}

pub fn substringBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
    if (value == .null_value) return error.ArrayCutNullIndex;
    if (value != .dictionary) return null;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    const first_value = value.dictionary.get(first_key.string) orelse return null;
    const last_value = value.dictionary.get(last_key.string) orelse .undefined;
    if (first_value != .number) return null;
    const first_number = first_value.number;
    const last_number = try runtime.valueToExplicitRangeNumber(last_value) + 1;
    const normalize = struct {
        fn apply(number: f64, size: usize) usize {
            if (std.math.isNan(number) or number <= 0 or number == -std.math.inf(f64)) return 0;
            if (number == std.math.inf(f64)) return size;
            if (number >= @as(f64, @floatFromInt(size))) return size;
            return @intFromFloat(@trunc(number));
        }
    }.apply;
    var start = normalize(first_number, length);
    var end = normalize(last_number, length);
    if (start > end) std.mem.swap(usize, &start, &end);
    return .{ .start = start, .count = end - start };
}

pub fn spliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number)) return 0;
    if (number == std.math.inf(f64)) return length;
    if (number == -std.math.inf(f64)) return 0;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

pub fn directIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn propertyIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn charAtIndex(number: f64, length: usize) ?usize {
    if (std.math.isNan(number) or number == 0) return if (length > 0) 0 else null;
    if (!std.math.isFinite(number)) return null;
    const integer = @trunc(number);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(length))) return null;
    return @intFromFloat(integer);
}

pub fn positiveLength(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

pub fn fillLength(number: f64, maximum: usize) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(maximum))) return error.ArrayFillSizeLimit;
    return @intFromFloat(@floor(number));
}

pub fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

pub fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

pub fn appendAsciiUnits(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

pub fn appendUtf8Units(output: *std.ArrayList(u16), allocator: std.mem.Allocator, text: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try output.appendSlice(allocator, units);
}

test "表行propertyはbyte bufferのprototype属性を解決する" {
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
    var constructor_key = try runtime.stringUtf8("constructor");
    try roots.protect(&constructor_key);
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);
    var byte_length_key = try runtime.stringUtf8("byteLength");
    try roots.protect(&byte_length_key);
    var byte_offset_key = try runtime.stringUtf8("byteOffset");
    try roots.protect(&byte_offset_key);
    var bytes_per_element_key = try runtime.stringUtf8("BYTES_PER_ELEMENT");
    try roots.protect(&bytes_per_element_key);
    var buffer_key = try runtime.stringUtf8("buffer");
    try roots.protect(&buffer_key);
    var slice_key = try runtime.stringUtf8("slice");
    try roots.protect(&slice_key);
    var subarray_key = try runtime.stringUtf8("subarray");
    try roots.protect(&subarray_key);
    var locale_key = try runtime.stringUtf8("toLocaleString");
    try roots.protect(&locale_key);
    var max_byte_length_key = try runtime.stringUtf8("maxByteLength");
    try roots.protect(&max_byte_length_key);
    var resizable_key = try runtime.stringUtf8("resizable");
    try roots.protect(&resizable_key);
    var detached_key = try runtime.stringUtf8("detached");
    try roots.protect(&detached_key);

    var constructor = try indexed(&runtime, buffer, constructor_key);
    try roots.protect(&constructor);
    var constructor_name = try indexed(&runtime, constructor, name_key);
    try roots.protect(&constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'B', 'u', 'f', 'f', 'e', 'r' }, constructor_name.string.units);
    try std.testing.expectEqual(@as(f64, 2), (try indexed(&runtime, buffer, byte_length_key)).number);
    try std.testing.expectEqual(@as(f64, 0), (try indexed(&runtime, buffer, byte_offset_key)).number);
    try std.testing.expectEqual(@as(f64, 1), (try indexed(&runtime, buffer, bytes_per_element_key)).number);
    var buffer_backing = try indexed(&runtime, buffer, buffer_key);
    try roots.protect(&buffer_backing);
    try std.testing.expect(buffer_backing == .bytes);
    try std.testing.expectEqual(ByteKind.array_buffer, buffer_backing.bytes.kind);
    try std.testing.expectEqual(@as(usize, 2), buffer_backing.bytes.bytes.len);
    try std.testing.expectEqual(@as(f64, 2), (try indexed(&runtime, buffer_backing, byte_length_key)).number);
    var same_buffer_backing = try indexed(&runtime, buffer, buffer_key);
    try roots.protect(&same_buffer_backing);
    try std.testing.expect(same_buffer_backing.bytes == buffer_backing.bytes);
    var buffer_view = try runtime.createByteBufferView(buffer.bytes, 0, buffer.bytes.bytes.len);
    try roots.protect(&buffer_view);
    var view_backing = try indexed(&runtime, buffer_view, buffer_key);
    try roots.protect(&view_backing);
    try std.testing.expect(view_backing.bytes == buffer_backing.bytes);
    buffer_view.bytes.set(0, 9);
    try std.testing.expectEqual(@as(f64, 9), buffer.bytes.get(0).number);
    buffer.bytes.set(0, 8);
    try std.testing.expectEqual(@as(f64, 8), buffer_view.bytes.get(0).number);
    var slice = try indexed(&runtime, buffer, slice_key);
    try roots.protect(&slice);
    var slice_name = try indexed(&runtime, slice, name_key);
    try roots.protect(&slice_name);
    try std.testing.expectEqualSlices(u16, &.{ 's', 'l', 'i', 'c', 'e' }, slice_name.string.units);
    var locale = try indexed(&runtime, buffer, locale_key);
    try roots.protect(&locale);
    var locale_name = try indexed(&runtime, locale, name_key);
    try roots.protect(&locale_name);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' }, locale_name.string.units);

    constructor = try indexed(&runtime, uint8, constructor_key);
    try roots.protect(&constructor);
    constructor_name = try indexed(&runtime, constructor, name_key);
    try roots.protect(&constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'U', 'i', 'n', 't', '8', 'A', 'r', 'r', 'a', 'y' }, constructor_name.string.units);
    try std.testing.expectEqual(@as(f64, 2), (try indexed(&runtime, uint8, byte_length_key)).number);
    try std.testing.expectEqual(@as(f64, 1), (try indexed(&runtime, uint8, bytes_per_element_key)).number);
    var uint8_backing = try indexed(&runtime, uint8, buffer_key);
    try roots.protect(&uint8_backing);
    try std.testing.expect(uint8_backing == .bytes);
    try std.testing.expectEqual(ByteKind.array_buffer, uint8_backing.bytes.kind);
    try std.testing.expectEqual(@as(usize, 2), uint8_backing.bytes.bytes.len);
    var same_uint8_backing = try indexed(&runtime, uint8, buffer_key);
    try roots.protect(&same_uint8_backing);
    try std.testing.expect(same_uint8_backing.bytes == uint8_backing.bytes);
    var subarray = try indexed(&runtime, uint8, subarray_key);
    try roots.protect(&subarray);
    var subarray_name = try indexed(&runtime, subarray, name_key);
    try roots.protect(&subarray_name);
    try std.testing.expectEqualSlices(u16, &.{ 's', 'u', 'b', 'a', 'r', 'r', 'a', 'y' }, subarray_name.string.units);

    constructor = try indexed(&runtime, array_buffer, constructor_key);
    try roots.protect(&constructor);
    constructor_name = try indexed(&runtime, constructor, name_key);
    try roots.protect(&constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'r', 'r', 'a', 'y', 'B', 'u', 'f', 'f', 'e', 'r' }, constructor_name.string.units);
    try std.testing.expectEqual(@as(f64, 2), (try indexed(&runtime, array_buffer, byte_length_key)).number);
    try std.testing.expectEqual(@as(f64, 2), (try indexed(&runtime, array_buffer, max_byte_length_key)).number);
    try std.testing.expect(!(try indexed(&runtime, array_buffer, resizable_key)).boolean);
    try std.testing.expect(!(try indexed(&runtime, array_buffer, detached_key)).boolean);
    try std.testing.expect((try indexed(&runtime, array_buffer, bytes_per_element_key)) == .undefined);
    try std.testing.expect((try indexed(&runtime, array_buffer, buffer_key)) == .undefined);
}

test "byte bufferから抽出したslice関数は未束縛エラーを再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 1, 2, 3, 4 });
    try roots.protect(&buffer);
    var slice_key = try runtime.stringUtf8("slice");
    try roots.protect(&slice_key);
    var buffer_slice_function = try indexed(&runtime, buffer, slice_key);
    try roots.protect(&buffer_slice_function);
    try std.testing.expectError(error.NotCallable, runtime.call(buffer_slice_function, &.{ .{ .number = 0 }, .{ .number = 2 } }));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'subarray')", runtime.failureMessage().?);
}

test "Bufferの空viewもbacking storageからのbyteOffsetを保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 1, 2, 3, 4 });
    try roots.protect(&buffer);
    var view = try byteBufferSlice(&runtime, buffer.bytes, 1, 3);
    try roots.protect(&view);
    var empty = try byteBufferSlice(&runtime, view.bytes, 2, 2);
    try roots.protect(&empty);

    var byte_length = try runtime.stringUtf8("byteLength");
    try roots.protect(&byte_length);
    var byte_offset = try runtime.stringUtf8("byteOffset");
    try roots.protect(&byte_offset);
    var offset = try runtime.stringUtf8("offset");
    try roots.protect(&offset);
    try std.testing.expectEqual(@as(f64, 0), (try indexed(&runtime, empty, byte_length)).number);
    try std.testing.expectEqual(@as(f64, 3), (try indexed(&runtime, empty, byte_offset)).number);
    try std.testing.expectEqual(@as(f64, 3), (try indexed(&runtime, empty, offset)).number);
}
