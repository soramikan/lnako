const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_io = @import("../../runtime/low_level_io.zig");
const low_level_hash = @import("../../runtime/low_level_hash.zig");
const low_level_fs = @import("../../runtime/low_level_fs.zig");
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

const throwIo = shared.throwIo;
const throwIoMapped = shared.throwIoMapped;
const throwIoMappedPair = shared.throwIoMappedPair;
const throwStructured = shared.throwStructured;
const publicSizeValue = shared.publicSizeValue;
const pathStringFromBytes = shared.pathStringFromBytes;
const lookupHandle = shared.lookupHandle;
const sizeArgument = shared.sizeArgument;
const requirePath = shared.pathArgument;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;
const expectThrownPathPair = shared.expectThrownPathPair;

pub fn statPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, follow: bool) !Value {
    _ = state;
    const operation = if (follow) foundation.filesystem_operations.stat else foundation.filesystem_operations.lstat;
    const capability: foundation.Capability = if (follow) .stat else .lstat;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const metadata = context.stat(path, follow) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, capability);
    };
    return statValue(runtime, metadata);
}

fn statValue(runtime: *Runtime, metadata: low_level_fs.Metadata) !Value {
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.kind, try runtime.stringUtf8(metadata.kind.name()));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.size, try publicSizeValue(runtime, metadata.size));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mode, .{ .number = @floatFromInt(metadata.mode) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.uid, .{ .number = @floatFromInt(metadata.uid) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.gid, .{ .number = @floatFromInt(metadata.gid) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.dev, .{ .number = @floatFromInt(metadata.dev) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.rdev, .{ .number = @floatFromInt(metadata.rdev) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.inode, .{ .number = @floatFromInt(metadata.inode) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.nlink, .{ .number = @floatFromInt(metadata.nlink) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.block_size, .{ .number = @floatFromInt(metadata.block_size) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.blocks, .{ .number = @floatFromInt(metadata.blocks) });
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.atime_ns, try timeValue(runtime, metadata.atime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mtime_ns, try timeValue(runtime, metadata.mtime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.ctime_ns, try timeValue(runtime, metadata.ctime_ns));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.birthtime_ns, try timeValue(runtime, metadata.birthtime_ns));
    return dictionary;
}

fn timeValue(runtime: *Runtime, nanoseconds: foundation.OptionalTimeNs) !Value {
    const value = nanoseconds orelse return .null_value;
    return runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), value));
}

pub fn symlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.symlink;
    const target = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(target);
    const link = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(link);
    context.createSymlink(target, link) catch |failure| {
        return throwIo(runtime, effects, failure, operation, target, link, .symlink);
    };
    return .undefined;
}

pub fn readlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.readlink;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const destination = context.readlink(runtime.allocator(), path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .readlink);
    };
    defer runtime.allocator().free(destination);
    return pathStringFromBytes(runtime, destination);
}

pub fn hardlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.hardlink;
    const target = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(target);
    const link = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(link);
    context.createHardLink(target, link) catch |failure| {
        return throwIo(runtime, effects, failure, operation, target, link, .hardlink);
    };
    return .undefined;
}

pub fn realpathPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.realpath;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const resolved = context.realpath(runtime.allocator(), path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .realpath);
    };
    defer runtime.allocator().free(resolved);
    return pathStringFromBytes(runtime, resolved);
}

pub fn renamePath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.rename;
    const source = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(source);
    const destination = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(destination);
    context.rename(source, destination) catch |failure| {
        return throwIo(runtime, effects, failure, operation, source, destination, .rename);
    };
    return .undefined;
}

pub fn unlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.unlink;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.unlink(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .unlink);
    };
    return .undefined;
}

pub fn rmdirPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.rmdir;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.rmdir(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .rmdir);
    };
    return .undefined;
}

