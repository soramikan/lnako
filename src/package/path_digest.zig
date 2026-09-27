//! Portable tree digest shared by lock generation and sync validation.
const std = @import("std");
const builtin = @import("builtin");
const lock_model = @import("lock_model.zig");
const provider = @import("provider.zig");

const Entry = struct { rel: []const u8, kind: std.Io.File.Kind, size: u64 = 0 };

/// Canonical relative names use `/`; on POSIX a backslash remains a filename byte.
pub fn canonicalPath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    var previous_separator = false;
    for (path) |byte| {
        const is_separator = byte == '/' or (builtin.os.tag == .windows and byte == '\\');
        if (is_separator) {
            if (previous_separator) continue;
            try normalized.append(gpa, '/');
        } else {
            try normalized.append(gpa, byte);
        }
        previous_separator = is_separator;
    }
    return normalized.toOwnedSlice(gpa);
}

const ResolvedKind = enum { file, directory, other };

/// readdir が返した kind を digest 用の分類へ正規化する。NFS/FUSE 等
/// `DT_UNKNOWN` を返す fs では `.unknown` のままなので、no-follow stat
/// で実体を判定する。symlink・特殊 file は `.other`（拒否側）へ分類する。
fn resolveEntryKind(io: std.Io, dir: std.Io.Dir, name: []const u8, reported: std.Io.File.Kind) !ResolvedKind {
    return switch (reported) {
        .file => .file,
        .directory => .directory,
        .unknown => blk: {
            const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
            break :blk switch (stat.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            };
        },
        else => .other,
    };
}

fn appendEntries(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, rel: []const u8, entries: *std.ArrayList(Entry)) !void {
    var it = dir.iterate();
    while (it.next(io) catch |err| return err) |entry| {
        // `.nako`/`.git` は digest 対象外。Windows では `.NAKO`/`.GIT`
        // が同一 dir を指すため大小文字非依存で比較する。
        const managed = if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(entry.name, ".nako") or std.ascii.eqlIgnoreCase(entry.name, ".git")
        else
            std.mem.eql(u8, entry.name, ".nako") or std.mem.eql(u8, entry.name, ".git");
        if (managed) continue;
        const joined = if (rel.len == 0) try gpa.dupe(u8, entry.name) else try std.fs.path.join(gpa, &.{ rel, entry.name });
        const child_rel = try canonicalPath(gpa, joined);
        gpa.free(joined);
        const kind = try resolveEntryKind(io, dir, entry.name, entry.kind);
        switch (kind) {
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                try entries.append(gpa, .{ .rel = child_rel, .kind = .file, .size = stat.size });
            },
            .directory => {
                try entries.append(gpa, .{ .rel = child_rel, .kind = .directory });
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try appendEntries(io, gpa, child, child_rel, entries);
            },
            .other => return error.UnsupportedEntry,
        }
    }
}

test "resolveEntryKind は DT_UNKNOWN 相当の entry を stat で判定する" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    try temporary.dir.createDir(io, "sub", .default_dir);
    // readdir が kind を返せない fs でも stat 由来の実体で分類される。
    try std.testing.expectEqual(ResolvedKind.file, try resolveEntryKind(io, temporary.dir, "a.txt", .unknown));
    try std.testing.expectEqual(ResolvedKind.directory, try resolveEntryKind(io, temporary.dir, "sub", .unknown));
    // symlink・特殊 file 報告は従来どおり拒否側（.other）のまま。
    try std.testing.expectEqual(ResolvedKind.other, try resolveEntryKind(io, temporary.dir, "a.txt", .sym_link));
    if (builtin.os.tag != .windows) {
        try temporary.dir.symLink(io, "a.txt", "link.txt", .{});
        // unknown 報告された symlink も stat が .sym_link を返して拒否側。
        try std.testing.expectEqual(ResolvedKind.other, try resolveEntryKind(io, temporary.dir, "link.txt", .unknown));
    }
}

test "digest は管理 dir を除外し POSIX では大小文字違いを別名として数える" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const base = try digest(io, a, root);

    // `.nako`/`.git` は digest 対象外（依存先で sync/build しても
    // 親 lock が陳腐化しない契約）。
    try temporary.dir.createDirPath(io, ".nako/env");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/x", .data = "y" });
    try temporary.dir.createDir(io, ".git", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref" });
    try std.testing.expectEqual(base, try digest(io, a, root));

    // `.NAKO` は Windows（および大小文字非区別 FS）では `.nako` と同一
    // dir なので、先に `.nako` を消してから作成する。Windows では除外、
    // POSIX では別名の通常 entry として digest に乗る。
    try temporary.dir.deleteTree(io, ".nako");
    try temporary.dir.createDir(io, ".NAKO", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = ".NAKO/z", .data = "z" });
    const folded = try digest(io, a, root);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(base, folded);
    } else {
        try std.testing.expect(!std.mem.eql(u8, &base, &folded));
    }
}

