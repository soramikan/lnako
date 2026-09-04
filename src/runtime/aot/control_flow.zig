const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub export fn lnako_aot_runtime_drain_events() callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    state.pollAotInterrupt(runtime) catch |failure| state.runtimeFailure(failure);
    state.drainAotProcessTasks(runtime) catch |failure| state.runtimeFailure(failure);
    state.drainAotFileTasks(runtime) catch |failure| state.runtimeFailure(failure);
    state.drainAotTimers(runtime) catch |failure| state.runtimeFailure(failure);
    state.drainAotArchiveTasks(runtime) catch |failure| state.runtimeFailure(failure);
    state.pollAotInterrupt(runtime) catch |failure| state.runtimeFailure(failure);
    if (runtime.http_server_state.started) {
        while (runtime.http_server_state.started) {
            _ = state.pollAotHttpServer(runtime) catch |failure| state.runtimeFailure(failure);
            state.drainAotProcessTasks(runtime) catch |failure| state.runtimeFailure(failure);
            state.drainAotFileTasks(runtime) catch |failure| state.runtimeFailure(failure);
            state.drainAotPromiseTasks(runtime) catch |failure| state.runtimeFailure(failure);
            state.drainAotArchiveTasks(runtime) catch |failure| state.runtimeFailure(failure);
            state.pollAotInterrupt(runtime) catch |failure| state.runtimeFailure(failure);
        }
    }
}

pub export fn lnako_aot_http_server_init(
    method: ?*state.Value,
    get_data: ?*state.Value,
    post_data: ?*state.Value,
    files_data: ?*state.Value,
) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.http_globals = .{
        .method = method,
        .get_data = get_data,
        .post_data = post_data,
        .files_data = files_data,
    };
}

