const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const foundation = @import("../runtime/low_level_foundation.zig");
const low_level_io = @import("../runtime/low_level_io.zig");
const common = @import("system/common.zig");
const shared = @import("node/shared.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const Dictionary = value_mod.Dictionary;

/// Interpreterが保持する低レイヤー命令の状態。Handle値は不透明オブジェクト
/// （辞書）であり、その同一性だけをhandle tableの `HandleId` へ結びつける。
/// 同じ形の辞書を手作りしてもこの対応表に載らないため無効になる。
pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    handle_ids: std.AutoHashMapUnmanaged(usize, foundation.HandleId) = .empty,
    handle_by_id: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    handle_values: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        const actual = self.allocator orelse allocator;
        self.handle_ids.deinit(actual);
        self.handle_by_id.deinit(actual);
        self.handle_values.deinit(actual);
        self.* = undefined;
    }

    fn memory(self: *State, allocator: std.mem.Allocator) std.mem.Allocator {
        if (self.allocator) |existing| return existing;
        self.allocator = allocator;
        return allocator;
    }

    pub fn trace(self: *State, runtime: *Runtime) !void {
        for (self.handle_values.items) |value| try runtime.traceExternal(value);
    }
};

/// Host（CliHost）が実装する実OS I/O。関数ポインタはハンドル表を保持する
/// Host側の状態へ繋がる。rawは `HandleId.raw()` であり、なでしこ値には
/// 公開しない。
pub const Context = struct {
    context: *anyopaque,
    openFileFn: ?*const fn (context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 = null,
    closeFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    readFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize = null,
    writeFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize = null,
    syncFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    truncateFileFn: ?*const fn (context: *anyopaque, raw: u64, size: u64) anyerror!void = null,
    /// Issue #28: stdinの単一source of truth。`標準入力バイト読む` と
    /// テキスト系stdin命令（`plugin_node` 経由）が同じ `StdinSource` の
    /// `consumed` カーソルを消費する。sourceはhost側（CliHost等）が所有し、
    /// peekは生成せず既存を返し、stdinSourceFnは無ければ生成する。
    /// `allocator` 引数は助言的で、実装はhost寿命のallocatorで確保すること
    /// （呼び出し側の短命runtime allocatorでsourceを確保するとUAFになる）。
    /// peekとstdinSourceFnはセットで提供すること（peek欠落だとTTY `尋` が
    /// 共有sourceを見落とし直接行readへ切り替わってバイトを置き去りにする）。
    peekStdinSourceFn: ?*const fn (context: *anyopaque) ?*low_level_io.StdinSource = null,
    stdinSourceFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource = null,
    writeStdoutBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    writeStderrBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    syncStdoutFn: ?*const fn (context: *anyopaque) anyerror!void = null,
    syncStderrFn: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn openFile(self: Context, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) !u64 {
        const function = self.openFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, mode, exclusive, sync);
    }

    pub fn closeFile(self: Context, raw: u64) !void {
        const function = self.closeFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw);
    }

    pub fn readFileBytes(self: Context, raw: u64, buffer: []u8) !usize {
        const function = self.readFileBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, buffer);
    }

    pub fn writeFileBytes(self: Context, raw: u64, bytes: []const u8) !usize {
        const function = self.writeFileBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, bytes);
    }

    pub fn syncFile(self: Context, raw: u64) !void {
        const function = self.syncFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw);
    }

    pub fn truncateFile(self: Context, raw: u64, size: u64) !void {
        const function = self.truncateFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, size);
    }

    pub fn stdinSource(self: Context, allocator: std.mem.Allocator) !*low_level_io.StdinSource {
        const function = self.stdinSourceFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator);
    }

    pub fn writeStdoutBytes(self: Context, bytes: []const u8) !usize {
        const function = self.writeStdoutBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, bytes);
    }

    pub fn writeStderrBytes(self: Context, bytes: []const u8) !usize {
        const function = self.writeStderrBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, bytes);
    }

    pub fn syncStdout(self: Context) !void {
        const function = self.syncStdoutFn orelse return error.LowLevelIoUnavailable;
        return function(self.context);
    }

    pub fn syncStderr(self: Context) !void {
        const function = self.syncStderrFn orelse return error.LowLevelIoUnavailable;
        return function(self.context);
    }

    pub fn hasStreamFileIo(self: Context) bool {
        return self.openFileFn != null and self.closeFileFn != null and self.readFileBytesFn != null and self.writeFileBytesFn != null and self.syncFileFn != null;
    }

    pub fn hasTruncate(self: Context) bool {
        return self.truncateFileFn != null;
    }

    pub fn hasRawStdio(self: Context) bool {
        return self.stdinSourceFn != null and self.peekStdinSourceFn != null and self.writeStdoutBytesFn != null and self.writeStderrBytesFn != null and self.syncStdoutFn != null and self.syncStderrFn != null;
    }
};

