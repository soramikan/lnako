//! アーカイブ型 artifact（`tar.gz` / `npm-tarball`）の検証付き展開。
//!
//! gzip 解除 → tar 走査 → `dest_abs` への安全な書き出しを行う。
//! symlink・特殊 entry・非規範 path（`..`・`\`・制御文字・絶対 path）は
//! 拒否し、`materialize.Limits` の量上限を展開途中にも適用する。
//! 展開結果を消費側へ渡す前に `materialize.copyTree` で複製検証を通す
//! ことを想定している（この層は archive 形式の拒否と量の先止めを担う）。

const std = @import("std");
const materialize = @import("materialize.zig");
const npkg_files = @import("npkg_files.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// gzip/tar の形式が壊れている、または宣言された type と一致しない。
    InvalidArchive,
    /// `file`・`directory` 以外の特殊 entry（fifo・デバイス・長名以外の
    /// 未対応 header 等）。
    UnsupportedEntry,
    /// symlink entry を検出した。package tree に symlink は許可しない。
    SymlinkEncountered,
    /// entry 名が規範 path 成分でない（`..`・`.`・`\`・制御文字・絶対）。
    NonCanonicalPath,
    DuplicatePath,
    CaseCollision,
    TooManyEntries,
    FileTooLarge,
    TreeTooLarge,
    TreeTooDeep,
    OutOfMemory,
};

pub const Options = struct {
    /// 先頭から除外する path 成分数。`npm-tarball` は `package/` 前置を
    /// 持つため 1、`tar.gz` は 0。
    strip_components: u32 = 0,
    limits: materialize.Limits = .{},
};

/// tar entry 名を規範化する。`..`・`.`・`\`・制御文字・先頭 `/` は
/// `error.NonCanonicalPath`。`strip_components` 未満しか成分を持たない
/// entry は null（例: npm-tarball の `package/` dir 自身）。
fn normalizeEntryName(raw: []const u8, strip_components: u32, gpa: Allocator) (Error || Allocator.Error)!?[]u8 {
    if (raw.len == 0 or raw[0] == '/') return error.NonCanonicalPath;
    var rel = std.ArrayListUnmanaged(u8).empty;
    errdefer rel.deinit(gpa);
    var depth: u32 = 0;
    var components = std.mem.splitScalar(u8, raw, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.NonCanonicalPath;
        for (component) |byte| {
            if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.NonCanonicalPath;
        }
        depth += 1;
        if (depth <= strip_components) continue;
        if (rel.items.len > 0) try rel.append(gpa, '/');
        try rel.appendSlice(gpa, component);
    }
    if (rel.items.len == 0) return null;
    return try rel.toOwnedSlice(gpa);
}

