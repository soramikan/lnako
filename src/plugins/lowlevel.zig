const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../runtime/value.zig");
const foundation = @import("../runtime/low_level_foundation.zig");
const low_level_hash = @import("../runtime/low_level_hash.zig");
const low_level_fs = @import("../runtime/low_level_fs.zig");
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
    createHashFn: ?*const fn (context: *anyopaque, algorithm: []const u8) anyerror!u64 = null,
    updateHashFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!void = null,
    digestHashFn: ?*const fn (context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 = null,
    discardHashFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    statFn: ?*const fn (context: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata = null,
    symlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    readlinkFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 = null,
    hardlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    realpathFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 = null,
    renameFn: ?*const fn (context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void = null,
    unlinkFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    rmdirFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,

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

    pub fn createHash(self: Context, algorithm: []const u8) !u64 {
        const function = self.createHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, algorithm);
    }

    pub fn updateHash(self: Context, raw: u64, bytes: []const u8) !void {
        const function = self.updateHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw, bytes);
    }

    pub fn digestHash(self: Context, raw: u64, allocator: std.mem.Allocator) ![]u8 {
        const function = self.digestHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw, allocator);
    }

    pub fn discardHash(self: Context, raw: u64) !void {
        const function = self.discardHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw);
    }

    pub fn stat(self: Context, path: []const u8, follow: bool) !low_level_fs.Metadata {
        const function = self.statFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, follow);
    }

    pub fn createSymlink(self: Context, target: []const u8, link: []const u8) !void {
        const function = self.symlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, target, link);
    }

    pub fn readlink(self: Context, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const function = self.readlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator, path);
    }

    pub fn createHardLink(self: Context, target: []const u8, link: []const u8) !void {
        const function = self.hardlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, target, link);
    }

    pub fn realpath(self: Context, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
        const function = self.realpathFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator, path);
    }

    pub fn rename(self: Context, source: []const u8, destination: []const u8) !void {
        const function = self.renameFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, source, destination);
    }

    pub fn unlink(self: Context, path: []const u8) !void {
        const function = self.unlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path);
    }

    pub fn rmdir(self: Context, path: []const u8) !void {
        const function = self.rmdirFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path);
    }

    pub fn hasStreamFileIo(self: Context) bool {
        return self.openFileFn != null and self.closeFileFn != null and self.readFileBytesFn != null and self.writeFileBytesFn != null and self.syncFileFn != null;
    }

    pub fn hasTruncate(self: Context) bool {
        return self.truncateFileFn != null;
    }

    pub fn hasIncrementalHash(self: Context) bool {
        return self.createHashFn != null and self.updateHashFn != null and self.digestHashFn != null and self.discardHashFn != null;
    }

    pub fn hasStat(self: Context) bool {
        return self.statFn != null;
    }

    pub fn hasSymlink(self: Context) bool {
        return self.symlinkFn != null;
    }

    pub fn hasReadlink(self: Context) bool {
        return self.readlinkFn != null;
    }

    pub fn hasHardLink(self: Context) bool {
        return self.hardlinkFn != null;
    }

    pub fn hasRealpath(self: Context) bool {
        return self.realpathFn != null;
    }

    pub fn hasRename(self: Context) bool {
        return self.renameFn != null;
    }

    pub fn hasUnlink(self: Context) bool {
        return self.unlinkFn != null;
    }

    pub fn hasRmdir(self: Context) bool {
        return self.rmdirFn != null;
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
    if (std.mem.eql(u8, name, foundation.hash_commands.create)) return @as(?Value, try hashCreate(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.update)) return @as(?Value, try hashUpdate(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.digest)) return @as(?Value, try hashDigest(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.hash_commands.discard)) return @as(?Value, try hashDiscard(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.stat)) return @as(?Value, try statPath(runtime, state, context, effects, arguments, true));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.lstat)) return @as(?Value, try statPath(runtime, state, context, effects, arguments, false));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.symlink)) return @as(?Value, try symlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.readlink)) return @as(?Value, try readlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.hardlink)) return @as(?Value, try hardlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.realpath)) return @as(?Value, try realpathPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.rename)) return @as(?Value, try renamePath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.unlink)) return @as(?Value, try unlinkPath(runtime, state, context, effects, arguments));
    if (std.mem.eql(u8, name, foundation.filesystem_commands.rmdir)) return @as(?Value, try rmdirPath(runtime, state, context, effects, arguments));
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
        .incremental_hash => context.hasIncrementalHash(),
        .stat, .lstat => context.hasStat(),
        .symlink => context.hasSymlink(),
        .readlink => context.hasReadlink(),
        .hardlink => context.hasHardLink(),
        .realpath => context.hasRealpath(),
        .rename => context.hasRename(),
        .unlink => context.hasUnlink(),
        .rmdir => context.hasRmdir(),
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
    // 孤立サロゲートを保持する可逆なWTF-8でパスを作る（fs系と同じ規則）。
    const path = try foundation.pathBytesFromUtf16(runtime.allocator(), path_value.string.units);
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
        return throwIo(runtime, effects, failure, foundation.stream_operations.open, path, null, .stream_file_io);
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
        return throwIo(runtime, effects, failure, foundation.stream_operations.close, null, null, .stream_file_io);
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
            return throwIo(runtime, effects, failure, foundation.stream_operations.read, null, null, .stream_file_io);
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
        return throwIo(runtime, effects, failure, foundation.stream_operations.write, null, null, .stream_file_io);
    };
    return publicSizeValue(runtime, written);
}

