const std = @import("std");
const project_trust = @import("project_trust.zig");

const Allocator = std.mem.Allocator;

fn realPathDirAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var directory = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

/// Find an environment inside the nearest project boundary containing the input.
/// Ancestor search stops at `nako.toml`; shared writable ancestors are never trusted.
pub fn findProjectRoot(allocator: Allocator, io: std.Io, input_path: []const u8) !?[]u8 {
    return findProjectRootDetailed(allocator, io, input_path, null);
}

/// 信頼検証で拒否したことを呼出し側へ伝える戻り値。`rejected` が true なら
/// 「プロジェクトが無い」ではなく「見つかったが書き込み権限検証で拒否した」。
fn reject(rejected: ?*bool) ?[]u8 {
    if (rejected) |flag| flag.* = true;
    return null;
}

pub fn findProjectRootDetailed(allocator: Allocator, io: std.Io, input_path: []const u8, rejected: ?*bool) !?[]u8 {
    if (rejected) |flag| flag.* = false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const absolute_input = try std.Io.Dir.cwd().realPathFileAlloc(io, input_path, temporary);
    const start = std.fs.path.dirname(absolute_input) orelse absolute_input;

    var project_root: ?[]const u8 = null;
    var current = start;
    while (true) {
        const manifest_path = try std.fs.path.join(temporary, &.{ current, "nako.toml" });
        if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
            const canonical_manifest = std.Io.Dir.cwd().realPathFileAlloc(io, manifest_path, temporary) catch return null;
            if (!isPathWithin(current, canonical_manifest) or try project_trust.isUnsafeWritablePath(temporary, io, canonical_manifest)) return reject(rejected);
            project_root = current;
            break;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    const root = project_root orelse return null;

    // Check every directory from the importer through the manifest boundary;
    // parents above the selected boundary are intentionally irrelevant.
    current = start;
    while (true) {
        if (try project_trust.isUnsafeWritablePath(temporary, io, current)) return reject(rejected);
        if (std.mem.eql(u8, current, root)) break;
        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }

    // project root 自体と root〜importer 間が安全でも、root の親が共有
    // writable なら root tree を rename して同じ path の別 project へ置き
    // 換えられる。nako.toml の取り違えで manifest identity ごと偽装でき、
    // importer が属する project 全体の信頼性を崩すため filesystem root まで
    // 遡って fail closed で検査する。
    if (try project_trust.hasUnsafeWritableAncestors(temporary, io, root, "/")) return reject(rejected);

    current = start;
    while (true) {
        const environment_path = try std.fs.path.join(temporary, &.{ current, ".nako", "environment.json" });
        if (std.Io.Dir.cwd().access(io, environment_path, .{})) |_| {
            const nako_path = try std.fs.path.join(temporary, &.{ current, ".nako" });
            const canonical_nako = realPathDirAlloc(temporary, io, nako_path) catch return null;
            const canonical_environment = std.Io.Dir.cwd().realPathFileAlloc(io, environment_path, temporary) catch return null;
            // `.nako` dir 自体が共有writableなら、その下の materialized tree
            // を差し替えて同一 manifest identity を装うことができるため、
            // file だけでなく dir の書き込み権限も検証する。
            if (!isPathWithin(root, canonical_nako) or !isPathWithin(canonical_nako, canonical_environment) or
                try project_trust.isUnsafeWritablePath(temporary, io, canonical_nako) or
                try project_trust.isUnsafeWritablePath(temporary, io, canonical_environment)) return reject(rejected);
            const lock_path = try std.fs.path.join(temporary, &.{ root, "nako.lock" });
            if (std.Io.Dir.cwd().access(io, lock_path, .{})) |_| {
                const canonical_lock = std.Io.Dir.cwd().realPathFileAlloc(io, lock_path, temporary) catch return null;
                if (!isPathWithin(root, canonical_lock) or try project_trust.isUnsafeWritablePath(temporary, io, canonical_lock)) return reject(rejected);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            return try allocator.dupe(u8, root);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (std.mem.eql(u8, current, root)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

fn isPathWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return false;
    return std.fs.path.isSep(path[root.len]);
}
