const std = @import("std");
const cache_key = @import("cache_key.zig");
const manifest_mod = @import("manifest.zig");
const materialize_tree = @import("materialize.zig");
const npkg_files = @import("npkg_files.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

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
    } else if (std.mem.eql(u8, source_kind, "path")) blk: {
        // immutable path 依存の native export は、世代内複製をさらに
        // `.nako/native/` の安定 root へ移す。key は sync と同じく内容
        // pin（`artifacts["source"].sha256`）から導出する。mutable は宣言
        // path を生参照するため安定 root を持たない。
        const mutable_value = get(source, "mutable");
        const mutable = if (mutable_value) |value| (value == .bool and value.bool) else false;
        if (mutable) return null;
        const rel = requiredString(source, "path") orelse return error.InvalidEnvironment;
        const artifacts = asObject(get(lock_entry, "artifacts") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const artifact = asObject(artifacts.get("source") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const pin = requiredString(artifact, "sha256") orelse return error.InvalidEnvironment;
        break :blk try cache_key.artifactKey(allocator, "path", pin, rel);
    } else if (std.mem.eql(u8, source_kind, "registry") or std.mem.eql(u8, source_kind, "static")) blk: {
        // sync の selectArtifact と同じく、implementation 省略は source 扱い。
        const implementation = requiredString(lock_entry, "implementation") orelse "source";
        const artifacts = asObject(get(lock_entry, "artifacts") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        // lock.zig は artifacts を key 昇順に parse してから kind 一致の先頭を
        // 選ぶため、ここでも挿入順ではなく最小 key の kind 一致 record を選ぶ。
        var selected: ?std.json.ObjectMap = null;
        var selected_key: []const u8 = "";
        var iterator = artifacts.iterator();
        while (iterator.next()) |item| {
            const artifact = asObject(item.value_ptr.*) orelse return error.InvalidEnvironment;
            const kind = requiredString(artifact, "kind") orelse return error.InvalidEnvironment;
            if (!std.mem.eql(u8, kind, implementation)) continue;
            if (selected == null or std.mem.order(u8, item.key_ptr.*, selected_key) == .lt) {
                selected = artifact;
                selected_key = item.key_ptr.*;
            }
        }
        const artifact = selected orelse return error.InvalidEnvironment;
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
pub fn validateRoot(allocator: Allocator, io: std.Io, project_root: []const u8, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, ".nako/native/") or !npkg_files.isCanonicalPath(path)) return error.InvalidEnvironment;
    const package_path = try std.fs.path.resolve(allocator, &.{ project_root, path });
    defer allocator.free(package_path);
    const native_root_path = try std.fs.path.join(allocator, &.{ project_root, ".nako", "native" });
    defer allocator.free(native_root_path);
    const native_root = realPathDirAlloc(allocator, io, native_root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    defer allocator.free(native_root);
    const package_root = realPathDirAlloc(allocator, io, package_path) catch |err| switch (err) {
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
    errdefer allocator.free(relative);
    const native_root = try ensureNativeStoreRoot(allocator, io, project_root);
    defer allocator.free(native_root);
    const destination = try std.fs.path.join(allocator, &.{ native_root, key });
    defer allocator.free(destination);
    if (std.Io.Dir.cwd().access(io, destination, .{})) |_| {
        if (try treesEquivalent(allocator, io, tree_abs, destination)) return relative;
        return error.CorruptExistingRoot;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const stage_root = try std.fs.path.join(allocator, &.{ native_root, "staging" });
    defer allocator.free(stage_root);
    try std.Io.Dir.cwd().createDirPath(io, stage_root);
    const stage_parent = try std.fs.path.join(allocator, &.{ stage_root, generation });
    defer allocator.free(stage_parent);
    const stage = try std.fs.path.join(allocator, &.{ stage_parent, key });
    defer allocator.free(stage);
    defer std.Io.Dir.cwd().deleteTree(io, stage_parent) catch {};
    _ = try materialize_tree.copyTree(allocator, io, tree_abs, stage, .{});
    try std.Io.Dir.renameAbsolute(stage, destination, io);
    return relative;
}

fn ensureNativeStoreRoot(allocator: Allocator, io: std.Io, project_root: []const u8) ![]u8 {
    const project_real = try realPathDirAlloc(allocator, io, project_root);
    defer allocator.free(project_real);
    const nako_path = try std.fs.path.join(allocator, &.{ project_real, ".nako" });
    defer allocator.free(nako_path);
    const nako_real = try ensureContainedDirectory(allocator, io, project_real, nako_path);
    defer allocator.free(nako_real);
    const native_path = try std.fs.path.join(allocator, &.{ nako_real, "native" });
    defer allocator.free(native_path);
    return try ensureContainedDirectory(allocator, io, nako_real, native_path);
}

fn ensureContainedDirectory(allocator: Allocator, io: std.Io, parent_real: []const u8, path: []const u8) ![]u8 {
    const existing = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const stat = if (existing) |found| found else blk: {
        try std.Io.Dir.cwd().createDirPath(io, path);
        break :blk try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    };
    if (stat.kind != .directory) return error.UnsafeStorePath;
    const real = try realPathDirAlloc(allocator, io, path);
    errdefer allocator.free(real);
    if (!isWithin(parent_real, real)) return error.UnsafeStorePath;
    return real;
}

fn treesEquivalent(allocator: Allocator, io: std.Io, left: []const u8, right: []const u8) !bool {
    const left_stat = std.Io.Dir.cwd().statFile(io, left, .{ .follow_symlinks = false }) catch return false;
    const right_stat = std.Io.Dir.cwd().statFile(io, right, .{ .follow_symlinks = false }) catch return false;
    if (left_stat.kind != .directory or right_stat.kind != .directory) return false;
    var left_dir = std.Io.Dir.openDirAbsolute(io, left, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer left_dir.close(io);
    var right_dir = std.Io.Dir.openDirAbsolute(io, right, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer right_dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var left_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var right_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var left_iterator = left_dir.iterate();
    while (try left_iterator.next(io)) |entry| try left_names.append(arena, try arena.dupe(u8, entry.name));
    var right_iterator = right_dir.iterate();
    while (try right_iterator.next(io)) |entry| try right_names.append(arena, try arena.dupe(u8, entry.name));
    sortNames(left_names.items);
    sortNames(right_names.items);
    if (left_names.items.len != right_names.items.len) return false;
    for (left_names.items, right_names.items) |left_name, right_name| {
        if (!std.mem.eql(u8, left_name, right_name)) return false;
        const left_path = try std.fs.path.join(arena, &.{ left, left_name });
        const right_path = try std.fs.path.join(arena, &.{ right, right_name });
        const left_entry = std.Io.Dir.cwd().statFile(io, left_path, .{ .follow_symlinks = false }) catch return false;
        const right_entry = std.Io.Dir.cwd().statFile(io, right_path, .{ .follow_symlinks = false }) catch return false;
        if (left_entry.kind != right_entry.kind) return false;
        switch (left_entry.kind) {
            .directory => if (!try treesEquivalent(arena, io, left_path, right_path)) return false,
            .file => {
                if (left_entry.size != right_entry.size) return false;
                if (left_entry.size == std.math.maxInt(u64)) return false;
                // ツリー全体をarenaへ保持しないよう固定bufferでchunk比較する。
                if (!try filesEquivalent(io, left_path, right_path)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn filesEquivalent(io: std.Io, left: []const u8, right: []const u8) !bool {
    var left_file = std.Io.Dir.cwd().openFile(io, left, .{}) catch return false;
    defer left_file.close(io);
    var right_file = std.Io.Dir.cwd().openFile(io, right, .{}) catch return false;
    defer right_file.close(io);
    var left_buffer: [8192]u8 = undefined;
    var right_buffer: [8192]u8 = undefined;
    var left_reader = left_file.reader(io, &left_buffer);
    var right_reader = right_file.reader(io, &right_buffer);
    while (true) {
        var left_chunk: [8192]u8 = undefined;
        var right_chunk: [8192]u8 = undefined;
        // 側ごとにbuffer満杯まで読み進めて短尺読みの差を正規化する。
        const left_length = fillChunk(&left_reader.interface, &left_chunk) catch return false;
        const right_length = fillChunk(&right_reader.interface, &right_chunk) catch return false;
        if (left_length != right_length) return false;
        if (left_length == 0) return true;
        if (!std.mem.eql(u8, left_chunk[0..left_length], right_chunk[0..right_length])) return false;
    }
}

fn fillChunk(reader: *std.Io.Reader, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const length = try reader.readSliceShort(buffer[total..]);
        if (length == 0) break;
        total += length;
    }
    return total;
}

fn sortNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
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

fn temporaryRootAlloc(allocator: Allocator, io: std.Io, directory: std.Io.Dir) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

test "native artifact root selects first matching kind despite platform keys and duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"source":{"type":"registry"},"implementation":"native","artifacts":{"linux-x86_64":{"kind":"native","url":"https://example.invalid/first","sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"macos-arm64":{"kind":"native","url":"https://example.invalid/second","sha256":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}
    , .{});
    defer parsed.deinit();
    const entry = asObject(parsed.value).?;
    const root = try expectedRoot(allocator, entry.get("source").?.object, entry);
    const first_key = try cache_key.artifactKey(allocator, "artifact", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "https://example.invalid/first");
    const expected = try relativeRoot(allocator, first_key);
    try testing.expectEqualStrings(expected, root.?);
}

test "native artifact rootは同kind複数recordをkey昇順で選択する" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    // lock.zig の parse は artifacts を key 昇順に並べ替えてから kind 一致の
    // 先頭を選ぶ。逆順の挿入順でも "aaa" record と一致しなければならない。
    const parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"source":{"type":"registry"},"implementation":"native","artifacts":{"zzz":{"kind":"native","url":"https://example.invalid/last","sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"aaa":{"kind":"native","url":"https://example.invalid/first","sha256":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}
    , .{});
    defer parsed.deinit();
    const entry = asObject(parsed.value).?;
    const root = try expectedRoot(allocator, entry.get("source").?.object, entry);
    const first_key = try cache_key.artifactKey(allocator, "artifact", "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "https://example.invalid/first");
    const expected = try relativeRoot(allocator, first_key);
    try testing.expectEqualStrings(expected, root.?);
}

test "native artifact rootはimplementation省略時にsync同様source artifactを選ぶ" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"source":{"type":"registry"},"artifacts":{"bin":{"kind":"native","url":"https://example.invalid/native","sha256":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"src":{"kind":"source","url":"https://example.invalid/source","sha256":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}}
    , .{});
    defer parsed.deinit();
    const entry = asObject(parsed.value).?;
    const root = try expectedRoot(allocator, entry.get("source").?.object, entry);
    const source_key = try cache_key.artifactKey(allocator, "artifact", "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "https://example.invalid/source");
    const expected = try relativeRoot(allocator, source_key);
    try testing.expectEqualStrings(expected, root.?);
}

test "native artifact rootはimmutable path依存を内容pinから導出しmutableは持たない" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    // immutable path 依存は世代内複製の pin（`artifacts["source"].sha256`）から
    // sync と同じ `artifactKey("path", pin, rel)` の安定 root を導出する。
    const parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"source":{"type":"path","path":"deps/imm"},"artifacts":{"source":{"sha256":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}}
    , .{});
    defer parsed.deinit();
    const entry = asObject(parsed.value).?;
    const root = try expectedRoot(allocator, entry.get("source").?.object, entry);
    const expected_key = try cache_key.artifactKey(allocator, "path", "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "deps/imm");
    const expected = try relativeRoot(allocator, expected_key);
    try testing.expectEqualStrings(expected, root.?);

    // mutable path は宣言 dir を生参照するため安定 root を持たない。
    const mutable_parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"source":{"type":"path","path":"deps/mut","mutable":true},"artifacts":{"source":{"sha256":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}}
    , .{});
    defer mutable_parsed.deinit();
    const mutable_entry = asObject(mutable_parsed.value).?;
    try testing.expect((try expectedRoot(allocator, mutable_entry.get("source").?.object, mutable_entry)) == null);
}

test "native materialize reuses an equivalent root and rejects a changed file" {
    const io = testing.io;
    const allocator = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "source/subdir");
    try temporary.dir.writeFile(io, .{ .sub_path = "source/subdir/main.nako3", .data = "verified" });
    const root = try temporaryRootAlloc(allocator, io, temporary.dir);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);

    const first = try materialize(allocator, io, root, source, "key", "gen-first");
    defer allocator.free(first);
    const second = try materialize(allocator, io, root, source, "key", "gen-second");
    defer allocator.free(second);
    try testing.expectEqualStrings(first, second);

    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/native/key/subdir/main.nako3", .data = "tampered" });
    try testing.expectError(error.CorruptExistingRoot, materialize(allocator, io, root, source, "key", "gen-third"));
}

test "native materialize rejects an escaping native store symlink" {
    const io = testing.io;
    const allocator = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "source");
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.createDirPath(io, "outside");
    const root = try temporaryRootAlloc(allocator, io, temporary.dir);
    defer allocator.free(root);
    const outside = try std.fs.path.join(allocator, &.{ root, "outside" });
    defer allocator.free(outside);
    temporary.dir.symLink(io, outside, ".nako/native", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    try testing.expectError(error.UnsafeStorePath, materialize(allocator, io, root, source, "key", "gen-link"));
}

test "stable native root resolves only within .nako/native" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/native/artifact-abc123");
    const root = try temporaryRootAlloc(testing.allocator, io, temporary.dir);
    defer testing.allocator.free(root);
    const resolved = try validateRoot(testing.allocator, io, root, ".nako/native/artifact-abc123");
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.startsWith(u8, resolved, root));
    try testing.expectError(error.InvalidEnvironment, validateRoot(testing.allocator, io, root, ".nako/env/gen-test/deps/native"));
}
