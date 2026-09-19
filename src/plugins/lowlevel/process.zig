const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_process = @import("../../runtime/low_level_process.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
const node_shared = @import("../node/shared.zig");
const shared = @import("shared.zig");
// ドメインテストはディスパッチャ経由で契約を検査する。本番ビルドでは
// call.zigを解析しないよう、テスト時にだけ読み込んで閉路を避ける。
const call = if (builtin.is_test) @import("call.zig").call else void;

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;
const emptyContext = low_level_context.emptyContext;

const throwStructured = shared.throwStructured;
const throwIo = shared.throwIo;
const throwIoAs = shared.throwIoAs;
const lookupHandle = shared.lookupHandle;
const forgetHandle = shared.forgetHandle;
const rememberHandle = shared.rememberHandle;
const u32Argument = shared.u32Argument;
const i32Argument = shared.i32Argument;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;

/// nadesiko文字列をOSへ渡すWTF-8へ可逆変換する。孤立サロゲートは保持し、
/// argvやenvでエスケープ崩れを起こさない。
fn requireWtf8(value: Value, allocator: std.mem.Allocator) ![]u8 {
    if (value != .string) return error.InvalidType;
    return foundation.pathBytesFromUtf16(allocator, value.string.units);
}

fn requireStream(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !foundation.ProcessStream {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "STREAMは文字列である必要があります");
    }
    const text = try node_shared.valueUtf8(runtime, value);
    defer runtime.allocator().free(text);
    return foundation.ProcessStream.fromText(text) orelse {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "STREAMは標準入力/標準出力/標準エラー出力のいずれかです");
    };
}

fn parseStdioMode(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !foundation.ProcessStdioMode {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "stdioは文字列である必要があります");
    }
    const text = try node_shared.valueUtf8(runtime, value);
    defer runtime.allocator().free(text);
    return foundation.ProcessStdioMode.fromText(text) orelse {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "stdioはinherit/pipe/nullのいずれかです");
    };
}

fn applyStdioMode(
    runtime: *Runtime,
    effects: Effects,
    operation: []const u8,
    value: Value,
    stdin: *foundation.ProcessStdioMode,
    stdout: *foundation.ProcessStdioMode,
    stderr: *foundation.ProcessStdioMode,
) !void {
    if (value == .string) {
        const mode = try parseStdioMode(runtime, effects, value, operation);
        stdin.* = mode;
        stdout.* = mode;
        stderr.* = mode;
        return;
    }
    if (value != .dictionary) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "stdioは文字列または辞書である必要があります");
    }
    if (node_shared.dictionaryGetAscii(value.dictionary, foundation.ProcessStream.stdin.name())) |field| {
        stdin.* = try parseStdioMode(runtime, effects, field, operation);
    }
    if (node_shared.dictionaryGetAscii(value.dictionary, foundation.ProcessStream.stdout.name())) |field| {
        stdout.* = try parseStdioMode(runtime, effects, field, operation);
    }
    if (node_shared.dictionaryGetAscii(value.dictionary, foundation.ProcessStream.stderr.name())) |field| {
        stderr.* = try parseStdioMode(runtime, effects, field, operation);
    }
}

