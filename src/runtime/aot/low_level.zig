const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const shared = @import("shared.zig");
const foundation = @import("../low_level_foundation.zig");
const low_level_io = @import("../low_level_io.zig");
const low_level_hash = @import("../low_level_hash.zig");
const plugin_lowlevel = @import("../../plugins/lowlevel.zig");

const aot_builtin = shared.aot_builtin;
const BigInt = shared.BigInt;

const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const numberValue = state.numberValue;
const valueToNumber = state.valueToNumber;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
const runtimeUtf8String = state.runtimeUtf8String;
const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
const aotRuntimeIo = state.aotRuntimeIo;
const staticUtf8 = state.staticUtf8;
const isString = state.isString;
const dictionaryProperty = state.dictionaryProperty;

const read_chunk_bytes: usize = 64 * 1024;
const fflush = state.fflush;

fn io(runtime: *Runtime) std.Io {
    return aotRuntimeIo(runtime);
}

fn table(runtime: *Runtime) *low_level_io.FileHandleTable {
    if (runtime.low_level_handles == null) {
        runtime.low_level_handles = low_level_io.FileHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_handles.?;
}

fn hashTable(runtime: *Runtime) *low_level_hash.HashHandleTable {
    if (runtime.low_level_hash_handles == null) {
        runtime.low_level_hash_handles = low_level_hash.HashHandleTable.init(runtime.allocator);
    }
    return &runtime.low_level_hash_handles.?;
}

pub fn pluginContext(runtime: *Runtime) plugin_lowlevel.Context {
    return .{
        .context = runtime,
        .openFileFn = pluginOpenFile,
        .closeFileFn = pluginCloseFile,
        .readFileBytesFn = pluginReadFileBytes,
        .writeFileBytesFn = pluginWriteFileBytes,
        .syncFileFn = pluginSyncFile,
        .truncateFileFn = pluginTruncateFile,
        .createHashFn = pluginCreateHash,
        .updateHashFn = pluginUpdateHash,
        .digestHashFn = pluginDigestHash,
        .discardHashFn = pluginDiscardHash,
        .peekStdinSourceFn = pluginPeekStdinSource,
        .stdinSourceFn = pluginStdinSource,
        .writeStdoutBytesFn = pluginWriteStdoutBytes,
        .writeStderrBytesFn = pluginWriteStderrBytes,
        .syncStdoutFn = pluginSyncStdout,
        .syncStderrFn = pluginSyncStderr,
    };
}

fn pluginOpenFile(context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return (try table(runtime).open(io(runtime), .{ .path = path, .mode = mode, .exclusive = exclusive, .sync = sync })).raw();
}

fn pluginCloseFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    const removed = table(runtime).remove(id) orelse return error.BadFileDescriptor;
    removed.file.close(io(runtime));
    forgetHandleId(runtime, id);
}

fn pluginReadFileBytes(context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.readAtCurrent(io(runtime), entry.file, buffer);
}

fn pluginWriteFileBytes(context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.writeHandle(io(runtime), entry, bytes);
}

fn pluginSyncFile(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.sync(io(runtime), entry.file);
}

fn pluginTruncateFile(context: *anyopaque, raw: u64, size: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = table(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    return low_level_io.setLength(io(runtime), entry.file, size);
}

fn pluginCreateHash(context: *anyopaque, algorithm: []const u8) anyerror!u64 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const hasher = try low_level_hash.startNamed(algorithm);
    return (try hashTable(runtime).insert(hasher)).raw();
}

fn pluginUpdateHash(context: *anyopaque, raw: u64, bytes: []const u8) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const entry = hashTable(runtime).find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    entry.hasher.update(bytes);
}

fn pluginDigestHash(context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    var removed = hashTable(runtime).remove(id) orelse return error.BadFileDescriptor;
    forgetHandleId(runtime, id);
    return removed.hasher.finalize(allocator);
}

fn pluginDiscardHash(context: *anyopaque, raw: u64) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const id = foundation.HandleId.fromRaw(raw);
    _ = hashTable(runtime).remove(id) orelse return error.BadFileDescriptor;
    forgetHandleId(runtime, id);
}

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
fn pluginReadStdinChunk(context: *anyopaque, buffer: []u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return low_level_io.readAtCurrent(io(runtime), stdioStdinFile(runtime), buffer);
}

fn pluginPeekStdinSource(context: *anyopaque) ?*low_level_io.StdinSource {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    return if (runtime.stdin_source) |*source| source else null;
}

