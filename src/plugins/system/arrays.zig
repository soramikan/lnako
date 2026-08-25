const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const operators = @import("../../runtime/operators.zig");
const common = @import("common.zig");
const json = @import("json.zig");
const regexp = @import("regexp.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const safe_array_element_limit: usize = 1_000_000;

pub const Context = struct {
    context: *anyopaque,
    randomFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,
    callFn: ?*const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value = null,
    resolveFn: ?*const fn (context: *anyopaque, name: []const u8) anyerror!Value = null,

    fn random(self: ?Context) !f64 {
        const actual = self orelse return error.RandomSourceUnavailable;
        const function = actual.randomFn orelse return error.RandomSourceUnavailable;
        const result = try function(actual.context);
        if (!std.math.isFinite(result) or result < 0 or result >= 1) return error.InvalidRandomValue;
        return result;
    }

    fn invoke(self: ?Context, callable: Value, arguments: []const Value) !Value {
        const actual = self orelse return error.CallbackExecutionUnavailable;
        const function = actual.callFn orelse return error.CallbackExecutionUnavailable;
        return function(actual.context, callable, arguments);
    }

    fn resolve(self: ?Context, runtime: *Runtime, value: Value) !Value {
        if (value == .function) return value;
        if (value != .string) return error.NotCallable;
        const actual = self orelse return error.CallbackExecutionUnavailable;
        const function = actual.resolveFn orelse return error.CallbackExecutionUnavailable;
        const name = try value.string.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(name);
        return function(actual.context, name);
    }
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    const c = common.argument(arguments, 2);
    if (isAny(name, &.{ "配列結合", "配列只結合" })) return try join(runtime, a, if (eql(name, "配列只結合")) try runtime.stringUtf8("") else b);
    if (eql(name, "配列検索")) return .{ .number = @floatFromInt(arraySearch(a, b)) };
    if (isAny(name, &.{ "配列要素数", "要素数", "LEN" })) return .{ .number = @floatFromInt(elementCount(a)) };
    if (eql(name, "配列挿入")) return try insertOne(runtime, a, b, c);
    if (eql(name, "配列一括挿入")) return try insertMany(runtime, a, b, c);
    if (eql(name, "配列ソート")) return try sortDefault(runtime, a);
    if (eql(name, "配列数値変換")) return try numericConvert(runtime, a);
    if (eql(name, "配列数値ソート")) return try sortNumeric(runtime, a);
    if (eql(name, "配列カスタムソート")) return try sortCustom(runtime, a, b, context);
    if (eql(name, "配列逆順")) return try reverse(a);
    if (eql(name, "配列シャッフル")) return try shuffle(a, context);
    if (isAny(name, &.{ "配列削除", "配列切取" })) return try cut(runtime, a, b);
    if (eql(name, "配列取出")) return try take(runtime, a, b, c);
    if (eql(name, "配列ポップ")) return try pop(a);
    if (isAny(name, &.{ "配列プッシュ", "配列追加" })) return try push(a, b);
    if (eql(name, "配列複製")) return try deepClone(runtime, a);
    if (eql(name, "配列範囲コピー")) return try rangeCopy(runtime, a, b);
    if (isAny(name, &.{ "参照", "配列参照" })) return try reference(runtime, a, b);
    if (eql(name, "配列足")) return try arrayAdd(runtime, a, b);
    if (eql(name, "配列最大値")) return try reduceExtremum(runtime, a, true);
    if (eql(name, "配列最小値")) return try reduceExtremum(runtime, a, false);
    if (eql(name, "配列合計")) return try sum(runtime, a);
    if (eql(name, "配列入替")) return try swap(a, b, c);
    if (eql(name, "配列連番作成")) return try sequence(runtime, a, b);
    if (eql(name, "配列要素作成")) return try fill(runtime, a, b);
    if (isAny(name, &.{ "配列関数適用", "配列マップ" })) return try map(runtime, a, b, context, false);
    if (eql(name, "配列フィルタ")) return try map(runtime, a, b, context, true);

    if (eql(name, "表ソート")) return try tableSort(runtime, a, b, false);
    if (eql(name, "表数値ソート")) return try tableSort(runtime, a, b, true);
    if (eql(name, "表ピックアップ")) return try tablePickup(runtime, a, b, c, false);
    if (eql(name, "表完全一致ピックアップ")) return try tablePickup(runtime, a, b, c, true);
    if (eql(name, "表検索")) return try tableSearch(runtime, a, b, c, common.argument(arguments, 3));
    if (eql(name, "表列数")) return try tableColumnCount(runtime, a);
    if (eql(name, "表行数")) return try tableRowCount(a);
    if (eql(name, "表行列交換")) return try transpose(runtime, a, false);
    if (eql(name, "表右回転")) return try transpose(runtime, a, true);
    if (eql(name, "表重複削除")) return try tableUnique(runtime, a, b);
    if (eql(name, "表列取得")) return try tableColumn(runtime, a, b);
    if (eql(name, "表列挿入")) return try tableInsertColumn(runtime, a, b, c);
    if (eql(name, "表列削除")) return try tableDeleteColumn(runtime, a, b);
    if (eql(name, "表列合計")) return try tableColumnSum(runtime, a, b);
    if (eql(name, "表曖昧検索")) return try tableRegexpSearch(runtime, a, b, c, common.argument(arguments, 3));
    if (eql(name, "表正規表現ピックアップ")) return try tableRegexpPickup(runtime, a, b, c);
    return null;
}

fn join(runtime: *Runtime, source: Value, separator: Value) !Value {
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

fn arraySearch(source: Value, needle: Value) i64 {
    if (source != .array) return -1;
    for (source.array.items.items, 0..) |item, index| if (Value.strictEqual(item, needle)) return @intCast(index);
    return -1;
}

fn elementCount(value: Value) usize {
    return switch (value) {
        .bytes => |bytes| bytes.bytes.len,
        .array => |array| array.len(),
        .dictionary => |dictionary| dictionary.len(),
        .string => |string| string.len(),
        .function, .promise => 0,
        else => 1,
    };
}

fn testElementCountFunction(_: *Runtime, _: []const Value) !Value {
    return .undefined;
}

const TestMutatingSortContext = struct {
    target: *value_mod.Array,
    mutated: bool = false,

    fn invoke(raw: *anyopaque, _: Value, arguments: []const Value) anyerror!Value {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!self.mutated) {
            self.target.items.clearRetainingCapacity();
            self.mutated = true;
        }
        return .{ .number = arguments[0].number - arguments[1].number };
    }
};

fn insertOne(runtime: *Runtime, source: Value, index_value: Value, item: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.insert(spliceIndex(try runtime.valueToNumber(index_value), source.array.len()), item);
    return runtime.createArray();
}

fn insertMany(runtime: *Runtime, source: Value, index_value: Value, items: Value) !Value {
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

fn sortDefault(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source, .string, null);
    return source;
}

fn numericConvert(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var source_root = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    for (source_root.array.items.items) |*item| {
        const original = item.*;
        const number = try common.parseFloatValue(runtime, original);
        item.* = .{ .number = number };
    }
    return source_root;
}

fn sortNumeric(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source, .number, null);
    return source;
}