/// ATIME/MTIME引数を `SetTime` 契約へ変換する。nullは既存値維持、
/// 文字列 `"now"` は現在時刻、Number/BigIntはナノ秒の明示値。
fn requireSetTime(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) !foundation.SetTime {
    return switch (value) {
        .null_value => .unchanged,
        .number => |number| .{ .at = foundation.timeNsFromNumber(number) catch {
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります");
        } },
        .bigint => |bigint| .{ .at = bigint.toI128() catch {
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります");
        } },
        .string => |string| if (isNowString(string.units))
            .now
        else
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, "時刻はナノ秒の整数か\"now\"である必要があります"),
        else => return throwStructured(runtime, effects, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります"),
    };
}

fn isNowString(units: []const u16) bool {
    if (units.len != 3) return false;
    return units[0] == 'n' and units[1] == 'o' and units[2] == 'w';
}

pub fn truncatePath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.truncate;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const size = sizeArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, path, null, "切詰める大きさが不正です");
    };
    context.truncatePath(path, size) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .truncate);
    };
    return .undefined;
}

pub fn utimePath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.utime;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const atime = try requireSetTime(runtime, effects, common.argument(arguments, 1), operation);
    const mtime = try requireSetTime(runtime, effects, common.argument(arguments, 2), operation);
    context.utimePath(path, atime, mtime) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .utime);
    };
    return .undefined;
}

pub fn utimeHandle(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.filesystem_operations.futime;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    const atime = try requireSetTime(runtime, effects, common.argument(arguments, 1), operation);
    const mtime = try requireSetTime(runtime, effects, common.argument(arguments, 2), operation);
    context.setTimestampsFile(id.raw(), atime, mtime) catch |failure| {
        return throwIo(runtime, effects, failure, operation, null, null, .utime);
    };
    return .undefined;
}

pub fn statfsPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.statfs;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    const info = context.statfs(path) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.statfsErrorCode(failure), operation, path, .statfs);
    };
    return fsInfoValue(runtime, info);
}

/// `fsInfo`辞書を組み立てる。カタログ `typeSchemas.fsInfo` の全8フィールドを
/// `fs_info_key_list` と同じ順序で入れる。ブロック・inode数はu64全体を
/// 保持するため安全整数を超える値はBigIntへ写す。
fn fsInfoValue(runtime: *Runtime, info: low_level_fs.FsInfo) !Value {
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.block_size, try publicSizeValue(runtime, info.block_size));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.blocks, try publicSizeValue(runtime, info.blocks));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.free, try publicSizeValue(runtime, info.free));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.available, try publicSizeValue(runtime, info.available));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.files, try publicSizeValue(runtime, info.files));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.free_files, try publicSizeValue(runtime, info.free_files));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.filesystem_type, try runtime.stringUtf8(info.filesystemType()));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.fs_info_keys.filesystem_id, try runtime.stringUtf8(info.filesystemId()));
    return dictionary;
}

pub fn reflinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.reflink;
    const source = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(source);
    const destination = try requirePath(runtime, effects, common.argument(arguments, 1), operation);
    defer runtime.allocator().free(destination);
    // MODEは省略時null（SRC権限継承）。指定時は0〜0o7777の権限bit。
    const mode_value = common.argument(arguments, 2);
    const mode: ?u32 = if (mode_value == .undefined) null else try shared.unsignedArgument(runtime, effects, mode_value, operation, foundation.max_permission_mode, "modeは0〜0o7777の整数である必要があります");
    context.reflink(source, destination, mode) catch |failure| {
        return throwIoMappedPair(runtime, effects, failure, foundation.reflinkErrorCode(failure), operation, source, destination, .reflink);
    };
    return .undefined;
}

