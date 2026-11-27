//! v1 materialize 環境（`.nako/v1`）の JSON と公開。
//!
//! 形式の正本は `client-bridge-api.md`（作業ツリー直下）。要点:
//!
//! - `.nako/v1/environment.json` は公開ポインタで、atomic replace が commit 点。
//! - 実体は `generations/<gen>/environment.json` と
//!   `generations/<gen>/packages/<sha256hex>/`。
//! - loader は `load` で世代 JSON を読み、package root・export entry の実在を
//!   no-follow で検証する。旧 `.nako/environment.json` は読まない。

const std = @import("std");
const types = @import("v1_types.zig");
const environment = @import("environment.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;
pub const pointer_file = "environment.json";
pub const generation_file = "environment.json";
pub const packages_dir = "packages";
pub const generations_dir = "generations";
pub const max_pointer_bytes: usize = 4 * 1024;
pub const max_environment_bytes: usize = 8 * 1024 * 1024;
pub const max_packages: usize = 2048;
pub const max_exports_per_package: usize = 512;
pub const max_global_commands: usize = 4096;

pub const Export = struct {
    subpath: []const u8,
    entry: []const u8,
    binding: types.Binding,
};

pub const Package = struct {
    id: []const u8,
    version: []const u8,
    kind: types.Kind,
    sha256: []const u8,
    /// 世代 dir 相対の package root（例 `packages/<64hex>`）。
    root: []const u8,
    exports: []const Export = &.{},
    exports_global_commands: bool = false,
    global_commands: []const []const u8 = &.{},
};

pub const Environment = struct {
    generation: []const u8,
    profile: []const u8,
    runtime: types.Runtime,
    target_triple: ?[]const u8 = null,
    lock_sha256: []const u8,
    packages: []const Package = &.{},
    /// `Store.load` が返す場合、全文字列を所有する arena。
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Environment) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }
};

pub fn validGeneration(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "gen-")) return false;
    const hex = name[4..];
    if (hex.len != 16) return false;
    for (hex) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// profile・lock digest・package の (key, sha256, kind) から決定的な世代名を作る。
pub fn generationName(
    allocator: Allocator,
    profile: []const u8,
    lock_sha256: []const u8,
    packages: []const Package,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("lnako-v1-environment\x00");
    hasher.update(profile);
    hasher.update("\x00");
    hasher.update(lock_sha256);
    for (packages) |package| {
        hasher.update("\x00");
        hasher.update(package.id);
        hasher.update("\x00");
        hasher.update(package.version);
        hasher.update("\x00");
        hasher.update(@tagName(package.kind));
        hasher.update("\x00");
        hasher.update(package.sha256);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "gen-{s}", .{hex[0..16]});
}

