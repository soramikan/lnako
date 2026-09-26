//! 内容アドレス型パッケージ cache。OS 標準の cache dir に検証済みの
//! package 内容を不変 entry として保存し、`.nako/` 環境が共有利用する。
//!
//! - entry は `objects/<key>/` の dir で、staging で検証を完了してから
//!   原子的に rename して公開する。公開済み entry は変更しない。
//! - 同時に走る取得・公開・clean は `cache.lock` の OS file lock で排他する。
//!   process 終了時に lock は自動解放されるため、中断後に stale lock は残らない。
//! - staging の残留は公開時・clean 時に回収する。

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const materialize = @import("materialize.zig");

const Allocator = std.mem.Allocator;

/// entry 公開完了の marker。staging 内で最後に書き込み、rename 後に存在
/// すれば完全な entry として扱う。公開途中で中断された entry には無い。
pub const complete_marker = ".nako-cache-entry";
pub const lock_name = "cache.lock";
pub const objects_dir = "objects";
pub const staging_dir = "staging";
pub const checkouts_dir = "checkouts";
pub const git_workspaces_dir = "git-workspaces";

/// Git checkout（object database・worktree 全体）を cache へ複写する際の
/// 制限。複写対象は package tree ではなく repository 全体なので、package
/// payload 向けの既定上限（file 64MiB・tree 256MiB）は pack file で容易に
/// 超過する。package 用の厳しい上限は `.git` を除いた object materialize
/// 側で引き続き適用し、ここでは量の上限のみ緩和する。symlink・特殊
/// entry・規範外名の拒否など構造検査は package と同じ規則が残る。
pub const checkout_copy_options: materialize.Options = .{
    .limits = .{
        .max_entries = 1 << 22,
        .max_total_bytes = std.math.maxInt(u64),
        .max_file_bytes = std.math.maxInt(u64),
        .max_depth = 128,
    },
};

pub const Error = error{
    Busy,
    InvalidKey,
    OutOfMemory,
};

/// key に使える文字。hex・`git-<hex>`・`http-<hex>` 等の決定的 ID のみ。
fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

const DigestEntry = struct {
    rel: []const u8,
    kind: std.Io.File.Kind,
    size: u64 = 0,
};

fn digestEntryLessThan(_: void, a: DigestEntry, b: DigestEntry) bool {
    return std.mem.order(u8, a.rel, b.rel) == .lt;
}

fn collectDigestEntries(io: std.Io, gpa: Allocator, dir: std.Io.Dir, rel: []const u8, exclude_names: []const []const u8, entries: *std.ArrayListUnmanaged(DigestEntry)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // 呼出し側指定の除外名（source pin では `.nako`/`.git`）を除く。
        var excluded = false;
        for (exclude_names) |excluded_name| {
            if (std.mem.eql(u8, entry.name, excluded_name)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        const child_rel = if (rel.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fs.path.join(gpa, &.{ rel, entry.name });
        var owns_child_rel = true;
        defer if (owns_child_rel) gpa.free(child_rel);
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                try entries.append(gpa, .{ .rel = child_rel, .kind = .file, .size = stat.size });
                owns_child_rel = false;
            },
            .directory => {
                try entries.append(gpa, .{ .rel = child_rel, .kind = .directory });
                owns_child_rel = false;
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try collectDigestEntries(io, gpa, child, child_rel, exclude_names, entries);
            },
            else => return error.UnsupportedEntry,
        }
    }
}

/// source tree の digest から除く名前。`.nako`（lnako が生成する依存
/// 環境）と `.git`（VCS メタデータ）は source 内容ではないため、path
/// 依存 pin・mutable path の内容 digest ではこの除外が必要（依存先で
/// sync/build しただけで親 lock が陳腐化しないため）。cache entry の
/// integrity digest では `.nako/**` を明示的に同梱した package を正しく
/// 識別できるよう除外しない。
pub const source_pin_exclude = [_][]const u8{ ".nako", ".git" };