/// Issue #29/#31のパス操作を実OSで検証するためのContext。InterpreterのHostと
/// 同じ `low_level_fs` 実装を共有し、dispatchと値組み立てだけを単体で検査する。
/// `ファイル時刻設定済` のhandle解決は実ファイル表を持つため、開閉callbackも
/// 併せて提供する。
const FsTestHost = struct {
    table: low_level_io.FileHandleTable,

    fn init() FsTestHost {
        return .{ .table = low_level_io.FileHandleTable.init(std.testing.allocator) };
    }

    fn deinit(self: *FsTestHost) void {
        self.table.deinit(std.testing.io);
    }

    fn openCallback(pointer: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        return (try self.table.open(std.testing.io, .{ .path = path, .mode = mode, .exclusive = exclusive, .sync = sync })).raw();
    }

    fn closeCallback(pointer: *anyopaque, raw: u64) anyerror!void {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const removed = self.table.remove(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        removed.file.close(std.testing.io);
    }

    fn setTimestampsCallback(pointer: *anyopaque, raw: u64, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return low_level_fs.setTimestampsHandle(std.testing.io, entry.file, atime, mtime);
    }

    fn truncateFileCallback(pointer: *anyopaque, raw: u64, size: u64) anyerror!void {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return low_level_io.setLength(std.testing.io, entry.file, size);
    }

    fn statCallback(_: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata {
        return low_level_fs.stat(std.testing.io, path, follow);
    }

    fn symlinkCallback(_: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
        return low_level_fs.createSymlink(std.testing.io, target, link);
    }

    fn readlinkCallback(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        return low_level_fs.readlink(std.testing.io, allocator, path);
    }

    fn hardlinkCallback(_: *anyopaque, target: []const u8, link: []const u8) anyerror!void {
        return low_level_fs.createHardLink(std.testing.io, target, link);
    }

    fn realpathCallback(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        return low_level_fs.realpath(std.testing.io, allocator, path);
    }

    fn renameCallback(_: *anyopaque, source: []const u8, destination: []const u8) anyerror!void {
        return low_level_fs.rename(std.testing.io, source, destination);
    }

    fn unlinkCallback(_: *anyopaque, path: []const u8) anyerror!void {
        return low_level_fs.unlink(std.testing.io, path);
    }

    fn rmdirCallback(_: *anyopaque, path: []const u8) anyerror!void {
        return low_level_fs.rmdir(std.testing.io, path);
    }

    fn truncatePathCallback(_: *anyopaque, path: []const u8, size: u64) anyerror!void {
        return low_level_fs.truncatePath(std.testing.io, path, size);
    }

    fn utimePathCallback(_: *anyopaque, path: []const u8, atime: foundation.SetTime, mtime: foundation.SetTime) anyerror!void {
        return low_level_fs.setTimestampsPath(std.testing.io, path, atime, mtime);
    }

    fn statfsCallback(_: *anyopaque, path: []const u8) anyerror!low_level_fs.FsInfo {
        return low_level_fs.statfs(std.testing.io, path);
    }

    fn reflinkCallback(_: *anyopaque, source: []const u8, destination: []const u8, mode: ?u32) anyerror!void {
        return low_level_fs.reflink(std.testing.io, source, destination, mode);
    }

    fn seekDataCallback(pointer: *anyopaque, raw: u64, offset: i64) anyerror!i64 {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return low_level_fs.seekExtent(std.testing.io, entry.file, offset, .data);
    }

    fn seekHoleCallback(pointer: *anyopaque, raw: u64, offset: i64) anyerror!i64 {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return low_level_fs.seekExtent(std.testing.io, entry.file, offset, .hole);
    }

    fn allocateCallback(pointer: *anyopaque, raw: u64, offset: i64, size: u64) anyerror!void {
        const self: *FsTestHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return low_level_fs.allocate(std.testing.io, entry.file, offset, size);
    }

    fn context(self: *FsTestHost) Context {
        return .{
            .stream = .{
                .context = self,
                .openFileFn = openCallback,
                .closeFileFn = closeCallback,
                .truncateFileFn = truncateFileCallback,
                .setTimestampsFileFn = setTimestampsCallback,
                .seekDataFileFn = seekDataCallback,
                .seekHoleFileFn = seekHoleCallback,
                .allocateFileFn = allocateCallback,
            },
            .fs = .{
                .context = self,
                .statFn = statCallback,
                .symlinkFn = symlinkCallback,
                .readlinkFn = readlinkCallback,
                .hardlinkFn = hardlinkCallback,
                .realpathFn = realpathCallback,
                .renameFn = renameCallback,
                .unlinkFn = unlinkCallback,
                .rmdirFn = rmdirCallback,
                .truncatePathFn = truncatePathCallback,
                .utimePathFn = utimePathCallback,
                .statfsFn = statfsCallback,
                .reflinkFn = reflinkCallback,
            },
        };
    }
};

test "低レイヤーのstatはContext経由で辞書を返しcapabilityが有効になる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "hello" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "plain.txt" });
    defer std.testing.allocator.free(path_bytes);

    var path = try runtime.stringUtf8(path_bytes);
    try roots.protect(&path);
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var capability_name = try runtime.stringUtf8("stat");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    var result = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    const kind = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const kind_text = try node_shared.valueUtf8(&runtime, kind);
    defer runtime.allocator().free(kind_text);
    try std.testing.expectEqualStrings("file", kind_text);
    const size = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.size) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), size.number);
    const mtime = node_shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.mtime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(mtime == .bigint);
    // カタログ typeSchemas.stat の全15フィールドが辞書に存在する。
    inline for (foundation.stat_field_key_list) |key| {
        try std.testing.expect(node_shared.dictionaryGetAscii(result.dictionary, key) != null);
    }

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{.{ .number = 1 }}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "低レイヤーのunlink/rmdirはContext経由でEISDIRとENOTEMPTYを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "empty", .default_dir);
    try temporary.dir.createDir(std.testing.io, "full", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "full/child.txt", .data = "" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    const empty_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "empty" });
    defer std.testing.allocator.free(empty_path);
    const full_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "full" });
    defer std.testing.allocator.free(full_path);

    var empty_dir = try runtime.stringUtf8(empty_path);
    try roots.protect(&empty_dir);
    var full_dir = try runtime.stringUtf8(full_path);
    try roots.protect(&full_dir);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルリンク削除", &.{empty_dir}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EISDIR");

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "空フォルダ削除", &.{full_dir}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTEMPTY");

    _ = (try call(&runtime, &state, context, effects, "空フォルダ削除", &.{empty_dir})) orelse return error.TestExpectedEqual;
}

