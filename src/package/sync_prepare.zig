//! `sync.run` の package 取得・検証系。lock の source pin と materialize 済み
//! tree の digest 照合、cache object 構築、manifest/exports/commands の解決を
//! 担う。同期の entry point は `sync.zig` 側にある。

const std = @import("std");
const builtin = @import("builtin");
const zip = @import("../archive/zip.zig");
const cache = @import("cache.zig");
const diag = @import("diagnostics.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const materialize = @import("materialize.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const npkg_verify = @import("npkg_verify.zig");
const path_digest = @import("path_digest.zig");
const provider = @import("provider.zig");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const unpack = @import("unpack.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = enum {
    lnako,
    cnako,

    pub fn name(self: Runtime) []const u8 {
        return @tagName(self);
    }
};

pub const Error = error{
    LockNotFound,
    LockInvalid,
    /// `nako.toml` が存在するのに lock の `manifestSha256` と一致しない。
    StaleLock,
    UnknownProfile,
    InvalidProfile,
    MissingSource,
    MissingArtifact,
    Busy,
    InvalidKey,
    InvalidGeneration,
    /// cache・環境 dir の作成・rename・削除など予期しない IO 失敗。
    FileSystem,
    OutOfMemory,
} || fetch.Error;

/// fs 由来の広いエラーセットを `Error` へ畳み込む。OOM・Canceled・Busy は
/// そのまま伝え、それ以外の IO 失敗は `FileSystem` にまとめる。
pub fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Busy => error.Busy,
        else => error.FileSystem,
    };
}

/// `materialize.copyTree` の失敗を診断付き `Error` へ変換する。規範外・
/// symlink・重複は unsafe な package 内容として `invalid_source`、量の
/// 上限超過は `too_large`、残る IO 失敗は `FileSystem`。
fn mapTreeError(ctx: *Context, err: anyerror, subject: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.SymlinkEncountered, error.UnsupportedEntry, error.NonCanonicalPath, error.DuplicatePath, error.CaseCollision => ctx.session.fail(.invalid_source, .package, subject, "package tree for \"{s}\" is not safe to materialize: {s}", .{ subject, @errorName(err) }),
        error.TooManyEntries, error.FileTooLarge, error.TreeTooLarge, error.TreeTooDeep => ctx.session.fail(.too_large, .package, subject, "package tree for \"{s}\" exceeds materialize limits: {s}", .{ subject, @errorName(err) }),
        else => error.FileSystem,
    };
}

/// materialize 済みの generation tree を lock の pin と照合する。
/// 宣言 dir の前後照合だけでは、検査通過後に内容を差し替えて copy
/// させてから元へ戻す挟み撃ちで未 pin の bytes が環境へ残るため、
/// 公開対象の複製 tree 自身を pin と照合して塞ぐ。
fn verifyMaterializedPathPin(ctx: *const Context, entry: *const lock_model.PackageEntry, tree_dir: std.Io.Dir) Error!void {
    const pin = path_digest.pinnedSourceHash(entry) orelse
        return ctx.session.fail(.invalid_source, .package, entry.name, "path dependency \"{s}\" has no source pin", .{entry.name});
    const copied_digest = path_digest.digestDir(ctx.io, ctx.gpa, tree_dir) catch |err| return mapFs(err);
    if (!path_digest.pinHashMatches(copied_digest, pin)) {
        return ctx.session.fail(.hash_mismatch, .package, entry.name, "materialized path dependency \"{s}\" does not match nako.lock pin", .{entry.name});
    }
}

/// mutable path 依存の metadata 読取用 snapshot の digest を
/// `lock.input.mutable_paths` の記録と照合する。workspace 内の複製を
/// digest 化して記録と一致した snapshot だけを metadata の読取 source
/// として使う（live tree の未検証 metadata を公開しない）。
fn verifyMutablePathSnapshot(ctx: *const Context, dep_name: []const u8, rel: []const u8, snapshot_dir: std.Io.Dir) Error!void {
    const actual_digest = path_digest.digestDir(ctx.io, ctx.gpa, snapshot_dir) catch |err| return mapFs(err);
    const actual = try std.fmt.allocPrint(ctx.arena, "sha256:{s}", .{std.fmt.bytesToHex(actual_digest, .lower)});
    for (ctx.lock.input.mutable_paths) |mutable| {
        if (std.mem.eql(u8, mutable.path, rel)) {
            if (!std.mem.eql(u8, actual, mutable.sha256)) {
                return ctx.session.fail(.hash_mismatch, .package, dep_name, "snapshot of mutable path dependency \"{s}\" does not match nako.lock digest", .{dep_name});
            }
            return;
        }
    }
    // mutable path 宣言に記録が無い状態は sync 開始時の
    // mutablePathMismatchDir で既に拒否される。ここは防御のための不一致。
    return ctx.session.fail(.invalid_source, .package, dep_name, "mutable path dependency \"{s}\" has no recorded digest", .{dep_name});
}

pub const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    session: *fetch.Session,
    cache_store: *const cache.Store,
    project_abs: []const u8,
    /// pinned project root handle。lock・manifest・相対 path 依存の宣言
    /// dir の解決はこの handle 相対で行い、root の rename/replace 競合で
    /// 別 dir を参照しない。
    project_dir: std.Io.Dir,
    /// 同期対象の lock（mutable path の記録 digest 参照用）。
    lock: *const lock_model.Lock,
    /// `<gen>/deps`（materialize 先）、generation dir handle 相対で開いたもの。
    deps_dir: std.Io.Dir,
    /// `.lnako-work-<gen>` の pinned handle。artifact の一時 archive・
    /// 展開先はこの handle 相対にだけ作る（絶対 path を再解決しない）。
    workspace_dir: std.Io.Dir,
    /// `.nako/env/<gen>`（env.json の path に使う前置）。
    generation_rel: []const u8,
    runtime: Runtime,
    target: resolver.Target,
    used_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    used_names: std.StringHashMapUnmanaged(void) = .empty,

    /// 検証済み cache tree の snapshot は `workspace_dir`（同期専有の
    /// project 内 workspace）へ置く。共有 cache `staging/` 内だと別の
    /// cache 書込主体が列挙・差替えできるため、snapshot 親 dir は
    /// workspace handle で固定する。
    fn objectTree(self: *const Context, key: []const u8) Error!?cache.Store.VerifiedTree {
        return self.cache_store.openVerifiedTree(self.gpa, key, self.workspace_dir) catch |err| return mapFs(err);
    }
};

/// `nako.lock` を読み、環境を同期する。失敗時は `session` 由来の診断を

// ---------------------------------------------------------------------------
// package 取得
// ---------------------------------------------------------------------------

