const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const operators = @import("../../runtime/operators.zig");
const common = @import("common.zig");
const json = @import("json.zig");
const regexp = @import("regexp.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const ByteKind = value_mod.ByteKind;

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
    if (eql(name, "配列入替")) return try swap(runtime, a, b, c);
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
    for (source.array.items.items, 0..) |item, index| {
        if (!source.array.isPresent(index)) continue;
        if (Value.strictEqual(item, needle)) return @intCast(index);
    }
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

const ZeroRandomContext = struct {
    fn next(_: *anyopaque) anyerror!f64 {
        return 0;
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

    try array.normalizePresence();

    // Allocate initialized scratch storage before sorting. This avoids O(n^2)
    // behavior and prevents OOM from exposing an uninitialized array slot.
    var source_root = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    const temporary = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(temporary);
    const temporary_presence = try runtime.allocator().dupe(bool, array.presence.items);
    defer runtime.allocator().free(temporary_presence);
    for (temporary) |*item| try roots.protect(item);

    var width: usize = 1;
    var from_source = true;
    while (width < array.items.items.len) : (width = std.math.mul(usize, width, 2) catch array.items.items.len) {
        const input = if (from_source) array.items.items else temporary;
        const output = if (from_source) temporary else array.items.items;
        const input_presence = if (from_source) array.presence.items else temporary_presence;
        const output_presence = if (from_source) temporary_presence else array.presence.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareForSort(runtime, input[left], input_presence[left], input[right], input_presence[right], mode, callback);
                if (order == .gt) {
                    output[destination] = input[right];
                    output_presence[destination] = input_presence[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    output_presence[destination] = input_presence[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) {
                output[destination] = input[left];
                output_presence[destination] = input_presence[left];
            }
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) {
                output[destination] = input[right];
                output_presence[destination] = input_presence[right];
            }
            start = end;
        }
        from_source = !from_source;
    }
    if (!from_source) {
        std.mem.copyForwards(Value, array.items.items, temporary);
        std.mem.copyForwards(bool, array.presence.items, temporary_presence);
    }
}

fn stableCallbackSort(runtime: *Runtime, array: *value_mod.Array, callback: SortCallback) !void {
    // ECMAScript collects the indexed values before invoking the comparator.
    // Keep both merge buffers detached from the live array so a callback may
    // resize or reallocate that array without invalidating an active slice.
    const original_length = array.len();
    try array.normalizePresence();
    const first = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(first);
    const second = try runtime.allocator().dupe(Value, first);
    defer runtime.allocator().free(second);
    const first_presence = try runtime.allocator().dupe(bool, array.presence.items);
    defer runtime.allocator().free(first_presence);
    const second_presence = try runtime.allocator().dupe(bool, first_presence);
    defer runtime.allocator().free(second_presence);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (first) |*item| try roots.protect(item);
    for (second) |*item| try roots.protect(item);

    var width: usize = 1;
    var from_first = true;
    while (width < original_length) : (width = std.math.mul(usize, width, 2) catch original_length) {
        const input = if (from_first) first else second;
        const output = if (from_first) second else first;
        const input_presence = if (from_first) first_presence else second_presence;
        const output_presence = if (from_first) second_presence else first_presence;
        var start: usize = 0;
        while (start < original_length) {
            const middle = @min(std.math.add(usize, start, width) catch original_length, original_length);
            const end = @min(std.math.add(usize, middle, width) catch original_length, original_length);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareForSort(runtime, input[left], input_presence[left], input[right], input_presence[right], .callback, callback);
                if (order == .gt) {
                    output[destination] = input[right];
                    output_presence[destination] = input_presence[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    output_presence[destination] = input_presence[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) {
                output[destination] = input[left];
                output_presence[destination] = input_presence[left];
            }
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) {
                output[destination] = input[right];
                output_presence[destination] = input_presence[right];
            }
            start = end;
        }
        from_first = !from_first;
    }

    if (array.len() < original_length) {
        const old_length = array.len();
        try array.items.resize(runtime.allocator(), original_length);
        @memset(array.items.items[old_length..], .undefined);
        try array.presence.resize(runtime.allocator(), original_length);
        @memset(array.presence.items[old_length..], false);
    }
    const sorted = if (from_first) first else second;
    std.mem.copyForwards(Value, array.items.items[0..original_length], sorted);
    const sorted_presence = if (from_first) first_presence else second_presence;
    std.mem.copyForwards(bool, array.presence.items[0..original_length], sorted_presence);
}

fn compareForSort(runtime: *Runtime, left: Value, left_present: bool, right: Value, right_present: bool, mode: SortMode, callback: ?SortCallback) !std.math.Order {
    // ECMAScript Array#sort places undefined after all defined values without
    // invoking the comparator. Holes are not collected by the spec, so they
    // remain after explicit undefined.
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
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
    try source.array.normalizePresence();
    std.mem.reverse(Value, source.array.items.items);
    std.mem.reverse(bool, source.array.presence.items);
    return source;
}

fn shuffle(source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.normalizePresence();
    var index = source.array.len();
    while (index > 1) {
        index -= 1;
        const random_index: usize = @intFromFloat(@floor(try Context.random(context) * @as(f64, @floatFromInt(index + 1))));
        std.mem.swap(Value, &source.array.items.items[index], &source.array.items.items[random_index]);
        // The upstream implementation performs two indexed assignments.
        // Reading a hole yields undefined, but either assignment materializes
        // its target property even when the source side was absent.
        source.array.presence.items[index] = true;
        source.array.presence.items[random_index] = true;
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
    try array.normalizePresence();
    for (0..actual) |_| {
        const was_present = array.isPresent(start);
        const value = array.remove(start);
        const result_length = try result.array.push(value);
        if (!was_present) _ = try result.array.deleteIndex(result_length - 1);
    }
    return result;
}

fn appendArraySlot(array: *value_mod.Array, value: Value, present: bool) !void {
    const length = try array.push(value);
    if (!present) _ = try array.deleteIndex(length - 1);
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

fn reference(runtime: *Runtime, source: Value, index_value: Value) !Value {
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
    if (source_value == .dictionary) {
        var key = try runtime.valueToString(index);
        try roots.protect(&key);
        if (source_value.dictionary.get(key.string)) |value| return value;
        if (try tableInheritedProperty(runtime, source_value, key.string.units)) |value| return value;
        return .undefined;
    }
    return error.IndexableValueExpected;
}

fn bigIntPropertyIndex(value: *value_mod.BigInt, length: usize) ?usize {
    const integer = value.toI64() catch return null;
    if (integer < 0) return null;
    const index = std.math.cast(usize, integer) orelse return null;
    return if (index < length) index else null;
}

fn invalidStringRange(runtime: *Runtime, index: Value) !Value {
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

fn arrayAdd(runtime: *Runtime, source: Value, other: Value) !Value {
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

fn reduceExtremum(runtime: *Runtime, source: Value, maximum: bool) !Value {
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

fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

fn sum(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result: f64 = 0;
    for (source.array.items.items, 0..) |item, index| {
        if (!source.array.isPresent(index)) continue;
        const number = try common.parseFloatValue(runtime, item);
        if (!std.math.isNan(number)) result += number;
    }
    return .{ .number = result };
}

fn swap(runtime: *Runtime, source: Value, first_value: Value, second_value: Value) !Value {
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
        const required_length = std.math.add(usize, index, 1) catch return error.ArraySizeLimitExceeded;
        if (required_length > rooted[0].array.len() and required_length > safe_array_element_limit) return error.ArraySizeLimitExceeded;
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
    var rooted_source = source;
    var rooted_column = column;
    var row: Value = .undefined;
    var left_cell: Value = .undefined;
    var right_cell: Value = .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_column);
    try roots.protect(&row);
    try roots.protect(&left_cell);
    try roots.protect(&right_cell);
    try rooted_source.array.normalizePresence();
    var index: usize = 1;
    while (index < rooted_source.array.len()) : (index += 1) {
        row = rooted_source.array.items.items[index];
        const row_present = rooted_source.array.isPresent(index);
        var cursor = index;
        while (cursor > 0) {
            const order = try compareTableRows(
                runtime,
                rooted_source.array.items.items[cursor - 1],
                rooted_source.array.isPresent(cursor - 1),
                row,
                row_present,
                rooted_column,
                numeric,
                &left_cell,
                &right_cell,
            );
            if (order != .gt) break;
            rooted_source.array.items.items[cursor] = rooted_source.array.items.items[cursor - 1];
            rooted_source.array.presence.items[cursor] = rooted_source.array.presence.items[cursor - 1];
            cursor -= 1;
        }
        rooted_source.array.items.items[cursor] = row;
        rooted_source.array.presence.items[cursor] = row_present;
    }
    return rooted_source;
}

fn compareTableRows(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    column: Value,
    numeric: bool,
    left_cell: *Value,
    right_cell: *Value,
) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left == .undefined) return if (right == .undefined) .eq else .gt;
    if (right == .undefined) return .lt;
    left_cell.* = try indexed(runtime, left, column);
    right_cell.* = try indexed(runtime, right, column);
    if (numeric) {
        const left_number = try runtime.valueToNumber(left_cell.*);
        const right_number = try runtime.valueToNumber(right_cell.*);
        return if (std.math.isNan(left_number) or std.math.isNan(right_number)) .eq else std.math.order(left_number, right_number);
    }
    return (try operators.compare(runtime, left_cell.*, right_cell.*)) orelse .eq;
}

fn tablePickup(runtime: *Runtime, source: Value, column: Value, needle: Value, exact: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [7]Value{ source, column, needle, .undefined, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.createArray();
    if (!exact) rooted[4] = try runtime.valueToString(rooted[2]);
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        // Array.prototype.filter skips holes but invokes the callback for an
        // explicit undefined row, which then fails during row[index].
        if (!rooted[0].array.isPresent(index)) continue;
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
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        if (rooted[0].array.isPresent(index)) {
            _ = try rooted[2].array.push(try indexed(runtime, row, rooted[1]));
        } else {
            try appendArraySlot(rooted[2].array, .undefined, false);
        }
    }
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
    try rooted[0].array.normalizePresence();
    const positive_order = try operators.compare(runtime, rooted[1], .{ .number = 0 });
    const positive = positive_order != null and positive_order.? == .gt;
    for (rooted[0].array.items.items, 0..) |row, index| {
        // Array.prototype.forEach skips holes in the outer table.  An
        // explicit undefined row remains observable and therefore follows
        // the existing row-type error path below.
        if (!rooted[0].array.isPresent(index)) continue;
        rooted[4] = try runtime.createArray();
        if (row == .array) {
            try row.array.normalizePresence();
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
                for (row.array.items.items[0..prefix], 0..) |item, row_index| try appendArraySlot(rooted[4].array, item, row.array.isPresent(row_index));
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
            for (row.array.items.items[suffix..], suffix..) |item, row_index| try appendArraySlot(rooted[4].array, item, row.array.isPresent(row_index));
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
        } else if (row == .bytes) {
            const length = row.bytes.bytes.len;
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), length);
                rooted[5] = try byteBufferSlice(runtime, row.bytes, 0, prefix);
                _ = try rooted[4].array.push(rooted[5]);
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), length);
            rooted[5] = try byteBufferSlice(runtime, row.bytes, suffix, length);
            _ = try rooted[4].array.push(rooted[5]);
        } else return error.ArrayExpected;
        _ = try rooted[3].array.push(rooted[4]);
    }
    return rooted[3];
}

fn byteBufferSlice(runtime: *Runtime, buffer: *value_mod.ByteBuffer, start: usize, end: usize) !Value {
    const bytes = buffer.bytes[start..end];
    return switch (buffer.kind) {
        .buffer => runtime.createByteBufferView(buffer, start, end),
        .uint8_array => runtime.createUint8Array(bytes),
        .array_buffer => runtime.createArrayBuffer(bytes),
    };
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

const objectPrototypeMethodNames = [_][]const u8{
    "__defineGetter__",
    "__defineSetter__",
    "hasOwnProperty",
    "__lookupGetter__",
    "__lookupSetter__",
    "isPrototypeOf",
    "propertyIsEnumerable",
    "toLocaleString",
    "toString",
    "valueOf",
};

const functionPrototypeMethodNames = [_][]const u8{ "apply", "bind", "call" };

const arrayPrototypeMethodNames = [_][]const u8{
    "at",
    "concat",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "flat",
    "flatMap",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "pop",
    "push",
    "reduce",
    "reduceRight",
    "reverse",
    "shift",
    "slice",
    "some",
    "sort",
    "splice",
    "unshift",
    "values",
    "with",
};

const stringPrototypeMethodNames = [_][]const u8{
    "anchor",
    "at",
    "big",
    "blink",
    "bold",
    "charAt",
    "charCodeAt",
    "codePointAt",
    "concat",
    "endsWith",
    "fixed",
    "fontcolor",
    "fontsize",
    "includes",
    "indexOf",
    "isWellFormed",
    "italics",
    "lastIndexOf",
    "link",
    "localeCompare",
    "match",
    "matchAll",
    "normalize",
    "padEnd",
    "padStart",
    "repeat",
    "replace",
    "replaceAll",
    "search",
    "slice",
    "small",
    "split",
    "startsWith",
    "strike",
    "sub",
    "substr",
    "substring",
    "toLocaleLowerCase",
    "toLocaleUpperCase",
    "toLowerCase",
    "toUpperCase",
    "toWellFormed",
    "trim",
    "trimEnd",
    "trimLeft",
    "trimRight",
    "trimStart",
};

const byteBufferTypedArrayMethodNames = [_][]const u8{
    "at",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "reverse",
    "reduce",
    "reduceRight",
    "set",
    "slice",
    "some",
    "sort",
    "subarray",
    "toReversed",
    "toSorted",
    "values",
    "with",
};

const byteBufferBufferMethodNames = [_][]const u8{
    "copy",
    "equals",
    "inspect",
    "compare",
    "write",
    "toJSON",
    "swap16",
    "swap32",
    "swap64",
};

const byteBufferArrayBufferMethodNames = [_][]const u8{
    "slice",
    "resize",
    "transfer",
    "transferToFixedLength",
};

fn asciiUnitsEqual(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

fn inheritedMethodName(units: []const u16, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (asciiUnitsEqual(units, name)) return name;
    return null;
}

fn tableInheritedFunction(runtime: *Runtime, name: []const u8) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var function_name = try runtime.stringUtf8(name);
    try roots.protect(&function_name);
    return runtime.createNativeFunction(function_name.string, 0, tableInheritedFunctionSentinel, &.{});
}

fn tableInheritedFunctionSentinel(_: *Runtime, _: []const Value) !Value {
    return .undefined;
}

fn tableInheritedProperty(runtime: *Runtime, source: Value, units: []const u16) !?Value {
    if (asciiUnitsEqual(units, "__proto__")) {
        return switch (source) {
            .dictionary => @as(?Value, try runtime.createDictionary()),
            .array => @as(?Value, try runtime.createArray()),
            .string => @as(?Value, try runtime.stringCodeUnits(&.{})),
            .function => @as(?Value, try tableInheritedFunction(runtime, "")),
            else => null,
        };
    }

    if (asciiUnitsEqual(units, "prototype") and source == .function) {
        return switch (source.function.kind) {
            .ir => @as(?Value, try runtime.createDictionary()),
            .native, .external => null,
        };
    }

    const constructor_name: ?[]const u8 = switch (source) {
        .dictionary => "Object",
        .array => "Array",
        .string => "String",
        .function => "Function",
        .number => "Number",
        .boolean => "Boolean",
        .bigint => "BigInt",
        .bytes => switch (source.bytes.kind) {
            .buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .array_buffer => "ArrayBuffer",
        },
        else => null,
    };
    if (constructor_name) |name| if (asciiUnitsEqual(units, "constructor")) return @as(?Value, try tableInheritedFunction(runtime, name));

    if (source == .bytes) {
        const buffer = source.bytes;
        if (asciiUnitsEqual(units, "byteLength")) return @as(?Value, .{ .number = @floatFromInt(buffer.bytes.len) });
        if (asciiUnitsEqual(units, "byteOffset")) {
            if (buffer.kind == .array_buffer) return null;
            const offset = if (buffer.bytes.len == 0) 0 else @intFromPtr(buffer.bytes.ptr) - @intFromPtr(buffer.storage.bytes.ptr);
            return @as(?Value, .{ .number = @floatFromInt(offset) });
        }
        if (asciiUnitsEqual(units, "BYTES_PER_ELEMENT")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, .{ .number = 1 });
        }
        if (asciiUnitsEqual(units, "buffer")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
        }
        if (buffer.kind == .array_buffer) {
            if (asciiUnitsEqual(units, "maxByteLength")) return @as(?Value, .{ .number = @floatFromInt(buffer.bytes.len) });
            if (asciiUnitsEqual(units, "resizable") or asciiUnitsEqual(units, "detached")) return @as(?Value, .{ .boolean = false });
            if (inheritedMethodName(units, &byteBufferArrayBufferMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
        } else {
            if (inheritedMethodName(units, &byteBufferTypedArrayMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
            if (buffer.kind == .buffer) {
                if (inheritedMethodName(units, &byteBufferBufferMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
                if (asciiUnitsEqual(units, "toLocaleString")) return @as(?Value, try tableInheritedFunction(runtime, "toString"));
            }
        }
    }

    if (inheritedMethodName(units, &objectPrototypeMethodNames)) |name| {
        if (source == .dictionary or source == .array or source == .string or source == .function or
            source == .number or source == .boolean or source == .bigint or source == .bytes) return @as(?Value, try tableInheritedFunction(runtime, name));
    }
    if (source == .function) {
        if (inheritedMethodName(units, &functionPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
    }
    if (source == .array) {
        if (inheritedMethodName(units, &arrayPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
    }
    if (source == .string) {
        if (inheritedMethodName(units, &stringPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, name));
    }
    return null;
}

pub fn hasStandardInheritedProperty(runtime: *Runtime, source: Value, units: []const u16) !bool {
    return (try tableInheritedProperty(runtime, source, units)) != null;
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

    var number_constructor = try indexed(&runtime, .{ .number = 1 }, constructor_key);
    try roots.protect(&number_constructor);
    var number_constructor_name = try indexed(&runtime, number_constructor, name_key);
    try roots.protect(&number_constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'N', 'u', 'm', 'b', 'e', 'r' }, number_constructor_name.string.units);
}

test "参照は辞書と配列の標準prototype propertyを解決する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    var array = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&array);
    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);
    var constructor_key = try runtime.stringUtf8("constructor");
    try roots.protect(&constructor_key);
    var proto_key = try runtime.stringUtf8("__proto__");
    try roots.protect(&proto_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);

    var dictionary_method = try reference(&runtime, dictionary, to_string_key);
    try roots.protect(&dictionary_method);
    try std.testing.expect(dictionary_method == .function);
    var dictionary_constructor = try reference(&runtime, dictionary, constructor_key);
    try roots.protect(&dictionary_constructor);
    try std.testing.expect(dictionary_constructor == .function);
    var dictionary_constructor_name = try indexed(&runtime, dictionary_constructor, name_key);
    try roots.protect(&dictionary_constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'O', 'b', 'j', 'e', 'c', 't' }, dictionary_constructor_name.string.units);
    var dictionary_proto = try reference(&runtime, dictionary, proto_key);
    try roots.protect(&dictionary_proto);
    try std.testing.expect(dictionary_proto == .dictionary);

    var array_method = try reference(&runtime, array, map_key);
    try roots.protect(&array_method);
    try std.testing.expect(array_method == .function);
    var alias_method = (try call(&runtime, "配列参照", &.{ array, to_string_key }, null)).?;
    try roots.protect(&alias_method);
    try std.testing.expect(alias_method == .function);

    try dictionary.dictionary.set(to_string_key.string, .{ .number = 7 });
    var own_value = try reference(&runtime, dictionary, to_string_key);
    try roots.protect(&own_value);
    try std.testing.expectEqual(@as(f64, 7), own_value.number);
}

fn tableDeleteColumn(runtime: *Runtime, source: Value, column_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, column_value, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, row_index| {
        if (!rooted[0].array.isPresent(row_index)) continue;
        if (row != .array) return error.ArrayExpected;
        rooted[3] = try runtime.createArray();
        try row.array.normalizePresence();
        const column = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
        for (row.array.items.items, 0..) |item, index| {
            if (index != column) try appendArraySlot(rooted[3].array, item, row.array.isPresent(index));
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
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        if (!rooted[0].array.isPresent(index)) continue;
        rooted[3] = try indexed(runtime, row, rooted[1]);
        rooted[2] = try operators.binary(runtime, .add, rooted[2], rooted[3]);
    }
    return rooted[2];
}

fn tableRegexpSearch(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [8]Value{ source, row_value, column, pattern, row_value, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    // The upstream command constructs RegExp before entering the loop.  This
    // makes an invalid pattern fail even when the table is empty or the raw
    // start value is already out of range.
    rooted[7] = if (rooted[3] == .undefined) try runtime.stringCodeUnits(&.{}) else try runtime.valueToString(rooted[3]);
    var compiled = try regexp.RawPattern.init(runtime.allocator(), rooted[7].string.units, false);
    defer compiled.deinit();
    while ((try operators.compare(runtime, rooted[4], .{ .number = @floatFromInt(rooted[0].array.len()) })) == .lt) {
        rooted[5] = try indexed(runtime, rooted[0], rooted[4]);
        rooted[6] = try indexed(runtime, rooted[5], rooted[2]);
        rooted[6] = try runtime.valueToString(rooted[6]);
        if (try compiled.matches(rooted[6].string.units)) return rooted[4];
        rooted[4] = try incrementTableSearchRow(runtime, rooted[4]);
    }
    return .{ .number = -1 };
}

fn tableRegexpPickup(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [8]Value{ source, column, pattern, .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[6] = if (rooted[2] == .undefined) try runtime.stringCodeUnits(&.{}) else try runtime.valueToString(rooted[2]);
    var compiled = try regexp.RawPattern.init(runtime.allocator(), rooted[6].string.units, false);
    defer compiled.deinit();
    rooted[3] = try runtime.createArray();
    for (rooted[0].array.items.items) |row| {
        rooted[4] = try indexed(runtime, row, rooted[1]);
        rooted[7] = try runtime.valueToString(rooted[4]);
        if (!(try compiled.matches(rooted[7].string.units))) continue;
        rooted[5] = switch (row) {
            .array => blk: {
                const copy = try runtime.createArray();
                rooted[5] = copy;
                for (row.array.items.items) |item| _ = try rooted[5].array.push(item);
                break :blk rooted[5];
            },
            .string => row,
            .bytes => |buffer| switch (buffer.kind) {
                .buffer => try runtime.createByteBufferView(buffer, 0, buffer.bytes.len),
                .uint8_array => try runtime.createUint8Array(buffer.bytes),
                .array_buffer => try runtime.createArrayBuffer(buffer.bytes),
            },
            else => return error.ArrayExpected,
        };
        _ = try rooted[3].array.push(rooted[5]);
    }
    return rooted[3];
}

fn arrayPropertyGet(array: *value_mod.Array, key: *value_mod.String, index: ?usize) Value {
    if (index) |position| return array.get(position);
    if (std.mem.eql(u16, key.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(array.len()) };
    return array.getProperty(key) orelse .undefined;
}

fn arrayPropertySet(array: *value_mod.Array, key: *value_mod.String, index: ?usize, value: Value) !void {
    if (index) |position| return array.set(position, value);
    if (std.mem.eql(u16, key.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    return array.setProperty(key, value);
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
        if (rooted[0].bytes.kind != .array_buffer and std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(rooted[0].bytes.bytes.len) };
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

fn propertyIndexUnits(units: []const u16) ?usize {
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
    const last_number = try runtime.valueToExplicitRangeNumber(last_value);
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

fn appendAsciiUnits(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

fn appendUtf8Units(output: *std.ArrayList(u16), allocator: std.mem.Allocator, text: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try output.appendSlice(allocator, units);
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

test "疎配列の順序操作は値とpresenceの公式境界を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var sorted = try runtime.createArray();
    try roots.protect(&sorted);
    try sorted.array.set(0, .{ .number = 3 });
    try sorted.array.set(2, .{ .number = 1 });
    try sorted.array.set(3, .undefined);
    _ = try call(&runtime, "配列ソート", &.{sorted}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, sorted.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), sorted.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), sorted.array.get(1).number);
    try std.testing.expectEqual(Value.undefined, sorted.array.get(2));
    try std.testing.expectEqual(Value.undefined, sorted.array.get(3));

    var numeric = try runtime.createArray();
    try roots.protect(&numeric);
    try numeric.array.set(0, .{ .number = 10 });
    try numeric.array.set(2, .{ .number = 2 });
    try numeric.array.set(3, .undefined);
    _ = try call(&runtime, "配列数値ソート", &.{numeric}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, numeric.array.presence.items);
    try std.testing.expectEqual(@as(f64, 2), numeric.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 10), numeric.array.get(1).number);
    try std.testing.expectEqual(Value.undefined, numeric.array.get(2));

    var converted = try runtime.createArray();
    try roots.protect(&converted);
    try converted.array.set(0, .undefined);
    try converted.array.set(2, .{ .number = 4 });
    _ = try call(&runtime, "配列数値変換", &.{converted}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, converted.array.presence.items);
    try std.testing.expect(std.math.isNan(converted.array.get(0).number));
    try std.testing.expect(std.math.isNan(converted.array.get(1).number));
    try std.testing.expectEqual(@as(f64, 4), converted.array.get(2).number);

    var reversed = try runtime.createArray();
    try roots.protect(&reversed);
    try reversed.array.set(0, .{ .number = 1 });
    try reversed.array.set(2, .{ .number = 3 });
    _ = try call(&runtime, "配列逆順", &.{reversed}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, reversed.array.presence.items);
    try std.testing.expectEqual(@as(f64, 3), reversed.array.get(0).number);
    try std.testing.expectEqual(Value.undefined, reversed.array.get(1));
    try std.testing.expectEqual(@as(f64, 1), reversed.array.get(2).number);

    var shuffled = try runtime.createArray();
    try roots.protect(&shuffled);
    try shuffled.array.set(0, .{ .number = 1 });
    try shuffled.array.set(2, .{ .number = 3 });
    var random_state: u8 = 0;
    _ = try call(&runtime, "配列シャッフル", &.{shuffled}, .{
        .context = &random_state,
        .randomFn = ZeroRandomContext.next,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, shuffled.array.presence.items);
    try std.testing.expectEqual(Value.undefined, shuffled.array.get(0));
    try std.testing.expectEqual(@as(f64, 3), shuffled.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 1), shuffled.array.get(2).number);
}

test "疎配列のsplice系操作は削除側と戻り値側のpresenceを移動する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var removed_source = try runtime.createArray();
    try roots.protect(&removed_source);
    try removed_source.array.set(0, .{ .number = 1 });
    try removed_source.array.set(2, .{ .number = 3 });
    const removed = (try call(&runtime, "配列削除", &.{ removed_source, .{ .number = 1 } }, null)).?;
    try std.testing.expectEqual(Value.undefined, removed);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, removed_source.array.presence.items);
    try std.testing.expectEqual(@as(f64, 3), removed_source.array.get(1).number);

    var taken_source = try runtime.createArray();
    try roots.protect(&taken_source);
    try taken_source.array.set(0, .{ .number = 1 });
    try taken_source.array.set(2, .{ .number = 3 });
    const taken = (try call(&runtime, "配列取出", &.{ taken_source, .{ .number = 1 }, .{ .number = 2 } }, null)).?;
    try std.testing.expectEqualSlices(bool, &.{ false, true }, taken.array.presence.items);
    try std.testing.expectEqual(Value.undefined, taken.array.get(0));
    try std.testing.expectEqual(@as(f64, 3), taken.array.get(1).number);
    try std.testing.expectEqualSlices(bool, &.{true}, taken_source.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), taken_source.array.get(0).number);

    var inserted = try runtime.createArray();
    try roots.protect(&inserted);
    try inserted.array.set(0, .{ .number = 1 });
    try inserted.array.set(2, .{ .number = 3 });
    _ = try call(&runtime, "配列挿入", &.{ inserted, .{ .number = 1 }, .{ .number = 9 } }, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, inserted.array.presence.items);
    try std.testing.expectEqual(@as(f64, 9), inserted.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 3), inserted.array.get(3).number);

    var bulk = try runtime.createArray();
    try roots.protect(&bulk);
    try bulk.array.set(0, .{ .number = 1 });
    try bulk.array.set(2, .{ .number = 3 });
    var values = try runtime.createArray();
    try roots.protect(&values);
    try values.array.set(1, .{ .number = 7 });
    _ = try call(&runtime, "配列一括挿入", &.{ bulk, .{ .number = 1 }, values }, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, true }, bulk.array.presence.items);
    try std.testing.expectEqual(Value.undefined, bulk.array.get(1));
    try std.testing.expectEqual(@as(f64, 7), bulk.array.get(2).number);
    try std.testing.expectEqual(@as(f64, 3), bulk.array.get(4).number);
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
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);
    try std.testing.expectEqualSlices(u16, &.{ '二', '引', '数' }, (try indexed(&runtime, function, name_key)).string.units);

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

test "表ソートは最上位配列のholeと明示的undefinedをpresence順に保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var high = try common.arrayFromValues(&runtime, &.{.{ .number = 2 }});
    try roots.protect(&high);
    var low = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&low);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, high);
    try table.array.set(2, low);
    try table.array.set(3, .undefined);

    const sorted = try tableSort(&runtime, table, .{ .number = 0 }, false);
    try std.testing.expectEqual(table.array, sorted.array);
    try std.testing.expectEqual(low.array, table.array.get(0).array);
    try std.testing.expectEqual(high.array, table.array.get(1).array);
    try std.testing.expectEqual(Value.undefined, table.array.get(2));
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, table.array.presence.items);

    var high_text = try runtime.stringUtf8("10");
    try roots.protect(&high_text);
    var low_text = try runtime.stringUtf8("2");
    try roots.protect(&low_text);
    var numeric_high = try common.arrayFromValues(&runtime, &.{high_text});
    try roots.protect(&numeric_high);
    var numeric_low = try common.arrayFromValues(&runtime, &.{low_text});
    try roots.protect(&numeric_low);
    var numeric_table = try runtime.createArray();
    try roots.protect(&numeric_table);
    try numeric_table.array.set(0, numeric_high);
    try numeric_table.array.set(2, numeric_low);
    try numeric_table.array.set(3, .undefined);
    _ = try tableSort(&runtime, numeric_table, .{ .number = 0 }, true);
    try std.testing.expectEqual(numeric_low.array, numeric_table.array.get(0).array);
    try std.testing.expectEqual(numeric_high.array, numeric_table.array.get(1).array);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, numeric_table.array.presence.items);
}

test "表列取得と表ピックアップは最上位のholeをArrayメソッドどおり扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var first = try common.arrayFromValues(&runtime, &.{ .{ .number = 2 }, .{ .number = 20 } });
    try roots.protect(&first);
    var second = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&second);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, first);
    try table.array.set(2, second);

    var column = try tableColumn(&runtime, table, .{ .number = 1 });
    try roots.protect(&column);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, column.array.presence.items);
    try std.testing.expectEqual(@as(f64, 20), column.array.get(0).number);
    try std.testing.expectEqual(Value.undefined, column.array.get(1));
    try std.testing.expectEqual(Value.undefined, column.array.get(2));

    var partial = try tablePickup(&runtime, table, .{ .number = 0 }, .{ .number = 1 }, false);
    try roots.protect(&partial);
    try std.testing.expectEqual(@as(usize, 1), partial.array.len());
    try std.testing.expectEqual(second.array, partial.array.get(0).array);
    var exact = try tablePickup(&runtime, table, .{ .number = 0 }, .{ .number = 2 }, true);
    try roots.protect(&exact);
    try std.testing.expectEqual(@as(usize, 1), exact.array.len());
    try std.testing.expectEqual(first.array, exact.array.get(0).array);
}