/// `プロセス起動`。ARGVは文字列の配列、OPTIONSはcwd/env/stdio/detachedの辞書。
/// すべての一時メモリはこの呼び出しのarenaが所有し、spawn後に解放する。
pub fn spawn(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.spawn;
    const capability: foundation.Capability = .argv_spawn;
    const argv_value = common.argument(arguments, 0);
    if (argv_value != .array) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "ARGVは文字列の配列である必要があります");
    }

    var arena_state = std.heap.ArenaAllocator.init(runtime.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < argv_value.array.len()) : (index += 1) {
        const item = argv_value.array.get(index);
        const owned = requireWtf8(item, arena) catch |failure| switch (failure) {
            error.InvalidType => return throwStructured(runtime, effects, .EINVAL, operation, null, null, "ARGVの要素は文字列である必要があります"),
            else => return failure,
        };
        try argv.append(arena, owned);
    }
    if (argv.items.len == 0) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "ARGVが空です");
    }

    var options = low_level_process.SpawnOptions{};
    var env: std.ArrayList(low_level_process.EnvEntry) = .empty;
    const options_value = common.argument(arguments, 1);
    if (options_value != .undefined) {
        if (options_value != .dictionary) {
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, "OPTIONSは辞書である必要があります");
        }
        if (node_shared.dictionaryGetAscii(options_value.dictionary, foundation.process_option_keys.cwd)) |cwd_value| {
            if (cwd_value != .undefined) {
                options.cwd = requireWtf8(cwd_value, arena) catch |failure| switch (failure) {
                    error.InvalidType => return throwStructured(runtime, effects, .EINVAL, operation, null, null, "cwdは文字列である必要があります"),
                    else => return failure,
                };
            }
        }
        if (node_shared.dictionaryGetAscii(options_value.dictionary, foundation.process_option_keys.env)) |env_value| {
            if (env_value != .undefined) {
                if (env_value != .dictionary) {
                    return throwStructured(runtime, effects, .EINVAL, operation, null, null, "envは辞書である必要があります");
                }
                const keys = env_value.dictionary.keys();
                const values = env_value.dictionary.values();
                for (keys, values) |key, env_field| {
                    if (env_field != .string) {
                        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "envの値は文字列である必要があります");
                    }
                    const name = foundation.pathBytesFromUtf16(arena, key.units) catch |failure| return failure;
                    const value_text = foundation.pathBytesFromUtf16(arena, env_field.string.units) catch |failure| return failure;
                    try env.append(arena, .{ .name = name, .value = value_text });
                }
                options.env = env.items;
            }
        }
        if (node_shared.dictionaryGetAscii(options_value.dictionary, foundation.process_option_keys.stdio)) |stdio_value| {
            if (stdio_value != .undefined) {
                try applyStdioMode(runtime, effects, operation, stdio_value, &options.stdin, &options.stdout, &options.stderr);
            }
        }
        if (node_shared.dictionaryGetAscii(options_value.dictionary, foundation.process_option_keys.detached)) |detached_value| {
            if (detached_value != .undefined) {
                if (detached_value != .boolean) {
                    return throwStructured(runtime, effects, .EINVAL, operation, null, null, "detachedは真偽値である必要があります");
                }
                options.detached = detached_value.boolean;
            }
        }
    }

    const raw = context.spawnProcess(argv.items, options) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, capability);
    };
    errdefer context.discardProcess(raw) catch {};

    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(state, runtime.allocator(), handle, foundation.HandleId.fromRaw(raw));
    return handle;
}

/// `プロセス待機`。handleを消費し、waitResult（exitCode/signal）を返す。
pub fn wait(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.wait;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    // ファイル/ハッシュhandleを待機へ渡された場合はプロセス表を変更しない。
    // ここで対応表を消すと元の資源が操作不能になるため、保持したままEBADFにする。
    if (!foundation.isProcessHandleId(id)) {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    }
    const result = context.waitProcess(id.raw()) catch |failure| {
        // 失敗経路でもentryは消費済みなので、言語handleを残すと再waitが
        // 二重解放相当になる。必ずforgetしてからエラーを返す。
        forgetHandle(state, handle);
        return throwIoAs(runtime, effects, failure, operation, null, .argv_spawn);
    };
    forgetHandle(state, handle);
    return waitResultValue(runtime, result);
}

fn waitResultValue(runtime: *Runtime, result: low_level_process.WaitResult) !Value {
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.wait_result_keys.exit_code, .{ .number = @floatFromInt(result.exit_code) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.wait_result_keys.signal, if (result.signal) |signal| .{ .number = @floatFromInt(signal) } else .null_value);
    return dictionary;
}

/// `プロセスID取得`。現在のプロセスのpidを返す。
pub fn pidGet(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = arguments;
    const pid = context.processId() catch |failure| {
        return throwIoAs(runtime, effects, failure, foundation.process_operations.getpid, null, .argv_spawn);
    };
    return .{ .number = @floatFromInt(pid) };
}

/// `親プロセスID取得`。取得できない環境はENOTSUPを返す。
pub fn ppidGet(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = arguments;
    const pid = context.parentProcessId() catch |failure| {
        return throwIoAs(runtime, effects, failure, foundation.process_operations.getppid, null, .argv_spawn);
    };
    return .{ .number = @floatFromInt(pid) };
}

/// `シグナル送信`。PIDとSIGNALはいずれもu32。
pub fn signalSend(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.kill;
    const pid = u32Argument(common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const signal = u32Argument(common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "SIGNALが不正です");
    };
    context.signalProcess(pid, signal) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, .signal);
    };
    return .undefined;
}

