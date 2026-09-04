const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const shared = @import("shared.zig");
const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const ByteKind = shared.ByteKind;

const common = @import("../common.zig");
const json = @import("../json.zig");
const operators = @import("../../../runtime/operators.zig");
const prototype_mod = @import("prototype.zig");
const Range = shared.Range;
const appendArraySlot = shared.appendArraySlot;
const appendAsciiUnits = shared.appendAsciiUnits;
const appendUtf8Units = shared.appendUtf8Units;
const arrayPropertyGet = shared.arrayPropertyGet;
const arrayPropertySet = shared.arrayPropertySet;
const charAtIndex = shared.charAtIndex;
const fillLength = shared.fillLength;
const indexed = shared.indexed;
const positiveLength = shared.positiveLength;
const propertyIndex = shared.propertyIndex;
const propertyIndexUnits = shared.propertyIndexUnits;
const rangeBounds = shared.rangeBounds;
const safe_array_element_limit = shared.safe_array_element_limit;
const spliceIndex = shared.spliceIndex;
const spliceRangeBounds = shared.spliceRangeBounds;
const substringBounds = shared.substringBounds;
const tableInheritedProperty = prototype_mod.tableInheritedProperty;
const testElementCountFunction = shared.testElementCountFunction;

pub fn join(runtime: *Runtime, source: Value, separator: Value) !Value {
    var separator_text = try runtime.valueToString(separator);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&separator_text);
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    if (source == .array) {
        for (source.array.items.items, 0..) |item, index| {
            if (index > 0) try output.appendSlice(runtime.allocator(), separator_text.string.units);
            if (item == .undefined or item == .null_value) continue;
            const text = try runtime.valueToString(item);
            try output.appendSlice(runtime.allocator(), text.string.units);
        }
    } else {
        const text = try runtime.valueToString(source);
        var start: usize = 0;
        var first = true;
        for (text.string.units, 0..) |unit, index| if (unit == '\n') {
            if (!first) try output.appendSlice(runtime.allocator(), separator_text.string.units);
            try output.appendSlice(runtime.allocator(), text.string.units[start..index]);
            start = index + 1;
            first = false;
        };
        if (!first) try output.appendSlice(runtime.allocator(), separator_text.string.units);
        try output.appendSlice(runtime.allocator(), text.string.units[start..]);
    }
    return runtime.stringCodeUnits(output.items);
}

pub fn arraySearch(source: Value, needle: Value) i64 {
    if (source != .array) return -1;
    for (source.array.items.items, 0..) |item, index| {
        if (!source.array.isPresent(index)) continue;
        if (Value.strictEqual(item, needle)) return @intCast(index);
    }
    return -1;
}

pub fn elementCount(value: Value) usize {
    return switch (value) {
        .bytes => |bytes| bytes.bytes.len,
        .array => |array| array.len(),
        .dictionary => |dictionary| dictionary.len(),
        .string => |string| string.len(),
        .function, .promise => 0,
        else => 1,
    };
}

pub fn insertOne(runtime: *Runtime, source: Value, index_value: Value, item: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.insert(spliceIndex(try runtime.valueToNumber(index_value), source.array.len()), item);
    return runtime.createArray();
}

pub fn insertMany(runtime: *Runtime, source: Value, index_value: Value, items: Value) !Value {
    if (source != .array or items != .array) return error.ArrayExpected;
    var source_root = source;
    var index_root = index_value;
    var items_root = items;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    try roots.protect(&index_root);
    try roots.protect(&items_root);
    const copy = try runtime.allocator().dupe(Value, items.array.items.items);
    defer runtime.allocator().free(copy);
    for (copy, 0..) |item, offset| {
        // The official implementation evaluates i + j on every iteration,
        // so a string index concatenates ("1" + 0 -> "10") while a numeric
        // index is added arithmetically.  Keep that coercion before splice.
        const offset_value = try operators.binary(runtime, .add, index_root, .{ .number = @floatFromInt(offset) });
        const index = spliceIndex(try runtime.valueToNumber(offset_value), source_root.array.len());
        try source_root.array.insert(index, item);
    }
    return source_root;
}

pub fn numericConvert(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var source_root = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    try source_root.array.normalizePresence();
    for (source_root.array.items.items, 0..) |*item, index| {
        const original = item.*;
        const number = try common.parseFloatValue(runtime, original);
        item.* = .{ .number = number };
        // The upstream implementation assigns through every indexed
        // position.  Unlike sort/reverse, conversion therefore fills holes
        // with the parsed value of undefined (NaN).
        source_root.array.presence.items[index] = true;
    }
    return source_root;
}

pub fn reverse(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.normalizePresence();
    std.mem.reverse(Value, source.array.items.items);
    std.mem.reverse(bool, source.array.presence.items);
    return source;
}