fn pluginStdinSource(context: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource {
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
fn pluginWriteStdoutBytes(context: *anyopaque, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    return low_level_io.writeAtCurrent(io(runtime), stdioStdoutFile(runtime), bytes);
}

/// stderr系のflushが見る条件は `stdout` 側。`fflush(null)` は全libc streamを
/// 流すので、実際に触るfdはfd 1である。stdoutが注入済みなら滞留putchar出力を
/// 実fd 1へ流さないようflushを抑える（stderrの注入有無では決めない）。
fn pluginWriteStderrBytes(context: *anyopaque, bytes: []const u8) anyerror!usize {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    return low_level_io.writeAtCurrent(io(runtime), stdioStderrFile(runtime), bytes);
}

fn pluginSyncStdout(context: *anyopaque) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    try low_level_io.sync(io(runtime), stdioStdoutFile(runtime));
}

fn pluginSyncStderr(context: *anyopaque) anyerror!void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (runtime.stdio_files.stdout == null) _ = fflush(null);
    try low_level_io.sync(io(runtime), stdioStderrFile(runtime));
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
fn findHandleId(runtime: *Runtime, value: Value) ?foundation.HandleId {
    const object = value.object() orelse return null;
    const raw = runtime.low_level_handle_ids.get(@intFromPtr(object)) orelse return null;
    return foundation.HandleId.fromRaw(raw);
}

fn forgetHandle(runtime: *Runtime, value: Value) void {
    if (findHandleId(runtime, value)) |id| forgetHandleId(runtime, id);
}

fn fileFor(runtime: *Runtime, value: Value) ?*low_level_io.OpenHandle {
    const id = findHandleId(runtime, value) orelse return null;
    return table(runtime).find(id);
}

fn openBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1 or !isString(arguments[0])) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, null, null, "pathは文字列である必要があります");
    }
    const path = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    var mode_owned: ?[]u8 = null;
    defer if (mode_owned) |owned| runtime.allocator.free(owned);
    if (arguments.len > 1 and arguments[1].tag != @intFromEnum(Tag.undefined)) {
        if (!isString(arguments[1])) {
            return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, path, null, "modeは文字列である必要があります");
        }
        mode_owned = try valueUtf8LossyAlloc(runtime, arguments[1]);
    }
    const parsed = foundation.parseOpenMode(mode_owned orelse "r") catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.open, path, null, "開くmodeが不正です");
    };
    const id = table(runtime).open(io(runtime), .{
        .path = path,
        .mode = parsed.mode,
        .exclusive = parsed.exclusive,
        .sync = parsed.sync,
    }) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.open, path);
    };
    errdefer {
        if (table(runtime).remove(id)) |removed| removed.file.close(io(runtime));
    }
    var handle = try runtime.createDictionary(&.{});
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&handle), 1);
    defer runtime.popRoots(&roots);
    try rememberHandle(runtime, handle, id);
    return handle;
}

fn closeBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    }
    const id = findHandleId(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    const removed = table(runtime).remove(id) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.close, null, null, "無効なハンドルです");
    };
    removed.file.close(io(runtime));
    forgetHandleId(runtime, id);
    if (runtime.dynamic_forget_handle) |forget| forget(runtime, id.raw());
    return .{};
}

fn readBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.read, null, null, "無効なハンドルです");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.read, null, null, "無効なハンドルです");
    };
    var remaining = sizeArgument(runtime, if (arguments.len > 1) arguments[1] else .{}) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.read, null, null, "読み込む大きさが不正です");
    };
    const allocator = runtime.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    while (remaining > 0) {
        const chunk_length: usize = @intCast(@min(remaining, read_chunk_bytes));
        const start = output.items.len;
        try output.resize(allocator, start + chunk_length);
        const read = low_level_io.readAtCurrent(io(runtime), entry.file, output.items[start..]) catch |failure| {
            return throwIo(runtime, failure, foundation.stream_operations.read, null);
        };
        output.shrinkRetainingCapacity(start + read);
        if (read == 0 or read < chunk_length) break;
        remaining -= read;
    }
    return runtime.createBytes(output.items);
}

fn writeBytesBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    }
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.write, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.write, null, null, "書き込む値はBytesである必要があります");
    };
    const written = low_level_io.writeHandle(io(runtime), entry, bytes) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.write, null);
    };
    return publicSizeValue(runtime, written);
}

fn syncBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.fsync, null, null, "無効なハンドルです");
    };
    low_level_io.sync(io(runtime), entry.file) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.fsync, null);
    };
    return .{};
}