fn openFile(io: std.Io, root: std.Io.Dir, rel: []const u8) !std.Io.File {
    var current = root;
    var owns = false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (parts.peek() == null) {
            const file = current.openFile(io, part, .{ .follow_symlinks = false }) catch |err| {
                if (owns) current.close(io);
                return err;
            };
            if (owns) current.close(io);
            return file;
        }
        const next = current.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
            if (owns) current.close(io);
            return err;
        };
        if (owns) current.close(io);
        current = next;
        owns = true;
    }
    if (owns) current.close(io);
    return error.FileSystem;
}

/// Follow only the declared root, never symlinks found inside the tree.
pub fn digest(io: std.Io, gpa: std.mem.Allocator, root: []const u8) ![32]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = true });
    defer dir.close(io);
    return digestDir(io, gpa, dir);
}

/// `digest` の dir handle 版。root の開き方（declared root の symlink
/// follow 等）は呼出し側が済ませる。内部 entry は変わらず no-follow。
pub fn digestDir(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) ![32]u8 {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.rel);
        entries.deinit(gpa);
    }
    try appendEntries(io, gpa, dir, "", &entries);
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.rel, b.rel) == .lt;
        }
    }.less);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries.items) |entry| {
        hasher.update(entry.rel);
        hasher.update(&.{0});
        if (entry.kind == .directory) {
            hasher.update("D");
            continue;
        }
        hasher.update("F");
        var size_le: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_le, entry.size, .little);
        hasher.update(&size_le);
        var file = try openFile(io, dir, entry.rel);
        defer file.close(io);
        // Windows returned file handle is asynchronous although its mode flag is unset.
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            var chunk: [8192]u8 = undefined;
            const n = try reader.interface.readSliceShort(&chunk);
            if (n == 0) break;
            hasher.update(chunk[0..n]);
        }
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

/// lock entry の source artifact に記録された pin hash（`sha256:...` または
/// SRI 表記）。path 依存 pin・materialize 結果の照合に使う。
pub fn pinnedSourceHash(entry: *const lock_model.PackageEntry) ?[]const u8 {
    for (entry.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.key, "source") and artifact.sha256 != null) return artifact.sha256.?;
    }
    return null;
}

pub fn pinHashMatches(actual: [32]u8, recorded: []const u8) bool {
    var normalized: [32]u8 = undefined;
    return lock_model.normalizeSha256(recorded, &normalized) and std.mem.eql(u8, &actual, &normalized);
}

pub fn mutablePathMismatch(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) !?[]const u8 {
    var sets: std.ArrayList([]const lock_model.PackageEntry) = .empty;
    defer sets.deinit(gpa);
    try sets.append(gpa, lock.packages);
    for (lock.profile_packages) |profile| try sets.append(gpa, profile.packages);
    var declared: std.ArrayList([]const u8) = .empty;
    defer declared.deinit(gpa);
    for (sets.items) |set| for (set) |*entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path or !(source.mutable orelse false)) continue;
        try declared.append(gpa, source.path orelse return entry.name);
    };
    // `mutablePaths` が宣言済み package の mutable path source 集合と
    // 完全一致することを digest 計算より先に検証する。片方向だけの
    // 照合では、細工した lock に `..` や絶対 path の余分な record を
    // 混ぜて任意 dir の tree digest（深い再帰読取）を強要できる。
    for (lock.input.mutable_paths) |mutable| {
        var known = false;
        for (declared.items) |rel| {
            if (std.mem.eql(u8, mutable.path, rel)) {
                known = true;
                break;
            }
        }
        if (!known) return mutable.path;
    }
    for (declared.items) |rel| {
        var recorded = false;
        for (lock.input.mutable_paths) |mutable| {
            if (std.mem.eql(u8, mutable.path, rel)) {
                recorded = true;
                break;
            }
        }
        if (!recorded) return rel;
    }
    return mutablePathsMismatch(gpa, io, project_root, lock.input.mutable_paths);
}

