const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const operators = @import("../../runtime/operators.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    if (eql(name, "足")) return try addParsed(runtime, a, b);
    if (eql(name, "合計")) return try sum(runtime, arguments);
    if (eql(name, "引")) return try operators.binary(runtime, .subtract, a, b);
    if (eql(name, "掛")) return try multiplyExtended(runtime, a, b);
    if (eql(name, "倍")) return try operators.binary(runtime, .multiply, a, b);
    if (eql(name, "割")) return try operators.binary(runtime, .divide, a, b);
    if (eql(name, "割余")) return try operators.binary(runtime, .remainder, a, b);
    if (eql(name, "偶数")) return .{ .boolean = @rem(try common.parseIntValue(runtime, a, null), 2) == 0 };
    if (eql(name, "奇数")) return .{ .boolean = @rem(try common.parseIntValue(runtime, a, null), 2) == 1 };
    if (eql(name, "二乗")) return try operators.binary(runtime, .multiply, a, a);
    if (eql(name, "べき乗")) return .{ .number = std.math.pow(f64, try runtime.valueToNumber(a), try runtime.valueToNumber(b)) };
    if (eql(name, "以上")) return try relation(runtime, a, b, .gte);
    if (eql(name, "以下")) return try relation(runtime, a, b, .lte);
    if (eql(name, "未満")) return try relation(runtime, a, b, .lt);
    if (eql(name, "超")) return try relation(runtime, a, b, .gt);
    if (eql(name, "等")) return .{ .boolean = Value.strictEqual(a, b) };
    if (eql(name, "等無")) return .{ .boolean = !Value.strictEqual(a, b) };
    if (eql(name, "一致")) return .{ .boolean = deepEqual(a, b) };
    if (eql(name, "不一致")) return .{ .boolean = !deepEqual(a, b) };
    if (eql(name, "範囲内")) {
        const lower = try relation(runtime, a, b, .gte);
        const upper = try relation(runtime, a, common.argument(arguments, 2), .lte);
        return .{ .boolean = lower.boolean and upper.boolean };
    }
    if (eql(name, "範囲")) return try makeRange(runtime, a, b);
    if (eql(name, "連続加算")) return try sequentialAdd(runtime, arguments);
    if (eql(name, "MAX") or eql(name, "最大値")) return try extremum(runtime, arguments, true);
    if (eql(name, "MIN") or eql(name, "最小値")) return try extremum(runtime, arguments, false);
    if (eql(name, "CLAMP")) return try clamp(runtime, a, b, common.argument(arguments, 2));
    if (eql(name, "論理OR")) return if (a.toBoolean()) a else b;
    if (eql(name, "論理AND")) return if (a.toBoolean()) b else a;
    if (eql(name, "論理NOT")) return .{ .boolean = !a.toBoolean() };
    if (eql(name, "OR")) return try operators.binary(runtime, .bit_or, a, b);
    if (eql(name, "AND")) return try operators.binary(runtime, .bit_and, a, b);
    if (eql(name, "XOR")) return try operators.binary(runtime, .bit_xor, a, b);
    if (eql(name, "NOT")) return try operators.bitNot(runtime, a);
    if (eql(name, "SHIFT_L")) return try operators.binary(runtime, .shift_left, a, b);
    if (eql(name, "SHIFT_R")) return try operators.binary(runtime, .shift_right, a, b);
    if (eql(name, "SHIFT_UR")) return try operators.binary(runtime, .shift_right_unsigned, a, b);
    if (eql(name, "真偽判定")) return try runtime.stringUtf8(if (a.toBoolean()) "真" else "偽");
    return null;
}

fn addParsed(runtime: *Runtime, left: Value, right: Value) !Value {
    if (left == .bigint or right == .bigint) {
        var left_bigint = try toBigInt(runtime, left);
        var right_bigint = try toBigInt(runtime, right);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&left_bigint);
        try roots.protect(&right_bigint);
        return operators.binary(runtime, .add, left_bigint, right_bigint);
    }
    return .{ .number = (try common.parseFloatValue(runtime, left)) + (try common.parseFloatValue(runtime, right)) };
}

