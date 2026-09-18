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

/// 構造化エラーを例外として投げるためのコールバック。Interpreterが
/// `exception_value` に辞書を設定して `error.NakoException` を返す。
pub const Effects = struct {
    context: *anyopaque,
    throwFn: *const fn (context: *anyopaque, value: Value) anyerror!void,

    pub fn throw(self: Effects, value: Value) !void {
        return self.throwFn(self.context, value);
    }
};

pub const read_chunk_bytes: usize = 64 * 1024;

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

pub fn forgetHandle(state: *State, value: Value) void {
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

pub fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value) {
        .number => |number| foundation.sizeFromNumber(number),
        .bigint => |bigint| foundation.sizeFromUnsigned(bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
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