fn sortCustom(runtime: *Runtime, function_value: Value, source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    var source_root = source;
    var function_root = function_value;
    var callable: Value = .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    try roots.protect(&function_root);
    try roots.protect(&callable);
    callable = try Context.resolve(context, runtime, function_root);
    try stableSort(runtime, source_root, .callback, .{ .context = context, .callable = callable });
    return source_root;
}

const SortMode = enum { string, number, relational, callback };
const SortCallback = struct { context: ?Context, callable: Value };

fn stableSort(runtime: *Runtime, source: Value, mode: SortMode, callback: ?SortCallback) !void {
    const array = source.array;
    if (array.items.items.len < 2) return;
    if (mode == .callback) return stableCallbackSort(runtime, array, callback.?);

    // Allocate initialized scratch storage before sorting. This avoids O(n^2)
    // behavior and prevents OOM from exposing an uninitialized array slot.
    var source_root = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    const temporary = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(temporary);
    for (temporary) |*item| try roots.protect(item);

    var width: usize = 1;
    var from_source = true;
    while (width < array.items.items.len) : (width = std.math.mul(usize, width, 2) catch array.items.items.len) {
        const input = if (from_source) array.items.items else temporary;
        const output = if (from_source) temporary else array.items.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareForSort(runtime, input[left], input[right], mode, callback);
                if (order == .gt) {
                    output[destination] = input[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) output[destination] = input[left];
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) output[destination] = input[right];
            start = end;
        }
        from_source = !from_source;
    }
    if (!from_source) std.mem.copyForwards(Value, array.items.items, temporary);
}

fn stableCallbackSort(runtime: *Runtime, array: *value_mod.Array, callback: SortCallback) !void {
    // ECMAScript collects the indexed values before invoking the comparator.
    // Keep both merge buffers detached from the live array so a callback may
    // resize or reallocate that array without invalidating an active slice.
    const original_length = array.len();
    const first = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(first);
    const second = try runtime.allocator().dupe(Value, first);
    defer runtime.allocator().free(second);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (first) |*item| try roots.protect(item);
    for (second) |*item| try roots.protect(item);

    var width: usize = 1;
    var from_first = true;
    while (width < original_length) : (width = std.math.mul(usize, width, 2) catch original_length) {
        const input = if (from_first) first else second;
        const output = if (from_first) second else first;
        var start: usize = 0;
        while (start < original_length) {
            const middle = @min(std.math.add(usize, start, width) catch original_length, original_length);
            const end = @min(std.math.add(usize, middle, width) catch original_length, original_length);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareForSort(runtime, input[left], input[right], .callback, callback);
                if (order == .gt) {
                    output[destination] = input[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) output[destination] = input[left];
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) output[destination] = input[right];
            start = end;
        }
        from_first = !from_first;
    }

    if (array.len() < original_length) {
        const old_length = array.len();
        try array.items.resize(runtime.allocator(), original_length);
        @memset(array.items.items[old_length..], .undefined);
    }
    const sorted = if (from_first) first else second;
    std.mem.copyForwards(Value, array.items.items[0..original_length], sorted);
}

fn compareForSort(runtime: *Runtime, left: Value, right: Value, mode: SortMode, callback: ?SortCallback) !std.math.Order {
    // ECMAScript Array#sort places undefined (including dense stand-ins for
    // holes) after all defined values without invoking the comparator.
    if (left == .undefined) return if (right == .undefined) .eq else .gt;
    if (right == .undefined) return .lt;
    return switch (mode) {
        .string => blk: {
            var converted = [2]Value{ .undefined, .undefined };
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&converted[0]);
            try roots.protect(&converted[1]);
            converted[0] = try runtime.valueToString(left);
            converted[1] = try runtime.valueToString(right);
            const rooted_left = converted[0];
            const rooted_right = converted[1];
            break :blk value_mod.String.order(rooted_left.string.*, rooted_right.string.*);
        },
        .number => blk: {
            const left_number = try common.parseFloatValue(runtime, left);
            const right_number = try common.parseFloatValue(runtime, right);
            if (std.math.isNan(left_number) or std.math.isNan(right_number)) break :blk .eq;
            break :blk std.math.order(left_number, right_number);
        },
        .relational => (try operators.compare(runtime, left, right)) orelse .eq,
        .callback => blk: {
            const actual = callback.?;
            const result = try Context.invoke(actual.context, actual.callable, &.{ left, right });
            const number = try runtime.valueToNumber(result);
            if (std.math.isNan(number) or number == 0) break :blk .eq;
            break :blk if (number < 0) .lt else .gt;
        },
    };
}