/// Root-relative file open. Each directory component is opened without following
/// symlinks, rather than letting an absolute path traversal escape the pinned tree.
fn openRelativeFile(io: std.Io, root: std.Io.Dir, rel: []const u8) !std.Io.File {
    var current = root;
    var owns_current = false;
    errdefer if (owns_current) current.close(io);
    var parts = std.mem.splitScalar(u8, rel, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (parts.peek() == null) {
            const file = try current.openFile(io, part, .{ .follow_symlinks = false });
            if (owns_current) current.close(io);
            owns_current = false;
            return file;
        }
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
    if (owns_current) current.close(io);
    owns_current = false;
    return error.InvalidPath;
}

/// `tree/` の内容 digest。path・種別・size・内容を決定順で hash するため
/// 同一 tree は常に同一 digest。marker 記録と hit 時の再検証に使う。
/// `mutable = false` の path 依存 pin でも同じ digest を利用する。
/// `exclude_names` に列挙した dir/file 名は digest 対象から除く。
pub fn digestTree(io: std.Io, gpa: Allocator, tree_abs: []const u8, exclude_names: []const []const u8) ![32]u8 {
    var tree_dir = try std.Io.Dir.cwd().openDir(io, tree_abs, .{ .iterate = true, .follow_symlinks = false });
    defer tree_dir.close(io);
    return digestTreeFromDir(io, gpa, tree_dir, exclude_names);
}

/// Path dependency では宣言された root 自体が symlink の場合を許す。
/// root を handle 化した後の走査は `digestTreeFromDir` が従来どおり no-follow
/// で行うため、package tree 内部の symlink は引き続き拒否される。
pub fn digestTreeFollowingRoot(io: std.Io, gpa: Allocator, tree_abs: []const u8, exclude_names: []const []const u8) ![32]u8 {
    var tree_dir = try std.Io.Dir.cwd().openDir(io, tree_abs, .{ .iterate = true, .follow_symlinks = true });
    defer tree_dir.close(io);
    return digestTreeFromDir(io, gpa, tree_dir, exclude_names);
}

fn digestTreeFromDir(io: std.Io, gpa: Allocator, tree_dir: std.Io.Dir, exclude_names: []const []const u8) ![32]u8 {
    var entries = std.ArrayListUnmanaged(DigestEntry).empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.rel);
        entries.deinit(gpa);
    }
    try collectDigestEntries(io, gpa, tree_dir, "", exclude_names, &entries);
    std.mem.sort(DigestEntry, entries.items, {}, digestEntryLessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries.items) |entry| {
        hasher.update(entry.rel);
        hasher.update(&.{0});
        switch (entry.kind) {
            .directory => hasher.update("D"),
            .file => {
                hasher.update("F");
                var size_le: [8]u8 = undefined;
                std.mem.writeInt(u64, &size_le, entry.size, .little);
                hasher.update(&size_le);
                // 大きな file を一括確保しないよう、固定 buffer で
                // ストリーミング読み出しして hash を更新する。
                var file = try openRelativeFile(io, tree_dir, entry.rel);
                defer file.close(io);
                var read_buffer: [8192]u8 = undefined;
                // Zig 0.16 の Windows no-follow open は実際には非同期 handle を作るが
                // File.flags.nonblocking を false で返す。positional readerへ実modeを伝え、
                // 必要なbyte offsetを指定した非同期readを正しく待機させる。
                if (builtin.os.tag == .windows) file.flags.nonblocking = true;
                var reader = file.reader(io, &read_buffer);
                while (true) {
                    var chunk: [8192]u8 = undefined;
                    const length = try reader.interface.readSliceShort(&chunk);
                    if (length == 0) break;
                    hasher.update(chunk[0..length]);
                }
            },
            else => unreachable,
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// marker 本文 `sha256:<64hex>` を32バイトへデコードする。不一致は false。
fn parseMarkerDigest(text: []const u8, out: *[32]u8) bool {
    const line = std.mem.trim(u8, text, "\r\n");
    if (line.len != 7 + 64 or !std.mem.startsWith(u8, line, "sha256:")) return false;
    _ = std.fmt.hexToBytes(out, line[7..]) catch return false;
    return true;
}

/// OS 標準の cache dir を返す。環境変数が無い・環境列挙不可なら null。
/// - Windows: `%LOCALAPPDATA%\lnako\cache`（無ければ `%TEMP%\lnako-cache`）
/// - macOS: `~/Library/Caches/lnako`
/// - その他 POSIX: `$XDG_CACHE_HOME/lnako` → `~/.cache/lnako`
pub fn defaultRoot(gpa: Allocator) Allocator.Error!?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            if (try fetch.envVar(gpa, "LOCALAPPDATA")) |base| {
                defer gpa.free(base);
                return try std.fs.path.join(gpa, &.{ base, "lnako", "cache" });
            }
            if (try fetch.envVar(gpa, "TEMP")) |base| {
                defer gpa.free(base);
                return try std.fs.path.join(gpa, &.{ base, "lnako-cache" });
            }
            return null;
        },
        .macos => {
            const home = (try fetch.envVar(gpa, "HOME")) orelse return null;
            defer gpa.free(home);
            return try std.fs.path.join(gpa, &.{ home, "Library", "Caches", "lnako" });
        },
        else => {
            if (try fetch.envVar(gpa, "XDG_CACHE_HOME")) |base| {
                defer gpa.free(base);
                if (base.len != 0) return try std.fs.path.join(gpa, &.{ base, "lnako" });
            }
            const home = (try fetch.envVar(gpa, "HOME")) orelse return null;
            defer gpa.free(home);
            return try std.fs.path.join(gpa, &.{ home, ".cache", "lnako" });
        },
    }
}

