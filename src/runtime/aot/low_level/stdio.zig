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

/// Issue #28: raw標準入出力が触るstdio fd。`stdio_files` のnullは実プロセスの
/// `std.Io.File.stdin()/stdout()/stderr()` を指し、テストはパイプ等を注入する。
pub fn stdioStdinFile(runtime: *Runtime) std.Io.File {
    return runtime.stdio_files.stdin orelse std.Io.File.stdin();
}

pub fn stdioStdoutFile(runtime: *Runtime) std.Io.File {
    return runtime.stdio_files.stdout orelse std.Io.File.stdout();
}

pub fn stdioStderrFile(runtime: *Runtime) std.Io.File {
    return runtime.stdio_files.stderr orelse std.Io.File.stderr();
}

/// 共有stdin sourceの下位reader。1呼出しで最大buffer.lenバイトを返し、
/// 0はEOF。バッファリングは `StdinSource` 側だけが行う。
pub fn pluginReadStdinChunk(context: *anyopaque, buffer: []u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_io.readAtCurrent(io(runtime), stdioStdinFile(runtime), buffer);
}

pub fn pluginPeekStdinSource(context: *anyopaque) ?*low_level_io.StdinSource {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return if (runtime.stdin_source) |*source| source else null;
}

pub fn pluginStdinSource(context: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    _ = allocator;
    return ensureAotStdinSource(runtime);
}

/// AOTランタイムが持つ共有stdin sourceを遅延生成する。native builtinと
/// 埋め込みinterpreter（`pluginContext` 経由）の両方が同じ `consumed`
/// カーソルを消費する。`runtime.allocator` を使うのはsourceが
/// `Runtime.deinit` と同じ寿命を持つため（呼び出し側の短命allocatorは
/// 使わない）。sourceの `read_context` はこのRuntimeへのback-pointerを
/// 持つため、生成後にRuntimeを値コピー（例: `state.active_runtime` への
/// 代入）してはいけない——sourceは最終配置のRuntime上で生成すること。
pub fn ensureAotStdinSource(runtime: *Runtime) !*low_level_io.StdinSource {
    if (runtime.stdin_source == null) {
        runtime.stdin_source = low_level_io.StdinSource.init(runtime.allocator, runtime, pluginReadStdinChunk);
    }
    return &runtime.stdin_source.?;
}

/// rawバイト書込みはlibc stdoutのバッファ済み出力（putchar等）より後に
/// 届くよう、先に `fflush(null)` してからfdへ直接書く。`stdio_files` 注入時は
/// 書き込み先が実stdio fdではないためlibcとの順序づけは不要で、flushしない
/// （テストプロセスで滞留したputchar出力を実fdへ流し込まないためでもある）。
pub fn pluginWriteStdoutBytes(context: *anyopaque, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    return low_level_io.writeAtCurrent(io(runtime), stdioStdoutFile(runtime), bytes);
}

/// stderr系のflushが見る条件は `stdout` 側。`fflush(null)` は全libc streamを
/// 流すので、実際に触るfdはfd 1である。stdoutが注入済みなら滞留putchar出力を
/// 実fd 1へ流さないようflushを抑える（stderrの注入有無では決めない）。
pub fn pluginWriteStderrBytes(context: *anyopaque, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    return low_level_io.writeAtCurrent(io(runtime), stdioStderrFile(runtime), bytes);
}

pub fn pluginSyncStdout(context: *anyopaque) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    try low_level_io.sync(io(runtime), stdioStdoutFile(runtime));
}

pub fn pluginSyncStderr(context: *anyopaque) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    try low_level_io.sync(io(runtime), stdioStderrFile(runtime));
}

/// `標準入力バイト読む`。共有sourceから最大SIZEバイトを1回のfillで返す。
/// 0バイトはEOF、SIZE未満の非0は部分読取り（`plugins/lowlevel.zig` の
/// `stdinRead` と同じ契約）。
pub fn stdinReadBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, "read", null, null, "読み込む大きさが不正です");
    }
    const size = sizeArgument(runtime, arguments[0]) catch {
        return throwStructured(runtime, .EINVAL, "read", null, null, "読み込む大きさが不正です");
    };
    const source = ensureAotStdinSource(runtime) catch |failure| {
        return throwIoAs(runtime, failure, "read", null, .raw_stdio);
    };
    // 1呼出しの返却は1fillぶんまで（`plugins/lowlevel.zig` の `stdinRead` と
    // 同じくfill上限で切り詰め、巨大SIZEの一括確保によるOOMを避ける）。
    const length: usize = @intCast(@min(size, low_level_io.stdin_fill_bytes));
    const buffer = try runtime.allocator.alloc(u8, length);
    defer runtime.allocator.free(buffer);
    const read = source.read(buffer) catch |failure| {
        return throwIoAs(runtime, failure, "read", null, .raw_stdio);
    };
    return runtime.createBytes(buffer[0..read]);
}

