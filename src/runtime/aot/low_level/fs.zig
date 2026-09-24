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
const pathArgument = shared.pathArgument;
const sizeArgument = shared.sizeArgument;
const setTimeArgument = shared.setTimeArgument;
const bytesArgument = shared.bytesArgument;
const publicSizeValue = shared.publicSizeValue;
const setField = shared.setField;
const throwIo = shared.throwIo;
const throwIoAs = shared.throwIoAs;
const throwIoMapped = shared.throwIoMapped;
const throwIoMappedPair = shared.throwIoMappedPair;
const unsignedArgument = shared.unsignedArgument;
const throwStructured = shared.throwStructured;
const aotThrownCode = shared.aotThrownCode;
const pendingErrorCode = shared.pendingErrorCode;
const expectPendingCode = shared.expectPendingCode;

const lowLevelFileBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelFileBuiltin else void;
const lowLevelHashBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelHashBuiltin else void;
const lowLevelCapabilitySupportedBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelCapabilitySupportedBuiltin else void;

pub fn pluginStat(context: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.stat(io(runtime), path, follow);
}

pub fn pluginSymlink(context: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.createSymlink(io(runtime), target, link);
}

pub fn pluginReadlink(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.readlink(io(runtime), allocator, path);
}

pub fn pluginHardlink(context: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.createHardLink(io(runtime), target, link);
}

pub fn pluginRealpath(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.realpath(io(runtime), allocator, path);
}

pub fn pluginRename(context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.rename(io(runtime), source, destination);
}

pub fn pluginUnlink(context: *anyopaque, path: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.unlink(io(runtime), path);
}

pub fn pluginRmdir(context: *anyopaque, path: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.rmdir(io(runtime), path);
}

pub fn statBuiltin(runtime: *Runtime, arguments: []const Value, follow: bool) !Value {
    const operation = if (follow) foundation.filesystem_operations.stat else foundation.filesystem_operations.lstat;
    const capability: foundation.Capability = if (follow) .stat else .lstat;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const metadata = low_level_fs.stat(io(runtime), path, follow) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, capability);
    };
    return statValue(runtime, metadata);
}

fn statValue(runtime: *Runtime, metadata: low_level_fs.Metadata) !Value {
    var result = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&result), 1);
    defer runtime.popRoots(&roots);
    try setField(runtime, result, foundation.stat_field_keys.kind, try runtimeUtf8String(runtime, metadata.kind.name()));
    try setField(runtime, result, foundation.stat_field_keys.size, try publicSizeValue(runtime, metadata.size));
    try setField(runtime, result, foundation.stat_field_keys.mode, numberValue(@floatFromInt(metadata.mode)));
    try setField(runtime, result, foundation.stat_field_keys.uid, numberValue(@floatFromInt(metadata.uid)));
    try setField(runtime, result, foundation.stat_field_keys.gid, numberValue(@floatFromInt(metadata.gid)));
    try setField(runtime, result, foundation.stat_field_keys.dev, numberValue(@floatFromInt(metadata.dev)));
    try setField(runtime, result, foundation.stat_field_keys.rdev, numberValue(@floatFromInt(metadata.rdev)));
    try setField(runtime, result, foundation.stat_field_keys.inode, numberValue(@floatFromInt(metadata.inode)));
    try setField(runtime, result, foundation.stat_field_keys.nlink, numberValue(@floatFromInt(metadata.nlink)));
    try setField(runtime, result, foundation.stat_field_keys.block_size, numberValue(@floatFromInt(metadata.block_size)));
    try setField(runtime, result, foundation.stat_field_keys.blocks, numberValue(@floatFromInt(metadata.blocks)));
    try setField(runtime, result, foundation.stat_field_keys.atime_ns, try timeValue(runtime, metadata.atime_ns));
    try setField(runtime, result, foundation.stat_field_keys.mtime_ns, try timeValue(runtime, metadata.mtime_ns));
    try setField(runtime, result, foundation.stat_field_keys.ctime_ns, try timeValue(runtime, metadata.ctime_ns));
    try setField(runtime, result, foundation.stat_field_keys.birthtime_ns, try timeValue(runtime, metadata.birthtime_ns));
    return result;
}

fn timeValue(runtime: *Runtime, nanoseconds: foundation.OptionalTimeNs) !Value {
    const value = nanoseconds orelse return .{ .tag = @intFromEnum(Tag.null_value) };
    return runtime.ownBigInt(try BigInt.init(runtime.allocator, value));
}

pub fn symlinkBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.symlink;
    const target = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(target);
    const link = try pathArgument(runtime, arguments[1], operation);
    defer runtime.allocator.free(link);
    low_level_fs.createSymlink(io(runtime), target, link) catch |failure| {
        return throwIo(runtime, failure, operation, target, link, .symlink);
    };
    return .{};
}

pub fn readlinkBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.readlink;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const destination = low_level_fs.readlink(io(runtime), runtime.allocator, path) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .readlink);
    };
    defer runtime.allocator.free(destination);
    return pathStringFromBytes(runtime, destination);
}

