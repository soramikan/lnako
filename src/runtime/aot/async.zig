const std = @import("std");
const builtin = @import("builtin");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const zip_archive = shared.zip_archive;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Object = aot_state.Object;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const BigInt = aot_state.BigInt;
const AotTimer = aot_state.AotTimer;
const AotPromiseTask = aot_state.AotPromiseTask;
const AotPromiseReaction = aot_state.AotPromiseReaction;
const AotPromiseReactionMode = aot_state.AotPromiseReactionMode;
const AotPromiseState = aot_state.AotPromiseState;
const AotPromiseAllState = aot_state.AotPromiseAllState;
const AotPromiseAllHandler = aot_state.AotPromiseAllHandler;
const AotPromiseChainKind = aot_state.AotPromiseChainKind;
const AotProcessMode = aot_state.AotProcessMode;
const AotProcessTask = aot_state.AotProcessTask;
const AotFileTask = aot_state.AotFileTask;
const AotFileTaskOperation = aot_state.AotFileTaskOperation;
const AotArchiveTask = aot_state.AotArchiveTask;
const AotArchiveOperation = aot_state.AotArchiveOperation;
const AotClientHttpTask = aot_state.AotClientHttpTask;
const AotClientHttpResult = aot_state.AotClientHttpResult;
const AotCommandResult = aot_state.AotCommandResult;
const numberValue = aot_state.numberValue;
const numberString = aot_state.numberString;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const currentTimeMilliseconds = aot_state.currentTimeMilliseconds;
const invokeAotCallback = aot_state.invokeAotCallback;
const resolveAotCallback = aot_state.resolveAotCallback;
const aotClientHttpResponseValue = aot_state.aotClientHttpResponseValue;
const aotFileCopyMoveWithIo = aot_state.aotFileCopyMoveWithIo;
const dynamicToAotValue = aot_state.dynamicToAotValue;
const pollAotInterrupt = aot_state.pollAotInterrupt;
const currentDirectoryAlloc = aot_state.currentDirectoryAlloc;
const error_message = shared.error_message;
const writeBytes = aot_state.writeBytes;
const aot_timer_event_limit = aot_state.aot_timer_event_limit;

pub fn aotDelayMilliseconds(runtime: *Runtime, value: Value) !u64 {
    const seconds = try valueToNumberRuntime(runtime, value);
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = @floor(seconds * 1000.0);
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.TimerOverflow;
    return @intFromFloat(milliseconds);
}

pub fn sleepAotUntil(runtime: *Runtime, target: u64) !void {
    if (target <= runtime.elapsed_milliseconds) return;
    const delay = target - runtime.elapsed_milliseconds;
    if (delay > @as(u64, std.math.maxInt(i64))) return error.TimerOverflow;
    while (runtime.elapsed_milliseconds < target) {
        try pollAotInterrupt(runtime);
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        const remaining = target - runtime.elapsed_milliseconds;
        const slice = @min(remaining, @as(u64, 20));
        try std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            std.Io.Duration.fromMilliseconds(@intCast(slice)),
            .awake,
        );
        runtime.elapsed_milliseconds += slice;
        try pollAotInterrupt(runtime);
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
    }
}