/// 世代の `environment.json` を決定的なバイト列で書き出す。
pub fn emit(allocator: Allocator, env: *const Environment) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\n  \"schema_version\": 1,\n  \"generation\": ");
    try writeJsonString(writer, env.generation);
    try writer.writeAll(",\n  \"profile\": ");
    try writeJsonString(writer, env.profile);
    try writer.writeAll(",\n  \"runtime\": ");
    try writeJsonString(writer, @tagName(env.runtime));
    if (env.target_triple) |triple| {
        try writer.writeAll(",\n  \"target_triple\": ");
        try writeJsonString(writer, triple);
    }
    try writer.writeAll(",\n  \"lock_sha256\": ");
    try writeJsonString(writer, env.lock_sha256);
    try writer.writeAll(",\n  \"packages\": [");
    for (env.packages, 0..) |package, package_index| {
        if (package_index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\"id\": ");
        try writeJsonString(writer, package.id);
        try writer.writeAll(", \"version\": ");
        try writeJsonString(writer, package.version);
        try writer.writeAll(", \"kind\": ");
        try writeJsonString(writer, @tagName(package.kind));
        try writer.writeAll(", \"sha256\": ");
        try writeJsonString(writer, package.sha256);
        try writer.writeAll(", \"root\": ");
        try writeJsonString(writer, package.root);
        try writer.writeAll(", \"exports\": [");
        for (package.exports, 0..) |export_entry, export_index| {
            if (export_index > 0) try writer.writeAll(", ");
            try writer.writeAll("{\"subpath\": ");
            try writeJsonString(writer, export_entry.subpath);
            try writer.writeAll(", \"entry\": ");
            try writeJsonString(writer, export_entry.entry);
            try writer.writeAll(", \"binding\": ");
            try writeJsonString(writer, @tagName(export_entry.binding));
            try writer.writeAll("}");
        }
        try writer.writeAll("], \"exports_global_commands\": ");
        try writer.writeAll(if (package.exports_global_commands) "true" else "false");
        try writer.writeAll(", \"global_commands\": [");
        for (package.global_commands, 0..) |command, command_index| {
            if (command_index > 0) try writer.writeAll(", ");
            try writeJsonString(writer, command);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("\n  ]\n}\n");
    return output.toOwnedSlice();
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub const LoadError = error{
    InvalidPointer,
    InvalidEnvironment,
    UnsafePath,
    MissingPath,
    TooLarge,
    OutOfMemory,
};

/// `.nako/v1` の管理ハンドル。すべて root 相対で no-follow に開く。
pub const Store = struct {
    io: std.Io,
    nako: std.Io.Dir,
    v1: std.Io.Dir,
    generations: std.Io.Dir,

    pub fn open(io: std.Io, project_dir: std.Io.Dir) !Store {
        var nako = try environment.openManagedChildDir(project_dir, io, ".nako", false);
        errdefer nako.close(io);
        var v1 = try environment.openManagedChildDir(nako, io, "v1", false);
        errdefer v1.close(io);
        const generations = try environment.openManagedChildDir(v1, io, generations_dir, true);
        return .{ .io = io, .nako = nako, .v1 = v1, .generations = generations };
    }

    /// 既存の `.nako/v1` だけを開く（作成しない）。loader 用。
    pub fn openExisting(io: std.Io, project_dir: std.Io.Dir) !?Store {
        var nako = project_dir.openDir(io, ".nako", .{ .iterate = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        errdefer nako.close(io);
        var v1 = nako.openDir(io, "v1", .{ .iterate = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        errdefer v1.close(io);
        const generations = v1.openDir(io, generations_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        return .{ .io = io, .nako = nako, .v1 = v1, .generations = generations };
    }

    pub fn deinit(self: *Store) void {
        self.generations.close(self.io);
        self.v1.close(self.io);
        self.nako.close(self.io);
        self.* = undefined;
    }

    pub fn readPointer(self: *Store, allocator: Allocator) !?[]const u8 {
        const stat = self.v1.statFile(self.io, pointer_file, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.UnsafePath;
        if (stat.kind != .file) return error.InvalidPointer;
        if (stat.size > max_pointer_bytes) return error.TooLarge;
        const file = try self.v1.openFile(self.io, pointer_file, .{ .follow_symlinks = false });
        defer file.close(self.io);
        const bytes = try readLimited(self.io, allocator, file, max_pointer_bytes);
        defer allocator.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidPointer;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidPointer,
        };
        const version = switch (object.get("schema_version") orelse return error.InvalidPointer) {
            .integer => |value| value,
            else => return error.InvalidPointer,
        };
        if (version != schema_version) return error.InvalidPointer;
        const generation = switch (object.get("generation") orelse return error.InvalidPointer) {
            .string => |value| value,
            else => return error.InvalidPointer,
        };
        if (!validGeneration(generation)) return error.InvalidPointer;
        return try allocator.dupe(u8, generation);
    }

    pub fn writePointer(self: *Store, generation: []const u8) !void {
        if (!validGeneration(generation)) return error.InvalidPointer;
        var buffer: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{{\"schema_version\":1,\"generation\":\"{s}\"}}\n", .{generation});
        var atomic = try self.v1.createFileAtomic(self.io, pointer_file, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.replace(self.io);
    }

    /// 指定世代の dir を no-follow で開く。不存在は `error.FileNotFound`。
    pub fn openGeneration(self: *Store, generation: []const u8) !std.Io.Dir {
        if (!validGeneration(generation)) return error.InvalidPointer;
        const dir = try self.generations.openDir(self.io, generation, .{
            .iterate = false,
            .follow_symlinks = false,
        });
        return dir;
    }

    /// staging dir を空にして開く。前回の途中失敗を回収する。
    pub fn openStaging(self: *Store, generation: []const u8) !std.Io.Dir {
        if (!validGeneration(generation)) return error.InvalidPointer;
        const name = try std.fmt.allocPrint(std.heap.page_allocator, ".staging-{s}", .{generation});
        defer std.heap.page_allocator.free(name);
        try environment.deleteTreeChecked(self.v1, self.io, name);
        return environment.openManagedChildDir(self.v1, self.io, name, false);
    }

    /// staging を世代へ rename する。既存世代がある場合は内容を検証して
    /// 再利用する（途中失敗からの再試行を冪等にする）。異なる内容の同名
    /// 世代は退避名へ移してから置換し、rename 失敗時は旧世代を戻す。
    pub fn commitStaging(self: *Store, generation: []const u8, staging: *std.Io.Dir, expected_env: []const u8) !bool {
        if (!validGeneration(generation)) return error.InvalidPointer;
        staging.close(self.io);
        const staging_name = try std.fmt.allocPrint(std.heap.page_allocator, ".staging-{s}", .{generation});
        defer std.heap.page_allocator.free(staging_name);

        const existing = self.generations.statFile(self.io, generation, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |stat| {
            if (stat.kind == .directory) {
                const matches = self.generationMatches(generation, expected_env) catch false;
                if (matches) {
                    try environment.deleteTreeChecked(self.v1, self.io, staging_name);
                    return false;
                }

                // 同名世代を置き換える場合も、rename 成功までは旧世代を
                // 退避名で保持する。rename が失敗しても旧環境を読める。
                const retired_name = try std.fmt.allocPrint(std.heap.page_allocator, ".retired-{s}", .{generation});
                defer std.heap.page_allocator.free(retired_name);
                try environment.deleteTreeChecked(self.v1, self.io, retired_name);
                try self.generations.rename(generation, self.v1, retired_name, self.io);
                self.v1.rename(staging_name, self.generations, generation, self.io) catch |err| {
                    self.v1.rename(retired_name, self.generations, generation, self.io) catch {};
                    return err;
                };
                environment.deleteTreeChecked(self.v1, self.io, retired_name) catch {};
                return true;
            }
            // 壊れた世代・symlink はリンク本体だけを除去して作り直す。
            try environment.deleteTreeChecked(self.generations, self.io, generation);
        }
        try self.v1.rename(staging_name, self.generations, generation, self.io);
        return true;
    }

    fn generationMatches(self: *Store, generation: []const u8, expected_env: []const u8) !bool {
        var dir = try self.openGeneration(generation);
        defer dir.close(self.io);
        const bytes = try readFileLimited(self.io, std.heap.page_allocator, dir, generation_file, max_environment_bytes);
        defer std.heap.page_allocator.free(bytes);
        return std.mem.eql(u8, bytes, expected_env);
    }

    /// 世代 JSON の生バイト列（レポート用）。検証は `load` が行う。
    pub fn readGenerationJson(self: *Store, allocator: Allocator, generation: []const u8) ![]u8 {
        var dir = try self.openGeneration(generation);
        defer dir.close(self.io);
        return readFileLimited(self.io, allocator, dir, generation_file, max_environment_bytes);
    }

    /// 世代 JSON を読み、構造と実在を検証する。
    pub fn load(self: *Store, allocator: Allocator) !?Environment {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const generation = (try self.readPointer(arena.allocator())) orelse {
            arena.deinit();
            return null;
        };
        var dir = self.openGeneration(generation) catch |err| switch (err) {
            error.FileNotFound => return error.MissingPath,
            else => return err,
        };
        defer dir.close(self.io);
        const bytes = try readFileLimited(self.io, allocator, dir, generation_file, max_environment_bytes);
        defer allocator.free(bytes);
        var parsed_env = try parseEnvironment(arena.allocator(), self.io, dir, bytes, generation);
        parsed_env.arena = arena;
        return parsed_env;
    }
};

/// 世代 JSON を解析し、package root と export entry の実在を no-follow で
/// 検証する。
pub fn parseEnvironment(
    allocator: Allocator,
    io: std.Io,
    generation_dir: std.Io.Dir,
    bytes: []const u8,
    expected_generation: []const u8,
) !Environment {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidEnvironment;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidEnvironment,
    };
    try rejectUnknown(root, &.{ "schema_version", "generation", "profile", "runtime", "target_triple", "lock_sha256", "packages" });
    const version = try requiredInteger(root, "schema_version");
    if (version != schema_version) return error.InvalidEnvironment;
    const generation = try requiredString(allocator, root, "generation");
    if (!std.mem.eql(u8, generation, expected_generation)) return error.InvalidEnvironment;
    const profile = try requiredString(allocator, root, "profile");
    if (!types.validLocalName(profile)) return error.InvalidEnvironment;
    const runtime_text = try requiredString(allocator, root, "runtime");
    const runtime = types.parseRuntime(runtime_text) orelse return error.InvalidEnvironment;
    const target_triple = if (root.get("target_triple")) |value|
        try allocator.dupe(u8, try asString(value))
    else
        null;
    if (target_triple) |triple| {
        if (!types.validTargetTriple(triple)) return error.InvalidEnvironment;
    }
    const lock_sha256 = try requiredString(allocator, root, "lock_sha256");
    if (!types.validHash(lock_sha256)) return error.InvalidEnvironment;

    const packages_value = root.get("packages") orelse return error.InvalidEnvironment;
    const packages_array = switch (packages_value) {
        .array => |value| value,
        else => return error.InvalidEnvironment,
    };
    if (packages_array.items.len > max_packages) return error.InvalidEnvironment;

    var packages: std.ArrayList(Package) = .empty;
    var roots: std.StringHashMap(void) = .init(allocator);
    var keys: std.StringHashMap(void) = .init(allocator);
    for (packages_array.items) |value| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidEnvironment,
        };
        try rejectUnknown(object, &.{ "id", "version", "kind", "sha256", "root", "exports", "exports_global_commands", "global_commands" });
        const id = try requiredString(allocator, object, "id");
        if (!types.validId(id)) return error.InvalidEnvironment;
        const package_version = try requiredString(allocator, object, "version");
        if (!types.validPublicVersion(package_version)) return error.InvalidEnvironment;
        const kind_text = try requiredString(allocator, object, "kind");
        const kind = types.parseKind(kind_text) orelse return error.InvalidEnvironment;
        const sha256 = try requiredString(allocator, object, "sha256");
        if (!types.validHash(sha256)) return error.InvalidEnvironment;
        const root_path = try requiredString(allocator, object, "root");
        if (!types.validPath(root_path)) return error.InvalidEnvironment;
        const expected_root = try std.fmt.allocPrint(allocator, "packages/{s}", .{sha256[7..]});
        if (!std.mem.eql(u8, root_path, expected_root)) return error.InvalidEnvironment;
        const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ id, package_version });
        if ((try keys.getOrPut(key)).found_existing) return error.InvalidEnvironment;
        if ((try roots.getOrPut(root_path)).found_existing) return error.InvalidEnvironment;

        const exports = try parseExports(allocator, object);
        const exports_global_commands = try requiredBool(object, "exports_global_commands");
        const global_commands = try parseStringArray(allocator, object, "global_commands");
        if (global_commands.len > max_global_commands) return error.InvalidEnvironment;
        var has_global = false;
        for (exports) |export_entry| {
            if (export_entry.binding == .global) has_global = true;
        }
        if (has_global != exports_global_commands) return error.InvalidEnvironment;

        // 実在検査。root は世代 dir 直下の通常ディレクトリ、entry はその
        // 配下の通常ファイルでなければならない。
        const root_stat = generation_dir.statFile(io, root_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.MissingPath,
            else => return err,
        };
        if (root_stat.kind == .sym_link or root_stat.kind != .directory) return error.UnsafePath;
        for (exports) |export_entry| {
            const entry_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, export_entry.entry });
            const entry_stat = generation_dir.statFile(io, entry_rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return error.MissingPath,
                else => return err,
            };
            if (entry_stat.kind == .sym_link or entry_stat.kind != .file) return error.UnsafePath;
        }

        try packages.append(allocator, .{
            .id = id,
            .version = package_version,
            .kind = kind,
            .sha256 = sha256,
            .root = root_path,
            .exports = exports,
            .exports_global_commands = exports_global_commands,
            .global_commands = global_commands,
        });
    }

    return .{
        .generation = generation,
        .profile = profile,
        .runtime = runtime,
        .target_triple = target_triple,
        .lock_sha256 = lock_sha256,
        .packages = try packages.toOwnedSlice(allocator),
    };
}

fn parseExports(allocator: Allocator, object: std.json.ObjectMap) ![]const Export {
    const value = object.get("exports") orelse return error.InvalidEnvironment;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidEnvironment,
    };
    if (array.items.len > max_exports_per_package) return error.InvalidEnvironment;
    var exports: std.ArrayList(Export) = .empty;
    var seen: std.StringHashMap(void) = .init(allocator);
    for (array.items) |item| {
        const entry_object = switch (item) {
            .object => |entry| entry,
            else => return error.InvalidEnvironment,
        };
        try rejectUnknown(entry_object, &.{ "subpath", "entry", "binding" });
        const subpath = try requiredString(allocator, entry_object, "subpath");
        if (!validSubpath(subpath)) return error.InvalidEnvironment;
        if ((try seen.getOrPut(subpath)).found_existing) return error.InvalidEnvironment;
        const entry_path = try requiredString(allocator, entry_object, "entry");
        if (!types.validPath(entry_path)) return error.InvalidEnvironment;
        const binding_text = try requiredString(allocator, entry_object, "binding");
        const binding = types.parseBinding(binding_text) orelse return error.InvalidEnvironment;
        try exports.append(allocator, .{ .subpath = subpath, .entry = entry_path, .binding = binding });
    }
    return exports.toOwnedSlice(allocator);
}

fn validSubpath(text: []const u8) bool {
    if (std.mem.eql(u8, text, ".")) return true;
    if (!std.mem.startsWith(u8, text, "./")) return false;
    return types.validPath(text[2..]);
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) LoadError!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidEnvironment;
    }
}

