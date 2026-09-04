const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub export fn lnako_aot_runtime_init() callconv(.c) c_int {
    state.aot_interrupt_requested.store(false, .release);
    shared.AotWindowsStdout.configure();
    if (state.active_runtime == null) {
        var runtime: state.Runtime = .{ .allocator = std.heap.c_allocator, .random_state = state.initialRandomState() };
        runtime.process_io = std.Io.Threaded.init(std.heap.c_allocator, .{ .environ = state.aotProcessEnvironment() });
        runtime.process_io_initialized = true;
        state.active_runtime = runtime;
    }
    return 0;
}

pub export fn lnako_aot_global_read_site(site_id: u64) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.global_trace.record(site_id);
}

pub export fn lnako_aot_global_write_site(site_id: u64) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.global_trace.recordWrite(site_id);
}

pub export fn lnako_aot_literal_site(site_id: u64) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.literal_trace.record(site_id);
}

pub export fn lnako_aot_node_constants_init(
    command_line: ?*state.Value,
    runtime_name: ?*state.Value,
    runtime_path: ?*state.Value,
    argc: i32,
    argv: ?*const anyopaque,
) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const count: usize = if (argc > 0) @intCast(argc) else 0;

    if (command_line) |out| {
        out.* = runtime.createArray(&.{}) catch |failure| state.runtimeFailure(failure);
        var frame = state.RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(out), 1);
        defer runtime.popRoots(&frame);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const value = state.runtimeUtf8StringLossy(runtime, aotProcessArgument(argv, index)) catch |failure| state.runtimeFailure(failure);
            out.object().?.payload.array.append(runtime.allocator, value) catch |failure| state.runtimeFailure(failure);
        }
    }

    const first = aotProcessArgument(argv, 0);
    if (runtime_path) |out| out.* = state.runtimeUtf8StringLossy(runtime, first) catch |failure| state.runtimeFailure(failure);
    if (runtime_name) |out| out.* = state.runtimeUtf8StringLossy(runtime, state.nodeBasename(first)) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_node_constants_init_wide(
    command_line: ?*state.Value,
    runtime_name: ?*state.Value,
    runtime_path: ?*state.Value,
    argc: i32,
    argv: ?*const anyopaque,
) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const count: usize = if (argc > 0) @intCast(argc) else 0;

    if (command_line) |out| {
        out.* = runtime.createArray(&.{}) catch |failure| state.runtimeFailure(failure);
        var frame = state.RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(out), 1);
        defer runtime.popRoots(&frame);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const value = runtime.createString(aotProcessWideArgument(argv, index)) catch |failure| state.runtimeFailure(failure);
            out.object().?.payload.array.append(runtime.allocator, value) catch |failure| state.runtimeFailure(failure);
        }
    }

    const first = aotProcessWideArgument(argv, 0);
    if (runtime_path) |out| out.* = runtime.createString(first) catch |failure| state.runtimeFailure(failure);
    if (runtime_name) |out| out.* = runtime.createString(state.nodeBasenameWideFor(first, true)) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_node_directory_constants_init(
    desktop: ?*state.Value,
    documents: ?*state.Value,
    temporary: ?*state.Value,
) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (desktop) |out| out.* = state.nodeDirectoryBuiltin(runtime, .node_desktop) catch |failure| state.runtimeFailure(failure);
    if (documents) |out| out.* = state.nodeDirectoryBuiltin(runtime, .node_documents) catch |failure| state.runtimeFailure(failure);
    if (temporary) |out| out.* = state.nodeDirectoryBuiltin(runtime, .node_temporary_directory) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_node_mother_path_init(
    mother_path: ?*state.Value,
    source_path: ?[*]const u8,
    source_len: u64,
) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const source = if (source_path) |pointer| pointer[0..@as(usize, @intCast(source_len))] else &.{};
    const absolute_source = if (std.fs.path.isAbsolute(source))
        runtime.allocator.dupe(u8, source) catch |failure| state.runtimeFailure(failure)
    else blk: {
        const cwd = state.currentDirectoryAlloc(runtime) catch |failure| state.runtimeFailure(failure);
        defer runtime.allocator.free(cwd);
        break :blk std.fs.path.resolve(runtime.allocator, &.{ cwd, source }) catch |failure| state.runtimeFailure(failure);
    };
    defer runtime.allocator.free(absolute_source);
    const directory = state.nodeDirname(absolute_source);
    runtime.setAotSourceDirectory(directory) catch |failure| state.runtimeFailure(failure);
    if (mother_path) |out| out.* = state.runtimeUtf8StringLossy(runtime, directory) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_runtime_deinit() callconv(.c) void {
    state.aot_interrupt_requested.store(false, .release);
    if (state.active_runtime) |*runtime| runtime.deinit();
    state.active_runtime = null;
}

pub export fn lnako_aot_push_roots(frame: *state.RootFrame, values: ?[*]state.Value, len: usize) callconv(.c) void {
    if (state.active_runtime) |*runtime| runtime.pushRoots(frame, values, len);
}

pub export fn lnako_aot_pop_roots(frame: *state.RootFrame) callconv(.c) void {
    if (state.active_runtime) |*runtime| runtime.popRoots(frame);
}

pub export fn lnako_aot_collect() callconv(.c) usize {
    return if (state.active_runtime) |*runtime| runtime.collect() else 0;
}

pub export fn lnako_aot_exception_set(value: *const state.Value) callconv(.c) void {
    if (state.active_runtime) |*runtime| runtime.setException(value.*);
}

