const std = @import("std");
const foundation = @import("low_level_foundation.zig");

/// Issue #27のストリームI/Oが使う実OSハンドル表。OSのファイル記述子や
/// `std.Io.File` をなでしこ値として公開せず、この表の `HandleId` を介する。
/// Interpreter（Host側CliHost）とAOT（Runtime側）の両方がこの表を持つ。
pub const OpenHandle = struct {
    id: foundation.HandleId,
    file: std.Io.File,
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
        try self.entries.append(self.allocator, .{ .id = id, .file = file });
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
        return self.insert(file);
    }
};

pub const OpenOptions = struct {
    path: []const u8,
    mode: foundation.OpenMode,
    exclusive: bool = false,
};

pub const OpenError = anyerror;
pub const ReadError = anyerror;
pub const WriteError = anyerror;
pub const SyncError = anyerror;
pub const SetLengthError = anyerror;
pub const CloseError = anyerror;

fn openFile(io: std.Io, options: OpenOptions) OpenError!std.Io.File {
    switch (options.mode) {
        .read => return std.Io.Dir.cwd().openFile(io, options.path, .{ .mode = .read_only }),
        .read_write => return std.Io.Dir.cwd().openFile(io, options.path, .{ .mode = .read_write }),
        .write_create_truncate => return std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = false,
            .truncate = true,
            .exclusive = options.exclusive,
        }),
        .write_read_create_truncate => return std.Io.Dir.cwd().createFile(io, options.path, .{
            .read = true,
            .truncate = true,
            .exclusive = options.exclusive,
        }),
        .append_create => {
            const file = try std.Io.Dir.cwd().createFile(io, options.path, .{
                .read = false,
                .truncate = false,
                .exclusive = options.exclusive,
            });
            errdefer file.close(io);
            try seekToEnd(io, file);
            return file;
        },
        .append_read_create => {
            const file = try std.Io.Dir.cwd().createFile(io, options.path, .{
                .read = true,
                .truncate = false,
                .exclusive = options.exclusive,
            });
            errdefer file.close(io);
            try seekToEnd(io, file);
            return file;
        },
    }
}

fn seekToEnd(io: std.Io, file: std.Io.File) !void {
    const end = try file.length(io);
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
    try std.testing.expectEqual(@as(u64, 3), try file.length(std.testing.io));

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
    try std.testing.expectEqual(@as(usize, 2), try writeAtCurrent(std.testing.io, table.find(writer_id).?.file, "cd"));
    const removed = table.remove(writer_id).?;
    removed.file.close(std.testing.io);

    const reader_id = try table.open(std.testing.io, .{ .path = path, .mode = .read });
    var buffer: [8]u8 = undefined;
    const read = try readAtCurrent(std.testing.io, table.find(reader_id).?.file, &buffer);
    try std.testing.expectEqualSlices(u8, "abcd", buffer[0..read]);
}