pub fn cut(runtime: *Runtime, source: Value, index_value: Value) !Value {
    if (source == .array) {
        if (index_value == .number) return source.array.remove(spliceIndex(index_value.number, source.array.len()));
        if (try spliceRangeBounds(runtime, index_value, source.array.len())) |range| return spliceArray(runtime, source.array, range.start, range.count);
        return .null_value;
    }
    if (source == .dictionary and index_value == .string) {
        var roots = runtime.rootFrame();
        defer roots.deinit();
        var rooted_source = source;
        var rooted_index = index_value;
        try roots.protect(&rooted_source);
        try roots.protect(&rooted_index);
        var own = false;
        const old = if (rooted_source.dictionary.get(rooted_index.string)) |value| blk: {
            own = true;
            break :blk value;
        } else (try tableInheritedProperty(runtime, rooted_source, rooted_index.string.units)) orelse return .undefined;
        if (!old.toBoolean()) return .undefined;
        if (own) _ = rooted_source.dictionary.remove(rooted_index.string);
        return old;
    }
    return error.ArrayExpected;
}

pub fn take(runtime: *Runtime, source: Value, index_value: Value, count_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    const start = spliceIndex(try runtime.valueToNumber(index_value), source.array.len());
    const count = positiveLength(try runtime.valueToNumber(count_value), source.array.len() - start);
    return spliceArray(runtime, source.array, start, count);
}

pub fn spliceArray(runtime: *Runtime, array: *value_mod.Array, start: usize, count: usize) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const actual = @min(count, array.len() - @min(start, array.len()));
    try array.normalizePresence();
    for (0..actual) |_| {
        const was_present = array.isPresent(start);
        const value = array.remove(start);
        const result_length = try result.array.push(value);
        if (!was_present) _ = try result.array.deleteIndex(result_length - 1);
    }
    return result;
}

pub fn pop(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    return source.array.pop();
}

pub fn push(source: Value, value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    _ = try source.array.push(value);
    return source;
}

pub fn deepClone(runtime: *Runtime, source: Value) !Value {
    var encoded = (try json.call(runtime, "JSON変換", &.{source})).?;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&encoded);
    return (try json.call(runtime, "JSON取得", &.{encoded})).?;
}

pub fn cloneValue(runtime: *Runtime, source: Value, arrays: *std.ArrayList(*value_mod.Array), dictionaries: *std.ArrayList(*value_mod.Dictionary)) !Value {
    return switch (source) {
        .array => |array| blk: {
            for (arrays.items) |active| if (active == array) return error.CircularCloneValue;
            try arrays.append(runtime.allocator(), array);
            defer _ = arrays.pop();
            var result = try runtime.createArray();
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            for (array.items.items) |item| _ = try result.array.push(try cloneValue(runtime, item, arrays, dictionaries));
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            for (dictionaries.items) |active| if (active == dictionary) return error.CircularCloneValue;
            try dictionaries.append(runtime.allocator(), dictionary);
            defer _ = dictionaries.pop();
            var result = try runtime.createDictionary();
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            for (dictionary.keys(), dictionary.values()) |key, value| try result.dictionary.set(key, try cloneValue(runtime, value, arrays, dictionaries));
            break :blk result;
        },
        .undefined => .undefined,
        .function => .undefined,
        else => source,
    };
}

pub fn rangeCopy(runtime: *Runtime, source: Value, index_value: Value) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var rooted_source = source;
    var rooted_index = index_value;
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_index);
    if (rooted_source != .array) return error.ArrayExpected;
    if (rooted_index == .number) {
        const index = propertyIndex(rooted_index.number) orelse return .undefined;
        if (index >= rooted_source.array.len()) return .undefined;
        const item = rooted_source.array.get(index);
        return switch (item) {
            .array, .dictionary, .bytes, .promise, .null_value => deepClone(runtime, item),
            else => item,
        };
    }
    const range = (try rangeBounds(runtime, rooted_index, rooted_source.array.len())) orelse return .undefined;
    var result = try runtime.createArray();
    try roots.protect(&result);
    for (rooted_source.array.items.items[range.start .. range.start + range.count]) |item| _ = try result.array.push(item);
    return deepClone(runtime, result);
}

pub fn reference(runtime: *Runtime, source: Value, index_value: Value) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var rooted_source = source;
    var rooted_index = index_value;
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_index);
    const source_value = rooted_source;
    const index = rooted_index;
    if (source_value == .string) {
        if (index == .number) {
            const position = charAtIndex(index.number, source_value.string.len()) orelse return runtime.stringUtf8("");
            if (position >= source_value.string.len()) return runtime.stringUtf8("");
            return runtime.stringCodeUnits(source_value.string.units[position .. position + 1]);
        }
        const range = (try substringBounds(runtime, index, source_value.string.len())) orelse return invalidStringRange(runtime, index);
        return runtime.stringCodeUnits(source_value.string.units[range.start .. range.start + range.count]);
    }
    if (source_value == .array) {
        if (index == .number or index == .bigint or index == .string) return try indexed(runtime, source_value, index);
        const range = (try rangeBounds(runtime, index, source_value.array.len())) orelse return .undefined;
        var result = try runtime.createArray();
        try roots.protect(&result);
        try source_value.array.normalizePresence();
        for (source_value.array.items.items[range.start .. range.start + range.count], range.start..) |item, source_index| {
            try appendArraySlot(result.array, item, source_value.array.isPresent(source_index));
        }
        return result;
    }
    if (source_value == .bytes) return try indexed(runtime, source_value, index);
    if (source_value == .dictionary) {
        var key = try runtime.valueToString(index);
        try roots.protect(&key);
        if (source_value.dictionary.get(key.string)) |value| return value;
        if (try tableInheritedProperty(runtime, source_value, key.string.units)) |value| return value;
        return .undefined;
    }
    return error.IndexableValueExpected;
}