fn reverse(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    std.mem.reverse(Value, source.array.items.items);
    return source;
}

fn shuffle(source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    var index = source.array.len();
    while (index > 1) {
        index -= 1;
        const random_index: usize = @intFromFloat(@floor(try Context.random(context) * @as(f64, @floatFromInt(index + 1))));
        std.mem.swap(Value, &source.array.items.items[index], &source.array.items.items[random_index]);
    }
    return source;
}

fn cut(runtime: *Runtime, source: Value, index_value: Value) !Value {
    if (source == .array) {
        if (index_value == .number) return source.array.remove(spliceIndex(index_value.number, source.array.len()));
        if (try spliceRangeBounds(runtime, index_value, source.array.len())) |range| return spliceArray(runtime, source.array, range.start, range.count);
        return .null_value;
    }
    if (source == .dictionary and index_value == .string) {
        const old = source.dictionary.get(index_value.string) orelse return .undefined;
        if (!old.toBoolean()) return .undefined;
        _ = source.dictionary.remove(index_value.string);
        return old;
    }
    return error.ArrayExpected;
}

fn take(runtime: *Runtime, source: Value, index_value: Value, count_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    const start = spliceIndex(try runtime.valueToNumber(index_value), source.array.len());
    const count = positiveLength(try runtime.valueToNumber(count_value), source.array.len() - start);
    return spliceArray(runtime, source.array, start, count);
}

fn spliceArray(runtime: *Runtime, array: *value_mod.Array, start: usize, count: usize) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const actual = @min(count, array.len() - @min(start, array.len()));
    for (0..actual) |_| _ = try result.array.push(array.remove(start));
    return result;
}

fn pop(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    return source.array.pop();
}

fn push(source: Value, value: Value) !Value {
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

fn cloneValue(runtime: *Runtime, source: Value, arrays: *std.ArrayList(*value_mod.Array), dictionaries: *std.ArrayList(*value_mod.Dictionary)) !Value {
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

fn rangeCopy(runtime: *Runtime, source: Value, index_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    if (index_value == .number) {
        const index = propertyIndex(index_value.number) orelse return .undefined;
        if (index >= source.array.len()) return .undefined;
        const item = source.array.get(index);
        return switch (item) {
            .array, .dictionary, .bytes, .promise, .null_value => deepClone(runtime, item),
            else => item,
        };
    }
    const range = (try rangeBounds(runtime, index_value, source.array.len())) orelse return .undefined;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items[range.start .. range.start + range.count]) |item| _ = try result.array.push(item);
    return deepClone(runtime, result);
}

fn reference(runtime: *Runtime, source: Value, index_value: Value) !Value {
    if (source == .string) {
        if (index_value == .number) {
            const index = charAtIndex(index_value.number, source.string.len()) orelse return runtime.stringUtf8("");
            if (index >= source.string.len()) return runtime.stringUtf8("");
            return runtime.stringCodeUnits(source.string.units[index .. index + 1]);
        }
        const range = (try substringBounds(runtime, index_value, source.string.len())) orelse return error.InvalidStringRange;
        return runtime.stringCodeUnits(source.string.units[range.start .. range.start + range.count]);
    }
    if (source == .array) {
        if (index_value == .number) return source.array.get(propertyIndex(index_value.number) orelse return .undefined);
        const range = (try rangeBounds(runtime, index_value, source.array.len())) orelse return .undefined;
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (source.array.items.items[range.start .. range.start + range.count]) |item| _ = try result.array.push(item);
        return result;
    }
    if (source == .dictionary) {
        const key = try runtime.valueToString(index_value);
        return source.dictionary.get(key.string) orelse .undefined;
    }
    return error.IndexableValueExpected;
}

fn arrayAdd(runtime: *Runtime, source: Value, other: Value) !Value {
    if (source != .array) return deepClone(runtime, source);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items) |item| _ = try result.array.push(item);
    if (other == .array) {
        for (other.array.items.items) |item| _ = try result.array.push(item);
    } else {
        _ = try result.array.push(other);
    }
    return result;
}