pub fn preparePackage(ctx: *Context, entry: *const lock_model.PackageEntry) Error!environment.PackageRecord {
    const arena = ctx.arena;
    const source = entry.source orelse entry.resolved_from orelse {
        return ctx.session.fail(.invalid_source, .package, entry.name, "package \"{s}\" has no source in the lock", .{entry.name});
    };

    var env_path: []const u8 = undefined;
    var manifest: ?manifest_mod.Manifest = null;
    var tree_abs: ?[]const u8 = null;
    var tree_dir: ?std.Io.Dir = null;
    defer if (tree_dir) |*dir| dir.close(ctx.io);
    var verified_commands: ?[]const npkg_commands.Command = null;
    var manifest_from_npkg = false;

    switch (source.kind) {
        .path => {
            const rel = source.path orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "path source of \"{s}\" has no path", .{entry.name});
            // 非規範の形式（空成分・`.` 成分・末尾 separator・制御文字）だけ
            // 拒否する。spec §3.4.3 は相対・絶対の双方を許容するため `..` や
            // 絶対 path は宣言者の正当な選択であり、lock の契約でも禁止されない。
            if (!isCanonicalDepPath(rel)) {
                return ctx.session.fail(.invalid_source, .package, entry.name, "path of \"{s}\" is not a canonical dependency path: \"{s}\"", .{ entry.name, rel });
            }
            const mutable = source.mutable orelse false;
            // commands 走査の診断表示・記録用の絶対 path（env.json には宣言
            // path を記録する）。内容の解決は pinned handle 相対で行い、
            // この絶対 path は表示・記録にだけ使う。
            const dep_abs = if (provider.isAbsoluteDepPath(rel))
                try arena.dupe(u8, rel)
            else
                try std.fs.path.join(arena, &.{ ctx.project_abs, rel });
            // 宣言 dir を開く。相対 path は pinned project root handle 相対で
            // 解決し、root の rename/replace 競合で別 dir を読まない。宣言
            // root が directory symlink の場合も path_digest（root のみ
            // follow）と同じ契約で受理するため root は follow して開く。
            // 内部 entry の no-follow 制約は materialize 側の走査で維持される。
            // 絶対 path 宣言は project root の外なので cwd で開く。
            var dep_dir = if (provider.isAbsoluteDepPath(rel))
                std.Io.Dir.cwd().openDir(ctx.io, rel, .{ .iterate = true, .follow_symlinks = true }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return ctx.session.fail(.unavailable, .package, dep_abs, "cannot open path dependency \"{s}\" directory: {s}", .{ entry.name, @errorName(err) }),
                }
            else
                ctx.project_dir.openDir(ctx.io, rel, .{ .iterate = true, .follow_symlinks = true }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return ctx.session.fail(.unavailable, .package, dep_abs, "cannot open path dependency \"{s}\" directory: {s}", .{ entry.name, @errorName(err) }),
                };
            defer dep_dir.close(ctx.io);
            if (mutable) {
                // mutable source は宣言 dir を生参照する（env_path には宣言
                // path を記録）。ただし manifest・exports・commands の
                // metadata は workspace 内の digest 照合済み snapshot から
                // 読む。live tree を読むと事前照合後の変更で未検証の
                // metadata を公開し得るため、同期専有 workspace へ複製し
                // その digest を lock 記録と照合した上で読む。
                var snapshots = environment.openManagedChildDir(ctx.workspace_dir, ctx.io, "path-snapshots", true) catch |err| return mapFs(err);
                defer snapshots.close(ctx.io);
                const snapshot_name = try shortKey(arena, "path", &.{ entry.name, rel });
                var snapshot = environment.openManagedChildDir(snapshots, ctx.io, snapshot_name, true) catch |err| return mapFs(err);
                _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, &dep_dir, &snapshot, .{ .exclude_names = &cache.source_pin_exclude }) catch |err| {
                    snapshot.close(ctx.io);
                    return mapTreeError(ctx, err, entry.name);
                };
                try verifyMutablePathSnapshot(ctx, entry.name, rel, snapshot);
                manifest = try provider.readDependencyManifestDir(ctx.session, snapshot, "nako.toml", dep_abs, entry.name, "path");
                env_path = try arena.dupe(u8, rel);
                tree_abs = dep_abs;
                tree_dir = snapshot;
            } else {
                // immutable path 依存は内容 pin した snapshot を generation
                // 内へ複製してその path を記録する。宣言 dir を生参照したまま
                // 公開すると、sync 後の編集が lock を変えずに `--no-sync`
                // 消費者へ届いてしまうため。digest 対象外の `.nako`/`.git`
                // は複製しない。manifest・exports・commands の metadata は
                // pin 照合済みの複製 tree から読み、宣言 dir の live 参照は
                // しない（複製中の差替えで未検証 metadata を読まないため）。
                const materialized = try materializeIntoGeneration(ctx, entry.name, &dep_dir, .{ .exclude_names = &cache.source_pin_exclude });
                tree_dir = materialized.tree_dir;
                env_path = materialized.env_path;
                try verifyMaterializedPathPin(ctx, entry, materialized.tree_dir);
                manifest = try provider.readDependencyManifestDir(ctx.session, materialized.tree_dir, "nako.toml", dep_abs, entry.name, "path");
            }
        },
        .git => {
            const url = source.url orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "git source of \"{s}\" has no url", .{entry.name});
            const commit = source.commit orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "git source of \"{s}\" has no commit", .{entry.name});
            // repo 内 subdir は repo 境界内の相対 path のみ許容する。`..` や
            // 絶対 path で checkout の外を指す細工した lock を拒否する
            // （path 依存と違い repo 外参照は契約に無い）。
            if (source.path) |sub| {
                if (!isCanonicalRepoPath(sub)) {
                    return ctx.session.fail(.invalid_source, .package, entry.name, "git subdir of \"{s}\" is not a repo-relative path: \"{s}\"", .{ entry.name, sub });
                }
            }
            // Cache の tree/marker は同じ攻撃者が書き換えられるため、Git object
            // cache hit でも必ず lock commit を Git object database で再検証し、
            // pinned checkout から package tree を再生成する。
            const object_key = try shortKey(arena, "git", &.{ url, commit, source.path orelse "" });
            try rememberKey(ctx, object_key);
            const checkout_key = try shortKey(arena, "git", &.{ url, source.path orelse "" });
            var checkouts = environment.openManagedChildDir(ctx.workspace_dir, ctx.io, "git-checkouts", true) catch |err| return mapFs(err);
            defer checkouts.close(ctx.io);
            var checkout = environment.openManagedChildDir(checkouts, ctx.io, checkout_key, true) catch |err| return mapFs(err);
            defer environment.deleteTreeChecked(checkouts, ctx.io, checkout_key) catch {};
            defer checkout.close(ctx.io);
            // checkout の読書き・Git subprocess は全てこの pinned handle 相対
            // で行い、作業 dir の絶対 path は一切使わない。
            const cached_checkout_opt = ctx.cache_store.openCheckout(checkout_key) catch |err| return mapFs(err);
            if (cached_checkout_opt) |cached_checkout| {
                var cached = cached_checkout;
                defer cached.close(ctx.io);
                _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, &cached, &checkout, cache.checkout_copy_options) catch |err| return mapTreeError(ctx, err, entry.name);
            }
            const acquired = try provider.acquireGit(ctx.session, .{
                .name = entry.name,
                .url = url,
                .commit = commit,
                .path = source.path,
            }, checkout, source);
            manifest = acquired.manifest;
            const resolved_commit = acquired.source.commit orelse commit;
            if (!std.mem.eql(u8, resolved_commit, commit)) {
                return ctx.session.fail(.source_collision, .repository, url, "git source of \"{s}\" resolved to {s}, lock expects {s}", .{ entry.name, resolved_commit, commit });
            }
            // repository 全体（object database 含む）の複写なので package
            // tree 用の上限ではなく checkout 用の緩和済み制限を使う。
            _ = ctx.cache_store.replaceCheckout(checkout_key, &checkout, cache.checkout_copy_options) catch |err| return mapTreeError(ctx, err, entry.name);
            try buildGitObject(ctx, object_key, &checkout, source.path);
            var tree_handle = try ctx.objectTree(object_key);
            if (tree_handle == null) return error.FileSystem;
            defer tree_handle.?.close();
            const materialized = try materializeIntoGeneration(ctx, entry.name, &tree_handle.?.dir, .{});
            tree_dir = materialized.tree_dir;
            env_path = materialized.env_path;
        },
        .http => {
            const url = source.url orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "http source of \"{s}\" has no url", .{entry.name});
            const declared_hash = source.hash orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "http source of \"{s}\" has no hash", .{entry.name});
            const object_key = try artifactKey(arena, "http", declared_hash, url);
            try rememberKey(ctx, object_key);
            var archive: ?[]const u8 = try ctx.cache_store.readVerifiedSourceArchive(arena, object_key, declared_hash);
            var artifact_type: []const u8 = if (archive) |cached| provider.httpArtifactType(cached) else "raw";
            if (archive == null) {
                if (ctx.cache_store.entryExists(object_key)) {
                    ctx.cache_store.removeEntry(object_key) catch |err| return mapFs(err);
                }
                const acquired = try provider.acquireHttp(ctx.session, .{
                    .name = entry.name,
                    .url = url,
                    .hash = declared_hash,
                });
                archive = acquired.artifact_bytes.?;
                artifact_type = acquired.artifact_type orelse "raw";
                manifest = acquired.manifest;
            }
            manifest_from_npkg = std.mem.eql(u8, artifact_type, ".npkg");
            // Cache tree/marker は自己認証に過ぎない。毎回 lock hash を検証した
            // raw bytes から tree を再構築し、derived tree を信頼根拠にしない。
            const prepared = try buildArtifactObject(ctx, object_key, archive.?, artifact_type, entry);
            applyPrepared(&manifest, &verified_commands, prepared);
            manifest = manifest orelse try checkedCachedManifest(ctx, object_key, entry);
            var tree_handle = try ctx.objectTree(object_key);
            if (tree_handle == null) return error.FileSystem;
            defer tree_handle.?.close();
            const materialized = try materializeIntoGeneration(ctx, entry.name, &tree_handle.?.dir, .{});
            tree_dir = materialized.tree_dir;
            env_path = materialized.env_path;
        },
        .registry, .static => {
            // lock が記録する `source.url` は package 固有 URL であり、
            // registry ルートではない。同期時は index を引き直さず、
            // lock の artifact URL・hash・type を直接使って取得・検証する。
            const artifact = selectArtifact(ctx, entry) orelse
                return ctx.session.fail(.not_found, .artifact, entry.name, "package \"{s}\" has no artifact for runtime \"{s}\"", .{ entry.name, ctx.runtime.name() });
            manifest_from_npkg = if (artifact.type) |artifact_type| std.mem.eql(u8, artifact_type, ".npkg") else false;
            const url = artifact.url orelse
                return ctx.session.fail(.invalid_source, .artifact, entry.name, "artifact \"{s}\" of \"{s}\" has no url", .{ artifact.key, entry.name });
            const object_key = try artifactKey(arena, "artifact", artifact.sha256 orelse artifact.key, url);
            try rememberKey(ctx, object_key);
            var archive: ?[]const u8 = null;
            if (artifact.sha256) |expected| {
                archive = try ctx.cache_store.readVerifiedSourceArchive(arena, object_key, expected);
            }
            if (archive == null) {
                if (ctx.cache_store.entryExists(object_key)) {
                    ctx.cache_store.removeEntry(object_key) catch |err| return mapFs(err);
                }
                const bytes = try fetch.fetchBytes(ctx.session, url, .artifact);
                if (artifact.sha256) |expected| {
                    try fetch.verifyHash(ctx.session, bytes, expected, url, .artifact);
                }
                archive = bytes;
            }
            // lock artifact hash と一致した raw archive から毎回展開する。
            // hash の無い artifact は cache bytes を一切信頼せず再取得する。
            const prepared = try buildArtifactObject(ctx, object_key, archive.?, artifact.type orelse "raw", entry);
            applyPrepared(&manifest, &verified_commands, prepared);
            manifest = manifest orelse try checkedCachedManifest(ctx, object_key, entry);
            var tree_handle = try ctx.objectTree(object_key);
            if (tree_handle == null) return error.FileSystem;
            defer tree_handle.?.close();
            const materialized = try materializeIntoGeneration(ctx, entry.name, &tree_handle.?.dir, .{});
            tree_dir = materialized.tree_dir;
            env_path = materialized.env_path;
        },
    }

    // exports・commands は manifest がある場合だけ記録する。
    // `.npkg` を verify した経路では検証済み model をそのまま使う。
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    if (manifest) |*m| {
        if (manifest_mod.hasUnsafeNonNpkgExportTargets(m, manifest_from_npkg)) {
            return ctx.session.fail(.invalid_metadata, .manifest, entry.name, "package \"{s}\" has an export target that is not a canonical package-relative path", .{entry.name});
        }
        exports = try resolveExports(ctx, m, entry, tree_abs, tree_dir);
    }
    const commands: []const npkg_commands.Command = verified_commands orelse blk: {
        if (manifest) |*m| break :blk try collectCommands(ctx, tree_abs, tree_dir, m);
        if (tree_abs != null or tree_dir != null) break :blk try collectCommands(ctx, tree_abs, tree_dir, null);
        break :blk &.{};
    };

    return .{
        .key = try arena.dupe(u8, entry.id),
        .name = try arena.dupe(u8, entry.name),
        .version = try arena.dupe(u8, entry.version),
        .id = if (isPackageId(entry.id)) try arena.dupe(u8, entry.id) else null,
        .path = env_path,
        .exports = exports.items,
        .commands = commands,
    };
}