pub export fn lnako_aot_exception_set_error_message(value: *const state.Value) callconv(.c) void {
    if (state.active_runtime) |*runtime| runtime.setErrorMessage(value.*);
}

pub export fn lnako_aot_exception_pending() callconv(.c) c_int {
    return if (state.active_runtime) |runtime| @intFromBool(runtime.has_pending_exception) else 0;
}

pub export fn lnako_aot_exception_take(out: *state.Value) callconv(.c) void {
    out.* = if (state.active_runtime) |*runtime| runtime.takeException() else .{};
}

pub export fn lnako_aot_exception_abort() callconv(.c) noreturn {
    if (state.active_runtime) |*runtime| {
        if (runtime.has_pending_exception) {
            const message = state.pendingExceptionMessageUtf8Alloc(runtime) catch {
                // The exception is already pending, but formatting it may
                // allocate (for example for an array value).  Never replace
                // this path with an allocator panic or recurse through the
                // exception machinery: retain the established safe fallback.
                state.runtimeFailure(error.NakoException);
            };
            defer runtime.allocator.free(message);
            std.debug.print("[実行時エラー] {s}\n", .{message});
            std.process.exit(1);
        }
    }
    state.runtimeFailure(error.NakoException);
}

pub export fn lnako_aot_dispatch_display_begin(site_id: u64) callconv(.c) u64 {
    var ignored_epoch: u64 = 0;
    return lnako_aot_dispatch_display_begin_with_epoch(site_id, &ignored_epoch);
}

pub export fn lnako_aot_dispatch_display_begin_with_epoch(site_id: u64, epoch_out: *u64) callconv(.c) u64 {
    const runtime = if (state.active_runtime) |*active| active else {
        epoch_out.* = 0;
        return shared.no_dispatch_call_id;
    };
    epoch_out.* = runtime.failure_epoch;
    return runtime.dispatch_trace.begin("display", 0, "direct-display", site_id);
}

pub export fn lnako_aot_dispatch_result(call_id: u64, site_id: u64, start_epoch: u64) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.dispatch_trace.result(call_id, "display", 0, "direct-display", site_id, runtime.failure_epoch == start_epoch);
}

pub export fn lnako_aot_throw_site(site_id: u64) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const call_id = runtime.dispatch_trace.begin(
        state.aot_builtin.throw_statement_canonical_opcode,
        state.aot_builtin.throw_statement_opcode,
        state.aot_builtin.throw_statement_route,
        site_id,
    );
    runtime.dispatch_trace.result(
        call_id,
        state.aot_builtin.throw_statement_canonical_opcode,
        state.aot_builtin.throw_statement_opcode,
        state.aot_builtin.throw_statement_route,
        site_id,
        false,
    );
}

pub export fn lnako_aot_stdio_call(
    out: *state.Value,
    display_log: ?*state.Value,
    values: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        runtime.setFailure(error.UnknownCommand);
        return;
    };
    if (!state.isStdioCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "builtin", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "builtin", site_id, success);
    const actual = if (values) |pointer| pointer[0..len] else &.{};
    state.stdioBuiltin(runtime, command, actual, display_log) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_plugin_management_call(
    out: *state.Value,
    values: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    plugin_name: *state.Value,
    namespace: *state.Value,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        runtime.setFailure(error.UnknownCommand);
        return;
    };
    if (!state.isPluginManagementCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "builtin", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "builtin", site_id, success);
    const actual = if (values) |pointer| pointer[0..len] else &.{};
    state.pluginManagementBuiltin(runtime, command, actual, plugin_name, namespace) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_hatena_execute(
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
    const command = state.aot_builtin.Command.system_hatena_execute;
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, @intFromEnum(command), "hatena-default", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, @intFromEnum(command), "hatena-default", site_id, success);
    if (runtime.hatena_callbacks.items.len > 0) {
        _ = state.invokeHatenaCallbacks(runtime, if (value) |pointer| pointer.* else .{}, line, path, display_log) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        success = runtime.failure_epoch == start_epoch;
        return;
    }
    state.debugDisplayBuiltin(runtime, if (value) |pointer| pointer.* else .{}, line, path, display_log) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_regexp_call(out: *state.Value, captures: ?*state.Value, arguments: ?[*]const state.Value, len: usize, opcode: u16) callconv(.c) void {
    lnako_aot_regexp_call_site(out, captures, arguments, len, opcode, 0);
}

pub export fn lnako_aot_regexp_call_site(out: *state.Value, captures: ?*state.Value, arguments: ?[*]const state.Value, len: usize, opcode: u16, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "regexp", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "regexp", site_id, false);
        return;
    };
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "regexp", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "regexp", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = if (arguments) |pointer| pointer[0..len] else &.{};
    const result = state.regexpBuiltin(runtime, command, values) catch |failure| {
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return;
    };
    out.* = result.value;
    if (captures) |target| {
        if (result.captures) |value| target.* = value;
    }
    success = runtime.failure_epoch == start_epoch;
}

fn aotProcessArgument(argv: ?*const anyopaque, index: usize) []const u8 {
    const raw = argv orelse return "";
    const values: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(raw));
    const value = values[index] orelse return "";
    return std.mem.span(value);
}

fn aotProcessWideArgument(argv: ?*const anyopaque, index: usize) []const u16 {
    const raw = argv orelse return &.{};
    const values: [*:null]const ?[*:0]const u16 = @ptrCast(@alignCast(raw));
    const value = values[index] orelse return &.{};
    return std.mem.span(value);
}

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
