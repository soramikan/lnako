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

const Allocator = std.mem.Allocator;

/// entry 公開完了の marker。staging 内で最後に書き込み、rename 後に存在
/// すれば完全な entry として扱う。公開途中で中断された entry には無い。
pub const complete_marker = ".nako-cache-entry";
pub const lock_name = "cache.lock";
pub const objects_dir = "objects";
pub const staging_dir = "staging";
pub const checkouts_dir = "checkouts";

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

fn collectDigestEntries(io: std.Io, gpa: Allocator, root_abs: []const u8, rel: []const u8, exclude_names: []const []const u8, entries: *std.ArrayListUnmanaged(DigestEntry)) !void {
    const abs = if (rel.len == 0) try gpa.dupe(u8, root_abs) else try std.fs.path.join(gpa, &.{ root_abs, rel });
    defer gpa.free(abs);
    var dir = try std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true });
    defer dir.close(io);
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
        switch (entry.kind) {
            .file => {
                const file_abs = try std.fs.path.join(gpa, &.{ root_abs, child_rel });
                defer gpa.free(file_abs);
                const stat = try std.Io.Dir.cwd().statFile(io, file_abs, .{});
                try entries.append(gpa, .{ .rel = child_rel, .kind = .file, .size = stat.size });
            },
            .directory => {
                try entries.append(gpa, .{ .rel = child_rel, .kind = .directory });
                try collectDigestEntries(io, gpa, root_abs, child_rel, exclude_names, entries);
            },
            // symlink 等は内容アドレス tree に存在しない（publish 前の
            // materialize 検証で拒否済み）。存在したら digest 不能として失敗。
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

/// `tree/` の内容 digest。path・種別・size・内容を決定順で hash するため
/// 同一 tree は常に同一 digest。marker 記録と hit 時の再検証に使う。
/// `mutable = false` の path 依存 pin でも同じ digest を利用する。
/// `exclude_names` に列挙した dir/file 名は digest 対象から除く。
pub fn digestTree(io: std.Io, gpa: Allocator, tree_abs: []const u8, exclude_names: []const []const u8) ![32]u8 {
    var entries = std.ArrayListUnmanaged(DigestEntry).empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.rel);
        entries.deinit(gpa);
    }
    try collectDigestEntries(io, gpa, tree_abs, "", exclude_names, &entries);
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
                const abs = try std.fs.path.join(gpa, &.{ tree_abs, entry.rel });
                defer gpa.free(abs);
                // 大きな file を一括確保しないよう、固定 buffer で
                // ストリーミング読み出しして hash を更新する。
                var file = try std.Io.Dir.cwd().openFile(io, abs, .{});
                defer file.close(io);
                var read_buffer: [8192]u8 = undefined;
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
    /// `objects/`・`staging/`・`cache.lock` を持つ cache ルートの絶対 path。
    root: []const u8,

    /// cache 管理下の dir を実 dir として開く。管理 dir 自体が symlink
    /// （共有 cache を別主体が改変した場合等）なら、リンクのみを除去して
    /// 実 dir を作り直す。`deleteTree` は entry 内の symlink を追従しない
    /// が、管理 dir 自身の symlink は openDir が追従して cache 外を
    /// 走査・削除し得るため、ここで排除する。
    fn ensureManagedDir(io: std.Io, path: []const u8) !void {
        return environment.ensureManagedDir(io, path);
    }

    /// `root` を開き、必要な下位 dir を作成する。
    pub fn open(gpa: Allocator, io: std.Io, root: []const u8) !Store {
        const owned = try gpa.dupe(u8, root);
        errdefer gpa.free(owned);
        const objects = try std.fs.path.join(gpa, &.{ owned, objects_dir });
        defer gpa.free(objects);
        try ensureManagedDir(io, objects);
        const staging = try std.fs.path.join(gpa, &.{ owned, staging_dir });
        defer gpa.free(staging);
        try ensureManagedDir(io, staging);
        const checkouts = try std.fs.path.join(gpa, &.{ owned, checkouts_dir });
        defer gpa.free(checkouts);
        try ensureManagedDir(io, checkouts);
        return .{ .gpa = gpa, .io = io, .root = owned };
    }

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.root);
        self.* = undefined;
    }

    /// `objects/<key>` の絶対 path。key 不正は null。
    pub fn entryPath(self: *const Store, gpa: Allocator, key: []const u8) Allocator.Error!?[]u8 {
        if (!validKey(key)) return null;
        return try std.fs.path.join(gpa, &.{ self.root, objects_dir, key });
    }

    /// `checkouts/<key>` の絶対 path。git checkout 等の再利用作業 dir。
    pub fn checkoutPath(self: *const Store, gpa: Allocator, key: []const u8) Allocator.Error!?[]u8 {
        if (!validKey(key)) return null;
        return try std.fs.path.join(gpa, &.{ self.root, checkouts_dir, key });
    }

    /// 完了 marker まで存在する完全な entry があるか。
    /// marker の有無だけを見る軽量版。内容を信頼して利用する判断は
    /// `verifyEntry` を使うこと。
    pub fn entryExists(self: *const Store, key: []const u8) bool {
        const entry = (self.entryPath(self.gpa, key) catch return false) orelse return false;
        defer self.gpa.free(entry);
        const marker_file = std.fs.path.join(self.gpa, &.{ entry, complete_marker }) catch return false;
        defer self.gpa.free(marker_file);
        std.Io.Dir.cwd().access(self.io, marker_file, .{}) catch return false;
        return true;
    }

    /// marker が記録した tree digest と entry の実内容を照合する。
    /// 共有 cache への改変（marker だけ残して内容を差し替えた場合など）を
    /// 検出するため、hit した entry を消費する前に必ず呼ぶこと。
    /// 戻り値は「marker あり・digest 一致」のみ true。IO 失敗も false。
    pub fn verifyEntry(self: *const Store, gpa: Allocator, key: []const u8) !bool {
        const entry = (try self.entryPath(gpa, key)) orelse return false;
        defer gpa.free(entry);
        const marker_file = std.fs.path.join(gpa, &.{ entry, complete_marker }) catch return false;
        defer gpa.free(marker_file);
        const expected = std.Io.Dir.cwd().readFileAlloc(self.io, marker_file, gpa, .limited(4096)) catch return false;
        defer gpa.free(expected);
        const tree = std.fs.path.join(gpa, &.{ entry, "tree" }) catch return false;
        defer gpa.free(tree);
        // integrity digest は展開物全体（明示同梱の `.nako/**` 含む）を
        // 対象にするため除外名は空。
        const actual = digestTree(self.io, gpa, tree, &.{}) catch return false;
        var expected_bytes: [32]u8 = undefined;
        return parseMarkerDigest(expected, &expected_bytes) and std.mem.eql(u8, &expected_bytes, &actual);
    }

    /// Destination entry が marker と実 tree の両方で指定 digest に一致するか。
    fn verifyEntryDigest(self: *const Store, gpa: Allocator, key: []const u8, digest: [32]u8) !bool {
        const entry = (try self.entryPath(gpa, key)) orelse return false;
        defer gpa.free(entry);
        const marker_file = std.fs.path.join(gpa, &.{ entry, complete_marker }) catch return false;
        defer gpa.free(marker_file);
        const marker = std.Io.Dir.cwd().readFileAlloc(self.io, marker_file, gpa, .limited(4096)) catch return false;
        defer gpa.free(marker);
        var recorded: [32]u8 = undefined;
        if (!parseMarkerDigest(marker, &recorded) or !std.mem.eql(u8, &recorded, &digest)) return false;
        const tree = std.fs.path.join(gpa, &.{ entry, "tree" }) catch return false;
        defer gpa.free(tree);
        const actual = digestTree(self.io, gpa, tree, &.{}) catch return false;
        return std.mem.eql(u8, &actual, &digest);
    }

    /// entry（改変検出・不完全など）を削除する。cache lock 保持中に呼ぶこと。
    pub fn removeEntry(self: *const Store, key: []const u8) !void {
        const entry = (try self.entryPath(self.gpa, key)) orelse return error.InvalidKey;
        defer self.gpa.free(entry);
        try environment.deleteTreeChecked(std.Io.Dir.cwd(), self.io, entry);
    }

    /// 完了 marker の無い entry（公開途中で中断した残骸）を削除する。
    /// cache lock 保持中に呼ぶこと。
    /// 管理 dir は symlink 非追従で開き、削除は dir ハンドル相対で行う
    /// （管理 dir 自身の symlink による cache 外への逸脱を防ぐ）。
    pub fn pruneIncomplete(self: *const Store) !void {
        const objects = try std.fs.path.join(self.gpa, &.{ self.root, objects_dir });
        defer self.gpa.free(objects);
        var dir = openManagedDir(self.io, objects) catch |err| switch (err) {
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
        const staging = try std.fs.path.join(self.gpa, &.{ self.root, staging_dir });
        defer self.gpa.free(staging);
        var sdir = openManagedDir(self.io, staging) catch return;
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
        // 完了 marker を staging 内に書いてから rename する。rename は atomic
        // なので、観測される entry は常に marker 付きの完全なものになる。
        // marker には `tree/` の内容 digest を記録し、hit 時の再検証に使う
        // （共有 cache を改変されても marker だけで信頼しない契約）。
        const tree = try std.fs.path.join(self.gpa, &.{ staging_abs, "tree" });
        defer self.gpa.free(tree);
        const digest = try digestTree(self.io, self.gpa, tree, &.{});
        var marker: [7 + 64 + 1]u8 = undefined;
        @memcpy(marker[0..7], "sha256:");
        @memcpy(marker[7..71], &std.fmt.bytesToHex(digest, .lower));
        marker[71] = '\n';
        const marker_file = try std.fs.path.join(self.gpa, &.{ staging_abs, complete_marker });
        defer self.gpa.free(marker_file);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = marker_file, .data = &marker });
        const dest = try std.fs.path.join(self.gpa, &.{ self.root, objects_dir, key });
        defer self.gpa.free(dest);
        std.Io.Dir.renameAbsolute(staging_abs, dest, self.io) catch |rename_err| switch (rename_err) {
            // Destination exists (or was concurrently created). Do not assume a
            // matching key proves its contents: verify both its marker and tree
            // against this already-verified staging digest before discarding data.
            error.IsDir, error.NotDir, error.DirNotEmpty, error.AccessDenied => {
                if (try self.verifyEntryDigest(self.gpa, key, digest)) {
                    try environment.deleteTreeChecked(std.Io.Dir.cwd(), self.io, staging_abs);
                } else {
                    self.removeEntry(key) catch |remove_err| switch (remove_err) {
                        error.FileNotFound => {},
                        else => return remove_err,
                    };
                    try std.Io.Dir.renameAbsolute(staging_abs, dest, self.io);
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
        const objects = try std.fs.path.join(self.gpa, &.{ self.root, objects_dir });
        defer self.gpa.free(objects);
        var removed: usize = 0;
        var dir = openManagedDir(self.io, objects) catch |err| switch (err) {
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

    /// objects・checkouts・staging の全内容を削除する（cache の完全初期化）。
    /// cache lock 保持中に呼ぶこと。戻り値は削除したトップレ項目数。
    /// 管理 dir は symlink 非追従で開き、削除は dir ハンドル相対で行う
    /// （管理 dir 自身の symlink による cache 外への逸脱を防ぐ）。
    pub fn cleanAll(self: *const Store) !usize {
        var removed: usize = 0;
        const subdirs = [_][]const u8{ objects_dir, staging_dir, checkouts_dir };
        for (subdirs) |sub| {
            const base = try std.fs.path.join(self.gpa, &.{ self.root, sub });
            defer self.gpa.free(base);
            var dir = openManagedDir(self.io, base) catch |err| switch (err) {
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
        // cache root ハンドル相対で `cache.lock` を開く。leaf symlink は
        // openManagedLockFile がリンク本体のみ除去して作り直す。
        var root_dir = std.Io.Dir.cwd().openDir(self.io, self.root, .{
            .follow_symlinks = false,
        }) catch |err| return err;
        defer root_dir.close(self.io);
        var file = environment.openManagedLockFile(root_dir, self.io, lock_name, nonblocking) catch |err| switch (err) {
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

fn openTempStore(temporary: *std.testing.TmpDir) !Store {
    const root = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return try Store.open(testing.allocator, testing.io, root);
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