var unused_context_host: u8 = 0;

pub fn emptyContext() Context {
    return .{ .context = @ptrCast(&unused_context_host) };
}

/// 構造化エラーを例外として投げるためのコールバック。Interpreterが
/// `exception_value` に辞書を設定して `error.NakoException` を返す。
pub const Effects = struct {
    context: *anyopaque,
    throwFn: *const fn (context: *anyopaque, value: Value) anyerror!void,

    pub fn throw(self: Effects, value: Value) !void {
        return self.throwFn(self.context, value);
    }
};

const read_chunk_bytes: usize = 64 * 1024;

pub fn call(
    runtime: *Runtime,
    state: *State,
    context: Context,
    effects: Effects,
    name: []const u8,
    arguments: []const Value,
) !?Value {
    if (foundation.catalogCommandFor(name)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, effects, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        // 実装済み命令の引数不足は引数数エラー。未実装命令はENOTSUPが
        // 「未実装」の通知を兼ねるためmin未満もENOTSUPへ統一する
        // （`aot/low_level.zig` の lowLevelUnsupportedBuiltin と同じ方針）。
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, effects, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    if (std.mem.eql(u8, name, foundation.capability_supported_command)) {
        return @as(?Value, .{ .boolean = capabilitySupported(arguments, context) });
    }
    if (std.mem.eql(u8, name, foundation.capability_list_command)) {
        return @as(?Value, try capabilityList(runtime));
    }
    if (matches(name, foundation.stream_commands.open, foundation.stream_commands.open_user)) return @as(?Value, try openFile(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.close, foundation.stream_commands.close_user)) return @as(?Value, try closeFile(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.read_bytes, foundation.stream_commands.read_bytes_user)) return @as(?Value, try readBytes(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stream_commands.write_bytes, foundation.stream_commands.write_bytes_user)) return @as(?Value, try writeBytes(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stream_commands.sync)) return @as(?Value, try syncFile(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stream_commands.truncate)) return @as(?Value, try truncateFile(runtime, state, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stdin_read, foundation.stdio_commands.stdin_read_user)) return @as(?Value, try stdinRead(runtime, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stdout_write, foundation.stdio_commands.stdout_write_user)) return @as(?Value, try stdoutWrite(runtime, context, effects, arguments));
    if (matches(name, foundation.stdio_commands.stderr_write, foundation.stdio_commands.stderr_write_user)) return @as(?Value, try stderrWrite(runtime, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.stdio_commands.stdout_sync)) return @as(?Value, try stdoutSync(runtime, context, effects));
    if (std.mem.eql(u8, name, foundation.stdio_commands.stderr_sync)) return @as(?Value, try stderrSync(runtime, context, effects));
    // カタログ掲載済みだが未実装の命令は、capabilityとoperationを設定した
    // 構造化 ENOTSUP で応答する（G0の未対応契約）。実装済み命令がここへ
    // 到達するのはdispatch腕の書き忘れなので、開発時に検出する。
    if (foundation.catalogCommandFor(name)) |command| {
        std.debug.assert(!command.implemented);
        const capability: ?[]const u8 = if (command.capability) |cap| cap.id() else null;
        return throwStructured(runtime, effects, .ENOTSUP, command.operation, null, capability, "この低レイヤー命令はまだ実装されていません");
    }
    return null;
}

fn matches(name: []const u8, canonical: []const u8, user_form: []const u8) bool {
    return std.mem.eql(u8, name, canonical) or std.mem.eql(u8, name, user_form);
}

fn capabilitySupported(arguments: []const Value, context: Context) bool {
    const value = common.argument(arguments, 0);
    if (value != .string) return false;
    var buffer: [64]u8 = undefined;
    const length = @min(value.string.units.len, buffer.len);
    for (value.string.units[0..length], 0..) |unit, index| {
        if (unit > 0x7f) return false;
        buffer[index] = @intCast(unit);
    }
    const capability = foundation.Capability.fromId(buffer[0..length]) orelse return false;
    if (!foundation.capabilityImplemented(capability)) return false;
    return switch (capability) {
        .stream_file_io => context.hasStreamFileIo(),
        .truncate => context.hasTruncate(),
        .raw_stdio => context.hasRawStdio(),
        else => false,
    };
}

fn capabilityList(runtime: *Runtime) !Value {
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    inline for (std.meta.tags(foundation.Capability)) |capability| {
        _ = try result.array.push(try runtime.stringUtf8(capability.id()));
    }
    return result;
}

fn openFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const path_value = common.argument(arguments, 0);
    if (path_value != .string) {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.open, null, null, "pathは文字列である必要があります");
    }
    const path = try shared.valueUtf8(runtime, path_value);
    defer runtime.allocator().free(path);
    const mode_value = common.argument(arguments, 1);
    var mode_text: ?[]u8 = null;
    defer if (mode_text) |text| runtime.allocator().free(text);
    if (mode_value != .undefined) {
        if (mode_value != .string) {
            return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.open, path, null, "modeは文字列である必要があります");
        }
        mode_text = try shared.valueUtf8(runtime, mode_value);
    }
    const parsed = foundation.parseOpenMode(mode_text orelse "r") catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.open, path, null, "開くmodeが不正です");
    };
    const raw = context.openFile(path, parsed.mode, parsed.exclusive, parsed.sync) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.open, path);
    };
    errdefer context.closeFile(raw) catch {};
    const id = foundation.HandleId.fromRaw(raw);
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(state, runtime.allocator(), handle, id);
    return handle;
}