pub fn runAotShellCommand(runtime: *Runtime, command: []const u8, cwd: []const u8) !AotCommandResult {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = try std.process.run(runtime.allocator, runtime.process_io.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

pub fn aotRuntimeIo(runtime: *Runtime) std.Io {
    return if (runtime.process_io_initialized) runtime.process_io.io() else std.Io.Threaded.global_single_threaded.io();
}

pub fn queueAotProcess(runtime: *Runtime, command: []const u8, mode: AotProcessMode, callback: Value) !void {
    const allocator = runtime.allocator;
    const task = try allocator.create(AotProcessTask);
    const owned_command = allocator.dupe(u8, command) catch |failure| {
        allocator.destroy(task);
        return failure;
    };
    const owned_cwd = currentDirectoryAlloc(runtime) catch |failure| {
        allocator.free(owned_command);
        allocator.destroy(task);
        return failure;
    };
    task.* = .{
        .runtime = runtime,
        .command = owned_command,
        .cwd = owned_cwd,
        .mode = mode,
        .callback = callback,
    };
    runtime.process_tasks.append(allocator, task) catch |failure| {
        task.deinit(allocator, false);
        return failure;
    };
    task.thread = std.Thread.spawn(.{}, AotProcessTask.run, .{task}) catch |failure| {
        _ = runtime.process_tasks.pop();
        task.deinit(allocator, false);
        return failure;
    };
}

pub fn queueAotFileTask(runtime: *Runtime, operation: AotFileTaskOperation, source: []const u8, destination: []const u8, overwrite: bool, callback: Value) !void {
    const allocator = runtime.allocator;
    const task = try allocator.create(AotFileTask);
    const owned_source = allocator.dupe(u8, source) catch |failure| {
        allocator.destroy(task);
        return failure;
    };
    const owned_destination = allocator.dupe(u8, destination) catch |failure| {
        allocator.free(owned_source);
        allocator.destroy(task);
        return failure;
    };
    task.* = .{
        .runtime = runtime,
        .operation = operation,
        .source = owned_source,
        .destination = owned_destination,
        .overwrite = overwrite,
        .callback = callback,
    };
    runtime.file_tasks.append(allocator, task) catch |failure| {
        task.deinit(allocator, false);
        return failure;
    };
    task.thread = std.Thread.spawn(.{}, AotFileTask.run, .{task}) catch |failure| {
        _ = runtime.file_tasks.pop();
        task.deinit(allocator, false);
        return failure;
    };
}

pub fn readyAotProcessTaskIndex(runtime: *const Runtime) ?usize {
    var selected: ?usize = null;
    for (runtime.process_tasks.items, 0..) |task, index| {
        if (!task.complete.load(.acquire)) continue;
        if (selected == null or task.completion_order < runtime.process_tasks.items[selected.?].completion_order) selected = index;
    }
    return selected;
}

pub fn readyAotFileTaskIndex(runtime: *const Runtime) ?usize {
    var selected: ?usize = null;
    for (runtime.file_tasks.items, 0..) |task, index| {
        if (!task.complete.load(.acquire)) continue;
        if (selected == null or task.completion_order < runtime.file_tasks.items[selected.?].completion_order) selected = index;
    }
    return selected;
}

pub fn writeAotStderr(bytes: []const u8) void {
    if (bytes.len > 0) std.debug.print("{s}", .{bytes});
}

pub fn writeAotAjaxReceiveError(status: u16, failure: ?anyerror) void {
    if (failure) |err| {
        std.debug.print("[AJAX受信のエラー] Error: {s}\n", .{error_message.forFailure(err)});
    } else {
        std.debug.print("[AJAX受信のエラー] Error: status={d}\n", .{status});
    }
}

pub fn drainAotProcessTasks(runtime: *Runtime) !void {
    while (readyAotProcessTaskIndex(runtime)) |index| {
        try countAotEvent(runtime);
        const task = runtime.process_tasks.orderedRemove(index);
        defer task.deinit(runtime.allocator, true);
        if (task.failure) |failure| return failure;
        const result = &(task.result orelse return error.AsyncCommandMissingResult);
        switch (task.mode) {
            .command_output => if (result.exit_code == 0) {
                if (result.stdout.len > 0) writeBytes(result.stdout, true);
            } else writeAotStderr(result.stderr),
            .output_callback => {
                if (result.exit_code != 0) return error.CommandFailed;
                var rooted = [_]Value{ task.callback, .{} };
                var roots = RootFrame{};
                runtime.pushRoots(&roots, &rooted, rooted.len);
                defer runtime.popRoots(&roots);
                rooted[1] = try runtimeUtf8StringLossy(runtime, result.stdout);
                _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
            },
        }
    }
}

pub fn drainAotFileTasks(runtime: *Runtime) !void {
    while (readyAotFileTaskIndex(runtime)) |index| {
        try countAotEvent(runtime);
        const task = runtime.file_tasks.orderedRemove(index);
        defer task.deinit(runtime.allocator, true);
        if (task.failure != null) return error.FileOperationFailed;
        var callback = task.callback;
        var frame = RootFrame{};
        runtime.pushRoots(&frame, @ptrCast(&callback), 1);
        defer runtime.popRoots(&frame);
        _ = try invokeAotCallback(runtime, callback, null, 0);
    }
}

pub fn earliestAotTimerIndex(runtime: *const Runtime) ?usize {
    if (runtime.timers.items.len == 0) return null;
    var earliest: usize = 0;
    for (runtime.timers.items[1..], 1..) |timer, index| {
        if (timer.due_milliseconds < runtime.timers.items[earliest].due_milliseconds) earliest = index;
    }
    return earliest;
}

pub fn countAotEvent(runtime: *Runtime) !void {
    if (runtime.timer_event_count >= aot_timer_event_limit) return error.EventLoopLimitExceeded;
    runtime.timer_event_count += 1;
}

pub fn executeAotTimer(runtime: *Runtime, index: usize) !void {
    try countAotEvent(runtime);
    const timer = runtime.timers.orderedRemove(index);
    var callback = timer.callback;
    var root = RootFrame{};
    runtime.pushRoots(&root, @ptrCast(&callback), 1);
    defer runtime.popRoots(&root);
    try sleepAotUntil(runtime, timer.due_milliseconds);
    if (timer.repeating) {
        const next_due = std.math.add(u64, runtime.elapsed_milliseconds, timer.interval_milliseconds) catch return error.TimerOverflow;
        try runtime.timers.append(runtime.allocator, .{
            .id = timer.id,
            .due_milliseconds = next_due,
            .interval_milliseconds = timer.interval_milliseconds,
            .repeating = true,
            .callback = callback,
        });
    }
    var id = numberValue(@floatFromInt(timer.id));
    _ = try invokeAotCallback(runtime, callback, @ptrCast(&id), 1);
}

pub fn aotArchiveExecute(
    runtime: *Runtime,
    operation: AotArchiveOperation,
    use_external_tool: bool,
    source: []const u8,
    destination: []const u8,
    tool_path: []const u8,
) ![]u8 {
    const allocator = runtime.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!use_external_tool) {
        switch (operation) {
            .create => try zip_archive.create(allocator, io, source, destination),
            .extract => try zip_archive.extract(io, source, destination),
        }
        return allocator.alloc(u8, 0);
    }
    // This is an explicit test-only adapter for the hermetic archive fixture.
    // It preserves the changed tool-path state and AOT callback/event route,
    // while normal AOT executions continue to launch the configured tool.
    if (std.c.getenv("LNAKO_TEST_ARCHIVE_HELPER")) |helper| {
        if (std.mem.eql(u8, std.mem.span(helper), tool_path)) {
            switch (operation) {
                .create => try zip_archive.create(allocator, io, source, destination),
                .extract => try zip_archive.extract(io, source, destination),
            }
            return allocator.alloc(u8, 0);
        }
    }

    var output_option: ?[]u8 = null;
    defer if (output_option) |option| allocator.free(option);
    var argv_storage: [6][]const u8 = undefined;
    const argv: []const []const u8 = switch (operation) {
        .create => blk: {
            argv_storage = .{ tool_path, "a", "-r", destination, source, "-y" };
            break :blk argv_storage[0..6];
        },
        .extract => blk: {
            output_option = try std.fmt.allocPrint(allocator, "-o{s}", .{destination});
            argv_storage = .{ tool_path, "x", source, output_option.?, "-y", undefined };
            break :blk argv_storage[0..5];
        },
    };
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ArchiveToolFailed;
    }
    return result.stdout;
}