pub fn invalidStringRange(runtime: *Runtime, index: Value) !Value {
    const encoded = try json.call(runtime, "JSON変換", &.{index}) orelse .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var rooted_encoded = encoded;
    try roots.protect(&rooted_encoded);
    var message: std.ArrayList(u16) = .empty;
    errdefer message.deinit(runtime.allocator());
    try appendUtf8Units(&message, runtime.allocator(), "『参照』で文字列型の範囲指定(");
    if (rooted_encoded == .undefined) {
        try appendAsciiUnits(&message, runtime.allocator(), "undefined");
    } else {
        try message.appendSlice(runtime.allocator(), rooted_encoded.string.units);
    }
    try appendUtf8Units(&message, runtime.allocator(), ")が不正です。");
    try runtime.setFailureMessageUnits(message.items);
    return error.InvalidStringRange;
}

pub fn arrayAdd(runtime: *Runtime, source: Value, other: Value) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var rooted_source = source;
    var rooted_other = other;
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_other);
    if (rooted_source != .array) return deepClone(runtime, rooted_source);
    var result = try runtime.createArray();
    try roots.protect(&result);
    try rooted_source.array.normalizePresence();
    for (rooted_source.array.items.items, 0..) |item, source_index| {
        try appendArraySlot(result.array, item, rooted_source.array.isPresent(source_index));
    }
    if (rooted_other == .array) {
        try rooted_other.array.normalizePresence();
        for (rooted_other.array.items.items, 0..) |item, other_index| {
            try appendArraySlot(result.array, item, rooted_other.array.isPresent(other_index));
        }
    } else {
        try appendArraySlot(result.array, rooted_other, true);
    }
    return result;
}

pub fn reduceExtremum(runtime: *Runtime, source: Value, maximum: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var first_index: ?usize = null;
    for (0..source.array.len()) |index| if (source.array.isPresent(index)) {
        first_index = index;
        break;
    };
    const first = first_index orelse return error.NonEmptyArrayExpected;
    var present_count: usize = 0;
    for (0..source.array.len()) |index| {
        if (source.array.isPresent(index)) present_count += 1;
    }
    if (present_count == 1) return source.array.get(first);
    var result = try runtime.valueToNumber(source.array.get(first));
    for (source.array.items.items[first + 1 ..], 0..) |item, offset| {
        const index = first + 1 + offset;
        if (!source.array.isPresent(index)) continue;
        const number = try runtime.valueToNumber(item);
        if (std.math.isNan(number) or std.math.isNan(result)) {
            result = std.math.nan(f64);
        } else if ((maximum and (number > result or (number == result and isNegativeZero(result)))) or
            (!maximum and (number < result or (number == result and isNegativeZero(number)))))
        {
            result = number;
        }
    }
    return .{ .number = result };
}

pub fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

pub fn sum(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result: f64 = 0;
    for (source.array.items.items, 0..) |item, index| {
        if (!source.array.isPresent(index)) continue;
        const number = try common.parseFloatValue(runtime, item);
        if (!std.math.isNan(number)) result += number;
    }
    return .{ .number = result };
}

