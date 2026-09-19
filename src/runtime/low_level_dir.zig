const std = @import("std");
const foundation = @import("low_level_foundation.zig");
const low_level_fs = @import("low_level_fs.zig");
const allocator_telemetry = @import("allocator_telemetry.zig");

/// Issue #33の逐次ディレクトリ列挙が返す1エントリ。`name` はWTF-8のバイト列で、
/// 呼び出し側が渡したallocatorで確保される（同じallocatorで `free` する）。
/// `kind` は `stat` と同じ file/directory/symlink/other/unknown の語彙。
pub const Entry = struct {
    name: []u8,
    kind: low_level_fs.FileKind,
};

/// 逐次列挙の1ハンドル。開いたディレクトリと、そのカーソルを持つIteratorを
/// 1つにまとめる。Iteratorは2048 byteの固定バッファを内蔵するため、数万件の
/// ディレクトリでも列挙中の追加メモリはエントリ名の複製ぶんだけになる。
pub const OpenDir = struct {
    id: foundation.HandleId,
    iterator: std.Io.Dir.Iterator,

    fn close(self: *OpenDir, io: std.Io) void {
        self.iterator.reader.dir.close(io);
    }
};

/// 生成番号付きのディレクトリhandle表。ファイル・ハッシュとは別のindex空間
/// （`foundation.dir_handle_index_base` 以上）から払い出し、raw HandleIdが
/// 種別を跨いで衝突しないようにする。close後は同じindexのgenerationを進める
/// ため、index再利用によるuse-after-closeを誤検出しない。
pub const DirHandleTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OpenDir) = .empty,
    generations: std.AutoHashMap(u32, u32),
    free_indices: std.ArrayList(u32) = .empty,
    next_index: u32 = foundation.dir_handle_index_base,

    pub fn init(allocator: std.mem.Allocator) DirHandleTable {
        return .{ .allocator = allocator, .generations = std.AutoHashMap(u32, u32).init(allocator) };
    }

    pub fn deinit(self: *DirHandleTable, io: std.Io) void {
        for (self.entries.items) |*entry| entry.close(io);
        self.entries.deinit(self.allocator);
        self.generations.deinit();
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const DirHandleTable) usize {
        return self.entries.items.len;
    }

    pub fn find(self: *DirHandleTable, id: foundation.HandleId) ?*OpenDir {
        for (self.entries.items) |*entry| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) return entry;
        }
        return null;
    }

    /// ディレクトリを開いて列挙可能なハンドルを返す。列挙はOSが返す順序のまま
    /// （ソートしない）で、`.` と `..` は `next` が除外する。
    pub fn open(self: *DirHandleTable, io: std.Io, path: []const u8) !foundation.HandleId {
        const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        const id = try self.allocateId();
        errdefer self.free_indices.append(self.allocator, id.index) catch {};
        try self.entries.append(self.allocator, .{ .id = id, .iterator = std.Io.Dir.iterateAssumeFirstIteration(dir) });
        return id;
    }

    /// 次のエントリ名をallocatorで複製して返す。EOFはnull。`.` / `..` は
    /// 読み飛ばす。返却した `Entry.name` は呼び出し側がfreeする。
    pub fn next(self: *DirHandleTable, id: foundation.HandleId, io: std.Io, allocator: std.mem.Allocator) !?Entry {
        const entry = self.find(id) orelse return error.BadFileDescriptor;
        while (try entry.iterator.next(io)) |item| {
            // ZigのIteratorは既に `.` / `..` を除外するが、契約として明示する。
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            return .{
                .name = try allocator.dupe(u8, item.name),
                .kind = low_level_fs.kindFrom(item.kind),
            };
        }
        return null;
    }

    /// close時に同じindexのgenerationを進め、空きindexとして再利用する。
    /// 0へ回った場合は1へ飛ばす。
    pub fn remove(self: *DirHandleTable, io: std.Io, id: foundation.HandleId) ?OpenDir {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) {
                var removed = self.entries.swapRemove(index);
                removed.close(io);
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

    fn allocateId(self: *DirHandleTable) !foundation.HandleId {
        if (self.free_indices.pop()) |index| {
            const generation = self.generations.get(index) orelse 1;
            return .{ .index = index, .generation = if (generation == 0) 1 else generation };
        }
        var index: u32 = self.next_index;
        if (index < foundation.dir_handle_index_base) index = foundation.dir_handle_index_base;
        // ファイル・ハッシュのindex空間へ巻き戻らないよう、必ずbase以上に留める。
        while (self.generations.contains(index)) {
            index +%= 1;
            if (index < foundation.dir_handle_index_base) index = foundation.dir_handle_index_base;
        }
        try self.generations.put(index, 1);
        self.next_index = index +% 1;
        if (self.next_index < foundation.dir_handle_index_base) self.next_index = foundation.dir_handle_index_base;
        return .{ .index = index, .generation = 1 };
    }
};

