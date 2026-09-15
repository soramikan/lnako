const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");

/// Issue #27のストリームI/Oが使う実OSハンドル表。OSのファイル記述子や
/// `std.Io.File` をなでしこ値として公開せず、この表の `HandleId` を介する。
/// Interpreter（Host側CliHost）とAOT（Runtime側）の両方がこの表を持つ。
pub const OpenHandle = struct {
    id: foundation.HandleId,
    file: std.Io.File,
    append: bool = false,
};

/// 生成番号付きのハンドル表。closeしてもindexのgenerationを保持し、
/// use-after-closeを同じindexの再割当てで誤検出しない。
pub const FileHandleTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OpenHandle) = .empty,
    generations: std.AutoHashMap(u32, u32),
    free_indices: std.ArrayList(u32) = .empty,
    next_index: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) FileHandleTable {
        return .{ .allocator = allocator, .generations = std.AutoHashMap(u32, u32).init(allocator) };
    }

    pub fn deinit(self: *FileHandleTable, io: std.Io) void {
        for (self.entries.items) |*entry| entry.file.close(io);
        self.entries.deinit(self.allocator);
        self.generations.deinit();
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const FileHandleTable) usize {
        return self.entries.items.len;
    }

    pub fn find(self: *FileHandleTable, id: foundation.HandleId) ?*OpenHandle {
        for (self.entries.items) |*entry| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) return entry;
        }
        return null;
    }

    pub fn insert(self: *FileHandleTable, file: std.Io.File) !foundation.HandleId {
        const id = try self.allocateId();
        errdefer self.free_indices.append(self.allocator, id.index) catch {};
        try self.entries.append(self.allocator, .{ .id = id, .file = file, .append = false });
        return id;
    }

    /// close時に同じindexのgenerationを進め、空きindexとして再利用する。
    /// 0へ回った場合は1へ飛ばす。
    pub fn remove(self: *FileHandleTable, id: foundation.HandleId) ?OpenHandle {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) {
                const removed = self.entries.swapRemove(index);
                if (self.generations.getPtr(id.index)) |generation| {
                    generation.* = generation.* +% 1;
                    if (generation.* == 0) generation.* = 1;
                }
                self.free_indices.append(self.allocator, id.index) catch {};
                return removed;
            }
        }
        return null;
    }

    fn allocateId(self: *FileHandleTable) !foundation.HandleId {
        if (self.free_indices.pop()) |index| {
            const generation = self.generations.get(index) orelse 1;
            return .{ .index = index, .generation = if (generation == 0) 1 else generation };
        }
        var index: u32 = self.next_index;
        if (index == 0) index = 1;
        while (self.generations.contains(index) or index == 0) index +%= 1;
        try self.generations.put(index, 1);
        self.next_index = index +% 1;
        if (self.next_index == 0) self.next_index = 1;
        return .{ .index = index, .generation = 1 };
    }

    /// ファイルを開いてハンドル表へ載せる。modeに応じて読み書き・生成・
    /// 切詰・appendの開始位置まで確定する。
    pub fn open(self: *FileHandleTable, io: std.Io, options: OpenOptions) OpenError!foundation.HandleId {
        const file = try openFile(io, options);
        errdefer file.close(io);
        const id = try self.insert(file);
        self.find(id).?.append = options.mode.isAppend() and !posixOpenUsed(options);
        return id;
    }
};

pub const OpenOptions = struct {
    path: []const u8,
    mode: foundation.OpenMode,
    exclusive: bool = false,
    sync: bool = false,
};

pub const OpenError = anyerror;
pub const ReadError = anyerror;
pub const WriteError = anyerror;
pub const SyncError = anyerror;
pub const SetLengthError = anyerror;
pub const CloseError = anyerror;

fn posixOpenUsed(options: OpenOptions) bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => false,
        else => options.mode.isAppend() or options.sync,
    };
}

fn openFile(io: std.Io, options: OpenOptions) OpenError!std.Io.File {
    if (posixOpenUsed(options)) return openPosix(io, options);
    if (options.sync) return error.LowLevelIoUnavailable;
    return switch (options.mode) {
        .read => std.Io.Dir.cwd().openFile(io, options.path, .{ .mode = .read_only }),
        .read_write => std.Io.Dir.cwd().openFile(io, options.path, .{ .mode = .read_write }),
        .write_create_truncate => std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = false,
            .truncate = true,
            .exclusive = options.exclusive,
        }),
        .write_read_create_truncate => std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = true,
            .truncate = true,
            .exclusive = options.exclusive,
        }),
        .append_create => std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = false,
            .truncate = false,
            .exclusive = options.exclusive,
        }),
        .append_read_create => std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = true,
            .truncate = false,
            .exclusive = options.exclusive,
        }),
    };
}