pub fn swap(runtime: *Runtime, source: Value, first_value: Value, second_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [5]Value{ source, first_value, second_value, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.valueToString(rooted[1]);
    rooted[4] = try runtime.valueToString(rooted[2]);
    const first_index = propertyIndexUnits(rooted[3].string.units);
    const second_index = propertyIndexUnits(rooted[4].string.units);
    const largest_index = if (first_index) |first| if (second_index) |second| @max(first, second) else first else second_index;
    if (largest_index) |index| {
        const required_length = std.math.add(usize, index, 1) catch return error.ArraySparseLengthLimit;
        if (required_length > rooted[0].array.len() and required_length > safe_array_element_limit) return error.ArraySparseLengthLimit;
    }
    // Array length is read-only for this command's two assignment steps when
    // represented by the native dense array.  Keep the failure atomic instead
    // of mutating one side before the second assignment can be validated.
    if (std.mem.eql(u16, rooted[3].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, rooted[4].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    const first_item = arrayPropertyGet(rooted[0].array, rooted[3].string, first_index);
    const second_item = arrayPropertyGet(rooted[0].array, rooted[4].string, second_index);
    try arrayPropertySet(rooted[0].array, rooted[3].string, first_index, second_item);
    try arrayPropertySet(rooted[0].array, rooted[4].string, second_index, first_item);
    return rooted[0];
}

pub fn sequence(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
    var current = first_value;
    var last = last_value;
    var result: Value = .undefined;
    var one: Value = .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&current);
    try roots.protect(&last);
    try roots.protect(&result);
    try roots.protect(&one);
    result = try runtime.createArray();
    if (std.meta.activeTag(first_value) == .bigint or std.meta.activeTag(last_value) == .bigint) {
        one = try runtime.bigIntLiteral("1n");
    }
    var count: usize = 0;
    while (try operators.compare(runtime, current, last)) |order| {
        if (order == .gt) break;
        if (count >= safe_array_element_limit) return error.ArraySequenceSizeLimit;
        if (std.meta.activeTag(last) != .bigint and try runtime.valueToNumber(last) == std.math.inf(f64)) return error.ArraySequenceSizeLimit;
        _ = try result.array.push(current);
        if (std.meta.activeTag(current) == .bigint) {
            current = try operators.binary(runtime, .add, current, one);
        } else {
            const current_number = try runtime.valueToNumber(current);
            const next: Value = .{ .number = current_number + @as(f64, 1) };
            if (next.number == current_number) {
                if (try operators.compare(runtime, next, last)) |next_order| {
                    if (next_order != .gt) return error.ArraySequenceSizeLimit;
                }
            }
            current = next;
        }
        count += 1;
    }
    return result;
}

pub fn fill(runtime: *Runtime, value: Value, shape: Value) !Value {
    var value_root = value;
    var shape_root = shape;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value_root);
    try roots.protect(&shape_root);
    if (shape_root == .array) {
        if (shape_root.array.items.items.len == 0) return runtime.createArray();
        try validateFillDimensions(runtime, shape_root.array.items.items);
        return fillDimensions(runtime, value_root, shape_root.array.items.items, 0);
    }
    const count = try fillLength(try runtime.valueToNumber(shape_root), safe_array_element_limit - 1);
    return fillCount(runtime, value_root, count);
}

pub fn validateFillDimensions(runtime: *Runtime, dimensions: []const Value) !void {
    var product: usize = 1;
    var total: usize = 0;
    for (dimensions) |dimension| {
        const count = try fillLength(try runtime.valueToNumber(dimension), safe_array_element_limit);
        product = std.math.mul(usize, product, count) catch return error.ArrayFillSizeLimit;
        total = std.math.add(usize, total, product) catch return error.ArrayFillSizeLimit;
        if (total > safe_array_element_limit) return error.ArrayFillSizeLimit;
        if (product == 0) break;
    }
}

pub fn fillDimensions(runtime: *Runtime, value: Value, dimensions: []const Value, depth: usize) !Value {
    if (depth >= dimensions.len) return cloneFillValue(runtime, value);
    const count = try fillLength(try runtime.valueToNumber(dimensions[depth]), safe_array_element_limit);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (0..count) |_| _ = try result.array.push(try fillDimensions(runtime, value, dimensions, depth + 1));
    return result;
}

pub fn fillCount(runtime: *Runtime, value: Value, count: usize) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (0..count) |_| _ = try result.array.push(try cloneFillValue(runtime, value));
    return result;
}

pub fn cloneFillValue(runtime: *Runtime, value: Value) !Value {
    if (value != .array) return switch (value) {
        .dictionary, .bytes, .promise => deepClone(runtime, value),
        else => value,
    };
    var source = value;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    try roots.protect(&result);
    try source.array.normalizePresence();
    for (source.array.items.items, 0..) |item, index| {
        try appendArraySlot(result.array, try cloneFillValue(runtime, item), source.array.isPresent(index));
    }
    return result;
}

