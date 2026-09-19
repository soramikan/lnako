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
const setTimeArgument = shared.setTimeArgument;
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

fn pathArgument(runtime: *Runtime, value: Value, operation: []const u8) ![]u8 {
    if (!isString(value)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    // lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの
    // 誤操作につながるため、可逆なWTF-8変換を使う（InterpreterのrequirePathと同じ規則）。
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return foundation.pathBytesFromUtf16(runtime.allocator, units);
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