/// cache.lock の排他保持。`unlock` で解放して file を閉じる。
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
    /// `objects/`・`staging/`・`cache.lock` を持つ cache ルートの絶対 path
    /// （パス返却 API との互換用。ファイル操作の基準には使用しない）。
    root: []const u8,
    /// open 時点の cache ルートを固定する no-follow directory handle。
    root_dir: std.Io.Dir,

    /// cache 管理下の dir を実 dir として開く。管理 dir 自体が symlink
    /// （共有 cache を別主体が改変した場合等）なら、リンクのみを除去して
    /// 実 dir を作り直す。`deleteTree` は entry 内の symlink を追従しない
    /// が、管理 dir 自身の symlink は openDir が追従して cache 外を
    /// 走査・削除し得るため、ここで排除する。
    fn ensureManagedDir(io: std.Io, path: []const u8) !void {
        return environment.ensureManagedDir(io, path);
    }

    fn openRootRelativeDir(self: *const Store, rel: []const u8, iterate: bool) !std.Io.Dir {
        var current = self.root_dir;
        var owns_current = false;
        errdefer if (owns_current) current.close(self.io);
        var parts = std.mem.splitScalar(u8, rel, std.fs.path.sep);
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
            const next = try current.openDir(self.io, part, .{
                .follow_symlinks = false,
                .iterate = if (parts.peek() == null) iterate else false,
            });
            if (owns_current) current.close(self.io);
            current = next;
            owns_current = true;
        }
        if (!owns_current) return error.InvalidPath;
        return current;
    }

    /// Git 作業領域を選択された cache root の下から no-follow で開く。
    /// Git subprocess・checkout の読書きはこの pinned handle 相対で行い、
    /// root path 文字列を subprocess の `-C` 等へ渡さない（root の rename/
    /// 置換で path が別 tree を指し得るため）。
    pub fn openGitWorkspaceRoot(self: *const Store) !std.Io.Dir {
        return self.openRootChild(git_workspaces_dir, true);
    }

    /// root 内の managed directory を root handle 相対で no-follow open する。
    fn openRootChild(self: *const Store, name: []const u8, iterate: bool) !std.Io.Dir {
        self.root_dir.createDir(self.io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var child = try self.root_dir.openDir(self.io, name, .{
            .follow_symlinks = false,
            .iterate = iterate,
        });
        errdefer child.close(self.io);
        const stat = try child.stat(self.io);
        if (stat.kind == .sym_link) return error.SymLinkLoop;
        return child;
    }

    /// `root` を開き、必要な下位 dir を作成する。
    pub fn open(gpa: Allocator, io: std.Io, root: []const u8) !Store {
        const owned = try gpa.dupe(u8, root);
        errdefer gpa.free(owned);
        try ensureManagedDir(io, owned);
        var root_dir = try std.Io.Dir.cwd().openDir(io, owned, .{ .follow_symlinks = false });
        errdefer root_dir.close(io);
        const store = Store{ .gpa = gpa, .io = io, .root = owned, .root_dir = root_dir };
        for ([_][]const u8{ objects_dir, staging_dir, checkouts_dir, git_workspaces_dir }) |name| {
            var child = try store.openRootChild(name, false);
            child.close(io);
        }
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.root_dir.close(self.io);
        self.gpa.free(self.root);
        self.* = undefined;
    }

    /// Path-returning API guard only: Zig's portable stat exposes an inode but
    /// no cross-platform volume identity here, and the check/use pair is TOCTOU.
    /// Destructive/internal operations must use root_dir instead.
    fn rootPathStillPinned(self: *const Store) bool {
        const pinned = self.root_dir.stat(self.io) catch return false;
        var current = std.Io.Dir.cwd().openDir(self.io, self.root, .{ .follow_symlinks = false }) catch return false;
        defer current.close(self.io);
        const resolved = current.stat(self.io) catch return false;
        return resolved.kind == .directory and resolved.inode == pinned.inode;
    }

    /// `objects/<key>` の絶対 path。key 不正/root path が pinned root でない場合は null。
    /// 戻り値は path-based なテスト用補助であり、root の rename/置換後は
    /// pinned cache を指す保証がない。Store 操作・subprocess には使わないこと。
    pub fn entryPath(self: *const Store, gpa: Allocator, key: []const u8) Allocator.Error!?[]u8 {
        if (!validKey(key) or !self.rootPathStillPinned()) return null;
        return try std.fs.path.join(gpa, &.{ self.root, objects_dir, key });
    }

    fn openEntryDir(self: *const Store, key: []const u8) !std.Io.Dir {
        if (!validKey(key)) return error.InvalidKey;
        var objects = try self.openRootChild(objects_dir, false);
        defer objects.close(self.io);
        return objects.openDir(self.io, key, .{ .follow_symlinks = false });
    }

    /// Lock/source-bound archive bytes are stored beside `tree/` and revalidated
    /// by the caller against the external artifact hash before use.
    pub fn readSourceArchive(self: *const Store, gpa: Allocator, key: []const u8) !?[]u8 {
        if (!validKey(key)) return error.InvalidKey;
        var entry = self.openEntryDir(key) catch return null;
        defer entry.close(self.io);
        const bytes = entry.readFileAlloc(self.io, "source.archive", gpa, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return bytes;
    }

    pub fn readVerifiedSourceArchive(self: *const Store, gpa: Allocator, key: []const u8, expected_hash: []const u8) !?[]u8 {
        const bytes = (try self.readSourceArchive(gpa, key)) orelse return null;
        var valid = false;
        if (fetch.normalizeSha256(expected_hash)) |expected| {
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
            valid = std.mem.eql(u8, &expected, &actual);
        } else if (fetch.normalizeSha512(expected_hash)) |expected| {
            var actual: [64]u8 = undefined;
            std.crypto.hash.sha2.Sha512.hash(bytes, &actual, .{});
            valid = std.mem.eql(u8, &expected, &actual);
        }
        if (!valid) {
            gpa.free(bytes);
            return null;
        }
        return bytes;
    }

    /// Open the verified immutable object's tree as an independently owned handle.
    /// `null` means missing, incomplete, or digest-invalid; no root-derived path is
    /// constructed, so the returned handle remains pinned across root replacement.
    pub fn openVerifiedTree(self: *const Store, gpa: Allocator, key: []const u8) !?std.Io.Dir {
        if (!validKey(key)) return error.InvalidKey;
        var entry = self.openEntryDir(key) catch return null;
        defer entry.close(self.io);
        const expected = entry.readFileAlloc(self.io, complete_marker, gpa, .limited(4096)) catch return null;
        defer gpa.free(expected);
        var tree = entry.openDir(self.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch return null;
        var expected_digest: [32]u8 = undefined;
        if (!parseMarkerDigest(expected, &expected_digest)) {
            tree.close(self.io);
            return null;
        }
        const actual_digest = digestTreeFromDir(self.io, gpa, tree, &.{}) catch {
            tree.close(self.io);
            return null;
        };
        if (!std.mem.eql(u8, &expected_digest, &actual_digest)) {
            tree.close(self.io);
            return null;
        }
        return tree;
    }

    /// Create a fresh root-relative staging directory for `key`, removing any
    /// stale stage without following symlinks. Caller owns the returned handle.
    pub fn openStaging(self: *const Store, key: []const u8) !std.Io.Dir {
        if (!validKey(key)) return error.InvalidKey;
        var parent = try self.openRootChild(staging_dir, false);
        defer parent.close(self.io);
        environment.deleteTreeChecked(parent, self.io, key) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try parent.createDir(self.io, key, .default_dir);
        return parent.openDir(self.io, key, .{ .iterate = true, .follow_symlinks = false });
    }

    /// Publish staging/<key> through handles rooted at the pinned cache root.
    pub fn publishStaging(self: *const Store, key: []const u8) !void {
        if (!validKey(key)) return error.InvalidKey;
        var staging = try self.openRootChild(staging_dir, false);
        defer staging.close(self.io);
        const digest = blk: {
            var stage_dir = try staging.openDir(self.io, key, .{ .iterate = true, .follow_symlinks = false });
            defer stage_dir.close(self.io);
            var tree = try stage_dir.openDir(self.io, "tree", .{ .iterate = true, .follow_symlinks = false });
            defer tree.close(self.io);
            const tree_digest = try digestTreeFromDir(self.io, self.gpa, tree, &.{});
            var marker: [72]u8 = undefined;
            @memcpy(marker[0..7], "sha256:");
            @memcpy(marker[7..71], &std.fmt.bytesToHex(tree_digest, .lower));
            marker[71] = '\n';
            try stage_dir.writeFile(self.io, .{ .sub_path = complete_marker, .data = &marker });
            break :blk tree_digest;
        };

        var objects = try self.openRootChild(objects_dir, false);
        defer objects.close(self.io);
        staging.rename(key, objects, key, self.io) catch |rename_err| switch (rename_err) {
            error.IsDir, error.NotDir, error.DirNotEmpty, error.AccessDenied => {
                if (try self.verifyEntryDigest(self.gpa, key, digest)) {
                    try environment.deleteTreeChecked(staging, self.io, key);
                } else {
                    self.removeEntry(key) catch |remove_err| switch (remove_err) {
                        error.FileNotFound => {},
                        else => return remove_err,
                    };
                    try staging.rename(key, objects, key, self.io);
                }
            },
            else => return rename_err,
        };
    }

    /// Open an existing checkout by key. The returned handle is owned by caller.
    pub fn openCheckout(self: *const Store, key: []const u8) !?std.Io.Dir {
        if (!validKey(key)) return error.InvalidKey;
        var checkouts = try self.openRootChild(checkouts_dir, false);
        defer checkouts.close(self.io);
        return checkouts.openDir(self.io, key, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    /// Replace a checkout with a copy from a caller-opened source directory.
    /// Copy and cleanup/rename remain relative to pinned cache handles.
    pub fn replaceCheckout(self: *const Store, key: []const u8, source: *std.Io.Dir, options: materialize.Options) !materialize.Result {
        if (!validKey(key)) return error.InvalidKey;
        var checkouts = try self.openRootChild(checkouts_dir, false);
        defer checkouts.close(self.io);
        const stage_name = try std.fmt.allocPrint(self.gpa, ".{s}-staging", .{key});
        defer self.gpa.free(stage_name);
        const backup_name = try std.fmt.allocPrint(self.gpa, ".{s}-backup", .{key});
        defer self.gpa.free(backup_name);
        for ([_][]const u8{ stage_name, backup_name }) |name| {
            environment.deleteTreeChecked(checkouts, self.io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        try checkouts.createDir(self.io, stage_name, .default_dir);
        errdefer environment.deleteTreeChecked(checkouts, self.io, stage_name) catch {};
        var destination = try checkouts.openDir(self.io, stage_name, .{ .iterate = true, .follow_symlinks = false });
        const result = materialize.copyTreeFromDirs(self.gpa, self.io, source, &destination, options) catch |err| {
            destination.close(self.io);
            return err;
        };
        destination.close(self.io);
        if (checkouts.openDir(self.io, key, .{ .follow_symlinks = false })) |old| {
            var old_dir = old;
            old_dir.close(self.io);
            try checkouts.rename(key, checkouts, backup_name, self.io);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        errdefer checkouts.rename(backup_name, checkouts, key, self.io) catch {};
        try checkouts.rename(stage_name, checkouts, key, self.io);
        environment.deleteTreeChecked(checkouts, self.io, backup_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return result;
    }

    /// 完了 marker まで存在する完全な entry があるか。
    /// marker の有無だけを見る軽量版。内容を信頼して利用する判断は
    /// `verifyEntry` を使うこと。
    pub fn entryExists(self: *const Store, key: []const u8) bool {
        var entry = self.openEntryDir(key) catch return false;
        defer entry.close(self.io);
        entry.access(self.io, complete_marker, .{}) catch return false;
        return true;
    }

    /// marker が記録した tree digest と entry の実内容を照合する。
    /// 共有 cache への改変（marker だけ残して内容を差し替えた場合など）を
    /// 検出するため、hit した entry を消費する前に必ず呼ぶこと。
    /// 戻り値は「marker あり・digest 一致」のみ true。IO 失敗も false。
    pub fn verifyEntry(self: *const Store, gpa: Allocator, key: []const u8) !bool {
        var entry = self.openEntryDir(key) catch return false;
        defer entry.close(self.io);
        const expected = entry.readFileAlloc(self.io, complete_marker, gpa, .limited(4096)) catch return false;
        defer gpa.free(expected);
        var tree = entry.openDir(self.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch return false;
        defer tree.close(self.io);
        // integrity digest は展開物全体（明示同梱の `.nako/**` 含む）を
        // 対象にするため除外名は空。
        const actual = digestTreeFromDir(self.io, gpa, tree, &.{}) catch return false;
        var expected_bytes: [32]u8 = undefined;
        return parseMarkerDigest(expected, &expected_bytes) and std.mem.eql(u8, &expected_bytes, &actual);
    }

    /// Destination entry が marker と実 tree の両方で指定 digest に一致するか。
    fn verifyEntryDigest(self: *const Store, gpa: Allocator, key: []const u8, digest: [32]u8) !bool {
        var entry = self.openEntryDir(key) catch return false;
        defer entry.close(self.io);
        const marker = entry.readFileAlloc(self.io, complete_marker, gpa, .limited(4096)) catch return false;
        defer gpa.free(marker);
        var recorded: [32]u8 = undefined;
        if (!parseMarkerDigest(marker, &recorded) or !std.mem.eql(u8, &recorded, &digest)) return false;
        var tree = entry.openDir(self.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch return false;
        defer tree.close(self.io);
        const actual = digestTreeFromDir(self.io, gpa, tree, &.{}) catch return false;
        return std.mem.eql(u8, &actual, &digest);
    }

    /// entry（改変検出・不完全など）を削除する。cache lock 保持中に呼ぶこと。
    pub fn removeEntry(self: *const Store, key: []const u8) !void {
        if (!validKey(key)) return error.InvalidKey;
        var objects = try self.openRootChild(objects_dir, false);
        defer objects.close(self.io);
        try environment.deleteTreeChecked(objects, self.io, key);
    }

    /// 完了 marker の無い entry（公開途中で中断した残骸）を削除する。
    /// cache lock 保持中に呼ぶこと。
    /// 管理 dir は symlink 非追従で開き、削除は dir ハンドル相対で行う
    /// （管理 dir 自身の symlink による cache 外への逸脱を防ぐ）。
    pub fn pruneIncomplete(self: *const Store) !void {
        var dir = self.openRootChild(objects_dir, true) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (self.entryExists(entry.name)) continue;
            environment.deleteTreeChecked(dir, self.io, entry.name) catch continue;
        }
        // staging の残留も回収する。
        var sdir = self.openRootChild(staging_dir, true) catch return;
        defer sdir.close(self.io);
        var sit = sdir.iterate();
        while (try sit.next(self.io)) |entry| {
            environment.deleteTreeChecked(sdir, self.io, entry.name) catch continue;
        }
    }

    /// `staging_abs`（検証済みの dir 木）を `objects/<key>` として原子的に
    /// 公開する。同名 entry があれば、marker と tree digest が staging の
    /// 内容と一致する場合だけ staging を破棄し、不一致なら既存 entry を
    /// 除去して公開を再試行する。
    /// `staging_abs` は cache root の `staging/` 内でなくてもよいが、
    /// rename が同じ volume 内で成立する必要がある（跨ぐ場合は呼出し側が
    /// cache 内 staging を使う）。
    pub fn publish(self: *const Store, key: []const u8, staging_abs: []const u8) !void {
        if (!validKey(key)) return error.InvalidKey;

        // Paths lexically under the cache root must resolve through the pinned
        // staging handle; never reopen a replaced root path supplied by a caller.
        const expected_staging = try std.fs.path.join(self.gpa, &.{ self.root, staging_dir, key });
        defer self.gpa.free(expected_staging);
        var staging_parent: std.Io.Dir = undefined;
        var owns_parent = false;
        var staging_name: []const u8 = undefined;
        if (std.mem.eql(u8, staging_abs, expected_staging)) {
            staging_parent = try self.openRootChild(staging_dir, false);
            owns_parent = true;
            staging_name = key;
        } else {
            const root_prefix = try std.fmt.allocPrint(self.gpa, "{s}{c}", .{ self.root, std.fs.path.sep });
            defer self.gpa.free(root_prefix);
            staging_name = std.fs.path.basename(staging_abs);
            if (staging_name.len == 0 or std.mem.eql(u8, staging_name, ".") or std.mem.eql(u8, staging_name, "..")) return error.InvalidStagingPath;
            if (std.mem.startsWith(u8, staging_abs, root_prefix)) {
                const rel = staging_abs[root_prefix.len..];
                if (std.fs.path.dirname(rel)) |parent_rel| {
                    staging_parent = try self.openRootRelativeDir(parent_rel, false);
                    owns_parent = true;
                } else {
                    staging_parent = self.root_dir;
                }
            } else {
                const parent_path = std.fs.path.dirname(staging_abs) orelse return error.InvalidStagingPath;
                staging_parent = try std.Io.Dir.cwd().openDir(self.io, parent_path, .{});
                owns_parent = true;
            }
        }
        defer if (owns_parent) staging_parent.close(self.io);
        var digest: [32]u8 = undefined;
        {
            // Windows cannot rename this directory while its child directory handles
            // remain open; close them before publishing staging into objects/.
            var staging_dir_handle = try staging_parent.openDir(self.io, staging_name, .{ .iterate = true, .follow_symlinks = false });
            defer staging_dir_handle.close(self.io);
            var tree = try staging_dir_handle.openDir(self.io, "tree", .{ .iterate = true, .follow_symlinks = false });
            defer tree.close(self.io);
            digest = try digestTreeFromDir(self.io, self.gpa, tree, &.{});
            var marker: [7 + 64 + 1]u8 = undefined;
            @memcpy(marker[0..7], "sha256:");
            @memcpy(marker[7..71], &std.fmt.bytesToHex(digest, .lower));
            marker[71] = '\n';
            try staging_dir_handle.writeFile(self.io, .{ .sub_path = complete_marker, .data = &marker });
        }

        var objects = try self.openRootChild(objects_dir, false);
        defer objects.close(self.io);
        staging_parent.rename(staging_name, objects, key, self.io) catch |rename_err| switch (rename_err) {
            // Destination exists (or was concurrently created). Verify from the
            // pinned root before discarding or replacing it.
            error.IsDir, error.NotDir, error.DirNotEmpty, error.AccessDenied => {
                if (try self.verifyEntryDigest(self.gpa, key, digest)) {
                    try environment.deleteTreeChecked(staging_parent, self.io, staging_name);
                } else {
                    self.removeEntry(key) catch |remove_err| switch (remove_err) {
                        error.FileNotFound => {},
                        else => return remove_err,
                    };
                    try staging_parent.rename(staging_name, objects, key, self.io);
                }
            },
            else => return rename_err,
        };
    }

    /// 管理 dir を symlink 非追従で開く。管理 dir 自身が symlink なら
    /// リンクのみ除去して実 dir を作り直す（cache 外を走査しないため）。
    /// Windows reparse point も open 後の stat で検出する（実装は
    /// `environment.openManagedDir`）。
    fn openManagedDir(io: std.Io, path: []const u8) !std.Io.Dir {
        return environment.openManagedDir(io, path, true);
    }

    /// `keep` に含まれない entry を削除する。呼出し側が cache lock を保持
    /// している前提で、使用中 entry を消さない協調を実現する。staging と
    /// 未完了 entry も回収する。戻り値は削除した entry 数。
    pub fn cleanKeep(self: *const Store, keep: []const []const u8) !usize {
        var removed: usize = 0;
        var dir = self.openRootChild(objects_dir, true) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(self.io);
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
                environment.deleteTreeChecked(dir, self.io, entry.name) catch continue;
                removed += 1;
            }
        }
        try self.pruneIncomplete();
        return removed;
    }

    /// objects・checkouts・staging・git-workspaces を削除する（cache の完全初期化）。
    /// cache lock 保持中に呼ぶこと。戻り値は削除したトップレ項目数。
    /// 管理 dir は symlink 非追従で開き、削除は dir ハンドル相対で行う
    /// （管理 dir 自身の symlink による cache 外への逸脱を防ぐ）。
    pub fn cleanAll(self: *const Store) !usize {
        var removed: usize = 0;
        const subdirs = [_][]const u8{ objects_dir, staging_dir, checkouts_dir, git_workspaces_dir };
        for (subdirs) |sub| {
            var dir = self.openRootChild(sub, true) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer dir.close(self.io);
            var it = dir.iterate();
            while (try it.next(self.io)) |entry| {
                environment.deleteTreeChecked(dir, self.io, entry.name) catch continue;
                removed += 1;
            }
        }
        return removed;
    }

    /// `cache.lock` を排他取得する。別 process が保持中は `error.Busy`。
    /// OS の advisory lock は process 終了で自動解放されるため、中断後に
    /// stale lock が残らない。
    pub fn lock(self: *const Store) !LockGuard {
        return self.lockImpl(true);
    }

    /// `lock` の blocking 版。保持中の処理が終わるまで待つ。
    pub fn lockWait(self: *const Store) !LockGuard {
        return self.lockImpl(false);
    }

    fn lockImpl(self: *const Store, nonblocking: bool) !LockGuard {
        // open 時に固定した cache root handle 相対で `cache.lock` を開く。
        // leaf symlink は openManagedLockFile がリンク本体のみ除去して作り直す。
        var file = environment.openManagedLockFile(self.root_dir, self.io, lock_name, nonblocking) catch |err| switch (err) {
            error.WouldBlock => return error.Busy,
            else => return err,
        };
        errdefer file.close(self.io);
        return .{ .file = file, .io = self.io };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "digestTreeFollowingRoot follows only the declared root symlink" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "tree/sub");
    try temporary.dir.writeFile(io, .{ .sub_path = "tree/sub/file", .data = "payload" });
    try temporary.dir.symLink(io, "tree", "root-link", .{ .is_directory = true });
    const tmp_root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const tree_path = try std.fs.path.join(testing.allocator, &.{ tmp_root, "tree" });
    defer testing.allocator.free(tree_path);
    const link_path = try std.fs.path.join(testing.allocator, &.{ tmp_root, "root-link" });
    defer testing.allocator.free(link_path);

    const expected = try digestTree(io, testing.allocator, tree_path, &.{});
    const through_link = try digestTreeFollowingRoot(io, testing.allocator, link_path, &.{});
    try testing.expectEqualSlices(u8, &expected, &through_link);

    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.symLink(io, "../../outside", "tree/sub/external", .{ .is_directory = true });
    try testing.expectError(error.UnsupportedEntry, digestTreeFollowingRoot(io, testing.allocator, link_path, &.{}));
}

fn openTempStore(temporary: *std.testing.TmpDir) !Store {
    const root = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return try Store.open(testing.allocator, testing.io, root);
}

test "cache cleanAll は open 後に root が symlink へ置換されても別 root を削除しない" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "root/objects/victim");
    try temporary.dir.createDirPath(io, "root/staging/poison/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "root/objects/victim/pinned", .data = "pinned" });
    try temporary.dir.writeFile(io, .{ .sub_path = "root/staging/poison/tree/payload", .data = "pinned" });
    try temporary.dir.createDirPath(io, "attacker/objects/keep");
    try temporary.dir.createDirPath(io, "attacker/staging/keep");
    try temporary.dir.createDirPath(io, "attacker/checkouts/keep");
    try temporary.dir.createDirPath(io, "attacker/objects/victim");
    try temporary.dir.createDirPath(io, "attacker/staging/poison/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "attacker/objects/victim/sentinel", .data = "safe" });
    try temporary.dir.writeFile(io, .{ .sub_path = "attacker/staging/poison/tree/payload", .data = "attacker" });
    try temporary.dir.writeFile(io, .{ .sub_path = "attacker/objects/keep/sentinel", .data = "safe" });
    try temporary.dir.writeFile(io, .{ .sub_path = "attacker/staging/keep/sentinel", .data = "safe" });
    try temporary.dir.writeFile(io, .{ .sub_path = "attacker/checkouts/keep/sentinel", .data = "safe" });
    const root = try temporary.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);
    const attacker = try temporary.dir.realPathFileAlloc(io, "attacker", testing.allocator);
    defer testing.allocator.free(attacker);

    var store = try Store.open(testing.allocator, io, root);
    defer store.deinit();
    var guard = try store.lock();
    defer guard.unlock();

    // Store が pinned handle と lock を保持した後で root path を置換する。
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}-moved", .{root});
    defer testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(root, moved, io);
    temporary.dir.symLink(io, attacker, "root", .{}) catch return error.SkipZigTest;

    // Root-derived staging paths and same-key deletions must also stay pinned.
    const poison_staging = try std.fs.path.join(testing.allocator, &.{ root, staging_dir, "poison" });
    defer testing.allocator.free(poison_staging);
    try store.publish("poison", poison_staging);
    try store.removeEntry("victim");
    try testing.expect((try store.entryPath(testing.allocator, "keep")) == null);

    for ([_][]const u8{
        "attacker/objects/keep/sentinel",
        "attacker/staging/keep/sentinel",
        "attacker/checkouts/keep/sentinel",
        "attacker/objects/victim/sentinel",
    }) |path| {
        const bytes = try temporary.dir.readFileAlloc(io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings("safe", bytes);
    }
    const attacker_staging = try temporary.dir.readFileAlloc(io, "attacker/staging/poison/tree/payload", testing.allocator, .unlimited);
    defer testing.allocator.free(attacker_staging);
    try testing.expectEqualStrings("attacker", attacker_staging);
    const published = try std.fs.path.join(testing.allocator, &.{ moved, objects_dir, "poison", "tree", "payload" });
    defer testing.allocator.free(published);
    const published_bytes = try std.Io.Dir.cwd().readFileAlloc(io, published, testing.allocator, .unlimited);
    defer testing.allocator.free(published_bytes);
    try testing.expectEqualStrings("pinned", published_bytes);
    _ = try store.cleanAll();
    const after_clean = try temporary.dir.readFileAlloc(io, "attacker/objects/keep/sentinel", testing.allocator, .unlimited);
    defer testing.allocator.free(after_clean);
    try testing.expectEqualStrings("safe", after_clean);
}

test "cache verified tree handle は root replacement 後も pinned entry を読む" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const root = try temporary.dir.realPathFileAlloc(io, "cache", testing.allocator);
    defer testing.allocator.free(root);
    var store = try Store.open(testing.allocator, io, root);
    defer store.deinit();
    var stage = try store.openStaging("object");
    try stage.createDir(io, "tree", .default_dir);
    var tree = try stage.openDir(io, "tree", .{});
    try tree.writeFile(io, .{ .sub_path = "payload", .data = "pinned" });
    tree.close(io);
    stage.close(io);
    try store.publishStaging("object");
    var opened = (try store.openVerifiedTree(testing.allocator, "object")).?;
    defer opened.close(io);

    const moved = try std.fmt.allocPrint(testing.allocator, "{s}-moved", .{root});
    defer testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(root, moved, io);
    const bytes = try opened.readFileAlloc(io, "payload", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("pinned", bytes);
}

test "cache materialize は root replacement 後も pinned tree を複製する" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    try temporary.dir.createDirPath(io, "attacker");
    try temporary.dir.createDirPath(io, "dest");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", testing.allocator);
    defer testing.allocator.free(cache_root);
    const attacker_root = try temporary.dir.realPathFileAlloc(io, "attacker", testing.allocator);
    defer testing.allocator.free(attacker_root);

    var store = try Store.open(testing.allocator, io, cache_root);
    defer store.deinit();
    var guard = try store.lock();
    defer guard.unlock();
    var staging = try store.openStaging("victim");
    try staging.createDir(io, "tree", .default_dir);
    var tree = try staging.openDir(io, "tree", .{ .iterate = true, .follow_symlinks = false });
    try tree.writeFile(io, .{ .sub_path = "payload", .data = "pinned" });
    tree.close(io);
    staging.close(io);
    try store.publishStaging("victim");

    {
        var attacker = try Store.open(testing.allocator, io, attacker_root);
        defer attacker.deinit();
        var attacker_stage = try attacker.openStaging("victim");
        try attacker_stage.createDir(io, "tree", .default_dir);
        var attacker_tree = try attacker_stage.openDir(io, "tree", .{ .iterate = true, .follow_symlinks = false });
        try attacker_tree.writeFile(io, .{ .sub_path = "payload", .data = "attacker" });
        attacker_tree.close(io);
        attacker_stage.close(io);
        try attacker.publishStaging("victim");
    }

    const moved = try std.fmt.allocPrint(testing.allocator, "{s}-moved", .{cache_root});
    defer testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(cache_root, moved, io);
    temporary.dir.symLink(io, attacker_root, "cache", .{}) catch return error.SkipZigTest;

    var source = (try store.openVerifiedTree(testing.allocator, "victim")).?;
    defer source.close(io);
    var destination = try temporary.dir.openDir(io, "dest", .{ .iterate = true, .follow_symlinks = false });
    defer destination.close(io);
    _ = try materialize.copyTreeFromDirs(testing.allocator, io, &source, &destination, .{});
    const copied = try temporary.dir.readFileAlloc(io, "dest/payload", testing.allocator, .unlimited);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("pinned", copied);
    const attacker_payload = try temporary.dir.readFileAlloc(io, "attacker/objects/victim/tree/payload", testing.allocator, .unlimited);
    defer testing.allocator.free(attacker_payload);
    try testing.expectEqualStrings("attacker", attacker_payload);
}

test "cache staging は stale stage を除去し checkout を handle 経由で置換する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();
    var stale = try store.openStaging("stage-key");
    try stale.writeFile(io, .{ .sub_path = "stale", .data = "old" });
    stale.close(io);
    var fresh = try store.openStaging("stage-key");
    try testing.expectError(error.FileNotFound, fresh.openFile(io, "stale", .{}));
    fresh.close(io);

    try temporary.dir.createDirPath(io, "source/sub");
    try temporary.dir.writeFile(io, .{ .sub_path = "source/sub/file", .data = "new" });
    var source = try temporary.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    _ = try store.replaceCheckout("checkout-key", &source, .{});
    var checkout = (try store.openCheckout("checkout-key")).?;
    defer checkout.close(io);
    const bytes = try checkout.readFileAlloc(io, "sub/file", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("new", bytes);
    _ = try store.replaceCheckout("checkout-key", &source, .{});
}

test "cache store は staging を publish で原子的に公開する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "stage/tree/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "stage/tree/src/index.nako3", .data = "●テストとは\n" });
    const staging_abs = try temporary.dir.realPathFileAlloc(io, "stage", testing.allocator);
    defer testing.allocator.free(staging_abs);

    var store = try openTempStore(&temporary);
    defer store.deinit();
    try store.publish("deadbeef", staging_abs);
    try testing.expect(store.entryExists("deadbeef"));
    try testing.expect(!store.entryExists("other"));

    // 公開された tree の内容を確認する。
    const entry = (try store.entryPath(testing.allocator, "deadbeef")).?;
    defer testing.allocator.free(entry);
    const copied = try std.fs.path.join(testing.allocator, &.{ entry, "tree", "src", "index.nako3" });
    defer testing.allocator.free(copied);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, copied, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("●テストとは\n", bytes);
}

test "cache store は同一 key の再公開で既存 entry の内容を検証する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "first/tree");
    try temporary.dir.createDirPath(io, "second/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "first/tree/a", .data = "1" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second/tree/a", .data = "2" });
    const first = try temporary.dir.realPathFileAlloc(io, "first", testing.allocator);
    defer testing.allocator.free(first);
    const second = try temporary.dir.realPathFileAlloc(io, "second", testing.allocator);
    defer testing.allocator.free(second);

    var store = try openTempStore(&temporary);
    defer store.deinit();
    try store.publish("same", first);
    try store.publish("same", second);

    const entry = (try store.entryPath(testing.allocator, "same")).?;
    defer testing.allocator.free(entry);
    const file = try std.fs.path.join(testing.allocator, &.{ entry, "tree", "a" });
    defer testing.allocator.free(file);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("2", bytes);

    // marker を残したまま destination tree を改変した競合も拒否し、
    // 検証済み staging を捨てずに destination を置き換える。
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "tampered" });
    try temporary.dir.createDirPath(io, "third/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "third/tree/a", .data = "3" });
    const third = try temporary.dir.realPathFileAlloc(io, "third", testing.allocator);
    defer testing.allocator.free(third);
    try store.publish("same", third);
    const repaired = try std.Io.Dir.cwd().readFileAlloc(io, file, testing.allocator, .unlimited);
    defer testing.allocator.free(repaired);
    try testing.expectEqualStrings("3", repaired);

    // markerless destination は key が同じでも検証済み staging を優先する。
    const marker = try std.fs.path.join(testing.allocator, &.{ entry, complete_marker });
    defer testing.allocator.free(marker);
    try std.Io.Dir.cwd().deleteFile(io, marker);
    try temporary.dir.createDirPath(io, "fourth/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "fourth/tree/a", .data = "4" });
    const fourth = try temporary.dir.realPathFileAlloc(io, "fourth", testing.allocator);
    defer testing.allocator.free(fourth);
    try store.publish("same", fourth);
    const final_bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, testing.allocator, .unlimited);
    defer testing.allocator.free(final_bytes);
    try testing.expectEqualStrings("4", final_bytes);
}