fn reduceExtremum(runtime: *Runtime, source: Value, maximum: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    if (source.array.len() == 0) return error.NonEmptyArrayExpected;
    if (source.array.len() == 1) return source.array.get(0);
    var result = try runtime.valueToNumber(source.array.get(0));
    for (source.array.items.items[1..]) |item| {
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

fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

fn sum(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result: f64 = 0;
    for (source.array.items.items) |item| {
        const number = try common.parseFloatValue(runtime, item);
        if (!std.math.isNan(number)) result += number;
    }
    return .{ .number = result };
}

fn swap(source: Value, first_value: Value, second_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    const first = if (first_value == .number) directIndex(first_value.number) orelse return error.InvalidArrayIndex else return error.InvalidArrayIndex;
    const second = if (second_value == .number) directIndex(second_value.number) orelse return error.InvalidArrayIndex else return error.InvalidArrayIndex;
    const required_length = std.math.add(usize, @max(first, second), 1) catch return error.ArraySizeLimitExceeded;
    if (required_length > source.array.len() and required_length > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    const first_item = source.array.get(first);
    const second_item = source.array.get(second);
    try source.array.set(first, second_item);
    try source.array.set(second, first_item);
    return source;
}

fn sequence(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
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
        if (count >= safe_array_element_limit) return error.ArraySizeLimitExceeded;
        if (std.meta.activeTag(last) != .bigint and try runtime.valueToNumber(last) == std.math.inf(f64)) return error.ArraySizeLimitExceeded;
        _ = try result.array.push(current);
        if (std.meta.activeTag(current) == .bigint) {
            current = try operators.binary(runtime, .add, current, one);
        } else {
            const current_number = try runtime.valueToNumber(current);
            const next: Value = .{ .number = current_number + @as(f64, 1) };
            if (next.number == current_number) {
                if (try operators.compare(runtime, next, last)) |next_order| {
                    if (next_order != .gt) return error.ArraySizeLimitExceeded;
                }
            }
            current = next;
        }
        count += 1;
    }
    return result;
}

fn fill(runtime: *Runtime, value: Value, shape: Value) !Value {
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

fn validateFillDimensions(runtime: *Runtime, dimensions: []const Value) !void {
    var product: usize = 1;
    var total: usize = 1;
    for (dimensions) |dimension| {
        const count = try fillLength(try runtime.valueToNumber(dimension), safe_array_element_limit);
        product = std.math.mul(usize, product, count) catch return error.ArraySizeLimitExceeded;
        total = std.math.add(usize, total, product) catch return error.ArraySizeLimitExceeded;
        if (total > safe_array_element_limit) return error.ArraySizeLimitExceeded;
        if (product == 0) break;
    }
}

fn fillDimensions(runtime: *Runtime, value: Value, dimensions: []const Value, depth: usize) !Value {
    if (depth >= dimensions.len) return cloneFillValue(runtime, value);
    const count = try fillLength(try runtime.valueToNumber(dimensions[depth]), safe_array_element_limit);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (0..count) |_| _ = try result.array.push(try fillDimensions(runtime, value, dimensions, depth + 1));
    return result;
}

fn fillCount(runtime: *Runtime, value: Value, count: usize) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (0..count) |_| _ = try result.array.push(try cloneFillValue(runtime, value));
    return result;
}

fn cloneFillValue(runtime: *Runtime, value: Value) !Value {
    if (value != .array) return if (value == .dictionary) deepClone(runtime, value) else value;
    var source = value;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    try roots.protect(&result);
    for (source.array.items.items) |item| _ = try result.array.push(try cloneFillValue(runtime, item));
    return result;
}

fn map(runtime: *Runtime, function_value: Value, source: Value, context: ?Context, filtering: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var callable = try Context.resolve(context, runtime, function_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&callable);
    var result = try runtime.createArray();
    try roots.protect(&result);
    for (source.array.items.items) |item| {
        const mapped = try Context.invoke(context, callable, &.{item});
        if (!filtering) _ = try result.array.push(mapped) else if (mapped.toBoolean()) _ = try result.array.push(item);
    }
    return result;
}

fn tableSort(runtime: *Runtime, source: Value, column: Value, numeric: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var index: usize = 1;
    while (index < source.array.len()) : (index += 1) {
        const row = source.array.items.items[index];
        var cursor = index;
        while (cursor > 0) {
            const left = try indexed(runtime, source.array.items.items[cursor - 1], column);
            const right = try indexed(runtime, row, column);
            const order = if (numeric) blk: {
                const left_number = try runtime.valueToNumber(left);
                const right_number = try runtime.valueToNumber(right);
                break :blk if (std.math.isNan(left_number) or std.math.isNan(right_number)) std.math.Order.eq else std.math.order(left_number, right_number);
            } else (try operators.compare(runtime, left, right)) orelse .eq;
            if (order != .gt) break;
            source.array.items.items[cursor] = source.array.items.items[cursor - 1];
            cursor -= 1;
        }
        source.array.items.items[cursor] = row;
    }
    return source;
}

fn tablePickup(runtime: *Runtime, source: Value, column: Value, needle: Value, exact: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [7]Value{ source, column, needle, .undefined, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.createArray();
    if (!exact) rooted[4] = try runtime.valueToString(rooted[2]);
    for (rooted[0].array.items.items) |row| {
        rooted[5] = try indexed(runtime, row, rooted[1]);
        const matches = if (exact) Value.strictEqual(rooted[5], rooted[2]) else blk: {
            rooted[6] = try runtime.valueToString(rooted[5]);
            break :blk std.mem.indexOf(u16, rooted[6].string.units, rooted[4].string.units) != null;
        };
        if (matches) _ = try rooted[3].array.push(row);
    }
    return rooted[3];
}

fn tableSearch(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [6]Value{ source, column, row_value, needle, row_value, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    while ((try operators.compare(runtime, rooted[4], .{ .number = @floatFromInt(rooted[0].array.len()) })) == .lt) {
        rooted[5] = try indexed(runtime, rooted[0], rooted[4]);
        const cell = try indexed(runtime, rooted[5], rooted[1]);
        if (Value.strictEqual(cell, rooted[3])) return rooted[4];
        rooted[4] = try incrementTableSearchRow(runtime, rooted[4]);
    }
    return .{ .number = -1 };
}

fn incrementTableSearchRow(runtime: *Runtime, row: Value) !Value {
    if (row == .bigint) {
        var one = try value_mod.BigInt.init(runtime.allocator(), 1);
        defer one.deinit();
        return runtime.ownBigInt(try row.bigint.add(runtime.allocator(), one));
    }
    return .{ .number = try runtime.valueToNumber(row) + 1 };
}

fn tableColumnCount(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [2]Value{ source, .{ .number = 1 } };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    for (rooted[0].array.items.items) |row| {
        const length = try rowLengthValue(row);
        if ((try operators.compare(runtime, length, rooted[1])) == .gt) rooted[1] = length;
    }
    return rooted[1];
}

fn rowLengthValue(row: Value) !Value {
    return switch (row) {
        .array => |array| .{ .number = @floatFromInt(array.len()) },
        .string => |string| .{ .number = @floatFromInt(string.len()) },
        .bytes => |buffer| if (buffer.kind == .array_buffer) .undefined else .{ .number = @floatFromInt(buffer.bytes.len) },
        .null_value, .undefined => error.TableRowMissing,
        .dictionary => |dictionary| blk: {
            var units = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };
            var key = value_mod.String{ .allocator = dictionary.allocator, .units = &units };
            break :blk dictionary.get(&key) orelse .undefined;
        },
        // The official compiler wraps Nadesiko functions in a rest-argument
        // closure, whose JavaScript Function.length is always zero.
        .function => .{ .number = 0 },
        else => .undefined,
    };
}

fn tableRowCount(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    return .{ .number = @floatFromInt(source.array.len()) };
}

fn transpose(runtime: *Runtime, source: Value, rotate: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[1] = try tableColumnCount(runtime, rooted[0]);
    const columns = try tableIterationCount(runtime, rooted[1]);
    const cells = std.math.mul(usize, columns, rooted[0].array.len()) catch return error.ArraySizeLimitExceeded;
    if (cells > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    rooted[2] = try runtime.createArray();
    for (0..columns) |column| {
        var row_result = try runtime.createArray();
        try roots.protect(&row_result);
        for (0..rooted[0].array.len()) |offset| {
            const row_index = if (rotate) rooted[0].array.len() - offset - 1 else offset;
            const row = rooted[0].array.get(row_index);
            rooted[3] = try indexed(runtime, row, .{ .number = @floatFromInt(column) });
            if (!rotate and rooted[3] == .undefined) rooted[3] = try runtime.stringUtf8("");
            _ = try row_result.array.push(rooted[3]);
        }
        _ = try rooted[2].array.push(row_result);
    }
    return rooted[2];
}

fn tableIterationCount(runtime: *Runtime, value: Value) !usize {
    const number = if (value == .bigint) value.bigint.toF64() else try runtime.valueToNumber(value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@ceil(number));
}

fn tableUnique(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [5]Value{ source, column, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    rooted[3] = try runtime.createDictionary();
    for (rooted[0].array.items.items) |row| {
        rooted[4] = try runtime.valueToString(try indexed(runtime, row, rooted[1]));
        if (!isObjectPrototypeKey(rooted[4].string.units) and !rooted[3].dictionary.has(rooted[4].string)) {
            try rooted[3].dictionary.set(rooted[4].string, .{ .boolean = true });
            _ = try rooted[2].array.push(row);
        }
    }
    return rooted[2];
}

fn tableColumn(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [3]Value{ source, column, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    for (rooted[0].array.items.items) |row| _ = try rooted[2].array.push(try indexed(runtime, row, rooted[1]));
    return rooted[2];
}

fn tableInsertColumn(runtime: *Runtime, source: Value, column_value: Value, values: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [6]Value{ source, column_value, values, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.createArray();
    if (rooted[0].array.len() == 0) return rooted[3];
    const positive_order = try operators.compare(runtime, rooted[1], .{ .number = 0 });
    const positive = positive_order != null and positive_order.? == .gt;
    for (rooted[0].array.items.items, 0..) |row, index| {
        rooted[4] = try runtime.createArray();
        if (row == .array) {
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
                for (row.array.items.items[0..prefix]) |item| _ = try rooted[4].array.push(item);
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
            for (row.array.items.items[suffix..]) |item| _ = try rooted[4].array.push(item);
        } else if (row == .string) {
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.string.len());
                rooted[5] = try runtime.stringCodeUnits(row.string.units[0..prefix]);
                _ = try rooted[4].array.push(rooted[5]);
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.string.len());
            rooted[5] = try runtime.stringCodeUnits(row.string.units[suffix..]);
            _ = try rooted[4].array.push(rooted[5]);
        } else return error.ArrayExpected;
        _ = try rooted[3].array.push(rooted[4]);
    }
    return rooted[3];
}

fn isObjectPrototypeKey(units: []const u16) bool {
    const keys = [_][]const u8{
        "constructor",
        "__defineGetter__",
        "__defineSetter__",
        "hasOwnProperty",
        "__lookupGetter__",
        "__lookupSetter__",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toString",
        "valueOf",
        "__proto__",
        "toLocaleString",
    };
    for (keys) |key| {
        if (units.len != key.len) continue;
        var matches = true;
        for (units, key) |unit, byte| if (unit != byte) {
            matches = false;
            break;
        };
        if (matches) return true;
    }
    return false;
}

fn tableDeleteColumn(runtime: *Runtime, source: Value, column_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, column_value, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    for (rooted[0].array.items.items) |row| {
        if (row != .array) return error.ArrayExpected;
        rooted[3] = try runtime.createArray();
        const column = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
        for (row.array.items.items, 0..) |item, index| {
            if (index != column) _ = try rooted[3].array.push(item);
        }
        _ = try rooted[2].array.push(rooted[3]);
    }
    return rooted[2];
}

fn tableColumnSum(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, column, .{ .number = 0 }, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    for (rooted[0].array.items.items) |row| {
        rooted[3] = try indexed(runtime, row, rooted[1]);
        rooted[2] = try operators.binary(runtime, .add, rooted[2], rooted[3]);
    }
    return rooted[2];
}

fn tableRegexpSearch(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    const start = spliceIndex(try runtime.valueToNumber(row_value), source.array.len());
    for (source.array.items.items[start..], start..) |row, index| if (try regexpMatches(runtime, try indexed(runtime, row, column), pattern)) return .{ .number = @floatFromInt(index) };
    return .{ .number = -1 };
}

fn tableRegexpPickup(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items) |row| if (try regexpMatches(runtime, try indexed(runtime, row, column), pattern)) {
        if (row != .array) return error.ArrayExpected;
        var copy = try runtime.createArray();
        try roots.protect(&copy);
        for (row.array.items.items) |item| _ = try copy.array.push(item);
        _ = try result.array.push(copy);
    };
    return result;
}

fn regexpMatches(runtime: *Runtime, source: Value, pattern: Value) !bool {
    const result = (try regexp.callWithEffects(runtime, "正規表現マッチ", &.{ source, pattern })).?;
    return result.value != .null_value;
}

fn indexed(runtime: *Runtime, source: Value, key: Value) !Value {
    var rooted = [3]Value{ source, key, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    if (rooted[0] == .null_value or rooted[0] == .undefined) return error.TableRowMissing;
    rooted[2] = try runtime.valueToString(rooted[1]);
    if (rooted[0] == .array) {
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].array.len()) };
        const index = propertyIndexUnits(rooted[2].string.units) orelse return .undefined;
        return rooted[0].array.get(index);
    }
    if (rooted[0] == .dictionary) return rooted[0].dictionary.get(rooted[2].string) orelse .undefined;
    if (rooted[0] == .string) {
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].string.len()) };
        const index = propertyIndexUnits(rooted[2].string.units) orelse return .undefined;
        if (index >= rooted[0].string.len()) return .undefined;
        return try runtime.stringCodeUnits(&.{rooted[0].string.units[index]});
    }
    if (rooted[0] == .bytes) {
        if (rooted[0].bytes.kind == .array_buffer) return .undefined;
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].bytes.bytes.len) };
        const index = propertyIndexUnits(rooted[2].string.units) orelse return .undefined;
        return rooted[0].bytes.get(index);
    }
    if (rooted[0] == .function and std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = 0 };
    return .undefined;
}

