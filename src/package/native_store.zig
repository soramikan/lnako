const std = @import("std");
const cache_key = @import("cache_key.zig");
const manifest_mod = @import("manifest.zig");
const materialize_tree = @import("materialize.zig");
const npkg_files = @import("npkg_files.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn get(object: std.json.ObjectMap, key: []const u8) ?Value {
    return object.get(key);
}

fn asObject(value: Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = get(object, key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = get(object, key) orelse return null;
    return if (value == .string) value.string else null;
}

/// Content-addressed package root used by native exports in environment.json.
pub fn relativeRoot(allocator: Allocator, key: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, ".nako/native/{s}", .{key});
}

/// Derive the same object key used by sync from the locked source fields.
pub fn expectedRoot(allocator: Allocator, source: std.json.ObjectMap, lock_entry: std.json.ObjectMap) !?[]u8 {
    const source_kind = requiredString(source, "type") orelse return error.InvalidEnvironment;
    const key = if (std.mem.eql(u8, source_kind, "git")) blk: {
        const url = requiredString(source, "url") orelse return error.InvalidEnvironment;
        const commit = requiredString(source, "commit") orelse return error.InvalidEnvironment;
        const path = optionalString(source, "path") orelse "";
        break :blk try cache_key.shortKey(allocator, "git", &.{ url, commit, path });
    } else if (std.mem.eql(u8, source_kind, "http")) blk: {
        const url = requiredString(source, "url") orelse return error.InvalidEnvironment;
        const hash = requiredString(source, "hash") orelse return error.InvalidEnvironment;
        break :blk try cache_key.artifactKey(allocator, "http", hash, url);
    } else if (std.mem.eql(u8, source_kind, "registry") or std.mem.eql(u8, source_kind, "static")) blk: {
        const implementation = requiredString(lock_entry, "implementation") orelse return error.InvalidEnvironment;
        const artifacts = asObject(get(lock_entry, "artifacts") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const artifact = asObject(artifacts.get(implementation) orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const url = requiredString(artifact, "url") orelse return error.InvalidEnvironment;
        const hash = requiredString(artifact, "sha256") orelse return error.InvalidEnvironment;
        break :blk try cache_key.artifactKey(allocator, "artifact", hash, url);
    } else {
        return null;
    };
    return try relativeRoot(allocator, key);
}

/// Resolve an environment-supplied stable root and ensure it remains inside the
/// project-owned native store (including through symlinks).
pub fn validateRoot(allocator: Allocator, io: std.Io, project_root: []const u8, path: []const u8) ![:0]u8 {
    if (!std.mem.startsWith(u8, path, ".nako/native/") or !npkg_files.isCanonicalPath(path)) return error.InvalidEnvironment;
    const package_path = try std.fs.path.resolve(allocator, &.{ project_root, path });
    defer allocator.free(package_path);
    const native_root_path = try std.fs.path.join(allocator, &.{ project_root, ".nako", "native" });
    defer allocator.free(native_root_path);
    const native_root = std.Io.Dir.cwd().realPathFileAlloc(io, native_root_path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    defer allocator.free(native_root);
    const package_root = std.Io.Dir.cwd().realPathFileAlloc(io, package_path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    errdefer allocator.free(package_root);
    if (!isWithin(project_root, native_root) or !isWithin(native_root, package_root)) return error.InvalidEnvironment;
    const stat = std.Io.Dir.cwd().statFile(io, package_root, .{}) catch return error.InvalidEnvironment;
    if (stat.kind != .directory) return error.InvalidEnvironment;
    return package_root;
}

/// Copy a complete package tree to an immutable project-local location.
/// The caller supplies its unique generation name for private staging.
pub fn materialize(allocator: Allocator, io: std.Io, project_root: []const u8, tree_abs: []const u8, key: []const u8, generation: []const u8) ![]u8 {
    const relative = try relativeRoot(allocator, key);
    const destination = try std.fs.path.join(allocator, &.{ project_root, relative });
    if (std.Io.Dir.cwd().access(io, destination, .{})) |_| {
        return relative;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const stage_root = try std.fs.path.join(allocator, &.{ project_root, ".nako", "native", "staging" });
    try std.Io.Dir.cwd().createDirPath(io, stage_root);
    const stage_parent = try std.fs.path.join(allocator, &.{ stage_root, generation });
    const stage = try std.fs.path.join(allocator, &.{ stage_parent, key });
    defer std.Io.Dir.cwd().deleteTree(io, stage_parent) catch {};
    _ = try materialize_tree.copyTree(allocator, io, tree_abs, stage, .{});
    try std.Io.Dir.renameAbsolute(stage, destination, io);
    return relative;
}

pub fn manifestMatchesLock(manifest: *const manifest_mod.Manifest, name: []const u8, version: []const u8) bool {
    if (!std.mem.eql(u8, manifest.package.name, name)) return false;
    const locked_version = semver.Version.parse(version) catch return false;
    return manifest.package.version.same(locked_version);
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

const testing = std.testing;

test "stable native root resolves only within .nako/native" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/native/artifact-abc123");
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const resolved = try validateRoot(testing.allocator, io, root, ".nako/native/artifact-abc123");
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.startsWith(u8, resolved, root));
    try testing.expectError(error.InvalidEnvironment, validateRoot(testing.allocator, io, root, ".nako/env/gen-test/deps/native"));
}