test "表列挿入削除合計は外側と行内部のholeをforEachとsliceどおり扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var sparse_row = try runtime.createArray();
    try roots.protect(&sparse_row);
    try sparse_row.array.set(0, .{ .number = 1 });
    try sparse_row.array.set(2, .{ .number = 3 });
    var dense_row = try common.arrayFromValues(&runtime, &.{ .{ .number = 4 }, .{ .number = 5 } });
    try roots.protect(&dense_row);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, sparse_row);
    try table.array.set(2, dense_row);
    var values = try common.arrayFromValues(&runtime, &.{ .{ .number = 9 }, .{ .number = 8 }, .{ .number = 7 } });
    try roots.protect(&values);

    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    try std.testing.expectEqual(@as(usize, 2), inserted.array.len());
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, inserted.array.get(0).array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), inserted.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 9), inserted.array.get(0).array.get(1).number);
    try std.testing.expectEqual(Value.undefined, inserted.array.get(0).array.get(2));
    try std.testing.expectEqual(@as(f64, 3), inserted.array.get(0).array.get(3).number);
    try std.testing.expectEqual(@as(f64, 7), inserted.array.get(1).array.get(1).number);

    var deleted = try tableDeleteColumn(&runtime, table, .{ .number = 1 });
    try roots.protect(&deleted);
    try std.testing.expectEqual(@as(usize, 2), deleted.array.len());
    try std.testing.expectEqualSlices(bool, &.{ true, true }, deleted.array.get(0).array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), deleted.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), deleted.array.get(0).array.get(1).number);
    try std.testing.expectEqual(@as(f64, 4), deleted.array.get(1).array.get(0).number);

    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, table.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), table.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 4), table.array.get(2).array.get(0).number);
    const sum_value = try tableColumnSum(&runtime, table, .{ .number = 0 });
    try std.testing.expectEqual(@as(f64, 5), sum_value.number);
}