pub fn hardlinkBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.hardlink;
    const target = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(target);
    const link = try pathArgument(runtime, arguments[1], operation);
    defer runtime.allocator.free(link);
    low_level_fs.createHardLink(io(runtime), target, link) catch |failure| {
        return throwIo(runtime, failure, operation, target, link, .hardlink);
    };
    return .{};
}

pub fn realpathBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.realpath;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const resolved = low_level_fs.realpath(io(runtime), runtime.allocator, path) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .realpath);
    };
    defer runtime.allocator.free(resolved);
    return pathStringFromBytes(runtime, resolved);
}

pub fn renameBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.rename;
    const source = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(source);
    const destination = try pathArgument(runtime, arguments[1], operation);
    defer runtime.allocator.free(destination);
    low_level_fs.rename(io(runtime), source, destination) catch |failure| {
        return throwIo(runtime, failure, operation, source, destination, .rename);
    };
    return .{};
}

pub fn unlinkBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.unlink;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    low_level_fs.unlink(io(runtime), path) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .unlink);
    };
    return .{};
}

pub fn rmdirBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.rmdir;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    low_level_fs.rmdir(io(runtime), path) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .rmdir);
    };
    return .{};
}

pub fn truncateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.truncate;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const size = sizeArgument(runtime, arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, operation, path, null, "切詰める大きさが不正です");
    };
    low_level_fs.truncatePath(io(runtime), path, size) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .truncate);
    };
    return .{};
}

pub fn utimeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.utime;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const atime = try setTimeArgument(runtime, arguments[1], operation);
    const mtime = try setTimeArgument(runtime, arguments[2], operation);
    low_level_fs.setTimestampsPath(io(runtime), path, atime, mtime) catch |failure| {
        return throwIo(runtime, failure, operation, path, null, .utime);
    };
    return .{};
}

pub fn pluginTruncatePath(context: *anyopaque, path: []const u8, size: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.truncatePath(io(runtime), path, size);
}

pub fn pluginUtimePath(context: *anyopaque, path: []const u8, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.setTimestampsPath(io(runtime), path, atime, mtime);
}

pub fn pluginStatfs(context: *anyopaque, path: []const u8) anyerror!low_level_fs.FsInfo {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.statfs(io(runtime), path);
}

pub fn pluginReflink(context: *anyopaque, source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_fs.reflink(io(runtime), source, destination, mode);
}

/// `ファイルシステム情報取得`（statfs相当）。`path` が属するFSの容量・inode
/// 統計を `fsInfo` 契約の辞書で返す。
pub fn statfsBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.statfs;
    const path = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(path);
    const info = low_level_fs.statfs(io(runtime), path) catch |failure| {
        return throwIoMapped(runtime, failure, foundation.statfsErrorCode(failure), operation, path, .statfs);
    };
    return fsInfoValue(runtime, info);
}

fn fsInfoValue(runtime: *Runtime, info: low_level_fs.FsInfo) !Value {
    var result = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&result), 1);
    defer runtime.popRoots(&roots);
    try setField(runtime, result, foundation.fs_info_keys.block_size, try publicSizeValue(runtime, info.block_size));
    try setField(runtime, result, foundation.fs_info_keys.blocks, try publicSizeValue(runtime, info.blocks));
    try setField(runtime, result, foundation.fs_info_keys.free, try publicSizeValue(runtime, info.free));
    try setField(runtime, result, foundation.fs_info_keys.available, try publicSizeValue(runtime, info.available));
    try setField(runtime, result, foundation.fs_info_keys.files, try publicSizeValue(runtime, info.files));
    try setField(runtime, result, foundation.fs_info_keys.free_files, try publicSizeValue(runtime, info.free_files));
    try setField(runtime, result, foundation.fs_info_keys.filesystem_type, try runtimeUtf8String(runtime, info.filesystemType()));
    try setField(runtime, result, foundation.fs_info_keys.filesystem_id, try runtimeUtf8String(runtime, info.filesystemId()));
    return result;
}

/// `ファイルクローン`。MODE省略はSRC権限継承、明示時は `0..=0o7777` の
/// 数値権限を適用する。非対応OS/FSは構造化ENOTSUP。
pub fn reflinkBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.reflink;
    const source = try pathArgument(runtime, arguments[0], operation);
    defer runtime.allocator.free(source);
    const destination = try pathArgument(runtime, arguments[1], operation);
    defer runtime.allocator.free(destination);
    const mode: ?u32 = if (arguments.len > 2 and arguments[2].tag != @intFromEnum(Tag.undefined))
        try unsignedArgument(runtime, arguments[2], operation, foundation.max_permission_mode, "modeは0〜0o7777の整数である必要があります")
    else
        null;
    low_level_fs.reflink(io(runtime), source, destination, mode) catch |failure| {
        return throwIoMappedPair(runtime, failure, foundation.reflinkErrorCode(failure), operation, source, destination, .reflink);
    };
    return .{};
}