fn closeFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    context.closeFile(id.raw()) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.close, null);
    };
    forgetHandle(state, handle);
    return .undefined;
}

fn readBytes(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.read, null, null, "無効なハンドルです");
    };
    var remaining = sizeArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.read, null, null, "読み込む大きさが不正です");
    };
    const allocator = runtime.allocator();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    while (remaining > 0) {
        const chunk_length: usize = @intCast(@min(remaining, read_chunk_bytes));
        const start = output.items.len;
        try output.resize(allocator, start + chunk_length);
        const read = context.readFileBytes(id.raw(), output.items[start..]) catch |failure| {
            return throwIo(runtime, effects, failure, foundation.stream_operations.read, null);
        };
        output.shrinkRetainingCapacity(start + read);
        if (read == 0 or read < chunk_length) break;
        remaining -= read;
    }
    return runtime.createBytes(output.items);
}

fn writeBytes(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    };
    const written = context.writeFileBytes(id.raw(), bytes) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.write, null);
    };
    return publicSizeValue(runtime, written);
}

fn syncFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    context.syncFile(id.raw()) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.fsync, null);
    };
    return .undefined;
}

fn truncateFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    };
    const size = sizeArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    };
    context.truncateFile(id.raw(), size) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.ftruncate, null);
    };
    return .undefined;
}

/// `標準入力バイト読む`。共有sourceから最大SIZEバイトを1回のfillで
/// 返す。0バイトはEOF、SIZE未満の非0は部分読取り。Buffer-kind以外の
/// 値では読まずにEINVAL。
fn stdinRead(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const size = sizeArgument(runtime, common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, "read", null, null, "読み込む大きさが不正です");
    };
    const source = context.stdinSource(runtime.allocator()) catch |failure| {
        return throwIoAs(runtime, effects, failure, "read", null, .raw_stdio);
    };
    // 1呼出しの返却は1fillぶんまで。巨大SIZEの一括確保によるOOMを避けるため
    // fill上限で切り詰める（部分読取りは契約上許容）。
    const length: usize = @intCast(@min(size, low_level_io.stdin_fill_bytes));
    const buffer = try runtime.allocator().alloc(u8, length);
    defer runtime.allocator().free(buffer);
    const read = source.read(buffer) catch |failure| {
        return throwIoAs(runtime, effects, failure, "read", null, .raw_stdio);
    };
    return runtime.createBytes(buffer[0..read]);
}

fn stdoutWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    return rawWrite(runtime, context, effects, arguments, false);
}

