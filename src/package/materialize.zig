//! 検証付きのディレクトリ木コピー。package source tree・展開済み artifact・
//! cache entry を `.nako` 世代 dir へ安全に複製する。
//!
//! - 走査はディレクトリハンドル相対で行い、symlink は辿らず検出次第拒否
//!   する（openDir の `follow_symlinks=false` + iterate entry kind）。
//! - 各 entry 名は規範 path 成分（`npkg_files.isCanonicalPath` と同じ
//!   基準：`.`・`..`・`\`・制御文字・空を含まない）であることを要求する。
//! - 同一相対 path の重複と、ASCII 大小文字を畳んだ相対 path の衝突を拒否
//!   する（大小文字非区別 FS への持ち込みでも内容が壊れないように）。
//! - ファイル数・総量・単一ファイル量・深さに上限を設ける。

const std = @import("std");
const npkg_files = @import("npkg_files.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    /// 木内のファイル・ディレクトリ合計の上限。
    max_entries: u32 = 1 << 16,
    /// ファイル内容の総量上限。
    max_total_bytes: u64 = 256 * 1024 * 1024,
    /// 単一ファイルの上限。
    max_file_bytes: u64 = 64 * 1024 * 1024,
    /// 相対 path の深さ上限（成分数）。
    max_depth: u32 = 32,
};

pub const Error = error{
    /// symlink entry を検出した。package tree に symlink は許可しない。
    SymlinkEncountered,
    /// file・directory 以外の特殊 entry（fifo・socket・デバイス等）。
    UnsupportedEntry,
    /// entry 名が規範 path 成分でない（`.`・`..`・`\`・制御文字等）。
    NonCanonicalPath,
    /// 同一相対 path が二度現れた。
    DuplicatePath,
    /// ASCII 大小文字を畳むと衝突する相対 path が存在する。
    CaseCollision,
    TooManyEntries,
    FileTooLarge,
    TreeTooLarge,
    TreeTooDeep,
    OutOfMemory,
};

pub const Result = struct {
    files: u64 = 0,
    directories: u64 = 0,
    total_bytes: u64 = 0,
};

/// コピー時の除外指定。`exclude_names` に一致する entry 名は任意の深さで
/// 複製しない（git checkout の `.git` を除外する等）。
pub const Options = struct {
    limits: Limits = .{},
    exclude_names: []const []const u8 = &.{},
};

/// 相対 path の重複・大小文字衝突を検出する索引。木を歩く側が
/// `record(rel)` で確認しながら使う。内部で保持するキーは init に渡した
/// allocator が所有する。
pub const PathSet = struct {
    seen_exact: std.StringHashMap(void),
    seen_lower: std.StringHashMap(void),

    pub fn init(allocator: Allocator) PathSet {
        return .{
            .seen_exact = std.StringHashMap(void).init(allocator),
            .seen_lower = std.StringHashMap(void).init(allocator),
        };
    }

    /// `rel`（posix `/` 区切りの相対 path）を記録する。既出は
    /// `error.DuplicatePath`、ASCII 大小文字を畳んで一致するものは
    /// `error.CaseCollision`。
    pub fn record(self: *PathSet, rel: []const u8) (Error || Allocator.Error)!void {
        const owned = try self.seen_exact.allocator.dupe(u8, rel);
        if ((try self.seen_exact.getOrPut(owned)).found_existing) return error.DuplicatePath;
        const lower = try std.ascii.allocLowerString(self.seen_lower.allocator, owned);
        if ((try self.seen_lower.getOrPut(lower)).found_existing) return error.CaseCollision;
    }
};

/// `src_abs` の木を `dest_abs` へ複製する。`dest_abs` は存在しないか空
/// であること（既存 entry との衝突は `PathAlreadyExists`）。
/// src 自体が symlink でも拒否する。
pub fn copyTree(
    gpa: Allocator,
    io: std.Io,
    src_abs: []const u8,
    dest_abs: []const u8,
    options: Options,
) !Result {
    // src が symlink かどうかを statFile(follow=false) で確認する。
    const src_stat = try std.Io.Dir.cwd().statFile(io, src_abs, .{ .follow_symlinks = false });
    switch (src_stat.kind) {
        .directory => {},
        .sym_link => return error.SymlinkEncountered,
        else => return error.UnsupportedEntry,
    }

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var paths = PathSet.init(arena);

    var result: Result = .{};
    var state = State{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .options = options,
        .paths = &paths,
        .result = &result,
    };

    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_abs, .{ .iterate = true, .follow_symlinks = false });
    defer src_dir.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dest_abs);
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_abs, .{ .follow_symlinks = false });
    defer dest_dir.close(io);

    try state.walk(&src_dir, &dest_dir, "", 0);
    return result;
}