test "表正規表現系はraw RegExpと浅いコピーとGCを保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var first_text = try runtime.stringUtf8("alice");
    try roots.protect(&first_text);
    var marker = try runtime.createDictionary();
    try roots.protect(&marker);
    var first = try common.arrayFromValues(&runtime, &.{ first_text, marker });
    try roots.protect(&first);
    var second_text = try runtime.stringUtf8("bob");
    try roots.protect(&second_text);
    var second = try common.arrayFromValues(&runtime, &.{second_text});
    try roots.protect(&second);
    var table = try common.arrayFromValues(&runtime, &.{ first, second });
    try roots.protect(&table);
    var raw_pattern = try runtime.stringUtf8("^ali");
    try roots.protect(&raw_pattern);
    const found = try tableRegexpSearch(&runtime, table, .{ .number = 0 }, .{ .number = 0 }, raw_pattern);
    try std.testing.expectEqual(@as(f64, 0), found.number);

    var slash_pattern = try runtime.stringUtf8("/^ali/i");
    try roots.protect(&slash_pattern);
    try std.testing.expectEqual(@as(f64, -1), (try tableRegexpSearch(&runtime, table, .{ .number = 0 }, .{ .number = 0 }, slash_pattern)).number);

    var start_text = try runtime.stringUtf8("1");
    try roots.protect(&start_text);
    var bob_pattern = try runtime.stringUtf8("bob");
    try roots.protect(&bob_pattern);
    const string_start = try tableRegexpSearch(&runtime, table, start_text, .{ .number = 0 }, bob_pattern);
    try std.testing.expectEqual(start_text.string, string_start.string);
    var start_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&start_bigint);
    const bigint_start = try tableRegexpSearch(&runtime, table, start_bigint, .{ .number = 0 }, bob_pattern);
    try std.testing.expectEqual(@as(i64, 1), bigint_start.bigint.toI64());

    var picked = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, raw_pattern);
    try roots.protect(&picked);
    try std.testing.expect(picked.array != table.array);
    try std.testing.expect(picked.array.get(0).array != first.array);
    try std.testing.expectEqual(marker.dictionary, picked.array.get(0).array.get(1).dictionary);

    var empty_pattern_pickup = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, .undefined);
    try roots.protect(&empty_pattern_pickup);
    try std.testing.expectEqual(@as(usize, 2), empty_pattern_pickup.array.len());
    var string_table = try common.arrayFromValues(&runtime, &.{first_text});
    try roots.protect(&string_table);
    var first_unit_pattern = try runtime.stringUtf8("^a");
    try roots.protect(&first_unit_pattern);
    var string_pickup = try tableRegexpPickup(&runtime, string_table, .{ .number = 0 }, first_unit_pattern);
    try roots.protect(&string_pickup);
    try std.testing.expectEqual(first_text.string, string_pickup.array.get(0).string);

    var invalid = try runtime.stringUtf8("[");
    try roots.protect(&invalid);
    var empty = try runtime.createArray();
    try roots.protect(&empty);
    try std.testing.expectError(error.UnclosedCharacterClass, tableRegexpSearch(&runtime, empty, .{ .number = 0 }, .{ .number = 0 }, invalid));
    try std.testing.expectError(error.UnclosedCharacterClass, tableRegexpPickup(&runtime, empty, .{ .number = 0 }, invalid));

    var null_row = try common.arrayFromValues(&runtime, &.{Value.null_value});
    try roots.protect(&null_row);
    try std.testing.expectError(error.TableRowMissing, tableRegexpSearch(&runtime, null_row, .{ .number = 0 }, .{ .number = 0 }, raw_pattern));
    try std.testing.expectError(error.TableRowMissing, tableRegexpPickup(&runtime, null_row, .{ .number = 0 }, raw_pattern));
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

    var byte_row = try runtime.createBytes(&.{ 0x41, 0x42, 0x43 });
    try roots.protect(&byte_row);
    var byte_table = try common.arrayFromValues(&runtime, &.{byte_row});
    try roots.protect(&byte_table);
    var byte_values = try common.arrayFromValues(&runtime, &.{.{ .number = 9 }});
    try roots.protect(&byte_values);
    var byte_inserted = try tableInsertColumn(&runtime, byte_table, .{ .number = 1 }, byte_values);
    try roots.protect(&byte_inserted);
    try std.testing.expectEqual(@as(usize, 3), byte_inserted.array.get(0).array.len());
    try std.testing.expectEqualSlices(u8, &.{0x41}, byte_inserted.array.get(0).array.get(0).bytes.bytes);
    try std.testing.expectEqual(@as(f64, 9), byte_inserted.array.get(0).array.get(1).number);
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x43 }, byte_inserted.array.get(0).array.get(2).bytes.bytes);

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