test "cache store は marker の無い不完全 entry と staging 残留を回収する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var store = try openTempStore(&temporary);
    defer store.deinit();
    // 公開途中で中断した不完全 entry と staging 残骸を作る。
    const incomplete = try std.fs.path.join(testing.allocator, &.{ store.root, objects_dir, "broken", "tree" });
    defer testing.allocator.free(incomplete);
    try std.Io.Dir.cwd().createDirPath(io, incomplete);
    const stale = try std.fs.path.join(testing.allocator, &.{ store.root, staging_dir, "leftover" });
    defer testing.allocator.free(stale);
    try std.Io.Dir.cwd().createDirPath(io, stale);

    try testing.expect(!store.entryExists("broken"));
    try store.pruneIncomplete();

    const objects_path = try std.fs.path.join(testing.allocator, &.{ store.root, objects_dir });
    defer testing.allocator.free(objects_path);
    var objects = try std.Io.Dir.openDirAbsolute(io, objects_path, .{ .iterate = true });
    defer objects.close(io);
    var it = objects.iterate();
    try testing.expect((try it.next(io)) == null);

    const staging_path = try std.fs.path.join(testing.allocator, &.{ store.root, staging_dir });
    defer testing.allocator.free(staging_path);
    var staging = try std.Io.Dir.openDirAbsolute(io, staging_path, .{ .iterate = true });
    defer staging.close(io);
    var sit = staging.iterate();
    try testing.expect((try sit.next(io)) == null);
}

