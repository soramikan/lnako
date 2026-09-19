const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const shared = @import("shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_process = @import("../../low_level_process.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = shared.Runtime;
const Value = shared.Value;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const numberValue = shared.numberValue;
const valueToNumber = shared.valueToNumber;
const valueUtf16Alloc = shared.valueUtf16Alloc;
const runtimeUtf8String = shared.runtimeUtf8String;
const isString = shared.isString;
const dictionaryProperty = shared.dictionaryProperty;
const setField = shared.setField;
const throwIoAs = shared.throwIoAs;
const throwStructured = shared.throwStructured;
const rememberHandle = shared.rememberHandle;
const forgetHandle = shared.forgetHandle;
const findHandleId = shared.findHandleId;
const processTable = shared.processTable;
const ensureProcessIo = shared.ensureProcessIo;
const aotThrownCode = shared.aotThrownCode;

const lowLevelProcessBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelProcessBuiltin else void;

fn wtf8Alloc(runtime: *Runtime, arena: std.mem.Allocator, value: Value) ![]u8 {
    const units = valueUtf16Alloc(runtime, value) catch |failure| return failure;
    defer runtime.allocator.free(units);
    return foundation.pathBytesFromUtf16(arena, units);
}

/// なでしこ文字列（日本語のstream名を含む）をlossy UTF-8へ落として
/// capability名と比較する。
fn utf8LossyAlloc(runtime: *Runtime, value: Value) ![]u8 {
    return shared.valueUtf8LossyAlloc(runtime, value);
}

fn requireStream(runtime: *Runtime, value: Value, operation: []const u8) !foundation.ProcessStream {
    if (!isString(value)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "STREAMは文字列である必要があります");
    }
    const text = try utf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    return foundation.ProcessStream.fromText(text) orelse {
        return throwStructured(runtime, .EINVAL, operation, null, null, "STREAMは標準入力/標準出力/標準エラー出力のいずれかです");
    };
}

fn parseStdioMode(runtime: *Runtime, value: Value, operation: []const u8) !foundation.ProcessStdioMode {
    if (!isString(value)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "stdioは文字列である必要があります");
    }
    const text = try utf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    return foundation.ProcessStdioMode.fromText(text) orelse {
        return throwStructured(runtime, .EINVAL, operation, null, null, "stdioはinherit/pipe/nullのいずれかです");
    };
}

fn applyStdioMode(
    runtime: *Runtime,
    value: Value,
    operation: []const u8,
    stdin: *foundation.ProcessStdioMode,
    stdout: *foundation.ProcessStdioMode,
    stderr: *foundation.ProcessStdioMode,
) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string, .utf16_string => {
            const mode = try parseStdioMode(runtime, value, operation);
            stdin.* = mode;
            stdout.* = mode;
            stderr.* = mode;
        },
        .dictionary => {
            const dictionary = value.object().?.payload.dictionary;
            const stdin_field = dictionaryProperty(value, &.{ 's', 't', 'd', 'i', 'n' });
            if (stdin_field.tag != @intFromEnum(Tag.undefined)) stdin.* = try parseStdioMode(runtime, stdin_field, operation);
            const stdout_field = dictionaryProperty(value, &.{ 's', 't', 'd', 'o', 'u', 't' });
            if (stdout_field.tag != @intFromEnum(Tag.undefined)) stdout.* = try parseStdioMode(runtime, stdout_field, operation);
            const stderr_field = dictionaryProperty(value, &.{ 's', 't', 'd', 'e', 'r', 'r' });
            if (stderr_field.tag != @intFromEnum(Tag.undefined)) stderr.* = try parseStdioMode(runtime, stderr_field, operation);
            _ = dictionary;
        },
        else => return throwStructured(runtime, .EINVAL, operation, null, null, "stdioは文字列または辞書である必要があります"),
    }
}

fn u32Argument(value: Value) !u32 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => blk: {
            const number = valueToNumber(value);
            if (!foundation.isSafeInteger(number)) return error.InvalidInteger;
            if (number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidInteger;
            break :blk @intFromFloat(number);
        },
        .bigint => blk: {
            const integer = value.object().?.payload.bigint.toU128() catch return error.InvalidInteger;
            if (integer > std.math.maxInt(u32)) return error.InvalidInteger;
            break :blk @intCast(integer);
        },
        else => error.InvalidInteger,
    };
}

