const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const aot_shared = @import("../shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_io = @import("../../low_level_io.zig");
const low_level_hash = @import("../../low_level_hash.zig");
const low_level_fs = @import("../../low_level_fs.zig");
const low_level_dir = @import("../../low_level_dir.zig");
const low_level_context = @import("../../low_level/context.zig");
const low_level_process = @import("../../low_level_process.zig");

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
pub const dictionaryOwnProperty = state.dictionaryOwnProperty;
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

pub fn processTable(runtime: *Runtime) *low_level_process.ProcessTable {
    if (runtime.low_level_process_handles == null) {
        runtime.low_level_process_handles = low_level_process.ProcessTable.init(runtime.allocator);
    }
    return &runtime.low_level_process_handles.?;
}

/// プロセスspawn/waitが使うIoを保証する。AOTの `process_io` は
/// `lnako_aot_runtime_init` でも初期化されるが、単体テストはRuntimeを
/// 直接生成するため、初回にここでThreadedを用意する。`global_single_threaded`
/// はfailing allocatorでspawnできないため使わない。
pub fn ensureProcessIo(runtime: *Runtime) std.Io {
    if (!runtime.process_io_initialized) {
        runtime.process_io = std.Io.Threaded.init(runtime.allocator, .{ .environ = state.aotProcessEnvironment() });
        runtime.process_io_initialized = true;
    }
    return runtime.process_io.io();
}

pub fn dirTable(runtime: *Runtime) *low_level_dir.DirHandleTable {
    if (runtime.low_level_dir_handles == null) {
        runtime.low_level_dir_handles = low_level_dir.DirHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_dir_handles.?;
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
    return foundation.capabilitySupportedOnCurrentOs(capability);
}

pub fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value.tag) {
        @intFromEnum(Tag.number) => foundation.sizeFromNumber(valueToNumber(value)),
        @intFromEnum(Tag.bigint) => foundation.sizeFromUnsigned(value.object().?.payload.bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

/// lseek系のOFFSET引数。安全整数Numberまたはi64範囲のBigInt。
/// 契約外は `error.InvalidOffset` を返し、呼び出し側が構造化EINVALへ写す。
pub fn offsetArgument(_: *Runtime, value: Value) !i64 {
    return switch (value.tag) {
        @intFromEnum(Tag.number) => foundation.offsetFromNumber(valueToNumber(value)),
        @intFromEnum(Tag.bigint) => foundation.offsetFromSigned(value.object().?.payload.bigint.toI128() catch return error.InvalidOffset),
        else => error.InvalidOffset,
    };
}

/// lseek系の戻りoffsetを公開表現へ写す。安全整数はNumber、超過分はBigInt。
pub fn publicOffsetValue(runtime: *Runtime, offset: i64) !Value {
    return switch (foundation.publicOffset(offset)) {
        .number => numberValue(@floatFromInt(offset)),
        .bigint => runtime.ownBigInt(try BigInt.init(runtime.allocator, offset)),
    };
}

/// mode/umask等の上限付きu32引数。安全整数Numberまたはu32範囲のBigIntを
/// `0..=max` へ検証する。契約外は `operation` を載せた構造化EINVALを投げる。
/// posix系（chmod/access/umask）とreflinkのMODEが共有する。
pub fn unsignedArgument(runtime: *Runtime, value: Value, operation: []const u8, max: u32, message: []const u8) !u32 {
    var signed: i128 = undefined;
    switch (value.tag) {
        @intFromEnum(Tag.number) => {
            const number = valueToNumber(value);
            if (!foundation.isSafeInteger(number)) {
                return throwStructured(runtime, .EINVAL, operation, null, null, message);
            }
            signed = @intFromFloat(number);
        },
        @intFromEnum(Tag.bigint) => {
            signed = value.object().?.payload.bigint.toI128() catch {
                return throwStructured(runtime, .EINVAL, operation, null, null, message);
            };
        },
        else => return throwStructured(runtime, .EINVAL, operation, null, null, message),
    }
    if (signed < 0 or signed > @as(i128, max)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, message);
    }
    return @intCast(signed);
}

/// `ファイル時刻設定` / `ファイル時刻設定済` のATIME/MTIME引数を `SetTime` 契約へ
/// 変換する。nullは既存値維持、文字列 `"now"` は現在時刻、Number/BigIntは
/// ナノ秒の明示値。契約外は `operation` を載せた `EINVAL` を投げる。
pub fn setTimeArgument(runtime: *Runtime, value: Value, operation: []const u8) anyerror!foundation.SetTime {
    return switch (value.tag) {
        @intFromEnum(Tag.null_value) => .unchanged,
        @intFromEnum(Tag.number) => .{ .at = foundation.timeNsFromNumber(valueToNumber(value)) catch
            return throwStructured(runtime, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります") },
        @intFromEnum(Tag.bigint) => .{ .at = value.object().?.payload.bigint.toI128() catch
            return throwStructured(runtime, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります") },
        @intFromEnum(Tag.static_utf8_string), @intFromEnum(Tag.utf16_string) => if (isNowValue(value))
            .now
        else
            return throwStructured(runtime, .EINVAL, operation, null, null, "時刻はナノ秒の整数か\"now\"である必要があります"),
        else => return throwStructured(runtime, .EINVAL, operation, null, null, "時刻はナノ秒の整数である必要があります"),
    };
}

fn isNowValue(value: Value) bool {
    return switch (value.tag) {
        @intFromEnum(Tag.static_utf8_string) => std.mem.eql(u8, staticUtf8(value), "now"),
        @intFromEnum(Tag.utf16_string) => blk: {
            const units = value.object().?.payload.utf16_string;
            break :blk units.len == 3 and units[0] == 'n' and units[1] == 'o' and units[2] == 'w';
        },
        else => false,
    };
}

/// なでしこ文字列のpath引数を可逆なWTF-8（孤立サロゲート保持）へ変換する。
/// 非文字列は構造化EINVALを投げる。fs/posixドメインで共有する。
pub fn pathArgument(runtime: *Runtime, value: Value, operation: []const u8) ![]u8 {
    if (!isString(value)) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return foundation.pathBytesFromUtf16(runtime.allocator, units);
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

/// `プロセス起動` 専用。spawnの契約エラー集合
/// (ENOENT/EACCES/EPERM/EINVAL/ENOTSUP) に限定し、fd枯渇などの未写像失敗は
/// EINVALへ丸める。OOMは内部エラーとして伝播する。
pub fn throwSpawnIo(runtime: *Runtime, failure: anyerror, operation: []const u8, capability: foundation.Capability) anyerror {
    if (failure == error.OutOfMemory) return failure;
    const code = foundation.portableCodeForSpawnFailure(failure);
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructured(runtime, code, operation, null, capability_name, failureMessage(failure));
}

/// OS失敗を呼び出し側が選んだportable codeへ写す。コマンド契約が許すcodeを
/// EBADF/EINVAL/ENOTSUP等へ限定したいときに使う（Interpreterと同じ契約）。
/// `path` は失敗対象（無ければnull）。OOMは内部エラーとして伝播する。
pub fn throwIoMapped(
    runtime: *Runtime,
    failure: anyerror,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: foundation.Capability,
) anyerror {
    if (failure == error.OutOfMemory) return failure;
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructured(runtime, code, operation, path, capability_name, failureMessage(failure));
}

/// `throwIoMapped` の2パス版。SRC/DSTを持つ命令（reflink等）が
/// コマンド契約のcodeへ丸めつつ `path` と `path2` の両方をエラーへ載せる。
/// OOMは内部エラーとして伝播する。
pub fn throwIoMappedPair(
    runtime: *Runtime,
    failure: anyerror,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    path2: ?[]const u8,
    capability: foundation.Capability,
) anyerror {
    if (failure == error.OutOfMemory) return failure;
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructuredAt(runtime, code, operation, path, path2, capability_name, failureMessage(failure));
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
        error.InvalidTimestamp => "時刻が不正です",
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