test "配列切取は辞書のownと継承propertyを分ける" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var prototype = try runtime.createDictionary();
    try roots.protect(&prototype);
    var source = try runtime.createDictionary();
    try roots.protect(&source);
    var x_key = try runtime.stringUtf8("x");
    try roots.protect(&x_key);
    var zero_key = try runtime.stringUtf8("zero");
    try roots.protect(&zero_key);
    var proto_key = try runtime.stringUtf8("__proto__");
    try roots.protect(&proto_key);
    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);
    var own_key = try runtime.stringUtf8("own");
    try roots.protect(&own_key);

    try prototype.dictionary.set(x_key.string, .{ .number = 1 });
    try prototype.dictionary.set(zero_key.string, .{ .number = 0 });
    source.dictionary.prototype = prototype;

    var inherited = try cut(&runtime, source, x_key);
    try roots.protect(&inherited);
    try std.testing.expectEqual(@as(f64, 1), inherited.number);
    var inherited_after = try reference(&runtime, source, x_key);
    try roots.protect(&inherited_after);
    try std.testing.expectEqual(@as(f64, 1), inherited_after.number);

    var falsy_inherited = try cut(&runtime, source, zero_key);
    try roots.protect(&falsy_inherited);
    try std.testing.expectEqual(Value.undefined, falsy_inherited);
    var falsy_after = try reference(&runtime, source, zero_key);
    try roots.protect(&falsy_after);
    try std.testing.expectEqual(@as(f64, 0), falsy_after.number);

    var inherited_proto = try cut(&runtime, source, proto_key);
    try roots.protect(&inherited_proto);
    try std.testing.expect(inherited_proto == .dictionary);
    try std.testing.expect(inherited_proto.dictionary == prototype.dictionary);

    var inherited_method = try cut(&runtime, source, to_string_key);
    try roots.protect(&inherited_method);
    try std.testing.expect(inherited_method == .function);
    var method_after = try reference(&runtime, source, to_string_key);
    try roots.protect(&method_after);
    try std.testing.expect(method_after == .function);

    try source.dictionary.set(own_key.string, .{ .number = 2 });
    var own_value = try cut(&runtime, source, own_key);
    try roots.protect(&own_value);
    try std.testing.expectEqual(@as(f64, 2), own_value.number);
    try std.testing.expect(source.dictionary.get(own_key.string) == null);
}

test "疎配列の参照と配列足は穴のpresenceを保ち範囲コピーだけJSON化する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var sparse = try runtime.createArray();
    try roots.protect(&sparse);
    try sparse.array.set(0, .{ .number = 1 });
    try sparse.array.set(2, .{ .number = 3 });
    try sparse.array.set(3, .undefined);

    var range = try runtime.createDictionary();
    try roots.protect(&range);
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, .{ .number = 3 });

    var referenced = try reference(&runtime, sparse, range);
    try roots.protect(&referenced);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true }, referenced.array.presence.items);

    var copied = try rangeCopy(&runtime, sparse, range);
    try roots.protect(&copied);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true }, copied.array.presence.items);
    try std.testing.expectEqual(Value.null_value, copied.array.get(1));
    try std.testing.expectEqual(Value.null_value, copied.array.get(3));

    var dense_extra = try common.arrayFromValues(&runtime, &.{ .{ .number = 4 }, .{ .number = 5 } });
    try roots.protect(&dense_extra);
    var concatenated = try arrayAdd(&runtime, sparse, dense_extra);
    try roots.protect(&concatenated);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true, true, true }, concatenated.array.presence.items);

    var sparse_extra = try runtime.createArray();
    try roots.protect(&sparse_extra);
    try sparse_extra.array.set(1, .{ .number = 7 });
    var sparse_concatenated = try arrayAdd(&runtime, sparse, sparse_extra);
    try roots.protect(&sparse_concatenated);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true, false, true }, sparse_concatenated.array.presence.items);
}

test "参照はbyte bufferの添字とpropertyを解決する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 154 });
    try roots.protect(&buffer);
    var index = try runtime.stringUtf8("1");
    try roots.protect(&index);
    var length = try runtime.stringUtf8("length");
    try roots.protect(&length);
    var backing_key = try runtime.stringUtf8("buffer");
    try roots.protect(&backing_key);
    var byte_length = try runtime.stringUtf8("byteLength");
    try roots.protect(&byte_length);

    try std.testing.expectEqual(@as(f64, 85), (try reference(&runtime, buffer, .{ .number = 0 })).number);
    try std.testing.expectEqual(@as(f64, 154), (try reference(&runtime, buffer, index)).number);
    try std.testing.expectEqual(@as(f64, 2), (try reference(&runtime, buffer, length)).number);
    var backing = try reference(&runtime, buffer, backing_key);
    try roots.protect(&backing);
    try std.testing.expectEqual(value_mod.ByteKind.array_buffer, backing.bytes.kind);
    try std.testing.expectEqual(@as(f64, 2), (try reference(&runtime, backing, byte_length)).number);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, backing, .{ .number = 0 }));

    var uint8 = try runtime.createUint8Array(&.{ 7, 8 });
    try roots.protect(&uint8);
    try std.testing.expectEqual(@as(f64, 7), (try reference(&runtime, uint8, .{ .number = 0 })).number);
    try std.testing.expectEqual(@as(f64, 2), (try reference(&runtime, uint8, length)).number);
}

pub fn bigintRangeAllocationCase(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try common.arrayFromValues(&runtime, &.{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&source);
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    var last = try runtime.bigIntLiteral("1n");
    try roots.protect(&last);
    var range = try runtime.createDictionary();
    try roots.protect(&range);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, last);

    var copied = try rangeCopy(&runtime, source, range);
    try roots.protect(&copied);
    try std.testing.expectEqual(@as(usize, 2), copied.array.len());
    var text = try runtime.stringUtf8("ABC");
    try roots.protect(&text);
    var referenced = try reference(&runtime, text, range);
    try roots.protect(&referenced);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, referenced.string.units);
}