/// `プロセス優先度取得`。nice値（数値）を返す。
pub fn priorityGet(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.getpriority;
    const pid = u32Argument(common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const priority = context.processPriority(pid) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, .priority);
    };
    return .{ .number = @floatFromInt(priority) };
}

/// `プロセス優先度設定`。VALUEはi32（負のnice値も許す）。
pub fn prioritySet(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.setpriority;
    const pid = u32Argument(common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "PIDが不正です");
    };
    const value = i32Argument(common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "VALUEが不正です");
    };
    context.setProcessPriority(pid, value) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, .priority);
    };
    return .undefined;
}

/// `端末判定`。STREAMが端末ならtrue。
pub fn ttyIsatty(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.isatty;
    const stream = try requireStream(runtime, effects, common.argument(arguments, 0), operation);
    const result = context.processIsatty(stream) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, .tty_isatty);
    };
    return .{ .boolean = result };
}

/// `端末サイズ取得`。rows/columnsの辞書を返す。非端末はENOTSUP。
pub fn ttySize(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.process_operations.winsize;
    const stream = try requireStream(runtime, effects, common.argument(arguments, 0), operation);
    const size = context.processTtySize(stream) catch |failure| {
        return throwIoAs(runtime, effects, failure, operation, null, .tty_isatty);
    };
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.tty_size_keys.rows, .{ .number = @floatFromInt(size.rows) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.tty_size_keys.columns, .{ .number = @floatFromInt(size.columns) });
    return dictionary;
}

test "プロセス起動はARGV非配列と要素非文字列をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス起動", &.{.{ .number = 1 }}));
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var array = try runtime.createArray();
    try roots.protect(&array);
    _ = try array.array.push(.{ .number = 1 });
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス起動", &.{array}));
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var empty = try runtime.createArray();
    try roots.protect(&empty);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス起動", &.{empty}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "プロセス起動はhost不在でENOTSUPとargv_spawnを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var array = try runtime.createArray();
    try roots.protect(&array);
    var program = try runtime.stringUtf8("/bin/echo");
    try roots.protect(&program);
    _ = try array.array.push(program);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス起動", &.{array}));
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "argv_spawn");
}

test "端末判定と端末サイズはSTREAM不正をEINVAL、host不在をENOTSUPにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "端末判定", &.{.{ .number = 1 }}));
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var bad_stream = try runtime.stringUtf8("bogus");
    try roots.protect(&bad_stream);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "端末判定", &.{bad_stream}));
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var stdout = try runtime.stringUtf8("標準出力");
    try roots.protect(&stdout);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "端末判定", &.{stdout}));
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "tty_isatty");
}

test "シグナル送信は非整数のPID/SIGNALをEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "シグナル送信", &.{ .{ .number = -1 }, .{ .number = 15 } }));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "シグナル送信", &.{ .{ .number = 1 }, .{ .string = undefined } }));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "プロセス待機は別種handleを消費せずEBADFにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    // ファイルhandleのindex空間のhandleを待機へ渡しても、対応表から消さない。
    var file_handle = try runtime.createDictionary();
    try roots.protect(&file_handle);
    try rememberHandle(&state, runtime.allocator(), file_handle, .{ .index = 1, .generation = 1 });
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス待機", &.{file_handle}));
    try expectThrownCode(&runtime, thrown, "EBADF");
    try std.testing.expect(lookupHandle(&state, file_handle) != null);

    // ハッシュhandleのindex空間でも同様。
    var hash_handle = try runtime.createDictionary();
    try roots.protect(&hash_handle);
    try rememberHandle(&state, runtime.allocator(), hash_handle, .{ .index = foundation.hash_handle_index_base, .generation = 1 });
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス待機", &.{hash_handle}));
    try expectThrownCode(&runtime, thrown, "EBADF");
    try std.testing.expect(lookupHandle(&state, hash_handle) != null);
}

test "プロセス優先度設定は非整数VALUEをEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "プロセス優先度設定", &.{ .{ .number = 1 }, .{ .number = 1.5 } }));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

