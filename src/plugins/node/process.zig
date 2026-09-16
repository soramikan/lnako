const std = @import("std");
const common = @import("../system/common.zig");
const shared = @import("shared.zig");
const fs = @import("filesystem.zig");
const low_level_io = @import("../../runtime/low_level_io.zig");

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
        if (std.mem.eql(u8, name, "標準入力全取得")) {
            const source_state = try ensureStdinSource(runtime, context);
            // 不正UTF-8をU+FFFDへ置き換えるlossy変換。AOT側とupstreamの
            // Node（Buffer.toString相当）に揃える。
            return @as(?Value, try runtime.stringUtf8Lossy(try source_state.drainAll()));
        }
        const prompt = try valueUtf8(runtime, source);
        defer runtime.allocator().free(prompt);
        try context.writeStdout(prompt);
        var text: Value = undefined;
        var peeked_source: ?*low_level_io.StdinSource = null;
        const use_line_reader = blk: {
            // raw読取り等で共有sourceが既に作られている場合は、TTYでも
            // 直接行readへ切り替えない。切り替えるとsourceの履歴に
            // バッファ済みの未消費バイトを置き去りにする。
            if (context.peekStdinSourceFn) |peek| {
                peeked_source = peek(context.context);
                if (peeked_source != null) break :blk false;
            }
            if (context.isStdinTtyFn) |isTty| {
                if (!isTty(context.context)) break :blk false;
            }
            break :blk context.readStdinLineFn != null;
        };
        if (use_line_reader) {
            const function = context.readStdinLineFn.?;
            const line = try function(context.context, runtime.allocator());
            defer runtime.allocator().free(line);
            text = try runtime.stringUtf8Lossy(line);
        } else {
            // peek済みのsourceは再利用し、peekのみ提供する変則hostでも
            // stdinSourceFn再呼出しへ落ちないようにする。
            const source_state = peeked_source orelse try ensureStdinSource(runtime, context);
            const line = (try source_state.readLine()) orelse "";
            text = try runtime.stringUtf8Lossy(line);
        }
        if (std.mem.eql(u8, name, "文字尋")) return @as(?Value, text);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&text);
        const number = try runtime.valueToNumber(text);
        return @as(?Value, if (std.math.isNan(number)) text else .{ .number = number });
    }
    if (std.mem.eql(u8, name, "標準入力取得時")) {
        const actual_effects = effects orelse return error.CallbackExecutionUnavailable;
        const source_state = try ensureStdinSource(runtime, context);
        // 既存挙動を保つためEOFまで読み切ってから行ごとにcallbackする。
        _ = try source_state.drainAll();
        var callback = try actual_effects.resolve(source);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callback);
        while (try source_state.readLine()) |line| {
            var line_value = try runtime.stringUtf8Lossy(line);
            try roots.protect(&line_value);
            try actual_effects.setGlobal("対象", line_value);
            _ = try actual_effects.invoke(callback, &.{line_value});
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

/// テキスト系stdin命令が使う共有sourceをhostへ問い合わせる。
/// `標準入力バイト読む` 等のraw命令が先に作っていればそれをそのまま使い、
/// 両系統で `consumed` カーソルと履歴が共有される（Issue #28の
/// 「stdinの単一source of truth」要件）。
pub fn ensureStdinSource(runtime: *Runtime, context: Context) !*low_level_io.StdinSource {
    const function = context.stdinSourceFn orelse return error.StandardInputUnavailable;
    return function(context.context, runtime.allocator());
}
