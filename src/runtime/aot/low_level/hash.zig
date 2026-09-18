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

pub fn pluginCreateHash(context: *anyopaque, algorithm: []const u8) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const hasher = try low_level_hash.startNamed(algorithm);
    return (try hashTable(runtime).insert(hasher)).raw();
}

pub fn pluginUpdateHash(context: *anyopaque, raw: u64, bytes: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = hashTable(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    entry.hasher.update(bytes);
}

pub fn pluginDigestHash(context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    var removed = hashTable(runtime).remove(id) orelse return error.BadFileDescriptor;
    forgetHandleId(runtime, id);
    return removed.hasher.finalize(allocator);
}

pub fn pluginDiscardHash(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    _ = hashTable(runtime).remove(id) orelse return error.BadFileDescriptor;
    forgetHandleId(runtime, id);
}

pub fn hashCreateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1 or !isString(arguments[0])) {
        return throwStructured(runtime, .EINVAL, foundation.hash_operation, null, null, "アルゴリズム名は文字列である必要があります");
    }
    const algorithm = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(algorithm);
    const hasher = low_level_hash.startNamed(algorithm) catch |failure| {
        return throwHashFailure(runtime, failure);
    };
    const id = hashTable(runtime).insert(hasher) catch |failure| {
        return throwHashFailure(runtime, failure);
    };
    errdefer _ = hashTable(runtime).remove(id);
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    try rememberHandle(runtime, handle, id);
    return handle;
}

pub fn hashUpdateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, foundation.hash_operation, null, null, "追加する値はBytesである必要があります");
    }
    const bytes = bytesArgument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.hash_operation, null, null, "追加する値はBytesである必要があります");
    };
    const entry = hashTable(runtime).find(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    entry.hasher.update(bytes);
    return .{};
}

pub fn hashDigestBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    var encoding: low_level_hash.Encoding = .raw;
    if (arguments.len > 1 and arguments[1].tag != @intFromEnum(Tag.undefined) and arguments[1].tag != @intFromEnum(Tag.null_value)) {
        if (!isString(arguments[1])) {
            return throwStructured(runtime, .EINVAL, foundation.hash_operation, null, null, "encodingは文字列である必要があります");
        }
        const name = try valueUtf8LossyAlloc(runtime, arguments[1]);
        defer runtime.allocator.free(name);
        encoding = low_level_hash.Encoding.fromName(name) orelse {
            return throwStructured(runtime, .EINVAL, foundation.hash_operation, null, null, "未知のencodingです");
        };
    }
    var removed = hashTable(runtime).remove(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    // digestの成否に関わらずhandleは消費済みなので、先にidentity mappingを外す。
    forgetHandleId(runtime, id);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
    const digest = removed.hasher.finalize(runtime.allocator) catch |failure| {
        return throwHashFailure(runtime, failure);
    };
    defer runtime.allocator.free(digest);
    return encodeDigest(runtime, digest, encoding);
}

pub fn hashDiscardBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    _ = hashTable(runtime).remove(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    forgetHandleId(runtime, id);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
    return .{};
}

fn encodeDigest(runtime: *Runtime, digest: []const u8, encoding: low_level_hash.Encoding) !Value {
    switch (encoding) {
        .raw => return runtime.createBytes(digest),
        .hex => {
            const result = try runtime.allocator.alloc(u8, digest.len * 2);
            defer runtime.allocator.free(result);
            const text = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
            return runtimeUtf8String(runtime, text);
        },
        .base64, .base64url => {
            const result = try runtime.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
            defer runtime.allocator.free(result);
            _ = std.base64.standard.Encoder.encode(result, digest);
            if (encoding == .base64) return runtimeUtf8String(runtime, result);
            for (result) |*byte| byte.* = switch (byte.*) {
                '+' => '-',
                '/' => '_',
                else => byte.*,
            };
            var length = result.len;
            while (length > 0 and result[length - 1] == '=') length -= 1;
            return runtimeUtf8String(runtime, result[0..length]);
        },
        .latin1 => {
            const units = try runtime.allocator.alloc(u16, digest.len);
            defer runtime.allocator.free(units);
            for (digest, 0..) |byte, index| units[index] = byte;
            return runtime.createString(units);
        },
        .utf8 => return runtimeUtf8StringLossy(runtime, digest),
    }
}