test "孤立サロゲートのパスはU+FFFD名へ置換されず別ファイルを削除しない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 置換文字U+FFFDという名前の実在ファイル。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "\u{FFFD}", .data = "keep" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const replacement_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "\u{FFFD}" });
    defer std.testing.allocator.free(replacement_path);

    // "<dir>/<孤立サロゲート>" を作る。lossy変換だと"<dir>/�"になり実在ファイルを消す。
    const units = try std.testing.allocator.alloc(u16, directory.len + 2);
    defer std.testing.allocator.free(units);
    for (directory, 0..) |byte, index| units[index] = byte;
    units[directory.len] = '/';
    units[directory.len + 1] = 0xD800;
    var path = try runtime.stringCodeUnits(units);
    try roots.protect(&path);

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルリンク削除", &.{path}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
    // 失敗した元のパスを識別できる（孤立サロゲートを保持）。
    const error_path = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.path) orelse return error.TestExpectedEqual;
    try std.testing.expect(error_path == .string);
    try std.testing.expectEqualSlices(u16, units, error_path.string.units);

    // U+FFFD名のファイルは残っている。
    _ = try low_level_fs.stat(std.testing.io, replacement_path, true);
}

test "readlinkは孤立サロゲートを含むリンク先を可逆に返す" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "surrogate-link" });
    defer std.testing.allocator.free(link_path);

    // 孤立サロゲート1個だけをtargetにする（dangling）。
    var target = try runtime.stringCodeUnits(&[_]u16{0xD800});
    try roots.protect(&target);
    var link = try runtime.stringUtf8(link_path);
    try roots.protect(&link);

    _ = (try call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link })) orelse return error.TestExpectedEqual;
    var destination = (try call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&destination);
    try std.testing.expect(destination == .string);
    // lossy変換ならU+FFFDになるが、可逆変換では元の孤立サロゲートのまま。
    try std.testing.expectEqualSlices(u16, &[_]u16{0xD800}, destination.string.units);
}

