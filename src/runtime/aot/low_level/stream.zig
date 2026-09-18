const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const shared = @import("shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_io = @import("../../low_level_io.zig");
const low_level_hash = @import("../../low_level_hash.zig");
const low_level_fs = @import("../../low_level_fs.zig");

const aot_builtin = shared.aot_builtin;
const BigInt = shared.BigInt;
const Runtime = shared.Runtime;
const Value = shared.Value;
const Object = shared.Object;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const numberValue = shared.numberValue;
const valueToNumber = shared.valueToNumber;
const valueUtf8LossyAlloc = shared.valueUtf8LossyAlloc;
const valueUtf16Alloc = shared.valueUtf16Alloc;
const runtimeUtf8String = shared.runtimeUtf8String;
const runtimeUtf8StringLossy = shared.runtimeUtf8StringLossy;
const aotRuntimeIo = shared.aotRuntimeIo;
const staticUtf8 = shared.staticUtf8;
const isString = shared.isString;
const dictionaryProperty = shared.dictionaryProperty;
const fflush = shared.fflush;
const io = shared.io;
const table = shared.table;
const hashTable = shared.hashTable;
const read_chunk_bytes = shared.read_chunk_bytes;
const handleIdFor = shared.handleIdFor;
const handleValueForId = shared.handleValueForId;
const rememberHandle = shared.rememberHandle;
const forgetHandle = shared.forgetHandle;
const findHandleId = shared.findHandleId;
const forgetHandleId = shared.forgetHandleId;
const fileFor = shared.fileFor;
const pathStringFromBytes = shared.pathStringFromBytes;
const sizeArgument = shared.sizeArgument;
const bytesArgument = shared.bytesArgument;
const publicSizeValue = shared.publicSizeValue;
const setField = shared.setField;
const throwIo = shared.throwIo;
const throwIoAs = shared.throwIoAs;
const throwStructured = shared.throwStructured;
const aotThrownCode = shared.aotThrownCode;
const pendingErrorCode = shared.pendingErrorCode;
const expectPendingCode = shared.expectPendingCode;

const lowLevelFileBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelFileBuiltin else void;
const lowLevelHashBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelHashBuiltin else void;
const lowLevelCapabilitySupportedBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelCapabilitySupportedBuiltin else void;

pub fn pluginOpenFile(context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return (try table(runtime).open(io(runtime), .{ .path = path, .mode = mode, .exclusive = exclusive, .sync = sync })).raw();
}

pub fn pluginCloseFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    const removed = table(runtime).remove(id) orelse return error.BadFileDescriptor;
    removed.file.close(io(runtime));
    forgetHandleId(runtime, id);
}

pub fn pluginReadFileBytes(context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.readAtCurrent(io(runtime), entry.file, buffer);
}

pub fn pluginWriteFileBytes(context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.writeHandle(io(runtime), entry, bytes);
}

pub fn pluginSyncFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.sync(io(runtime), entry.file);
}

pub fn pluginTruncateFile(context: *anyopaque, raw: u64, size: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.setLength(io(runtime), entry.file, size);
}

pub fn openBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1 or !isString(arguments[0])) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, null, null, "pathは文字列である必要があります");
    }
    // 孤立サロゲートを保持する可逆なWTF-8でパスを作る（fs系と同じ規則）。
    const path_units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(path_units);
    const path = try foundation.pathBytesFromUtf16(runtime.allocator, path_units);
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
        return throwIo(runtime, failure, foundation.stream_operations.open, path, null, .stream_file_io);
    };
    errdefer {
        if (table(runtime).remove(id)) |removed| removed.file.close(io(runtime));
    }
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    try rememberHandle(runtime, handle, id);
    return handle;
}

pub fn closeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    const removed = table(runtime).remove(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    removed.file.close(io(runtime));
    forgetHandleId(runtime, id);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
    return .{};
}

pub fn readBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.read, null, null, "無効なハンドルです");
    }
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
            return throwIo(runtime, failure, foundation.stream_operations.read, null, null, .stream_file_io);
        };
        output.shrinkRetainingCapacity(start + read);
        if (read == 0 or read < chunk_length) break;
        remaining -= read;
    }
    return runtime.createBytes(output.items);
}

pub fn writeBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    }
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    };
    const written = low_level_io.writeHandle(io(runtime), entry, bytes) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.write, null, null, .stream_file_io);
    };
    return publicSizeValue(runtime, written);
}

pub fn syncBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    low_level_io.sync(io(runtime), entry.file) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.fsync, null, null, .stream_file_io);
    };
    return .{};
}

pub fn truncateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    }
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    };
    const size = sizeArgument(runtime, arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    };
    low_level_io.setLength(io(runtime), entry.file, size) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.ftruncate, null, null, .truncate);
    };
    return .{};
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

test "AOT低レイヤーは余分な引数をEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, closeBuiltin(&runtime, &.{ numberValue(1), numberValue(2) }));
}

test "AOT低レイヤーの引数なしopenと機能対応判定はEINVAL" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{}));
    // 実装済み命令の引数不足は引数数エラー。未知capabilityの照会falseとは区別する。
    try std.testing.expectError(error.NakoException, lowLevelCapabilitySupportedBuiltin(&runtime, &.{}));
    var roots = [_]Value{try runtimeUtf8String(&runtime, "unknown_capability")};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const supported = try lowLevelCapabilitySupportedBuiltin(&runtime, &roots);
    try std.testing.expectEqual(@as(u64, 0), supported.payload);
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
