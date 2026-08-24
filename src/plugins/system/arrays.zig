const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const operators = @import("../../runtime/operators.zig");
const common = @import("common.zig");
const json = @import("json.zig");
const regexp = @import("regexp.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

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
    if (eql(name, "表列数")) return try tableColumnCount(a);
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
        .array => |array| array.len(),
        .dictionary => |dictionary| dictionary.len(),
        .string => |string| string.len(),
        else => 1,
    };
}

fn insertOne(runtime: *Runtime, source: Value, index_value: Value, item: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.insert(spliceIndex(try runtime.valueToNumber(index_value), source.array.len()), item);
    return runtime.createArray();
}

fn insertMany(runtime: *Runtime, source: Value, index_value: Value, items: Value) !Value {
    if (source != .array or items != .array) return error.ArrayExpected;
    var index = spliceIndex(try runtime.valueToNumber(index_value), source.array.len());
    const copy = try runtime.allocator().dupe(Value, items.array.items.items);
    defer runtime.allocator().free(copy);
    for (copy) |item| {
        try source.array.insert(index, item);
        index += 1;
    }
    return source;
}

fn sortDefault(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source.array, .string, null);
    return source;
}

fn numericConvert(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    for (source.array.items.items) |*item| {
        const original = item.*;
        const number = try common.parseFloatValue(runtime, original);
        item.* = .{ .number = number };
    }
    return source;
}

fn sortNumeric(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source.array, .number, null);
    return source;
}

fn sortCustom(runtime: *Runtime, function_value: Value, source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    var callable = try Context.resolve(context, runtime, function_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&callable);
    try stableSort(runtime, source.array, .callback, .{ .context = context, .callable = callable });
    return source;
}

const SortMode = enum { string, number, relational, callback };
const SortCallback = struct { context: ?Context, callable: Value };

fn stableSort(runtime: *Runtime, array: *value_mod.Array, mode: SortMode, callback: ?SortCallback) !void {
    var index: usize = 1;
    while (index < array.len()) : (index += 1) {
        const value = array.items.items[index];
        var cursor = index;
        while (cursor > 0 and try compareForSort(runtime, array.items.items[cursor - 1], value, mode, callback) == .gt) {
            array.items.items[cursor] = array.items.items[cursor - 1];
            cursor -= 1;
        }
        array.items.items[cursor] = value;
    }
}

fn compareForSort(runtime: *Runtime, left: Value, right: Value, mode: SortMode, callback: ?SortCallback) !std.math.Order {
    return switch (mode) {
        .string => blk: {
            const left_text = try runtime.valueToString(left);
            const right_text = try runtime.valueToString(right);
            break :blk value_mod.String.order(left_text.string.*, right_text.string.*);
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
        if (try rangeBounds(runtime, index_value, source.array.len())) |range| return spliceArray(runtime, source.array, range.start, range.count);
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
    if (encoded == .undefined) return .undefined;
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
        const index = directIndex(index_value.number) orelse return .undefined;
        if (index >= source.array.len()) return .undefined;
        return deepClone(runtime, source.array.get(index));
    }
    const range = (try rangeBounds(runtime, index_value, source.array.len())) orelse return .undefined;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items[range.start .. range.start + range.count]) |item| _ = try result.array.push(try deepClone(runtime, item));
    return result;
}

