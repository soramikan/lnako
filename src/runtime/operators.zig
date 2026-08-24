const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const BigInt = value_mod.BigInt;

pub const Binary = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    power,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    shift_right_unsigned,
};

pub fn binary(runtime: *Runtime, operator: Binary, left: Value, right: Value) !Value {
    if (operator == .add and (left == .string or right == .string)) {
        const left_string = (try runtime.valueToString(left)).string;
        const right_string = (try runtime.valueToString(right)).string;
        return runtime.concatStrings(left_string.*, right_string.*);
    }
    if (left == .bigint or right == .bigint) {
        if (left != .bigint or right != .bigint) return error.CannotMixBigIntAndNumber;
        return bigIntBinary(runtime, operator, left.bigint.*, right.bigint.*);
    }
    const left_number = try left.toNumber(runtime.allocator());
    const right_number = try right.toNumber(runtime.allocator());
    return .{ .number = switch (operator) {
        .add => left_number + right_number,
        .subtract => left_number - right_number,
        .multiply => left_number * right_number,
        .divide => left_number / right_number,
        .remainder => @rem(left_number, right_number),
        .power => std.math.pow(f64, left_number, right_number),
        .bit_and => @floatFromInt(toInt32(left_number) & toInt32(right_number)),
        .bit_or => @floatFromInt(toInt32(left_number) | toInt32(right_number)),
        .bit_xor => @floatFromInt(toInt32(left_number) ^ toInt32(right_number)),
        .shift_left => @floatFromInt(toInt32(left_number) << @intCast(toUint32(right_number) & 31)),
        .shift_right => @floatFromInt(toInt32(left_number) >> @intCast(toUint32(right_number) & 31)),
        .shift_right_unsigned => @floatFromInt(toUint32(left_number) >> @intCast(toUint32(right_number) & 31)),
    } };
}

fn bigIntBinary(runtime: *Runtime, operator: Binary, left: BigInt, right: BigInt) !Value {
    const allocator = runtime.allocator();
    const result = switch (operator) {
        .add => try left.add(allocator, right),
        .subtract => try left.sub(allocator, right),
        .multiply => try left.mul(allocator, right),
        .divide => try left.divTrunc(allocator, right),
        .remainder => try left.rem(allocator, right),
        .power => blk: {
            if (right.isNegative()) return error.NegativeBigIntExponent;
            break :blk try left.pow(allocator, right.toU32() catch return error.BigIntExponentTooLarge);
        },
        .bit_and => try left.bitAnd(allocator, right),
        .bit_or => try left.bitOr(allocator, right),
        .bit_xor => try left.bitXor(allocator, right),
        .shift_left, .shift_right => blk: {
            const amount = right.toI64() catch return error.BigIntShiftTooLarge;
            const magnitude = if (amount < 0) @as(u64, @intCast(-(amount + 1))) + 1 else @as(u64, @intCast(amount));
            const shift: usize = std.math.cast(usize, magnitude) orelse return error.BigIntShiftTooLarge;
            const shift_left = (operator == .shift_left) != (amount < 0);
            break :blk if (shift_left) try left.shiftLeft(allocator, shift) else try left.shiftRight(allocator, shift);
        },
        .shift_right_unsigned => return error.UnsignedShiftOfBigInt,
    };
    return runtime.ownBigInt(result);
}

pub fn unaryMinus(runtime: *Runtime, value: Value) !Value {
    if (value == .bigint) return runtime.ownBigInt(try value.bigint.negate(runtime.allocator()));
    return .{ .number = -(try value.toNumber(runtime.allocator())) };
}

pub fn unaryPlus(runtime: *Runtime, value: Value) !Value {
    if (value == .bigint) return error.CannotConvertBigIntToNumber;
    return .{ .number = try value.toNumber(runtime.allocator()) };
}

