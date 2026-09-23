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
const lock_model = @import("lock_model.zig");
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
    alias: ?[]const u8 = null,
};

pub const Document = struct {
    lock_sha256: []const u8,
    profile: []const u8,
    runtime: []const u8,
    packages: []const PackageRecord,
    /// lock `input.mutablePaths` の写し。mutable path 依存の metadata
    /// （exports/commands）を環境へ snapshot するため、宣言 dir の内容が
    /// lock 再生成を要しない範囲で変わっても環境の陳腐化を検出できる
    /// ようにする。
    mutable_paths: []const lock_model.MutablePath = &.{},
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
    try writer.writeAll(",\"mutablePaths\":[");
    for (doc.mutable_paths, 0..) |mutable, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, mutable.path);
        try writer.writeAll(",\"sha256\":");
        try writeJsonString(writer, mutable.sha256);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"packages\":{");
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
                if (item.alias) |alias| {
                    try writer.writeAll(",\"alias\":");
                    try writeJsonString(writer, alias);
                }
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

/// `.nako` 管理下の dir を実 dir として開く。管理 dir 自体が symlink
/// （攻撃的なプロジェクトや他主体による改変）なら、リンクのみを除去
/// して実 dir を作り直す。`deleteTree` 等は entry 内の symlink を
/// 追従しないが、管理 dir 自身の symlink は openDir が追従して管理外
/// を走査・削除し得るため、ここで排除する。
/// Windows は `OPEN_REPARSE_POINT` が symlink 本体を正常に開くため、
/// open 後の stat で `.sym_link` も検出する。
pub fn ensureManagedDir(io: std.Io, path: []const u8) !void {
    var opened = try openManagedDir(io, path, false);
    opened.close(io);
}

/// 管理 dir を no-follow で開き、open 後の stat で leaf symlink/reparse
/// point を検出したらリンク本体のみ除去して作り直す。`iterate` 指定は
/// 走査目的の呼出し側で立てる。
pub fn openManagedDir(io: std.Io, path: []const u8, iterate: bool) !std.Io.Dir {
    while (true) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{
            .follow_symlinks = false,
            .iterate = iterate,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().createDirPath(io, path);
                continue;
            },
            error.SymLinkLoop, error.NotDir => {
                // leaf symlink・実ファイルはリンク/ファイル本体のみ除去する
                // （対象の中身は消えない）。
                removeManagedLeaf(io, path) catch {};
                try std.Io.Dir.cwd().createDirPath(io, path);
                continue;
            },
            else => return err,
        };
        const stat = dir.stat(io) catch |err| {
            dir.close(io);
            return err;
        };
        if (stat.kind != .sym_link) return dir;
        dir.close(io);
        // リンク本体だけを消す。Windows の directory reparse point は
        // unlink 系でなく rmdir 系が必要なため両方を試す。
        removeManagedLeaf(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
    }
}

/// symlink として確定した leaf をリンク本体だけ削除する。Windows の
/// directory reparse point は `DeleteFile` 系でなく `RemoveDirectory`
/// 系が必要なため `IsDir`/`AccessDenied` では `deleteDir` に切替える。
fn removeManagedLeaf(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => return std.Io.Dir.cwd().deleteDir(io, path),
        else => return err,
    };
}

/// 管理 dir ハンドル相対で lock file を排他 lock 付きで開く。
/// `createFile` は leaf symlink を追従して対象を truncate し得るため
/// 使わず、no-follow open（POSIX では `SymLinkLoop` で検出）と
/// `exclusive` 作成を往復させる。open と create の隙間に置かれた
/// symlink も `PathAlreadyExists` → 次周の no-follow open で検出し、
/// リンク本体のみ除去するため安全側に倒れる。
/// Windows では `OPEN_REPARSE_POINT` が symlink 本体を正常に開くため、
/// open 後の stat で `.sym_link` を検出して同じ経路へ合流させる。
/// `edit.lock`（env_state.zig）と `sync.lock`（Store.lockImpl）で共有する。
pub fn openManagedLockFile(dir: std.Io.Dir, io: std.Io, name: []const u8, nonblocking: bool) !std.Io.File {
    while (true) {
        if (dir.openFile(io, name, .{
            .mode = .read_write,
            .follow_symlinks = false,
            .resolve_beneath = true,
            .lock = .exclusive,
            .lock_nonblocking = nonblocking,
        })) |file| {
            const stat = file.stat(io) catch |err| {
                file.close(io);
                return err;
            };
            if (stat.kind == .sym_link) {
                file.close(io);
                try dir.deleteFile(io, name);
                continue;
            }
            return file;
        } else |err| switch (err) {
            error.FileNotFound => {
                if (dir.createFile(io, name, .{
                    .read = true,
                    .exclusive = true,
                    .resolve_beneath = true,
                    .lock = .exclusive,
                    .lock_nonblocking = nonblocking,
                })) |file| {
                    return file;
                } else |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                }
            },
            error.SymLinkLoop => {
                try dir.deleteFile(io, name);
            },
            else => return err,
        }
    }
}

