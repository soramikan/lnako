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

/// Fixed-shape Value ABI for the hot `文字数` builtin.  The input remains a
/// Value because String(value) can invoke ToPrimitive callbacks and therefore
/// cannot use the numeric double ABI.  Keeping this entry beside the existing
/// math ABI makes the generated call shape identical while avoiding the large
/// generic builtin switch for statically arity-checked calls.
pub export fn lnako_aot_unicode_length_call_site(out: *Value, input: *const Value, opcode: u16, site_id: u64) callconv(.c) void {
    const value = input.*;
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    var success = false;
    defer runtime.recordAotEntry(&runtime.counters.aot_unicode_length, success);
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "builtin", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "builtin", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "builtin", site_id);
    const start_epoch = runtime.failure_epoch;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "builtin", site_id, success);
    if (command != .unicode_length) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }

    // The caller's root slot already protects the input, but the conversion
    // path may invoke callbacks and collect. Keep a local rooted copy so the
    // dedicated ABI has the same GC boundary as the generic Value route.
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const units = state.valueUtf16Alloc(runtime, roots[0]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(units);
    out.* = state.numberValue(@floatFromInt(state.codePointCount(units)));
    success = runtime.failure_epoch == start_epoch;
}

/// Pure unary builtins which can use a fixed `double` argument ABI once the
/// compiler has proved the operand is numeric.  Commands omitted here keep
/// the generic Value ABI because they inspect objects, take two arguments, or
/// depend on runtime state (for example random numbers).
pub fn isMathUnaryF64Command(command: aot_builtin.Command) bool {
    return switch (command) {
        .to_int,
        .to_float,
        .math_sin,
        .math_cos,
        .math_tan,
        .math_arcsin,
        .math_arccos,
        .math_arctan,
        .math_rad2deg,
        .math_deg2rad,
        .math_sign,
        .math_abs,
        .math_exp,
        .math_log,
        .math_frac,
        .math_integer,
        .math_sqrt,
        .math_round,
        .math_ceil,
        .math_floor,
        => true,
        else => false,
    };
}

/// Numeric half of the pure unary builtin set.  Conversion and arity checks
/// remain in the generic dispatcher for dynamic operands; this helper only
/// receives the already-unboxed f64 value from the fixed ABI.
pub fn mathUnaryF64(command: aot_builtin.Command, value: f64) !f64 {
    return switch (command) {
        .to_int => state.parseIntNumberF64(value),
        .to_float => if (value == 0) 0 else value,
        .math_sin => @sin(value),
        .math_cos => @cos(value),
        .math_tan => @tan(value),
        .math_arcsin => std.math.asin(value),
        .math_arccos => std.math.acos(value),
        .math_arctan => std.math.atan(value),
        .math_rad2deg => value / std.math.pi * 180,
        .math_deg2rad => value / 180 * std.math.pi,
        .math_sign => if (value == 0) 0 else if (value > 0) 1 else -1,
        .math_abs => @abs(value),
        .math_exp => @exp(value),
        .math_log => @log(value),
        .math_frac => @rem(value, 1),
        .math_integer => @trunc(value),
        .math_sqrt => @sqrt(value),
        .math_round => mathRound(value),
        .math_ceil => @ceil(value),
        .math_floor => @floor(value),
        else => error.UnknownCommand,
    };
}