/// path 依存の宣言 path が byte 列として規範的か。spec §3.4.3 は相対・
/// 絶対の双方を許容するため `..` 成分や絶対 path は正当な入力（path 依存は
/// 宣言者が選ぶ局所 source であり、lock の契約でも禁止されない）。
/// ここでは細工した lock が混入させ得る非規範の形式だけを拒否する:
/// 空・末尾 separator（filesystem root を除く）・`.` 成分・途中の空成分・制御文字。
fn isCanonicalDepPath(path: []const u8) bool {
    if (path.len == 0) return false;
    const is_windows = builtin.os.tag == .windows;
    const separators = if (is_windows) "/\\" else "/";
    // Filesystem roots are the only canonical paths whose complete spelling
    // is a trailing separator; they cannot be normalized by trimming that byte.
    if (std.mem.eql(u8, path, "/")) return true;
    if (is_windows and path.len == 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return true;
    if (std.mem.indexOfScalar(u8, separators, path[path.len - 1]) != null) return false;
    const starts_sep = std.mem.indexOfScalar(u8, separators, path[0]) != null;
    var components = std.mem.splitAny(u8, path, separators);
    var index: usize = 0;
    while (components.next()) |component| : (index += 1) {
        if (component.len == 0) {
            // 先頭 separator（`/x`・`\\srv` の UNC 相当前置）のみ許容する。
            // `a//b` のような途中の空成分は非規範として拒否する。
            if (!(starts_sep and index <= 1)) return false;
            continue;
        }
        if (std.mem.eql(u8, component, ".")) return false;
        for (component) |byte| {
            if (byte < 0x20 or byte == 0x7f) return false;
        }
    }
    return true;
}

test "verifyMaterializedPathPin は generation 複製 tree を lock pin と照合する" {
    // 宣言 dir の前後照合の隙間（copy 中の差し替え→復元）で混入する
    // 未 pin bytes を塞ぐため、複製後の tree 自身を pin と照合する。
    const allocator = testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var session = fetch.Session.init(allocator, testing.io, .{});
    defer session.deinit();
    session.diagnostics = &diagnostics;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDir(testing.io, "tree", .default_dir);
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "tree/a.txt", .data = "pinned" });
    var tree_dir = try temporary.dir.openDir(testing.io, "tree", .{ .iterate = true });
    defer tree_dir.close(testing.io);

    var ctx = Context{
        .gpa = allocator,
        .arena = arena_impl.allocator(),
        .io = testing.io,
        .session = &session,
        .cache_store = undefined,
        .project_abs = "",
        .project_dir = std.Io.Dir.cwd(),
        .lock = undefined,
        .deps_dir = undefined,
        .workspace_dir = undefined,
        .generation_rel = "",
        .runtime = .lnako,
        .target = .{},
    };

    const digest = try path_digest.digestDir(testing.io, allocator, tree_dir);
    const pin = try std.fmt.allocPrint(arena_impl.allocator(), "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    const ok_artifacts = [_]lock_model.Artifact{.{ .key = "source", .kind = "source", .type = "raw", .sha256 = pin }};
    const ok_entry = lock_model.PackageEntry{ .id = "pkg:11111111111111111111111111111111", .name = "lib", .version = "1.0.0", .artifacts = &ok_artifacts };
    try verifyMaterializedPathPin(&ctx, &ok_entry, tree_dir);

    // 複製結果が pin と異なる tree（copy 中の改変相当）を拒否する。
    const wrong_digest = [_]u8{0x5a} ** 32;
    const wrong_pin = try std.fmt.allocPrint(arena_impl.allocator(), "sha256:{s}", .{std.fmt.bytesToHex(wrong_digest, .lower)});
    const bad_artifacts = [_]lock_model.Artifact{.{ .key = "source", .kind = "source", .type = "raw", .sha256 = wrong_pin }};
    const bad_entry = lock_model.PackageEntry{ .id = "pkg:11111111111111111111111111111111", .name = "lib", .version = "1.0.0", .artifacts = &bad_artifacts };
    try testing.expectError(error.HashMismatch, verifyMaterializedPathPin(&ctx, &bad_entry, tree_dir));

    // pin 自体が無い immutable path entry は source 定義不全。
    const unpinned = lock_model.PackageEntry{ .id = "pkg:11111111111111111111111111111111", .name = "lib", .version = "1.0.0" };
    try testing.expectError(error.InvalidSource, verifyMaterializedPathPin(&ctx, &unpinned, tree_dir));
}