fn sum(runtime: *Runtime, arguments: []const Value) !Value {
    const values = if (arguments.len >= 1 and arguments[0] == .array) arguments[0].array.items.items else arguments;
    const skip_nan = arguments.len >= 1 and arguments[0] == .array;
    var has_bigint = false;
    for (values) |value| if (value == .bigint) {
        has_bigint = true;
        break;
    };
    if (!has_bigint) {
        var total: f64 = 0;
        for (values) |value| {
            const number = try common.parseFloatValue(runtime, value);
            if (!skip_nan or !std.math.isNan(number)) total += number;
        }
        return .{ .number = total };
    }
    var total = try runtime.bigIntLiteral("0n");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&total);
    for (values) |value| {
        var converted = try toBigInt(runtime, value);
        try roots.protect(&converted);
        total = try operators.binary(runtime, .add, total, converted);
        try roots.protect(&total);
    }
    return total;
}

fn multiplyExtended(runtime: *Runtime, left: Value, right: Value) !Value {
    if (left == .string) {
        const count_number = try common.parseIntValue(runtime, right, null);
        if (std.math.isNan(count_number) or count_number <= 0) return runtime.stringUtf8("");
        if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RepetitionTooLarge;
        const count: usize = @intFromFloat(@trunc(count_number));
        const length = std.math.mul(usize, left.string.units.len, count) catch return error.RepetitionTooLarge;
        var units = try runtime.allocator().alloc(u16, length);
        defer runtime.allocator().free(units);
        for (0..count) |index| @memcpy(units[index * left.string.units.len ..][0..left.string.units.len], left.string.units);
        return runtime.stringCodeUnits(units);
    }
    if (left == .array) {
        const count_number = try common.parseIntValue(runtime, right, null);
        if (std.math.isNan(count_number) or count_number <= 0) return runtime.createArray();
        if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RepetitionTooLarge;
        const count: usize = @intFromFloat(@trunc(count_number));
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (0..count) |_| {
            for (left.array.items.items) |value| _ = try result.array.push(value);
        }
        return result;
    }
    return operators.binary(runtime, .multiply, left, right);
}

const Relation = enum { lt, lte, gt, gte };

fn relation(runtime: *Runtime, left: Value, right: Value, expected: Relation) !Value {
    const order = try operators.compare(runtime, left, right);
    return .{ .boolean = if (order) |actual| switch (expected) {
        .lt => actual == .lt,
        .lte => actual != .gt,
        .gt => actual == .gt,
        .gte => actual != .lt,
    } else false };
}

fn makeRange(runtime: *Runtime, first: Value, last: Value) !Value {
    var dictionary = try runtime.createDictionary();
    var first_root = first;
    var last_root = last;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try roots.protect(&first_root);
    try roots.protect(&last_root);
    try common.dictionarySetUtf8(runtime, dictionary.dictionary, "先頭", first_root);
    try common.dictionarySetUtf8(runtime, dictionary.dictionary, "末尾", last_root);
    return dictionary;
}

fn sequentialAdd(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return runtime.createDictionary();
    var result = if (arguments.len == 1) arguments[0] else arguments[1];
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (arguments[2..]) |value| {
        result = try operators.binary(runtime, .add, result, value);
        try roots.protect(&result);
    }
    if (arguments.len > 1) {
        result = try operators.binary(runtime, .add, result, arguments[0]);
        try roots.protect(&result);
    }
    return result;
}