fn propertyIndexUnits(units: []const u16) ?usize {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, unit - '0') catch return null;
    }
    return result;
}

const Range = struct { start: usize, count: usize };

fn rangeBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
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
    const last_number = try runtime.valueToNumber(last_value);
    const end = spliceIndex(last_number + 1, length);
    if (end <= first) return .{ .start = first, .count = 0 };
    return .{ .start = first, .count = end - first };
}

fn spliceRangeBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
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

fn substringBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
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
    const last_number = try runtime.valueToNumber(last_value) + 1;
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

fn spliceIndex(number: f64, length: usize) usize {
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

fn directIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

fn propertyIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

fn charAtIndex(number: f64, length: usize) ?usize {
    if (std.math.isNan(number) or number == 0) return if (length > 0) 0 else null;
    if (!std.math.isFinite(number)) return null;
    const integer = @trunc(number);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(length))) return null;
    return @intFromFloat(integer);
}

fn positiveLength(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

fn fillLength(number: f64, maximum: usize) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(maximum))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@floor(number));
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "関数とPromiseの要素数はObject.keysと同じ0にする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name = try runtime.stringUtf8("F");
    try roots.protect(&name);
    var function = try runtime.createNativeFunction(name.string, 0, testElementCountFunction, &.{});
    try roots.protect(&function);
    var promise = try runtime.createPromise();
    try roots.protect(&promise);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "配列要素数", &.{function}, null)).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "LEN", &.{promise}, null)).?.number);
}