test "verifyMutablePathSnapshot は metadata snapshot を lock 記録 digest と照合する" {
    // mutable path 依存の manifest・exports・commands は live tree では
    // なく digest 照合済み snapshot から読む契約の検証。
    const allocator = testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var session = fetch.Session.init(allocator, testing.io, .{});
    defer session.deinit();
    session.diagnostics = &diagnostics;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDir(testing.io, "tree", .default_dir);
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "tree/a.txt", .data = "recorded" });
    var tree_dir = try temporary.dir.openDir(testing.io, "tree", .{ .iterate = true });
    defer tree_dir.close(testing.io);

    const digest = try path_digest.digestDir(testing.io, allocator, tree_dir);
    const recorded = try std.fmt.allocPrint(arena_impl.allocator(), "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    const wrong = try std.fmt.allocPrint(arena_impl.allocator(), "sha256:{s}", .{std.fmt.bytesToHex([_]u8{0x5a} ** 32, .lower)});
    const mutable_paths = [_]lock_model.MutablePath{.{ .path = "deps/lib", .sha256 = recorded }};
    const lock_arena = std.heap.ArenaAllocator.init(allocator);
    const lock = lock_model.Lock{
        .arena = lock_arena,
        .input = .{
            .manifest_sha256 = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            .profile = "default",
            .target = .{ .os = "macos", .cpu = "aarch64", .abi = "gnu" },
            .mutable_paths = &mutable_paths,
        },
    };
    var ctx = Context{
        .gpa = allocator,
        .arena = arena_impl.allocator(),
        .io = testing.io,
        .session = &session,
        .cache_store = undefined,
        .project_abs = "",
        .project_dir = std.Io.Dir.cwd(),
        .lock = &lock,
        .deps_dir = undefined,
        .workspace_dir = undefined,
        .generation_rel = "",
        .runtime = .lnako,
        .target = .{},
    };

    // 記録 digest と一致する snapshot は受理する。
    try verifyMutablePathSnapshot(&ctx, "lib", "deps/lib", tree_dir);
    // 別 path の記録は `deps/lib` には使えない（宣言 path で照合する）。
    const other_paths = [_]lock_model.MutablePath{.{ .path = "deps/other", .sha256 = recorded }};
    var lock_other = lock;
    lock_other.input.mutable_paths = &other_paths;
    ctx.lock = &lock_other;
    try testing.expectError(error.InvalidSource, verifyMutablePathSnapshot(&ctx, "lib", "deps/lib", tree_dir));
    // 記録 digest と異なる snapshot は拒否する。
    const wrong_paths = [_]lock_model.MutablePath{.{ .path = "deps/lib", .sha256 = wrong }};
    var lock_wrong = lock;
    lock_wrong.input.mutable_paths = &wrong_paths;
    ctx.lock = &lock_wrong;
    try testing.expectError(error.HashMismatch, verifyMutablePathSnapshot(&ctx, "lib", "deps/lib", tree_dir));
}

test "sync fails when a selected export has no eligible implementation" {
    const allocator = testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var session = fetch.Session.init(allocator, testing.io, .{});
    defer session.deinit();
    session.diagnostics = &diagnostics;
    var ctx = Context{
        .gpa = allocator,
        .arena = arena_impl.allocator(),
        .io = testing.io,
        .session = &session,
        .cache_store = undefined,
        .project_abs = "",
        .project_dir = std.Io.Dir.cwd(),
        .lock = undefined,
        .deps_dir = undefined,
        .workspace_dir = undefined,
        .generation_rel = "",
        .runtime = .lnako,
        .target = .{},
    };
    const requires_feature = [_][]const u8{"native-feature"};
    const export_decl = manifest_mod.Export{
        .name = "entry",
        .native = &.{.{ .path = "entry.native", .features = &requires_feature }},
    };
    const target = exportArtifactTarget("lnako", .{
        .runtime = "lnako",
        .nako_version = try semver.Version.parse("3.7.24"),
    }, &.{});
    try testing.expectError(error.InvalidMetadata, resolveExportForSync(&ctx, &export_decl, target, false));
    try testing.expect(diagnostics.errorCount() > 0);
}

test "source export target preserves resolved features and Nako version" {
    const features = [_][]const u8{"native"};
    const current_target = exportArtifactTarget("lnako", .{
        .runtime = "lnako",
        .nako_version = try semver.Version.parse("3.7.24"),
    }, &features);
    const declaration = manifest_mod.ArtifactDecl{
        .path = "native.nako3",
        .when = "\"native\" in features and version >= \"3.7.0\"",
        .features = &features,
    };
    try testing.expect(try declaration.matchesTarget(testing.allocator, current_target, true));

    const older_target = exportArtifactTarget("lnako", .{
        .runtime = "lnako",
        .nako_version = try semver.Version.parse("3.6.9"),
    }, &features);
    try testing.expect(!try declaration.matchesTarget(testing.allocator, older_target, true));

    const missing_feature_target = exportArtifactTarget("lnako", .{
        .runtime = "lnako",
        .nako_version = try semver.Version.parse("3.7.24"),
    }, &.{});
    try testing.expect(!try declaration.matchesTarget(testing.allocator, missing_feature_target, true));
}

test "canonical dependency path uses host separators and admits filesystem roots" {
    try std.testing.expect(isCanonicalDepPath("/"));
    try std.testing.expect(isCanonicalDepPath("/deps/lib"));
    try std.testing.expect(!isCanonicalDepPath("/deps/"));
    try std.testing.expect(!isCanonicalDepPath("deps/"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isCanonicalDepPath("C:\\"));
        try std.testing.expect(isCanonicalDepPath("C:/"));
        try std.testing.expect(isCanonicalDepPath("C:\\deps\\lib"));
        try std.testing.expect(!isCanonicalDepPath("C:\\deps\\"));
    } else {
        // POSIX dependency names may contain or end with backslashes.
        try std.testing.expect(isCanonicalDepPath("lib\\"));
        try std.testing.expect(isCanonicalDepPath("lib\\\\part"));
        try std.testing.expect(!isCanonicalDepPath("lib//part"));
    }
}