pub fn mutablePathsMismatch(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, recorded: []const lock_model.MutablePath) !?[]const u8 {
    for (recorded) |mutable| {
        const abs = if (provider.isAbsoluteDepPath(mutable.path)) mutable.path else try std.fs.path.join(gpa, &.{ project_root, mutable.path });
        const actual_digest = digest(io, gpa, abs) catch return mutable.path;
        const actual = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(actual_digest, .lower)});
        if (!std.mem.eql(u8, actual, mutable.sha256)) return mutable.path;
    }
    return null;
}

/// `root_dir`（pinned handle）相対で `rel` を開き digest する。
/// 宣言 root が directory symlink の場合も `digest` と同じく root のみ
/// follow する。絶対 path 宣言は project root の外なので path 解決する。
fn digestDeclaredDir(io: std.Io, gpa: std.mem.Allocator, root_dir: std.Io.Dir, rel: []const u8) ![32]u8 {
    if (provider.isAbsoluteDepPath(rel)) return digest(io, gpa, rel);
    var dir = try root_dir.openDir(io, rel, .{ .iterate = true, .follow_symlinks = true });
    defer dir.close(io);
    return digestDir(io, gpa, dir);
}

/// `mutablePathsMismatch` の pinned `root_dir` handle 版。rename/replace
/// 競合時も検査対象は pinned root 配下に留まる。
pub fn mutablePathsMismatchDir(gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, recorded: []const lock_model.MutablePath) !?[]const u8 {
    for (recorded) |mutable| {
        const actual_digest = digestDeclaredDir(io, gpa, root_dir, mutable.path) catch return mutable.path;
        const actual = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(actual_digest, .lower)});
        if (!std.mem.eql(u8, actual, mutable.sha256)) return mutable.path;
    }
    return null;
}

/// `mutablePathMismatch` の pinned `root_dir` handle 版。
pub fn mutablePathMismatchDir(gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, lock: *const lock_model.Lock) !?[]const u8 {
    var sets: std.ArrayList([]const lock_model.PackageEntry) = .empty;
    defer sets.deinit(gpa);
    try sets.append(gpa, lock.packages);
    for (lock.profile_packages) |profile| try sets.append(gpa, profile.packages);
    var declared: std.ArrayList([]const u8) = .empty;
    defer declared.deinit(gpa);
    for (sets.items) |set| for (set) |*entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path or !(source.mutable orelse false)) continue;
        try declared.append(gpa, source.path orelse return entry.name);
    };
    for (lock.input.mutable_paths) |mutable| {
        var known = false;
        for (declared.items) |rel| {
            if (std.mem.eql(u8, mutable.path, rel)) {
                known = true;
                break;
            }
        }
        if (!known) return mutable.path;
    }
    for (declared.items) |rel| {
        var recorded = false;
        for (lock.input.mutable_paths) |mutable| {
            if (std.mem.eql(u8, mutable.path, rel)) {
                recorded = true;
                break;
            }
        }
        if (!recorded) return rel;
    }
    return mutablePathsMismatchDir(gpa, io, root_dir, lock.input.mutable_paths);
}

pub fn pathPinMismatch(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) !?[]const u8 {
    var sets: std.ArrayList([]const lock_model.PackageEntry) = .empty;
    defer sets.deinit(gpa);
    try sets.append(gpa, lock.packages);
    for (lock.profile_packages) |profile| try sets.append(gpa, profile.packages);
    for (sets.items) |set| for (set) |*entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path or (source.mutable orelse false)) continue;
        const rel = source.path orelse return entry.name;
        const recorded = pinnedSourceHash(entry) orelse return entry.name;
        const abs = if (provider.isAbsoluteDepPath(rel)) rel else try std.fs.path.join(gpa, &.{ project_root, rel });
        const actual = digest(io, gpa, abs) catch return entry.name;
        if (!pinHashMatches(actual, recorded)) return entry.name;
    };
    return null;
}

/// `pathPinMismatch` の pinned `root_dir` handle 版。rename/replace 競合時も
/// 検査対象は pinned root 配下に留まる。
pub fn pathPinMismatchDir(gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, lock: *const lock_model.Lock) !?[]const u8 {
    var sets: std.ArrayList([]const lock_model.PackageEntry) = .empty;
    defer sets.deinit(gpa);
    try sets.append(gpa, lock.packages);
    for (lock.profile_packages) |profile| try sets.append(gpa, profile.packages);
    for (sets.items) |set| for (set) |*entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path or (source.mutable orelse false)) continue;
        const rel = source.path orelse return entry.name;
        const recorded = pinnedSourceHash(entry) orelse return entry.name;
        const actual = digestDeclaredDir(io, gpa, root_dir, rel) catch return entry.name;
        if (!pinHashMatches(actual, recorded)) return entry.name;
    };
    return null;
}