fn openPosix(io: std.Io, options: OpenOptions) OpenError!std.Io.File {
    switch (builtin.os.tag) {
        .windows, .wasi => return error.LowLevelIoUnavailable,
        else => {
            var flags: std.posix.O = .{
                .ACCMODE = switch (options.mode) {
                    .read => .RDONLY,
                    .write_create_truncate, .append_create => .WRONLY,
                    .read_write, .write_read_create_truncate, .append_read_create => .RDWR,
                },
                .CREAT = options.mode.creates(),
                .TRUNC = options.mode.isTruncate(),
                .EXCL = options.exclusive,
            };
            if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
            if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
            if (options.mode.isAppend()) flags.APPEND = true;
            if (options.sync) flags.SYNC = true;
            const fd = try std.posix.openat(std.Io.Dir.cwd().handle, options.path, flags, 0o666);
            const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            errdefer file.close(io);
            if (options.mode.isAppend() and !posixFlagIsSet(file, "APPEND")) return error.LowLevelIoUnavailable;
            if (options.sync and !posixFlagIsSet(file, "SYNC")) return error.LowLevelIoUnavailable;
            return file;
        },
    }
}

fn posixFlagIsSet(file: std.Io.File, comptime field: []const u8) bool {
    if (!@hasField(std.posix.O, field)) return false;
    const get_rc = std.posix.system.fcntl(file.handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(get_rc) != .SUCCESS) return false;
    const flags: usize = @intCast(get_rc);
    return flags & (@as(usize, 1) << @bitOffsetOf(std.posix.O, field)) != 0;
}

/// ファイル末尾位置を返す。POSIXでは `file.length` と同じ。Windowsでは
/// `file.length` が内部で `NtQueryInformationFile(FileAllInformation)` を使い
/// `FILE_READ_ATTRIBUTES` を要求するため、書込み専用ハンドルでは
/// `STATUS_ACCESS_DENIED` になる。`FileStandardInformation`（GetFileSizeEx相当）は
/// 読み取り権限を要求しないため、書込み専用でも末尾を取得できる。
fn endOfFile(io: std.Io, file: std.Io.File) !u64 {
    switch (builtin.os.tag) {
        .windows => {
            var status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
            var info: std.os.windows.FILE.STANDARD_INFORMATION = undefined;
            return switch (std.os.windows.ntdll.NtQueryInformationFile(
                file.handle,
                &status_block,
                &info,
                @sizeOf(std.os.windows.FILE.STANDARD_INFORMATION),
                .Standard,
            )) {
                .SUCCESS => @as(u64, @bitCast(info.EndOfFile)),
                .ACCESS_DENIED => error.AccessDenied,
                else => |status| std.os.windows.unexpectedStatus(status),
            };
        },
        else => return file.length(io),
    }
}

fn seekToEnd(io: std.Io, file: std.Io.File) !void {
    const end = try endOfFile(io, file);
    var writer = file.writerStreaming(io, &.{});
    try writer.seekTo(end);
}

/// 現在位置から最大 `buffer.len` バイト読む。EOFは0バイトへ正規化する。
pub fn readAtCurrent(io: std.Io, file: std.Io.File, buffer: []u8) ReadError!usize {
    const read = file.readStreaming(io, &.{buffer}) catch |failure| switch (failure) {
        error.EndOfStream => return 0,
        else => return failure,
    };
    return read;
}

/// 現在位置からバイト列を書く。部分書込みの場合は実際に書いた数を返す。
pub fn writeAtCurrent(io: std.Io, file: std.Io.File, bytes: []const u8) WriteError!usize {
    return file.writeStreaming(io, &.{}, &.{bytes}, 1);
}

/// Issue #28のraw標準入出力が触るプロセスのstdio fd差し替え口。nullは
/// 実プロセスの `std.Io.File.stdin()/stdout()/stderr()` を指す。
/// 所有権は移らず、closeは差し替えた側（テスト等）が行う。
pub const StdioFiles = struct {
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
};

