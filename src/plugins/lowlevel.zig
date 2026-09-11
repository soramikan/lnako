const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const foundation = @import("../runtime/low_level_foundation.zig");
const common = @import("system/common.zig");
const shared = @import("node/shared.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const Dictionary = value_mod.Dictionary;

/// Interpreterが保持する低レイヤー命令の状態。Handle値は不透明オブジェクト
/// （辞書）であり、その同一性だけをhandle tableの `HandleId` へ結びつける。
/// 同じ形の辞書を手作りしてもこの対応表に載らないため無効になる。
pub const State = struct {
    handle_ids: std.AutoHashMapUnmanaged(usize, foundation.HandleId) = .empty,
    handle_values: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.handle_ids.deinit(allocator);
        self.handle_values.deinit(allocator);
        self.* = undefined;
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
    openFileFn: ?*const fn (context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool) anyerror!u64 = null,
    closeFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    readFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize = null,
    writeFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize = null,
    syncFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    truncateFileFn: ?*const fn (context: *anyopaque, raw: u64, size: u64) anyerror!void = null,

    pub fn openFile(self: Context, path: []const u8, mode: foundation.OpenMode, exclusive: bool) !u64 {
        const function = self.openFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, mode, exclusive);
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
        .stream_file_io => context.openFileFn != null,
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
    const path = try shared.valueUtf8(runtime, common.argument(arguments, 0));
    defer runtime.allocator().free(path);
    const mode_value = common.argument(arguments, 1);
    var mode_text: ?[]u8 = null;
    defer if (mode_text) |text| runtime.allocator().free(text);
    if (mode_value != .undefined) mode_text = try shared.valueUtf8(runtime, mode_value);
    const parsed = foundation.parseOpenMode(mode_text orelse "r") catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.stream_operations.open, path, null, "開くmodeが不正です");
    };
    const raw = context.openFile(path, parsed.mode, parsed.exclusive) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.open, path);
    };
    errdefer context.closeFile(raw) catch {};
    const id = foundation.HandleId.fromRaw(raw);
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try state.handle_ids.put(runtime.allocator(), @intFromPtr(handle.dictionary), id);
    errdefer _ = state.handle_ids.remove(@intFromPtr(handle.dictionary));
    try state.handle_values.append(runtime.allocator(), handle);
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
        if (read == 0) break;
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

fn lookupHandle(state: *State, value: Value) ?foundation.HandleId {
    if (value != .dictionary) return null;
    return state.handle_ids.get(@intFromPtr(value.dictionary));
}

fn forgetHandle(state: *State, value: Value) void {
    _ = state.handle_ids.remove(@intFromPtr(value.dictionary));
    for (state.handle_values.items, 0..) |candidate, index| {
        if (candidate == .dictionary and candidate.dictionary == value.dictionary) {
            _ = state.handle_values.swapRemove(index);
            break;
        }
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
    var dictionary = try runtime.createDictionary();
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
    const code = foundation.portableCodeForFailure(failure) orelse .EINVAL;
    const capability = if (code == .ENOTSUP) foundation.Capability.stream_file_io.id() else null;
    return throwStructured(runtime, effects, code, operation, path, capability, failureMessage(failure));
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
    const dictionary = buildError(runtime, code, operation, path, capability, message) catch |failure| return failure;
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
    try state.handle_ids.put(std.testing.allocator, @intFromPtr(first.dictionary), .{ .index = 1, .generation = 1 });
    try state.handle_values.append(std.testing.allocator, first);

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