/// `archive`（gzip 圧縮された tar）を `dest_abs` へ展開する。
/// `dest_abs` は存在しないか空 dir であること（無ければ作る）。
pub fn extractTarGz(gpa: Allocator, io: std.Io, archive: []const u8, dest_abs: []const u8, options: Options) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_abs);
    var input = std.Io.Reader.fixed(archive);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .gzip, &window_buf);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&decompress.reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    // PathSet の key は init allocator が所有する（copyTree と同じく arena
    // 一括解放の契約）。
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    var seen = materialize.PathSet.init(arena_impl.allocator());
    defer {
        seen.seen_exact.deinit();
        seen.seen_lower.deinit();
    }
    var entries: u64 = 0;
    var total_bytes: u64 = 0;

    while (true) {
        const file = it.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TarUnsupportedHeader => return error.UnsupportedEntry,
            else => return error.InvalidArchive,
        } orelse break;
        const rel = (try normalizeEntryName(file.name, options.strip_components, gpa)) orelse continue;
        defer gpa.free(rel);
        if (!npkg_files.isCanonicalPath(rel)) return error.NonCanonicalPath;
        // 深さは成分数。root 直下が 1。
        const depth = std.mem.count(u8, rel, "/") + 1;
        if (depth > options.limits.max_depth) return error.TreeTooDeep;
        entries += 1;
        if (entries > options.limits.max_entries) return error.TooManyEntries;
        try seen.record(rel);

        switch (file.kind) {
            .directory => {
                const abs = try std.fs.path.join(gpa, &.{ dest_abs, rel });
                defer gpa.free(abs);
                std.Io.Dir.cwd().createDirPath(io, abs) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            .file => {
                if (file.size > options.limits.max_file_bytes) return error.FileTooLarge;
                total_bytes += file.size;
                if (total_bytes > options.limits.max_total_bytes) return error.TreeTooLarge;
                const abs = try std.fs.path.join(gpa, &.{ dest_abs, rel });
                defer gpa.free(abs);
                if (std.fs.path.dirname(rel)) |parent| {
                    const parent_abs = try std.fs.path.join(gpa, &.{ dest_abs, parent });
                    defer gpa.free(parent_abs);
                    std.Io.Dir.cwd().createDirPath(io, parent_abs) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }
                var out = std.Io.Dir.cwd().createFile(io, abs, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.DuplicatePath,
                    else => return err,
                };
                defer out.close(io);
                var write_buf: [64 * 1024]u8 = undefined;
                var writer = out.writer(io, &write_buf);
                _ = it.streamRemaining(file, &writer.interface) catch |err| switch (err) {
                    // 書き出し側の失敗は archive ではなく FS の問題。
                    error.WriteFailed => return err,
                    else => return error.InvalidArchive,
                };
                try writer.interface.flush();
            },
            .sym_link => return error.SymlinkEncountered,
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// テスト用に tar を gzip 圧縮した byte 列を作る。`root` は tar 内の
/// 前置 dir（npm-tarball の `package/` 相当。空なら前置なし）。
fn buildTarGz(gpa: Allocator, root: []const u8, files: []const struct { path: []const u8, content: []const u8 }, links: []const struct { path: []const u8, target: []const u8 }) ![]u8 {
    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    if (root.len != 0) try tar_writer.setRoot(root);
    for (files) |file| try tar_writer.writeFileBytes(file.path, file.content, .{});
    for (links) |link| try tar_writer.writeLink(link.path, link.target, .{});
    try tar_writer.finishPedantically();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // Compress.init は出力 buffer の最低容量を要求するため先に確保する。
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(tar_buffer.written());
    try compress.finish();
    return try out.toOwnedSlice();
}

test "unpack extractTarGz は tar.gz を展開してファイルを書き出す" {
    const io = testing.io;
    const archive = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "nako.toml", .content = "[package]\n" },
        .{ .path = "src/index.nako3", .content = "●テストとは\n" },
    }, &.{});
    defer testing.allocator.free(archive);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);

    try extractTarGz(testing.allocator, io, archive, extract_dir, .{});
    const file_path = try std.fs.path.join(testing.allocator, &.{ extract_dir, "src", "index.nako3" });
    defer testing.allocator.free(file_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("●テストとは\n", bytes);
}

test "unpack extractTarGz は strip_components で前置 dir を除外する" {
    const io = testing.io;
    const archive = try buildTarGz(testing.allocator, "package", &.{
        .{ .path = "nako.toml", .content = "[package]\n" },
    }, &.{});
    defer testing.allocator.free(archive);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);

    try extractTarGz(testing.allocator, io, archive, extract_dir, .{ .strip_components = 1 });
    const file_path = try std.fs.path.join(testing.allocator, &.{ extract_dir, "nako.toml" });
    defer testing.allocator.free(file_path);
    try std.Io.Dir.cwd().access(io, file_path, .{});
}

test "unpack extractTarGz は symlink・traversal・重複 entry を拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);

    const symlinked = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "a.txt", .content = "x" },
    }, &.{
        .{ .path = "link.txt", .target = "a.txt" },
    });
    defer testing.allocator.free(symlinked);
    const out1 = try std.fs.path.join(testing.allocator, &.{ dest, "o1" });
    defer testing.allocator.free(out1);
    try testing.expectError(error.SymlinkEncountered, extractTarGz(testing.allocator, io, symlinked, out1, .{}));

    // `..` を含む entry は展開前に拒否する（tar.Writer が作れない形式を
    // 直接 byte 列で検査する代わりに normalizeEntryName で検証）。
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("../escape", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a/../b", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("/abs", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a\\b", 0, testing.allocator));

    // 同一 path の重複は PathSet が検出する。
    const dup = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "dup.txt", .content = "1" },
        .{ .path = "dup.txt", .content = "2" },
    }, &.{});
    defer testing.allocator.free(dup);
    const out2 = try std.fs.path.join(testing.allocator, &.{ dest, "o2" });
    defer testing.allocator.free(out2);
    try testing.expectError(error.DuplicatePath, extractTarGz(testing.allocator, io, dup, out2, .{}));
}

test "unpack extractTarGz は gzip でない入力を InvalidArchive とする" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);
    try testing.expectError(error.InvalidArchive, extractTarGz(testing.allocator, io, "not a gzip stream", extract_dir, .{}));
}
