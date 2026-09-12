const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");
const foundation = @import("../low_level_foundation.zig");
const low_level_io = @import("../low_level_io.zig");
const plugin_lowlevel = @import("../../plugins/lowlevel.zig");

const aot_builtin = shared.aot_builtin;
const BigInt = shared.BigInt;

const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const numberValue = state.numberValue;
const valueToNumber = state.valueToNumber;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
const runtimeUtf8String = state.runtimeUtf8String;
const aotRuntimeIo = state.aotRuntimeIo;
const staticUtf8 = state.staticUtf8;
const isString = state.isString;

const read_chunk_bytes: usize = 64 * 1024;

fn io(runtime: *Runtime) std.Io {
    return aotRuntimeIo(runtime);
}

fn table(runtime: *Runtime) *low_level_io.FileHandleTable {
    if (runtime.low_level_handles == null) {
        runtime.low_level_handles = low_level_io.FileHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_handles.?;
}

pub fn pluginContext(runtime: *Runtime) plugin_lowlevel.Context {
    return .{
        .context = runtime,
        .openFileFn = pluginOpenFile,
        .closeFileFn = pluginCloseFile,
        .readFileBytesFn = pluginReadFileBytes,
        .writeFileBytesFn = pluginWriteFileBytes,
        .syncFileFn = pluginSyncFile,
        .truncateFileFn = pluginTruncateFile,
    };
}

fn pluginOpenFile(context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return (try table(runtime).open(io(runtime), .{ .path = path, .mode = mode, .exclusive = exclusive, .sync = sync })).raw();
}

fn pluginCloseFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    const removed = table(runtime).remove(id) orelse return error.BadFileDescriptor;
    removed.file.close(io(runtime));
}

fn pluginReadFileBytes(context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.readAtCurrent(io(runtime), entry.file, buffer);
}

fn pluginWriteFileBytes(context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.writeHandle(io(runtime), entry, bytes);
}

fn pluginSyncFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.sync(io(runtime), entry.file);
}

fn pluginTruncateFile(context: *anyopaque, raw: u64, size: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.setLength(io(runtime), entry.file, size);
}

pub fn handleIdFor(runtime: *Runtime, value: Value) ?foundation.HandleId {
    return findHandleId(runtime, value);
}

pub fn rememberHandle(runtime: *Runtime, value: Value, id: foundation.HandleId) !void {
    const object = value.object() orelse return error.InvalidHandle;
    try runtime.low_level_handle_ids.put(runtime.allocator, @intFromPtr(object), id.raw());
}

/// ハンドル値（AOT辞書）の同一性から `HandleId` を探す。偽造辞書や
/// close済みハンドルは `null` になる。
fn findHandleId(runtime: *Runtime, value: Value) ?foundation.HandleId {
    const object = value.object() orelse return null;
    const raw = runtime.low_level_handle_ids.get(@intFromPtr(object)) orelse return null;
    return foundation.HandleId.fromRaw(raw);
}

fn forgetHandle(runtime: *Runtime, value: Value) void {
    const object = value.object() orelse return;
    _ = runtime.low_level_handle_ids.remove(@intFromPtr(object));
}

fn fileFor(runtime: *Runtime, value: Value) ?*low_level_io.OpenHandle {
    const id = findHandleId(runtime, value) orelse return null;
    return table(runtime).find(id);
}

fn openBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    if (!isString(arguments[0])) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, null, null, "pathは文字列である必要があります");
    }
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    var mode_owned: ?[]u8 = null;
    defer if (mode_owned) |owned| runtime.allocator.free(owned);
    if (arguments.len > 1 and arguments[1].tag != @intFromEnum(Tag.undefined)) {
        if (!isString(arguments[1])) {
            return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, path, null, "modeは文字列である必要があります");
        }
        mode_owned = try valueUtf8LossyAlloc(runtime, arguments[1]);
    }
    const parsed = foundation.parseOpenMode(mode_owned orelse "r") catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, path, null, "開くmodeが不正です");
    };
    const id = table(runtime).open(io(runtime), .{
        .path = path,
        .mode = parsed.mode,
        .exclusive = parsed.exclusive,
        .sync = parsed.sync,
    }) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.open, path);
    };
    errdefer {
        if (table(runtime).remove(id)) |removed| removed.file.close(io(runtime));
    }
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    const key = @intFromPtr(handle.object().?);
    try runtime.low_level_handle_ids.put(runtime.allocator, key, id.raw());
    return handle;
}

