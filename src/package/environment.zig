//! `.nako/` 環境の構築・切替・検証情報の記録。
//!
//! - 環境は `.nako/env/<generation>/` の世代 dir に構築し、最後に
//!   `.nako/environment.json` を原子的に書き換えて公開する。
//! - 構築は `.nako/staging/<generation>` で行い、中断残留は次回 sync 開始時
//!   の `recoverStaging` で回収する。
//! - sync の並行実行は `.nako/sync.lock` の OS file lock で排他する。
//!   process 終了で lock は自動解放される。
//! - `environment.json` は schema v1（`tools/package-system/schema/
//!   environment.schema.json`）の形で、cnako が `--no-sync` 実行時に
//!   lnako を起動せず整合性を検証できる情報（lockSha256・profile・
//!   runtime・各 package の path/exports/commands）を記録する。

const std = @import("std");
const fetch = @import("fetch.zig");
const npkg_commands = @import("npkg_commands.zig");

const Allocator = std.mem.Allocator;

pub const dir_name = ".nako";
pub const lock_name = "sync.lock";
pub const env_dir = "env";
pub const staging_dir = "staging";
pub const environment_file = "environment.json";
/// 現行世代名を記録する小ファイル。古い世代の保持判定に使う。
/// `environment.json` の公開契約ではなく内部状態で、内容が古くても
/// 余分な世代を残すだけで安全性には影響しない。
pub const current_file = "current";
pub const schema_version: u32 = 1;

/// 世代 dir 名の前置。`env/gen-<hex>`。
pub const generation_prefix = "gen-";

/// `.nako/environment.json` の1 package 分の記録。schema v1 と対応する。
pub const PackageRecord = struct {
    /// packages map のキー（Public ID `pkg:<32hex>`、または id を持たない
    /// source では manifest name 等の一意キー）。
    key: []const u8,
    name: []const u8,
    version: []const u8,
    id: ?[]const u8 = null,
    /// プロジェクト root からの相対 path（`.nako/env/<gen>/deps/<name>`、
    /// path 依存では宣言された相対 path）。
    path: []const u8,
    exports: []const ExportRecord = &.{},
    commands: []const npkg_commands.Command = &.{},
};

pub const ExportRecord = struct {
    name: []const u8,
    path: []const u8,
};

pub const Document = struct {
    lock_sha256: []const u8,
    profile: []const u8,
    runtime: []const u8,
    packages: []const PackageRecord,
};

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