fn extremum(runtime: *Runtime, arguments: []const Value, maximum: bool) !Value {
    if (arguments.len == 0) return .{ .number = if (maximum) -std.math.inf(f64) else std.math.inf(f64) };
    var result = try runtime.valueToNumber(arguments[0]);
    var has_nan = std.math.isNan(result);
    for (arguments[1..]) |value| {
        const number = try runtime.valueToNumber(value);
        if (std.math.isNan(number)) {
            has_nan = true;
        } else if (!has_nan) {
            result = if (maximum) @max(result, number) else @min(result, number);
        }
    }
    return .{ .number = if (has_nan) std.math.nan(f64) else result };
}

fn clamp(runtime: *Runtime, value: Value, lower: Value, upper: Value) !Value {
    const number = try runtime.valueToNumber(value);
    const minimum = try runtime.valueToNumber(lower);
    const maximum = try runtime.valueToNumber(upper);
    return .{ .number = @min(@max(number, minimum), maximum) };
}

fn toBigInt(runtime: *Runtime, value: Value) !Value {
    const primitive = try runtime.valueToPrimitive(value);
    return switch (primitive) {
        .bigint => primitive,
        .number => runtime.ownBigInt(try value_mod.BigInt.fromF64(runtime.allocator(), primitive.number)),
        .string => runtime.bigIntString(primitive.string),
        .boolean => runtime.bigIntLiteral(if (primitive.boolean) "1n" else "0n"),
        .null_value => error.CannotConvertNullToBigInt,
        .undefined => error.CannotConvertUndefinedToBigInt,
        else => error.InvalidBigIntConversion,
    };
}

fn deepEqual(left: Value, right: Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .array => |array| blk: {
            if (array.items.items.len != right.array.items.items.len) break :blk false;
            for (array.items.items, right.array.items.items) |a, b| if (!deepEqual(a, b)) break :blk false;
            break :blk true;
        },
        .dictionary => |dictionary| blk: {
            if (dictionary.len() != right.dictionary.len()) break :blk false;
            for (dictionary.keys(), dictionary.values(), 0..) |key, value, index| {
                if (!value_mod.String.eql(key.*, right.dictionary.keys()[index].*)) break :blk false;
                if (!deepEqual(value, right.dictionary.values()[index])) break :blk false;
            }
            break :blk true;
        },
        else => Value.strictEqual(left, right),
    };
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "四則・論理・ビット命令を動的値で実行する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const three = (try call(&runtime, "足", &.{ try runtime.stringUtf8("1"), .{ .number = 2 } })).?;
    try std.testing.expectEqual(@as(f64, 3), three.number);
    const repeated = (try call(&runtime, "掛", &.{ try runtime.stringUtf8("あ"), .{ .number = 3 } })).?;
    const utf8 = try repeated.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("あああ", utf8);
    try std.testing.expect((try call(&runtime, "範囲内", &.{ .{ .number = 2 }, .{ .number = 1 }, .{ .number = 3 } })).?.boolean);
    try std.testing.expectEqual(@as(f64, 2147483647), (try call(&runtime, "SHIFT_UR", &.{ .{ .number = -1 }, .{ .number = 1 } })).?.number);
    try std.testing.expect(!(try call(&runtime, "奇数", &.{.{ .number = -3 }})).?.boolean);
    try std.testing.expectError(error.CannotConvertBigIntToNumber, call(&runtime, "べき乗", &.{ try runtime.bigIntLiteral("2n"), try runtime.bigIntLiteral("3n") }));
    const sequential = (try call(&runtime, "連続加算", &.{ try runtime.stringUtf8("a"), try runtime.stringUtf8("b"), try runtime.stringUtf8("c") })).?;
    const sequential_utf8 = try sequential.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(sequential_utf8);
    try std.testing.expectEqualStrings("bca", sequential_utf8);
}

test "合計は先頭配列だけを集計しNaNを飛ばす" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var array = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    _ = try array.array.push(.{ .number = 1 });
    _ = try array.array.push(try runtime.stringUtf8("x"));
    _ = try array.array.push(.{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 3), (try call(&runtime, "合計", &.{ array, .{ .number = 100 } })).?.number);
}