pub fn drainAotArchiveTasks(runtime: *Runtime) !void {
    while (runtime.archive_tasks.items.len > 0) {
        try countAotEvent(runtime);
        var task = runtime.archive_tasks.orderedRemove(0);
        defer task.deinit(runtime.allocator);
        var callback = task.callback;
        var callback_frame = RootFrame{};
        runtime.pushRoots(&callback_frame, @ptrCast(&callback), 1);
        defer runtime.popRoots(&callback_frame);
        const output = try aotArchiveExecute(runtime, task.operation, task.use_external_tool, task.source, task.destination, task.tool_path);
        defer runtime.allocator.free(output);
        var result = try runtimeUtf8StringLossy(runtime, output);
        var result_frame = RootFrame{};
        runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
        defer runtime.popRoots(&result_frame);
        _ = try invokeAotCallback(runtime, callback, @ptrCast(&result), 1);
    }
}

pub fn drainAotPromiseTasks(runtime: *Runtime) !void {
    while (runtime.promise_tasks.items.len > 0) {
        try countAotEvent(runtime);
        const task = runtime.promise_tasks.orderedRemove(0);
        try executeAotPromiseTask(runtime, task);
    }
}

pub fn drainAotNativePluginTasks(runtime: *Runtime) !bool {
    const state = runtime.dynamic_state orelse return false;
    const native_pending = try state.interpreter.pollExternalPlugins();
    var pending_bridge = false;
    var index: usize = 0;
    while (index < runtime.dynamic_promise_bridges.items.len) {
        const bridge = runtime.dynamic_promise_bridges.items[index];
        if (bridge.state != state or bridge.promise.state == .pending) {
            pending_bridge = pending_bridge or bridge.state == state;
            index += 1;
            continue;
        }

        var rooted = [_]Value{ bridge.aot_promise, .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &rooted, rooted.len);
        defer runtime.popRoots(&frame);
        rooted[1] = try dynamicToAotValue(state, bridge.promise.result);
        if (bridge.promise.state == .fulfilled) {
            try resolveAotPromise(runtime, rooted[0].object().?, rooted[1]);
        } else {
            try rejectAotPromise(runtime, rooted[0].object().?, rooted[1]);
        }
        _ = runtime.dynamic_promise_bridges.orderedRemove(index);
        runtime.allocator.destroy(bridge);
    }
    return native_pending or pending_bridge;
}

