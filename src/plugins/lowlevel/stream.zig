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
const emptyContext = low_level_context.emptyContext;

const throwStructured = shared.throwStructured;
const throwIo = shared.throwIo;
const throwIoMapped = shared.throwIoMapped;
const lookupHandle = shared.lookupHandle;
const forgetHandle = shared.forgetHandle;
const rememberHandle = shared.rememberHandle;
const sizeArgument = shared.sizeArgument;
const offsetArgument = shared.offsetArgument;
const bytesArgument = shared.bytesArgument;
const publicSizeValue = shared.publicSizeValue;
const publicOffsetValue = shared.publicOffsetValue;
const read_chunk_bytes = shared.read_chunk_bytes;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;

pub fn openFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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
        mode_text = try node_shared.valueUtf8(runtime, mode_value);
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

pub fn closeFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

pub fn readBytes(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

pub fn writeBytes(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

pub fn syncFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    context.syncFile(id.raw()) catch |failure| {
        return throwIo(runtime, effects, failure, foundation.stream_operations.fsync, null, null, .stream_file_io);
    };
    return .undefined;
}

pub fn truncateFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
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

/// `ファイルデータ領域検索`（SEEK_DATA相当）。offset以降のデータ位置を返す。
pub fn seekData(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    return seekExtentFile(runtime, state, context, effects, arguments, .data);
}

/// `ファイル空洞領域検索`（SEEK_HOLE相当）。offset以降の空洞位置を返す。
pub fn seekHole(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    return seekExtentFile(runtime, state, context, effects, arguments, .hole);
}

fn seekExtentFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value, extent: low_level_fs.SeekExtent) !Value {
    const operation = foundation.stream_operations.lseek;
    const capability: foundation.Capability = if (extent == .data) .seek_data else .seek_hole;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    const offset = offsetArgument(common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "検索位置が不正です");
    };
    const result = (if (extent == .data)
        context.seekDataFile(id.raw(), offset)
    else
        context.seekHoleFile(id.raw(), offset)) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.seekErrorCode(failure), operation, null, capability);
    };
    return publicOffsetValue(runtime, result);
}

/// `ファイル領域確保`（fallocate相当）。offsetからsizeバイトを事前確保する。
pub fn allocateFile(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const operation = foundation.stream_operations.fallocate;
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, operation, null, null, "無効なハンドルです");
    };
    const offset = offsetArgument(common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "確保位置が不正です");
    };
    const size = sizeArgument(runtime, common.argument(arguments, 2)) catch {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "確保する大きさが不正です");
    };
    context.allocateFile(id.raw(), offset, size) catch |failure| {
        return throwIoMapped(runtime, effects, failure, foundation.fallocateErrorCode(failure), operation, null, .fallocate);
    };
    return .undefined;
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
    const path_code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const path_text = try node_shared.valueUtf8(&runtime, path_code);
    defer runtime.allocator().free(path_text);
    try std.testing.expectEqualStrings("EINVAL", path_text);

    var path = try runtime.stringUtf8("missing.txt");
    try roots.protect(&path);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ファイル開", &.{ path, .{ .number = 1 } }));
    try std.testing.expect(thrown == .dictionary);
    try roots.protect(&thrown);
    const mode_code = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.code) orelse return error.TestExpectedEqual;
    const mode_text = try node_shared.valueUtf8(&runtime, mode_code);
    defer runtime.allocator().free(mode_text);
    try std.testing.expectEqualStrings("EINVAL", mode_text);
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
    const context = Context{ .stream = .{ .context = @ptrCast(&host), .readFileBytesFn = ShortReadHost.read } };
    var result = (try call(&runtime, &state, context, effects, "ファイルバイト読", &.{ handle, .{ .number = 65536 } })) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(&runtime, result));
}