test "配列と表の破壊的操作・コピー・検索を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var array = try common.arrayFromValues(&runtime, &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 2 } });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    _ = (try call(&runtime, "配列数値ソート", &.{array}, null)).?;
    try std.testing.expectEqual(@as(f64, 1), array.array.get(0).number);
    _ = (try call(&runtime, "配列挿入", &.{ array, .{ .number = 1 }, .{ .number = 9 } }, null)).?;
    try std.testing.expectEqual(@as(f64, 9), array.array.get(1).number);
    const copy = (try call(&runtime, "配列範囲コピー", &.{ array, .{ .number = 1 } }, null)).?;
    try std.testing.expectEqual(@as(f64, 9), copy.number);
}

test "カスタムソート中に元配列が短縮されても収集済み要素を安全に書き戻す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var array = try common.arrayFromValues(&runtime, &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&array);
    var name = try runtime.stringUtf8("配列短縮比較");
    try roots.protect(&name);
    var function = try runtime.createNativeFunction(name.string, 2, testElementCountFunction, &.{});
    try roots.protect(&function);
    var test_context = TestMutatingSortContext{ .target = array.array };

    const result = (try call(&runtime, "配列カスタムソート", &.{ function, array }, .{
        .context = &test_context,
        .callFn = TestMutatingSortContext.invoke,
    })).?;

    try std.testing.expect(result.array == array.array);
    try std.testing.expect(test_context.mutated);
    try std.testing.expectEqual(@as(usize, 3), array.array.len());
    try std.testing.expectEqual(@as(f64, 1), array.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 2), array.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 3), array.array.get(2).number);
}