fn i32Argument(value: Value) !i32 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => blk: {
            const number = valueToNumber(value);
            if (!foundation.isSafeInteger(number)) return error.InvalidInteger;
            if (number < @as(f64, @floatFromInt(std.math.minInt(i32))) or
                number > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return error.InvalidInteger;
            break :blk @intFromFloat(number);
        },
        .bigint => blk: {
            const integer = value.object().?.payload.bigint.toI128() catch return error.InvalidInteger;
            if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32)) return error.InvalidInteger;
            break :blk @intCast(integer);
        },
        else => error.InvalidInteger,
    };
}

/// `プロセス起動`。ARGVは文字列の配列、OPTIONSはcwd/env/stdio/detachedの辞書。
pub fn spawnBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.spawn;
    const capability: foundation.Capability = .argv_spawn;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "ARGVは文字列の配列である必要があります");
    }
    if (arguments[0].tag != @intFromEnum(Tag.array)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "ARGVは文字列の配列である必要があります");
    }

    var arena_state = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    for (arguments[0].object().?.payload.array.items) |item| {
        if (!isString(item)) {
            return throwStructured(runtime, .EINVAL, operation, null, null, "ARGVの要素は文字列である必要があります");
        }
        try argv.append(arena, try wtf8Alloc(runtime, arena, item));
    }
    if (argv.items.len == 0) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "ARGVが空です");
    }

    var options = low_level_process.SpawnOptions{};
    var env: std.ArrayList(low_level_process.EnvEntry) = .empty;
    if (arguments.len > 1 and arguments[1].tag != @intFromEnum(Tag.undefined)) {
        if (arguments[1].tag != @intFromEnum(Tag.dictionary)) {
            return throwStructured(runtime, .EINVAL, operation, null, null, "OPTIONSは辞書である必要があります");
        }
        const cwd_value = dictionaryProperty(arguments[1], &.{ 'c', 'w', 'd' });
        if (cwd_value.tag != @intFromEnum(Tag.undefined)) {
            if (!isString(cwd_value)) {
                return throwStructured(runtime, .EINVAL, operation, null, null, "cwdは文字列である必要があります");
            }
            options.cwd = try wtf8Alloc(runtime, arena, cwd_value);
        }
        const env_value = dictionaryProperty(arguments[1], &.{ 'e', 'n', 'v' });
        if (env_value.tag != @intFromEnum(Tag.undefined)) {
            if (env_value.tag != @intFromEnum(Tag.dictionary)) {
                return throwStructured(runtime, .EINVAL, operation, null, null, "envは辞書である必要があります");
            }
            for (env_value.object().?.payload.dictionary.entries.items) |entry| {
                if (!isString(entry.value)) {
                    return throwStructured(runtime, .EINVAL, operation, null, null, "envの値は文字列である必要があります");
                }
                const name = try wtf8Alloc(runtime, arena, entry.key);
                const value_text = try wtf8Alloc(runtime, arena, entry.value);
                try env.append(arena, .{ .name = name, .value = value_text });
            }
            options.env = env.items;
        }
        const stdio_value = dictionaryProperty(arguments[1], &.{ 's', 't', 'd', 'i', 'o' });
        if (stdio_value.tag != @intFromEnum(Tag.undefined)) {
            try applyStdioMode(runtime, stdio_value, operation, &options.stdin, &options.stdout, &options.stderr);
        }
        const detached_value = dictionaryProperty(arguments[1], &.{ 'd', 'e', 't', 'a', 'c', 'h', 'e', 'd' });
        if (detached_value.tag != @intFromEnum(Tag.undefined)) {
            if (detached_value.tag != @intFromEnum(Tag.boolean)) {
                return throwStructured(runtime, .EINVAL, operation, null, null, "detachedは真偽値である必要があります");
            }
            options.detached = detached_value.payload != 0;
        }
    }

    const io = ensureProcessIo(runtime);
    const raw = processTable(runtime).spawn(io, argv.items, options) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, capability);
    };
    errdefer processTable(runtime).discard(io, raw) catch {};
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    try rememberHandle(runtime, handle, raw);
    return handle;
}