fn syncFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    context.syncFile(id.raw()) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.fsync, null, null, .stream_file_io);
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
        return throwIo(runtime, effects, failure, foundation.stream_operations.ftruncate, null, null, .truncate);
    };
    return .undefined;
}

fn hashCreate(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const algorithm_value = common.argument(arguments, 0);
    if (algorithm_value != .string) {
        return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "アルゴリズム名は文字列である必要があります");
    }
    const algorithm = try shared.valueUtf8(runtime, algorithm_value);
    defer runtime.allocator().free(algorithm);
    const raw = context.createHash(algorithm) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    errdefer context.discardHash(raw) catch {};
    const id = foundation.HandleId.fromRaw(raw);
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(state, runtime.allocator(), handle, id);
    return handle;
}

fn hashUpdate(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "追加する値はBytesである必要があります");
    };
    context.updateHash(id.raw(), bytes) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    return .undefined;
}

fn hashDigest(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    var encoding: low_level_hash.Encoding = .raw;
    const encoding_value = common.argument(arguments, 1);
    if (encoding_value != .undefined and encoding_value != .null_value) {
        if (encoding_value != .string) {
            return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "encodingは文字列である必要があります");
        }
        const name = try shared.valueUtf8(runtime, encoding_value);
        defer runtime.allocator().free(name);
        encoding = low_level_hash.Encoding.fromName(name) orelse {
            return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "未知のencodingです");
        };
    }
    const digest = context.digestHash(id.raw(), runtime.allocator()) catch |failure| {
        // digestHashはentryを見つけて消費してからfinalizeする。BadFileDescriptorは
        // 「hash表に無い」（ファイルhandleの取り違え等）で消費していないため、
        // 元handleのidentity mappingを消してはならない。
        if (failure != error.BadFileDescriptor and failure != error.IncrementalHashUnavailable) {
            forgetHandle(state, handle);
        }
        return throwHash(runtime, effects, failure);
    };
    defer runtime.allocator().free(digest);
    forgetHandle(state, handle);
    return encodeDigest(runtime, digest, encoding);
}

fn hashDiscard(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    context.discardHash(id.raw()) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    forgetHandle(state, handle);
    return .undefined;
}

fn encodeDigest(runtime: *Runtime, digest: []const u8, encoding: low_level_hash.Encoding) !Value {
    switch (encoding) {
        .raw => return runtime.createBytes(digest),
        .hex => {
            const result = try runtime.allocator().alloc(u8, digest.len * 2);
            defer runtime.allocator().free(result);
            const text = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
            return runtime.stringUtf8(text);
        },
        .base64, .base64url => {
            const result = try runtime.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
            defer runtime.allocator().free(result);
            _ = std.base64.standard.Encoder.encode(result, digest);
            if (encoding == .base64) return runtime.stringUtf8(result);
            for (result) |*byte| byte.* = switch (byte.*) {
                '+' => '-',
                '/' => '_',
                else => byte.*,
            };
            var length = result.len;
            while (length > 0 and result[length - 1] == '=') length -= 1;
            return runtime.stringUtf8(result[0..length]);
        },
        .latin1 => {
            const units = try runtime.allocator().alloc(u16, digest.len);
            defer runtime.allocator().free(units);
            for (digest, 0..) |byte, index| units[index] = byte;
            return runtime.stringCodeUnits(units);
        },
        .utf8 => return runtime.stringUtf8Lossy(digest),
    }
}