test "低レイヤーのsymlink/lstat/hardlink/readlink/realpath/renameはContext経由で動作する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "abc" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    const target_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "target.txt" });
    defer std.testing.allocator.free(target_path);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "link.txt" });
    defer std.testing.allocator.free(link_path);
    const hard_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "hard.txt" });
    defer std.testing.allocator.free(hard_path);
    const renamed_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "renamed.txt" });
    defer std.testing.allocator.free(renamed_path);

    var target = try runtime.stringUtf8(target_path);
    try roots.protect(&target);
    var link = try runtime.stringUtf8(link_path);
    try roots.protect(&link);
    var hard = try runtime.stringUtf8(hard_path);
    try roots.protect(&hard);
    var renamed = try runtime.stringUtf8(renamed_path);
    try roots.protect(&renamed);

    _ = (try call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link })) orelse return error.TestExpectedEqual;

    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "シンボリックリンク作成", &.{ target, link }));
    try roots.protect(&thrown);
    try expectThrownPathPair(&runtime, thrown, "EEXIST", "symlink", target_path, link_path);

    // lstatはsymlink自身、statは参照先を返す。
    var link_info = (try call(&runtime, &state, context, effects, "シンボリックリンク情報取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&link_info);
    const link_kind = node_shared.dictionaryGetAscii(link_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const link_kind_text = try node_shared.valueUtf8(&runtime, link_kind);
    defer runtime.allocator().free(link_kind_text);
    try std.testing.expectEqualStrings("symlink", link_kind_text);

    var followed_info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&followed_info);
    const followed_kind = node_shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const followed_kind_text = try node_shared.valueUtf8(&runtime, followed_kind);
    defer runtime.allocator().free(followed_kind_text);
    try std.testing.expectEqualStrings("file", followed_kind_text);

    // ハードリンクは同一inode・nlink=2。
    _ = (try call(&runtime, &state, context, effects, "ハードリンク作成", &.{ target, hard })) orelse return error.TestExpectedEqual;
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハードリンク作成", &.{ target, hard }));
    try roots.protect(&thrown);
    try expectThrownPathPair(&runtime, thrown, "EEXIST", "link", target_path, hard_path);
    var hard_info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{hard})) orelse return error.TestExpectedEqual;
    try roots.protect(&hard_info);
    const nlink = node_shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.nlink) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 2), nlink.number);
    const hard_inode = node_shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    const target_inode = node_shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(target_inode.number, hard_inode.number);

    var destination = (try call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&destination);
    const destination_text = try node_shared.valueUtf8(&runtime, destination);
    defer runtime.allocator().free(destination_text);
    try std.testing.expectEqualStrings(target_path, destination_text);

    // 非symlinkへのreadlinkはEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{target}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var resolved = (try call(&runtime, &state, context, effects, "実体パス取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&resolved);
    const resolved_text = try node_shared.valueUtf8(&runtime, resolved);
    defer runtime.allocator().free(resolved_text);
    try std.testing.expectEqualStrings(target_path, resolved_text);

    _ = (try call(&runtime, &state, context, effects, "パス名変更", &.{ link, renamed })) orelse return error.TestExpectedEqual;
    _ = (try call(&runtime, &state, context, effects, "ファイルリンク削除", &.{renamed})) orelse return error.TestExpectedEqual;

    // symlinkループのstatはELOOPへ写る。
    try temporary.dir.symLink(std.testing.io, "loop", "loop", .{});
    const loop_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "loop" });
    defer std.testing.allocator.free(loop_path);
    var loop = try runtime.stringUtf8(loop_path);
    try roots.protect(&loop);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{loop}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ELOOP");
}