/// 指す契約のため `..`・`.`・空成分・`\`・制御文字・絶対形式を拒否する。
fn isCanonicalRepoPath(path: []const u8) bool {
    if (path.len == 0 or path[path.len - 1] == '/') return false;
    if (provider.isAbsoluteDepPath(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
        for (component) |byte| {
            if (byte < 0x20 or byte == 0x7f or byte == '\\') return false;
        }
    }
    return true;
}

pub fn isPackageId(id: []const u8) bool {
    if (id.len != 36 or !std.mem.startsWith(u8, id, "pkg:")) return false;
    for (id[4..]) |c| {
        if (!std.ascii.isHex(c) or (c >= 'A' and c <= 'F')) return false;
    }
    return true;
}

/// `source.<field>` 群から決定的な cache key を作る。`prefix-<sha256先頭16>`。
fn shortKey(arena: Allocator, prefix: []const u8, parts: []const []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(prefix);
    for (parts) |part| {
        hasher.update(&[_]u8{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(arena, "{s}-{s}", .{ prefix, hex[0..16] });
}

/// ジェストを key に使う。そうでなければ宣言 hash を key 材料へ含める。
/// sha256 以外（sha512 等）でも lock の hash 更新が必ず別 entry になるよう
/// URL だけを key にしない（同じ URL で配布物が更新される通常ケースで
/// 古い内容を復元しないため）。
fn artifactKey(arena: Allocator, prefix: []const u8, declared_hash: []const u8, identity: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    if (lock_model.normalizeSha256(declared_hash, &digest)) {
        const hex = std.fmt.bytesToHex(digest, .lower);
        return try std.fmt.allocPrint(arena, "{s}-{s}", .{ prefix, hex[0..32] });
    }
    if (declared_hash.len != 0) {
        return try shortKey(arena, prefix, &.{ declared_hash, identity });
    }
    return try shortKey(arena, prefix, &.{identity});
}

fn rememberKey(ctx: *Context, key: []const u8) !void {
    for (ctx.used_keys.items) |item| {
        if (std.mem.eql(u8, item, key)) return;
    }
    try ctx.used_keys.append(ctx.arena, key);
}

/// git checkout から cache object を構築する。`.git` を除いた作業木を
/// staging へ検証付きで複製し、原子的に公開する。source は checkout の
/// pinned handle 相対で開き、絶対 path を再解決しない。
fn buildGitObject(ctx: *Context, key: []const u8, checkout: *std.Io.Dir, sub_path: ?[]const u8) Error!void {
    var sub_source: ?std.Io.Dir = null;
    defer if (sub_source) |*dir| dir.close(ctx.io);
    if (sub_path) |sub| {
        sub_source = checkout.openDir(ctx.io, sub, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    }
    const source: *std.Io.Dir = if (sub_source) |*dir| dir else checkout;
    var staging = ctx.cache_store.openStaging(key) catch |err| return mapFs(err);
    var staging_open = true;
    defer if (staging_open) staging.close(ctx.io);
    staging.createDir(ctx.io, "tree", .default_dir) catch |err| return mapFs(err);
    var destination = staging.openDir(ctx.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, source, &destination, .{
        .exclude_names = &.{".git"},
    }) catch |err| return mapTreeError(ctx, err, key);
    destination.close(ctx.io);
    staging.close(ctx.io);
    staging_open = false;
    ctx.cache_store.publishStaging(key) catch |err| return mapFs(err);
}

/// `.npkg` を検証した場合に返す検証済み model。manifest・commands は
/// `ctx.arena`（または検証 arena）が所有する。
const PreparedArtifact = struct {
    manifest: ?manifest_mod.Manifest = null,
    commands: ?[]const npkg_commands.Command = null,
};

fn applyPrepared(manifest: *?manifest_mod.Manifest, commands: *?[]const npkg_commands.Command, prepared: PreparedArtifact) void {
    if (prepared.manifest) |m| manifest.* = m;
    if (prepared.commands) |c| commands.* = c;
}

/// lock `input` が記録した engine version 文字列を `resolver.Target` の
/// semver へ戻す。欠落・解析不能は null（未検査）として扱う。
fn inputVersion(text: ?[]const u8) ?semver.Version {
    const value = text orelse return null;
    return semver.Version.parse(value) catch null;
}

/// materialize（`.npkg` 検証・export 解決）用の target を組み立てる。
/// 解決時の実効 target を引き継ぐ。`--compat-js` で選択した ESM
/// artifact や `-O` で選択した実装を検証が別条件で reject しないよう、
/// lock の `input.target` に記録済みの値を使う。engines 制約・
/// version-gated export の評価も同じ version tuple で行う。
/// `--profile` で別 profile を指定した場合は、その record が宣言した
/// `optimize` を優先する（解決時と同じく CLI の `-O` は入力 profile
/// にしか適用しない）。
pub fn materializeTarget(profile: []const u8, record: ?*const lock_model.ProfileRecord, input: *const lock_model.Input, runtime: Runtime) resolver.Target {
    return .{
        .runtime = runtime.name(),
        .os = if (record) |r| r.os else input.target.os,
        .cpu = if (record) |r| r.cpu else input.target.cpu,
        .abi = if (record) |r| r.abi else input.target.abi,
        .compat_js = (if (record) |r| r.compat_js orelse false else false) or
            (std.mem.eql(u8, profile, input.profile) and input.target.compat_js),
        .optimize = if (std.mem.eql(u8, profile, input.profile))
            input.target.optimize
        else if (record) |r| r.optimize orelse "O0" else "O0",
        // `min-os` 照合は解決時に lock へ記録した要求 OS バージョンと同一で
        // 行う（未記録の旧 lock では null = 不明、min-os 付き宣言は不適合）。
        .os_version = input.target.os_version,
        .nako_version = inputVersion(input.nako_version),
        .cnako_version = inputVersion(input.cnako_version),
        .lnako_version = inputVersion(input.lnako_version),
    };
}

/// `.npkg` 検証用の target。profile/runtime・有効 feature・実環境条件を
/// 使って必須 metadata・FILES.toml・artifact 適合を検査する。
fn npkgTarget(ctx: *Context, entry: *const lock_model.PackageEntry) npkg_verify.Target {
    var default_features = false;
    for (entry.features) |feature| {
        if (std.mem.eql(u8, feature, "default")) default_features = true;
    }
    return .{
        .runtime = ctx.runtime.name(),
        .os = ctx.target.os,
        .cpu = ctx.target.cpu,
        .abi = ctx.target.abi,
        .os_version = ctx.target.os_version,
        .libc = ctx.target.libc,
        .compat_js = ctx.target.compat_js,
        .optimize = ctx.target.optimize,
        .features = entry.features,
        .default_features = default_features,
        .nako_version = ctx.target.nako_version,
        .cnako_version = ctx.target.cnako_version,
        .lnako_version = ctx.target.lnako_version,
    };
}

/// `unpack` の失敗を診断付き `Error` へ変換する。archive 破損・規範外・
/// symlink・重複は unsafe な内容として `invalid_source`、量の上限超過は
/// `too_large`、残る IO 失敗は `FileSystem`。
fn mapUnpackError(ctx: *Context, err: anyerror, subject: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.InvalidArchive, error.UnsupportedEntry, error.SymlinkEncountered, error.NonCanonicalPath, error.DuplicatePath, error.CaseCollision => ctx.session.fail(.invalid_source, .artifact, subject, "artifact archive \"{s}\" is not safe to extract: {s}", .{ subject, @errorName(err) }),
        error.TooManyEntries, error.FileTooLarge, error.TreeTooLarge, error.TreeTooDeep => ctx.session.fail(.too_large, .artifact, subject, "artifact archive \"{s}\" exceeds extraction limits: {s}", .{ subject, @errorName(err) }),
        else => error.FileSystem,
    };
}

/// 取得 bytes から cache object を構築する。`tree/` の内容は artifact
/// type ごとに決まる:
/// - `.npkg`: 実 target で `npkg_verify.verify` してから ZIP 展開する。
///   必須 metadata・FILES.toml・対象環境の不整合も公開しない。
/// - `tar.gz` / `npm-tarball`: gzip 解除して検証付き tar 展開。
/// - `raw`: `tree/blob` として保存。
/// - その他の有効宣言済み type は未対応として明示的に失敗する。
/// アーカイブ系は staging の兄弟 dir へ展開してから `materialize.copyTree`
/// の規則（規範 path・重複・大小文字衝突・量上限）を通して `tree/` へ入れる。
fn buildArtifactObject(ctx: *Context, key: []const u8, bytes: []const u8, artifact_type: []const u8, entry: *const lock_model.PackageEntry) Error!PreparedArtifact {
    const arena = ctx.arena;
    var staging = ctx.cache_store.openStaging(key) catch |err| return mapFs(err);
    var staging_open = true;
    defer if (staging_open) staging.close(ctx.io);
    staging.createDir(ctx.io, "tree", .default_dir) catch |err| return mapFs(err);
    // Keep the original bytes outside tree/ so a future hit can validate them
    // against the lock's artifact hash before rebuilding the derived tree.
    staging.writeFile(ctx.io, .{ .sub_path = "source.archive", .data = bytes }) catch |err| return mapFs(err);
    var tree = staging.openDir(ctx.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    var tree_open = true;
    defer if (tree_open) tree.close(ctx.io);
    // 一時アーカイブ・展開先は `ctx.workspace_dir`（pinned handle）相対に
    // だけ作る。`.lnako-work-<gen>` を指す絶対 path が rename→symlink 置換
    // されても、archive 書込み・展開・cleanup が project 外へ出ない。
    const extract_name = try std.fmt.allocPrint(arena, "artifact-{s}.extract", .{key});
    var prepared = PreparedArtifact{};
    if (std.mem.eql(u8, artifact_type, ".npkg")) {
        // 公開前に package 検証を通す。hash 照合済みでも必須 metadata・
        // ファイル索引・対象環境の不整合を staging から出さない。
        var scratch = diag.List.init(ctx.gpa);
        defer scratch.deinit();
        const verified = npkg_verify.verify(arena, bytes, npkgTarget(ctx, entry), ctx.session.diagSink(&scratch)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .artifact, key, ".npkg artifact \"{s}\" failed package verification", .{key}),
        };
        prepared.manifest = verified.manifest;
        prepared.commands = verified.commands;
        const archive_name = try std.fmt.allocPrint(arena, "artifact-{s}.archive", .{key});
        ctx.workspace_dir.writeFile(ctx.io, .{ .sub_path = archive_name, .data = bytes }) catch |err| return mapFs(err);
        defer ctx.workspace_dir.deleteFile(ctx.io, archive_name) catch {};
        ctx.workspace_dir.createDir(ctx.io, extract_name, .default_dir) catch |err| return mapFs(err);
        var extracted = ctx.workspace_dir.openDir(ctx.io, extract_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
        defer {
            extracted.close(ctx.io);
            environment.deleteTreeChecked(ctx.workspace_dir, ctx.io, extract_name) catch {};
        }
        var archive_file = ctx.workspace_dir.openFile(ctx.io, archive_name, .{}) catch |err| return mapFs(err);
        defer archive_file.close(ctx.io);
        zip.extractOpened(ctx.io, archive_file, bytes.len, extracted) catch |err| {
            return ctx.session.fail(.invalid_metadata, .artifact, key, "artifact archive failed boundary-checked extraction: {s}", .{@errorName(err)});
        };
        _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, &extracted, &tree, .{}) catch |err| return mapTreeError(ctx, err, key);
    } else if (std.mem.eql(u8, artifact_type, "tar.gz") or std.mem.eql(u8, artifact_type, "npm-tarball")) {
        // npm-tarball は `package/` 前置を持つため先頭成分を除外する。
        ctx.workspace_dir.createDir(ctx.io, extract_name, .default_dir) catch |err| return mapFs(err);
        var extracted = ctx.workspace_dir.openDir(ctx.io, extract_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
        defer {
            extracted.close(ctx.io);
            environment.deleteTreeChecked(ctx.workspace_dir, ctx.io, extract_name) catch {};
        }
        unpack.extractTarGzInto(arena, ctx.io, bytes, extracted, .{
            .strip_components = if (std.mem.eql(u8, artifact_type, "npm-tarball")) 1 else 0,
        }) catch |err| return mapUnpackError(ctx, err, key);
        _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, &extracted, &tree, .{}) catch |err| return mapTreeError(ctx, err, key);
    } else if (std.mem.eql(u8, artifact_type, "raw")) {
        tree.writeFile(ctx.io, .{ .sub_path = "blob", .data = bytes }) catch |err| return mapFs(err);
    } else {
        // lock が受理する既知 type でも未対応のものは成功扱いにしない。
        return ctx.session.fail(.invalid_metadata, .artifact, key, "unsupported artifact type \"{s}\" for \"{s}\"", .{ artifact_type, key });
    }
    tree.close(ctx.io);
    tree_open = false;
    staging.close(ctx.io);
    staging_open = false;
    ctx.cache_store.publishStaging(key) catch |err| return mapFs(err);
    return prepared;
}

/// cache object から読み直した manifest。`from_npkg` は `NAKO-PKG/
/// METADATA.toml` 由来（= `.npkg` artifact の展開物）の場合に真。
const CachedManifest = struct {
    manifest: manifest_mod.Manifest,
    from_npkg: bool,
};

/// cache object 内の manifest を読み直す。`tree/NAKO-PKG/METADATA.toml`
/// を優先し、無ければ `tree/nako.toml` を探す。どちらも無ければ null。
fn cachedManifest(ctx: *Context, key: []const u8) Error!?CachedManifest {
    const arena = ctx.arena;
    var tree = (ctx.cache_store.openVerifiedTree(ctx.gpa, key, ctx.workspace_dir) catch |err| return mapFs(err)) orelse return null;
    defer tree.close();
    // 両方ある package では配布向け正規化済みの METADATA.toml が正本。
    const candidates = [_]struct { rel: []const u8, npkg: bool }{
        .{ .rel = "NAKO-PKG/METADATA.toml", .npkg = true },
        .{ .rel = "nako.toml", .npkg = false },
    };
    for (candidates) |candidate| {
        const path = candidate.rel;
        const limit: std.Io.Limit = if (ctx.session.policy.max_bytes == 0) .unlimited else .limited(ctx.session.policy.max_bytes);
        // 「manifest が無い」のは FileNotFound のみ。読取不能・dir 化・
        // 上限超過などは「無いもの」として次候補へ流さず、cache entry の
        // 破損として invalid_metadata で失敗させる。
        const bytes = tree.dir.readFileAlloc(ctx.io, path, arena, limit) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .manifest, path, "cached manifest at \"{s}\" is unreadable: {s}", .{ path, @errorName(err) }),
        };
        var scratch = diag.List.init(ctx.gpa);
        defer scratch.deinit();
        const parsed = if (candidate.npkg)
            manifest_mod.parseNpkgMetadata(arena, bytes, ctx.session.diagSink(&scratch))
        else
            manifest_mod.parse(arena, bytes, ctx.session.diagSink(&scratch));
        const manifest = parsed catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .manifest, path, "cached manifest at \"{s}\" is invalid", .{path}),
        };
        return .{ .manifest = manifest, .from_npkg = candidate.npkg };
    }
    return null;
}