test "配列ソート系は安定な破壊的操作とundefined末尾を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var astral = try runtime.stringUtf8("😀");
    try roots.protect(&astral);
    var private_use = try runtime.stringCodeUnits(&.{0xe000});
    try roots.protect(&private_use);
    var ascii = try runtime.stringUtf8("A");
    try roots.protect(&ascii);
    var values = try common.arrayFromValues(&runtime, &.{ private_use, .undefined, astral, ascii });
    try roots.protect(&values);
    const sorted = (try call(&runtime, "配列ソート", &.{values}, null)).?;
    try std.testing.expectEqual(values.array, sorted.array);
    try std.testing.expectEqualSlices(u16, &.{'A'}, values.array.get(0).string.units);
    try std.testing.expectEqual(astral.string, values.array.get(1).string);
    try std.testing.expectEqual(private_use.string, values.array.get(2).string);
    try std.testing.expectEqual(Value.undefined, values.array.get(3));

    var numeric_text = try runtime.stringUtf8("2x");
    try roots.protect(&numeric_text);
    var numeric = try common.arrayFromValues(&runtime, &.{ numeric_text, .undefined, .{ .number = 10 }, .{ .number = std.math.nan(f64) }, .{ .number = -0.0 }, .{ .number = 0.0 } });
    try roots.protect(&numeric);
    const numeric_sorted = (try call(&runtime, "配列数値ソート", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, numeric_sorted.array);
    try std.testing.expect(isNegativeZero(numeric.array.get(0).number));
    try std.testing.expect(!isNegativeZero(numeric.array.get(1).number));
    try std.testing.expectEqual(numeric_text.string, numeric.array.get(2).string);
    try std.testing.expectEqual(@as(f64, 10), numeric.array.get(3).number);
    try std.testing.expect(std.math.isNan(numeric.array.get(4).number));
    try std.testing.expectEqual(Value.undefined, numeric.array.get(5));

    const converted = (try call(&runtime, "配列数値変換", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, converted.array);
    try std.testing.expectEqual(std.meta.Tag(Value).number, std.meta.activeTag(numeric.array.get(2)));
    const reversed = (try call(&runtime, "配列逆順", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, reversed.array);
    try std.testing.expect(std.math.isNan(numeric.array.get(0).number));
}

test "表検索系はlengthとraw開始値の型を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var length_key = try runtime.stringUtf8("length");
    try roots.protect(&length_key);
    var text_length = try runtime.stringUtf8("7");
    try roots.protect(&text_length);
    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    try dictionary.dictionary.set(length_key.string, text_length);
    var dictionary_table = try common.arrayFromValues(&runtime, &.{dictionary});
    try roots.protect(&dictionary_table);
    try std.testing.expectEqual(text_length.string, (try tableColumnCount(&runtime, dictionary_table)).string);

    var function_name = try runtime.stringUtf8("二引数");
    try roots.protect(&function_name);
    var function = try runtime.createNativeFunction(function_name.string, 2, testElementCountFunction, &.{});
    try roots.protect(&function);
    try std.testing.expectEqual(@as(f64, 0), (try indexed(&runtime, function, length_key)).number);

    var zero_text = try runtime.stringUtf8("zero");
    try roots.protect(&zero_text);
    var one_value_text = try runtime.stringUtf8("one");
    try roots.protect(&one_value_text);
    var two_value_text = try runtime.stringUtf8("two");
    try roots.protect(&two_value_text);
    var zero = try common.arrayFromValues(&runtime, &.{zero_text});
    try roots.protect(&zero);
    var one = try common.arrayFromValues(&runtime, &.{one_value_text});
    try roots.protect(&one);
    var two = try common.arrayFromValues(&runtime, &.{two_value_text});
    try roots.protect(&two);
    var table = try common.arrayFromValues(&runtime, &.{ zero, one, two });
    try roots.protect(&table);
    var one_text = try runtime.stringUtf8("1");
    try roots.protect(&one_text);
    var one_needle = try runtime.stringUtf8("one");
    try roots.protect(&one_needle);
    var two_needle = try runtime.stringUtf8("two");
    try roots.protect(&two_needle);
    try std.testing.expectEqual(one_text.string, (try tableSearch(&runtime, table, .{ .number = 0 }, one_text, one_needle)).string);
    try std.testing.expectEqual(@as(f64, 2), (try tableSearch(&runtime, table, .{ .number = 0 }, one_text, two_needle)).number);
    var one_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&one_bigint);
    try std.testing.expectEqual(@as(i64, 1), (try tableSearch(&runtime, table, .{ .number = 0 }, one_bigint, one_needle)).bigint.toI64());
    try std.testing.expectEqual(@as(i64, 2), (try tableSearch(&runtime, table, .{ .number = 0 }, one_bigint, two_needle)).bigint.toI64());
    var object_start = try runtime.createDictionary();
    try roots.protect(&object_start);
    try std.testing.expectEqual(@as(f64, -1), (try tableSearch(&runtime, table, .{ .number = 0 }, object_start, one_needle)).number);

    var buffer = try runtime.createBytes(&.{ 85, 9 });
    try roots.protect(&buffer);
    var buffer_table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&buffer_table);
    try std.testing.expectEqual(@as(f64, 2), (try tableColumnCount(&runtime, buffer_table)).number);
    try std.testing.expectEqual(@as(f64, 85), (try indexed(&runtime, buffer, .{ .number = 0 })).number);
    try std.testing.expectEqual(@as(f64, 0), (try tableSearch(&runtime, buffer_table, .{ .number = 0 }, .{ .number = 0 }, .{ .number = 85 })).number);

    var array_buffer = try runtime.createArrayBuffer(&.{ 85, 9 });
    try roots.protect(&array_buffer);
    try std.testing.expect((try indexed(&runtime, array_buffer, length_key)) == .undefined);
}