test "低レイヤーのtruncate/utimeはContext経由で反映され契約違反をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "meta.bin", .data = "hello world" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "meta.bin" });
    defer std.testing.allocator.free(path_bytes);
    var path = try runtime.stringUtf8(path_bytes);
    try roots.protect(&path);

    // パスtruncate: 11 -> 5 byte。
    _ = (try call(&runtime, &state, context, effects, "ファイルサイズ変更", &.{ path, .{ .number = 5 } })) orelse return error.TestExpectedEqual;
    var info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&info);
    const size = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.size) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), size.number);

    // 明示ナノ秒の時刻設定（BigInt引数）。サブ秒0.5sで1秒粒度を検出する。
    const explicit_ns: i128 = 1_600_000_000_500_000_000;
    var explicit = try runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), explicit_ns));
    try roots.protect(&explicit);
    _ = (try call(&runtime, &state, context, effects, "ファイル時刻設定", &.{ path, explicit, explicit })) orelse return error.TestExpectedEqual;
    info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&info);
    const atime = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.atime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(atime == .bigint);
    try std.testing.expect(@abs((try atime.bigint.toI64()) - explicit_ns) < std.time.ns_per_us);

    // NOWは現在時刻（2026年以降）へ進み、null/既存値維持は変更しない。
    var now_text = try runtime.stringUtf8("now");
    try roots.protect(&now_text);
    _ = (try call(&runtime, &state, context, effects, "ファイル時刻設定", &.{ path, now_text, .null_value })) orelse return error.TestExpectedEqual;
    info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&info);
    const now_atime = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.atime_ns) orelse return error.TestExpectedEqual;
    const kept_mtime = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.mtime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(try now_atime.bigint.toI64() > explicit_ns + std.time.ns_per_day);
    try std.testing.expect(@abs((try kept_mtime.bigint.toI64()) - explicit_ns) < std.time.ns_per_us);

    // 契約外の時刻はEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル時刻設定", &.{ path, .{ .number = 1.5 }, now_text }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    // ハンドル経由の時刻設定（now/now）。
    var mode = try runtime.stringUtf8("r+");
    try roots.protect(&mode);
    var handle = (try call(&runtime, &state, context, effects, "ファイル開く", &.{ path, mode })) orelse return error.TestExpectedEqual;
    try roots.protect(&handle);
    _ = (try call(&runtime, &state, context, effects, "ファイル時刻設定済", &.{ handle, now_text, now_text })) orelse return error.TestExpectedEqual;
    info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&info);
    const handle_atime = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.atime_ns) orelse return error.TestExpectedEqual;
    const handle_mtime = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.mtime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(try handle_atime.bigint.toI64() > explicit_ns + std.time.ns_per_day);
    try std.testing.expect(try handle_mtime.bigint.toI64() > explicit_ns + std.time.ns_per_day);

    // 無効ハンドルはEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル時刻設定済", &.{ .{ .number = 1 }, now_text, .null_value }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");

    // close後ハンドルもEBADF（状態から消えているため）。
    _ = (try call(&runtime, &state, context, effects, "ファイル閉じる", &.{handle})) orelse return error.TestExpectedEqual;
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル時刻設定済", &.{ handle, now_text, .null_value }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");

    // 存在しないパスはENOENT。
    const missing_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing-meta.bin" });
    defer std.testing.allocator.free(missing_bytes);
    var missing = try runtime.stringUtf8(missing_bytes);
    try roots.protect(&missing);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルサイズ変更", &.{ missing, .{ .number = 1 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
}