/// `environment.json` の本文を決定的に生成する。packages は key 順。
pub fn emit(gpa: Allocator, doc: Document, writer: *std.Io.Writer) !void {
    const sorted = try gpa.dupe(PackageRecord, doc.packages);
    defer gpa.free(sorted);
    std.mem.sort(PackageRecord, sorted, {}, struct {
        fn lessThan(_: void, a: PackageRecord, b: PackageRecord) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    try writer.writeAll("{\"schemaVersion\":1,\"lockSha256\":");
    try writeJsonString(writer, doc.lock_sha256);
    try writer.writeAll(",\"profile\":");
    try writeJsonString(writer, doc.profile);
    try writer.writeAll(",\"runtime\":");
    try writeJsonString(writer, doc.runtime);
    try writer.writeAll(",\"packages\":{");
    for (sorted, 0..) |package, index| {
        if (index > 0) try writer.writeByte(',');
        try writeJsonString(writer, package.key);
        try writer.writeAll(":{\"name\":");
        try writeJsonString(writer, package.name);
        try writer.writeAll(",\"version\":");
        try writeJsonString(writer, package.version);
        if (package.id) |id| {
            try writer.writeAll(",\"id\":");
            try writeJsonString(writer, id);
        }
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, package.path);
        if (package.exports.len != 0) {
            try writer.writeAll(",\"exports\":[");
            for (package.exports, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll("{\"name\":");
                try writeJsonString(writer, item.name);
                try writer.writeAll(",\"path\":");
                try writeJsonString(writer, item.path);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        }
        if (package.commands.len != 0) {
            try writer.writeAll(",\"commands\":[");
            for (package.commands, 0..) |command, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll("{\"name\":");
                try writeJsonString(writer, command.name);
                if (command.variable) {
                    try writer.writeAll(",\"variable\":true}");
                    continue;
                }
                try writer.writeAll(",\"args\":[");
                for (command.args, 0..) |arg, j| {
                    if (j > 0) try writer.writeByte(',');
                    try writeJsonString(writer, arg);
                }
                try writer.writeAll("],\"josi\":[");
                for (command.josi, 0..) |josi, j| {
                    if (j > 0) try writer.writeByte(',');
                    try writeJsonString(writer, josi);
                }
                try writer.writeByte(']');
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("}}\n");
}

/// `.nako` の排他保持。
pub const LockGuard = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn unlock(self: *LockGuard) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    /// `<project>/.nako` の絶対 path。
    root: []const u8,

    /// `project_root` 配下の `.nako` を開き、必要な下位 dir を作成する。
    /// `project_root` が相対 path の場合は cwd 基準で絶対化して保持する。
    pub fn open(gpa: Allocator, io: std.Io, project_root: []const u8) !Store {
        const project_abs: [:0]u8 = if (std.fs.path.isAbsolute(project_root))
            try gpa.dupeZ(u8, project_root)
        else
            try std.Io.Dir.cwd().realPathFileAlloc(io, project_root, gpa);
        defer gpa.free(project_abs);
        const root = try std.fs.path.join(gpa, &.{ project_abs, dir_name });
        errdefer gpa.free(root);
        try std.Io.Dir.cwd().createDirPath(io, root);
        const env_path = try std.fs.path.join(gpa, &.{ root, env_dir });
        defer gpa.free(env_path);
        try std.Io.Dir.cwd().createDirPath(io, env_path);
        const staging_path = try std.fs.path.join(gpa, &.{ root, staging_dir });
        defer gpa.free(staging_path);
        try std.Io.Dir.cwd().createDirPath(io, staging_path);
        return .{ .gpa = gpa, .io = io, .root = root };
    }

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.root);
        self.* = undefined;
    }

    /// `.nako/sync.lock` を排他取得する。別 process が保持中は
    /// `error.Busy`。OS lock は process 終了で自動解放される。
    pub fn lock(self: *const Store) !LockGuard {
        return self.lockImpl(true);
    }

    /// `lock` の blocking 版。保持中の sync が終わるまで待つ。
    pub fn lockWait(self: *const Store) !LockGuard {
        return self.lockImpl(false);
    }

    fn lockImpl(self: *const Store, nonblocking: bool) !LockGuard {
        const path = try std.fs.path.join(self.gpa, &.{ self.root, lock_name });
        defer self.gpa.free(path);
        var file = std.Io.Dir.cwd().createFile(self.io, path, .{
            .read = true,
            .lock = .exclusive,
            .lock_nonblocking = nonblocking,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.Busy,
            else => return err,
        };
        errdefer file.close(self.io);
        return .{ .file = file, .io = self.io };
    }

    /// `.nako/current` に記録された現行世代名を返す。無ければ null。
    /// 世代名として不正な内容は null として扱う（余分な世代を残す方向）。
    pub fn readCurrent(self: *const Store, gpa: Allocator) !?[]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.root, current_file });
        defer self.gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(bytes);
        const name = std.mem.trim(u8, bytes, " \t\r\n");
        if (!validGenerationName(name)) return null;
        return try gpa.dupe(u8, name);
    }

    /// `.nako/current` を原子的に書き換える。`commit` の環境公開後に呼ぶ。
    pub fn writeCurrent(self: *const Store, generation: []const u8) !void {
        if (!validGenerationName(generation)) return error.InvalidGeneration;
        const path = try std.fs.path.join(self.gpa, &.{ self.root, current_file });
        defer self.gpa.free(path);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, generation);
        try atomic.file.writeStreamingAll(self.io, "\n");
        try atomic.replace(self.io);
    }

    /// `.nako/environment.json` の内容を読む。無ければ null。
    pub fn readEnvironmentJson(self: *const Store, gpa: Allocator) !?[]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.root, environment_file });
        defer self.gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return bytes;
    }

    /// 中断残留の staging dir を回収する。`staging/` の中身を全て削除する。
    /// lock 保持中に呼ぶこと（並行する構築中の staging を消さないため）。
    pub fn recoverStaging(self: *const Store) !void {
        const staging = try std.fs.path.join(self.gpa, &.{ self.root, staging_dir });
        defer self.gpa.free(staging);
        var dir = std.Io.Dir.cwd().openDir(self.io, staging, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const victim = try std.fs.path.join(self.gpa, &.{ staging, entry.name });
            defer self.gpa.free(victim);
            std.Io.Dir.cwd().deleteTree(self.io, victim) catch continue;
        }
    }

    /// `staging` 配下に新しい世代 staging dir を作る。戻り値は
    /// `<root>/staging/gen-<rand>` の絶対 path と世代名。文字列は
    /// `gpa` が所有する（呼出し側の arena へ渡せば一括解放できる）。
    pub const StagingEnv = struct {
        /// `gen-<rand>`。
        generation: []const u8,
        /// `<root>/staging/<generation>`。
        abs_path: []const u8,
    };

    pub fn newGeneration(self: *const Store, gpa: Allocator) !StagingEnv {
        var rand: [8]u8 = undefined;
        std.Io.random(self.io, &rand);
        const generation = try std.fmt.allocPrint(gpa, generation_prefix ++ "{s}", .{std.fmt.bytesToHex(rand, .lower)});
        errdefer gpa.free(generation);
        const abs = try std.fs.path.join(gpa, &.{ self.root, staging_dir, generation });
        errdefer gpa.free(abs);
        try std.Io.Dir.cwd().createDirPath(self.io, abs);
        return .{ .generation = generation, .abs_path = abs };
    }

    /// staging 世代 dir を `env/<generation>` へ rename してから
    /// `environment.json` を原子的に書き換えて公開する。
    /// `environment_bytes` は `emit` の出力。
    /// 失敗時は env.json を変更しない（直前の有効環境がそのまま使える）。
    pub fn commit(self: *const Store, generation: []const u8, environment_bytes: []const u8) !void {
        const staging_abs = try std.fs.path.join(self.gpa, &.{ self.root, staging_dir, generation });
        defer self.gpa.free(staging_abs);
        const env_abs = try std.fs.path.join(self.gpa, &.{ self.root, env_dir, generation });
        defer self.gpa.free(env_abs);
        try std.Io.Dir.renameAbsolute(staging_abs, env_abs, self.io);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, env_abs) catch {};

        // environment.json は最後に原子的に書き換える。rename までは
        // staging の一時ファイルで、crash しても直前の env.json が残る。
        const json_path = try std.fs.path.join(self.gpa, &.{ self.root, environment_file });
        defer self.gpa.free(json_path);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, json_path, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, environment_bytes);
        try atomic.replace(self.io);
    }

    /// `env/` 配下で `keep` に含まれない世代 dir を削除する。
    /// 現行（env.json が参照する世代）と直前世代を keep として渡す想定。
    pub fn pruneGenerations(self: *const Store, keep: []const []const u8) !usize {
        const env_path = try std.fs.path.join(self.gpa, &.{ self.root, env_dir });
        defer self.gpa.free(env_path);
        var dir = std.Io.Dir.cwd().openDir(self.io, env_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(self.io);
        var removed: usize = 0;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            var keep_it = false;
            for (keep) |k| {
                if (std.mem.eql(u8, k, entry.name)) {
                    keep_it = true;
                    break;
                }
            }
            if (!keep_it) {
                const victim = try std.fs.path.join(self.gpa, &.{ env_path, entry.name });
                defer self.gpa.free(victim);
                std.Io.Dir.cwd().deleteTree(self.io, victim) catch continue;
                removed += 1;
            }
        }
        return removed;
    }
};