fn truncateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    }
    if (arguments.len < 2) {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    }
    const entry = fileFor(runtime, arguments[0]) orelse {
        return throwStructured(runtime, .EBADF, foundation.stream_operations.ftruncate, null, null, "無効なハンドルです");
    };
    const size = sizeArgument(runtime, arguments[1]) catch {
        return throwStructured(runtime, .EINVAL, foundation.stream_operations.ftruncate, null, null, "切詰める大きさが不正です");
    };
    low_level_io.setLength(io(runtime), entry.file, size) catch |failure| {
        return throwIo(runtime, failure, foundation.stream_operations.ftruncate, null);
    };
    return .{};
}

/// `標準入力バイト読む`。共有sourceから最大SIZEバイトを1回のfillで返す。
/// 0バイトはEOF、SIZE未満の非0は部分読取り（`plugins/lowlevel.zig` の
/// `stdinRead` と同じ契約）。
fn stdinReadBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
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
fn stdioWriteBuiltin(runtime: *Runtime, arguments: []const Value, to_stderr: bool) !Value {
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

fn stdioSyncBuiltin(runtime: *Runtime, to_stderr: bool) !Value {
    (if (to_stderr) pluginSyncStderr(runtime) else pluginSyncStdout(runtime)) catch |failure| {
        return throwIoAs(runtime, failure, "fsync", null, .raw_stdio);
    };
    return .{};
}

fn hashCreateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
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

fn hashUpdateBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
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

fn hashDigestBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
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

fn hashDiscardBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
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

/// カタログ掲載済みで実装済みのincremental hash命令。arity検査は
/// `lowLevelFileBuiltin` と同じ契約（実装済み命令の下限未満はEINVAL）で行う。
pub fn lowLevelHashBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (aot_builtin.lowLevelCatalogCommand(command)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    return switch (command) {
        .low_level_hash_create => hashCreateBuiltin(runtime, arguments),
        .low_level_hash_update => hashUpdateBuiltin(runtime, arguments),
        .low_level_hash_digest => hashDigestBuiltin(runtime, arguments),
        .low_level_hash_discard => hashDiscardBuiltin(runtime, arguments),
        else => lowLevelUnsupportedBuiltin(runtime, command, arguments),
    };
}

pub fn lowLevelFileBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (aot_builtin.lowLevelCatalogCommand(command)) |spec| {
        if (arguments.len > spec.max) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
        // 実装済み命令の引数不足は引数数エラー（Interpreterのcallと同じ契約）。
        // 未実装命令はENOTSUPが「未実装」の通知を兼ねるためmin未満もENOTSUP。
        if (spec.implemented and arguments.len < spec.min) {
            return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
        }
    }
    return switch (command) {
        .low_level_file_open => openBuiltin(runtime, arguments),
        .low_level_file_close => closeBuiltin(runtime, arguments),
        .low_level_file_read_bytes => readBytesBuiltin(runtime, arguments),
        .low_level_file_write_bytes => writeBytesBuiltin(runtime, arguments),
        .low_level_file_sync => syncBuiltin(runtime, arguments),
        .low_level_file_truncate => truncateBuiltin(runtime, arguments),
        .low_level_stdin_read => stdinReadBuiltin(runtime, arguments),
        .low_level_stdout_write => stdioWriteBuiltin(runtime, arguments, false),
        .low_level_stderr_write => stdioWriteBuiltin(runtime, arguments, true),
        .low_level_stdout_sync => stdioSyncBuiltin(runtime, false),
        .low_level_stderr_sync => stdioSyncBuiltin(runtime, true),
        // dispatchは未実装命令を `lowLevelUnsupportedBuiltin` へ振り分けるため
        // 通常は到達しない。仮に到達しても構造化エラーの契約を維持する。
        else => lowLevelUnsupportedBuiltin(runtime, command, arguments),
    };
}

pub fn lowLevelCapabilitySupportedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const spec = aot_builtin.lowLevelCatalogCommand(.low_level_capability_supported) orelse return error.UnknownCommand;
    // 実装済み命令の引数不足は引数数エラー（Interpreterのcallと同じ契約）。
    if (arguments.len > spec.max or arguments.len < spec.min) {
        return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
    }
    const supported = capabilitySupported(arguments[0]);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(supported) };
}