/// `標準出力バイト書く`/`標準エラー出力バイト書く`。Bytes値をUTF-8変換や
/// NUL終端を挟まずfdへ直接書き、実際に書けたバイト数を返す。
pub fn stdioWriteBuiltin(runtime: *Runtime, arguments: []const Value, to_stderr: bool) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EINVAL, "write", null, null, "書き込む値はBytesである必要があります");
    }
    const bytes = bytesArgument(arguments[0]) catch {
        return throwStructured(runtime, .EINVAL, "write", null, null, "書き込む値はBytesである必要があります");
    };
    const written = (if (to_stderr) pluginWriteStderrBytes(runtime, bytes) else pluginWriteStdoutBytes(runtime, bytes)) catch |failure| {
        return throwIoAs(runtime, failure, "write", null, .raw_stdio);
    };
    return publicSizeValue(runtime, written);
}

pub fn stdioSyncBuiltin(runtime: *Runtime, to_stderr: bool) !Value {
    (if (to_stderr) pluginSyncStderr(runtime) else pluginSyncStdout(runtime)) catch |failure| {
        return throwIoAs(runtime, failure, "fsync", null, .raw_stdio);
    };
    return .{};
}

test "AOT標準入力バイト読むはNUL/不正UTF-8を保持しテキスト系とcursorを共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "stdin.bin", .data = "\x00\xffa\nrest\n" });
    const stdin_file = try temporary.dir.openFile(std.testing.io, "stdin.bin", .{});
    defer stdin_file.close(std.testing.io);
    runtime.stdio_files.stdin = stdin_file;
    // `文字尋` はプロンプトをstdio_stdoutへ書き、未注入だと実fd 1へ
    // libcバッファflushが走る。test runnerのプロトコルpipeを汚さないよう
    // stdoutにもsinkを注入する。
    const prompt_sink = try temporary.dir.createFile(std.testing.io, "prompt.bin", .{});
    defer prompt_sink.close(std.testing.io);
    runtime.stdio_files.stdout = prompt_sink;

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    // SIZE=0はEOFではなく空Bytesを返し、cursorも動かさない（POSIXの
    // read(fd,buf,0)と同じ）。
    roots[0] = try stdinReadBuiltin(&runtime, &.{numberValue(0)});
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(roots[0])).len);

    // "\x00\xffa\n" をUTF-8検証・変換なしで返す。
    roots[0] = try stdinReadBuiltin(&runtime, &.{numberValue(4)});
    try std.testing.expectEqualSlices(u8, "\x00\xffa\n", try bytesArgument(roots[0]));

    // テキスト系（`文字尋` 相当）は同じsourceの残りから行を読む。
    roots[3] = try runtimeUtf8String(&runtime, "");
    roots[1] = try state.nodeStdinLineBuiltin(&runtime, .node_stdin_character, &.{roots[3]});
    const line = try valueUtf8LossyAlloc(&runtime, roots[1]);
    defer runtime.allocator.free(line);
    try std.testing.expectEqualStrings("rest", line);

    // 行消費後はEOF: 0バイトのBytesを返す。
    roots[2] = try stdinReadBuiltin(&runtime, &.{numberValue(8)});
    try std.testing.expectEqual(@as(usize, 0), (try bytesArgument(roots[2])).len);
}

test "AOT標準入力バイト読むは履歴上限超過をENOSPCの構造化エラーにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "stdin.bin", .data = "012345" });
    const stdin_file = try temporary.dir.openFile(std.testing.io, "stdin.bin", .{});
    defer stdin_file.close(std.testing.io);
    runtime.stdio_files.stdin = stdin_file;

    // fillが1回に6バイト足し、上限4を超えてStreamTooLong→ENOSPCになる。
    const source = try ensureAotStdinSource(&runtime);
    source.max_history_bytes = 4;

    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectError(error.NakoException, stdinReadBuiltin(&runtime, &.{numberValue(8)}));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings("ENOSPC", code);
}