/// Fixed signature ABI for hot pure numeric builtins.  The dispatch trace,
/// route, failure epoch, and exception behavior intentionally mirror the
/// generic builtin call site; only the Value argument packing/conversion is
/// removed for statically proven numeric operands.
pub export fn lnako_aot_math_unary_f64_call_site(out: *Value, value: f64, opcode: u16, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    var success = false;
    defer runtime.recordAotEntry(&runtime.counters.aot_math_f64, success);
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "builtin", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "builtin", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    // Every opcode admitted by this ABI belongs to the ordinary builtin
    // route. Keeping the route literal avoids pulling the full route
    // classifier into a fixed-signature hot path.
    const route = "builtin";
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, route, site_id);
    const start_epoch = runtime.failure_epoch;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, route, site_id, success);
    if (!isMathUnaryF64Command(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    out.* = numberValue(mathUnaryF64(command, value) catch |failure| {
        runtime.setFailure(failure);
        return;
    });
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_math_unary_value_call_site(out: *Value, input: *const Value, opcode: u16, site_id: u64) callconv(.c) void {
    const value = input.*;
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    var success = false;
    defer runtime.recordAotEntry(&runtime.counters.aot_math_value, success);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    const root_input = value.tag != @intFromEnum(Tag.number);
    if (root_input) runtime.pushRoots(&frame, &roots, roots.len);
    defer if (root_input) runtime.popRoots(&frame);
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "builtin", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "builtin", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    // Every opcode admitted by this ABI belongs to the ordinary builtin
    // route. Keeping the route literal avoids pulling the full route
    // classifier into a fixed-signature hot path.
    const route = "builtin";
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, route, site_id);
    const start_epoch = runtime.failure_epoch;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, route, site_id, success);
    if (!isMathUnaryF64Command(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    out.* = mathUnaryValue(runtime, command, value) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

fn mathUnaryValue(runtime: *Runtime, command: aot_builtin.Command, value: Value) !Value {
    if (value.tag == @intFromEnum(Tag.number)) return numberValue(try mathUnaryF64(command, @bitCast(value.payload)));
    return switch (command) {
        .to_int => numberValue(try state.parseIntBuiltin(runtime, value)),
        .to_float => numberValue(try parseFloatBuiltin(runtime, value)),
        else => mathBuiltin(runtime, command, &.{value}),
    };
}

pub fn parseFloatBuiltin(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => blk: {
            const number: f64 = @bitCast(value.payload);
            break :blk if (number == 0) 0 else number;
        },
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
    return number_mod.roundHalfPositive(value);
}

test "AOT純粋数値builtin専用ABIはgeneric結果と例外境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    state.active_runtime.?.perf_counters_checked = true;
    state.active_runtime.?.perf_counters_enabled = true;

    var specialized: Value = .{};
    state.lnako_aot_math_unary_f64_call_site(&specialized, 9, @intFromEnum(aot_builtin.Command.math_sqrt), 0x11);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, -1.2, @intFromEnum(aot_builtin.Command.math_abs), 0x12);
    try std.testing.expectEqual(@as(f64, 1.2), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, -1.8, @intFromEnum(aot_builtin.Command.math_integer), 0x13);
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, -1.2, @intFromEnum(aot_builtin.Command.math_floor), 0x14);
    try std.testing.expectEqual(@as(f64, -2), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, -1.2, @intFromEnum(aot_builtin.Command.math_ceil), 0x15);
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, 1e21, @intFromEnum(aot_builtin.Command.to_int), 0x16);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(specialized.payload)));

    const input = numberValue(1e21);
    var generic: Value = .{};
    state.lnako_aot_builtin_call(&generic, @ptrCast(&input), 1, @intFromEnum(aot_builtin.Command.to_int));
    try std.testing.expectEqual(@as(f64, @bitCast(generic.payload)), @as(f64, @bitCast(specialized.payload)));

    // binary64の中間丸めで誤る境界を専用ABIでもgenericと同じく保つ。
    state.lnako_aot_math_unary_f64_call_site(&specialized, 0.49999999999999994, @intFromEnum(aot_builtin.Command.math_round), 0x1a);
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(specialized.payload)));
    state.lnako_aot_math_unary_f64_call_site(&specialized, 4503599627370497, @intFromEnum(aot_builtin.Command.math_round), 0x1b);
    try std.testing.expectEqual(@as(f64, 4503599627370497), @as(f64, @bitCast(specialized.payload)));

    state.lnako_aot_math_unary_f64_call_site(&specialized, 2, @intFromEnum(aot_builtin.Command.math_atan2), 0x17);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(specialized.tag)));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    _ = state.active_runtime.?.takeException();
    const math_counters = state.active_runtime.?.counters.aot_math_f64;
    try std.testing.expectEqual(@as(u64, 9), math_counters.calls);
    try std.testing.expectEqual(@as(u64, 8), math_counters.successes);
    try std.testing.expectEqual(@as(u64, 1), math_counters.failures);
    const generic_counters = state.active_runtime.?.counters.aot_generic_builtin;
    try std.testing.expectEqual(@as(u64, 1), generic_counters.calls);
    try std.testing.expectEqual(@as(u64, 1), generic_counters.successes);
    try std.testing.expectEqual(@as(u64, 0), generic_counters.failures);
}

test "fixed TOFLOAT normalizes negative zero like parseFloat String" {
    const converted = try mathUnaryF64(.to_float, -0.0);
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(converted)));
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const generic = try parseFloatBuiltin(&runtime, numberValue(-0.0));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(generic)));
}

test "single Value math ABI keeps numeric fast path and string coercion" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const numeric = try mathUnaryValue(&runtime, .math_sqrt, numberValue(16));
    const coerced = try mathUnaryValue(&runtime, .math_sqrt, state.staticStringValue("16"));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(numeric.payload)));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(coerced.payload)));
}