pub export fn lnako_aot_http_server_call(
    out: *state.Value,
    method: *state.Value,
    get_data: *state.Value,
    post_data: *state.Value,
    files_data: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.http_globals = .{ .method = method, .get_data = get_data, .post_data = post_data, .files_data = files_data };
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "http-server", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "http-server", site_id, false);
        return;
    };
    if (!state.isHttpServerCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "http-server", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "http-server", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.httpServerBuiltin(runtime, command, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_archive_tool_path_set(
    out: *state.Value,
    values: ?[*]const state.Value,
    len: usize,
    archive_tool_path: *state.Value,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const command = state.aot_builtin.Command.node_archive_tool_path_set;
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, @intFromEnum(command), "archive-tool-path", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, @intFromEnum(command), "archive-tool-path", site_id, success);
    if (len == 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    archive_tool_path.* = values.?[0];
    runtime.archive_tool_path_custom = true;
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_archive_call(
    out: *state.Value,
    archive_tool_path: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-archive", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-archive", site_id, false);
        return;
    };
    if (!state.isArchiveCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-archive", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-archive", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const callback = command == .node_archive_extract_callback or command == .node_archive_create_callback;
    const required: usize = if (callback) 3 else 2;
    if (len < required) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = arguments.?;
    var roots = [_]state.Value{ .{}, .{}, .{}, .{} };
    for (0..@min(len, roots.len)) |index| roots[index] = values[index];
    var frame = state.RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    var callback_value: state.Value = .{};
    if (callback) {
        callback_value = state.resolveAotCallback(runtime, roots[0]) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        roots[0] = callback_value;
    }
    const source_index: usize = if (callback) 1 else 0;
    const destination_index: usize = source_index + 1;
    const source = state.valueUtf8LossyAlloc(runtime, roots[source_index]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(source);
    const destination = state.valueUtf8LossyAlloc(runtime, roots[destination_index]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(destination);
    const tool_path = state.valueUtf8LossyAlloc(runtime, archive_tool_path.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(tool_path);
    const operation: state.AotArchiveOperation = if (command == .node_archive_extract or command == .node_archive_extract_callback) .extract else .create;
    if (callback) {
        const queued_source = runtime.allocator.dupe(u8, source) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        errdefer runtime.allocator.free(queued_source);
        const queued_destination = runtime.allocator.dupe(u8, destination) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        errdefer runtime.allocator.free(queued_destination);
        const queued_tool_path = runtime.allocator.dupe(u8, tool_path) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        errdefer runtime.allocator.free(queued_tool_path);
        runtime.archive_tasks.append(runtime.allocator, .{
            .operation = operation,
            .use_external_tool = runtime.archive_tool_path_custom,
            .source = queued_source,
            .destination = queued_destination,
            .tool_path = queued_tool_path,
            .callback = callback_value,
        }) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        success = runtime.failure_epoch == start_epoch;
        return;
    }
    const output = state.aotArchiveExecute(runtime, operation, runtime.archive_tool_path_custom, source, destination, tool_path) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(output);
    out.* = .{ .tag = @intFromEnum(shared.Tag.boolean), .payload = 1 };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_ajax_options_set(
    out: *state.Value,
    values: ?[*]const state.Value,
    len: usize,
    ajax_options: *state.Value,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const command = state.aot_builtin.Command.node_ajax_options_set;
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, @intFromEnum(command), "ajax-options", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, @intFromEnum(command), "ajax-options", site_id, success);
    if (len == 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    ajax_options.* = values.?[0];
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_ajax_onerror_set(
    out: *state.Value,
    values: ?[*]const state.Value,
    len: usize,
    ajax_onerror: *state.Value,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (values == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const command = state.aot_builtin.Command.node_ajax_onerror_set;
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, @intFromEnum(command), "ajax-onerror", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, @intFromEnum(command), "ajax-onerror", site_id, success);
    if (len == 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    ajax_onerror.* = values.?[0];
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_node_http_call(
    out: *state.Value,
    ajax_options: ?*state.Value,
    ajax_onerror: ?*state.Value,
    target: ?*state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-http", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-http", site_id, false);
        return;
    };
    if (!state.isNodeHttpCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-http", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-http", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nodeHttpBuiltin(runtime, ajax_options, ajax_onerror, target, command, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_node_stdin_callback_call(
    out: *state.Value,
    target: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-stdin-lines", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-stdin-lines", site_id, false);
        return;
    };
    if (command != .node_stdin_callback) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-stdin-lines", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-stdin-lines", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nodeStdinCallbackBuiltin(runtime, target, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_timer_call_site(
    out: *state.Value,
    target: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "timer", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "timer", site_id, false);
        return;
    };
    if (command != .timer_after and command != .timer_every and command != .timer_stop and command != .timer_stop_all) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "timer", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "timer", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.timerBuiltin(runtime, command, actual, target) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_promise_call_site(
    out: *state.Value,
    last_promise: *state.Value,
    target: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "promise", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "promise", site_id, false);
        return;
    };
    if (command != .promise_create and command != .promise_success and command != .promise_settled and command != .promise_failure and command != .promise_finally and command != .promise_all) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "promise", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "promise", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.promiseAotBuiltin(runtime, command, actual, last_promise, target) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_file_operation_call(
    out: *state.Value,
    file_copy_default: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-file-operation", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-file-operation", site_id, false);
        return;
    };
    if (!state.isNodeFileOperationCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-file-operation", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-file-operation", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nodeFileOperationBuiltin(runtime, command, actual, file_copy_default) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_node_process_call(
    out: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-process", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-process", site_id, false);
        return;
    };
    if (!state.isNodeProcessCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-process", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-process", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nodeProcessBuiltin(runtime, command, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_node_file_callback_call(
    out: *state.Value,
    target: *state.Value,
    arguments: ?[*]const state.Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(state.aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "node-file-callback", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "node-file-callback", site_id, false);
        return;
    };
    if (!state.isNodeFileCallbackCommand(command)) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "node-file-callback", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "node-file-callback", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.nodeFileCallbackBuiltin(runtime, target, command, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}
