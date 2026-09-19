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

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const Dictionary = value_mod.Dictionary;

/// handle表本体はAOTのdynamic bridgeも共有するため共通基盤層が所有する。
/// 既存のプラグイン内参照のためここから再エクスポートする。
pub const low_level_state = @import("../../runtime/low_level/state.zig");
pub const State = low_level_state.State;
pub const lookupHandle = low_level_state.lookupHandle;
pub const handleForId = low_level_state.handleForId;
pub const rememberHandle = low_level_state.rememberHandle;
pub const forgetHandle = low_level_state.forgetHandle;
pub const forgetHandleId = low_level_state.forgetHandleId;

/// 構造化エラーを例外として投げるためのコールバック。Interpreterが
/// `exception_value` に辞書を設定して `error.NakoException` を返す。
/// `invokeFn` / `resolveFn` は `ディレクトリ列挙時` のコールバック実行に使う。
/// Hostが提供しない場合は未設定（null）で、糖衣命令はENOTSUP相当の失敗になる。
pub const Effects = struct {
    context: *anyopaque,
    throwFn: *const fn (context: *anyopaque, value: Value) anyerror!void,
    invokeFn: ?*const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value = null,
    resolveFn: ?*const fn (context: *anyopaque, value: Value) anyerror!Value = null,

    pub fn throw(self: Effects, value: Value) !void {
        return self.throwFn(self.context, value);
    }

    pub fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        const function = self.invokeFn orelse return error.CallbackExecutionUnavailable;
        return function(self.context, callable, arguments);
    }

    /// 関数値または関数名（文字列）を呼び出し可能な値へ解決する。
    pub fn resolve(self: Effects, value: Value) !Value {
        const function = self.resolveFn orelse return error.CallbackExecutionUnavailable;
        return function(self.context, value);
    }
};

pub const read_chunk_bytes: usize = 64 * 1024;

pub fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value) {
        .number => |number| foundation.sizeFromNumber(number),
        .bigint => |bigint| foundation.sizeFromUnsigned(bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

/// pid/signalのようなu32値。安全整数Numberまたはu32範囲のBigIntだけを受け付ける。
pub fn u32Argument(value: Value) !u32 {
    return switch (value) {
        .number => |number| blk: {
            if (!foundation.isSafeInteger(number)) return error.InvalidInteger;
            if (number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidInteger;
            break :blk @intFromFloat(number);
        },
        .bigint => |bigint| blk: {
            const integer = bigint.toU128() catch return error.InvalidInteger;
            if (integer > std.math.maxInt(u32)) return error.InvalidInteger;
            break :blk @intCast(integer);
        },
        else => error.InvalidInteger,
    };
}

/// priority値のようなi32値。安全整数Numberまたはi32範囲のBigIntだけを受け付ける。
pub fn i32Argument(value: Value) !i32 {
    return switch (value) {
        .number => |number| blk: {
            if (!foundation.isSafeInteger(number)) return error.InvalidInteger;
            if (number < @as(f64, @floatFromInt(std.math.minInt(i32))) or
                number > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return error.InvalidInteger;
            break :blk @intFromFloat(number);
        },
        .bigint => |bigint| blk: {
            const integer = bigint.toI128() catch return error.InvalidInteger;
            if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32)) return error.InvalidInteger;
            break :blk @intCast(integer);
        },
        else => error.InvalidInteger,
    };
}

pub fn bytesArgument(runtime: *Runtime, value: Value) ![]const u8 {
    if (value != .bytes) return error.InvalidBytes;
    if (value.bytes.kind != .buffer) return error.InvalidBytes;
    _ = runtime;
    return value.bytes.bytes;
}

pub fn publicSizeValue(runtime: *Runtime, size: u64) !Value {
    return switch (foundation.publicSize(size)) {
        .number => .{ .number = @floatFromInt(size) },
        .bigint => runtime.ownBigInt(try value_mod.BigInt.init(runtime.allocator(), size)),
    };
}

/// readlink/realpathが返すOSパス（WTF-8）を可逆になでしこ文字列へ戻す。
/// 孤立サロゲートを保持し、WTF-8として不正な任意バイト列（POSIXの非UTF-8名など）
/// は既存のlossy変換へフォールバックする。fs/AOTの同名処理と同じ規則。
pub fn pathStringFromBytes(runtime: *Runtime, bytes: []const u8) !Value {
    const units = foundation.pathUnitsFromBytes(runtime.allocator(), bytes) catch |failure| {
        if (failure != error.InvalidWtf8) return failure;
        return runtime.stringUtf8Lossy(bytes);
    };
    defer runtime.allocator().free(units);
    return runtime.stringCodeUnits(units);
}

/// なでしこ文字列のpath引数を可逆なWTF-8（孤立サロゲート保持）へ変換する。
/// lossy変換は孤立サロゲートをU+FFFDへ化けさせ、実在する同名ファイルへの誤操作を
/// 招くため、非文字列は構造化EINVALにする。fs/posixドメインで共有する。
pub fn pathArgument(runtime: *Runtime, effects: Effects, value: Value, operation: []const u8) ![]u8 {
    if (value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "pathは文字列である必要があります");
    }
    return foundation.pathBytesFromUtf16(runtime.allocator(), value.string.units);
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
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.code, try runtime.stringUtf8(code.name()));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.native_code, .null_value);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.operation, try runtime.stringUtf8(operation));
    // pathはWTF-8（孤立サロゲートを含み得る）なので、入力と同じ可逆変換で
    // 文字列化し、失敗した元のパスを呼び出し側が識別できるようにする。
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path, if (path) |value| try pathStringFromBytes(runtime, value) else .null_value);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.path2, if (path2) |value| try pathStringFromBytes(runtime, value) else .null_value);
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.message, try runtime.stringUtf8(message));
    try node_shared.setDictionary(runtime, dictionary.dictionary, foundation.error_object_keys.capability, if (capability) |value| try runtime.stringUtf8(value) else .null_value);
    return dictionary;
}