fn requiredString(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidEnvironment;
    return allocator.dupe(u8, try asString(value));
}

fn asString(value: std.json.Value) LoadError![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidEnvironment,
    };
}

fn requiredInteger(object: std.json.ObjectMap, name: []const u8) LoadError!i64 {
    const value = object.get(name) orelse return error.InvalidEnvironment;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidEnvironment,
    };
}

fn requiredBool(object: std.json.ObjectMap, name: []const u8) LoadError!bool {
    const value = object.get(name) orelse return error.InvalidEnvironment;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidEnvironment,
    };
}

fn parseStringArray(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = object.get(name) orelse return error.InvalidEnvironment;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidEnvironment,
    };
    var list: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        try list.append(allocator, try allocator.dupe(u8, try asString(item)));
    }
    return list.toOwnedSlice(allocator);
}

fn readFileLimited(io: std.Io, allocator: Allocator, dir: std.Io.Dir, name: []const u8, max_bytes: usize) ![]u8 {
    const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.UnsafePath;
    if (stat.kind != .file) return error.InvalidEnvironment;
    if (stat.size > max_bytes) return error.TooLarge;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    return readLimited(io, allocator, file, max_bytes);
}

fn readLimited(io: std.Io, allocator: Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        else => return err,
    };
    if (bytes.len > max_bytes) {
        allocator.free(bytes);
        return error.TooLarge;
    }
    return bytes;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