fn stderrWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    return rawWrite(runtime, context, effects, arguments, true);
}

/// `標準出力バイト書く`/`標準エラー出力バイト書く`。Bytes値をUTF-8変換や
/// NUL終端を挟まずfdへ直接書き、実際に書けたバイト数を返す。
fn rawWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value, to_stderr: bool) !Value {
    const bytes = bytesArgument(runtime, common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, "write", null, null, "書き込む値はBytesである必要があります");
    };
    const written = (if (to_stderr) context.writeStderrBytes(bytes) else context.writeStdoutBytes(bytes)) catch |failure| {
        return throwIoAs(runtime, effects, failure, "write", null, .raw_stdio);
    };
    return publicSizeValue(runtime, written);
}

fn stdoutSync(runtime: *Runtime, context: Context, effects: Effects) !Value {
    context.syncStdout() catch |failure| {
        return throwIoAs(runtime, effects, failure, "fsync", null, .raw_stdio);
    };
    return .undefined;
}

fn stderrSync(runtime: *Runtime, context: Context, effects: Effects) !Value {
    context.syncStderr() catch |failure| {
        return throwIoAs(runtime, effects, failure, "fsync", null, .raw_stdio);
    };
    return .undefined;
}

pub fn lookupHandle(state: *State, value: Value) ?foundation.HandleId {
    if (value != .dictionary) return null;
    return state.handle_ids.get(@intFromPtr(value.dictionary));
}

pub fn handleForId(state: *State, id: foundation.HandleId) ?Value {
    return state.handle_by_id.get(id.raw());
}

pub fn rememberHandle(state: *State, allocator: std.mem.Allocator, value: Value, id: foundation.HandleId) !void {
    if (value != .dictionary) return error.InvalidHandle;
    const memory = state.memory(allocator);
    try state.handle_ids.put(memory, @intFromPtr(value.dictionary), id);
    errdefer _ = state.handle_ids.remove(@intFromPtr(value.dictionary));
    try state.handle_by_id.put(memory, id.raw(), value);
    errdefer _ = state.handle_by_id.remove(id.raw());
    try state.handle_values.append(memory, value);
}

fn forgetHandle(state: *State, value: Value) void {
    if (lookupHandle(state, value)) |id| forgetHandleId(state, id);
}

pub fn forgetHandleId(state: *State, id: foundation.HandleId) void {
    _ = state.handle_by_id.remove(id.raw());
    var index: usize = 0;
    while (index < state.handle_values.items.len) {
        const candidate = state.handle_values.items[index];
        if (candidate == .dictionary) {
            if (state.handle_ids.get(@intFromPtr(candidate.dictionary))) |mapped| {
                if (mapped.index == id.index and mapped.generation == id.generation) {
                    _ = state.handle_ids.remove(@intFromPtr(candidate.dictionary));
                    _ = state.handle_values.swapRemove(index);
                    continue;
                }
            }
        }
        index += 1;
    }
}

fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value) {
        .number => |number| foundation.sizeFromNumber(number),
        .bigint => |bigint| foundation.sizeFromUnsigned(bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

fn bytesArgument(runtime: *Runtime, value: Value) ![]const u8 {
    if (value != .bytes) return error.InvalidBytes;
    if (value.bytes.kind != .buffer) return error.InvalidBytes;
    _ = runtime;
    return value.bytes.bytes;
}

fn publicSizeValue(runtime: *Runtime, size: u64) !Value {
    return switch (foundation.publicSize(size)) {
        .number => .{ .number = @floatFromInt(size) },
        .bigint => runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), size)),
    };
}

fn buildError(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) !Value {
    var dictionary = try runtime.createDictionaryKind(.structured_error);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.code, try runtime.stringUtf8(code.name()));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.native_code, .null_value);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.operation, try runtime.stringUtf8(operation));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path, if (path) |value| try runtime.stringUtf8(value) else .null_value);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path2, .null_value);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.message, try runtime.stringUtf8(message));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.capability, if (capability) |value| try runtime.stringUtf8(value) else .null_value);
    return dictionary;
}

fn throwIo(runtime: *Runtime, effects: Effects, failure: anyerror, operation: []const u8, path: ?[]const u8) anyerror {
    return throwIoAs(runtime, effects, failure, operation, path, if (std.mem.eql(u8, operation, foundation.stream_operations.ftruncate)) .truncate else .stream_file_io);
}