/// 世代 dir 名が有効か（`gen-` 前置 + 文字種）。
pub fn validGenerationName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, generation_prefix)) return false;
    const rest = name[generation_prefix.len..];
    if (rest.len == 0 or rest.len > 64) return false;
    for (rest) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn openTempStore(temporary: *std.testing.TmpDir) !Store {
    const root = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return try Store.open(testing.allocator, testing.io, root);
}

test "environment emit は schema v1 の決定的 JSON を key 順で生成する" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    const commands = [_]npkg_commands.Command{
        .{ .name = "テスト", .args = &.{"A"}, .josi = &.{"を"} },
        .{ .name = "値", .variable = true },
    };
    const packages = [_]PackageRecord{
        .{ .key = "pkg:22222222222222222222222222222222", .name = "b", .version = "2.0.0", .id = null, .path = "deps/b" },
        .{ .key = "pkg:11111111111111111111111111111111", .name = "a", .version = "1.0.0", .id = "pkg:11111111111111111111111111111111", .path = ".nako/env/gen-aa/deps/a", .exports = &.{.{ .name = "a", .path = "src/a.nako3" }}, .commands = &commands },
    };
    try emit(testing.allocator, .{
        .lock_sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .profile = "default",
        .runtime = "lnako",
        .packages = &packages,
    }, &buffer.writer);

    const text = buffer.writer.buffered();
    // key 順（pkg:1111… が先）に並ぶ。
    const first = std.mem.indexOf(u8, text, "pkg:11111111111111111111111111111111").?;
    const second = std.mem.indexOf(u8, text, "pkg:22222222222222222222222222222222").?;
    try testing.expect(first < second);

    // JSON 構造を parse して schema v1 の必須フィールドを確認する。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("schemaVersion").?.integer);
    try testing.expectEqualStrings("sha256:0000000000000000000000000000000000000000000000000000000000000000", root.get("lockSha256").?.string);
    try testing.expectEqualStrings("default", root.get("profile").?.string);
    try testing.expectEqualStrings("lnako", root.get("runtime").?.string);
    const map = root.get("packages").?.object;
    const a = map.get("pkg:11111111111111111111111111111111").?.object;
    try testing.expectEqualStrings("a", a.get("name").?.string);
    try testing.expectEqualStrings("1.0.0", a.get("version").?.string);
    try testing.expectEqualStrings(".nako/env/gen-aa/deps/a", a.get("path").?.string);
    const commands_value = a.get("commands").?.array;
    try testing.expectEqual(@as(usize, 2), commands_value.items.len);
    try testing.expectEqualStrings("テスト", commands_value.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("A", commands_value.items[0].object.get("args").?.array.items[0].string);
    try testing.expectEqualStrings("を", commands_value.items[0].object.get("josi").?.array.items[0].string);
    try testing.expectEqual(true, commands_value.items[1].object.get("variable").?.bool);
    // id を持たない record は "id" を出力しない。
    try testing.expect(map.get("pkg:22222222222222222222222222222222").?.object.get("id") == null);

    // 同一入力からは常に同一バイト列になる。
    var second_buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer second_buffer.deinit();
    try emit(testing.allocator, .{
        .lock_sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .profile = "default",
        .runtime = "lnako",
        .packages = &packages,
    }, &second_buffer.writer);
    try testing.expectEqualStrings(text, second_buffer.writer.buffered());
}

