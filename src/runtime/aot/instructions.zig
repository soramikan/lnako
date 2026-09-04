const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub export fn lnako_aot_bigint_truthy(value: *const state.Value) callconv(.c) c_int {
    const object = value.object() orelse return 0;
    if (object.payload != .bigint) return 0;
    return @intFromBool(!object.payload.bigint.isZero());
}

pub export fn lnako_aot_arithmetic(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.Arithmetic, opcode) orelse {
        runtime.setFailure(error.InvalidArithmeticOperator);
        return;
    };
    out.* = state.arithmetic(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_compare(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.Comparison, opcode) orelse {
        runtime.setFailure(error.InvalidComparison);
        return;
    };
    out.* = .{
        .tag = @intFromEnum(shared.Tag.boolean),
        .payload = @intFromBool(state.compareValues(runtime, operator, left.*, right.*) catch |failure| {
            runtime.setFailure(failure);
            return;
        }),
    };
}

pub export fn lnako_aot_shift(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.ShiftOperator, opcode) orelse {
        runtime.setFailure(error.InvalidShiftOperator);
        return;
    };
    out.* = state.shift(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_concat(out: *state.Value, left: *const state.Value, right: *const state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    out.* = state.concat(runtime, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_increment(target: *state.Value, amount: *const state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    target.* = state.incrementValue(runtime, target.*, amount.*);
}

pub export fn lnako_aot_index_get(out: *state.Value, container: *const state.Value, key: *const state.Value) callconv(.c) void {
    const container_value = container.*;
    const key_value = key.*;
    out.* = if (state.active_runtime) |*runtime| runtime.indexGet(container_value, key_value) else .{};
}

pub export fn lnako_aot_index_set(container: *const state.Value, key: *const state.Value, value: *const state.Value) callconv(.c) c_int {
    const runtime = if (state.active_runtime) |*active| active else return -1;
    if (container.tag == @intFromEnum(shared.Tag.undefined) or container.tag == @intFromEnum(shared.Tag.null_value)) {
        runtime.setIndexAssignmentFailure(container.*, key.*);
        return -1;
    }
    runtime.indexSet(container.*, key.*, value.*) catch return -1;
    return 0;
}

pub export fn lnako_aot_destructure_get(out: *state.Value, source: *const state.Value, index: usize) callconv(.c) void {
    out.* = if (state.active_runtime) |*runtime| runtime.destructureGet(source.*, index) else .{};
}

pub export fn lnako_aot_iterator_new(out: *state.Value, values: ?[*]const state.Value, len: usize, is_range: bool, direction: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createIterator(source, is_range, direction) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_iterator_has_next(iterator: *const state.Value) callconv(.c) c_int {
    return if (state.active_runtime) |*runtime| @intFromBool(runtime.iteratorHasNext(iterator.*)) else 0;
}

pub export fn lnako_aot_iterator_next(out: *state.Value, iterator: *const state.Value, repeat_target: ?*state.Value, value_target: ?*state.Value, key_target: ?*state.Value, range_target: ?*state.Value) callconv(.c) void {
    out.* = if (state.active_runtime) |*runtime| runtime.iteratorNext(iterator.*, repeat_target, value_target, key_target, range_target) else .{};
}

pub export fn lnako_aot_binding_cell_new(out: *state.Value, initial: ?*const state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    out.* = runtime.createBindingCell(if (initial) |value| value.* else .{}) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_binding_cell_value(cell: *state.Value) callconv(.c) *state.Value {
    if (cell.tag != @intFromEnum(shared.Tag.binding_cell)) state.runtimeFailure(error.InvalidBindingCell);
    const object = cell.object() orelse state.runtimeFailure(error.InvalidBindingCell);
    if (object.payload != .binding_cell) state.runtimeFailure(error.InvalidBindingCell);
    return &object.payload.binding_cell;
}

/// Dedicated ABI for the two commands that update the system `対象` value.
/// The target is explicit so a local variable named 対象 can never shadow the
/// command's side effect in generated LLVM.
pub export fn lnako_aot_cut(out: *state.Value, target: *state.Value, arguments: ?[*]const state.Value, len: usize, mode: u8) callconv(.c) void {
    lnako_aot_cut_site(out, target, arguments, len, mode, 0);
}

pub export fn lnako_aot_cut_site(out: *state.Value, target: *state.Value, arguments: ?[*]const state.Value, len: usize, mode: u8, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command: state.aot_builtin.Command = if (mode == 0) .cut else .cut_range;
    const opcode = @intFromEnum(command);
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "cut", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "cut", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const required: usize = if (mode == 0) 2 else if (mode == 1) 3 else 0;
    if (required == 0 or len < required) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = arguments.?;
    const result = state.cutBuiltin(runtime, values[0], values[1], if (mode == 1) values[2] else null, mode == 1) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    // state.cutBuiltin roots both values until this point; assign only after both
    // allocations and all delayed property accesses have succeeded.
    out.* = result.result;
    target.* = result.remainder;
    success = runtime.failure_epoch == start_epoch;
}