test "cache store の cleanKeep は keep 以外の entry を削除する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    for ([_][]const u8{ "keep-a", "drop-b", "drop-c" }) |key| {
        const staging = try std.fs.path.join(testing.allocator, &.{ store.root, staging_dir, key });
        defer testing.allocator.free(staging);
        const tree = try std.fmt.allocPrint(testing.allocator, "{s}/tree", .{staging});
        defer testing.allocator.free(tree);
        try std.Io.Dir.cwd().createDirPath(io, tree);
        try store.publish(key, staging);
    }
    const removed = try store.cleanKeep(&.{"keep-a"});
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expect(store.entryExists("keep-a"));
    try testing.expect(!store.entryExists("drop-b"));
    try testing.expect(!store.entryExists("drop-c"));
}

test "checkout_copy_options は repository 全体の大容量複写を許容し構造検査を維持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // package 用の既定上限（file 64MiB）を超える pack file 相当の単一 file。
    const payload = try testing.allocator.alloc(u8, 64 * 1024 * 1024 + 1);
    defer testing.allocator.free(payload);
    @memset(payload, 0);
    try temporary.dir.createDirPath(io, "src/.git/objects/pack");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/.git/objects/pack/pack-big", .data = payload });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/index.nako3", .data = "x" });
    try temporary.dir.createDir(io, "dst-default", .default_dir);
    try temporary.dir.createDir(io, "dst-checkout", .default_dir);

    var source = try temporary.dir.openDir(io, "src", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);

    // package tree 向け既定上限では pack file が上限超過で失敗する。
    {
        var dst = try temporary.dir.openDir(io, "dst-default", .{ .iterate = true, .follow_symlinks = false });
        defer dst.close(io);
        try testing.expectError(error.FileTooLarge, materialize.copyTreeFromDirs(testing.allocator, io, &source, &dst, .{}));
    }
    // checkout 用の緩和済み制限では repository 全体を複写できる。
    {
        var dst = try temporary.dir.openDir(io, "dst-checkout", .{ .iterate = true, .follow_symlinks = false });
        defer dst.close(io);
        _ = try materialize.copyTreeFromDirs(testing.allocator, io, &source, &dst, checkout_copy_options);
        const stat = try dst.statFile(io, ".git/objects/pack/pack-big", .{});
        try testing.expectEqual(@as(u64, payload.len), stat.size);
    }
    // 量の緩和でも構造検査は残る（symlink は引き続き拒否）。
    source.symLink(io, "outside", "escape", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    {
        try temporary.dir.createDir(io, "dst-symlink", .default_dir);
        var dst = try temporary.dir.openDir(io, "dst-symlink", .{ .iterate = true, .follow_symlinks = false });
        defer dst.close(io);
        try testing.expectError(error.SymlinkEncountered, materialize.copyTreeFromDirs(testing.allocator, io, &source, &dst, checkout_copy_options));
    }
}

