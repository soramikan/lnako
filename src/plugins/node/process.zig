const std = @import("std");
const common = @import("../system/common.zig");
const shared = @import("shared.zig");
const fs = @import("filesystem.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const State = shared.State;
const Effects = shared.Effects;
const CommandResult = shared.CommandResult;
const FileOperation = shared.FileOperation;
const valueUtf8 = shared.valueUtf8;

pub fn callProcess(runtime: *Runtime, state: *State, context: Context, effects: ?Effects, name: []const u8, arguments: []const Value, source: Value) !?Value {
    if (std.mem.eql(u8, name, "起動待機") or std.mem.eql(u8, name, "起動") or std.mem.eql(u8, name, "コマンド実行") or std.mem.eql(u8, name, "コマンド実行待機")) {
        const command = try valueUtf8(runtime, source);
        defer runtime.allocator().free(command);
        if ((std.mem.eql(u8, name, "起動") or std.mem.eql(u8, name, "コマンド実行")) and context.startCommandFn != null and context.pollOperationFn != null) {
            const token = try context.startCommandFn.?(context.context, command);
            try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .command_output });
            return @as(?Value, .undefined);
        }
        var result = try context.runCommand(runtime.allocator(), command);
        defer result.deinit(runtime.allocator());
        if (std.mem.eql(u8, name, "起動待機")) {
            if (result.exit_code != 0) return error.CommandFailed;
            return @as(?Value, try runtime.stringUtf8(result.stdout));
        }
        if (std.mem.eql(u8, name, "コマンド実行待機")) {
            try context.writeStdout(result.stdout);
            try context.writeStderr(result.stderr);
            return @as(?Value, .{ .number = result.exit_code });
        }
        if (result.exit_code == 0) {
            if (result.stdout.len > 0) {
                try context.writeStdout(result.stdout);
                try context.writeStdout("\n");
            }
        } else try context.writeStderr(result.stderr);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "起動時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        const command = try valueUtf8(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(command);
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        if (context.startCommandFn != null and context.pollOperationFn != null) {
            const token = try context.startCommandFn.?(context.context, command);
            try state.pending_operations.append(runtime.allocator(), .{ .token = token, .mode = .output_callback, .callback = callback });
            return @as(?Value, .undefined);
        }
        var result = try context.runCommand(runtime.allocator(), command);
        defer result.deinit(runtime.allocator());
        if (result.exit_code != 0) return error.CommandFailed;
        var stdout = try runtime.stringUtf8Lossy(result.stdout);
        try roots.protect(&stdout);
        _ = try actual_effects.invoke(callback, &.{stdout});
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "コンソールクリア")) return @as(?Value, .undefined);
    if (std.mem.eql(u8, name, "尋") or std.mem.eql(u8, name, "文字尋") or std.mem.eql(u8, name, "標準入力全取得")) {
        try ensureStdin(runtime.allocator(), state, context);
        if (std.mem.eql(u8, name, "標準入力全取得")) return @as(?Value, try runtime.stringUtf8(state.stdin_bytes.?));
        const prompt = try valueUtf8(runtime, source);
        defer runtime.allocator().free(prompt);
        try context.writeStdout(prompt);
        const line = nextStdinLine(state);
        var text = try runtime.stringUtf8(line);
        if (std.mem.eql(u8, name, "文字尋")) return @as(?Value, text);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&text);
        const number = try runtime.valueToNumber(text);
        return @as(?Value, if (std.math.isNan(number)) text else .{ .number = number });
    }
    if (std.mem.eql(u8, name, "標準入力取得時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        try ensureStdin(runtime.allocator(), state, context);
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        while (state.stdin_offset < state.stdin_bytes.?.len) {
            var line = try runtime.stringUtf8(nextStdinLine(state));
            try roots.protect(&line);
            try actual_effects.setGlobal("対象", line);
            _ = try actual_effects.invoke(callback, &.{line});
        }
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "強制終了時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        state.interrupt_callback = try actual_effects.resolve(source);
        const install_interrupt = context.installInterruptFn orelse return error.InterruptHandlingUnavailable;
        try install_interrupt(context.context);
        return @as(?Value, .undefined);
    }
    if (std.mem.eql(u8, name, "終") or std.mem.eql(u8, name, "終了") or std.mem.eql(u8, name, "プロセス終")) {
        const number = if (std.mem.eql(u8, name, "プロセス終")) try runtime.valueToNumber(source) else 0;
        state.requested_exit_code = if (!std.math.isFinite(number)) 0 else @intFromFloat(@mod(@trunc(number), 256.0));
        return error.ProcessExitRequested;
    }
    return null;
}

pub fn ensureStdin(allocator: std.mem.Allocator, state: *State, context: Context) !void {
    if (state.stdin_bytes != null) return;
    const function = context.readStdinFn orelse return error.StandardInputUnavailable;
    state.stdin_bytes = try function(context.context, allocator);
}

pub fn nextStdinLine(state: *State) []const u8 {
    const bytes = state.stdin_bytes.?;
    if (state.stdin_offset >= bytes.len) return "";
    const start = state.stdin_offset;
    var end = start;
    while (end < bytes.len and bytes[end] != '\n') end += 1;
    state.stdin_offset = if (end < bytes.len) end + 1 else end;
    if (end > start and bytes[end - 1] == '\r') end -= 1;
    return bytes[start..end];
}