/// cache object から manifest を読み、`.npkg` 由来なら現在 target への適合を
/// 再検証する。展開済み object は公開時に検証済みだが、公開時と今回の
/// profile/target が異なり得るため hit 経路でも適合判定を省略しない。
/// manifest が無ければ null。不適合なら `invalid_metadata` で失敗する。
fn checkedCachedManifest(ctx: *Context, key: []const u8, entry: *const lock_model.PackageEntry) Error!?manifest_mod.Manifest {
    const cached = (try cachedManifest(ctx, key)) orelse return null;
    if (!cached.from_npkg) return cached.manifest;
    var manifest = cached.manifest;
    var scratch = diag.List.init(ctx.gpa);
    defer scratch.deinit();
    npkg_verify.checkManifestTarget(ctx.arena, &manifest, npkgTarget(ctx, entry), ctx.session.diagSink(&scratch)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.session.fail(.invalid_metadata, .artifact, key, "cached .npkg object \"{s}\" does not fit the requested target", .{key}),
    };
    return manifest;
}

/// registry artifact の選択。lock が記録した `implementation`（解決時に
/// 固定された実装種別）に従う。記録が無い古い lock は `source` 扱い。
/// `none` は実装を持たないため null。
fn selectArtifact(ctx: *Context, entry: *const lock_model.PackageEntry) ?*const lock_model.Artifact {
    _ = ctx;
    const implementation = entry.implementation orelse "source";
    if (std.mem.eql(u8, implementation, "none")) return null;
    return entry.artifact(implementation);
}

/// package 名を `.nako` 内 dir 名へ変換する。`[a-z0-9-]` 以外は `-` へ畳み、
/// 空なら hash 名を使う。同一世代内での重複には `-2`・`-3`…を付ける。
const MaterializedPackage = struct { env_path: []const u8, tree_dir: std.Io.Dir };