/// tty成功経路の値整形を検証するhost（OS ioctlには依存しない）。
const FakeTtyHost = struct {
    var dummy: u8 = 0;

    fn isatty(_: *anyopaque, _: foundation.ProcessStream) anyerror!bool {
        return true;
    }

    fn hostTtySize(_: *anyopaque, _: foundation.ProcessStream) anyerror!low_level_process.TtySize {
        return .{ .rows = 24, .columns = 80 };
    }

    fn context() Context {
        return .{ .process = .{
            .context = @ptrCast(&dummy),
            .isattyFn = isatty,
            .ttySizeFn = hostTtySize,
        } };
    }
};

test "端末判定/端末サイズ取得は成功値を返しcapabilityがtrueになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var stream = try runtime.stringUtf8("stdout");
    try roots.protect(&stream);
    var tty = (try call(&runtime, &state, FakeTtyHost.context(), effects, "端末判定", &.{stream})) orelse return error.TestExpectedEqual;
    try roots.protect(&tty);
    try std.testing.expect(tty == .boolean and tty.boolean);

    var size = (try call(&runtime, &state, FakeTtyHost.context(), effects, "端末サイズ取得", &.{stream})) orelse return error.TestExpectedEqual;
    try roots.protect(&size);
    const rows = node_shared.dictionaryGetAscii(size.dictionary, foundation.tty_size_keys.rows) orelse return error.TestExpectedEqual;
    const columns = node_shared.dictionaryGetAscii(size.dictionary, foundation.tty_size_keys.columns) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 24), rows.number);
    try std.testing.expectEqual(@as(f64, 80), columns.number);

    var capability_name = try runtime.stringUtf8("tty_isatty");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, FakeTtyHost.context(), effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);
}

/// 実OSのプロセス表をProcessContextとして公開するテストhost。
/// テスト時だけ実体を持ち、本番ビルドでは空型としてコードへ残さない。
const ProcessTestHost = if (builtin.is_test) struct {
    table: low_level_process.ProcessTable,
    io: std.Io,

    fn init(io: std.Io) ProcessTestHost {
        return .{ .table = low_level_process.ProcessTable.init(std.testing.allocator), .io = io };
    }

    fn deinit(self: *ProcessTestHost) void {
        self.table.deinit(self.io);
    }

    fn spawnProcess(pointer: *anyopaque, argv: []const []const u8, options: low_level_process.SpawnOptions) anyerror!u64 {
        const self: *ProcessTestHost = @ptrCast(@alignCast(pointer));
        return (try self.table.spawn(self.io, argv, options)).raw();
    }

    fn waitProcess(pointer: *anyopaque, raw: u64) anyerror!low_level_process.WaitResult {
        const self: *ProcessTestHost = @ptrCast(@alignCast(pointer));
        return self.table.wait(self.io, foundation.HandleId.fromRaw(raw));
    }

    fn discardProcess(pointer: *anyopaque, raw: u64) anyerror!void {
        const self: *ProcessTestHost = @ptrCast(@alignCast(pointer));
        return self.table.discard(self.io, foundation.HandleId.fromRaw(raw));
    }

    fn getpid(_: *anyopaque) anyerror!u32 {
        return low_level_process.currentPid();
    }

    fn getppid(_: *anyopaque) anyerror!u32 {
        return low_level_process.parentPid();
    }

    fn signal(_: *anyopaque, pid: u32, signal_number: u32) anyerror!void {
        return low_level_process.sendSignal(pid, signal_number);
    }

    fn hostPriorityGet(_: *anyopaque, pid: u32) anyerror!i32 {
        return low_level_process.getPriority(pid);
    }

    fn hostPrioritySet(_: *anyopaque, pid: u32, value: i32) anyerror!void {
        return low_level_process.setPriority(pid, value);
    }

    fn isatty(pointer: *anyopaque, stream: foundation.ProcessStream) anyerror!bool {
        const self: *ProcessTestHost = @ptrCast(@alignCast(pointer));
        return low_level_process.isTty(self.io, self.fileFor(stream));
    }

    fn hostTtySize(pointer: *anyopaque, stream: foundation.ProcessStream) anyerror!low_level_process.TtySize {
        const self: *ProcessTestHost = @ptrCast(@alignCast(pointer));
        return low_level_process.ttySize(self.io, self.fileFor(stream));
    }

    fn fileFor(self: *ProcessTestHost, stream: foundation.ProcessStream) std.Io.File {
        _ = self;
        return switch (stream) {
            .stdin => std.Io.File.stdin(),
            .stdout => std.Io.File.stdout(),
            .stderr => std.Io.File.stderr(),
        };
    }

    fn context(self: *ProcessTestHost) Context {
        return .{ .process = .{
            .context = @ptrCast(self),
            .spawnFn = spawnProcess,
            .waitFn = waitProcess,
            .discardFn = discardProcess,
            .getpidFn = getpid,
            .getppidFn = getppid,
            .signalFn = signal,
            .priorityGetFn = hostPriorityGet,
            .prioritySetFn = hostPrioritySet,
            .isattyFn = isatty,
            .ttySizeFn = hostTtySize,
        } };
    }
} else struct {};