pub fn bitNot(runtime: *Runtime, value: Value) !Value {
    if (value == .bigint) return runtime.ownBigInt(try value.bigint.bitNot(runtime.allocator()));
    return .{ .number = @floatFromInt(~toInt32(try value.toNumber(runtime.allocator()))) };
}

/// ECMAScriptの抽象関係比較。NaNを含む場合はnull（undefined result）を返す。
pub fn compare(runtime: *Runtime, left: Value, right: Value) !?std.math.Order {
    if (left == .string and right == .string) return value_mod.String.order(left.string.*, right.string.*);
    if (left == .bigint and right == .bigint) return BigInt.order(left.bigint.*, right.bigint.*);
    if (left == .bigint and right == .string) {
        const converted = runtime.bigIntString(right.string.*) catch return null;
        return BigInt.order(left.bigint.*, converted.bigint.*);
    }
    if (left == .string and right == .bigint) {
        const converted = runtime.bigIntString(left.string.*) catch return null;
        return BigInt.order(converted.bigint.*, right.bigint.*);
    }
    if (left == .bigint) return compareBigIntNumber(left.bigint.*, try right.toNumber(runtime.allocator()));
    if (right == .bigint) {
        const order = compareBigIntNumber(right.bigint.*, try left.toNumber(runtime.allocator())) orelse return null;
        return invertOrder(order);
    }
    const left_number = try left.toNumber(runtime.allocator());
    const right_number = try right.toNumber(runtime.allocator());
    if (std.math.isNan(left_number) or std.math.isNan(right_number)) return null;
    return std.math.order(left_number, right_number);
}

pub fn toInt32(number: f64) i32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    if (value >= 2147483648.0) value -= 4294967296.0;
    return @intFromFloat(value);
}

pub fn toUint32(number: f64) u32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    return @intFromFloat(value);
}

fn compareBigIntNumber(bigint: BigInt, number: f64) !?std.math.Order {
    if (std.math.isNan(number)) return null;
    if (number == std.math.inf(f64)) return .lt;
    if (number == -std.math.inf(f64)) return .gt;
    var integer = try BigInt.fromF64(bigint.managed.allocator, @trunc(number));
    defer integer.deinit();
    const integer_order = BigInt.order(bigint, integer);
    if (integer_order != .eq) return integer_order;
    const fraction = number - @trunc(number);
    if (fraction > 0) return .lt;
    if (fraction < 0) return .gt;
    return .eq;
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

test "動的な加算とBigInt混在エラーを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const text = try runtime.stringUtf8("個");
    const concatenated = try binary(&runtime, .add, .{ .number = 3 }, text);
    const utf8 = try concatenated.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("3個", utf8);
    const bigint = try runtime.bigIntLiteral("10n");
    try std.testing.expectError(error.CannotMixBigIntAndNumber, binary(&runtime, .add, bigint, .{ .number = 1 }));
    const sum = try binary(&runtime, .add, bigint, try runtime.bigIntLiteral("2n"));
    const sum_text = try sum.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(sum_text);
    try std.testing.expectEqualStrings("12", sum_text);
}

test "Numberビット演算を32bitへ正規化する" {
    try std.testing.expectEqual(@as(i32, -1), toInt32(4294967295));
    try std.testing.expectEqual(@as(u32, 4294967295), toUint32(-1));
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const shifted = try binary(&runtime, .shift_right_unsigned, .{ .number = -1 }, .{ .number = 1 });
    try std.testing.expectEqual(@as(f64, 2147483647), shifted.number);
}

test "BigIntと小数の関係比較を精度損失なく処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const bigint = try runtime.bigIntLiteral("9007199254740993n");
    try std.testing.expectEqual(std.math.Order.gt, (try compare(&runtime, bigint, .{ .number = 9007199254740992.0 })).?);
    try std.testing.expectEqual(std.math.Order.lt, (try compare(&runtime, try runtime.bigIntLiteral("3n"), .{ .number = 3.5 })).?);
}