test "AOT標準出力/標準エラー出力バイト書くはfdへraw書込みし実書込数を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const stdout_file = try temporary.dir.createFile(std.testing.io, "stdout.bin", .{ .read = true });
    const stderr_file = try temporary.dir.createFile(std.testing.io, "stderr.bin", .{ .read = true });
    runtime.stdio_files.stdout = stdout_file;
    runtime.stdio_files.stderr = stderr_file;

    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createBytes("\x00\xffout");
    roots[1] = try runtime.createBytes("e\x80rr");

    const out_written = try stdioWriteBuiltin(&runtime, &.{roots[0]}, false);
    try std.testing.expectEqual(@as(f64, 5), valueToNumber(out_written));
    const err_written = try stdioWriteBuiltin(&runtime, &.{roots[1]}, true);
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(err_written));
    _ = try stdioSyncBuiltin(&runtime, false);
    _ = try stdioSyncBuiltin(&runtime, true);

    stdout_file.close(std.testing.io);
    stderr_file.close(std.testing.io);
    runtime.stdio_files = .{};
    const out_bytes = try temporary.dir.readFileAlloc(std.testing.io, "stdout.bin", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(out_bytes);
    const err_bytes = try temporary.dir.readFileAlloc(std.testing.io, "stderr.bin", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(err_bytes);
    try std.testing.expectEqualSlices(u8, "\x00\xffout", out_bytes);
    try std.testing.expectEqualSlices(u8, "e\x80rr", err_bytes);
}

test "AOT raw stdioは不正引数をEINVALにしraw_stdio対応判定はtrue" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "raw_stdio");
    const supported = try lowLevelCapabilitySupportedBuiltin(&runtime, &.{roots[0]});
    try std.testing.expectEqual(@as(u64, 1), supported.payload);

    // arity・size不正・非Bytesは構造化EINVAL。
    try std.testing.expectError(error.NakoException, lowLevelFileBuiltin(&runtime, .low_level_stdin_read, &.{}));
    const arity_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(arity_code);
    try std.testing.expectEqualStrings("EINVAL", arity_code);

    try std.testing.expectError(error.NakoException, lowLevelFileBuiltin(&runtime, .low_level_stdin_read, &.{numberValue(-1)}));
    const size_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(size_code);
    try std.testing.expectEqualStrings("EINVAL", size_code);

    roots[1] = try runtimeUtf8String(&runtime, "not-bytes");
    try std.testing.expectError(error.NakoException, stdioWriteBuiltin(&runtime, &.{roots[1]}, false));
    const kind_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(kind_code);
    try std.testing.expectEqualStrings("EINVAL", kind_code);

    // Buffer kind以外（Uint8Array）もEINVAL。
    roots[2] = try runtime.createUint8Array("ab");
    try std.testing.expectError(error.NakoException, stdioWriteBuiltin(&runtime, &.{roots[2]}, true));
    const array_code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(array_code);
    try std.testing.expectEqualStrings("EINVAL", array_code);
}

test "AOT raw stdioの書込み失敗は構造化エラーを投げる" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 読取り専用で開いたfdへの書込みは失敗し、構造化codeを持つ例外になる。
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "readonly.bin", .data = "" });
    const stdout_file = try temporary.dir.openFile(std.testing.io, "readonly.bin", .{});
    defer stdout_file.close(std.testing.io);
    runtime.stdio_files.stdout = stdout_file;

    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createBytes("x");

    try std.testing.expectError(error.NakoException, stdioWriteBuiltin(&runtime, &.{roots[0]}, false));
    const code = try aotThrownCode(&runtime);
    defer runtime.allocator.free(code);
    // 読取り専用fdへの書込みはPOSIXではNotOpenForWriting→EBADF、Windowsでは
    // WriteFileがERROR_ACCESS_DENIEDを返すためAccessDenied→EACCESへ写像される。
    const expected = if (builtin.os.tag == .windows) "EACCES" else "EBADF";
    try std.testing.expectEqualStrings(expected, code);
}