test "environment JSON は再解析でき、実在しない entry を拒否する" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "gen-0123456789abcdef/packages/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try temporary.dir.writeFile(io, .{ .sub_path = "gen-0123456789abcdef/packages/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad/index.nako3", .data = "1とは" });
    try temporary.dir.writeFile(io, .{ .sub_path = "gen-0123456789abcdef/environment.json", .data = "" });

    var generation_dir = try temporary.dir.openDir(io, "gen-0123456789abcdef", .{ .follow_symlinks = false });
    defer generation_dir.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = Environment{
        .generation = "gen-0123456789abcdef",
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .lock_sha256 = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        .packages = &.{
            .{
                .id = "@acme/json",
                .version = "1.1.0",
                .kind = .universal,
                .sha256 = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                .root = "packages/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                .exports = &.{.{ .subpath = ".", .entry = "index.nako3", .binding = .scoped }},
            },
        },
    };
    const bytes = try emit(a, &env);
    const parsed = try parseEnvironment(a, io, generation_dir, bytes, "gen-0123456789abcdef");
    try testing.expectEqualStrings("default", parsed.profile);
    try testing.expectEqual(@as(usize, 1), parsed.packages.len);

    // entry を消すと MissingPath。
    try temporary.dir.deleteFile(io, "gen-0123456789abcdef/packages/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad/index.nako3");
    try testing.expectError(error.MissingPath, parseEnvironment(a, io, generation_dir, bytes, "gen-0123456789abcdef"));
}

test "世代名は入力から決定的で、形式を検証する" {
    const a = testing.allocator;
    const packages = [_]Package{
        .{
            .id = "@acme/json",
            .version = "1.1.0",
            .kind = .universal,
            .sha256 = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .root = "packages/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        },
    };
    const one = try generationName(a, "default", "sha256:aa", &packages);
    defer a.free(one);
    const two = try generationName(a, "default", "sha256:aa", &packages);
    defer a.free(two);
    try testing.expectEqualStrings(one, two);
    try testing.expect(validGeneration(one));
    try testing.expect(!validGeneration("gen-XYZ"));
}