test "Git workspace roots are isolated under each selected cache root" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache-a");
    try temporary.dir.createDirPath(io, "cache-b");
    const root_a = try temporary.dir.realPathFileAlloc(io, "cache-a", testing.allocator);
    defer testing.allocator.free(root_a);
    const root_b = try temporary.dir.realPathFileAlloc(io, "cache-b", testing.allocator);
    defer testing.allocator.free(root_b);
    var store_a = try Store.open(testing.allocator, io, root_a);
    defer store_a.deinit();
    var store_b = try Store.open(testing.allocator, io, root_b);
    defer store_b.deinit();

    var workspaces_a = try store_a.openGitWorkspaceRoot();
    defer workspaces_a.close(io);
    var workspaces_b = try store_b.openGitWorkspaceRoot();
    defer workspaces_b.close(io);

    // 同名 key の workspace は選択 cache root ごとに独立している。
    try workspaces_a.createDir(io, "git-abc123", .default_dir);
    try testing.expectError(error.FileNotFound, workspaces_b.access(io, "git-abc123", .{}));
}

test "Git workspace root refuses a symlink under a selected cache" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/sentinel", .data = "untouched" });
    const root = try temporary.dir.realPathFileAlloc(io, "cache", testing.allocator);
    defer testing.allocator.free(root);
    var store = try Store.open(testing.allocator, io, root);
    defer store.deinit();
    try store.root_dir.deleteTree(io, git_workspaces_dir);
    store.root_dir.symLink(io, "../outside", git_workspaces_dir, .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    if (store.openGitWorkspaceRoot()) |workspace| {
        var opened = workspace;
        opened.close(io);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.SymLinkLoop, error.NotDir, error.AccessDenied, error.PermissionDenied => {},
        else => return err,
    }
    const sentinel = try temporary.dir.readFileAlloc(io, "outside/sentinel", testing.allocator, .limited(32));
    defer testing.allocator.free(sentinel);
    try testing.expectEqualStrings("untouched", sentinel);
}