/// ENOTSUPのときだけ `capability` をエラー辞書へ載せるI/O失敗。
/// `throwIo` のcapability判定をパラメータ化したもの。
fn throwIoAs(runtime: *Runtime, effects: Effects, failure: anyerror, operation: []const u8, path: ?[]const u8, capability: foundation.Capability) anyerror {
    const code = foundation.portableCodeForFailure(failure) orelse .EINVAL;
    return throwStructured(runtime, effects, code, operation, path, if (code == .ENOTSUP) capability.id() else null, failureMessage(failure));
}

fn throwStructured(
    runtime: *Runtime,
    effects: Effects,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    var dictionary = buildError(runtime, code, operation, path, capability, message) catch |failure| return failure;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    roots.protect(&dictionary) catch |failure| return failure;
    runtime.setFailureMessage(message) catch |failure| return failure;
    effects.throw(dictionary) catch |failure| return failure;
    return error.NakoException;
}

fn failureMessage(failure: anyerror) []const u8 {
    return switch (failure) {
        error.FileNotFound => "ファイルが見つかりません",
        error.AccessDenied, error.PermissionDenied => "アクセスが拒否されました",
        error.IsDir => "ディレクトリです",
        error.NotDir => "ディレクトリではありません",
        error.PathAlreadyExists => "既に存在します",
        error.ReadOnlyFileSystem => "読み取り専用ファイルシステムです",
        error.NoSpaceLeft => "空き容量がありません",
        error.BrokenPipe => "パイプが切断されました",
        error.NotOpenForReading, error.NotOpenForWriting, error.BadFileDescriptor => "無効なハンドルです",
        error.LowLevelIoUnavailable => "低レイヤーI/Oは利用できません",
        error.DiskQuota, error.FileTooBig => "空き容量がありません",
        error.ProcessFdQuotaExceeded => "プロセスで開けるファイル数の上限に達しました",
        error.SystemFdQuotaExceeded => "システムで開けるファイル数の上限に達しました",
        error.SymLinkLoop => "シンボリックリンクがループしています",
        error.StreamTooLong => "標準入力が上限を超えました",
        else => @errorName(failure),
    };
}

test "Stateはhandle値の同一性だけを対応表へ載せる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);

    var first = try runtime.createDictionary();
    var second = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&first);
    try roots.protect(&second);
    try state.handle_ids.put(state.memory(std.testing.allocator), @intFromPtr(first.dictionary), .{ .index = 1, .generation = 1 });
    try state.handle_values.append(state.memory(std.testing.allocator), first);

    try std.testing.expect(lookupHandle(&state, first) != null);
    try std.testing.expect(lookupHandle(&state, second) == null);
    try std.testing.expect(lookupHandle(&state, .{ .number = 1 }) == null);

    forgetHandle(&state, first);
    try std.testing.expect(lookupHandle(&state, first) == null);
    try std.testing.expectEqual(@as(usize, 0), state.handle_values.items.len);
}

test "sizeArgumentは安全整数とBigIntの大きさだけを受け付ける" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, 0), try sizeArgument(&runtime, .{ .number = 0 }));
    try std.testing.expectEqual(@as(u64, 1024), try sizeArgument(&runtime, .{ .number = 1024 }));
    try std.testing.expectError(error.InvalidSize, sizeArgument(&runtime, .{ .number = -1 }));
    try std.testing.expectError(error.InvalidSize, sizeArgument(&runtime, .{ .number = 1.5 }));
    try std.testing.expectError(error.InvalidSize, sizeArgument(&runtime, .{ .string = undefined }));
    const big_value = try runtime.ownBigInt(try value_mod.BigInt.init(std.testing.allocator, @as(u64, 9007199254740993)));
    try std.testing.expectEqual(@as(u64, 9007199254740993), try sizeArgument(&runtime, big_value));
}

test "bytesArgumentはBuffer kindのBytesだけを受け付ける" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var bytes = try runtime.createBytes("abc");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&bytes);
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(&runtime, bytes));
    var uint8_array = try runtime.createUint8Array("abc");
    try roots.protect(&uint8_array);
    try std.testing.expectError(error.InvalidBytes, bytesArgument(&runtime, uint8_array));
    try std.testing.expectError(error.InvalidBytes, bytesArgument(&runtime, .{ .number = 1 }));
}