fn hashFailureCode(failure: anyerror) foundation.PortableErrorCode {
    return switch (failure) {
        error.UnsupportedHashAlgorithm => .EINVAL,
        error.IncrementalHashUnsupported, error.IncrementalHashUnavailable => .ENOTSUP,
        else => foundation.portableCodeForFailure(failure) orelse .EINVAL,
    };
}

fn throwHash(runtime: *Runtime, effects: Effects, failure: anyerror) anyerror {
    const code = hashFailureCode(failure);
    const capability = if (code == .ENOTSUP) foundation.Capability.incremental_hash.id() else null;
    return throwStructured(runtime, effects, code, foundation.hash_operation, null, capability, hashFailureMessage(failure));
}

fn hashFailureMessage(failure: anyerror) []const u8 {
    return switch (failure) {
        error.UnsupportedHashAlgorithm => "未対応のハッシュアルゴリズムです",
        error.IncrementalHashUnsupported => "このアルゴリズムは逐次計算に対応していません",
        error.IncrementalHashUnavailable => "逐次ハッシュは利用できません",
        error.BadFileDescriptor => "無効なハンドルです",
        else => @errorName(failure),
    };
}

fn requirePath(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) ![]u8 {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    // lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの
    // 誤操作につながるため、可逆なWTF-8変換を使う（AOTのpathArgumentと同じ規則）。
    return foundation.pathBytesFromUtf16(runtime.allocator(), value.string.units);
}

fn statPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, follow: bool) !Value {
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
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.kind, try runtime.stringUtf8(metadata.kind.name()));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.size, try publicSizeValue(runtime, metadata.size));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mode, .{ .number = @floatFromInt(metadata.mode) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.uid, .{ .number = @floatFromInt(metadata.uid) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.gid, .{ .number = @floatFromInt(metadata.gid) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.dev, .{ .number = @floatFromInt(metadata.dev) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.rdev, .{ .number = @floatFromInt(metadata.rdev) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.inode, .{ .number = @floatFromInt(metadata.inode) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.nlink, .{ .number = @floatFromInt(metadata.nlink) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.block_size, .{ .number = @floatFromInt(metadata.block_size) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.blocks, .{ .number = @floatFromInt(metadata.blocks) });
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.atime_ns, try timeValue(runtime, metadata.atime_ns));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.mtime_ns, try timeValue(runtime, metadata.mtime_ns));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.ctime_ns, try timeValue(runtime, metadata.ctime_ns));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.stat_field_keys.birthtime_ns, try timeValue(runtime, metadata.birthtime_ns));
    return dictionary;
}

fn timeValue(runtime: *Runtime, nanoseconds: foundation.OptionalTimeNs) !Value {
    const value = nanoseconds orelse return .null_value;
    return runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), value));
}

fn symlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

fn readlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

fn hardlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

fn realpathPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

/// readlink/realpathが返すOSパス（WTF-8）を可逆になでしこ文字列へ戻す。
/// 孤立サロゲートを保持し、WTF-8として不正な任意バイト列（POSIXの非UTF-8名など）
/// は既存のlossy変換へフォールバックする。AOTのpathStringFromBytesと同じ規則。
fn pathStringFromBytes(runtime: *Runtime, bytes: []const u8) !Value {
    const units = foundation.pathUnitsFromBytes(runtime.allocator(), bytes) catch |failure| {
        if (failure != error.InvalidWtf8) return failure;
        return runtime.stringUtf8Lossy(bytes);
    };
    defer runtime.allocator().free(units);
    return runtime.stringCodeUnits(units);
}

fn renamePath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

fn unlinkPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.unlink;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.unlink(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .unlink);
    };
    return .undefined;
}

fn rmdirPath(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.filesystem_operations.rmdir;
    const path = try requirePath(runtime, effects, common.argument(arguments, 0), operation);
    defer runtime.allocator().free(path);
    context.rmdir(path) catch |failure| {
        return throwIo(runtime, effects, failure, operation, path, null, .rmdir);
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
    path2: ?[]const u8,
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
    // pathはWTF-8（孤立サロゲートを含み得る）なので、入力と同じ可逆変換で
    // 文字列化し、失敗した元のパスを呼び出し側が識別できるようにする。
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path, if (path) |value| try pathStringFromBytes(runtime, value) else .null_value);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path2, if (path2) |value| try pathStringFromBytes(runtime, value) else .null_value);
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.message, try runtime.stringUtf8(message));
    try shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.capability, if (capability) |value| try runtime.stringUtf8(value) else .null_value);
    return dictionary;
}