pub fn drainAotClientHttpTasks(runtime: *Runtime) !void {
    while (runtime.client_http_tasks.items.len > 0) {
        try countAotEvent(runtime);
        var task = runtime.client_http_tasks.orderedRemove(0);
        defer task.deinit(runtime.allocator);

        if (task.result.failure) |failure| {
            switch (task.mode) {
                .callback => {
                    const handler: Value = if (task.onerror) |pointer| pointer.* else .{};
                    if (handler.tag == @intFromEnum(Tag.function)) {
                        var rooted = [_]Value{ handler, .{} };
                        var frame = RootFrame{};
                        runtime.pushRoots(&frame, &rooted, rooted.len);
                        defer runtime.popRoots(&frame);
                        rooted[1] = try runtimeUtf8StringLossy(runtime, @errorName(failure));
                        _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
                    } else return error.HttpRequestFailed;
                },
                .set_target => writeAotAjaxReceiveError(task.result.status, failure),
                .response_promise => {
                    if (task.promise.tag != @intFromEnum(Tag.promise)) return error.InvalidPendingPromise;
                    var reason = try runtimeUtf8StringLossy(runtime, @errorName(failure));
                    var frame = RootFrame{};
                    runtime.pushRoots(&frame, @ptrCast(&reason), 1);
                    defer runtime.popRoots(&frame);
                    try rejectAotPromise(runtime, task.promise.object().?, reason);
                },
            }
            continue;
        }

        switch (task.mode) {
            .callback => {
                var rooted = [_]Value{ task.callback, .{} };
                var frame = RootFrame{};
                runtime.pushRoots(&frame, &rooted, rooted.len);
                defer runtime.popRoots(&frame);
                rooted[1] = try runtimeUtf8StringLossy(runtime, task.result.body);
                if (task.target) |target| target.* = rooted[1];
                _ = try invokeAotCallback(runtime, rooted[0], @ptrCast(&rooted[1]), 1);
            },
            .set_target => {
                const status = task.result.status;
                if (status >= 200 and status < 300) {
                    if (task.target) |target| target.* = try runtimeUtf8StringLossy(runtime, task.result.body);
                } else writeAotAjaxReceiveError(status, null);
            },
            .response_promise => {
                if (task.promise.tag != @intFromEnum(Tag.promise)) return error.InvalidPendingPromise;
                var rooted = [_]Value{ task.promise, .{} };
                var frame = RootFrame{};
                runtime.pushRoots(&frame, &rooted, rooted.len);
                defer runtime.popRoots(&frame);
                rooted[1] = try aotClientHttpResponseValue(runtime, task.result);
                try resolveAotPromise(runtime, rooted[0].object().?, rooted[1]);
            },
        }
    }
}