/// ディレクトリの絶対パスを1つ作る（テスト用）。symlinkを解決しない。
pub fn tmpPath(temporary: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    return std.fs.path.join(std.testing.allocator, &.{ directory, name });
}

test "ディレクトリ表は列挙・EOF・二重closeを扱う" {
    var table = DirHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });
    try temporary.dir.createDir(std.testing.io, "sub", .default_dir);
    const path = try tmpPath(&temporary, ".");
    defer std.testing.allocator.free(path);

    const id = try table.open(std.testing.io, path);
    try std.testing.expect(id.index >= foundation.dir_handle_index_base);
    try std.testing.expectEqual(@as(usize, 1), table.len());

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| std.testing.allocator.free(name);
        names.deinit(std.testing.allocator);
    }
    var kinds: std.ArrayList(low_level_fs.FileKind) = .empty;
    defer kinds.deinit(std.testing.allocator);
    while (try table.next(id, std.testing.io, std.testing.allocator)) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.name, "."));
        try std.testing.expect(!std.mem.eql(u8, entry.name, ".."));
        try names.append(std.testing.allocator, entry.name);
        try kinds.append(std.testing.allocator, entry.kind);
    }
    try std.testing.expectEqual(@as(usize, 2), names.items.len);

    const removed = table.remove(std.testing.io, id).?;
    try std.testing.expectEqual(id.index, removed.id.index);
    try std.testing.expect(table.find(id) == null);
    try std.testing.expect(table.remove(std.testing.io, id) == null);
    try std.testing.expectError(error.BadFileDescriptor, table.next(id, std.testing.io, std.testing.allocator));

    // indexは世代を進めて再利用する。
    const reused = try table.open(std.testing.io, path);
    try std.testing.expectEqual(id.index, reused.index);
    try std.testing.expect(reused.generation != id.generation);
    _ = table.remove(std.testing.io, reused).?;
}

test "ディレクトリ表のindexはハッシュ空間へ侵入しない" {
    var table = DirHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    const first = try table.allocateId();
    const second = try table.allocateId();
    try std.testing.expectEqual(foundation.dir_handle_index_base, first.index);
    try std.testing.expectEqual(foundation.dir_handle_index_base + 1, second.index);
    try std.testing.expect(first.index > foundation.hash_handle_index_base);
}

test "存在しないパスと通常ファイルのopenはENOENTとENOTDIRになる" {
    var table = DirHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "" });
    const plain = try tmpPath(&temporary, "plain.txt");
    defer std.testing.allocator.free(plain);
    const missing = try tmpPath(&temporary, "missing");
    defer std.testing.allocator.free(missing);

    try std.testing.expectError(error.NotDir, table.open(std.testing.io, plain));
    try std.testing.expectError(error.FileNotFound, table.open(std.testing.io, missing));
}

test "数万件のディレクトリでも列挙中のメモリはエントリ名ぶんに留まる" {
    // 列挙中の同時確保がエントリ数へ比例しないことを、確保量を数える
    // allocatorで検証する。名前は1件ごとにfreeするため、ピークは
    // 最大ファイル名ぶん（+小さな管理余裕）に収まる。
    var telemetry = try allocator_telemetry.Telemetry.init(std.testing.allocator);
    defer telemetry.deinit();
    const counting = telemetry.allocator();

    var table = DirHandleTable.init(std.testing.allocator);
    defer table.deinit(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const entry_count: usize = 20_000;
    var name_buffer: [32]u8 = undefined;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const name = try std.fmt.bufPrint(&name_buffer, "entry-{d}.dat", .{index});
        var file = try temporary.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    const path = try tmpPath(&temporary, ".");
    defer std.testing.allocator.free(path);

    const id = try table.open(std.testing.io, path);
    var seen: usize = 0;
    while (try table.next(id, std.testing.io, counting)) |entry| {
        counting.free(entry.name);
        seen += 1;
    }
    try std.testing.expectEqual(entry_count, seen);
    _ = table.remove(std.testing.io, id).?;

    const snapshot = telemetry.snapshot();
    try std.testing.expect(snapshot.live_bytes == 0);
    // 一度に保持するのは最大ファイル名 1 件ぶんだけ。20,000件分を
    // 蓄積していればこの上限を大きく超える。
    try std.testing.expect(snapshot.peak_live_bytes <= 64 * 1024);
}
