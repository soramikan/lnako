const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

/// Registers one absolute native-plugin path embedded by the LLVM module.
/// Loading is deferred until the first plugin command so AOT startup retains
/// the same lazy behavior as the Interpreter while keeping the normal path
/// free of JavaScript runtime code.
pub export fn lnako_aot_native_plugin_register(path: ?[*]const u8, len: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const path_pointer = path orelse {
        if (len != 0) runtime.setFailure(error.InvalidArgumentCount);
        return;
    };
    const path_slice = path_pointer[0..len];
    if (path_slice.len == 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    for (runtime.native_plugin_paths.items) |candidate| if (std.mem.eql(u8, candidate, path_slice)) return;
    const owned_path = runtime.allocator.dupe(u8, path_slice) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    runtime.native_plugin_paths.append(runtime.allocator, owned_path) catch |failure| {
        runtime.allocator.free(owned_path);
        runtime.setFailure(failure);
    };
}

/// Registers a generated global with the embedded Zig interpreter used by
/// `ナデシコ` and `ナデシコ続`. The pointer remains valid for the generated
/// program lifetime and lets dynamic code observe and update ordinary AOT
/// globals without crossing the JavaScript compatibility boundary.
pub export fn lnako_aot_dynamic_global_register(name: ?[*]const u8, len: usize, slot: ?*state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const name_pointer = name orelse {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    };
    const value_slot = slot orelse {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    };
    const name_slice = name_pointer[0..len];
    if (state.dynamicGlobal(runtime, name_slice)) |entry| {
        entry.slot = value_slot;
        entry.value = value_slot.*;
        return;
    }
    const owned_name = runtime.allocator.dupe(u8, name_slice) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    runtime.dynamic_globals.append(runtime.allocator, .{ .name = owned_name, .value = value_slot.*, .slot = value_slot }) catch |failure| {
        runtime.allocator.free(owned_name);
        runtime.setFailure(failure);
    };
}

/// Dedicated ABI for the two runtime-source commands. The source is parsed,
/// lowered, verified, and executed by the normal Zig interpreter in a
/// persistent per-process state; no JavaScript engine is loaded in this path.
pub export fn lnako_aot_dynamic_call(
    out: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "dynamic-execute", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "dynamic-execute", site_id, false);
        return;
    };
    if (command != .system_nadesiko and command != .system_nadesiko_continue) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "dynamic-execute", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "dynamic-execute", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.dynamicBuiltin(runtime, command, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

/// Invokes a named native-plugin command through the same `lnako_plugin_v1`
/// ABI used by the Interpreter. The adapter owns a persistent ordinary Zig
/// Interpreter for plugin host callbacks, while values and settled promises
/// are copied into the AOT heap; no JavaScript compatibility runtime is used.
pub export fn lnako_aot_native_plugin_call(
    out: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    name: ?[*]const u8,
    name_len: usize,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const name_pointer = name orelse {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    };
    const command_name = name_pointer[0..name_len];
    const call_id = runtime.dispatch_trace.begin(command_name, 0, "native-plugin", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, 0, "native-plugin", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nativePluginBuiltin(runtime, command_name, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_function_new(out: *state.Value, callback: state.FunctionCallback, arity: usize, captures: ?[*]const state.Value, capture_count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (captures) |pointer| pointer[0..capture_count] else if (capture_count == 0) &.{} else state.runtimeFailure(error.InvalidCaptures);
    for (source) |capture| if (capture.tag != @intFromEnum(shared.Tag.binding_cell)) state.runtimeFailure(error.InvalidBindingCell);
    out.* = runtime.createFunction(callback, arity, source) catch |failure| state.runtimeFailure(failure);
}

/// Named variant used by LLVM-generated functions. The original ABI remains
/// available for embedders and unit tests that intentionally create an
/// anonymous native function.
pub export fn lnako_aot_function_new_named(
    out: *state.Value,
    callback: state.FunctionCallback,
    arity: usize,
    name: ?[*]const u8,
    name_len: usize,
    captures: ?[*]const state.Value,
    capture_count: usize,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const function_name = if (name) |pointer| pointer[0..name_len] else if (name_len == 0) &.{} else state.runtimeFailure(error.InvalidFunctionName);
    const source = if (captures) |pointer| pointer[0..capture_count] else if (capture_count == 0) &.{} else state.runtimeFailure(error.InvalidCaptures);
    for (source) |capture| if (capture.tag != @intFromEnum(shared.Tag.binding_cell)) state.runtimeFailure(error.InvalidBindingCell);
    out.* = runtime.createNamedFunction(callback, arity, function_name, source) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_function_capture(out: *state.Value, context: *anyopaque, index: usize) callconv(.c) void {
    const object: *state.Object = @ptrCast(@alignCast(context));
    if (object.payload != .function or index >= object.payload.function.captures.len) state.runtimeFailure(error.InvalidClosureCapture);
    out.* = object.payload.function.captures[index];
}

pub export fn lnako_aot_function_call(out: *state.Value, callable: *const state.Value, arguments: ?[*]const state.Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (callable.tag != @intFromEnum(shared.Tag.function)) state.runtimeFailure(error.NotCallable);
    const object = callable.object() orelse state.runtimeFailure(error.NotCallable);
    if (object.payload != .function) state.runtimeFailure(error.NotCallable);
    const function = object.payload.function;
    if (arguments == null and len != 0) state.runtimeFailure(error.InvalidArguments);
    switch (function.promise_kind) {
        .none => {},
        .resolver => |resolver| {
            const settled = if (len > 0) arguments.?[0] else state.Value{};
            if (resolver.rejected) {
                state.rejectAotPromise(runtime, resolver.promise, settled) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            } else {
                state.resolveAotPromise(runtime, resolver.promise, settled) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            }
            return;
        },
        .all_handler => |handler| {
            const settled = if (len > 0) arguments.?[0] else state.Value{};
            out.* = state.handleAotPromiseAll(runtime, handler, settled) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            return;
        },
    }
    var padded: ?[]state.Value = null;
    defer if (padded) |values| runtime.allocator.free(values);
    var call_arguments = arguments;
    if (len < function.arity) {
        const values = runtime.allocator.alloc(state.Value, function.arity) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        padded = values;
        if (arguments) |source| @memcpy(values[0..len], source[0..len]);
        values[len] = runtime.systemContext() catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        @memset(values[len + 1 ..], .{});
        call_arguments = values.ptr;
    }
    function.callback(out, @ptrCast(object), call_arguments, function.arity);
}