/// カタログ掲載済みだが未実装の低レイヤー命令。カタログ定義のarityを超える
/// 呼び出しはEINVAL、範囲内は `capability` と `operation` を持つ構造化
/// ENOTSUP を投げる（`aot_compiles_unsupported_calls`）。min未満の呼び出しも
/// ENOTSUP とする: 実装済み命令と異なりENOTSUPが「未実装」の通知を兼ねるため、
/// 引数不足をEINVALへ分けると呼び出し側が未実装と引数不正を区別できなくなる
/// （助詞呼出はコンパイル時のarity検査を通らず実行時へ到達する）。
pub fn lowLevelUnsupportedBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const spec = aot_builtin.lowLevelCatalogCommand(command) orelse return error.UnknownCommand;
    // 実装済み命令がここへ到達するのはdispatch caseの配置ずれなので、
    // 開発時に検出する（`plugins/lowlevel.zig` のフォールバックと同じ防御）。
    std.debug.assert(!spec.implemented);
    if (arguments.len > spec.max) {
        return throwStructured(runtime, .EINVAL, spec.operation, null, null, "引数の数が不正です");
    }
    const capability: ?[]const u8 = if (spec.capability) |cap| cap.id() else null;
    return throwStructured(runtime, .ENOTSUP, spec.operation, null, capability, "この低レイヤー命令はまだ実装されていません");
}

pub fn lowLevelCapabilityListBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len > 0) {
        return throwStructured(runtime, .EINVAL, "capability", null, null, "引数の数が不正です");
    }
    const result = try runtime.createArray(&.{});
    var rooted = [_]Value{ result, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    inline for (std.meta.tags(foundation.Capability)) |capability| {
        rooted[1] = try runtimeUtf8String(runtime, capability.id());
        try rooted[0].object().?.payload.array.append(runtime.allocator, rooted[1]);
    }
    return rooted[0];
}

fn capabilitySupported(value: Value) bool {
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

fn sizeArgument(_: *Runtime, value: Value) !u64 {
    return switch (value.tag) {
        @intFromEnum(Tag.number) => foundation.sizeFromNumber(valueToNumber(value)),
        @intFromEnum(Tag.bigint) => foundation.sizeFromUnsigned(value.object().?.payload.bigint.toU128() catch return error.InvalidSize),
        else => error.InvalidSize,
    };
}

fn bytesArgument(value: Value) ![]const u8 {
    if (value.tag != @intFromEnum(Tag.byte_buffer)) return error.InvalidBytes;
    const buffer = value.object().?.payload.byte_buffer;
    if (buffer.kind != .buffer) return error.InvalidBytes;
    return buffer.bytes;
}

fn publicSizeValue(runtime: *Runtime, size: u64) !Value {
    return switch (foundation.publicSize(size)) {
        .number => numberValue(@floatFromInt(size)),
        .bigint => runtime.ownBigInt(try BigInt.init(runtime.allocator, size)),
    };
}

fn setField(runtime: *Runtime, dictionary: Value, name: []const u8, value: Value) !void {
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
    try setField(runtime, result, foundation.error_object_keys.path, if (path) |value| try runtimeUtf8String(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.path2, .{ .tag = @intFromEnum(Tag.null_value) });
    try setField(runtime, result, foundation.error_object_keys.message, try runtimeUtf8String(runtime, message));
    try setField(runtime, result, foundation.error_object_keys.capability, if (capability) |value| try runtimeUtf8String(runtime, value) else .{ .tag = @intFromEnum(Tag.null_value) });
    // 構造化エラー印。`["code"]` 等のフィールド参照と、文字列化＝`message`
    // の両方を可能にする。通常辞書の `message` キーとは区別される。
    if (result.object()) |object| object.structured_error = true;
    return result;
}

fn throwIo(runtime: *Runtime, failure: anyerror, operation: []const u8, path: ?[]const u8) anyerror {
    return throwIoAs(runtime, failure, operation, path, if (std.mem.eql(u8, operation, foundation.stream_operations.ftruncate)) .truncate else .stream_file_io);
}

/// ENOTSUPのときだけ `capability` をエラー辞書へ載せるI/O失敗。
/// `throwIo` のcapability判定をパラメータ化したもの（`plugins/lowlevel.zig`
/// の `throwIoAs` と同じ契約）。
fn throwIoAs(runtime: *Runtime, failure: anyerror, operation: []const u8, path: ?[]const u8, capability: foundation.Capability) anyerror {
    const code = foundation.portableCodeForFailure(failure) orelse .EINVAL;
    return throwStructured(runtime, code, operation, path, if (code == .ENOTSUP) capability.id() else null, failureMessage(failure));
}

fn throwStructured(
    runtime: *Runtime,
    code: foundation.PortableErrorCode,
    operation: []const u8,
    path: ?[]const u8,
    capability: ?[]const u8,
    message: []const u8,
) anyerror {
    var dictionary = buildError(runtime, code, operation, path, capability, message) catch |failure| return failure;
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

test "AOT低レイヤーはread/write/truncate/closeをハンドル同一性で扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aot-low-level.txt" });
    defer std.testing.allocator.free(path);

    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, path);
    roots[3] = try runtimeUtf8String(&runtime, "w");
    const handle = try openBuiltin(&runtime, &.{ roots[0], roots[3] });
    try std.testing.expectEqual(@as(u32, 1), runtime.low_level_handle_ids.size);

    roots[1] = try runtime.createBytes("abcd");
    const written = try writeBytesBuiltin(&runtime, &.{ handle, roots[1] });
    try std.testing.expectEqual(@as(u64, 4), try sizeArgument(&runtime, written));

    _ = try truncateBuiltin(&runtime, &.{ handle, written });

    roots[2] = try runtime.createBytes("xy");
    _ = try writeBytesBuiltin(&runtime, &.{ handle, roots[2] });
    _ = try closeBuiltin(&runtime, &.{handle});
    try std.testing.expectEqual(@as(u32, 0), runtime.low_level_handle_ids.size);
    try std.testing.expect(runtime.low_level_handles.?.len() == 0);
    try std.testing.expectError(error.NakoException, closeBuiltin(&runtime, &.{handle}));
    try std.testing.expectError(error.NakoException, writeBytesBuiltin(&runtime, &.{ handle, roots[1] }));
}