pub fn drainAotEvents(runtime: *Runtime) !void {
    while (true) {
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        try drainAotClientHttpTasks(runtime);
        try drainAotArchiveTasks(runtime);
        const native_plugins_pending = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        if (earliestAotTimerIndex(runtime)) |index| {
            try executeAotTimer(runtime, index);
            continue;
        }
        if (runtime.process_tasks.items.len > 0 or runtime.file_tasks.items.len > 0 or runtime.client_http_tasks.items.len > 0 or native_plugins_pending) {
            try std.Io.sleep(
                std.Io.Threaded.global_single_threaded.io(),
                std.Io.Duration.fromMilliseconds(1),
                .awake,
            );
            runtime.elapsed_milliseconds += 1;
            continue;
        }
        break;
    }
}

pub fn drainAotTimers(runtime: *Runtime) !void {
    try drainAotEvents(runtime);
}

pub fn waitAotMilliseconds(runtime: *Runtime, milliseconds: u64) !void {
    const target = std.math.add(u64, runtime.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    while (true) {
        try drainAotProcessTasks(runtime);
        try drainAotFileTasks(runtime);
        try drainAotClientHttpTasks(runtime);
        try drainAotArchiveTasks(runtime);
        _ = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        const index = earliestAotTimerIndex(runtime) orelse break;
        if (runtime.timers.items[index].due_milliseconds > target) break;
        try executeAotTimer(runtime, index);
    }
    try drainAotProcessTasks(runtime);
    try drainAotFileTasks(runtime);
    try drainAotClientHttpTasks(runtime);
    try drainAotArchiveTasks(runtime);
    _ = try drainAotNativePluginTasks(runtime);
    try drainAotPromiseTasks(runtime);
    try sleepAotUntil(runtime, target);
    try drainAotProcessTasks(runtime);
    try drainAotFileTasks(runtime);
    try drainAotClientHttpTasks(runtime);
    _ = try drainAotNativePluginTasks(runtime);
}

pub fn scheduleAotTimer(runtime: *Runtime, arguments: []const Value, repeating: bool, target: ?*Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    var values = [_]Value{ arguments[0], arguments[1], .{} };
    var root = RootFrame{};
    runtime.pushRoots(&root, &values, values.len);
    defer runtime.popRoots(&root);
    values[0] = try resolveAotCallback(runtime, values[0]);
    const delay = try aotDelayMilliseconds(runtime, values[1]);
    const id = runtime.next_timer_id;
    runtime.next_timer_id = std.math.add(u64, runtime.next_timer_id, 1) catch return error.TimerOverflow;
    const due = std.math.add(u64, runtime.elapsed_milliseconds, delay) catch return error.TimerOverflow;
    try runtime.timers.append(runtime.allocator, .{
        .id = id,
        .due_milliseconds = due,
        .interval_milliseconds = if (repeating) delay else 0,
        .repeating = repeating,
        .callback = values[0],
    });
    values[2] = numberValue(@floatFromInt(id));
    if (target) |pointer| pointer.* = values[2];
    return values[2];
}

pub fn timerBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value, target: ?*Value) !Value {
    switch (command) {
        .timer_after => return scheduleAotTimer(runtime, arguments, false, target),
        .timer_every => return scheduleAotTimer(runtime, arguments, true, target),
        .timer_stop => {
            if (arguments.len == 0 or arguments[arguments.len - 1].tag != @intFromEnum(Tag.number)) {
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
            }
            const number = @as(f64, @bitCast(arguments[arguments.len - 1].payload));
            if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
            }
            const id: u64 = @intFromFloat(@trunc(number));
            for (runtime.timers.items, 0..) |timer, index| {
                if (timer.id != id) continue;
                _ = runtime.timers.orderedRemove(index);
                return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
            }
            return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        },
        .timer_stop_all => {
            runtime.timers.clearRetainingCapacity();
            return .{};
        },
        else => return error.UnknownCommand,
    }
}

pub fn timerWaitBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const source = if (arguments.len > 0) arguments[arguments.len - 1] else Value{};
    const delay = try aotDelayMilliseconds(runtime, source);
    try waitAotMilliseconds(runtime, delay);
    return .{};
}