test "Stateは最初に使ったallocatorで解放する" {
    var state = State{};
    try state.handle_ids.put(state.memory(std.testing.allocator), 1, .{ .index = 1, .generation = 1 });
    try state.handle_values.append(state.memory(std.testing.allocator), .undefined);
    state.deinit(std.heap.page_allocator);
}

/// Issue #28 raw stdioの検証用host。stdinは事前充填した共有sourceを返し、
/// stdout/stderr書込みとsync呼出しを記録する。`write_limit` で部分書込み、
/// `write_failure`/`sync_failure` で構造化エラーを再現する。
const StdioTestHost = struct {
    preloaded: []const u8 = "",
    /// feederモード用: 設定時はinitPreloadedではなく下位reader経由で
    /// 履歴を足すsourceを作る（履歴上限超過の試験に必要）。
    feed_chunks: ?[]const u8 = null,
    feed_offset: usize = 0,
    max_history: ?usize = null,
    source: ?low_level_io.StdinSource = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_syncs: usize = 0,
    stderr_syncs: usize = 0,
    write_limit: usize = std.math.maxInt(usize),
    write_failure: ?anyerror = null,
    sync_failure: ?anyerror = null,

    fn deinit(self: *StdioTestHost, allocator: std.mem.Allocator) void {
        if (self.source) |*source| source.deinit();
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
    }

    fn peek(pointer: *anyopaque) ?*low_level_io.StdinSource {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return if (self.source) |*source| source else null;
    }

    fn feedRead(pointer: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        const remaining = self.feed_chunks.?[self.feed_offset..];
        const count = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..count], remaining[0..count]);
        self.feed_offset += count;
        return count;
    }

    fn stdinSource(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.source == null) {
            if (self.feed_chunks != null) {
                self.source = low_level_io.StdinSource.init(allocator, self, feedRead);
                if (self.max_history) |max| self.source.?.max_history_bytes = max;
            } else {
                self.source = try low_level_io.StdinSource.initPreloaded(allocator, self.preloaded);
            }
        }
        return &self.source.?;
    }

    fn writeInto(list: *std.ArrayList(u8), self: *StdioTestHost, bytes: []const u8) anyerror!usize {
        if (self.write_failure) |failure| return failure;
        const count = @min(bytes.len, self.write_limit);
        try list.appendSlice(std.testing.allocator, bytes[0..count]);
        return count;
    }

    fn writeStdout(pointer: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return writeInto(&self.stdout, self, bytes);
    }

    fn writeStderr(pointer: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return writeInto(&self.stderr, self, bytes);
    }

    fn syncStdout(pointer: *anyopaque) anyerror!void {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.sync_failure) |failure| return failure;
        self.stdout_syncs += 1;
    }

    fn syncStderr(pointer: *anyopaque) anyerror!void {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.sync_failure) |failure| return failure;
        self.stderr_syncs += 1;
    }

    fn context(self: *StdioTestHost) Context {
        return .{
            .context = @ptrCast(self),
            .peekStdinSourceFn = peek,
            .stdinSourceFn = stdinSource,
            .writeStdoutBytesFn = writeStdout,
            .writeStderrBytesFn = writeStderr,
            .syncStdoutFn = syncStdout,
            .syncStderrFn = syncStderr,
        };
    }
};

fn expectThrownCode(runtime: *Runtime, thrown: Value, expected: []const u8) !void {
    try std.testing.expect(thrown == .dictionary);
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "標準入力バイト読むはNULと不正UTF-8を保持しEOFで空Bytesを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "\x00\xff\x80a" ++ "\n" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var first = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 5 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&first);
    try std.testing.expectEqualSlices(u8, "\x00\xff\x80a\n", try bytesArgument(&runtime, first));
    var second = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 5 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&second);
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(&runtime, second)).len);
}

test "標準入力バイト読むは要求未満の部分読取りを返しsize不正をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "abc" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var result = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 16 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(&runtime, result));

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = -1 }}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "標準入力バイト読むは履歴上限超過をENOSPCの構造化エラーにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    // fillが1回に6バイト足し、上限4を超えてStreamTooLong→ENOSPCになる。
    var host = StdioTestHost{ .feed_chunks = "012345", .max_history = 4 };
    defer host.deinit(std.testing.allocator);

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 8 }}));
    try expectThrownCode(&runtime, thrown, "ENOSPC");
}

