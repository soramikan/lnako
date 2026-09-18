const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const aot_shared = @import("../shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_io = @import("../../low_level_io.zig");
const low_level_hash = @import("../../low_level_hash.zig");
const low_level_fs = @import("../../low_level_fs.zig");
const low_level_context = @import("../../low_level/context.zig");

pub const aot_builtin = aot_shared.aot_builtin;
pub const BigInt = aot_shared.BigInt;

pub const Runtime = state.Runtime;
pub const Value = state.Value;
pub const Object = state.Object;
pub const Tag = state.Tag;
pub const RootFrame = state.RootFrame;
pub const numberValue = state.numberValue;
pub const valueToNumber = state.valueToNumber;
pub const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
pub const valueUtf16Alloc = state.valueUtf16Alloc;
pub const runtimeUtf8String = state.runtimeUtf8String;
pub const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
pub const aotRuntimeIo = state.aotRuntimeIo;
pub const staticUtf8 = state.staticUtf8;
pub const isString = state.isString;
pub const dictionaryProperty = state.dictionaryProperty;
pub const fflush = state.fflush;
pub const read_chunk_bytes: usize = 64 * 1024;

pub fn io(runtime: *Runtime) std.Io {
    return aotRuntimeIo(runtime);
}

pub fn table(runtime: *Runtime) *low_level_io.FileHandleTable {
    if (runtime.low_level_handles == null) {
        runtime.low_level_handles = low_level_io.FileHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_handles.?;
}

pub fn hashTable(runtime: *Runtime) *low_level_hash.HashHandleTable {
    if (runtime.low_level_hash_handles == null) {
        runtime.low_level_hash_handles = low_level_hash.HashHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_hash_handles.?;
}

pub fn handleIdFor(runtime: *Runtime, value: Value) ?foundation.HandleId {
    return findHandleId(runtime, value);
}

pub fn handleValueForId(runtime: *Runtime, id: foundation.HandleId) ?Value {
    const pointer = runtime.low_level_handle_by_id.get(id.raw()) orelse return null;
    return .{ .tag = @intFromEnum(Tag.dictionary), .payload = pointer };
}

pub fn rememberHandle(runtime: *Runtime, value: Value, id: foundation.HandleId) !void {
    const object = value.object() orelse return error.InvalidHandle;
    const pointer = @intFromPtr(object);
    try runtime.low_level_handle_ids.put(runtime.allocator, pointer, id.raw());
    errdefer _ = runtime.low_level_handle_ids.remove(pointer);
    try runtime.low_level_handle_by_id.put(runtime.allocator, id.raw(), pointer);
}

pub fn forgetHandleId(runtime: *Runtime, id: foundation.HandleId) void {
    if (runtime.low_level_handle_by_id.fetchRemove(id.raw())) |entry| {
        _ = runtime.low_level_handle_ids.remove(entry.value);
    }
}

/// ハンドル値（AOT辞書）の同一性から `HandleId` を探す。偽造辞書や
/// close済みハンドルは `null` になる。
pub fn findHandleId(runtime: *Runtime, value: Value) ?foundation.HandleId {
    const object = value.object() orelse return null;
    const raw = runtime.low_level_handle_ids.get(@intFromPtr(object)) orelse return null;
    return foundation.HandleId.fromRaw(raw);
}

pub fn forgetHandle(runtime: *Runtime, value: Value) void {
    if (findHandleId(runtime, value)) |id| forgetHandleId(runtime, id);
}

pub fn fileFor(runtime: *Runtime, value: Value) ?*low_level_io.OpenHandle {
    const id = findHandleId(runtime, value) orelse return null;
    return table(runtime).find(id);
}

/// readlink/realpathが返すOSパス（WTF-8）を可逆になでしこ文字列へ戻す。
/// 孤立サロゲートを保持し、WTF-8として不正な任意バイト列は既存のlossy変換へ
/// フォールバックする。InterpreterのpathStringFromBytesと同じ規則。
pub fn pathStringFromBytes(runtime: *Runtime, bytes: []const u8) !Value {
    const units = foundation.pathUnitsFromBytes(runtime.allocator, bytes) catch |failure| {
        if (failure != error.InvalidWtf8) return failure;
        return runtimeUtf8StringLossy(runtime, bytes);
    };
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn capabilitySupported(value: Value) bool {
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

pub fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value.tag) {
        @intFromEnum(Tag.number) => foundation.sizeFromNumber(valueToNumber(value)),
        @intFromEnum(Tag.bigint) => foundation.sizeFromUnsigned(value.object().?.payload.bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

pub fn bytesArgument(value: Value) ![]const u8 {
    if (value.tag != @intFromEnum(Tag.byte_buffer)) return error.InvalidBytes;
    const buffer = value.object().?.payload.byte_buffer;
    if (buffer.kind != .buffer) return error.InvalidBytes;
    return buffer.bytes;
}

pub fn publicSizeValue(runtime: *Runtime, size: u64) !Value {
    return switch (foundation.publicSize(size)) {
        .number => numberValue(@floatFromInt(size)),
        .bigint => runtime.ownBigInt(try BigInt.init(runtime.allocator, size)),
    };
}

pub fn setField(runtime: *Runtime, dictionary: Value, name: []const u8, value: Value) !void {
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
    path2: ?[]const u8,
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
    // pathはWTF-8（孤立サロゲートを含み得る）なので、入力と同じ可逆変換で
    // 文字列化し、失敗した元のパスを呼び出し側が識別できるようにする。
    try setField(runtime, result, foundation.error_object_keys.path, if (path) |value| try pathStringFromBytes(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.path2, if (path2) |value| try pathStringFromBytes(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.message, try runtimeUtf8String(runtime, message));
    try setField(runtime, result, foundation.error_object_keys.capability, if (capability) |value| try runtimeUtf8String(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    // 構造化エラー印。`["code"]` 等のフィールド参照と、文字列化＝`message`
    // の両方を可能にする。通常辞書の `message` キーとは区別される。
    if (result.object()) |object| object.structured_error = true;
    return result;
}

pub fn throwIo(
    runtime: *Runtime,
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
    return throwStructuredAt(runtime, code, operation, path, path2, capability_name, failureMessage(failure));
}

/// path2を取らないI/O失敗の薄いラッパー（`plugins/lowlevel.zig` と同じ契約）。
pub fn throwIoAs(runtime: *Runtime, failure: anyerror, operation: []const u8, path: ?[]const u8, capability: foundation.Capability) anyerror {
    return throwIo(runtime, failure, operation, path, null, capability);
}

pub fn throwStructured(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    return throwStructuredAt(runtime, code, operation, path, null, capability, message);
}

fn throwStructuredAt(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    var dictionary = buildError(runtime, code, operation, path, path2, capability, message) catch |failure| return failure;
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&dictionary), 1);
    defer runtime.popRoots(&roots);
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
        error.DirNotEmpty => "ディレクトリが空ではありません",
        error.CrossDevice => "ファイルシステムをまたぐ操作です",
        error.NotLink => "シンボリックリンクではありません",
        error.OperationUnsupported, error.UnsupportedReparsePointType, error.Unsupported, error.NotSupported => "この操作は対応していません",
        error.LinkQuotaExceeded => "リンク数の上限に達しました",
        error.NameTooLong => "名前が長すぎます",
        error.FileBusy => "ファイルが使用中です",
        error.InputOutput => "入出力エラーです",
        error.StreamTooLong => "標準入力が上限を超えました",
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

pub fn aotThrownCode(runtime: *Runtime) ![]u8 {
    try std.testing.expect(runtime.has_pending_exception);
    const exception = runtime.takeException();
    const code = state.dictionaryOwnProperty(exception, &.{ 'c', 'o', 'd', 'e' }) orelse return error.TestExpectedEqual;
    return valueUtf8LossyAlloc(runtime, code);
}

pub fn pendingErrorCode(runtime: *Runtime) ![]u8 {
    try std.testing.expect(runtime.has_pending_exception);
    const code = dictionaryProperty(runtime.pending_exception, &.{ 'c', 'o', 'd', 'e' });
    return valueUtf8LossyAlloc(runtime, code);
}

pub fn expectPendingCode(runtime: *Runtime, expected: []const u8) !void {
    const code = try pendingErrorCode(runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings(expected, code);
}