/// `プロセス待機`。handleを消費し、waitResult（exitCode/signal）を返す。
pub fn waitBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.wait;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    };
    // ファイル/ハッシュhandleを待機へ渡された場合はプロセス表も対応表も
    // 変更しない（元の資源を操作不能にしない）。
    if (!foundation.isProcessHandleId(id)) {
        return throwStructured(runtime, .EBADF, operation, null, null, "無効なハンドルです");
    }
    const io = ensureProcessIo(runtime);
    const result = processTable(runtime).wait(io, id) catch |failure| {
        // 失敗経路でもentryは消費済みなので、言語handleを残さない。
        forgetHandle(runtime, arguments[0]);
        if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
        return throwIoAs(runtime, failure, operation, null, .argv_spawn);
    };
    forgetHandle(runtime, arguments[0]);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());

    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createDictionary(&.{});
    try setField(runtime, roots[0], foundation.wait_result_keys.exit_code, numberValue(@floatFromInt(result.exit_code)));
    roots[1] = if (result.signal) |signal| numberValue(@floatFromInt(signal)) else .{ .tag = @intFromEnum(Tag.null_value) };
    try setField(runtime, roots[0], foundation.wait_result_keys.signal, roots[1]);
    return roots[0];
}

/// `プロセスID取得`。現在のプロセスのpidを返す。
pub fn pidGetBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    _ = arguments;
    _ = ensureProcessIo(runtime);
    return numberValue(@floatFromInt(low_level_process.currentPid()));
}

/// `親プロセスID取得`。取得できない環境はENOTSUPを返す。
pub fn ppidGetBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    _ = arguments;
    _ = ensureProcessIo(runtime);
    const pid = low_level_process.parentPid() catch |failure| {
        return throwIoAs(runtime, failure, foundation.process_operations.getppid, null, .argv_spawn);
    };
    return numberValue(@floatFromInt(pid));
}

/// `シグナル送信`。PIDとSIGNALはいずれもu32。
pub fn signalSendBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.kill;
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDとSIGNALが必要です");
    }
    const pid = u32Argument(arguments[0]) catch {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const signal = u32Argument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, operation, null, null, "SIGNALが不正です");
    };
    low_level_process.sendSignal(pid, signal) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, .signal);
    };
    return .{};
}

/// `プロセス優先度取得`。nice値（数値）を返す。
pub fn priorityGetBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.getpriority;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDが不正です");
    }
    const pid = u32Argument(arguments[0]) catch {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const priority = low_level_process.getPriority(pid) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, .priority);
    };
    return numberValue(@floatFromInt(priority));
}

/// `プロセス優先度設定`。VALUEはi32（負のnice値も許す）。
pub fn prioritySetBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.setpriority;
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDとVALUEが必要です");
    }
    const pid = u32Argument(arguments[0]) catch {
        return throwStructured(runtime, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const value = i32Argument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, operation, null, null, "VALUEが不正です");
    };
    low_level_process.setPriority(pid, value) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, .priority);
    };
    return .{};
}

/// `端末判定`。STREAMが端末ならtrue。
pub fn ttyIsattyBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.isatty;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "STREAMが必要です");
    }
    const stream = try requireStream(runtime, arguments[0], operation);
    const result = low_level_process.isTty(ensureProcessIo(runtime), processStreamFile(runtime, stream)) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, .tty_isatty);
    };
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
}

/// `端末サイズ取得`。rows/columnsの辞書を返す。非端末はENOTSUP。
pub fn ttySizeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.process_operations.winsize;
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "STREAMが必要です");
    }
    const stream = try requireStream(runtime, arguments[0], operation);
    const size = low_level_process.ttySize(ensureProcessIo(runtime), processStreamFile(runtime, stream)) catch |failure| {
        return throwIoAs(runtime, failure, operation, null, .tty_isatty);
    };
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createDictionary(&.{});
    try setField(runtime, roots[0], foundation.tty_size_keys.rows, numberValue(@floatFromInt(size.rows)));
    try setField(runtime, roots[0], foundation.tty_size_keys.columns, numberValue(@floatFromInt(size.columns)));
    return roots[0];
}