pub fn bigintRangeAllocationTest(allocator: std.mem.Allocator) !void {
    bigintRangeAllocationCase(allocator) catch |failure| {
        // Zig 0.16のArrayList WriterはJSON複製中のOOMをWriteFailedへ
        // 変換するため、割当網羅テストへ元の意味を戻す。
        if (failure == error.WriteFailed) return error.OutOfMemory;
        return failure;
    };
}

pub fn referenceArrayStringKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try common.arrayFromValues(&runtime, &.{ .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&source);
    var key = try runtime.stringUtf8("length");
    try roots.protect(&key);
    const result = try reference(&runtime, source, key);
    try std.testing.expectEqual(@as(f64, 2), result.number);
}

test "参照の配列文字列添字は割当失敗でも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceArrayStringKeyAllocationTest, .{});
}

test "BigInt範囲終端は割当失敗とGCストレスでも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bigintRangeAllocationTest, .{});
}

pub fn expectReferenceStringRangeMessage(runtime: *Runtime, index: Value, expected: []const u8) !void {
    _ = reference(runtime, try runtime.stringUtf8("ABC"), index) catch |failure| {
        try std.testing.expectEqual(error.InvalidStringRange, failure);
        const actual = (try runtime.failureMessageValue()).?;
        const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
        defer std.testing.allocator.free(expected_units);
        try std.testing.expectEqualSlices(u16, expected_units, actual.string.units);
        runtime.clearFailureMessage();
        return;
    };
    try std.testing.expect(false);
}

test "参照の文字列範囲エラーはJSON値とUTF-16を公式文言へ埋め込む" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try expectReferenceStringRangeMessage(&runtime, .undefined, "『参照』で文字列型の範囲指定(undefined)が不正です。");

    var function_name = try runtime.stringUtf8("F");
    try roots.protect(&function_name);
    var function = try runtime.createNativeFunction(function_name.string, 0, testElementCountFunction, &.{});
    try roots.protect(&function);
    try expectReferenceStringRangeMessage(&runtime, function, "『参照』で文字列型の範囲指定(undefined)が不正です。");

    var string_index = try runtime.stringUtf8("ABC");
    try roots.protect(&string_index);
    try expectReferenceStringRangeMessage(&runtime, string_index, "『参照』で文字列型の範囲指定(\"ABC\")が不正です。");

    var array_index = try common.arrayFromValues(&runtime, &.{ .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&array_index);
    try expectReferenceStringRangeMessage(&runtime, array_index, "『参照』で文字列型の範囲指定([1,2])が不正です。");

    var dictionary_index = try runtime.createDictionary();
    try roots.protect(&dictionary_index);
    try expectReferenceStringRangeMessage(&runtime, dictionary_index, "『参照』で文字列型の範囲指定({})が不正です。");

    var lone_surrogate = try runtime.stringCodeUnits(&.{0xd800});
    try roots.protect(&lone_surrogate);
    try expectReferenceStringRangeMessage(&runtime, lone_surrogate, "『参照』で文字列型の範囲指定(\"\\ud800\")が不正です。");

    var pair = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00 });
    try roots.protect(&pair);
    try expectReferenceStringRangeMessage(&runtime, pair, "『参照』で文字列型の範囲指定(\"😀\")が不正です。");

    var bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&bigint);
    try std.testing.expectError(error.CannotSerializeBigInt, reference(&runtime, try runtime.stringUtf8("ABC"), bigint));

    var circular = try runtime.createDictionary();
    try roots.protect(&circular);
    var self_key = try runtime.stringUtf8("self");
    try roots.protect(&self_key);
    try circular.dictionary.set(self_key.string, circular);
    try std.testing.expectError(error.CircularCloneValue, reference(&runtime, try runtime.stringUtf8("ABC"), circular));
    try std.testing.expect(std.mem.startsWith(u8, runtime.failureMessage().?, "Converting circular structure to JSON"));
    runtime.clearFailureMessage();

    try std.testing.expectError(error.ArrayCutNullIndex, reference(&runtime, try runtime.stringUtf8("ABC"), .null_value));
}

pub fn referenceStringRangeAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("ABC");
    const index = try runtime.stringUtf8("bad");
    _ = reference(&runtime, source, index) catch |failure| {
        if (failure == error.InvalidStringRange) return;
        try std.testing.expect(runtime.failureMessage() == null);
        // Zig 0.16のArrayList Writerは内部の割当失敗をWriteFailedへ
        // 変換するため、割当網羅テストへ元の意味を戻す。
        if (failure == error.WriteFailed) return error.OutOfMemory;
        return failure;
    };
    return error.ExpectedInvalidStringRange;
}

test "参照の文字列範囲エラーは割当失敗時にも途中状態を残さない" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceStringRangeAllocationTest, .{});
}