const State = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    options: Options,
    paths: *PathSet,
    result: *Result,
    entries: u64 = 0,
    total_bytes: u64 = 0,

    fn recordPath(self: *State, rel: []const u8) !void {
        try self.paths.record(rel);
        self.entries += 1;
        if (self.entries > self.options.limits.max_entries) return error.TooManyEntries;
    }

    fn excluded(self: *State, name: []const u8) bool {
        for (self.options.exclude_names) |item| {
            if (std.mem.eql(u8, item, name)) return true;
        }
        return false;
    }

    fn walk(self: *State, src_dir: *std.Io.Dir, dest_dir: *std.Io.Dir, rel_prefix: []const u8, depth: u32) !void {
        if (depth > self.options.limits.max_depth) return error.TreeTooDeep;

        // 走査順を決定的にして、どの制限違反が先に報告されるかを安定させる。
        var names = try std.ArrayList([]const u8).initCapacity(self.arena, 16);
        var kinds = std.StringHashMap(std.Io.File.Kind).init(self.arena);
        var it = src_dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name = try self.arena.dupe(u8, entry.name);
            try names.append(self.arena, name);
            try kinds.put(name, entry.kind);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (names.items) |name| {
            const kind = kinds.get(name).?;
            if (self.excluded(name)) continue;
            // entry 名は単一成分。規範 path として妥当か検査する
            // （`.`・`..`・`\`・制御文字を含む名を拒否）。
            if (!npkg_files.isCanonicalPath(name)) return error.NonCanonicalPath;
            // entry の深さは成分数で数える（root の直下が 1）。
            if (depth + 1 > self.options.limits.max_depth) return error.TreeTooDeep;
            const rel = if (rel_prefix.len == 0)
                try self.arena.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ rel_prefix, name });

            switch (kind) {
                .sym_link => return error.SymlinkEncountered,
                .directory => {
                    try self.recordPath(rel);
                    var child_src = try src_dir.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false });
                    defer child_src.close(self.io);
                    try dest_dir.createDirPath(self.io, name);
                    var child_dest = try dest_dir.openDir(self.io, name, .{ .follow_symlinks = false });
                    defer child_dest.close(self.io);
                    self.result.directories += 1;
                    try self.walk(&child_src, &child_dest, rel, depth + 1);
                },
                .file => {
                    try self.recordPath(rel);
                    const st = try src_dir.statFile(self.io, name, .{ .follow_symlinks = false });
                    if (st.kind == .sym_link) return error.SymlinkEncountered;
                    if (st.kind != .file) return error.UnsupportedEntry;
                    if (st.size > self.options.limits.max_file_bytes) return error.FileTooLarge;
                    self.total_bytes += st.size;
                    if (self.total_bytes > self.options.limits.max_total_bytes) return error.TreeTooLarge;
                    // replace=false は既存 path を原子的に拒否する
                    // （PathAlreadyExists → DuplicatePath）。
                    std.Io.Dir.copyFile(src_dir.*, name, dest_dir.*, name, self.io, .{
                        .replace = false,
                    }) catch |err| switch (err) {
                        error.PathAlreadyExists => return error.DuplicatePath,
                        else => return err,
                    };
                    self.result.files += 1;
                    self.result.total_bytes += st.size;
                },
                else => return error.UnsupportedEntry,
            }
        }
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

fn absPath(temporary: *std.testing.TmpDir, rel: []const u8) ![]u8 {
    const base = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    return try std.fs.path.join(testing.allocator, &.{ base, rel });
}

test "materialize copyTree は木を複製し件数と byte 数を返す" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src/sub");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "abc" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/sub/b.txt", .data = "de" });

    const src = try absPath(&temporary, "src");
    defer testing.allocator.free(src);
    const dest = try absPath(&temporary, "dest");
    defer testing.allocator.free(dest);

    const result = try copyTree(testing.allocator, io, src, dest, .{});
    try testing.expectEqual(@as(u64, 2), result.files);
    try testing.expectEqual(@as(u64, 1), result.directories);
    try testing.expectEqual(@as(u64, 5), result.total_bytes);
    const copied = try temporary.dir.readFileAlloc(io, "dest/sub/b.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("de", copied);
}