test "environment store は commit で世代 dir と environment.json を切り替える" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    const generation = try store.newGeneration(testing.allocator);
    defer testing.allocator.free(generation.generation);
    defer testing.allocator.free(generation.abs_path);
    // staging に内容を作る。
    const deps = try std.fs.path.join(testing.allocator, &.{ generation.abs_path, "deps", "a" });
    defer testing.allocator.free(deps);
    try std.Io.Dir.cwd().createDirPath(io, deps);

    try store.commit(generation.generation, "{\"schemaVersion\":1}\n");
    try store.writeCurrent(generation.generation);

    const current = (try store.readCurrent(testing.allocator)).?;
    defer testing.allocator.free(current);
    try testing.expectEqualStrings(generation.generation, current);

    const json = (try store.readEnvironmentJson(testing.allocator)).?;
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"schemaVersion\":1}\n", json);

    // staging dir は env/<gen> へ移動済み。
    const env_gen = try std.fs.path.join(testing.allocator, &.{ store.root, env_dir, generation.generation, "deps", "a" });
    defer testing.allocator.free(env_gen);
    try std.Io.Dir.cwd().access(io, env_gen, .{});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, generation.abs_path, .{}));
}

test "environment store は中断残留の staging を recoverStaging で回収する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    const stale = try std.fs.path.join(testing.allocator, &.{ store.root, staging_dir, "gen-stale" });
    defer testing.allocator.free(stale);
    try std.Io.Dir.cwd().createDirPath(io, stale);
    try store.recoverStaging();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, stale, .{}));
}

test "environment store の lock は保持中に Busy を返し解放後に取得できる" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    var guard = try store.lock();
    try testing.expectError(error.Busy, store.lock());
    guard.unlock();
    var second = try store.lock();
    second.unlock();
}

test "environment store の pruneGenerations は keep 以外の世代を削除する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    for ([_][]const u8{ "gen-aaa", "gen-bbb" }) |name| {
        const dir = try std.fs.path.join(testing.allocator, &.{ store.root, env_dir, name });
        defer testing.allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    const removed = try store.pruneGenerations(&.{"gen-aaa"});
    try testing.expectEqual(@as(usize, 1), removed);
    const kept = try std.fs.path.join(testing.allocator, &.{ store.root, env_dir, "gen-aaa" });
    defer testing.allocator.free(kept);
    try std.Io.Dir.cwd().access(io, kept, .{});
    const dropped = try std.fs.path.join(testing.allocator, &.{ store.root, env_dir, "gen-bbb" });
    defer testing.allocator.free(dropped);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dropped, .{}));
}

test "validGenerationName は gen- 前置と文字種を検査する" {
    try testing.expect(validGenerationName("gen-0123abcd"));
    try testing.expect(!validGenerationName("gen-"));
    try testing.expect(!validGenerationName("other-0123"));
    try testing.expect(!validGenerationName("gen-../x"));
}