test "表正規表現ピックアップはBufferのsliceを共有する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 66 });
    try roots.protect(&buffer);
    var table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&table);
    var pattern = try runtime.stringUtf8("^85");
    try roots.protect(&pattern);
    var picked = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, pattern);
    try roots.protect(&picked);
    buffer.bytes.set(0, 7);
    try std.testing.expectEqual(@as(f64, 7), picked.array.get(0).bytes.get(0).number);
}

test "表列挿入はBufferのsliceだけを共有しTypedArrayのsliceを複製する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 1, 2, 3 });
    try roots.protect(&buffer);
    var table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&table);
    var values = try common.arrayFromValues(&runtime, &.{.{ .number = 9 }});
    try roots.protect(&values);
    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    buffer.bytes.set(0, 7);
    buffer.bytes.set(1, 8);
    const inserted_row = inserted.array.get(0).array;
    try std.testing.expectEqual(@as(f64, 7), inserted_row.get(0).bytes.get(0).number);
    try std.testing.expectEqual(@as(f64, 8), inserted_row.get(2).bytes.get(0).number);

    var uint8 = try runtime.createUint8Array(&.{ 4, 5 });
    try roots.protect(&uint8);
    var uint8_slice = try byteBufferSlice(&runtime, uint8.bytes, 0, 1);
    try roots.protect(&uint8_slice);
    uint8.bytes.set(0, 6);
    try std.testing.expectEqual(@as(f64, 4), uint8_slice.bytes.get(0).number);

    var array_buffer = try runtime.createArrayBuffer(&.{ 10, 11 });
    try roots.protect(&array_buffer);
    var array_buffer_slice = try byteBufferSlice(&runtime, array_buffer.bytes, 0, 1);
    try roots.protect(&array_buffer_slice);
    array_buffer.bytes.set(0, 12);
    try std.testing.expectEqual(@as(f64, 10), array_buffer_slice.bytes.get(0).number);
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

    var range_source = try common.arrayFromValues(&runtime, &.{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    try roots.protect(&range_source);
    var zero_bigint = try runtime.bigIntLiteral("0n");
    try roots.protect(&zero_bigint);
    var one_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&one_bigint);
    var negative_bigint = try runtime.bigIntLiteral("-2n");
    try roots.protect(&negative_bigint);
    var huge_positive_bigint = try runtime.bigIntLiteral("9007199254740993n");
    try roots.protect(&huge_positive_bigint);
    var huge_negative_bigint = try runtime.bigIntLiteral("-9007199254740993n");
    try roots.protect(&huge_negative_bigint);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, zero_bigint);
    var bigint_zero_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_zero_copy);
    try std.testing.expectEqual(@as(usize, 1), bigint_zero_copy.array.len());
    try range.dictionary.set(last_key.string, one_bigint);
    var bigint_one_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_one_copy);
    try std.testing.expectEqual(@as(usize, 2), bigint_one_copy.array.len());
    try range.dictionary.set(last_key.string, negative_bigint);
    var bigint_negative_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_negative_copy);
    try std.testing.expectEqual(@as(usize, 3), bigint_negative_copy.array.len());
    try range.dictionary.set(last_key.string, huge_positive_bigint);
    var bigint_huge_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_huge_copy);
    try std.testing.expectEqual(@as(usize, 4), bigint_huge_copy.array.len());
    try range.dictionary.set(last_key.string, huge_negative_bigint);
    var bigint_huge_negative_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_huge_negative_copy);
    try std.testing.expectEqual(@as(usize, 0), bigint_huge_negative_copy.array.len());
    try range.dictionary.set(first_key.string, one_bigint);
    try range.dictionary.set(last_key.string, .{ .number = 2 });
    try std.testing.expectEqual(Value.undefined, try rangeCopy(&runtime, range_source, range));
    try std.testing.expectEqual(@as(f64, 0), (try reference(&runtime, range_source, zero_bigint)).number);
    try std.testing.expectEqual(@as(f64, 1), (try reference(&runtime, range_source, one_bigint)).number);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, negative_bigint));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, huge_positive_bigint));

    var key_zero = try runtime.stringUtf8("0");
    try roots.protect(&key_zero);
    var key_one = try runtime.stringUtf8("1");
    try roots.protect(&key_one);
    var key_leading_zero = try runtime.stringUtf8("01");
    try roots.protect(&key_leading_zero);
    var key_negative_zero = try runtime.stringUtf8("-0");
    try roots.protect(&key_negative_zero);
    var key_negative_one = try runtime.stringUtf8("-1");
    try roots.protect(&key_negative_one);
    var key_decimal = try runtime.stringUtf8("1.0");
    try roots.protect(&key_decimal);
    var key_empty = try runtime.stringUtf8("");
    try roots.protect(&key_empty);
    var key_max = try runtime.stringUtf8("4294967295");
    try roots.protect(&key_max);
    var key_huge = try runtime.stringUtf8("900719925474099999999999999");
    try roots.protect(&key_huge);
    var key_length = try runtime.stringUtf8("length");
    try roots.protect(&key_length);
    try std.testing.expectEqual(@as(f64, 0), (try reference(&runtime, range_source, key_zero)).number);
    try std.testing.expectEqual(@as(f64, 1), (try reference(&runtime, range_source, key_one)).number);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_leading_zero));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_negative_zero));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_negative_one));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_decimal));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_empty));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_max));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_huge));
    try std.testing.expectEqual(@as(f64, 4), (try reference(&runtime, range_source, key_length)).number);
    const alias_arguments = [_]Value{ range_source, key_one };
    const alias_result = (try call(&runtime, "配列参照", &alias_arguments, null)).?;
    try std.testing.expectEqual(@as(f64, 1), alias_result.number);
    try std.testing.expectEqual(@as(?usize, 0), propertyIndexUnits(&.{'0'}));
    try std.testing.expectEqual(@as(?usize, 4294967294), propertyIndexUnits(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '4' }));
    try std.testing.expectEqual(@as(?usize, null), propertyIndexUnits(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '5' }));

    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, one_bigint);
    var bigint_text = try reference(&runtime, text, range);
    try roots.protect(&bigint_text);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, bigint_text.string.units);
    try range.dictionary.set(last_key.string, negative_bigint);
    var bigint_empty_text = try reference(&runtime, text, range);
    try roots.protect(&bigint_empty_text);
    try std.testing.expectEqual(@as(usize, 0), bigint_empty_text.string.len());

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

fn bigintRangeAllocationCase(allocator: std.mem.Allocator) !void {
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

fn bigintRangeAllocationTest(allocator: std.mem.Allocator) !void {
    bigintRangeAllocationCase(allocator) catch |failure| {
        // Zig 0.16のArrayList WriterはJSON複製中のOOMをWriteFailedへ
        // 変換するため、割当網羅テストへ元の意味を戻す。
        if (failure == error.WriteFailed) return error.OutOfMemory;
        return failure;
    };
}

fn referenceArrayStringKeyAllocationTest(allocator: std.mem.Allocator) !void {
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

fn expectReferenceStringRangeMessage(runtime: *Runtime, index: Value, expected: []const u8) !void {
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

fn referenceStringRangeAllocationTest(allocator: std.mem.Allocator) !void {
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
    try std.testing.expectError(error.ArraySizeLimitExceeded, swap(&runtime, swap_source, .{ .number = 0 }, .{ .number = @floatFromInt(safe_array_element_limit) }));

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
