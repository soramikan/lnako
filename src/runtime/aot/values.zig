const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub const Tag = shared.Tag;
pub const no_dispatch_call_id = shared.no_dispatch_call_id;
pub const Value = state.Value;
pub const RootFrame = state.RootFrame;

pub export fn lnako_aot_string_new(out: *state.Value, units: ?[*]const u16, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (units) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createString(source) catch return;
}

pub export fn lnako_aot_print_utf16(value: *const state.Value, newline: bool) callconv(.c) void {
    const object = value.object() orelse return;
    if (object.payload != .utf16_string) return;
    state.writeUtf16(object.payload.utf16_string, newline);
}

pub export fn lnako_aot_print_number(value: *const state.Value, newline: bool) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (value.tag != @intFromEnum(shared.Tag.number)) return;
    const text = state.numberString(runtime.allocator, @bitCast(value.payload)) catch return;
    defer runtime.allocator.free(text);
    state.writeBytes(text, newline);
}

pub export fn lnako_aot_bigint_new(out: *state.Value, source: ?[*]const u8, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const text = if (source) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createBigInt(text) catch return;
}

pub export fn lnako_aot_print_bigint(value: *const state.Value, newline: bool) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const object = value.object() orelse return;
    if (object.payload != .bigint) return;
    const text = object.payload.bigint.toString(runtime.allocator, 10) catch return;
    defer runtime.allocator.free(text);
    state.writeBytes(text, newline);
}

pub export fn lnako_aot_print_collection(value: *const state.Value, newline: bool) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (value.tag != @intFromEnum(shared.Tag.array) and value.tag != @intFromEnum(shared.Tag.dictionary)) return;
    const units = state.valueUtf16Alloc(runtime, value.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(units);
    state.writeUtf16(units, newline);
}

pub export fn lnako_aot_display_value(value: *const state.Value, newline: bool, display_log: ?*state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    state.displayValue(runtime, value.*, newline, display_log) catch |failure| runtime.setFailure(failure);
}

/// AOT版`デバッグ表示`は、LLVMが保持しているソース位置をABIで受け取り、
/// 公式命令のJSON化と「ファイル名(行): 値」形式を純Zigで再現する。
pub export fn lnako_aot_debug_display(
    out: *state.Value,
    value: ?*const state.Value,
    line: u64,
    source_path: ?[*]const u8,
    source_len: usize,
    display_log: ?*state.Value,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const path = if (source_path) |pointer| pointer[0..source_len] else if (source_len == 0) &.{} else {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    };
    const command = state.aot_builtin.Command.system_debug_display;
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, @intFromEnum(command), "debug-display", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, @intFromEnum(command), "debug-display", site_id, success);
    state.debugDisplayBuiltin(runtime, if (value) |pointer| pointer.* else .{}, line, path, display_log) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_display_many(values: ?[*]const state.Value, len: usize, display_log: ?*state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (values) |pointer| pointer[0..len] else &.{};
    state.displayMany(runtime, actual, display_log) catch |failure| runtime.setFailure(failure);
}

pub export fn lnako_aot_array_new(out: *state.Value, values: ?[*]const state.Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createArray(source) catch return;
}

pub export fn lnako_aot_dictionary_new(out: *state.Value, values: ?[*]const state.Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createObjectLiteral(source) catch return;
}

pub export fn lnako_aot_caniuse_agents_new(out: *state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    out.* = state.caniuseAgentsBuiltin(runtime) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_era_data_new(out: *state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    out.* = state.eraDataBuiltin(runtime) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}