fn throwIo(
    runtime: *Runtime,
    effects: Effects,
    failure: anyerror,
    operation: []const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: foundation.Capability,
) anyerror {
    // メモリ不足はportable code（EINVAL等）へ丸めず、内部エラーとして
    // 伝播させる。構造化エラーのcodeはOSエラーだけを表す。
    if (failure == error.OutOfMemory) return failure;
    const code = foundation.portableCodeForFailure(failure) orelse .EINVAL;
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructuredAt(runtime, effects, code, operation, path, path2, capability_name, failureMessage(failure));
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
    return throwStructuredAt(runtime, effects, code, operation, path, null, capability, message);
}

fn throwStructuredAt(
    runtime: *Runtime,
    effects: Effects,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    var dictionary = buildError(runtime, code, operation, path, path2, capability, message) catch |failure| return failure;
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
        error.DirNotEmpty => "ディレクトリが空ではありません",
        error.CrossDevice => "ファイルシステムをまたぐ操作です",
        error.NotLink => "シンボリックリンクではありません",
        error.OperationUnsupported, error.UnsupportedReparsePointType, error.Unsupported, error.NotSupported => "この操作は対応していません",
        error.LinkQuotaExceeded => "リンク数の上限に達しました",
        error.NameTooLong => "名前が長すぎます",
        error.FileBusy => "ファイルが使用中です",
        error.InputOutput => "入出力エラーです",
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
    try std.testing.expectEqual(@as(usize, 40), covered);
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

/// Issue #29のパス操作を実OSで検証するためのContext。InterpreterのHostと同じ
/// `low_level_fs` 実装を共有し、dispatchと値組み立てだけを単体で検査する。
const FsTestHost = struct {
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

    fn context() Context {
        return .{
            .context = @ptrCast(&unused_context_host),
            .statFn = statCallback,
            .symlinkFn = symlinkCallback,
            .readlinkFn = readlinkCallback,
            .hardlinkFn = hardlinkCallback,
            .realpathFn = realpathCallback,
            .renameFn = renameCallback,
            .unlinkFn = unlinkCallback,
            .rmdirFn = rmdirCallback,
        };
    }
};

const HashHost = struct {
    table: low_level_hash.HashHandleTable,

    fn init(allocator: std.mem.Allocator) HashHost {
        return .{ .table = low_level_hash.HashHandleTable.init(allocator) };
    }

    fn deinit(self: *HashHost) void {
        self.table.deinit();
    }

    fn create(pointer: *anyopaque, algorithm: []const u8) anyerror!u64 {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        return (try self.table.insert(try low_level_hash.startNamed(algorithm))).raw();
    }

    fn update(pointer: *anyopaque, raw: u64, bytes: []const u8) anyerror!void {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        entry.hasher.update(bytes);
    }

    fn digest(pointer: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        var removed = self.table.remove(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return removed.hasher.finalize(allocator);
    }

    fn discard(pointer: *anyopaque, raw: u64) anyerror!void {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        _ = self.table.remove(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    }

    fn context(self: *HashHost) Context {
        return .{
            .context = self,
            .createHashFn = create,
            .updateHashFn = update,
            .digestHashFn = digest,
            .discardHashFn = discard,
        };
    }
};

fn thrownErrorCode(runtime: *Runtime, thrown: Value) ![]u8 {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    return shared.valueUtf8(runtime, code);
}

test "Interpreter低レイヤーのincremental hashはchunk供給と完了後にEBADFになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);

    var chunk = try runtime.createBytes("a");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    chunk = try runtime.createBytes("b");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    chunk = try runtime.createBytes("c");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });

    var encoding = try runtime.stringUtf8("hex");
    try roots.protect(&encoding);
    var result = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
    try roots.protect(&result);
    const text = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", text);

    // 完了後のhandleは破棄済みで、追加も再完了もEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk }));
    const update_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(update_code);
    try std.testing.expectEqualStrings("EBADF", update_code);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ完了", &.{handle}));
    const digest_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(digest_code);
    try std.testing.expectEqualStrings("EBADF", digest_code);
}