test "標準出力/標準エラー出力バイト書くはrawバイトを分けて書き実書込数を返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{};
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var out_bytes = try runtime.createBytes("\x00\xffout");
    var err_bytes = try runtime.createBytes("e\x80rr");
    try roots.protect(&out_bytes);
    try roots.protect(&err_bytes);
    const out_written = (try call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{out_bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), out_written.number);
    const err_written = (try call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{err_bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 4), err_written.number);
    try std.testing.expectEqualSlices(u8, "\x00\xffout", host.stdout.items);
    try std.testing.expectEqualSlices(u8, "e\x80rr", host.stderr.items);
}

test "標準出力バイト書くは部分書込み数を返し非BytesをEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .write_limit = 2 };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var bytes = try runtime.createBytes("abcd");
    try roots.protect(&bytes);
    const written = (try call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 2), written.number);
    try std.testing.expectEqualSlices(u8, "ab", host.stdout.items);

    var text = try runtime.stringUtf8("not-bytes");
    try roots.protect(&text);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{text}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    var uint8 = try runtime.createUint8Array("ab");
    try roots.protect(&uint8);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{uint8}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "raw stdioのI/O失敗は構造化codeを持ちhost不在はENOTSUP+raw_stdio" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var host = StdioTestHost{ .write_failure = error.BrokenPipe };
    defer host.deinit(std.testing.allocator);
    var bytes = try runtime.createBytes("x");
    try roots.protect(&bytes);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{bytes}));
    try expectThrownCode(&runtime, thrown, "EPIPE");
    thrown = .undefined;
    host.write_failure = error.NoSpaceLeft;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{bytes}));
    try expectThrownCode(&runtime, thrown, "ENOSPC");
    thrown = .undefined;
    host.write_failure = null;
    host.sync_failure = error.BrokenPipe;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力同期", &.{}));
    try expectThrownCode(&runtime, thrown, "EPIPE");
    thrown = .undefined;
    host.sync_failure = null;
    _ = try call(&runtime, &state, host.context(), effects, "標準出力同期", &.{});
    _ = try call(&runtime, &state, host.context(), effects, "標準エラー出力同期", &.{});
    try std.testing.expectEqual(@as(usize, 1), host.stdout_syncs);
    try std.testing.expectEqual(@as(usize, 1), host.stderr_syncs);

    // hostがstdio callbackを提供しない場合はENOTSUPにcapabilityを載せる。
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "標準入力バイト読む", &.{.{ .number = 1 }}));
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    const capability = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.capability) orelse return error.TestExpectedEqual;
    const capability_text = try shared.valueUtf8(&runtime, capability);
    defer runtime.allocator().free(capability_text);
    try std.testing.expectEqualStrings("raw_stdio", capability_text);
}

test "raw stdioを提供するhostでは低レイヤー機能対応判定がtrue" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{};
    defer host.deinit(std.testing.allocator);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name = try runtime.stringUtf8("raw_stdio");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, host.context(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);
    const unsupported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(unsupported == .boolean and !unsupported.boolean);
}

test "標準入力バイト読むとテキスト系readLineは同じconsumedカーソルを消費する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "ab\ncd\n" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    // raw読取りで先頭3バイト("ab\n")を消費すると、テキスト系readLineは
    // 残りから行を返す。逆方向も同じcursorを共有する。
    var chunk = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 3 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&chunk);
    try std.testing.expectEqualSlices(u8, "ab\n", try bytesArgument(&runtime, chunk));
    const source = if (host.source) |*existing| existing else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), source.consumed);
    try std.testing.expectEqualStrings("cd", (try source.readLine()).?);
    var rest = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 8 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&rest);
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(&runtime, rest)).len);
}

fn captureThrow(context: *anyopaque, value: Value) !void {
    const captured: *Value = @ptrCast(@alignCast(context));
    captured.* = value;
}