fn throwHashFailure(runtime: *Runtime, failure: anyerror) anyerror {
    const code: foundation.PortableErrorCode = switch (failure) {
        error.UnsupportedHashAlgorithm => .EINVAL,
        error.IncrementalHashUnsupported, error.IncrementalHashUnavailable => .ENOTSUP,
        else => foundation.portableCodeForFailure(failure) orelse .EINVAL,
    };
    const capability = if (code == .ENOTSUP) foundation.Capability.incremental_hash.id() else null;
    return throwStructured(runtime, code, foundation.hash_operation, null, capability, hashFailureMessage(failure));
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

test "AOT低レイヤーのincremental hashは複数chunkと完了後EBADFを扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "sha256");
    const handle = try lowLevelHashBuiltin(&runtime, .low_level_hash_create, &.{roots[0]});
    roots[0] = handle;
    try std.testing.expectEqual(@as(u32, 1), runtime.low_level_handle_ids.size);

    for ([_][]const u8{ "a", "b", "c" }, 0..) |part, index| {
        roots[index + 1] = try runtime.createBytes(part);
        _ = try lowLevelHashBuiltin(&runtime, .low_level_hash_update, &.{ handle, roots[index + 1] });
    }

    roots[4] = try runtimeUtf8String(&runtime, "hex");
    const result = try lowLevelHashBuiltin(&runtime, .low_level_hash_digest, &.{ handle, roots[4] });
    const hex = try valueUtf8LossyAlloc(&runtime, result);
    defer runtime.allocator.free(hex);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);

    // 完了後はハッシュ表から外れ、追加も再完了もEBADF。
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_hash_handles.?.len());
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_update, &.{ handle, roots[1] }));
    try expectPendingCode(&runtime, "EBADF");
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_digest, &.{handle}));
    try expectPendingCode(&runtime, "EBADF");
}

test "AOT低レイヤーのハッシュ破棄は二重破棄をEBADFにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "md5");
    const handle = try lowLevelHashBuiltin(&runtime, .low_level_hash_create, &.{roots[0]});
    roots[0] = handle;
    _ = try lowLevelHashBuiltin(&runtime, .low_level_hash_discard, &.{handle});
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_discard, &.{handle}));
    try expectPendingCode(&runtime, "EBADF");
}

test "AOT低レイヤーのハッシュ開始は未知をEINVAL、RIPEMDをENOTSUPにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "crc32");
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_create, &.{roots[0]}));
    try expectPendingCode(&runtime, "EINVAL");
    const unknown_capability = dictionaryProperty(runtime.pending_exception, &.{ 'c', 'a', 'p', 'a', 'b', 'i', 'l', 'i', 't', 'y' });
    try std.testing.expectEqual(@intFromEnum(Tag.null_value), unknown_capability.tag);

    roots[0] = try runtimeUtf8String(&runtime, "ripemd160");
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_create, &.{roots[0]}));
    try expectPendingCode(&runtime, "ENOTSUP");
    const capability = dictionaryProperty(runtime.pending_exception, &.{ 'c', 'a', 'p', 'a', 'b', 'i', 'l', 'i', 't', 'y' });
    const capability_text = try valueUtf8LossyAlloc(&runtime, capability);
    defer runtime.allocator.free(capability_text);
    try std.testing.expectEqualStrings("incremental_hash", capability_text);
}

test "AOT低レイヤーのハッシュとファイルhandleは取り違えをEBADFにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aot-cross-kind.bin" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "aot-cross-kind.bin", .data = "abc" });

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, path);
    roots[1] = try runtimeUtf8String(&runtime, "rb");
    const file_handle = try lowLevelFileBuiltin(&runtime, .low_level_file_open, &.{ roots[0], roots[1] });
    roots[2] = file_handle;
    roots[3] = try runtimeUtf8String(&runtime, "md5");
    const hash_handle = try lowLevelHashBuiltin(&runtime, .low_level_hash_create, &.{roots[3]});
    var hash_roots = [_]Value{ hash_handle, .{} };
    var hash_frame: RootFrame = .{};
    runtime.pushRoots(&hash_frame, &hash_roots, hash_roots.len);
    defer runtime.popRoots(&hash_frame);
    hash_roots[1] = try runtime.createBytes("x");

    // ファイルhandleをハッシュ命令へ渡すとEBADF。ファイルhandleは有効なまま。
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_update, &.{ file_handle, hash_roots[1] }));
    try expectPendingCode(&runtime, "EBADF");
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_digest, &.{file_handle}));
    try expectPendingCode(&runtime, "EBADF");
    try std.testing.expectError(error.NakoException, lowLevelHashBuiltin(&runtime, .low_level_hash_discard, &.{file_handle}));
    try expectPendingCode(&runtime, "EBADF");
    _ = try lowLevelFileBuiltin(&runtime, .low_level_file_close, &.{file_handle});

    // ハッシュhandleをファイル命令へ渡すとEBADF。ハッシュhandleは有効なまま。
    try std.testing.expectError(error.NakoException, lowLevelFileBuiltin(&runtime, .low_level_file_close, &.{hash_handle}));
    try expectPendingCode(&runtime, "EBADF");
    _ = try lowLevelHashBuiltin(&runtime, .low_level_hash_discard, &.{hash_handle});
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
}