test "Interpreter低レイヤーのハッシュ破棄は二重破棄と偽造handleをEBADFにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    _ = try call(&runtime, &state, context, effects, "ハッシュ破棄", &.{handle});
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ破棄", &.{handle}));
    const discard_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(discard_code);
    try std.testing.expectEqualStrings("EBADF", discard_code);

    // 同じ形の辞書を手作りしてもhandle tableに載らずEBADF。
    var forged = try runtime.createDictionary();
    try roots.protect(&forged);
    var forged_bytes = try runtime.createBytes("x");
    try roots.protect(&forged_bytes);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ forged, forged_bytes }));
    const forged_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(forged_code);
    try std.testing.expectEqualStrings("EBADF", forged_code);
}

test "Interpreter低レイヤーのハッシュ開始は未知をEINVAL、RIPEMDをENOTSUPにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var unknown = try runtime.stringUtf8("crc32");
    try roots.protect(&unknown);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ開始", &.{unknown}));
    const unknown_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(unknown_code);
    try std.testing.expectEqualStrings("EINVAL", unknown_code);

    thrown = .undefined;
    var ripemd = try runtime.stringUtf8("ripemd160");
    try roots.protect(&ripemd);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ開始", &.{ripemd}));
    const ripemd_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(ripemd_code);
    try std.testing.expectEqualStrings("ENOTSUP", ripemd_code);

    // substring bytesはBuffer kindだけを受け付ける。
    thrown = .undefined;
    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var uint8_array = try runtime.createUint8Array("abc");
    try roots.protect(&uint8_array);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, uint8_array }));
    const bytes_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(bytes_code);
    try std.testing.expectEqualStrings("EINVAL", bytes_code);
}

test "Interpreter低レイヤーのincremental_hash対応判定は全callbackでtrue" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var name = try runtime.stringUtf8("incremental_hash");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, host.context(), effects, foundation.capability_supported_command, &.{name})).?;
    try std.testing.expect(supported == .boolean and supported.boolean);
    const unsupported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})).?;
    try std.testing.expect(unsupported == .boolean and !unsupported.boolean);
}

test "Interpreter低レイヤーのハッシュ完了はencoding省略でraw bytesを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var chunk = try runtime.createBytes("abc");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });

    // ENCODING省略はraw bytes。
    var raw = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{handle})).?;
    try roots.protect(&raw);
    try std.testing.expect(raw == .bytes);
    var hex_buffer: [32]u8 = undefined;
    const raw_hex = std.fmt.bufPrint(&hex_buffer, "{x}", .{raw.bytes.bytes}) catch unreachable;
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", raw_hex);

    // 未知encodingはEINVAL。
    var algorithm2 = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm2);
    var handle2 = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm2})).?;
    try roots.protect(&handle2);
    var bad_encoding = try runtime.stringUtf8("base32");
    try roots.protect(&bad_encoding);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle2, bad_encoding }));
    const encoding_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(encoding_code);
    try std.testing.expectEqualStrings("EINVAL", encoding_code);
}

test "Interpreter低レイヤーのハッシュ開始は非文字列と数値をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "ハッシュ開始", &.{.{ .number = 1 }}));
    const code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualStrings("EINVAL", code);
}

test "Interpreter低レイヤーのハッシュはGC stress下でもhandleを保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var chunk = try runtime.createBytes("abc");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    var encoding = try runtime.stringUtf8("hex");
    try roots.protect(&encoding);
    var result = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
    try roots.protect(&result);
    const text = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", text);
}

test "Interpreter低レイヤーのハッシュ完了encodingはハッシュ値計算と一致する" {
    const plugin_crypto = @import("crypto.zig");
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var input = try runtime.createBytes("abc");
    try roots.protect(&input);
    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    for ([_][]const u8{ "hex", "base64", "base64url", "latin1", "binary", "utf8", "utf-8" }) |encoding_name| {
        var encoding = try runtime.stringUtf8(encoding_name);
        try roots.protect(&encoding);
        var expected = (try plugin_crypto.call(&runtime, null, "ハッシュ値計算", &.{ input, algorithm, encoding })).?;
        try roots.protect(&expected);
        const expected_text = try shared.valueUtf8(&runtime, expected);
        defer std.testing.allocator.free(expected_text);

        var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
        try roots.protect(&handle);
        _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, input });
        var actual = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
        try roots.protect(&actual);
        const actual_text = try shared.valueUtf8(&runtime, actual);
        defer std.testing.allocator.free(actual_text);
        try std.testing.expectEqualStrings(expected_text, actual_text);
    }
}