test "cache store の排他 lock は保持中に Busy を返し解放後に取得できる" {
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

test "cache key は規範外の文字を拒否する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try openTempStore(&temporary);
    defer store.deinit();

    try testing.expect((try store.entryPath(testing.allocator, "../escape")) == null);
    try testing.expect((try store.entryPath(testing.allocator, "a/b")) == null);
    try testing.expect((try store.entryPath(testing.allocator, "")) == null);
    try testing.expectError(error.InvalidKey, store.publish("../escape", "/tmp/never"));
}

test "cache defaultRoot は環境から OS 標準 dir を導く" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const root = (try defaultRoot(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(root);
    try testing.expect(std.fs.path.isAbsolute(root));
    try testing.expect(std.mem.indexOf(u8, root, "lnako") != null);
}

test "cache verifyEntry は marker digest と内容の不整合を検出し removeEntry で除去する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "stage/tree");
    try temporary.dir.writeFile(io, .{ .sub_path = "stage/tree/payload", .data = "original" });
    const staging_abs = try temporary.dir.realPathFileAlloc(io, "stage", testing.allocator);
    defer testing.allocator.free(staging_abs);

    var store = try openTempStore(&temporary);
    defer store.deinit();
    try store.publish("victim", staging_abs);
    try testing.expect(try store.verifyEntry(testing.allocator, "victim"));

    // 公開済み tree を改変する（共有 cache への改変を模倣）。
    const entry = (try store.entryPath(testing.allocator, "victim")).?;
    defer testing.allocator.free(entry);
    const tampered = try std.fs.path.join(testing.allocator, &.{ entry, "tree", "payload" });
    defer testing.allocator.free(tampered);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tampered, .data = "replaced" });
    try testing.expect(!(try store.verifyEntry(testing.allocator, "victim")));

    // 改変 entry を除去すると marker も含めて消える。
    try store.removeEntry("victim");
    try testing.expect(!store.entryExists("victim"));
}

test "cache verifyEntry は marker が無い・壊れた entry を false とする" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var store = try openTempStore(&temporary);
    defer store.deinit();
    try testing.expect(!(try store.verifyEntry(testing.allocator, "missing")));

    // marker のみあって tree が無い不完全な entry も不一致。
    const broken = try std.fs.path.join(testing.allocator, &.{ store.root, objects_dir, "broken" });
    defer testing.allocator.free(broken);
    try std.Io.Dir.cwd().createDirPath(io, broken);
    const marker = try std.fs.path.join(testing.allocator, &.{ broken, complete_marker });
    defer testing.allocator.free(marker);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "sha256:nothex\n" });
    try testing.expect(!(try store.verifyEntry(testing.allocator, "broken")));
}
