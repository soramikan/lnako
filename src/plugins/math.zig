const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Context = struct {
    context: *anyopaque,
    randomFn: *const fn (context: *anyopaque) anyerror!f64,

    fn random(self: ?Context) !f64 {
        const actual = self orelse return error.RandomSourceUnavailable;
        const result = try actual.randomFn(actual.context);
        if (!std.math.isFinite(result) or result < 0 or result >= 1) return error.InvalidRandomValue;
        return result;
    }
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    if (eql(name, "SIN")) return number(@sin(try runtime.valueToNumber(a)));
    if (eql(name, "COS")) return number(@cos(try runtime.valueToNumber(a)));
    if (eql(name, "TAN")) return number(@tan(try runtime.valueToNumber(a)));
    if (eql(name, "ARCSIN")) return number(std.math.asin(try runtime.valueToNumber(a)));
    if (eql(name, "ARCCOS")) return number(std.math.acos(try runtime.valueToNumber(a)));
    if (eql(name, "ARCTAN")) return number(std.math.atan(try runtime.valueToNumber(a)));
    if (eql(name, "ATAN2")) return number(std.math.atan2(try runtime.valueToNumber(a), try runtime.valueToNumber(b)));
    if (eql(name, "座標角度計算")) return number(try coordinateAngle(runtime, a));
    if (isAny(name, &.{ "RAD2DEG", "度変換" })) return number(try runtime.valueToNumber(a) / std.math.pi * 180);
    if (isAny(name, &.{ "DEG2RAD", "ラジアン変換" })) return number(try runtime.valueToNumber(a) / 180 * std.math.pi);
    if (isAny(name, &.{ "SIGN", "符号" })) return number(try sign(runtime, a));
    if (isAny(name, &.{ "ABS", "絶対値" })) return number(@abs(try runtime.valueToNumber(a)));
    if (eql(name, "EXP")) return number(@exp(try runtime.valueToNumber(a)));
    if (isAny(name, &.{ "HYPOT", "斜辺" })) return number(std.math.hypot(try runtime.valueToNumber(a), try runtime.valueToNumber(b)));
    if (isAny(name, &.{ "LN", "LOG" })) return number(@log(try runtime.valueToNumber(a)));
    if (eql(name, "LOGN")) return number(try logarithm(runtime, a, b));
    if (isAny(name, &.{ "FRAC", "小数部分" })) return number(@rem(try runtime.valueToNumber(a), 1));
    if (eql(name, "整数部分")) return number(@trunc(try runtime.valueToNumber(a)));
    if (eql(name, "乱数")) return try randomValue(runtime, a, context);
    if (eql(name, "乱数範囲")) return number(@floor(try Context.random(context) * (try runtime.valueToNumber(b) - try runtime.valueToNumber(a) + 1)) + try runtime.valueToNumber(a));
    if (isAny(name, &.{ "SQRT", "平方根" })) return number(@sqrt(try runtime.valueToNumber(a)));
    if (isAny(name, &.{ "ROUND", "四捨五入" })) return number(jsRound(try runtime.valueToNumber(a)));
    if (eql(name, "小数点切上")) return number(try decimalRound(runtime, a, b, .ceil));
    if (eql(name, "小数点切下")) return number(try decimalRound(runtime, a, b, .floor));
    if (eql(name, "小数点四捨五入")) return number(try decimalRound(runtime, a, b, .round));
    if (isAny(name, &.{ "CEIL", "切上" })) return number(@ceil(try runtime.valueToNumber(a)));
    if (isAny(name, &.{ "FLOOR", "切捨" })) return number(@floor(try runtime.valueToNumber(a)));
    return null;
}

fn coordinateAngle(runtime: *Runtime, source: Value) !f64 {
    if (source != .array) return std.math.nan(f64);
    const x = try runtime.valueToNumber(source.array.get(0));
    const y = try runtime.valueToNumber(source.array.get(1));
    return std.math.atan2(y, x) / std.math.pi * 180;
}

fn sign(runtime: *Runtime, source: Value) !f64 {
    const parsed = try common.parseFloatValue(runtime, source);
    if (parsed == 0) return 0;
    const coerced = try runtime.valueToNumber(source);
    return if (coerced > 0) 1 else -1;
}

fn logarithm(runtime: *Runtime, base_value: Value, source_value: Value) !f64 {
    const base = try runtime.valueToNumber(base_value);
    const source = try runtime.valueToNumber(source_value);
    if (base == 2) return std.math.log2e * @log(source);
    if (base == 10) return std.math.log10e * @log(source);
    return @log(source) / @log(base);
}

fn randomValue(runtime: *Runtime, source: Value, context: ?Context) !Value {
    const random = try Context.random(context);
    if (source == .number) return number(@floor(random * source.number));
    var minimum: Value = .undefined;
    var maximum: Value = .undefined;
    if (source == .array) {
        minimum = source.array.get(0);
        maximum = source.array.get(1);
    } else if (source == .dictionary) {
        var first = try runtime.stringUtf8("先頭");
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&first);
        var last = try runtime.stringUtf8("末尾");
        try roots.protect(&last);
        minimum = source.dictionary.get(first.string) orelse return .undefined;
        maximum = source.dictionary.get(last.string) orelse .undefined;
    } else return .undefined;
    const lower = try runtime.valueToNumber(minimum);
    const upper = try runtime.valueToNumber(maximum);
    return number(@floor(random * (upper - lower + 1)) + lower);
}

const DecimalMode = enum { ceil, floor, round };

fn decimalRound(runtime: *Runtime, source: Value, digits_value: Value, mode: DecimalMode) !f64 {
    const value = try runtime.valueToNumber(source);
    const digits = try runtime.valueToNumber(digits_value);
    const base = std.math.pow(f64, 10, digits);
    const scaled = value * base;
    const rounded = switch (mode) {
        .ceil => @ceil(scaled),
        .floor => @floor(scaled),
        .round => jsRound(scaled),
    };
    return rounded / base;
}

fn jsRound(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const result = @floor(value + 0.5);
    if (result == 0 and value < 0) return -0.0;
    return result;
}

fn number(value: f64) Value {
    return .{ .number = value };
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "三角・対数・丸め・固定乱数を計算する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var random = FixedRandom{};
    const context = Context{ .context = &random, .randomFn = FixedRandom.next };
    try std.testing.expectApproxEqAbs(@as(f64, 1), (try call(&runtime, "SIN", &.{.{ .number = @as(f64, std.math.pi) / 2 }}, context)).?.number, 1e-14);
    try std.testing.expectEqual(@as(f64, -1), (try call(&runtime, "ROUND", &.{.{ .number = -1.5 }}, context)).?.number);
    try std.testing.expectEqual(@as(f64, 2), (try call(&runtime, "乱数範囲", &.{ .{ .number = 1 }, .{ .number = 3 } }, context)).?.number);
}

const FixedRandom = struct {
    fn next(_: *anyopaque) !f64 {
        return 0.5;
    }
};