fn expectThrownCode(runtime: *Runtime, thrown: Value, expected: []const u8) !void {
    try std.testing.expect(thrown == .dictionary);
    const code = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn expectThrownField(runtime: *Runtime, thrown: Value, key: []const u8, expected: []const u8) !void {
    const field = shared.dictionaryGetAscii(thrown.dictionary, key) orelse return error.TestExpectedEqual;
    const text = try shared.valueUtf8(runtime, field);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings(expected, text);
}

/// 2引数命令の構造化エラーが `path`=第1引数、`path2`=第2引数を持つことを検査する。
fn expectThrownPathPair(
    runtime: *Runtime,
    thrown: Value,
    expected_code: []const u8,
    expected_operation: []const u8,
    expected_path: []const u8,
    expected_path2: []const u8,
) !void {
    try expectThrownCode(runtime, thrown, expected_code);
    try expectThrownField(runtime, thrown, foundation.error_object_keys.operation, expected_operation);
    try expectThrownField(runtime, thrown, foundation.error_object_keys.path, expected_path);
    try expectThrownField(runtime, thrown, foundation.error_object_keys.path2, expected_path2);
}

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
    const context = FsTestHost.context();

    var capability_name = try runtime.stringUtf8("stat");
    try roots.protect(&capability_name);
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{capability_name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);

    var result = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{path})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    const kind = shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const kind_text = try shared.valueUtf8(&runtime, kind);
    defer runtime.allocator().free(kind_text);
    try std.testing.expectEqualStrings("file", kind_text);
    const size = shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.size) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), size.number);
    const mtime = shared.dictionaryGetAscii(result.dictionary, foundation.stat_field_keys.mtime_ns) orelse return error.TestExpectedEqual;
    try std.testing.expect(mtime == .bigint);
    // カタログ typeSchemas.stat の全15フィールドが辞書に存在する。
    inline for (foundation.stat_field_key_list) |key| {
        try std.testing.expect(shared.dictionaryGetAscii(result.dictionary, key) != null);
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
    const context = FsTestHost.context();

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

test "新規capabilityはホスト関数が無い場合ENOTSUPを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var name = try runtime.stringUtf8("stat");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and !supported.boolean);

    var path = try runtime.stringUtf8("whatever");
    try roots.protect(&path);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル詳細情報取得", &.{path}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "stat");
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
    const context = FsTestHost.context();

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
    const error_path = shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.path) orelse return error.TestExpectedEqual;
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
    const context = FsTestHost.context();

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
    const context = FsTestHost.context();

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
    const link_kind = shared.dictionaryGetAscii(link_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const link_kind_text = try shared.valueUtf8(&runtime, link_kind);
    defer runtime.allocator().free(link_kind_text);
    try std.testing.expectEqualStrings("symlink", link_kind_text);

    var followed_info = (try call(&runtime, &state, context, effects, "ファイル詳細情報取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&followed_info);
    const followed_kind = shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.kind) orelse return error.TestExpectedEqual;
    const followed_kind_text = try shared.valueUtf8(&runtime, followed_kind);
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
    const nlink = shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.nlink) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 2), nlink.number);
    const hard_inode = shared.dictionaryGetAscii(hard_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    const target_inode = shared.dictionaryGetAscii(followed_info.dictionary, foundation.stat_field_keys.inode) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(target_inode.number, hard_inode.number);

    var destination = (try call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&destination);
    const destination_text = try shared.valueUtf8(&runtime, destination);
    defer runtime.allocator().free(destination_text);
    try std.testing.expectEqualStrings(target_path, destination_text);

    // 非symlinkへのreadlinkはEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "シンボリックリンク先取得", &.{target}));
    try roots.protect(&thrown);
    try expectThrownCode(&runtime, thrown, "EINVAL");

    var resolved = (try call(&runtime, &state, context, effects, "実体パス取得", &.{link})) orelse return error.TestExpectedEqual;
    try roots.protect(&resolved);
    const resolved_text = try shared.valueUtf8(&runtime, resolved);
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