fn processStreamFile(runtime: *Runtime, stream: foundation.ProcessStream) std.Io.File {
    return switch (stream) {
        .stdin => state.stdioStdinFile(runtime),
        .stdout => state.stdioStdoutFile(runtime),
        .stderr => state.stdioStderrFile(runtime),
    };
}

/// 埋め込みinterpreter（dynamic bridge）向けHost callback。spawn/waitは
/// AOT Runtimeのプロセス表を共有する。
pub fn pluginSpawnProcess(context: *anyopaque, argv: []const []const u8, options: low_level_process.SpawnOptions) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return (try processTable(runtime).spawn(ensureProcessIo(runtime), argv, options)).raw();
}

pub fn pluginWaitProcess(context: *anyopaque, raw: u64) anyerror!low_level_process.WaitResult {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return processTable(runtime).wait(ensureProcessIo(runtime), foundation.HandleId.fromRaw(raw));
}

pub fn pluginDiscardProcess(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return processTable(runtime).discard(ensureProcessIo(runtime), foundation.HandleId.fromRaw(raw));
}

pub fn pluginGetpid(_: *anyopaque) anyerror!u32 {
    return low_level_process.currentPid();
}

pub fn pluginGetppid(_: *anyopaque) anyerror!u32 {
    return low_level_process.parentPid();
}

pub fn pluginSignal(_: *anyopaque, pid: u32, signal: u32) anyerror!void {
    return low_level_process.sendSignal(pid, signal);
}

pub fn pluginPriorityGet(_: *anyopaque, pid: u32) anyerror!i32 {
    return low_level_process.getPriority(pid);
}

pub fn pluginPrioritySet(_: *anyopaque, pid: u32, value: i32) anyerror!void {
    return low_level_process.setPriority(pid, value);
}

pub fn pluginIsatty(context: *anyopaque, stream: foundation.ProcessStream) anyerror!bool {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_process.isTty(ensureProcessIo(runtime), processStreamFile(runtime, stream));
}

pub fn pluginTtySize(context: *anyopaque, stream: foundation.ProcessStream) anyerror!low_level_process.TtySize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_process.ttySize(ensureProcessIo(runtime), processStreamFile(runtime, stream));
}

test "AOTプロセス起動はARGV非配列と空配列をEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_spawn, &.{numberValue(1)}));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings("EINVAL", code);

    roots[0] = try runtime.createArray(&.{});
    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_spawn, &.{roots[0]}));
    const empty_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(empty_code);
    try std.testing.expectEqualStrings("EINVAL", empty_code);
}

test "AOTプロセスAPIはPID/SIGNAL非整数をEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_signal_send, &.{ numberValue(-1), numberValue(15) }));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings("EINVAL", code);

    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_priority_set, &.{ numberValue(1), numberValue(1.5) }));
    const value_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(value_code);
    try std.testing.expectEqualStrings("EINVAL", value_code);
}