pub fn aotPromiseValue(object: *Object) Value {
    return .{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(object) };
}

pub fn aotPromiseObject(value: Value) ?*Object {
    if (value.tag != @intFromEnum(Tag.promise)) return null;
    const object = value.object() orelse return null;
    return if (object.payload == .promise) object else null;
}

pub fn createAotPromise(runtime: *Runtime) !Value {
    try runtime.beforeAllocation();
    return runtime.createObject(.{ .promise = .{} }, .promise);
}

pub fn enqueueAotPromiseReaction(runtime: *Runtime, promise: *Object, reaction: AotPromiseReaction) !void {
    const state = &promise.payload.promise;
    try runtime.promise_tasks.append(runtime.allocator, .{
        .callback = if (state.state == .rejected) reaction.on_rejected else reaction.on_fulfilled,
        .settled_value = state.result,
        .rejected = state.state == .rejected,
        .next = reaction.next,
        .mode = reaction.mode,
        .target_global = reaction.target_global,
    });
}

pub fn enqueueAotPromiseReactions(runtime: *Runtime, promise: *Object) !void {
    for (promise.payload.promise.reactions.items) |reaction| try enqueueAotPromiseReaction(runtime, promise, reaction);
    promise.payload.promise.reactions.clearRetainingCapacity();
}