test "表変換系はGCストレス下で文字列行とJSキー規則を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var text_row = try runtime.stringUtf8("abc");
    try roots.protect(&text_row);
    var table = try common.arrayFromValues(&runtime, &.{text_row});
    try roots.protect(&table);
    var values = try runtime.stringUtf8("Z");
    try roots.protect(&values);
    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    try std.testing.expectEqual(@as(usize, 3), inserted.array.get(0).array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, inserted.array.get(0).array.get(0).string.units);
    try std.testing.expectEqualSlices(u16, &.{'Z'}, inserted.array.get(0).array.get(1).string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'c' }, inserted.array.get(0).array.get(2).string.units);

    var prototype = try runtime.stringUtf8("__proto__");
    try roots.protect(&prototype);
    var ordinary = try runtime.stringUtf8("a");
    try roots.protect(&ordinary);
    var prototype_row = try common.arrayFromValues(&runtime, &.{prototype});
    try roots.protect(&prototype_row);
    var ordinary_row = try common.arrayFromValues(&runtime, &.{ordinary});
    try roots.protect(&ordinary_row);
    var duplicate_row = try common.arrayFromValues(&runtime, &.{ordinary});
    try roots.protect(&duplicate_row);
    var duplicate_table = try common.arrayFromValues(&runtime, &.{ prototype_row, ordinary_row, duplicate_row });
    try roots.protect(&duplicate_table);
    var unique = try tableUnique(&runtime, duplicate_table, .{ .number = 0 });
    try roots.protect(&unique);
    try std.testing.expectEqual(@as(usize, 1), unique.array.len());
    try std.testing.expect(unique.array.get(0).array == ordinary_row.array);

    var x = try runtime.stringUtf8("x");
    try roots.protect(&x);
    var y = try runtime.stringUtf8("y");
    try roots.protect(&y);
    var x_row = try common.arrayFromValues(&runtime, &.{x});
    try roots.protect(&x_row);
    var y_row = try common.arrayFromValues(&runtime, &.{y});
    try roots.protect(&y_row);
    var sum_table = try common.arrayFromValues(&runtime, &.{ x_row, y_row });
    try roots.protect(&sum_table);
    var column_sum = try tableColumnSum(&runtime, sum_table, .{ .number = 0 });
    try roots.protect(&column_sum);
    try std.testing.expectEqualSlices(u16, &.{ '0', 'x', 'y' }, column_sum.string.units);

    var empty = try runtime.createArray();
    try roots.protect(&empty);
    var bigint_index = try runtime.bigIntLiteral("1n");
    try roots.protect(&bigint_index);
    var empty_insert = try tableInsertColumn(&runtime, empty, bigint_index, .null_value);
    try roots.protect(&empty_insert);
    try std.testing.expectEqual(@as(usize, 0), empty_insert.array.len());
}

test "配列コピーと参照はJSONとJavaScript添字の境界を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var clone_failed = false;
    _ = deepClone(&runtime, .undefined) catch {
        clone_failed = true;
    };
    try std.testing.expect(clone_failed);

    var source = try common.arrayFromValues(&runtime, &.{.undefined});
    try roots.protect(&source);
    var range = try runtime.createDictionary();
    try roots.protect(&range);
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, .{ .number = 0 });
    var copied = try rangeCopy(&runtime, source, range);
    try roots.protect(&copied);
    try std.testing.expectEqual(Value.null_value, copied.array.get(0));

    var text = try runtime.stringUtf8("ABC");
    try roots.protect(&text);
    var character = try reference(&runtime, text, .{ .number = 1.9 });
    try roots.protect(&character);
    try std.testing.expectEqualSlices(u16, &.{'B'}, character.string.units);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, source, .{ .number = 0.9 }));

    try range.dictionary.set(first_key.string, .{ .number = 1e100 });
    try range.dictionary.set(last_key.string, .{ .number = 1e100 });
    var empty = try reference(&runtime, text, range);
    try roots.protect(&empty);
    try std.testing.expectEqual(@as(usize, 0), empty.string.len());

    var cut_source = try common.arrayFromValues(&runtime, &.{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    try roots.protect(&cut_source);
    try range.dictionary.set(first_key.string, .{ .number = -2 });
    try range.dictionary.set(last_key.string, .{ .number = -1 });
    var removed = try cut(&runtime, cut_source, range);
    try roots.protect(&removed);
    try std.testing.expectEqual(@as(f64, 2), removed.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), removed.array.get(1).number);
    try std.testing.expectEqual(@as(usize, 2), cut_source.array.len());

    _ = range.dictionary.remove(last_key.string);
    try range.dictionary.set(first_key.string, .{ .number = 1 });
    var missing_last_copy = try rangeCopy(&runtime, source, range);
    try roots.protect(&missing_last_copy);
    try std.testing.expectEqual(@as(usize, 0), missing_last_copy.array.len());
    try range.dictionary.set(first_key.string, .{ .number = 2 });
    var missing_last_text = try reference(&runtime, text, range);
    try roots.protect(&missing_last_text);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, missing_last_text.string.units);
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
    try std.testing.expectError(error.ArraySizeLimitExceeded, swap(swap_source, .{ .number = 0 }, .{ .number = @floatFromInt(safe_array_element_limit) }));

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
    try std.testing.expectError(error.ArraySizeLimitExceeded, sequence(&runtime, .{ .number = 0 }, .{ .number = std.math.inf(f64) }));
    try std.testing.expectError(error.ArraySizeLimitExceeded, sequence(&runtime, .{ .number = -std.math.inf(f64) }, .{ .number = -1 }));

    var empty_shape = try runtime.createArray();
    try roots.protect(&empty_shape);
    var empty_fill = try fill(&runtime, .{ .number = 7 }, empty_shape);
    try roots.protect(&empty_fill);
    try std.testing.expectEqual(@as(usize, 0), empty_fill.array.len());
    var undefined_fill = try fill(&runtime, .undefined, .{ .number = 2 });
    try roots.protect(&undefined_fill);
    try std.testing.expectEqual(Value.undefined, undefined_fill.array.get(0));
    try std.testing.expectEqual(Value.undefined, undefined_fill.array.get(1));
    try std.testing.expectError(error.ArraySizeLimitExceeded, fill(&runtime, .{ .number = 0 }, .{ .number = std.math.inf(f64) }));

    var huge_shape = try common.arrayFromValues(&runtime, &.{ .{ .number = @floatFromInt(safe_array_element_limit) }, .{ .number = 2 } });
    try roots.protect(&huge_shape);
    try std.testing.expectError(error.ArraySizeLimitExceeded, fill(&runtime, .{ .number = 0 }, huge_shape));
    var nested_value = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&nested_value);
    var independent_fill = try fill(&runtime, nested_value, .{ .number = 2 });
    try roots.protect(&independent_fill);
    try independent_fill.array.get(0).array.set(0, .{ .number = 9 });
    try std.testing.expectEqual(@as(f64, 1), independent_fill.array.get(1).array.get(0).number);
}