fn closeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    const removed = table(runtime).remove(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    removed.file.close(io(runtime));
    forgetHandle(runtime, arguments[0]);
    return .{};
}

fn readBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.read, null, null, "無効なハンドルです");
    };
    var remaining = sizeArgument(runtime, if (arguments.len > 1) arguments[1] else .{}) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.read, null, null, "読み込む大きさが不正です");
    };
    const allocator = runtime.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    while (remaining > 0) {
        const chunk_length: usize = @intCast(@min(remaining, read_chunk_bytes));
        const start = output.items.len;
        try output.resize(allocator, start + chunk_length);
        const read = low_level_io.readAtCurrent(io(runtime), entry.file, output.items[start..]) catch |failure| {
            return throwIo(runtime, failure, foundation.stream_operations.read, null);
        };
        output.shrinkRetainingCapacity(start + read);
        if (read == 0) break;
        remaining -= read;
    }
    return runtime.createBytes(output.items);
}

fn writeBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    };
    const written = low_level_io.writeHandle(io(runtime), entry, bytes) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.write, null);
    };
    return publicSizeValue(runtime, written);
}

fn syncBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    low_level_io.sync(io(runtime), entry.file) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.fsync, null);
    };
    return .{};
}

fn truncateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    };
    const size = sizeArgument(runtime, arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    };
    low_level_io.setLength(io(runtime), entry.file, size) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.ftruncate, null);
    };
    return .{};
}

pub fn lowLevelFileBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    return switch (command) {
        .low_level_file_open => openBuiltin(runtime, arguments),
        .low_level_file_close => closeBuiltin(runtime, arguments),
        .low_level_file_read_bytes => readBytesBuiltin(runtime, arguments),
        .low_level_file_write_bytes => writeBytesBuiltin(runtime, arguments),
        .low_level_file_sync => syncBuiltin(runtime, arguments),
        .low_level_file_truncate => truncateBuiltin(runtime, arguments),
        else => error.UnknownCommand,
    };
}

pub fn lowLevelCapabilitySupportedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    _ = runtime;
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const supported = capabilitySupported(arguments[0]);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(supported) };
}