test "配列集約・連番・要素生成の型変換と複製境界を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var singleton_text = try runtime.stringUtf8("9");
    try roots.protect(&singleton_text);
    var singleton_array = try common.arrayFromValues(&runtime, &.{singleton_text});
    try roots.protect(&singleton_array);
    try std.testing.expectEqual(std.meta.Tag(Value).string, std.meta.activeTag(try reduceExtremum(&runtime, singleton_array, true)));
    var singleton_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&singleton_bigint);
    var singleton_bigint_array = try common.arrayFromValues(&runtime, &.{singleton_bigint});
    try roots.protect(&singleton_bigint_array);
    try std.testing.expectEqual(singleton_bigint.bigint, (try reduceExtremum(&runtime, singleton_bigint_array, false)).bigint);
    try std.testing.expectError(error.ArrayExpected, reduceExtremum(&runtime, .{ .number = 1 }, true));

    var zeroes = try common.arrayFromValues(&runtime, &.{ .{ .number = -0.0 }, .{ .number = 0.0 } });
    try roots.protect(&zeroes);
    try std.testing.expect(!isNegativeZero((try reduceExtremum(&runtime, zeroes, true)).number));
    var reverse_zeroes = try common.arrayFromValues(&runtime, &.{ .{ .number = 0.0 }, .{ .number = -0.0 } });
    try roots.protect(&reverse_zeroes);
    try std.testing.expect(isNegativeZero((try reduceExtremum(&runtime, reverse_zeroes, false)).number));
    var with_nan = try common.arrayFromValues(&runtime, &.{ .{ .number = 2 }, .{ .number = std.math.nan(f64) }, .{ .number = 3 } });
    try roots.protect(&with_nan);
    try std.testing.expect(std.math.isNan((try reduceExtremum(&runtime, with_nan, true)).number));

    var swap_source = try common.arrayFromValues(&runtime, &.{.{ .number = 0 }});
    try roots.protect(&swap_source);
    try std.testing.expectError(error.ArraySparseLengthLimit, swap(&runtime, swap_source, .{ .number = 0 }, .{ .number = @floatFromInt(safe_array_element_limit) }));

    var first = try runtime.stringUtf8("2");
    try roots.protect(&first);
    var created_sequence = try sequence(&runtime, first, .{ .number = 4 });
    try roots.protect(&created_sequence);
    try std.testing.expectEqual(std.meta.Tag(Value).string, std.meta.activeTag(created_sequence.array.get(0)));
    try std.testing.expectEqual(@as(f64, 3), created_sequence.array.get(1).number);
    var bigint_first = try runtime.bigIntLiteral("2n");
    try roots.protect(&bigint_first);
    var bigint_last = try runtime.bigIntLiteral("4n");
    try roots.protect(&bigint_last);
    var bigint_sequence = try sequence(&runtime, bigint_first, bigint_last);
    try roots.protect(&bigint_sequence);
    try std.testing.expectEqual(@as(usize, 3), bigint_sequence.array.len());
    try std.testing.expectEqual(std.meta.Tag(Value).bigint, std.meta.activeTag(bigint_sequence.array.get(2)));
    try std.testing.expectError(error.ArraySequenceSizeLimit, sequence(&runtime, .{ .number = 0 }, .{ .number = std.math.inf(f64) }));
    try std.testing.expectError(error.ArraySequenceSizeLimit, sequence(&runtime, .{ .number = -std.math.inf(f64) }, .{ .number = -1 }));
    try std.testing.expectError(
        error.ArraySequenceSizeLimit,
        sequence(&runtime, .{ .number = 9_007_199_254_740_992 }, .{ .number = 9_007_199_254_740_992 }),
    );

    var empty_shape = try runtime.createArray();
    try roots.protect(&empty_shape);
    var empty_fill = try fill(&runtime, .{ .number = 7 }, empty_shape);
    try roots.protect(&empty_fill);
    try std.testing.expectEqual(@as(usize, 0), empty_fill.array.len());
    var undefined_fill = try fill(&runtime, .undefined, .{ .number = 2 });
    try roots.protect(&undefined_fill);
    try std.testing.expectEqual(Value.undefined, undefined_fill.array.get(0));
    try std.testing.expectEqual(Value.undefined, undefined_fill.array.get(1));
    try std.testing.expectError(error.ArrayFillSizeLimit, fill(&runtime, .{ .number = 0 }, .{ .number = std.math.inf(f64) }));

    var huge_shape = try common.arrayFromValues(&runtime, &.{ .{ .number = @floatFromInt(safe_array_element_limit) }, .{ .number = 2 } });
    try roots.protect(&huge_shape);
    try std.testing.expectError(error.ArrayFillSizeLimit, fill(&runtime, .{ .number = 0 }, huge_shape));
    var boundary_shape = try common.arrayFromValues(&runtime, &.{ .{ .number = 1 }, .{ .number = @floatFromInt(safe_array_element_limit - 1) } });
    try roots.protect(&boundary_shape);
    try validateFillDimensions(&runtime, boundary_shape.array.items.items);
    var over_boundary_shape = try common.arrayFromValues(&runtime, &.{ .{ .number = 1 }, .{ .number = @floatFromInt(safe_array_element_limit) } });
    try roots.protect(&over_boundary_shape);
    try std.testing.expectError(error.ArrayFillSizeLimit, validateFillDimensions(&runtime, over_boundary_shape.array.items.items));
    var nested_value = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&nested_value);
    var independent_fill = try fill(&runtime, nested_value, .{ .number = 2 });
    try roots.protect(&independent_fill);
    try independent_fill.array.get(0).array.set(0, .{ .number = 9 });
    try std.testing.expectEqual(@as(f64, 1), independent_fill.array.get(1).array.get(0).number);

    var sparse_value = try runtime.createArray();
    try roots.protect(&sparse_value);
    try sparse_value.array.set(1, .{ .number = 2 });
    try sparse_value.array.set(2, .undefined);
    var sparse_fill = try fill(&runtime, sparse_value, .{ .number = 1 });
    try roots.protect(&sparse_fill);
    const sparse_clone = sparse_fill.array.get(0).array;
    try std.testing.expectEqual(@as(usize, 3), sparse_clone.len());
    try std.testing.expect(!sparse_clone.isPresent(0));
    try std.testing.expect(sparse_clone.isPresent(1));
    try std.testing.expect(sparse_clone.isPresent(2));
    try sparse_clone.set(0, .{ .number = 9 });
    try std.testing.expectEqual(Value.undefined, sparse_value.array.get(0));
    try std.testing.expectEqual(@as(f64, 2), sparse_value.array.get(1).number);

    var fill_buffer = try runtime.createBytes(&.{ 85, 154 });
    try roots.protect(&fill_buffer);
    var buffer_fill = try fill(&runtime, fill_buffer, .{ .number = 1 });
    try roots.protect(&buffer_fill);
    try std.testing.expectEqual(std.meta.Tag(Value).dictionary, std.meta.activeTag(buffer_fill.array.get(0)));
    var data_key = try runtime.stringUtf8("data");
    try roots.protect(&data_key);
    const buffer_data = buffer_fill.array.get(0).dictionary.get(data_key.string).?;
    try std.testing.expectEqual(@as(f64, 85), buffer_data.array.get(0).number);
    try buffer_data.array.set(0, .{ .number = 9 });
    try std.testing.expectEqual(@as(u8, 85), fill_buffer.bytes.bytes[0]);

    var fill_uint8 = try runtime.createUint8Array(&.{ 139, 103 });
    try roots.protect(&fill_uint8);
    var uint8_fill = try fill(&runtime, fill_uint8, .{ .number = 1 });
    try roots.protect(&uint8_fill);
    try std.testing.expectEqual(std.meta.Tag(Value).dictionary, std.meta.activeTag(uint8_fill.array.get(0)));
    var zero_key = try runtime.stringUtf8("0");
    try roots.protect(&zero_key);
    try std.testing.expectEqual(@as(f64, 139), uint8_fill.array.get(0).dictionary.get(zero_key.string).?.number);

    var fill_array_buffer = try runtime.createArrayBuffer(&.{ 1, 2 });
    try roots.protect(&fill_array_buffer);
    var array_buffer_fill = try fill(&runtime, fill_array_buffer, .{ .number = 1 });
    try roots.protect(&array_buffer_fill);
    try std.testing.expectEqual(std.meta.Tag(Value).dictionary, std.meta.activeTag(array_buffer_fill.array.get(0)));
    try std.testing.expectEqual(@as(usize, 0), array_buffer_fill.array.get(0).dictionary.len());
}

test "配列入替はcanonical添字以外をown propertyとして保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var source = try common.arrayFromValues(&runtime, &.{ .{ .number = 10 }, .{ .number = 20 } });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var foo = try runtime.stringUtf8("foo");
    try roots.protect(&foo);
    var bar = try runtime.stringUtf8("bar");
    try roots.protect(&bar);
    var leading_zero = try runtime.stringUtf8("01");
    try roots.protect(&leading_zero);
    try source.array.setProperty(foo.string, .{ .number = 7 });
    try source.array.setProperty(leading_zero.string, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 7), (try indexed(&runtime, source, foo)).number);
    _ = try swap(&runtime, source, foo, bar);
    try std.testing.expectEqual(Value.undefined, try indexed(&runtime, source, foo));
    try std.testing.expectEqual(@as(f64, 7), (try indexed(&runtime, source, bar)).number);
    try std.testing.expectEqual(@as(f64, 8), (try indexed(&runtime, source, leading_zero)).number);
    try std.testing.expectEqual(@as(usize, 3), source.array.properties.items.len);
    const first_key = try source.array.properties.items[0].key.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(first_key);
    try std.testing.expectEqualStrings("foo", first_key);
}