/// 共有stdin sourceの1回あたりのfill/読取り上限。`標準入力バイト読む` の
/// SIZEはこの値で切り詰められる（部分読取り契約により許容）。
pub const stdin_fill_bytes: usize = 64 * 1024;

/// stdin履歴の総量上限。旧来の `allocRemaining(.limited(64MiB))` と同じ
/// 上限を `history` 全体へ適用し、無制限蓄積によるOOMを防ぐ。
pub const stdin_max_history_bytes: usize = 64 * 1024 * 1024;

/// Issue #28の標準入力の単一source of truth。rawバイト命令
/// （`標準入力バイト読む`）とテキスト系命令（`尋`/`標準入力取得時`/
/// `標準入力全取得`）が同じ `consumed` カーソルを消費する。
/// `history` は受信した全バイトを保持し、`標準入力全取得` が消費済みを
/// 含む全量を返すために切り詰めない（upstreamの `__stdinRaw` と同じ）。
/// 下位readerは `read_fn` への1回の呼び出しで最大buffer.lenバイトを返し、
/// 0はEOFを意味する。
pub const StdinSource = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    eof: bool = false,
    read_context: *anyopaque = undefined,
    read_fn: ?*const fn (context: *anyopaque, buffer: []u8) anyerror!usize = null,
    /// 履歴の総量上限。`標準入力全取得` が全履歴を返す契約のため消費済み
    /// も保持する必要があり、受信総量で制限する。超過時はfillが
    /// `error.StreamTooLong` を返す。`initPreloaded` はcapを適用しない
    /// （生成後にmaxを現履歴未満へ下げてはいけない）。
    max_history_bytes: usize = stdin_max_history_bytes,
    /// 上限超過の粘着フラグ。一度超えたら以後のfillはreaderを呼ばず即
    /// StreamTooLongを返し、retry loopがstdinを読み捨て続けるのを防ぐ。
    too_long: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        read_context: *anyopaque,
        read_fn: ?*const fn (context: *anyopaque, buffer: []u8) anyerror!usize,
    ) StdinSource {
        return .{ .allocator = allocator, .read_context = read_context, .read_fn = read_fn };
    }

    /// テスト用にバイト列を事前充填したsourceを作る。read_fnを持たず、
    /// 履歴を読み切るとEOFになる。
    pub fn initPreloaded(allocator: std.mem.Allocator, bytes: []const u8) !StdinSource {
        var source = StdinSource{ .allocator = allocator };
        try source.history.appendSlice(allocator, bytes);
        return source;
    }

    pub fn deinit(self: *StdinSource) void {
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    /// 履歴の末尾へ最大1チャンク読み足す。EOFまたはread_fn未設定なら
    /// eofを立てて0を返す。返却値は今回足したバイト数。
    fn fill(self: *StdinSource) !usize {
        if (self.eof) return 0;
        if (self.too_long) return error.StreamTooLong;
        const read_fn = self.read_fn orelse {
            self.eof = true;
            return 0;
        };
        const start = self.history.items.len;
        try self.history.resize(self.allocator, start + stdin_fill_bytes);
        // 誤実装readerがbuffer.len超を返しても history の内部状態を壊さないよう
        // 収容ぶんへ切り詰める。
        const received = @min(read_fn(self.read_context, self.history.items[start..]) catch |failure| {
            self.history.shrinkRetainingCapacity(start);
            return failure;
        }, stdin_fill_bytes);
        // 上限ちょうどで終わる入力はEOFまで受理するため、超過は読み取り後に
        // 判定する。既読ぶんと上限までの先頭は残し、超過分だけを捨てる
        // （start自体が上限を超える設定変更は縮めず、エラー状態のまま残す）。
        if (start + received > self.max_history_bytes) {
            self.history.shrinkRetainingCapacity(@max(@min(start + received, self.max_history_bytes), start));
            self.too_long = true;
            return error.StreamTooLong;
        }
        self.history.shrinkRetainingCapacity(start + received);
        if (received == 0) {
            self.eof = true;
            return 0;
        }
        return received;
    }

    /// 最大 `buffer.len` バイトを読む。履歴に残があればそこから返し、
    /// 無ければ1回だけfillしてから返す。0はEOF、buffer.len未満の非0は
    /// 部分読取り（呼び出し側は続きを再度呼べる）。
    pub fn read(self: *StdinSource, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        if (self.consumed >= self.history.items.len and try self.fill() == 0) return 0;
        const count = @min(buffer.len, self.history.items.len - self.consumed);
        @memcpy(buffer[0..count], self.history.items[self.consumed..][0..count]);
        self.consumed += count;
        return count;
    }

    /// `\n` 終端の1行を返す。`nextStdinLine` と同じくLF直前のCRを落とし、
    /// EOF終端の行も末尾CRを落とす。行内のCRは保持する。EOFで残りが
    /// 無ければ `null`。返却sliceはhistoryへの参照で、次のfill/read/
    /// readLineで再割当てにより無効になり得るため即座に消費すること。
    pub fn readLine(self: *StdinSource) !?[]const u8 {
        const start = self.consumed;
        var end = start;
        while (true) {
            const items = self.history.items;
            while (end < items.len and items[end] != '\n') end += 1;
            if (end < items.len) {
                self.consumed = end + 1;
                var line = items[start..end];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                return line;
            }
            if (self.eof) {
                if (end == start) return null;
                self.consumed = end;
                var line = items[start..end];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                return line;
            }
            _ = try self.fill();
        }
    }

    /// stdinをEOFまで読み切り、消費済みを含む全履歴を返す
    /// （`標準入力全取得` の返却対象）。
    pub fn drainAll(self: *StdinSource) ![]const u8 {
        while (!self.eof) _ = try self.fill();
        return self.history.items;
    }
};