test "低レイヤーのstatfsはContext経由でfsInfo辞書を返し契約エラーを丸める" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var path = try runtime.stringUtf8(directory);
    try roots.protect(&path);

    var capability_name = try runtime.stringUtf8("statfs");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    var result = (try call(&runtime, &state, context, effects, "ファイルシステム情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    // カタログ typeSchemas.fsInfo の全8フィールドが辞書に存在する。
    inline for (foundation.fs_info_key_list) |key| {
        try std.testing.expect(node_shared.dictionaryGetAscii(result.dictionary, key) != null);
    }
    const block_size = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.block_size) orelse return error.TestExpectedEqual;
    try std.testing.expect(block_size.number > 0);
    const fs_type = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.filesystem_type) orelse return error.TestExpectedEqual;
    const fs_type_text = try node_shared.valueUtf8(&runtime, fs_type);
    defer runtime.allocator().free(fs_type_text);
    try std.testing.expect(fs_type_text.len > 0);

    // 不在パスはENOENT、非文字列pathはEINVAL。
    const missing_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing-statfs" });
    defer std.testing.allocator.free(missing_bytes);
    var missing = try runtime.stringUtf8(missing_bytes);
    try roots.protect(&missing);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルシステム情報取得", &.{missing}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルシステム情報取得", &.{.{ .number = 1 }}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "低レイヤーのstatfsは2^53境界でカウンタをNumber/BigIntへ分ける" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    // typeSchemas.fsInfo のカウンタ6フィールドはsize型で、
    // 安全整数の境界でNumber/BigIntが分かれる必要がある。
    const max_safe: u64 = @intCast(foundation.max_safe_integer);
    const info: low_level_fs.FsInfo = .{
        .block_size = 4096,
        .blocks = max_safe + 1,
        .free = max_safe,
        .available = 0,
        .files = max_safe + 1,
        .free_files = 7,
    };
    var result = try fsInfoValue(&runtime, info);
    try roots.protect(&result);
    const blocks = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.blocks) orelse return error.TestExpectedEqual;
    try std.testing.expect(blocks == .bigint);
    try std.testing.expectEqual(@as(u128, max_safe + 1), try blocks.bigint.toU128());
    const free = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.free) orelse return error.TestExpectedEqual;
    try std.testing.expect(free == .number);
    try std.testing.expectEqual(@as(f64, @floatFromInt(max_safe)), free.number);
    const files = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.files) orelse return error.TestExpectedEqual;
    try std.testing.expect(files == .bigint);
    const free_files = node_shared.dictionaryGetAscii(result.dictionary, foundation.fs_info_keys.free_files) orelse return error.TestExpectedEqual;
    try std.testing.expect(free_files == .number);
}

test "低レイヤーのreflinkはContext経由でCoW複製を作り契約エラーを返す" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "src.txt", .data = "clone me" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const source_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "src.txt" });
    defer std.testing.allocator.free(source_bytes);
    const destination_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "dst.txt" });
    defer std.testing.allocator.free(destination_bytes);
    var source = try runtime.stringUtf8(source_bytes);
    try roots.protect(&source);
    var destination = try runtime.stringUtf8(destination_bytes);
    try roots.protect(&destination);

    var capability_name = try runtime.stringUtf8("reflink");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    // MODE省略はSRC権限を継承する。非対応FSはENOTSUPを返すので、
    // 契約コードの確認（capability=reflink）に留めて成功系のみスキップする。
    _ = call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, destination }) catch |failure| {
        try std.testing.expectEqual(error.NakoException, failure);
        try roots.protect(&thrown);
        try expectThrownCode(&runtime, thrown, "ENOTSUP");
        try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "reflink");
        return error.SkipZigTest;
    };
    const cloned = try temporary.dir.readFileAlloc(std.testing.io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(cloned);
    try std.testing.expectEqualStrings("clone me", cloned);

    // 明示MODEは権限を上書きする。
    const third_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "third.txt" });
    defer std.testing.allocator.free(third_bytes);
    var third = try runtime.stringUtf8(third_bytes);
    try roots.protect(&third);
    _ = (try call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, third, .{ .number = 0o777 } })) orelse return error.TestExpectedEqual;
    var info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{third})) orelse return error.TestExpectedEqual;
    try roots.protect(&info);
    const mode_field = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.mode) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 0o777), mode_field.number);

    // 既存DSTはEEXISTでpath/path2を持つ。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, destination }));
    try roots.protect(&thrown);
    try expectThrownPathPair(&runtime, thrown, "EEXIST", "reflink", source_bytes, destination_bytes);

    // MODE境界: 0o10000・負数・小数・文字列はEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, third, .{ .number = 0o10000 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, third, .{ .number = -1 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
    var mode_text = try runtime.stringUtf8("u+rwx");
    try roots.protect(&mode_text);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルクローン", &.{ source, third, mode_text }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    // 不在SRCはENOENT。
    const missing_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.txt" });
    defer std.testing.allocator.free(missing_bytes);
    var missing = try runtime.stringUtf8(missing_bytes);
    try roots.protect(&missing);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルクローン", &.{ missing, third }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOENT");
}