pub fn throwIo(
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

/// path2を取らないI/O失敗の薄いラッパー。
pub fn throwIoAs(runtime: *Runtime, effects: Effects, failure: anyerror, operation: []const u8, path: ?[]const u8, capability: foundation.Capability) anyerror {
    return throwIo(runtime, effects, failure, operation, path, null, capability);
}

/// `プロセス起動` 専用。spawnの契約エラー集合
/// (ENOENT/EACCES/EPERM/EINVAL/ENOTSUP) に限定し、fd枯渇などの未写像失敗は
/// EINVALへ丸める。OOMは内部エラーとして伝播する。
pub fn throwSpawnIo(runtime: *Runtime, effects: Effects, failure: anyerror, operation: []const u8, capability: foundation.Capability) anyerror {
    if (failure == error.OutOfMemory) return failure;
    const code = foundation.portableCodeForSpawnFailure(failure);
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructuredAt(runtime, effects, code, operation, null, null, capability_name, failureMessage(failure));
}

/// OS失敗を呼び出し側が選んだportable codeへ写す。コマンド契約が許すcodeを
/// EBADF/EINVAL/ENOTSUP等へ限定したいときに使う（汎用写像のEACCES等を
/// コマンド固有の上限へ丸める）。`path` は失敗対象（無ければnull）。OOMは
/// 内部エラーとして伝播する。
pub fn throwIoMapped(
    runtime: *Runtime,
    effects: Effects,
    failure: anyerror,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: foundation.Capability,
) anyerror {
    if (failure == error.OutOfMemory) return failure;
    const capability_name: ?[]const u8 = if (code == .ENOTSUP) capability.id() else null;
    return throwStructured(runtime, effects, code, operation, path, capability_name, failureMessage(failure));
}

pub fn throwStructured(
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
        error.StreamTooLong => "標準入力が上限を超えました",
        else => @errorName(failure),
    };
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

pub fn expectThrownCode(runtime: *Runtime, thrown: Value, expected: []const u8) !void {
    try std.testing.expect(thrown == .dictionary);
    const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const text = try node_shared.valueUtf8(runtime, code);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings(expected, text);
}

pub fn captureThrow(context: *anyopaque, value: Value) !void {
    const captured: *Value = @ptrCast(@alignCast(context));
    captured.* = value;
}

pub fn thrownErrorCode(runtime: *Runtime, thrown: Value) ![]u8 {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    return node_shared.valueUtf8(runtime, code);
}

pub fn expectThrownField(runtime: *Runtime, thrown: Value, key: []const u8, expected: []const u8) !void {
    const field = node_shared.dictionaryGetAscii(thrown.dictionary, key) orelse return error.TestExpectedEqual;
    const text = try node_shared.valueUtf8(runtime, field);
    defer runtime.allocator().free(text);
    try std.testing.expectEqualStrings(expected, text);
}

/// 2引数命令の構造化エラーが `path`=第1引数、`path2`=第2引数を持つことを検査する。
pub fn expectThrownPathPair(
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