pub fn writeHandle(io: std.Io, entry: *OpenHandle, bytes: []const u8) WriteError!usize {
    // POSIX経路は open 時の O_APPEND で原子的に末尾へ書く。それ以外（Windows）
    // は seek フォールバックなので、同一ファイルへの並行appendは
    // seekとwriteの間に他の書込みが割り込みうる（非原子）。
    if (entry.append) try seekToEnd(io, entry.file);
    return writeAtCurrent(io, entry.file, bytes);
}

/// 全バイトを書く。ファイルでは通常1回で書けるが、末尾まで試す。
pub fn writeAtCurrentAll(io: std.Io, file: std.Io.File, bytes: []const u8) WriteError!void {
    var index: usize = 0;
    while (index < bytes.len) {
        const written = try writeAtCurrent(io, file, bytes[index..]);
        if (written == 0) return error.Unexpected;
        index += written;
    }
}

pub fn sync(io: std.Io, file: std.Io.File) SyncError!void {
    return file.sync(io);
}

pub fn setLength(io: std.Io, file: std.Io.File, new_length: u64) SetLengthError!void {
    return file.setLength(io, new_length);
}

test "ハンドル表はindexとgenerationを持つ生ハンドルを発行する" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "handle-table-test.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "handle-table-test.txt", .data = "abc" });

    const first = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    try std.testing.expect(first.isValid());
    try std.testing.expectEqual(@as(usize, 1), table.len());
    const second = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    try std.testing.expect(second.index != first.index or second.generation != first.generation);
    try std.testing.expect(table.find(first) != null);
    try std.testing.expect(table.find(second) != null);

    const removed = table.remove(first).?;
    try std.testing.expectEqual(first, removed.id);
    try std.testing.expect(table.find(first) == null);
    removed.file.close(std.testing.io);

    const third = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    try std.testing.expectEqual(first.index, third.index);
    try std.testing.expect(third.generation != first.generation);
    try std.testing.expect(table.find(first) == null);
    try std.testing.expect(table.find(third) != null);
}

test "ハンドル表はread/write/seek-end/truncateを同一モジュールで検証できる" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "handle-io-test.txt" });
    defer std.testing.allocator.free(path);

    const id = try table.open(std.testing.io, .{ .path = path, .mode = .write_create_truncate });
    const file = &table.find(id).?.file;
    try std.testing.expectEqual(@as(usize, 3), try writeAtCurrent(std.testing.io, file.*, "abc"));
    try std.testing.expectEqual(@as(usize, 4), try writeAtCurrent(std.testing.io, file.*, "defg"));

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    const reader = &table.find(reader_id).?.file;
    var buffer: [16]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, reader.*, &buffer);
    try std.testing.expectEqual(@as(usize, 7), read);
    try std.testing.expectEqualSlices(u8, "abcdefg", buffer[0..read]);
    try std.testing.expectEqual(@as(usize, 0), try readAtCurrent(std.testing.io, reader.*, &buffer));

    try setLength(std.testing.io, file.*, 3);
    try std.testing.expectEqual(@as(u64, 3), try endOfFile(std.testing.io, file.*));

    try sync(std.testing.io, file.*);
}