test "低レイヤーの領域検索・領域確保はContext経由で動作し契約エラーを返す" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var host = FsTestHost.init();
    defer host.deinit();
    const context = host.context();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "sparse.bin", .data = "data" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path_bytes = try std.fs.path.join(std.testing.allocator, &.{ directory, "sparse.bin" });
    defer std.testing.allocator.free(path_bytes);
    // 先頭4byteがデータ、8192以降にデータがあるsparseファイルを作る。
    // Linuxでは実SEEK_DATA/SEEK_HOLE、macOSでは保守的emulated経路になる。
    {
        const raw = try std.Io.Dir.cwd().openFile(std.testing.io, path_bytes, .{ .mode = .read_write });
        defer raw.close(std.testing.io);
        try raw.writePositionalAll(std.testing.io, "tail", 8192);
    }
    var path = try runtime.stringUtf8(path_bytes);
    try roots.protect(&path);
    var mode = try runtime.stringUtf8("r+");
    try roots.protect(&mode);
    var handle = (try call(&runtime, &state, context, effects, "ファイル開く", &.{ path, mode })) orelse return error.TestExpectedEqual;
    try roots.protect(&handle);

    inline for (.{ "seek_data", "seek_hole" }) |capability_id| {
        var capability_name = try runtime.stringUtf8(capability_id);
        try roots.protect(&capability_name);
        const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
        try std.testing.expect(supported == .boolean and supported.boolean);
    }

    var data_at = (try call(&runtime, &state, context, effects, "ファイルデータ領域検索", &.{ handle, .{ .number = 0 } })) orelse return error.TestExpectedEqual;
    try roots.protect(&data_at);
    try std.testing.expectEqual(@as(f64, 0), data_at.number);
    var hole_at = (try call(&runtime, &state, context, effects, "ファイル空洞領域検索", &.{ handle, .{ .number = 0 } })) orelse return error.TestExpectedEqual;
    try roots.protect(&hole_at);
    // Linuxはブロック境界の実hole、emulated経路は末尾の仮想空洞8196を返す。
    if (builtin.os.tag == .linux) {
        try std.testing.expect(hole_at.number >= 4 and hole_at.number <= 8196);
    } else {
        try std.testing.expectEqual(@as(f64, 8196), hole_at.number);
    }
    // 末尾位置のhole検索は両経路で末尾8196を返し、末尾以降のdata検索はEINVAL。
    var end_hole = (try call(&runtime, &state, context, effects, "ファイル空洞領域検索", &.{ handle, .{ .number = 8196 } })) orelse return error.TestExpectedEqual;
    try roots.protect(&end_hole);
    try std.testing.expectEqual(@as(f64, 8196), end_hole.number);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルデータ領域検索", &.{ handle, .{ .number = 99999 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    // 負のoffset・非整数・小数はEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルデータ領域検索", &.{ handle, .{ .number = -1 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル空洞領域検索", &.{ handle, .{ .number = 1.5 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    // 領域確保: EOFを超える範囲はサイズを伸ばす。非対応FSはENOTSUPを許容する。
    var capability_name = try runtime.stringUtf8("fallocate");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);
    const allocated = call(&runtime, &state, context, effects, "ファイル領域確保", &.{ handle, .{ .number = 16384 }, .{ .number = 128 } }) catch |failure| blk: {
        try std.testing.expectEqual(error.NakoException, failure);
        try roots.protect(&thrown);
        try expectThrownCode(&runtime, thrown, "ENOTSUP");
        try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "fallocate");
        break :blk null;
    };
    if (allocated != null) {
        var info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
        try roots.protect(&info);
        const size_field = node_shared.dictionaryGetAscii(info.dictionary, foundation.stat_field_keys.size) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(f64, 16512), size_field.number);
    }

    // size=0と無効ハンドルはEINVAL/EBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル領域確保", &.{ handle, .{ .number = 0 }, .{ .number = 0 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイルデータ領域検索", &.{ .{ .number = 1 }, .{ .number = 0 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル領域確保", &.{ .{ .number = 1 }, .{ .number = 0 }, .{ .number = 1 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");

    _ = (try call(&runtime, &state, context, effects, "ファイル閉じる", &.{handle})) orelse return error.TestExpectedEqual;
    // close後ハンドルはEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ファイル空洞領域検索", &.{ handle, .{ .number = 0 } }));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EBADF");
}
