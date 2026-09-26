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
        if (std.mem.eql(u8, entry.name, ".nako") or std.mem.eql(u8, entry.name, ".git")) continue;
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

fn pinnedSourceHash(entry: *const lock_model.PackageEntry) ?[]const u8 {
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
    for (sets.items) |set| for (set) |*entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path or !(source.mutable orelse false)) continue;
        const rel = source.path orelse return entry.name;
        var recorded = false;
        for (lock.input.mutable_paths) |mutable| if (std.mem.eql(u8, mutable.path, rel)) {
            recorded = true;
        };
        if (!recorded) return rel;
    };
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