test "AOT低レイヤーのstatfsはfsInfo辞書を返し契約エラーを丸める" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try runtimeUtf8String(active, directory);

    const info = try state.lowLevelFileBuiltin(active, .low_level_statfs, &.{roots[0]});
    // typeSchemas.fsInfo の全8フィールドが辞書に存在する。
    inline for (foundation.fs_info_key_list) |key| {
        var units: [32]u16 = undefined;
        for (key, 0..) |character, index| units[index] = character;
        const field = dictionaryProperty(info, units[0..key.len]);
        try std.testing.expect(field.tag != @intFromEnum(Tag.undefined));
    }
    try std.testing.expect(valueToNumber(dictionaryProperty(info, &.{ 'b', 'l', 'o', 'c', 'k', 'S', 'i', 'z', 'e' })) > 0);

    // 非文字列pathはEINVAL、不在パスはENOENT。
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_statfs, &.{numberValue(1)}));
    try expectPendingCode(active, "EINVAL");
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing" });
    defer std.testing.allocator.free(missing);
    roots[1] = try runtimeUtf8String(active, missing);
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_statfs, &.{roots[1]}));
    try expectPendingCode(active, "ENOENT");
}

test "AOT低レイヤーのstatfsは2^53境界でカウンタをNumber/BigIntへ分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // typeSchemas.fsInfo のカウンタ6フィールドはsize型で、
    // 安全整数の境界でNumber/BigIntが分かれる必要がある。
    const max_safe: u64 = @intCast(foundation.max_safe_integer);
    const info: low_level_fs.FsInfo = .{
        .block_size = 4096,
        .blocks = max_safe + 1,
        .free = max_safe,
        .files = max_safe + 1,
        .free_files = 7,
    };
    var roots = [_]Value{.{}};
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try fsInfoValue(active, info);

    const blocks = dictionaryProperty(roots[0], &.{ 'b', 'l', 'o', 'c', 'k', 's' });
    try std.testing.expect(blocks.tag == @intFromEnum(Tag.bigint));
    try std.testing.expectEqual(@as(u128, max_safe + 1), try blocks.object().?.payload.bigint.toU128());
    const free = dictionaryProperty(roots[0], &.{ 'f', 'r', 'e', 'e' });
    try std.testing.expectEqual(@as(f64, @floatFromInt(max_safe)), valueToNumber(free));
    const free_files = dictionaryProperty(roots[0], &.{ 'f', 'r', 'e', 'e', 'F', 'i', 'l', 'e', 's' });
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(free_files));
}

test "AOT低レイヤーのreflinkは複製を作り契約エラーを返す" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "src.txt", .data = "clone me" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "src.txt" });
    defer std.testing.allocator.free(source_path);
    const destination_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "dst.txt" });
    defer std.testing.allocator.free(destination_path);

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);
    roots[0] = try runtimeUtf8String(active, source_path);
    roots[1] = try runtimeUtf8String(active, destination_path);

    // 非対応FSは構造化ENOTSUP（capability=reflink）になる。
    _ = state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[0], roots[1] }) catch |failure| {
        try std.testing.expectEqual(error.NakoException, failure);
        try expectPendingCode(active, "ENOTSUP");
        return error.SkipZigTest;
    };
    const cloned = try temporary.dir.readFileAlloc(std.testing.io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(cloned);
    try std.testing.expectEqualStrings("clone me", cloned);

    // 既存DSTはEEXISTでpath/path2を持つ。
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[0], roots[1] }));
    try expectPendingCode(active, "EEXIST");

    // MODE境界: 0o10000はEINVAL、0o700は適用される。
    const third_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "third.txt" });
    defer std.testing.allocator.free(third_path);
    roots[2] = try runtimeUtf8String(active, third_path);
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[0], roots[2], numberValue(0o10000) }));
    try expectPendingCode(active, "EINVAL");
    _ = try state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[0], roots[2], numberValue(0o700) });
    const info = try state.lowLevelFileBuiltin(active, .low_level_file_stat, &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 0o700), valueToNumber(dictionaryProperty(info, &.{ 'm', 'o', 'd', 'e' })));

    // 不在SRCはENOENT。
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.txt" });
    defer std.testing.allocator.free(missing);
    roots[3] = try runtimeUtf8String(active, missing);
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[3], roots[2] }));
    try expectPendingCode(active, "ENOENT");
}

test "AOT低レイヤーのIssue #36命令はWindowsで照会false・実行ENOTSUPになる" {
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) return error.SkipZigTest;
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    inline for (.{ "statfs", "reflink", "seek_data", "seek_hole", "fallocate" }) |capability_id| {
        roots[0] = try runtimeUtf8String(active, capability_id);
        const supported = try state.lowLevelCapabilitySupportedBuiltin(active, roots[0..1]);
        try std.testing.expectEqual(@intFromEnum(Tag.boolean), supported.tag);
        try std.testing.expect(supported.payload == 0);
    }

    roots[0] = try runtimeUtf8String(active, "x");
    roots[1] = try runtimeUtf8String(active, "y");
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_statfs, &.{roots[0]}));
    try expectPendingCode(active, "ENOTSUP");
    try std.testing.expectError(error.NakoException, state.lowLevelFileBuiltin(active, .low_level_reflink, &.{ roots[0], roots[1] }));
    try expectPendingCode(active, "ENOTSUP");
}
