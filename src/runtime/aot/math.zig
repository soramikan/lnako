const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const number_mod = shared.number_mod;

const Runtime = state.Runtime;
const Value = state.Value;
const Tag = state.Tag;
const numberValue = state.numberValue;
const valueToNumberRuntime = state.valueToNumberRuntime;
const valueUtf16Alloc = state.valueUtf16Alloc;
const staticStringValue = state.staticStringValue;
const time = state.time;

pub fn parseFloatBuiltin(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk try number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

pub fn mathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const a: Value = if (arguments.len > 0) arguments[0] else .{};
    const b: Value = if (arguments.len > 1) arguments[1] else .{};
    return switch (command) {
        .math_sin => numberValue(@sin(try valueToNumberRuntime(runtime, a))),
        .math_cos => numberValue(@cos(try valueToNumberRuntime(runtime, a))),
        .math_tan => numberValue(@tan(try valueToNumberRuntime(runtime, a))),
        .math_arcsin => numberValue(std.math.asin(try valueToNumberRuntime(runtime, a))),
        .math_arccos => numberValue(std.math.acos(try valueToNumberRuntime(runtime, a))),
        .math_arctan => numberValue(std.math.atan(try valueToNumberRuntime(runtime, a))),
        .math_atan2 => numberValue(std.math.atan2(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_coordinate_angle => numberValue(try mathCoordinateAngle(runtime, a)),
        .math_rad2deg => numberValue(try valueToNumberRuntime(runtime, a) / std.math.pi * 180),
        .math_deg2rad => numberValue(try valueToNumberRuntime(runtime, a) / 180 * std.math.pi),
        .math_sign => numberValue(try mathSign(runtime, a)),
        .math_abs => numberValue(@abs(try valueToNumberRuntime(runtime, a))),
        .math_exp => numberValue(@exp(try valueToNumberRuntime(runtime, a))),
        .math_hypot => numberValue(std.math.hypot(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_log => numberValue(@log(try valueToNumberRuntime(runtime, a))),
        .math_logn => numberValue(try mathLogarithm(runtime, a, b)),
        .math_frac => numberValue(@rem(try valueToNumberRuntime(runtime, a), 1)),
        .math_integer => numberValue(@trunc(try valueToNumberRuntime(runtime, a))),
        .math_sqrt => numberValue(@sqrt(try valueToNumberRuntime(runtime, a))),
        .math_round => numberValue(mathRound(try valueToNumberRuntime(runtime, a))),
        .math_decimal_ceil => numberValue(try mathDecimalRound(runtime, a, b, .ceil)),
        .math_decimal_floor => numberValue(try mathDecimalRound(runtime, a, b, .floor)),
        .math_decimal_round => numberValue(try mathDecimalRound(runtime, a, b, .round)),
        .math_ceil => numberValue(@ceil(try valueToNumberRuntime(runtime, a))),
        .math_floor => numberValue(@floor(try valueToNumberRuntime(runtime, a))),
        .math_random => try mathRandom(runtime, a),
        .math_random_range => try mathRandomRange(runtime, a, b),
        else => error.UnknownCommand,
    };
}

pub const default_random_seed: u64 = 5573589319906701683;

pub fn initialRandomState() u64 {
    const environment = std.c.getenv("LNAKO_TEST_RANDOM_SEED") orelse {
        const timestamp: u64 = @bitCast(time(null));
        const mixed = timestamp ^ @intFromPtr(&state.active_runtime);
        return if (mixed == 0) default_random_seed else mixed;
    };
    const parsed = std.fmt.parseInt(u64, std.mem.span(environment), 10) catch return default_random_seed;
    return if (parsed == 0) default_random_seed else parsed;
}

pub fn nextRandom(runtime: *Runtime) f64 {
    if (runtime.random_state == 0) runtime.random_state = initialRandomState();
    var value = runtime.random_state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    runtime.random_state = value;
    const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
    return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
}

pub fn mathRandom(runtime: *Runtime, source: Value) !Value {
    const random = nextRandom(runtime);
    if (source.tag == @intFromEnum(Tag.number)) return numberValue(@floor(random * @as(f64, @bitCast(source.payload))));

    var minimum: Value = .{};
    var maximum: Value = .{};
    switch (@as(Tag, @enumFromInt(source.tag))) {
        .array => {
            const items = source.object().?.payload.array.items;
            minimum = if (items.len > 0) items[0] else .{};
            maximum = if (items.len > 1) items[1] else .{};
        },
        .dictionary => {
            minimum = runtime.indexGet(source, staticStringValue("先頭"));
            maximum = runtime.indexGet(source, staticStringValue("末尾"));
        },
        else => return .{},
    }
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}

pub fn mathRandomRange(runtime: *Runtime, minimum: Value, maximum: Value) !Value {
    const random = nextRandom(runtime);
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}
pub fn mathCoordinateAngle(runtime: *Runtime, source: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return std.math.nan(f64);
    const items = source.object().?.payload.array.items;
    const x = try valueToNumberRuntime(runtime, if (items.len > 0) items[0] else .{});
    const y = try valueToNumberRuntime(runtime, if (items.len > 1) items[1] else .{});
    return std.math.atan2(y, x) / std.math.pi * 180;
}

pub fn mathParseFloat(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

pub fn mathSign(runtime: *Runtime, source: Value) !f64 {
    const parsed = try mathParseFloat(runtime, source);
    if (parsed == 0) return 0;
    const coerced = try valueToNumberRuntime(runtime, source);
    return if (coerced > 0) 1 else -1;
}

pub fn mathLogarithm(runtime: *Runtime, base_value: Value, source_value: Value) !f64 {
    const base = try valueToNumberRuntime(runtime, base_value);
    const source = try valueToNumberRuntime(runtime, source_value);
    if (base == 2) return std.math.log2e * @log(source);
    if (base == 10) return std.math.log10e * @log(source);
    return @log(source) / @log(base);
}

const MathDecimalMode = enum { ceil, floor, round };

pub fn mathDecimalRound(runtime: *Runtime, source: Value, digits_value: Value, mode: MathDecimalMode) !f64 {
    const value = try valueToNumberRuntime(runtime, source);
    const digits = try valueToNumberRuntime(runtime, digits_value);
    const base = std.math.pow(f64, 10, digits);
    const scaled = value * base;
    const rounded = switch (mode) {
        .ceil => @ceil(scaled),
        .floor => @floor(scaled),
        .round => mathRound(scaled),
    };
    return rounded / base;
}

pub fn mathRound(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const result = @floor(value + 0.5);
    if (result == 0 and value < 0) return -0.0;
    return result;
}