test "openは非文字列のpathとmodeをEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル開", &.{.{ .number = 1 }}));
    try std.testing.expect(thrown == .dictionary);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&thrown);
    const path_code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const path_text = try shared.valueUtf8(&runtime, path_code);
    defer runtime.allocator().free(path_text);
    try std.testing.expectEqualStrings("EINVAL", path_text);

    var path = try runtime.stringUtf8("missing.txt");
    try roots.protect(&path);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル開", &.{ path, .{ .number = 1 } }));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const mode_code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const mode_text = try shared.valueUtf8(&runtime, mode_code);
    defer runtime.allocator().free(mode_text);
    try std.testing.expectEqualStrings("EINVAL", mode_text);
}

test "throwStructuredはGC stress下でもエラー辞書を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{.{ .number = 1 }}));
    try std.testing.expect(thrown == .dictionary);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&thrown);
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EBADF", text);
}

const ShortReadHost = struct {
    calls: usize = 0,

    fn read(pointer: *anyopaque, raw: u64, buffer: []u8) anyerror!usize {
        const self: *ShortReadHost = @ptrCast(@alignCast(pointer));
        _ = raw;
        self.calls += 1;
        if (self.calls > 1) return error.WouldBlock;
        const n = @min(buffer.len, 3);
        @memcpy(buffer[0..n], "abc"[0..n]);
        return n;
    }
};

test "部分読込は要求chunk未満で打ち切る" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(&state, runtime.allocator(), handle, .{ .index = 1, .generation = 1 });
    var host = ShortReadHost{};
    const context = Context{ .context = @ptrCast(&host), .readFileBytesFn = ShortReadHost.read };
    var result = (try call(&runtime, &state, context, effects, "ファイルバイト読", &.{ handle, .{ .number = 65536 } })) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(&runtime, result));
}

test "未実装命令はdispatch名と利用者名の両形で構造化ENOTSUPを投げる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var arguments = [_]Value{.undefined} ** 4;
    var covered: usize = 0;
    for (foundation.catalog_commands) |spec| {
        if (spec.implemented) continue;
        covered += 1;
        for ([2][]const u8{ spec.name, spec.user_name orelse spec.name }) |name| {
            thrown = .undefined;
            try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, name, arguments[0..spec.min]));
            try std.testing.expect(thrown == .dictionary);
            try roots.protect(&thrown);
            try std.testing.expectEqual(value_mod.DictionaryKind.structured_error, thrown.dictionary.kind);
            const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
            const code_text = try shared.valueUtf8(&runtime, code);
            defer runtime.allocator().free(code_text);
            try std.testing.expectEqualStrings("ENOTSUP", code_text);
            const operation = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.operation) orelse return error.TestExpectedEqual;
            const operation_text = try shared.valueUtf8(&runtime, operation);
            defer runtime.allocator().free(operation_text);
            try std.testing.expectEqualStrings(spec.operation, operation_text);
            if (spec.capability) |capability| {
                const field = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.capability) orelse return error.TestExpectedEqual;
                const field_text = try shared.valueUtf8(&runtime, field);
                defer runtime.allocator().free(field_text);
                try std.testing.expectEqualStrings(capability.id(), field_text);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 48), covered);
}

test "実装済み命令の引数不足はEINVALで未知capability照会はfalse" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{}));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EINVAL", text);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{}));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const close_code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const close_text = try shared.valueUtf8(&runtime, close_code);
    defer runtime.allocator().free(close_text);
    try std.testing.expectEqualStrings("EINVAL", close_text);

    // 未知capability名の照会は引数数エラーではなくfalseを返す。
    var name = try runtime.stringUtf8("unknown_capability");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);
}

test "余分な引数はEINVALで、openだけのホストはstream_file_io非対応" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(&state, runtime.allocator(), handle, .{ .index = 1, .generation = 1 });
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル閉", &.{ handle, .{ .number = 1 } }));
    try roots.protect(&thrown);
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(&runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings("EINVAL", text);

    var name = try runtime.stringUtf8("stream_file_io");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);

    var truncate_name = try runtime.stringUtf8("truncate");
    try roots.protect(&truncate_name);
    const truncate_full = Context{
        .context = @ptrCast(&unused_context_host),
        .truncateFileFn = struct {
            fn dummy(_: *anyopaque, _: u64, _: u64) anyerror!void {
                return;
            }
        }.dummy,
    };
    const truncate_supported = (try call(&runtime, &state, truncate_full, effects, foundation.capability_supported_command, &.{truncate_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(truncate_supported == .boolean and truncate_supported.boolean);
}