test "AOT低レイヤーは余分な引数をEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, closeBuiltin(&runtime, &.{ numberValue(1), numberValue(2) }));
}

test "AOT低レイヤーの引数なしopenと機能対応判定はEINVAL" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{}));
    // 実装済み命令の引数不足は引数数エラー。未知capabilityの照会falseとは区別する。
    try std.testing.expectError(error.NakoException, lowLevelCapabilitySupportedBuiltin(&runtime, &.{}));
    var roots = [_]Value{try runtimeUtf8String(&runtime, "unknown_capability")};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const supported = try lowLevelCapabilitySupportedBuiltin(&runtime, &roots);
    try std.testing.expectEqual(@as(u64, 0), supported.payload);
}

test "AOT低レイヤーは非文字列のpathとmodeをEINVALにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &.{numberValue(1)}));
    var roots = [_]Value{ try runtimeUtf8String(&runtime, "missing.txt"), numberValue(1) };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectError(error.NakoException, openBuiltin(&runtime, &roots));
}

test "AOT低レイヤーのappendは切詰め後も末尾へ書く" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aot-append.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "aot-append.txt", .data = "abcdef" });

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, path);
    roots[1] = try runtimeUtf8String(&runtime, "a");
    const handle = try openBuiltin(&runtime, &.{ roots[0], roots[1] });
    _ = try truncateBuiltin(&runtime, &.{ handle, numberValue(2) });
    roots[2] = try runtime.createBytes("xy");
    _ = try writeBytesBuiltin(&runtime, &.{ handle, roots[2] });
    _ = try closeBuiltin(&runtime, &.{handle});

    const output = try temporary.dir.readFileAlloc(std.testing.io, "aot-append.txt", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "abxy", output);
}

test "AOT pluginContextはRuntimeのハンドル表へ開く" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "plugin-context.txt" });
    defer std.testing.allocator.free(path);

    const context = pluginContext(&runtime);
    const raw = try context.openFile(path, .write_create_truncate, false, false);
    try std.testing.expectEqual(@as(usize, 2), try context.writeFileBytes(raw, "ok"));
    try context.closeFile(raw);
    try std.testing.expectEqual(@as(usize, 0), runtime.low_level_handles.?.len());

    const output = try temporary.dir.readFileAlloc(std.testing.io, "plugin-context.txt", std.testing.allocator, .limited(8));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, "ok", output);
}

fn aotThrownCode(runtime: *Runtime) ![]u8 {
    try std.testing.expect(runtime.has_pending_exception);
    const exception = runtime.takeException();
    const code = state.dictionaryOwnProperty(exception, &.{ 'c', 'o', 'd', 'e' }) orelse return error.TestExpectedEqual;
    return valueUtf8LossyAlloc(runtime, code);
}

fn pendingErrorCode(runtime: *Runtime) ![]u8 {
    try std.testing.expect(runtime.has_pending_exception);
    const code = dictionaryProperty(runtime.pending_exception, &.{ 'c', 'o', 'd', 'e' });
    return valueUtf8LossyAlloc(runtime, code);
}

fn expectPendingCode(runtime: *Runtime, expected: []const u8) !void {
    const code = try pendingErrorCode(runtime);
    defer runtime.allocator.free(code);
    try std.testing.expectEqualStrings(expected, code);
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