fn reference(runtime: *Runtime, source: Value, index_value: Value) !Value {
    if (source == .string) {
        if (index_value == .number) {
            const index = directIndex(index_value.number) orelse return runtime.stringUtf8("");
            if (index >= source.string.len()) return runtime.stringUtf8("");
            return runtime.stringCodeUnits(source.string.units[index .. index + 1]);
        }
        const range = (try rangeBounds(runtime, index_value, source.string.len())) orelse return error.InvalidStringRange;
        return runtime.stringCodeUnits(source.string.units[range.start .. range.start + range.count]);
    }
    if (source == .array) {
        if (index_value == .number) return source.array.get(directIndex(index_value.number) orelse return .undefined);
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
    if (source != .array or source.array.len() == 0) return error.NonEmptyArrayExpected;
    var result = try runtime.valueToNumber(source.array.get(0));
    for (source.array.items.items[1..]) |item| {
        const number = try runtime.valueToNumber(item);
        result = if (maximum) @max(result, number) else @min(result, number);
    }
    return .{ .number = result };
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
    const first_item = source.array.get(first);
    const second_item = source.array.get(second);
    try source.array.set(first, second_item);
    try source.array.set(second, first_item);
    return source;
}

fn sequence(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
    const first = try runtime.valueToNumber(first_value);
    const last = try runtime.valueToNumber(last_value);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    if (!std.math.isFinite(first) or !std.math.isFinite(last)) return result;
    var current = first;
    var count: usize = 0;
    while (current <= last) : (current += 1) {
        if (count >= 10_000_000) return error.ArraySizeLimitExceeded;
        _ = try result.array.push(.{ .number = current });
        count += 1;
    }
    return result;
}

fn fill(runtime: *Runtime, value: Value, shape: Value) !Value {
    if (shape == .array) return fillDimensions(runtime, value, shape.array.items.items, 0);
    return fillCount(runtime, value, positiveLength(try runtime.valueToNumber(shape), 10_000_000));
}

fn fillDimensions(runtime: *Runtime, value: Value, dimensions: []const Value, depth: usize) !Value {
    if (depth >= dimensions.len) return deepClone(runtime, value);
    const count = positiveLength(try runtime.valueToNumber(dimensions[depth]), 10_000_000);
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
    for (0..count) |_| _ = try result.array.push(try deepClone(runtime, value));
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
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const needle_text = if (!exact) try runtime.valueToString(needle) else .undefined;
    for (source.array.items.items) |row| {
        const cell = try indexed(runtime, row, column);
        const matches = if (exact) Value.strictEqual(cell, needle) else blk: {
            const text = try runtime.valueToString(cell);
            break :blk std.mem.indexOf(u16, text.string.units, needle_text.string.units) != null;
        };
        if (matches) _ = try result.array.push(row);
    }
    return result;
}

fn tableSearch(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    const start = spliceIndex(try runtime.valueToNumber(row_value), source.array.len());
    for (source.array.items.items[start..], start..) |row, index| if (Value.strictEqual(try indexed(runtime, row, column), needle)) return .{ .number = @floatFromInt(index) };
    return .{ .number = -1 };
}

fn tableColumnCount(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var columns: usize = 1;
    for (source.array.items.items) |row| if (row == .array and row.array.len() > columns) {
        columns = row.array.len();
    };
    return .{ .number = @floatFromInt(columns) };
}

fn tableRowCount(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    return .{ .number = @floatFromInt(source.array.len()) };
}

fn transpose(runtime: *Runtime, source: Value, rotate: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    const columns: usize = @intFromFloat((try tableColumnCount(source)).number);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (0..columns) |column| {
        var row_result = try runtime.createArray();
        try roots.protect(&row_result);
        for (0..source.array.len()) |offset| {
            const row_index = if (rotate) source.array.len() - offset - 1 else offset;
            const row = source.array.get(row_index);
            const cell = if (row == .array and column < row.array.len()) row.array.get(column) else if (rotate) .undefined else try runtime.stringUtf8("");
            _ = try row_result.array.push(cell);
        }
        _ = try result.array.push(row_result);
    }
    return result;
}

fn tableUnique(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result = try runtime.createArray();
    var seen = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    try roots.protect(&seen);
    for (source.array.items.items) |row| {
        const key = try runtime.valueToString(try indexed(runtime, row, column));
        if (!seen.dictionary.has(key.string)) {
            try seen.dictionary.set(key.string, .{ .boolean = true });
            _ = try result.array.push(row);
        }
    }
    return result;
}

fn tableColumn(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items) |row| _ = try result.array.push(try indexed(runtime, row, column));
    return result;
}

fn tableInsertColumn(runtime: *Runtime, source: Value, column_value: Value, values: Value) !Value {
    if (source != .array or values != .array) return error.ArrayExpected;
    const column = spliceIndex(try runtime.valueToNumber(column_value), std.math.maxInt(usize));
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items, 0..) |row, index| {
        if (row != .array) return error.ArrayExpected;
        var new_row = try runtime.createArray();
        try roots.protect(&new_row);
        const insertion = @min(column, row.array.len());
        for (row.array.items.items[0..insertion]) |item| _ = try new_row.array.push(item);
        _ = try new_row.array.push(values.array.get(index));
        for (row.array.items.items[insertion..]) |item| _ = try new_row.array.push(item);
        _ = try result.array.push(new_row);
    }
    return result;
}

fn tableDeleteColumn(runtime: *Runtime, source: Value, column_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (source.array.items.items) |row| {
        if (row != .array) return error.ArrayExpected;
        var new_row = try runtime.createArray();
        try roots.protect(&new_row);
        const column = spliceIndex(try runtime.valueToNumber(column_value), row.array.len());
        for (row.array.items.items, 0..) |item, index| {
            if (index != column) _ = try new_row.array.push(item);
        }
        _ = try result.array.push(new_row);
    }
    return result;
}

fn tableColumnSum(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var result: Value = .{ .number = 0 };
    for (source.array.items.items) |row| result = try operators.binary(runtime, .add, result, try indexed(runtime, row, column));
    return result;
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
    if (source == .array) {
        const number = try runtime.valueToNumber(key);
        return source.array.get(directIndex(number) orelse return .undefined);
    }
    if (source == .dictionary) {
        const text = try runtime.valueToString(key);
        return source.dictionary.get(text.string) orelse .undefined;
    }
    return .undefined;
}

const Range = struct { start: usize, count: usize };

fn rangeBounds(runtime: *Runtime, value: Value, length: usize) !?Range {
    if (value != .dictionary) return null;
    const first_key = try runtime.stringUtf8("先頭");
    const last_key = try runtime.stringUtf8("末尾");
    const first_value = value.dictionary.get(first_key.string) orelse return null;
    const last_value = value.dictionary.get(last_key.string) orelse return null;
    if (first_value != .number) return null;
    const first = spliceIndex(first_value.number, length);
    const last_number = try runtime.valueToNumber(last_value);
    const last = if (last_number < 0) spliceIndex(last_number, length) else @min(directIndex(last_number) orelse 0, length);
    if (last < first) return .{ .start = first, .count = 0 };
    return .{ .start = first, .count = @min(last - first + 1, length - first) };
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
    if (!std.math.isFinite(number) or number < 0) return null;
    const integer = @trunc(number);
    if (integer > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(integer);
}

fn positiveLength(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
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