test "InterpreterのOPTIONSはcwd/env/stdio/detachedを解釈する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = ProcessTestHost.init(std.testing.io);
    defer host.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var argv = try spawnArgv(&runtime, &.{"/usr/bin/true"});
    try roots.protect(&argv);

    var stdio_dict = try runtime.createDictionary();
    try roots.protect(&stdio_dict);
    var null_mode = try runtime.stringUtf8("null");
    try roots.protect(&null_mode);
    try node_shared.setDictionary(&runtime, stdio_dict.dictionary, "stdout", null_mode);

    var env_dict = try runtime.createDictionary();
    try roots.protect(&env_dict);
    var env_value = try runtime.stringUtf8("1");
    try roots.protect(&env_value);
    try node_shared.setDictionary(&runtime, env_dict.dictionary, "LNAKO_PROC_TEST", env_value);

    var options = try runtime.createDictionary();
    try roots.protect(&options);
    var cwd_value = try runtime.stringUtf8(directory);
    try roots.protect(&cwd_value);
    try node_shared.setDictionary(&runtime, options.dictionary, "cwd", cwd_value);
    try node_shared.setDictionary(&runtime, options.dictionary, "env", env_dict);
    try node_shared.setDictionary(&runtime, options.dictionary, "stdio", stdio_dict);
    try node_shared.setDictionary(&runtime, options.dictionary, "detached", .{ .boolean = false });

    var handle = (try call(&runtime, &state, host.context(), effects, "プロセス起動", &.{ argv, options })) orelse return error.TestExpectedEqual;
    try roots.protect(&handle);
    var result = (try call(&runtime, &state, host.context(), effects, "プロセス待機", &.{handle})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    const exit_code = node_shared.dictionaryGetAscii(result.dictionary, foundation.wait_result_keys.exit_code) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 0), exit_code.number);

    // stdioを単一文字列で指定する形も受理する。
    var any = try runtime.stringUtf8("null");
    try roots.protect(&any);
    var options_string = try runtime.createDictionary();
    try roots.protect(&options_string);
    try node_shared.setDictionary(&runtime, options_string.dictionary, "stdio", any);
    var handle2 = (try call(&runtime, &state, host.context(), effects, "プロセス起動", &.{ argv, options_string })) orelse return error.TestExpectedEqual;
    try roots.protect(&handle2);
    _ = (try call(&runtime, &state, host.context(), effects, "プロセス待機", &.{handle2})) orelse return error.TestExpectedEqual;
}

fn spawnArgv(runtime: *Runtime, argv: []const []const u8) !Value {
    var array = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    for (argv) |argument| {
        var item = try runtime.stringUtf8(argument);
        try roots.protect(&item);
        _ = try array.array.push(item);
    }
    return array;
}

