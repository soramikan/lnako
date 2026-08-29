const std = @import("std");
const value_mod = @import("value.zig");
const string_mod = @import("string.zig");

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
    var left_root = left;
    var right_root = right;
    var frame = runtime.rootFrame();
    defer frame.deinit();
    try frame.protect(&left_root);
    try frame.protect(&right_root);
    const left_primitive = try runtime.valueToPrimitive(left_root);
    const right_primitive = try runtime.valueToPrimitive(right_root);
    if (operator == .add and (left_primitive == .string or right_primitive == .string)) {
        const left_string = (try runtime.valueToString(left_primitive)).string;
        const right_string = (try runtime.valueToString(right_primitive)).string;
        return runtime.concatStrings(left_string, right_string);
    }
    if (left_primitive == .bigint or right_primitive == .bigint) {
        if (left_primitive != .bigint or right_primitive != .bigint) return error.CannotMixBigIntAndNumber;
        return bigIntBinary(runtime, operator, left_primitive.bigint.*, right_primitive.bigint.*);
    }
    const left_number = try left_primitive.toNumber(runtime.allocator());
    const right_number = try right_primitive.toNumber(runtime.allocator());
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

/// なでしこ式の`+`は文字列連結ではなく数値加算。連結は`&`が担う。
pub fn nadesikoAdd(runtime: *Runtime, left: Value, right: Value) !Value {
    var left_root = left;
    var right_root = right;
    var frame = runtime.rootFrame();
    defer frame.deinit();
    try frame.protect(&left_root);
    try frame.protect(&right_root);
    // なでしこ式の`+`は元の値がBigIntのときだけBigInt加算へ進み、
    // それ以外のオブジェクトは公式のparseFloat(object)と同じく
    // 文字列hintのToPrimitiveを通してから数値化する。
    if (left_root == .bigint or right_root == .bigint) {
        const left_primitive = try runtime.valueToPrimitive(left_root);
        const right_primitive = try runtime.valueToPrimitive(right_root);
        if (left_primitive != .bigint or right_primitive != .bigint) return error.CannotMixBigIntAndNumber;
        return bigIntBinary(runtime, .add, left_primitive.bigint.*, right_primitive.bigint.*);
    }
    return .{ .number = try nadesikoAddNumber(runtime, left_root) + try nadesikoAddNumber(runtime, right_root) };
}

fn nadesikoAddNumber(runtime: *Runtime, value: Value) !f64 {
    if (value_mod.isObjectValue(value)) {
        const string_value = try runtime.valueToString(value);
        return string_mod.parseFloatNumber(runtime.allocator(), string_value.string.units);
    }
    return switch (value) {
        .number => |number| number,
        .string => |string| string_mod.parseFloatNumber(runtime.allocator(), string.units),
        .bigint => error.CannotConvertBigIntToNumber,
        else => std.math.nan(f64),
    };
}

/// 増減文は両辺を明示的にNumberへ変換し、未定義の対象を0として扱う。
pub fn increment(runtime: *Runtime, old: Value, amount: Value) !Value {
    const old_number: f64 = if (old == .undefined) 0 else try incrementNumber(runtime, old);
    return .{ .number = old_number + try incrementNumber(runtime, amount) };
}

fn incrementNumber(runtime: *Runtime, value: Value) !f64 {
    const primitive = try runtime.valueToPrimitive(value);
    if (primitive == .bigint) return primitive.bigint.toF64();
    return primitive.toNumber(runtime.allocator());
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
    const primitive = try runtime.valueToPrimitive(value);
    if (primitive == .bigint) return runtime.ownBigInt(try primitive.bigint.negate(runtime.allocator()));
    return .{ .number = -(try primitive.toNumber(runtime.allocator())) };
}

pub fn unaryPlus(runtime: *Runtime, value: Value) !Value {
    const primitive = try runtime.valueToPrimitive(value);
    if (primitive == .bigint) return error.CannotConvertBigIntToNumber;
    return .{ .number = try primitive.toNumber(runtime.allocator()) };
}

pub fn bitNot(runtime: *Runtime, value: Value) !Value {
    const primitive = try runtime.valueToPrimitive(value);
    if (primitive == .bigint) return runtime.ownBigInt(try primitive.bigint.bitNot(runtime.allocator()));
    return .{ .number = @floatFromInt(~toInt32(try primitive.toNumber(runtime.allocator()))) };
}

/// ECMAScriptの抽象関係比較。NaNを含む場合はnull（undefined result）を返す。
pub fn compare(runtime: *Runtime, left: Value, right: Value) !?std.math.Order {
    var left_root = left;
    var right_root = right;
    var frame = runtime.rootFrame();
    defer frame.deinit();
    try frame.protect(&left_root);
    try frame.protect(&right_root);
    const left_primitive = try runtime.valueToPrimitive(left_root);
    const right_primitive = try runtime.valueToPrimitive(right_root);
    if (left_primitive == .string and right_primitive == .string) return value_mod.String.order(left_primitive.string.*, right_primitive.string.*);
    if (left_primitive == .bigint and right_primitive == .bigint) return BigInt.order(left_primitive.bigint.*, right_primitive.bigint.*);
    if (left_primitive == .bigint and right_primitive == .string) {
        const converted = runtime.bigIntString(right_primitive.string) catch return null;
        return BigInt.order(left_primitive.bigint.*, converted.bigint.*);
    }
    if (left_primitive == .string and right_primitive == .bigint) {
        const converted = runtime.bigIntString(left_primitive.string) catch return null;
        return BigInt.order(converted.bigint.*, right_primitive.bigint.*);
    }
    if (left_primitive == .bigint) return compareBigIntNumber(left_primitive.bigint.*, try right_primitive.toNumber(runtime.allocator()));
    if (right_primitive == .bigint) {
        const order = (try compareBigIntNumber(right_primitive.bigint.*, try left_primitive.toNumber(runtime.allocator()))) orelse return null;
        return invertOrder(order);
    }
    const left_number = try left_primitive.toNumber(runtime.allocator());
    const right_number = try right_primitive.toNumber(runtime.allocator());
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

test "なでしこ式の加算は文字列を連結せず数値へ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const text = try runtime.stringUtf8("個");
    try std.testing.expect(std.math.isNan((try nadesikoAdd(&runtime, .{ .number = 3 }, text)).number));
    try std.testing.expectEqual(@as(f64, 7), (try nadesikoAdd(&runtime, try runtime.stringUtf8("5x"), .{ .number = 2 })).number);
    try std.testing.expect(std.math.isNan((try nadesikoAdd(&runtime, try runtime.createArray(), .{ .number = 1 })).number));
    try std.testing.expectError(error.CannotMixBigIntAndNumber, nadesikoAdd(&runtime, try runtime.bigIntLiteral("1n"), text));
}

test "増減文は未定義・文字列・BigIntをNumberへ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(f64, 1), (try increment(&runtime, .undefined, .{ .number = 1 })).number);
    try std.testing.expectEqual(@as(f64, 7), (try increment(&runtime, try runtime.stringUtf8("5"), .{ .number = 2 })).number);
    try std.testing.expectEqual(@as(f64, 7), (try increment(&runtime, try runtime.bigIntLiteral("5n"), .{ .number = 2 })).number);
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
