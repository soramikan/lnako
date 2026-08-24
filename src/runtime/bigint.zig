const std = @import("std");

const Managed = std.math.big.int.Managed;

/// Zig標準ライブラリの多倍長整数を、なでしこ値ランタイムの所有権規則へ合わせて包む。
pub const BigInt = struct {
    managed: Managed,

    pub fn init(allocator: std.mem.Allocator, value: anytype) !BigInt {
        return .{ .managed = try Managed.initSet(allocator, value) };
    }

    pub fn parseLiteral(allocator: std.mem.Allocator, source: []const u8) !BigInt {
        var text = source;
        if (text.len > 0 and (text[text.len - 1] == 'n' or text[text.len - 1] == 'N')) text = text[0 .. text.len - 1];
        return parseDigits(allocator, text, true);
    }

    pub fn parseString(allocator: std.mem.Allocator, source: []const u8) !BigInt {
        const trimmed = std.mem.trim(u8, source, " \t\r\n\x0b\x0c");
        if (trimmed.len == 0) return init(allocator, 0);
        return parseDigits(allocator, trimmed, false);
    }

    fn parseDigits(allocator: std.mem.Allocator, input: []const u8, allow_separator: bool) !BigInt {
        if (input.len == 0) return error.InvalidBigInt;
        var text = input;
        var base: u8 = 10;
        var negative = false;
        var had_sign = false;
        if (text[0] == '-' or text[0] == '+') {
            had_sign = true;
            negative = text[0] == '-';
            text = text[1..];
            if (text.len == 0) return error.InvalidBigInt;
        }
        if (text.len >= 2 and text[0] == '0') {
            const prefix = std.ascii.toLower(text[1]);
            if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
                if (had_sign) return error.InvalidBigInt;
                base = if (prefix == 'x') 16 else if (prefix == 'o') 8 else 2;
                text = text[2..];
            }
        }
        if (text.len == 0) return error.InvalidBigInt;
        for (text, 0..) |character, index| {
            if (character == '_') {
                if (!allow_separator or index == 0 or index + 1 == text.len or text[index - 1] == '_') return error.InvalidBigInt;
                continue;
            }
            _ = std.fmt.charToDigit(character, base) catch return error.InvalidBigInt;
        }
        var managed = try Managed.init(allocator);
        errdefer managed.deinit();
        if (negative) {
            const signed_text = try std.fmt.allocPrint(allocator, "-{s}", .{text});
            defer allocator.free(signed_text);
            managed.setString(base, signed_text) catch return error.InvalidBigInt;
        } else managed.setString(base, text) catch return error.InvalidBigInt;
        if (managed.eqlZero()) managed.setSign(true);
        return .{ .managed = managed };
    }

    pub fn deinit(self: *BigInt) void {
        self.managed.deinit();
        self.* = undefined;
    }

    pub fn clone(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        return .{ .managed = try self.managed.cloneWithDifferentAllocator(allocator) };
    }

    pub fn eql(left: BigInt, right: BigInt) bool {
        return Managed.eql(left.managed, right.managed);
    }

    pub fn order(left: BigInt, right: BigInt) std.math.Order {
        return Managed.order(left.managed, right.managed);
    }

    pub fn isZero(self: BigInt) bool {
        return self.managed.eqlZero();
    }

    pub fn isNegative(self: BigInt) bool {
        return !self.managed.isPositive() and !self.isZero();
    }

    pub fn toU32(self: BigInt) !u32 {
        return self.managed.toInt(u32);
    }

    pub fn toI64(self: BigInt) !i64 {
        return self.managed.toInt(i64);
    }

    pub fn toString(self: BigInt, allocator: std.mem.Allocator, base: u8) ![]u8 {
        return self.managed.toString(allocator, base, .lower);
    }

    pub fn toF64(self: BigInt) f64 {
        return self.managed.toFloat(f64, .nearest_even)[0];
    }

    pub fn fromF64(allocator: std.mem.Allocator, value: f64) !BigInt {
        if (!std.math.isFinite(value) or @trunc(value) != value) return error.InvalidBigIntNumber;
        if (value == 0) return init(allocator, 0);
        const bits: u64 = @bitCast(value);
        const negative = bits >> 63 != 0;
        const exponent_bits: u11 = @truncate(bits >> 52);
        const fraction = bits & ((@as(u64, 1) << 52) - 1);
        const significand = if (exponent_bits == 0) fraction else fraction | (@as(u64, 1) << 52);
        const exponent: i32 = if (exponent_bits == 0) -1022 - 52 else @as(i32, exponent_bits) - 1023 - 52;
        var result = try init(allocator, significand);
        errdefer result.deinit();
        if (exponent >= 0) {
            try result.managed.shiftLeft(&result.managed, @intCast(exponent));
        } else {
            try result.managed.shiftRight(&result.managed, @intCast(-exponent));
        }
        if (negative and !result.isZero()) result.managed.negate();
        return result;
    }

    pub fn add(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.add(&left.managed, &right.managed);
        return result;
    }

    pub fn sub(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.sub(&left.managed, &right.managed);
        return result;
    }

    pub fn mul(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.mul(&left.managed, &right.managed);
        return result;
    }

    pub fn divTrunc(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        if (right.isZero()) return error.DivisionByZero;
        var quotient = try init(allocator, 0);
        errdefer quotient.deinit();
        var remainder = try init(allocator, 0);
        defer remainder.deinit();
        try quotient.managed.divTrunc(&remainder.managed, &left.managed, &right.managed);
        return quotient;
    }

    pub fn rem(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        if (right.isZero()) return error.DivisionByZero;
        var quotient = try init(allocator, 0);
        defer quotient.deinit();
        var remainder = try init(allocator, 0);
        errdefer remainder.deinit();
        try quotient.managed.divTrunc(&remainder.managed, &left.managed, &right.managed);
        return remainder;
    }

    pub fn pow(self: BigInt, allocator: std.mem.Allocator, exponent: u32) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.pow(&self.managed, exponent);
        return result;
    }

    pub fn negate(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        var result = try self.clone(allocator);
        if (!result.isZero()) result.managed.negate();
        return result;
    }

    pub fn bitAnd(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.bitAnd(&left.managed, &right.managed);
        return result;
    }

    pub fn bitOr(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.bitOr(&left.managed, &right.managed);
        return result;
    }

    pub fn bitXor(left: BigInt, allocator: std.mem.Allocator, right: BigInt) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.bitXor(&left.managed, &right.managed);
        return result;
    }

    pub fn bitNot(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        var result = try self.negate(allocator);
        errdefer result.deinit();
        try result.managed.addScalar(&result.managed, -1);
        return result;
    }

    pub fn shiftLeft(self: BigInt, allocator: std.mem.Allocator, amount: usize) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.shiftLeft(&self.managed, amount);
        return result;
    }

    pub fn shiftRight(self: BigInt, allocator: std.mem.Allocator, amount: usize) !BigInt {
        var result = try init(allocator, 0);
        errdefer result.deinit();
        try result.managed.shiftRight(&self.managed, amount);
        return result;
    }
};