fn materializeIntoGeneration(ctx: *Context, package_name: []const u8, source: *std.Io.Dir, options: materialize.Options) Error!MaterializedPackage {
    const arena = ctx.arena;
    var sanitized: std.ArrayListUnmanaged(u8) = .empty;
    for (package_name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try sanitized.append(arena, std.ascii.toLower(c));
        } else {
            try sanitized.append(arena, '-');
        }
    }
    var dir_name = std.mem.trim(u8, sanitized.items, "-");
    if (dir_name.len == 0) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(package_name, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        dir_name = try std.fmt.allocPrint(arena, "pkg-{s}", .{hex[0..8]});
    }
    var final_name = dir_name;
    var suffix: u32 = 2;
    while (ctx.used_names.contains(final_name)) {
        final_name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ dir_name, suffix });
        suffix += 1;
    }
    try ctx.used_names.put(arena, try arena.dupe(u8, final_name), {});

    ctx.deps_dir.createDirPath(ctx.io, final_name) catch |err| return mapFs(err);
    var destination = ctx.deps_dir.openDir(ctx.io, final_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    _ = materialize.copyTreeFromDirs(ctx.gpa, ctx.io, source, &destination, options) catch |err| {
        destination.close(ctx.io);
        return mapTreeError(ctx, err, package_name);
    };
    return .{
        .env_path = try std.fs.path.join(arena, &.{ ctx.generation_rel, "deps", final_name }),
        .tree_dir = destination,
    };
}

/// export 宣言の選択に使う条件を、実際に解決された lock entry から構築する。
fn exportArtifactTarget(runtime: []const u8, target: resolver.Target, features: []const []const u8) manifest_mod.ArtifactTarget {
    return .{
        .runtime = runtime,
        .os = target.os,
        .cpu = target.cpu,
        .abi = target.abi,
        .compat_js = target.compat_js,
        .optimize = target.optimize,
        .version = target.nako_version,
        .features = features,
    };
}

/// Export.resolve の null は条件不一致（警告なし）と選択実装の失敗（error
/// diagnostics 付き）の双方を表す。sync では後者を package failure にする。
fn resolveExportForSync(ctx: *Context, export_decl: *const manifest_mod.Export, target: manifest_mod.ArtifactTarget, prefer_native: bool) Error!?manifest_mod.ExportResolution {
    var scratch = diag.List.init(ctx.gpa);
    defer scratch.deinit();
    const diagnostics = ctx.session.diagSink(&scratch);
    const prior_errors = diagnostics.errorCount();
    const resolution = export_decl.resolve(ctx.arena, target, prefer_native, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (resolution == null and diagnostics.errorCount() > prior_errors) {
        return ctx.session.fail(.invalid_metadata, .manifest, export_decl.name, "selected implementation for export \"{s}\" is not available for the sync target", .{export_decl.name});
    }
    return resolution;
}

/// 選択された export target が package tree 内に通常 file として存在するか。
/// `tree_dir`（materialize 済み）は handle 相対で確認する。`tree_abs`
/// （path 依存）は宣言 dir を開いて export path の各中間成分を no-follow
/// で辿る。dir・symlink・特殊 file は不適格（symlink 化した中間 dir 経由
/// で tree 外の file を指す宣言を env.json へ記録しない。宣言 dir 自身へ
/// の symlink は path pin・digest が担保した宣言位置の解決として辿る）。
fn exportTargetIsFile(ctx: *Context, tree_abs: ?[]const u8, tree_dir: ?std.Io.Dir, target: []const u8) bool {
    if (tree_dir) |dir| {
        const stat = dir.statFile(ctx.io, target, .{ .follow_symlinks = false }) catch return false;
        return stat.kind == .file;
    }
    const root = tree_abs orelse return false;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, root, .{}) catch return false;
    defer dir.close(ctx.io);
    var components = std.mem.splitScalar(u8, target, '/');
    while (components.next()) |component| {
        if (components.peek() == null) {
            const stat = dir.statFile(ctx.io, component, .{ .follow_symlinks = false }) catch return false;
            return stat.kind == .file;
        }
        const child = dir.openDir(ctx.io, component, .{ .follow_symlinks = false }) catch return false;
        dir.close(ctx.io);
        dir = child;
    }
    return false;
}

/// manifest の export を lock entry の解決結果に合わせて選択し、env.json の
/// `exports` 配列へ変換する。`native` は prefer-native として resolve へ渡し、
/// ESM は profile が許可する場合のみ含める。`none` は空を返す。
/// 選択された target が package tree 内に実在しない宣言は失敗させる
/// （明示 `commands.json` 等で source 走査を回避した経路でも env.json が
/// 不在 file を参照しないようにする）。
fn resolveExports(ctx: *Context, manifest: *const manifest_mod.Manifest, entry: *const lock_model.PackageEntry, tree_abs: ?[]const u8, tree_dir: ?std.Io.Dir) Error!std.ArrayListUnmanaged(environment.ExportRecord) {
    const implementation = entry.implementation;
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    if (implementation) |impl| {
        if (std.mem.eql(u8, impl, "none")) return exports;
    }
    const prefer_native = if (implementation) |impl| std.mem.eql(u8, impl, "native") else false;
    const target = exportArtifactTarget(ctx.runtime.name(), ctx.target, entry.features);
    for (manifest.exports) |*export_decl| {
        // 代表実装は lock が記録したパッケージ単位の選択結果で、各 export
        // の個別実装を縛るものではない。`native` 選択は `prefer_native` と
        // して渡し、export ごとの解決結果（source/native/esm）は個別に
        // 記録する（kind 不一致で export を捨てると source-only の公開
        // entry が env.json から消えて runtime 解決できなくなる）。
        const resolution = try resolveExportForSync(ctx, export_decl, target, prefer_native) orelse continue;
        if (resolution.kind == .esm and !(std.mem.eql(u8, ctx.runtime.name(), "cnako") or ctx.target.compat_js)) continue;
        if (!exportTargetIsFile(ctx, tree_abs, tree_dir, resolution.target)) {
            return ctx.session.fail(.invalid_metadata, .manifest, export_decl.name, "export target \"{s}\" of \"{s}\" does not exist as a regular file in the package tree", .{ resolution.target, entry.name });
        }
        try exports.append(ctx.arena, .{
            .name = try ctx.arena.dupe(u8, export_decl.name),
            .alias = if (export_decl.alias) |alias| try ctx.arena.dupe(u8, alias) else null,
            .path = try ctx.arena.dupe(u8, resolution.target),
        });
    }
    return exports;
}

/// 明示 `NAKO-PKG/commands.json` があればその index を採用し、無い場合は
/// manifest exports から生成する。index の有無に関わらず、source export
/// を起点とした import 閉包は必ず走査して検証する（`commands.json` は
/// あくまで index であり、閉包走査を省略すると `.nako`/`.git` 配下の未
/// pin 内容への取り込みを迂回できてしまう）。
fn collectCommands(ctx: *Context, tree_abs: ?[]const u8, tree_dir: ?std.Io.Dir, manifest: ?*const manifest_mod.Manifest) Error![]const npkg_commands.Command {
    const arena = ctx.arena;
    const display_root = tree_abs orelse ctx.generation_rel;
    var indexed_commands: ?[]const npkg_commands.Command = null;
    if (tree_dir) |tree| {
        if (tree.readFileAlloc(ctx.io, "NAKO-PKG/commands.json", arena, .limited(16 * 1024 * 1024))) |bytes| {
            var scratch = diag.List.init(ctx.gpa);
            defer scratch.deinit();
            const parsed = npkg_commands.parse(arena, bytes, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ctx.session.fail(.invalid_metadata, .manifest, display_root, "commands.json in package failed validation", .{}),
            };
            indexed_commands = parsed.commands;
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .manifest, display_root, "commands.json in package is unreadable: {s}", .{@errorName(err)}),
        }
    } else if (tree_abs) |root| {
        const commands_path = try std.fs.path.join(arena, &.{ root, "NAKO-PKG/commands.json" });
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, commands_path, arena, .limited(16 * 1024 * 1024))) |bytes| {
            var scratch = diag.List.init(ctx.gpa);
            defer scratch.deinit();
            const parsed = npkg_commands.parse(arena, bytes, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ctx.session.fail(.invalid_metadata, .manifest, commands_path, "commands.json in package failed validation", .{}),
            };
            indexed_commands = parsed.commands;
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .manifest, commands_path, "commands.json in package is unreadable: {s}", .{@errorName(err)}),
        }
    }
    const m = manifest orelse return indexed_commands orelse &.{};
    if (tree_abs == null and tree_dir == null) return indexed_commands orelse &.{};

    // export の source path を entry として静的に走査する。明示 index が
    // ある経路でも同じ走査を行い、解決した import 先の成分に `.nako`/
    // `.git` が現れた時点で拒否する（command 一覧の生成が不要でも検査は
    // 必要）。
    var entry_paths = std.ArrayListUnmanaged([]const u8).empty;
    for (m.exports) |*export_decl| {
        if (export_decl.path) |path| try entry_paths.append(arena, path);
    }
    if (entry_paths.items.len == 0) return indexed_commands orelse &.{};

    var provider_state = DirSourceProvider{
        .io = ctx.io,
        .root = if (tree_abs) |root| try arena.dupe(u8, root) else null,
        .dir = tree_dir,
    };
    var scratch = diag.List.init(ctx.gpa);
    defer scratch.deinit();
    const generated = npkg_commands_gen.generate(arena, provider_state.provider(), entry_paths.items, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.session.fail(.invalid_metadata, .manifest, m.package.name, "failed to derive commands for package \"{s}\"", .{m.package.name}),
    };
    // 明示 index があれば commands の記録内容は index を採用する。
    // `generate` は import 閉包の妥当性検査として動作した。
    if (indexed_commands) |commands| return commands;
    return generated.commands;
}

