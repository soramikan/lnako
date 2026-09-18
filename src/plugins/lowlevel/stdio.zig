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
const throwIoAs = shared.throwIoAs;
const sizeArgument = shared.sizeArgument;
const bytesArgument = shared.bytesArgument;
const publicSizeValue = shared.publicSizeValue;

const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;

/// `標準入力バイト読む`。共有sourceから最大SIZEバイトを1回のfillで
/// 返す。0バイトはEOF、SIZE未満の非0は部分読取り。Buffer-kind以外の
/// 値では読まずにEINVAL。
pub fn stdinRead(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    const size = sizeArgument(runtime, common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, "read", null, null, "読み込む大きさが不正です");
    };
    const source = context.stdinSource(runtime.allocator()) catch |failure| {
        return throwIoAs(runtime, effects, failure, "read", null, .raw_stdio);
    };
    // 1呼出しの返却は1fillぶんまで。巨大SIZEの一括確保によるOOMを避けるため
    // fill上限で切り詰める（部分読取りは契約上許容）。
    const length: usize = @intCast(@min(size, low_level_io.stdin_fill_bytes));
    const buffer = try runtime.allocator().alloc(u8, length);
    defer runtime.allocator().free(buffer);
    const read = source.read(buffer) catch |failure| {
        return throwIoAs(runtime, effects, failure, "read", null, .raw_stdio);
    };
    return runtime.createBytes(buffer[0..read]);
}

pub fn stdoutWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    return rawWrite(runtime, context, effects, arguments, false);
}

pub fn stderrWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value) !Value {
    return rawWrite(runtime, context, effects, arguments, true);
}

/// `標準出力バイト書く`/`標準エラー出力バイト書く`。Bytes値をUTF-8変換や
/// NUL終端を挟まずfdへ直接書き、実際に書けたバイト数を返す。
fn rawWrite(runtime: *Runtime, context: Context, effects: Effects, arguments: []const Value, to_stderr: bool) !Value {
    const bytes = bytesArgument(runtime, common.argument(arguments, 0)) catch {
        return throwStructured(runtime, effects, .EINVAL, "write", null, null, "書き込む値はBytesである必要があります");
    };
    const written = (if (to_stderr) context.writeStderrBytes(bytes) else context.writeStdoutBytes(bytes)) catch |failure| {
        return throwIoAs(runtime, effects, failure, "write", null, .raw_stdio);
    };
    return publicSizeValue(runtime, written);
}

pub fn stdoutSync(runtime: *Runtime, context: Context, effects: Effects) !Value {
    context.syncStdout() catch |failure| {
        return throwIoAs(runtime, effects, failure, "fsync", null, .raw_stdio);
    };
    return .undefined;
}

pub fn stderrSync(runtime: *Runtime, context: Context, effects: Effects) !Value {
    context.syncStderr() catch |failure| {
        return throwIoAs(runtime, effects, failure, "fsync", null, .raw_stdio);
    };
    return .undefined;
}

/// Issue #28 raw stdioの検証用host。stdinは事前充填した共有sourceを返し、
/// stdout/stderr書込みとsync呼出しを記録する。`write_limit` で部分書込み、
/// `write_failure`/`sync_failure` で構造化エラーを再現する。
const StdioTestHost = struct {
    preloaded: []const u8 = "",
    /// feederモード用: 設定時はinitPreloadedではなく下位reader経由で
    /// 履歴を足すsourceを作る（履歴上限超過の試験に必要）。
    feed_chunks: ?[]const u8 = null,
    feed_offset: usize = 0,
    max_history: ?usize = null,
    source: ?low_level_io.StdinSource = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_syncs: usize = 0,
    stderr_syncs: usize = 0,
    write_limit: usize = std.math.maxInt(usize),
    write_failure: ?anyerror = null,
    sync_failure: ?anyerror = null,

    fn deinit(self: *StdioTestHost, allocator: std.mem.Allocator) void {
        if (self.source) |*source| source.deinit();
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
    }

    fn peek(pointer: *anyopaque) ?*low_level_io.StdinSource {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return if (self.source) |*source| source else null;
    }

    fn feedRead(pointer: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        const remaining = self.feed_chunks.?[self.feed_offset..];
        const count = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..count], remaining[0..count]);
        self.feed_offset += count;
        return count;
    }

    fn stdinSource(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.source == null) {
            if (self.feed_chunks != null) {
                self.source = low_level_io.StdinSource.init(allocator, self, feedRead);
                if (self.max_history) |max| self.source.?.max_history_bytes = max;
            } else {
                self.source = try low_level_io.StdinSource.initPreloaded(allocator, self.preloaded);
            }
        }
        return &self.source.?;
    }

    fn writeInto(list: *std.ArrayList(u8), self: *StdioTestHost, bytes: []const u8) anyerror!usize {
        if (self.write_failure) |failure| return failure;
        const count = @min(bytes.len, self.write_limit);
        try list.appendSlice(std.testing.allocator, bytes[0..count]);
        return count;
    }

    fn writeStdout(pointer: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return writeInto(&self.stdout, self, bytes);
    }

    fn writeStderr(pointer: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        return writeInto(&self.stderr, self, bytes);
    }

    fn syncStdout(pointer: *anyopaque) anyerror!void {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.sync_failure) |failure| return failure;
        self.stdout_syncs += 1;
    }

    fn syncStderr(pointer: *anyopaque) anyerror!void {
        const self: *StdioTestHost = @ptrCast(@alignCast(pointer));
        if (self.sync_failure) |failure| return failure;
        self.stderr_syncs += 1;
    }

    fn context(self: *StdioTestHost) Context {
        return .{ .stdio = .{
            .context = @ptrCast(self),
            .peekStdinSourceFn = peek,
            .stdinSourceFn = stdinSource,
            .writeStdoutBytesFn = writeStdout,
            .writeStderrBytesFn = writeStderr,
            .syncStdoutFn = syncStdout,
            .syncStderrFn = syncStderr,
        } };
    }
};