test "materialize copyTree は symlink entry を拒否する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/real.txt", .data = "x" });
    try temporary.dir.symLink(io, "real.txt", "src/link.txt", .{});

    const src = try absPath(&temporary, "src");
    defer testing.allocator.free(src);
    const dest = try absPath(&temporary, "dest");
    defer testing.allocator.free(dest);
    try testing.expectError(error.SymlinkEncountered, copyTree(testing.allocator, io, src, dest, .{}));
}

test "materialize copyTree は src 自体の symlink を拒否する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "real");
    try temporary.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const src = try absPath(&temporary, "link");
    defer testing.allocator.free(src);
    const dest = try absPath(&temporary, "dest");
    defer testing.allocator.free(dest);
    try testing.expectError(error.SymlinkEncountered, copyTree(testing.allocator, io, src, dest, .{}));
}

test "materialize copyTree は規範外の entry 名を拒否する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // POSIX では `\` を含むファイル名が作れる。持ち込むと Windows で
    // path 逸脱になるため規範外として拒否する。
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/a\\b", .data = "x" });

    const src = try absPath(&temporary, "src");
    defer testing.allocator.free(src);
    const dest = try absPath(&temporary, "dest");
    defer testing.allocator.free(dest);
    try testing.expectError(error.NonCanonicalPath, copyTree(testing.allocator, io, src, dest, .{}));
}

test "materialize PathSet は重複と ASCII 大小文字衝突を検出する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    var paths = PathSet.init(arena_impl.allocator());

    try paths.record("a/b/c.txt");
    try testing.expectError(error.DuplicatePath, paths.record("a/b/c.txt"));
    try testing.expectError(error.CaseCollision, paths.record("A/b/c.txt"));
    try testing.expectError(error.CaseCollision, paths.record("a/B/c.txt"));
    // 先頭が違えば大小文字の違いだけでは衝突しない。
    try paths.record("a/b/C.txt-other");
    try paths.record("other/b/c.txt");
}

test "materialize copyTree はサイズ・総量・深さの上限を適用する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src/d1/d2/d3");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/big", .data = "12345" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/d1/d2/d3/deep", .data = "x" });

    const src = try absPath(&temporary, "src");
    defer testing.allocator.free(src);

    // 単一ファイル上限。
    {
        const dest = try absPath(&temporary, "d1");
        defer testing.allocator.free(dest);
        try testing.expectError(error.FileTooLarge, copyTree(testing.allocator, io, src, dest, .{
            .limits = .{ .max_file_bytes = 4 },
        }));
    }
    // 総量上限（big 5B + deep 1B = 6B）。
    {
        const dest = try absPath(&temporary, "d2");
        defer testing.allocator.free(dest);
        try testing.expectError(error.TreeTooLarge, copyTree(testing.allocator, io, src, dest, .{
            .limits = .{ .max_total_bytes = 5 },
        }));
    }
    // 深さ上限（d1/d2/d3/deep は深さ 4）。
    {
        const dest = try absPath(&temporary, "d3");
        defer testing.allocator.free(dest);
        try testing.expectError(error.TreeTooDeep, copyTree(testing.allocator, io, src, dest, .{
            .limits = .{ .max_depth = 3 },
        }));
    }
    // 上限内なら成功する。
    {
        const dest = try absPath(&temporary, "ok");
        defer testing.allocator.free(dest);
        const result = try copyTree(testing.allocator, io, src, dest, .{
            .limits = .{ .max_file_bytes = 5, .max_total_bytes = 6, .max_depth = 4 },
        });
        try testing.expectEqual(@as(u64, 2), result.files);
    }
}

test "materialize copyTree は exclude_names を任意の深さで除外する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src/.git/objects");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/.git/HEAD", .data = "ref" });
    try temporary.dir.createDirPath(io, "src/sub/.git");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/sub/.git/config", .data = "x" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/sub/keep.txt", .data = "y" });

    const src = try absPath(&temporary, "src");
    defer testing.allocator.free(src);
    const dest = try absPath(&temporary, "dest");
    defer testing.allocator.free(dest);
    const result = try copyTree(testing.allocator, io, src, dest, .{
        .exclude_names = &.{".git"},
    });
    try testing.expectEqual(@as(u64, 1), result.files);
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "dest/.git", .{}));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "dest/sub/.git", .{}));
    try temporary.dir.access(io, "dest/sub/keep.txt", .{});
}