test "Interpreterは実プロセスを起動し終了コードとシグナル終了を待機する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = ProcessTestHost.init(std.testing.io);
    defer host.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var failed_argv = try spawnArgv(&runtime, &.{"/usr/bin/false"});
    try roots.protect(&failed_argv);
    var handle = (try call(&runtime, &state, host.context(), effects, "プロセス起動", &.{failed_argv})) orelse return error.TestExpectedEqual;
    try roots.protect(&handle);
    var result = (try call(&runtime, &state, host.context(), effects, "プロセス待機", &.{handle})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    const exit_code = node_shared.dictionaryGetAscii(result.dictionary, foundation.wait_result_keys.exit_code) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 1), exit_code.number);
    const signal_field = node_shared.dictionaryGetAscii(result.dictionary, foundation.wait_result_keys.signal) orelse return error.TestExpectedEqual;
    try std.testing.expect(signal_field == .null_value);
    // wait後はhandleが無効になり二重待機はEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "プロセス待機", &.{handle}));
    try expectThrownCode(&runtime, thrown, "EBADF");

    var sleep_argv = try spawnArgv(&runtime, &.{ "/bin/sleep", "30" });
    try roots.protect(&sleep_argv);
    var sleep_handle = (try call(&runtime, &state, host.context(), effects, "プロセス起動", &.{sleep_argv})) orelse return error.TestExpectedEqual;
    try roots.protect(&sleep_handle);
    const id = lookupHandle(&state, sleep_handle) orelse return error.TestExpectedEqual;
    const pid: u32 = @intCast(host.table.find(id).?.child.id.?);
    _ = try call(&runtime, &state, host.context(), effects, "シグナル送信", &.{ .{ .number = @floatFromInt(pid) }, .{ .number = 15 } });
    var killed = (try call(&runtime, &state, host.context(), effects, "プロセス待機", &.{sleep_handle})) orelse return error.TestExpectedEqual;
    try roots.protect(&killed);
    const killed_signal = node_shared.dictionaryGetAscii(killed.dictionary, foundation.wait_result_keys.signal) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 15), killed_signal.number);
}

test "InterpreterのPID/優先度/端末系は実OSの値を返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = ProcessTestHost.init(std.testing.io);
    defer host.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var pid = (try call(&runtime, &state, host.context(), effects, "プロセスID取得", &.{})) orelse return error.TestExpectedEqual;
    try roots.protect(&pid);
    try std.testing.expect(pid.number >= 1);
    var ppid = (try call(&runtime, &state, host.context(), effects, "親プロセスID取得", &.{})) orelse return error.TestExpectedEqual;
    try roots.protect(&ppid);
    try std.testing.expect(ppid.number >= 0);

    if (builtin.os.tag != .windows) {
        var priority = (try call(&runtime, &state, host.context(), effects, "プロセス優先度取得", &.{.{ .number = pid.number }})) orelse return error.TestExpectedEqual;
        try roots.protect(&priority);
        // nice値は環境依存なので整数性とget→set→getの一致だけを検証する。
        try std.testing.expectEqual(priority.number, @trunc(priority.number));
        _ = try call(&runtime, &state, host.context(), effects, "プロセス優先度設定", &.{ .{ .number = pid.number }, .{ .number = priority.number } });
        var priority_again = (try call(&runtime, &state, host.context(), effects, "プロセス優先度取得", &.{.{ .number = pid.number }})) orelse return error.TestExpectedEqual;
        try roots.protect(&priority_again);
        try std.testing.expectEqual(priority.number, priority_again.number);
    }

    var stream = try runtime.stringUtf8("標準出力");
    try roots.protect(&stream);
    var tty = (try call(&runtime, &state, host.context(), effects, "端末判定", &.{stream})) orelse return error.TestExpectedEqual;
    try roots.protect(&tty);
    try std.testing.expect(tty == .boolean);
    thrown = .undefined;
    if (low_level_process.isTty(std.testing.io, std.Io.File.stdout()) catch false) {
        var size = (try call(&runtime, &state, host.context(), effects, "端末サイズ取得", &.{stream})) orelse return error.TestExpectedEqual;
        try roots.protect(&size);
        const rows = node_shared.dictionaryGetAscii(size.dictionary, foundation.tty_size_keys.rows) orelse return error.TestExpectedEqual;
        const columns = node_shared.dictionaryGetAscii(size.dictionary, foundation.tty_size_keys.columns) orelse return error.TestExpectedEqual;
        try std.testing.expect(rows.number > 0 and columns.number > 0);
    } else {
        // 非端末（テスト実行環境のstdout）では端末サイズはENOTSUP。
        try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "端末サイズ取得", &.{stream}));
        try expectThrownCode(&runtime, thrown, "ENOTSUP");
    }
}

test "Interpreterのプロセス起動は存在しない実行ファイルをENOENTにする" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = ProcessTestHost.init(std.testing.io);
    defer host.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var argv = try spawnArgv(&runtime, &.{"/nonexistent/lnako-test-binary"});
    try roots.protect(&argv);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "プロセス起動", &.{argv}));
    try expectThrownCode(&runtime, thrown, "ENOENT");
}