test "標準入力バイト読むはNULと不正UTF-8を保持しEOFで空Bytesを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "\x00\xff\x80a" ++ "\n" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var first = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 5 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&first);
    try std.testing.expectEqualSlices(u8, "\x00\xff\x80a\n", try bytesArgument(&runtime, first));
    var second = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 5 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&second);
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(&runtime, second)).len);
}

test "標準入力バイト読むは要求未満の部分読取りを返しsize不正をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "abc" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var result = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 16 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&result);
    try std.testing.expectEqualSlices(u8, "abc", try bytesArgument(&runtime, result));

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = -1 }}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "標準入力バイト読むは履歴上限超過をENOSPCの構造化エラーにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    // fillが1回に6バイト足し、上限4を超えてStreamTooLong→ENOSPCになる。
    var host = StdioTestHost{ .feed_chunks = "012345", .max_history = 4 };
    defer host.deinit(std.testing.allocator);

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 8 }}));
    try expectThrownCode(&runtime, thrown, "ENOSPC");
}

test "標準出力/標準エラー出力バイト書くはrawバイトを分けて書き実書込数を返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{};
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var out_bytes = try runtime.createBytes("\x00\xffout");
    var err_bytes = try runtime.createBytes("e\x80rr");
    try roots.protect(&out_bytes);
    try roots.protect(&err_bytes);
    const out_written = (try call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{out_bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 5), out_written.number);
    const err_written = (try call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{err_bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 4), err_written.number);
    try std.testing.expectEqualSlices(u8, "\x00\xffout", host.stdout.items);
    try std.testing.expectEqualSlices(u8, "e\x80rr", host.stderr.items);
}

test "標準出力バイト書くは部分書込み数を返し非BytesをEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .write_limit = 2 };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    var bytes = try runtime.createBytes("abcd");
    try roots.protect(&bytes);
    const written = (try call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{bytes})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 2), written.number);
    try std.testing.expectEqualSlices(u8, "ab", host.stdout.items);

    var text = try runtime.stringUtf8("not-bytes");
    try roots.protect(&text);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{text}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    var uint8 = try runtime.createUint8Array("ab");
    try roots.protect(&uint8);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{uint8}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "raw stdioのI/O失敗は構造化codeを持ちhost不在はENOTSUP+raw_stdio" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var host = StdioTestHost{ .write_failure = error.BrokenPipe };
    defer host.deinit(std.testing.allocator);
    var bytes = try runtime.createBytes("x");
    try roots.protect(&bytes);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力バイト書く", &.{bytes}));
    try expectThrownCode(&runtime, thrown, "EPIPE");
    thrown = .undefined;
    host.write_failure = error.NoSpaceLeft;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準エラー出力バイト書く", &.{bytes}));
    try expectThrownCode(&runtime, thrown, "ENOSPC");
    thrown = .undefined;
    host.write_failure = null;
    host.sync_failure = error.BrokenPipe;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "標準出力同期", &.{}));
    try expectThrownCode(&runtime, thrown, "EPIPE");
    thrown = .undefined;
    host.sync_failure = null;
    _ = try call(&runtime, &state, host.context(), effects, "標準出力同期", &.{});
    _ = try call(&runtime, &state, host.context(), effects, "標準エラー出力同期", &.{});
    try std.testing.expectEqual(@as(usize, 1), host.stdout_syncs);
    try std.testing.expectEqual(@as(usize, 1), host.stderr_syncs);

    // hostがstdio callbackを提供しない場合はENOTSUPにcapabilityを載せる。
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "標準入力バイト読む", &.{.{ .number = 1 }}));
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    const capability = node_shared.dictionaryGetAscii(thrown.dictionary, foundation.error_object_keys.capability) orelse return error.TestExpectedEqual;
    const capability_text = try node_shared.valueUtf8(&runtime, capability);
    defer runtime.allocator().free(capability_text);
    try std.testing.expectEqualStrings("raw_stdio", capability_text);
}

test "raw stdioを提供するhostでは低レイヤー機能対応判定がtrue" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{};
    defer host.deinit(std.testing.allocator);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name = try runtime.stringUtf8("raw_stdio");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, host.context(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(supported == .boolean and supported.boolean);
    const unsupported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})) orelse return error.TestExpectedEqual;
    try std.testing.expect(unsupported == .boolean and !unsupported.boolean);
}

test "標準入力バイト読むとテキスト系readLineは同じconsumedカーソルを消費する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var host = StdioTestHost{ .preloaded = "ab\ncd\n" };
    defer host.deinit(std.testing.allocator);

    var roots = runtime.rootFrame();
    defer roots.deinit();
    // raw読取りで先頭3バイト("ab\n")を消費すると、テキスト系readLineは
    // 残りから行を返す。逆方向も同じcursorを共有する。
    var chunk = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 3 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&chunk);
    try std.testing.expectEqualSlices(u8, "ab\n", try bytesArgument(&runtime, chunk));
    const source = if (host.source) |*existing| existing else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), source.consumed);
    try std.testing.expectEqualStrings("cd", (try source.readLine()).?);
    var rest = (try call(&runtime, &state, host.context(), effects, "標準入力バイト読む", &.{.{ .number = 8 }})) orelse return error.TestExpectedEqual;
    try roots.protect(&rest);
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(&runtime, rest)).len);
}