test "ハンドル表のappendは既存内容の末尾へ書く" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "append.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "append.txt", .data = "ab" });

    const writer_id = try table.open(std.testing.io, .{ .path = path, .mode = .append_create });
    try std.testing.expectEqual(@as(usize, 2), try writeHandle(std.testing.io, table.find(writer_id).?, "cd"));
    const removed = table.remove(writer_id).?;
    removed.file.close(std.testing.io);

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abcd", buffer[0..read]);
}

test "a+は開いた直後に先頭から読め、append書込みは末尾へ足す" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "append-read.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "append-read.txt", .data = "abc" });

    const id = try table.open(std.testing.io, .{ .path = path, .mode = .append_read_create });
    const entry = table.find(id).?;
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, entry.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abc", buffer[0..read]);
    try std.testing.expectEqual(@as(usize, 1), try writeHandle(std.testing.io, entry, "X"));

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    const second = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abcX", buffer[0..second]);
}

test "二つのappendハンドルは順に末尾へ書く" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "append-two.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "append-two.txt", .data = "abc" });

    const first = try table.open(std.testing.io, .{ .path = path, .mode = .append_create });
    const second = try table.open(std.testing.io, .{ .path = path, .mode = .append_create });
    try std.testing.expectEqual(@as(usize, 1), try writeHandle(std.testing.io, table.find(first).?, "X"));
    try std.testing.expectEqual(@as(usize, 1), try writeHandle(std.testing.io, table.find(second).?, "Y"));

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abcXY", buffer[0..read]);
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expect(!table.find(first).?.append);
        try std.testing.expect(!table.find(second).?.append);
    }
}

test "appendモードは切詰め後も末尾へ書く" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "append-truncate.txt" });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "append-truncate.txt", .data = "abcdef" });

    const writer_id = try table.open(std.testing.io, .{ .path = path, .mode = .append_create });
    const entry = table.find(writer_id).?;
    try setLength(std.testing.io, entry.file, 2);
    try std.testing.expectEqual(@as(usize, 2), try writeHandle(std.testing.io, entry, "xy"));
    const removed = table.remove(writer_id).?;
    removed.file.close(std.testing.io);

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abxy", buffer[0..read]);
}

test "空書込みは0を返しwriteAtCurrentAllは残バイトを書き切る" {
    var table = FileHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "partial-write.txt" });
    defer std.testing.allocator.free(path);

    const id = try table.open(std.testing.io, .{ .path = path, .mode = .write_create_truncate });
    const file = table.find(id).?.file;
    try std.testing.expectEqual(@as(usize, 0), try writeAtCurrent(std.testing.io, file, ""));
    try writeAtCurrentAll(std.testing.io, file, "hello");

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "hello", buffer[0..read]);
}

test "StdinSourceのreadは履歴とEOFを共有カーソルで返す" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "ab\x00cd\xff");
    defer source.deinit();
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "ab\x00c", buffer[0..4]);
    try std.testing.expectEqual(@as(usize, 2), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "d\xff", buffer[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try source.read(&buffer));
    try std.testing.expect(source.eof);
}

test "StdinSourceのreadLineはCRLF正規化とEOF終端をnextStdinLineと揃える" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "abc\rX\r\n41\nrest\n");
    defer source.deinit();
    try std.testing.expectEqualStrings("abc\rX", (try source.readLine()).?);
    try std.testing.expectEqualStrings("41", (try source.readLine()).?);
    try std.testing.expectEqualStrings("rest", (try source.readLine()).?);
    try std.testing.expect((try source.readLine()) == null);
}

test "StdinSourceはraw読取りと行読取りが同じカーソルを消費する" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "ab\ncd\nef");
    defer source.deinit();
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "ab\n", &buffer);
    try std.testing.expectEqualStrings("cd", (try source.readLine()).?);
    try std.testing.expectEqualStrings("ef", (try source.readLine()).?);
    try std.testing.expect((try source.readLine()) == null);
    try std.testing.expectEqual(@as(usize, 0), try source.read(&buffer));
}