test "任意精度BigIntを解析して四則演算する" {
    var left = try BigInt.parseLiteral(std.testing.allocator, "123456789012345678901234567890n");
    defer left.deinit();
    var right = try BigInt.parseLiteral(std.testing.allocator, "0x10n");
    defer right.deinit();
    var sum = try left.add(std.testing.allocator, right);
    defer sum.deinit();
    const sum_text = try sum.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(sum_text);
    try std.testing.expectEqualStrings("123456789012345678901234567906", sum_text);
    var quotient = try left.divTrunc(std.testing.allocator, right);
    defer quotient.deinit();
    var remainder = try left.rem(std.testing.allocator, right);
    defer remainder.deinit();
    const remainder_text = try remainder.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(remainder_text);
    try std.testing.expectEqualStrings("2", remainder_text);
    try std.testing.expect(!quotient.isZero());
}

test "負数のBigIntビット演算を無限長2の補数として扱う" {
    var value = try BigInt.init(std.testing.allocator, 5);
    defer value.deinit();
    var inverted = try value.bitNot(std.testing.allocator);
    defer inverted.deinit();
    const text = try inverted.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("-6", text);
    var negative = try BigInt.init(std.testing.allocator, -8);
    defer negative.deinit();
    var shifted = try negative.shiftRight(std.testing.allocator, 2);
    defer shifted.deinit();
    const shifted_text = try shifted.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(shifted_text);
    try std.testing.expectEqualStrings("-2", shifted_text);
}

test "BigInt文字列の区切りと不正入力を区別する" {
    var literal = try BigInt.parseLiteral(std.testing.allocator, "1_000n");
    defer literal.deinit();
    try std.testing.expectError(error.InvalidBigInt, BigInt.parseString(std.testing.allocator, "1_000"));
    try std.testing.expectError(error.InvalidBigInt, BigInt.parseLiteral(std.testing.allocator, "1__0n"));
}

test "巨大なBigIntを精度を落とさず保持する" {
    var ten = try BigInt.init(std.testing.allocator, 10);
    defer ten.deinit();
    var power = try ten.pow(std.testing.allocator, 1000);
    defer power.deinit();
    const text = try power.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1001), text.len);
    try std.testing.expect(text[0] == '1');
    for (text[1..]) |digit| try std.testing.expect(digit == '0');
}