pub fn aotPromiseThen(
    runtime: *Runtime,
    source: *Object,
    on_fulfilled: Value,
    on_rejected: Value,
    mode: AotPromiseReactionMode,
    target_global: ?*Value,
) !Value {
    var roots = [_]Value{ aotPromiseValue(source), on_fulfilled, on_rejected, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[3] = try createAotPromise(runtime);
    const reaction = AotPromiseReaction{
        .on_fulfilled = roots[1],
        .on_rejected = roots[2],
        .next = roots[3].object().?,
        .mode = mode,
        .target_global = target_global,
    };
    if (source.payload.promise.state == .pending) {
        try source.payload.promise.reactions.append(runtime.allocator, reaction);
    } else try enqueueAotPromiseReaction(runtime, source, reaction);
    return roots[3];
}

pub fn resolveAotPromise(runtime: *Runtime, promise: *Object, value: Value) !void {
    const state = &promise.payload.promise;
    if (state.state != .pending) return;
    if (aotPromiseObject(value)) |source| {
        if (source == promise) return error.PromiseResolutionCycle;
        const reaction = AotPromiseReaction{ .next = promise };
        if (source.payload.promise.state == .pending) {
            try source.payload.promise.reactions.append(runtime.allocator, reaction);
        } else try enqueueAotPromiseReaction(runtime, source, reaction);
        return;
    }
    state.state = .fulfilled;
    state.result = value;
    try enqueueAotPromiseReactions(runtime, promise);
}

pub fn rejectAotPromise(runtime: *Runtime, promise: *Object, reason: Value) !void {
    const state = &promise.payload.promise;
    if (state.state != .pending) return;
    state.state = .rejected;
    state.result = reason;
    try enqueueAotPromiseReactions(runtime, promise);
}

pub fn forwardAotPromiseTask(runtime: *Runtime, task: AotPromiseTask) !void {
    if (task.rejected) return rejectAotPromise(runtime, task.next, task.settled_value);
    return resolveAotPromise(runtime, task.next, task.settled_value);
}

pub fn callbackFailureReason(runtime: *Runtime, failure: anyerror) !Value {
    if (runtime.has_pending_exception) return runtime.takeException();
    return runtimeUtf8String(runtime, error_message.forFailure(failure));
}

pub fn executeAotPromiseTask(runtime: *Runtime, task: AotPromiseTask) !void {
    var roots = [_]Value{ task.callback, task.settled_value, aotPromiseValue(task.next), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    if (roots[0].tag == @intFromEnum(Tag.undefined)) return forwardAotPromiseTask(runtime, task);
    if (roots[0].tag != @intFromEnum(Tag.function)) {
        roots[4] = try runtimeUtf8String(runtime, "NotCallable");
        return rejectAotPromise(runtime, task.next, roots[4]);
    }
    if (task.mode != .finally) {
        if (task.target_global) |target| target.* = roots[1];
    }

    var callback_arguments = [_]Value{ .{}, .{} };
    const callback_len: usize = switch (task.mode) {
        .standard => blk: {
            callback_arguments[0] = roots[1];
            break :blk 1;
        },
        .settled_pair => blk: {
            callback_arguments[0] = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(!task.rejected) };
            callback_arguments[1] = roots[1];
            break :blk 2;
        },
        .finally => 0,
    };
    roots[3] = invokeAotCallback(
        runtime,
        roots[0],
        if (callback_len == 0) null else callback_arguments[0..].ptr,
        callback_len,
    ) catch |failure| {
        roots[4] = try callbackFailureReason(runtime, failure);
        return rejectAotPromise(runtime, task.next, roots[4]);
    };
    if (task.mode == .finally) {
        if (task.rejected) return rejectAotPromise(runtime, task.next, task.settled_value);
        return resolveAotPromise(runtime, task.next, task.settled_value);
    }
    return resolveAotPromise(runtime, task.next, roots[3]);
}

pub fn createAotPromiseResolver(runtime: *Runtime, promise: *Object, rejected: bool) !Value {
    return runtime.createPromiseSpecialFunction(
        if (rejected) "reject" else "resolve",
        .{ .resolver = .{ .promise = promise, .rejected = rejected } },
    );
}

pub fn createAotPromiseWithExecutor(runtime: *Runtime, arguments: []const Value, last_promise: ?*Value) !Value {
    if (arguments.len == 0 or arguments[0].tag != @intFromEnum(Tag.function)) return error.NotCallable;
    var roots = [_]Value{ arguments[0], .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[1] = try createAotPromise(runtime);
    const promise = roots[1].object().?;
    roots[2] = try createAotPromiseResolver(runtime, promise, false);
    roots[3] = try createAotPromiseResolver(runtime, promise, true);
    var executor_arguments = [_]Value{ roots[2], roots[3] };
    _ = invokeAotCallback(runtime, roots[0], &executor_arguments, executor_arguments.len) catch |failure| {
        roots[4] = try callbackFailureReason(runtime, failure);
        try rejectAotPromise(runtime, promise, roots[4]);
    };
    if (last_promise) |target| target.* = roots[1];
    return roots[1];
}

pub fn chainAotPromise(
    runtime: *Runtime,
    arguments: []const Value,
    kind: AotPromiseChainKind,
    last_promise: ?*Value,
    target_global: ?*Value,
) !Value {
    if (arguments.len < 2 or arguments[0].tag != @intFromEnum(Tag.function)) return error.InvalidPromiseArguments;
    const source = aotPromiseObject(arguments[1]) orelse return error.InvalidPromiseArguments;
    var roots = [_]Value{ arguments[0], arguments[1], .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[2] = switch (kind) {
        .success => try aotPromiseThen(runtime, source, roots[0], .{}, .standard, target_global),
        .failure => try aotPromiseThen(runtime, source, .{}, roots[0], .standard, target_global),
        .settled => try aotPromiseThen(runtime, source, roots[0], roots[0], .settled_pair, target_global),
        .finally => try aotPromiseThen(runtime, source, roots[0], roots[0], .finally, target_global),
    };
    if (last_promise) |target| target.* = roots[2];
    return roots[2];
}

pub fn destroyAotPromiseAllState(runtime: *Runtime, state: *AotPromiseAllState) void {
    for (runtime.promise_all_states.items, 0..) |candidate, index| {
        if (candidate != state) continue;
        _ = runtime.promise_all_states.orderedRemove(index);
        runtime.allocator.destroy(state);
        return;
    }
}

pub fn handleAotPromiseAll(runtime: *Runtime, handler: AotPromiseAllHandler, settled: Value) !Value {
    const state = handler.state;
    if (handler.rejected) {
        try rejectAotPromise(runtime, state.promise, settled);
    } else {
        state.results.object().?.payload.array.items[handler.index] = settled;
    }
    if (state.remaining == 0) return .{};
    state.remaining -= 1;
    if (state.remaining == 0) {
        if (state.promise.payload.promise.state == .pending) try resolveAotPromise(runtime, state.promise, state.results);
        destroyAotPromiseAllState(runtime, state);
    }
    return .{};
}

pub fn createAotPromiseAllHandler(runtime: *Runtime, state: *AotPromiseAllState, index: usize, rejected: bool) !Value {
    return runtime.createPromiseSpecialFunction(
        if (rejected) "Promise.all rejected" else "Promise.all fulfilled",
        .{ .all_handler = .{ .state = state, .index = index, .rejected = rejected } },
    );
}

pub fn bundleAotPromises(runtime: *Runtime, arguments: []const Value, last_promise: ?*Value) !Value {
    const root_count = std.math.add(usize, arguments.len, 4) catch return error.ArrayTooLarge;
    const roots = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(roots);
    @memcpy(roots[0..arguments.len], arguments);
    @memset(roots[arguments.len..], .{});
    var frame = RootFrame{};
    runtime.pushRoots(&frame, roots.ptr, roots.len);
    defer runtime.popRoots(&frame);
    const promise_index = arguments.len;
    const results_index = arguments.len + 1;
    const fulfilled_index = arguments.len + 2;
    const rejected_index = arguments.len + 3;

    roots[promise_index] = try createAotPromise(runtime);
    roots[results_index] = try runtime.createArray(&.{});
    const result_items = &roots[results_index].object().?.payload.array;
    try result_items.ensureTotalCapacity(runtime.allocator, arguments.len);
    for (arguments) |_| try result_items.append(runtime.allocator, .{});

    const state = try runtime.allocator.create(AotPromiseAllState);
    state.* = .{ .promise = roots[promise_index].object().?, .results = roots[results_index] };
    try runtime.promise_all_states.append(runtime.allocator, state);
    var state_active = true;
    errdefer if (state_active) destroyAotPromiseAllState(runtime, state);

    for (arguments, 0..) |argument, index| {
        if (aotPromiseObject(argument)) |source| {
            state.remaining += 1;
            roots[fulfilled_index] = try createAotPromiseAllHandler(runtime, state, index, false);
            roots[rejected_index] = try createAotPromiseAllHandler(runtime, state, index, true);
            _ = try aotPromiseThen(runtime, source, roots[fulfilled_index], roots[rejected_index], .standard, null);
        } else result_items.items[index] = argument;
    }
    if (state.remaining == 0) {
        try resolveAotPromise(runtime, state.promise, state.results);
        destroyAotPromiseAllState(runtime, state);
        state_active = false;
    }
    if (last_promise) |target| target.* = roots[promise_index];
    return roots[promise_index];
}

pub fn promiseAotBuiltin(
    runtime: *Runtime,
    command: aot_builtin.Command,
    arguments: []const Value,
    last_promise: ?*Value,
    target_global: ?*Value,
) !Value {
    return switch (command) {
        .promise_create => createAotPromiseWithExecutor(runtime, arguments, last_promise),
        .promise_success => chainAotPromise(runtime, arguments, .success, last_promise, target_global),
        .promise_settled => chainAotPromise(runtime, arguments, .settled, last_promise, target_global),
        .promise_failure => chainAotPromise(runtime, arguments, .failure, last_promise, target_global),
        .promise_finally => chainAotPromise(runtime, arguments, .finally, last_promise, target_global),
        .promise_all => bundleAotPromises(runtime, arguments, last_promise),
        else => error.UnknownCommand,
    };
}

pub fn awaitAotPromise(runtime: *Runtime, value: Value) !Value {
    const promise = aotPromiseObject(value) orelse return value;
    var rooted = value;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&rooted), 1);
    defer runtime.popRoots(&frame);
    while (promise.payload.promise.state == .pending) {
        _ = try drainAotNativePluginTasks(runtime);
        try drainAotPromiseTasks(runtime);
        if (promise.payload.promise.state != .pending) break;
        if (earliestAotTimerIndex(runtime)) |index| {
            try executeAotTimer(runtime, index);
            continue;
        }
        break;
    }
    return switch (promise.payload.promise.state) {
        .fulfilled => promise.payload.promise.result,
        .rejected => {
            runtime.setException(promise.payload.promise.result);
            return error.NakoException;
        },
        .pending => error.PromiseStillPending,
    };
}