fn spawnArgv(runtime: *Runtime, argv: []const []const u8) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    for (argv) |argument| {
        roots[1] = try runtimeUtf8String(runtime, argument);
        _ = try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

test "AOTは実プロセスを起動し終了コードとシグナル終了をwaitResultで返す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try spawnArgv(&runtime, &.{"/usr/bin/false"});
    roots[1] = try lowLevelProcessBuiltin(&runtime, .low_level_process_spawn, &.{roots[0]});
    const result = try lowLevelProcessBuiltin(&runtime, .low_level_process_wait, &.{roots[1]});
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(dictionaryProperty(result, &.{ 'e', 'x', 'i', 't', 'C', 'o', 'd', 'e' })));
    try std.testing.expectEqual(@intFromEnum(Tag.null_value), dictionaryProperty(result, &.{ 's', 'i', 'g', 'n', 'a', 'l' }).tag);
    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_wait, &.{roots[1]}));
    const double_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(double_code);
    try std.testing.expectEqualStrings("EBADF", double_code);

    roots[2] = try spawnArgv(&runtime, &.{ "/bin/sleep", "30" });
    roots[3] = try lowLevelProcessBuiltin(&runtime, .low_level_process_spawn, &.{roots[2]});
    const id = findHandleId(&runtime, roots[3]) orelse return error.TestExpectedEqual;
    const pid: u32 = @intCast(processTable(&runtime).find(id).?.child.id.?);
    _ = try lowLevelProcessBuiltin(&runtime, .low_level_signal_send, &.{ numberValue(@floatFromInt(pid)), numberValue(15) });
    const killed = try lowLevelProcessBuiltin(&runtime, .low_level_process_wait, &.{roots[3]});
    try std.testing.expectEqual(@as(f64, 15), valueToNumber(dictionaryProperty(killed, &.{ 's', 'i', 'g', 'n', 'a', 'l' })));
}

test "AOTのPID/優先度/端末判定は実OSの値を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const pid = try lowLevelProcessBuiltin(&runtime, .low_level_pid_get, &.{});
    try std.testing.expect(valueToNumber(pid) >= 1);
    _ = try lowLevelProcessBuiltin(&runtime, .low_level_ppid_get, &.{});
    // priorityはPOSIX専用。WindowsはENOTSUPなので値の検証は非Windowsだけで行う。
    if (builtin.os.tag != .windows) {
        const priority = try lowLevelProcessBuiltin(&runtime, .low_level_process_priority_get, &.{pid});
        const priority_value = valueToNumber(priority);
        try std.testing.expectEqual(priority_value, @trunc(priority_value));
        _ = try lowLevelProcessBuiltin(&runtime, .low_level_process_priority_set, &.{ pid, numberValue(priority_value) });
        const priority_again = try lowLevelProcessBuiltin(&runtime, .low_level_process_priority_get, &.{pid});
        try std.testing.expectEqual(priority_value, valueToNumber(priority_again));
    } else {
        try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_priority_get, &.{pid}));
        const priority_code = try aotThrownCode(&runtime);
        defer runtime.allocator.free(priority_code);
        try std.testing.expectEqualStrings("ENOTSUP", priority_code);
    }

    roots[0] = try runtimeUtf8String(&runtime, "標準出力");
    const tty = try lowLevelProcessBuiltin(&runtime, .low_level_tty_isatty, &.{roots[0]});
    try std.testing.expectEqual(@intFromEnum(Tag.boolean), tty.tag);
    if (low_level_process.isTty(ensureProcessIo(&runtime), std.Io.File.stdout()) catch false) {
        const size = try lowLevelProcessBuiltin(&runtime, .low_level_tty_size, &.{roots[0]});
        try std.testing.expect(valueToNumber(dictionaryProperty(size, &.{ 'r', 'o', 'w', 's' })) > 0);
        try std.testing.expect(valueToNumber(dictionaryProperty(size, &.{ 'c', 'o', 'l', 'u', 'm', 'n', 's' })) > 0);
    } else {
        try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_tty_size, &.{roots[0]}));
        const code = try aotThrownCode(&runtime);
        defer runtime.allocator.free(code);
        try std.testing.expectEqualStrings("ENOTSUP", code);
    }
}

test "AOTのプロセス待機は別種handleを消費しない" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    try rememberHandle(&runtime, roots[0], .{ .index = 1, .generation = 1 });
    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_wait, &.{roots[0]}));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings("EBADF", code);
    // 対応表から消えていない（ファイル/ハッシュhandleとして引き続き使える）。
    try std.testing.expect(findHandleId(&runtime, roots[0]) != null);
}

test "AOTプロセス起動は存在しない実行ファイルをENOENTにする" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try spawnArgv(&runtime, &.{"/nonexistent/lnako-test-binary"});
    try std.testing.expectError(error.NakoException, lowLevelProcessBuiltin(&runtime, .low_level_process_spawn, &.{roots[0]}));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings("ENOENT", code);
}