/// `dir` ハンドル相対で `sub_path` 以下を削除する。各段で no-follow
/// stat を行い、symlink はリンク本体のみ除去して中身を再帰削除しない。
/// `std.Io.Dir.deleteTree` は各 entry を no-follow で開くが、Windows の
/// reparse point は no-follow open でも本体を開き得て中身を列挙して
/// しまうため、管理 dir 配下では stat 確認付きのこれを使う。
pub fn deleteTreeChecked(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) !void {
    const stat = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .directory) {
        var child = dir.openDir(io, sub_path, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer child.close(io);
        var it = child.iterate();
        while (try it.next(io)) |entry| {
            try deleteTreeChecked(child, io, entry.name);
        }
        dir.deleteDir(io, sub_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        };
        return;
    }
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        // Windows の directory reparse point は unlink 系でなく rmdir 系。
        error.IsDir, error.AccessDenied => dir.deleteDir(io, sub_path) catch |e2| switch (e2) {
            error.FileNotFound, error.NotDir => {},
            else => return e2,
        },
        else => return err,
    };
}

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
        try ensureManagedDir(io, root);
        const env_path = try std.fs.path.join(gpa, &.{ root, env_dir });
        defer gpa.free(env_path);
        try ensureManagedDir(io, env_path);
        const staging_path = try std.fs.path.join(gpa, &.{ root, staging_dir });
        defer gpa.free(staging_path);
        try ensureManagedDir(io, staging_path);
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
        // `.nako` dir ハンドル相対で `sync.lock` を開く。leaf symlink は
        // openManagedLockFile がリンク本体のみ除去して作り直すため、外部
        // file への truncate・lock を防げる。
        var nako_dir = std.Io.Dir.cwd().openDir(self.io, self.root, .{
            .follow_symlinks = false,
        }) catch |err| return err;
        defer nako_dir.close(self.io);
        var file = openManagedLockFile(nako_dir, self.io, lock_name, nonblocking) catch |err| switch (err) {
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

    /// 公開済み `environment.json` が参照している世代名を復元する。
    /// package の `path` に記録された `.nako/env/<gen>` を走査して最初に
    /// 見つかった世代名を返す。`current` と不一致の場合でも公開環境が
    /// 実際に使っている世代を特定できる（中断復旧時の保守的な世代保持用）。
    /// env.json が無い・読めない・世代参照を含まない場合は null。
    pub fn readPublishedGeneration(self: *const Store, gpa: Allocator) !?[]u8 {
        const bytes = (try self.readEnvironmentJson(gpa)) orelse return null;
        defer gpa.free(bytes);
        // 世代 dir を参照する path は `.nako/env/gen-<hex>/...` 形式。
        const marker = dir_name ++ "/" ++ env_dir ++ "/";
        const at = std.mem.indexOf(u8, bytes, marker) orelse return null;
        const start = at + marker.len;
        if (!std.mem.startsWith(u8, bytes[start..], generation_prefix)) return null;
        var end = start + generation_prefix.len;
        while (end < bytes.len and std.ascii.isHex(bytes[end])) end += 1;
        if (end == start + generation_prefix.len) return null;
        return try gpa.dupe(u8, bytes[start..end]);
    }

    /// 中断残留の staging dir を回収する。`staging/` の中身を全て削除する。
    /// lock 保持中に呼ぶこと（並行する構築中の staging を消さないため）。
    /// `staging/` 自身が symlink なら追従せずリンクのみ除去して作り直す
    /// （管理外の dir を走査して削除しないため）。
    pub fn recoverStaging(self: *const Store) !void {
        const staging = try std.fs.path.join(self.gpa, &.{ self.root, staging_dir });
        defer self.gpa.free(staging);
        // `staging/` 自身が symlink（Windows reparse point 含む）なら
        // openManagedDir がリンクのみ除去して実 dir を作り直す。
        var dir = try openManagedDir(self.io, staging, true);
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            // 開いた dir ハンドル相対で削除する。各段で no-follow stat を
            // 行うため entry が symlink/reparse point でも中身を辿らない。
            deleteTreeChecked(dir, self.io, entry.name) catch continue;
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
        // `env/` 自身が symlink/reparse point の場合もリンクのみ除去して
        // 作り直す（`.nako/env -> ../..` で管理外を走査・削除しないため）。
        var dir = try openManagedDir(self.io, env_path, true);
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
                // dir ハンドル相対 + 各段 no-follow stat で削除する。
                // Windows reparse point の世代 dir でもリンク本体のみ消す。
                deleteTreeChecked(dir, self.io, entry.name) catch continue;
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

test "environment store は readPublishedGeneration で公開環境の参照世代を復元する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    // env.json が無い状態では null。
    try testing.expect((try store.readPublishedGeneration(testing.allocator)) == null);

    const generation = try store.newGeneration(testing.allocator);
    defer testing.allocator.free(generation.generation);
    defer testing.allocator.free(generation.abs_path);
    var json_buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json_buffer.deinit();
    const pkgs = [_]PackageRecord{
        .{ .key = "k", .name = "a", .version = "1.0.0", .id = null, .path = try std.fmt.allocPrint(testing.allocator, ".nako/env/{s}/deps/a", .{generation.generation}) },
    };
    defer testing.allocator.free(pkgs[0].path);
    try emit(testing.allocator, .{ .lock_sha256 = "sha256:00", .profile = "default", .runtime = "lnako", .packages = &pkgs }, &json_buffer.writer);
    try store.commit(generation.generation, json_buffer.written());

    const published = (try store.readPublishedGeneration(testing.allocator)).?;
    defer testing.allocator.free(published);
    try testing.expectEqualStrings(generation.generation, published);

    // 世代参照を含まない env.json では null（保守判定で prune を見送る側）。
    const json_path = try std.fs.path.join(testing.allocator, &.{ store.root, environment_file });
    defer testing.allocator.free(json_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = "{\"packages\":[]}\n" });
    try testing.expect((try store.readPublishedGeneration(testing.allocator)) == null);
}