pub fn lowLevelCapabilityListBuiltin(runtime: *Runtime) !Value {
    const result = try runtime.createArray(&.{});
    var rooted = [_]Value{ result, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    inline for (std.meta.tags(foundation.Capability)) |capability| {
        rooted[1] = try runtimeUtf8String(runtime, capability.id());
        try rooted[0].object().?.payload.array.append(runtime.allocator, rooted[1]);
    }
    return rooted[0];
}

fn capabilitySupported(value: Value) bool {
    var buffer: [64]u8 = undefined;
    const text: []const u8 = switch (value.tag) {
        @intFromEnum(Tag.static_utf8_string) => staticUtf8(value),
        @intFromEnum(Tag.utf16_string) => blk: {
            const units = value.object().?.payload.utf16_string;
            if (units.len > buffer.len) return false;
            for (units, 0..) |unit, index| {
                if (unit > 0x7f) return false;
                buffer[index] = @intCast(unit);
            }
            break :blk buffer[0..units.len];
        },
        else => return false,
    };
    if (text.len > buffer.len) return false;
    const capability = foundation.Capability.fromId(text) orelse return false;
    return foundation.capabilityImplemented(capability);
}

fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value.tag) {
        @intFromEnum(Tag.number) => foundation.sizeFromNumber(valueToNumber(value)),
        @intFromEnum(Tag.bigint) => foundation.sizeFromUnsigned(value.object().?.payload.bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

fn bytesArgument(value: Value) ![]const u8 {
    if (value.tag != @intFromEnum(Tag.byte_buffer)) return error.InvalidBytes;
    const buffer = value.object().?.payload.byte_buffer;
    if (buffer.kind != .buffer) return error.InvalidBytes;
    return buffer.bytes;
}

fn publicSizeValue(runtime: *Runtime, size: u64) !Value {
    return switch (foundation.publicSize(size)) {
        .number => numberValue(@floatFromInt(size)),
        .bigint => runtime.ownBigInt(try BigInt.init(runtime.allocator, size)),
    };
}

fn setField(runtime: *Runtime, dictionary: Value, name: []const u8, value: Value) !void {
    var rooted = [_]Value{ dictionary, value, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[2] = try runtimeUtf8String(runtime, name);
    try runtime.setDictionary(&rooted[0].object().?.payload.dictionary, rooted[2], rooted[1]);
}

fn buildError(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) !Value {
    var result = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&result), 1);
    defer runtime.popRoots(&roots);
    try setField(runtime, result, foundation.error_object_keys.code, try runtimeUtf8String(runtime, code.name()));
    try setField(runtime, result, foundation.error_object_keys.native_code, .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.operation, try runtimeUtf8String(runtime, operation));
    try setField(runtime, result, foundation.error_object_keys.path, if (path) |value| try runtimeUtf8String(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.path2, .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.message, try runtimeUtf8String(runtime, message));
    try setField(runtime, result, foundation.error_object_keys.capability, if (capability) |value| try runtimeUtf8String(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    return result;
}

fn throwIo(runtime: *Runtime, failure: anyerror, operation: []const u8, path: ?[]const u8) anyerror {
    const code = foundation.portableCodeForFailure(failure) orelse .EINVAL;
    const capability = if (code == .ENOTSUP) foundation.Capability.stream_file_io.id() else null;
    return throwStructured(runtime, code, operation, path, capability, failureMessage(failure));
}

fn throwStructured(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    const dictionary = buildError(runtime, code, operation, path, capability, message) catch |failure| return failure;
    runtime.setException(dictionary);
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

test "AOT低レイヤーはバッファkindのBytesだけを書込みに受け付ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes("abc");
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(roots[0]));
    roots[1] = try runtime.createUint8Array("abc");
    try std.testing.expectError(error.InvalidBytes, bytesArgument(roots[1]));
}

test "AOT低レイヤーはread/write/truncate/closeをハンドル同一性で扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aot-low-level.txt" });
    defer std.testing.allocator.free(path);

    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, path);
    roots[3] = try runtimeUtf8String(&runtime, "w");
    const handle = try openBuiltin(&runtime, &.{ roots[0], roots[3] });
    try std.testing.expectEqual(@as(u32, 1), runtime.low_level_handle_ids.size);

    roots[1] = try runtime.createBytes("abcd");
    const written = try writeBytesBuiltin(&runtime, &.{ handle, roots[1] });
    try std.testing.expectEqual(@as(u64, 4), try sizeArgument(&runtime, written));

    _ = try truncateBuiltin(&runtime, &.{ handle, written });

    roots[2] = try runtime.createBytes("xy");
    _ = try writeBytesBuiltin(&runtime, &.{ handle, roots[2] });
    _ = try closeBuiltin(&runtime, &.{handle});
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
    try std.testing.expect(runtime.low_level_handles.?.len() == 0);
    try std.testing.expectError(error.NakoException, closeBuiltin(&runtime, &.{handle}));
    try std.testing.expectError(error.NakoException, writeBytesBuiltin(&runtime, &.{ handle, roots[1] }));
}

test "AOT低レイヤーは非文字列のpathとmodeをEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{numberValue(1)}));
    var roots = [_]Value{ try runtimeUtf8String(&runtime, "missing.txt"), numberValue(1) };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &roots));
}

test "AOT低レイヤーのappendは切詰め後も末尾へ書く" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aot-append.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "aot-append.txt", .data = "abcdef" });

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, path);
    roots[1] = try runtimeUtf8String(&runtime, "a");
    const handle = try openBuiltin(&runtime, &.{ roots[0], roots[1] });
    _ = try truncateBuiltin(&runtime, &.{ handle, numberValue(2) });
    roots[2] = try runtime.createBytes("xy");
    _ = try writeBytesBuiltin(&runtime, &.{ handle, roots[2] });
    _ = try closeBuiltin(&runtime, &.{handle});

    const output = try temporary.dir.readFileAlloc(std.testing.io, "aot-append.txt", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "abxy", output);
}

test "AOT pluginContextはRuntimeのハンドル表へ開く" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "plugin-context.txt" });
    defer std.testing.allocator.free(path);

    const context = pluginContext(&runtime);
    const raw = try context.openFile(path, .write_create_truncate, false, false);
    try std.testing.expectEqual(@as(usize, 2), try context.writeFileBytes(raw, "ok"));
    try context.closeFile(raw);
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_handles.?.len());

    const output = try temporary.dir.readFileAlloc(std.testing.io, "plugin-context.txt", std.testing.allocator, .limited(8));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "ok", output);
}