/// package dir からファイルを読む `npkg_commands_gen.SourceProvider`。
const DirSourceProvider = struct {
    io: std.Io,
    root: ?[]const u8,
    dir: ?std.Io.Dir,

    fn provider(self: *DirSourceProvider) npkg_commands_gen.SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *DirSourceProvider = @ptrCast(@alignCast(context));
        const bytes = if (self.dir) |dir|
            dir.readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            }
        else blk: {
            const abs = try std.fs.path.join(allocator, &.{ self.root.?, path });
            defer allocator.free(abs);
            break :blk std.Io.Dir.cwd().readFileAlloc(self.io, abs, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
        };
        return bytes;
    }
};

const testing = std.testing;

test "cachedManifest は manifest 欠落と読取不能を区別する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", testing.allocator);
    defer testing.allocator.free(cache_root);
    var store = try cache.Store.open(testing.allocator, io, cache_root);
    defer store.deinit();

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    var session = fetch.Session.init(testing.allocator, io, .{});
    defer session.deinit();
    var ctx = Context{
        .gpa = testing.allocator,
        .arena = arena_impl.allocator(),
        .io = io,
        .session = &session,
        .cache_store = &store,
        .project_abs = "",
        .project_dir = std.Io.Dir.cwd(),
        .lock = undefined,
        .deps_dir = temporary.dir,
        .workspace_dir = temporary.dir,
        .generation_rel = "",
        .runtime = .lnako,
        .target = .{},
    };

    // manifest を持たない完全な entry は null（読取不能とは区別する）。
    {
        var staging = try store.openStaging("cached-empty");
        try staging.createDir(io, "tree", .default_dir);
        staging.close(io);
        try store.publishStaging("cached-empty");
        try testing.expect((try cachedManifest(&ctx, "cached-empty")) == null);
    }

    // `nako.toml` が file でなく dir 化している entry は「無い」ではなく
    // 読取不能。次候補へ流さず invalid_metadata で失敗させる。
    {
        var staging = try store.openStaging("cached-broken");
        try staging.createDirPath(io, "tree/nako.toml");
        staging.close(io);
        try store.publishStaging("cached-broken");
        try testing.expectError(error.InvalidMetadata, cachedManifest(&ctx, "cached-broken"));
    }
}

test "artifactKey は宣言 hash を key 材料へ含める" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const allocator = arena_impl.allocator();
    const url = "https://example.test/pkg.tar.gz";
    // sha256 は digest 自体が key になるため表記が違っても同一 key。
    const a = try artifactKey(allocator, "http", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", url);
    const b = try artifactKey(allocator, "http", "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", url);
    try testing.expectEqualStrings(a, b);
    // sha256 以外の表記でも宣言 hash が key 材料へ入る。同じ URL で lock の
    // hash が更新されれば必ず別 entry になり、古い内容を復元しない。
    const c = try artifactKey(allocator, "http", "sha512:aaaa", url);
    const d = try artifactKey(allocator, "http", "sha512:bbbb", url);
    try testing.expect(!std.mem.eql(u8, c, d));
    try testing.expect(!std.mem.eql(u8, a, c));
    // 同じ hash 宣言でも取得元が違えば別 entry。
    const e = try artifactKey(allocator, "http", "sha512:aaaa", "https://other.test/pkg.tar.gz");
    try testing.expect(!std.mem.eql(u8, c, e));
}

test "materialize target は lock input の compatJs・optimize・engine version を引き継ぐ" {
    // 解決時に --compat-js/-O/engine version で選択した artifact を、
    // materialize 側の検証が別条件で reject しないよう、lock の
    // input.target/input.* に記録済みの実効値を再現する。
    var input = lock_model.Input{
        .manifest_sha256 = "sha256:aa",
        .profile = "default",
        .target = .{ .os = "macos", .cpu = "aarch64", .abi = "gnu", .compat_js = true, .optimize = "O3", .os_version = "15" },
        .nako_version = "3.7.24",
        .cnako_version = "3.7.24",
        .lnako_version = "0.2.2",
    };
    // 入力 profile では profile 宣言に compat-js/optimize がなくても
    // input.target の実効値を使い、解決した ESM artifact を保持する。
    const record = lock_model.ProfileRecord{
        .runtime = "lnako",
        .os = "macos",
        .cpu = "aarch64",
        .abi = "gnu",
    };
    const target = materializeTarget("default", &record, &input, .lnako);
    try testing.expect(target.compat_js);
    try testing.expectEqualStrings("O3", target.optimize);
    try testing.expectEqualStrings("15", target.os_version.?);
    try testing.expectEqual(@as(u64, 3), target.nako_version.?.major);
    try testing.expectEqual(@as(u64, 7), target.nako_version.?.minor);
    try testing.expectEqual(@as(u64, 24), target.nako_version.?.patch);
    try testing.expectEqual(@as(u64, 0), target.lnako_version.?.major);
    try testing.expectEqual(@as(u64, 2), target.lnako_version.?.minor);
    try testing.expectEqual(@as(u64, 2), target.lnako_version.?.patch);
    try testing.expect(target.cnako_version != null);

    // 別 profile を --profile で指定した場合はその record の optimize
    // 宣言を使う（CLI の -O は入力 profile にのみ適用される）。
    const other = lock_model.ProfileRecord{
        .os = "linux",
        .cpu = "x86_64",
        .abi = "gnu",
        .optimize = "O1",
    };
    const other_target = materializeTarget("release", &other, &input, .lnako);
    try testing.expectEqualStrings("O1", other_target.optimize);
    try testing.expect(!other_target.compat_js); // input の --compat-js は別 profile に漏らさない
    try testing.expectEqualStrings("linux", other_target.os);

    const other_declared_compat = lock_model.ProfileRecord{
        .os = "linux",
        .cpu = "x86_64",
        .abi = "gnu",
        .compat_js = true,
    };
    const other_declared_target = materializeTarget("release", &other_declared_compat, &input, .lnako);
    try testing.expect(other_declared_target.compat_js); // record 宣言は維持する

    // version を記録しない旧 lock は null（未検査）のまま。
    var legacy = lock_model.Input{
        .manifest_sha256 = "sha256:aa",
        .profile = "default",
        .target = .{ .os = "macos", .cpu = "aarch64", .abi = "gnu" },
    };
    const legacy_target = materializeTarget("default", &record, &legacy, .lnako);
    try testing.expect(!legacy_target.compat_js);
    try testing.expectEqualStrings("O0", legacy_target.optimize);
    try testing.expect(legacy_target.nako_version == null);
    try testing.expect(legacy_target.os_version == null);
}