test "StdinSourceのdrainAllは消費済みを含む全履歴を返す" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "ab\ncd");
    defer source.deinit();
    try std.testing.expectEqualStrings("ab", (try source.readLine()).?);
    try std.testing.expectEqualStrings("ab\ncd", try source.drainAll());
}

test "StdinSourceのfillはread_fnを通じて履歴へ追記する" {
    const Feeder = struct {
        chunks: []const []const u8,
        index: usize = 0,
        fn read(pointer: *anyopaque, buffer: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.index >= self.chunks.len) return 0;
            const chunk = self.chunks[self.index];
            self.index += 1;
            const count = @min(buffer.len, chunk.len);
            @memcpy(buffer[0..count], chunk[0..count]);
            return count;
        }
    };
    var feeder = Feeder{ .chunks = &.{ "ab", "\ncd" } };
    var source = StdinSource.init(std.testing.allocator, &feeder, Feeder.read);
    defer source.deinit();
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "ab", &buffer);
    try std.testing.expectEqualStrings("", (try source.readLine()).?);
    try std.testing.expectEqualStrings("cd", (try source.readLine()).?);
    try std.testing.expectEqualStrings("ab\ncd", try source.drainAll());
    try std.testing.expect(source.eof);
}

test "StdinSourceのreadLineはEOF終端行の末尾CRを落とす" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "abc\r");
    defer source.deinit();
    try std.testing.expectEqualStrings("abc", (try source.readLine()).?);
    try std.testing.expect((try source.readLine()) == null);
}

test "StdinSourceの0バイトreadはEOFでもなくカーソルも進めない" {
    var source = try StdinSource.initPreloaded(std.testing.allocator, "ab");
    defer source.deinit();
    try std.testing.expectEqual(@as(usize, 0), try source.read(&.{}));
    try std.testing.expect(!source.eof);
    try std.testing.expectEqual(@as(usize, 0), source.consumed);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "ab", &buffer);
}

test "StdinSourceのfillは履歴上限超過でStreamTooLongを返す" {
    const Feeder = struct {
        chunks: []const []const u8,
        index: usize = 0,
        fn read(pointer: *anyopaque, buffer: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.index >= self.chunks.len) return 0;
            const chunk = self.chunks[self.index];
            self.index += 1;
            const count = @min(buffer.len, chunk.len);
            @memcpy(buffer[0..count], chunk[0..count]);
            return count;
        }
    };
    var feeder = Feeder{ .chunks = &.{ "ab", "cdefgh", "i" } };
    var source = StdinSource.init(std.testing.allocator, &feeder, Feeder.read);
    defer source.deinit();
    source.max_history_bytes = 8;
    var buffer: [8]u8 = undefined;
    // 上限ちょうどまでは受理する（2+6=8）。
    try std.testing.expectEqual(@as(usize, 2), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "ab", buffer[0..2]);
    try std.testing.expectEqual(@as(usize, 6), try source.read(&buffer));
    try std.testing.expectEqualSlices(u8, "cdefgh", buffer[0..6]);
    // 上限超過はStreamTooLong。既読ぶんは保持される。
    try std.testing.expectError(error.StreamTooLong, source.read(&buffer));
    try std.testing.expectEqualStrings("abcdefgh", source.history.items);
    // 粘着: 再試行はreaderを呼ばず即StreamTooLongを返す（feederは進まない）。
    try std.testing.expectError(error.StreamTooLong, source.read(&buffer));
    try std.testing.expectEqual(@as(usize, 3), feeder.index);
}

test "StdinSourceは上限ちょうどの入力をEOFまで受理する" {
    const Feeder = struct {
        chunk: []const u8,
        done: bool = false,
        fn read(pointer: *anyopaque, buffer: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.done) return 0;
            self.done = true;
            const count = @min(buffer.len, self.chunk.len);
            @memcpy(buffer[0..count], self.chunk[0..count]);
            return count;
        }
    };
    var feeder = Feeder{ .chunk = "abcdefgh" };
    var source = StdinSource.init(std.testing.allocator, &feeder, Feeder.read);
    defer source.deinit();
    source.max_history_bytes = 8;
    try std.testing.expectEqualStrings("abcdefgh", try source.drainAll());
    try std.testing.expect(source.eof);
}
