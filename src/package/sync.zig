//! `nako.lock` 駆動の環境同期。lock の package 集合を provider 経由で取得・
//! 検証し、内容アドレス cache へ公開してから `.nako/` 環境を構築する。
//!
//! - `.nako/sync.lock` と `<cache>/cache.lock` の OS lock で並行 sync を直列化
//!   する。どちらも process 終了で自動解放される。
//! - package 内容は staging で検証・展開を完了してから cache `objects/` へ
//!   原子的に公開する。環境は `.nako/staging/<gen>` に構築し、世代 dir への
//!   rename と `environment.json` の原子書換で一度に切り替える。
//! - 失敗時は `environment.json`・`current`・前世代が一切変わらず、直前の
//!   有効環境がそのまま使える。
//! - `path` 依存は mutable source として宣言 dir をそのまま参照する
//!   （環境側へ複製しない）。cache・他プロジェクトへの波及は copy 経由の
//!   immutable entry 側で防ぐ。

const std = @import("std");
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
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = enum {
    lnako,
    cnako,

    pub fn name(self: Runtime) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    /// `nako.lock` と `nako.toml` を持つプロジェクトルート。
    project_root: []const u8 = ".",
    /// 構築対象の lock profile。null なら `lock.input.profile`。
    profile: ?[]const u8 = null,
    /// `environment.json` の `runtime` に記録する処理系。
    runtime: Runtime = .lnako,
    /// cache ルートの明示指定。null なら OS 標準 cache dir
    /// （環境変数が取れない場合は `<project>/.nako/cache` へ退避する）。
    cache_root: ?[]const u8 = null,
    /// 取得 policy（offline・上限・timeout・平文 http 許可）。
    policy: fetch.Policy = .{},
};

/// `environment.json` まで含む同期結果。全メモリは内蔵 arena が所有する。
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    /// 公開された世代名（`gen-<hex>`）。
    generation: []const u8,
    /// `.nako` の絶対 path。
    environment_root: []const u8,
    /// `environment.json` と同じ決定的バイト列。`--json` 出力に使う。
    environment_json: []const u8,
    /// 今回の sync が参照した cache object key。`clean` の keep list に使う。
    used_keys: []const []const u8 = &.{},
    package_count: usize,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
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
fn mapFs(err: anyerror) Error {
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

const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    session: *fetch.Session,
    cache_store: *const cache.Store,
    project_abs: []const u8,
    /// `<.nako>/staging/<gen>`。
    generation_abs: []const u8,
    /// `<gen>/deps`（materialize 先）。
    deps_abs: []const u8,
    /// `.nako/env/<gen>`（env.json の path に使う前置）。
    generation_rel: []const u8,
    runtime: Runtime,
    target: resolver.Target,
    used_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    used_names: std.StringHashMapUnmanaged(void) = .empty,

    fn objectTree(self: *const Context, key: []const u8) !?[]const u8 {
        const entry = (try self.cache_store.entryPath(self.arena, key)) orelse return null;
        return try std.fs.path.join(self.arena, &.{ entry, "tree" });
    }
};

/// `nako.lock` を読み、環境を同期する。失敗時は `session` 由来の診断を
/// `diagnostics` へ転写してから error を返す（直前の環境は変更されない）。
pub fn run(
    gpa: Allocator,
    io: std.Io,
    options: Options,
    diagnostics: *diag.List,
) Error!Report {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // --- lock の読み込みと profile 選択 ------------------------------------
    const project_abs: []const u8 = if (std.fs.path.isAbsolute(options.project_root))
        try arena.dupe(u8, options.project_root)
    else
        std.Io.Dir.cwd().realPathFileAlloc(io, options.project_root, arena) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.LockNotFound,
            else => return mapFs(err),
        };
    const lock_path = try std.fs.path.join(arena, &.{ project_abs, "nako.lock" });
    const lock_bytes = std.Io.Dir.cwd().readFileAlloc(io, lock_path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.LockNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.LockNotFound,
    };
    var lock_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &lock_digest, .{});
    const lock_sha256 = try std.fmt.allocPrint(arena, "sha256:{s}", .{std.fmt.bytesToHex(lock_digest, .lower)});

    var lock = lock_mod.parse(arena, lock_bytes, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LockInvalid,
    };
    lock_mod.validate(&lock, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (diagnostics.errorCount() > 0) return error.LockInvalid;

    // `nako.toml` が存在する場合、lock が記録した manifest hash と一致する
    // ことを確認する。古い lock で環境を構築して環境参照が manifest と
    // 不整合になるのを防ぐ。manifest が無い lock 駆動の用途（fixture 等）
    // では検査を省略する。
    const manifest_path = try std.fs.path.join(arena, &.{ project_abs, "nako.toml" });
    if (std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    }) |manifest_bytes| {
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &actual, .{});
        var expected: [32]u8 = undefined;
        if (!lock_model.normalizeSha256(lock.input.manifest_sha256, &expected) or
            !std.mem.eql(u8, &actual, &expected))
        {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "lock input manifestSha256 does not match nako.toml; re-resolve the lock before sync", .{});
            return error.StaleLock;
        }
    }

    const profile = options.profile orelse lock.input.profile;
    const entries = lock.packagesForProfile(profile) orelse {
        try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, profile, .{}, "lock has no package graph for profile \"{s}\"", .{profile});
        return error.UnknownProfile;
    };
    const record = lock.profileRecord(profile);
    if (record) |r| {
        // profile が別 runtime を明示している環境を要求 runtime で構築すると
        // cnako が lnako 環境を誤読する。`any`/`common` は両対応として許容。
        if (r.runtime) |declared| {
            const compatible = std.mem.eql(u8, declared, options.runtime.name()) or
                std.mem.eql(u8, declared, "any") or std.mem.eql(u8, declared, "common");
            if (!compatible) {
                try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, profile, .{}, "profile \"{s}\" targets runtime \"{s}\", not \"{s}\"", .{ profile, declared, options.runtime.name() });
                return error.InvalidProfile;
            }
        }
    }

    // --- 排他 --------------------------------------------------------------
    var env_store = environment.Store.open(gpa, io, project_abs) catch |err| return mapFs(err);
    defer env_store.deinit();
    var env_lock = env_store.lockWait() catch |err| return mapFs(err);
    defer env_lock.unlock();
    env_store.recoverStaging() catch |err| return mapFs(err);

    const cache_root = blk: {
        if (options.cache_root) |root| break :blk try arena.dupe(u8, root);
        if (try cache.defaultRoot(arena)) |root| break :blk root;
        // 環境変数から OS cache dir を決められない実行環境では project 内へ。
        break :blk try std.fs.path.join(arena, &.{ env_store.root, "cache" });
    };
    var cache_store = cache.Store.open(gpa, io, cache_root) catch |err| return mapFs(err);
    defer cache_store.deinit();
    var cache_lock = cache_store.lockWait() catch |err| return mapFs(err);
    defer cache_lock.unlock();
    cache_store.pruneIncomplete() catch |err| return mapFs(err);

    // --- 取得 session ------------------------------------------------------
    var session = fetch.Session.init(gpa, io, options.policy);
    defer session.deinit();
    session.diagnostics = diagnostics;

    // 直前の現行世代を覚えておく。切替え直後に直前世代を削除すると、
    // 読み取り途中の consumer を壊すため新・旧の双方を残す。
    const previous_generation = env_store.readCurrent(arena) catch |err| return mapFs(err);
    const generation = env_store.newGeneration(arena) catch |err| return mapFs(err);
    const deps_abs = try std.fs.path.join(arena, &.{ generation.abs_path, "deps" });
    std.Io.Dir.cwd().createDirPath(io, deps_abs) catch |err| return mapFs(err);
    const generation_rel = try std.fs.path.join(arena, &.{ environment.dir_name, environment.env_dir, generation.generation });

    var ctx = Context{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .session = &session,
        .cache_store = &cache_store,
        .project_abs = project_abs,
        .generation_abs = generation.abs_path,
        .deps_abs = deps_abs,
        .generation_rel = generation_rel,
        .runtime = options.runtime,
        .target = .{
            .runtime = options.runtime.name(),
            .os = if (record) |r| r.os else lock.input.target.os,
            .cpu = if (record) |r| r.cpu else lock.input.target.cpu,
            .abi = if (record) |r| r.abi else lock.input.target.abi,
            .compat_js = if (record) |r| r.compat_js orelse false else false,
            .optimize = if (record) |r| r.optimize orelse "O0" else "O0",
        },
    };

    // --- package の取得・検証・materialize ---------------------------------
    var records = std.ArrayListUnmanaged(environment.PackageRecord).empty;
    for (entries) |*entry| {
        const record_value = preparePackage(&ctx, entry) catch |err| {
            // provider 由来の失敗は session.failures に分類付きで記録済み。
            session.reportDiagnostics(diagnostics) catch {};
            return err;
        };
        try records.append(arena, record_value);
    }

    // --- 環境の公開 ---------------------------------------------------------
    var json_buffer: std.Io.Writer.Allocating = .init(arena);
    environment.emit(arena, .{
        .lock_sha256 = lock_sha256,
        .profile = profile,
        .runtime = options.runtime.name(),
        .packages = records.items,
    }, &json_buffer.writer) catch |err| switch (err) {
        // Allocating writer の WriteFailed は arena 確保の失敗。
        error.WriteFailed => return error.OutOfMemory,
        else => return mapFs(err),
    };

    // staging 世代 dir を env/ へ rename し、environment.json・current を
    // 原子的に切り替える。ここまで来る前に失敗した場合、既存環境は無変更。
    env_store.commit(generation.generation, json_buffer.written()) catch |err| return mapFs(err);
    env_store.writeCurrent(generation.generation) catch |err| return mapFs(err);

    // 前世代は使用中の可能性があるため、現行と直前世代の双方を残して整理する。
    var keep = std.ArrayListUnmanaged([]const u8).empty;
    try keep.append(arena, generation.generation);
    if (previous_generation) |previous| {
        if (!std.mem.eql(u8, previous, generation.generation)) {
            try keep.append(arena, previous);
        }
    }
    _ = env_store.pruneGenerations(keep.items) catch {};

    return .{
        .arena = arena_impl,
        .generation = generation.generation,
        // env_store.deinit で解放されるため arena へ複製する。
        .environment_root = try arena.dupe(u8, env_store.root),
        .environment_json = json_buffer.written(),
        .used_keys = ctx.used_keys.items,
        .package_count = records.items.len,
    };
}

// ---------------------------------------------------------------------------
// package 取得
// ---------------------------------------------------------------------------

fn preparePackage(ctx: *Context, entry: *const lock_model.PackageEntry) Error!environment.PackageRecord {
    const arena = ctx.arena;
    const source = entry.source orelse entry.resolved_from orelse {
        return ctx.session.fail(.invalid_source, .package, entry.name, "package \"{s}\" has no source in the lock", .{entry.name});
    };

    var env_path: []const u8 = undefined;
    var manifest: ?manifest_mod.Manifest = null;
    var tree_abs: ?[]const u8 = null;

    switch (source.kind) {
        .path => {
            const rel = source.path orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "path source of \"{s}\" has no path", .{entry.name});
            const acquired = try provider.acquirePath(ctx.session, .{
                .name = entry.name,
                .path = rel,
                .mutable = source.mutable orelse false,
            }, ctx.project_abs);
            manifest = acquired.manifest;
            // mutable source は宣言 dir を生参照する。環境側へ複製すると
            // 編集が反映されず mutable の契約を壊す。
            env_path = try arena.dupe(u8, rel);
        },
        .git => {
            const url = source.url orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "git source of \"{s}\" has no url", .{entry.name});
            const commit = source.commit orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "git source of \"{s}\" has no commit", .{entry.name});
            // checkout は可変の作業 dir。repo+subdir 単位で再利用する。
            const checkout_key = try shortKey(arena, "git", &.{ url, source.path orelse "" });
            const checkout_dir = (try ctx.cache_store.checkoutPath(arena, checkout_key)) orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "cannot derive checkout dir", .{});
            const acquired = try provider.acquireGit(ctx.session, .{
                .name = entry.name,
                .url = url,
                .commit = commit,
                .path = source.path,
            }, checkout_dir, source);
            manifest = acquired.manifest;
            const resolved_commit = acquired.source.commit orelse commit;

            const object_key = try shortKey(arena, "git", &.{ url, resolved_commit, source.path orelse "" });
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            if (!ctx.cache_store.entryExists(object_key)) {
                try buildGitObject(ctx, object_key, checkout_dir, source.path);
            }
            tree_abs = tree;
            const dest = try materializeIntoGeneration(ctx, entry.name, tree);
            env_path = dest;
        },
        .http => {
            const url = source.url orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "http source of \"{s}\" has no url", .{entry.name});
            const declared_hash = source.hash orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "http source of \"{s}\" has no hash", .{entry.name});
            const object_key = try artifactKey(ctx, "http", declared_hash, url);
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            if (!ctx.cache_store.entryExists(object_key)) {
                const acquired = try provider.acquireHttp(ctx.session, .{
                    .name = entry.name,
                    .url = url,
                    .hash = declared_hash,
                });
                manifest = acquired.manifest;
                try buildArtifactObject(ctx, object_key, acquired.artifact_bytes.?, acquired.artifact_type orelse "raw");
            } else {
                // cache 命中時も manifest が必要なら artifact を読み直す。
                manifest = try cachedManifest(ctx, object_key);
            }
            tree_abs = tree;
            const dest = try materializeIntoGeneration(ctx, entry.name, tree);
            env_path = dest;
        },
        .registry, .static => {
            const base = source.url orelse
                return ctx.session.fail(.invalid_source, .package, entry.name, "registry source of \"{s}\" has no url", .{entry.name});
            const artifact = selectArtifact(ctx, entry) orelse
                return ctx.session.fail(.not_found, .artifact, entry.name, "package \"{s}\" has no artifact for runtime \"{s}\"", .{ entry.name, ctx.runtime.name() });
            const object_key = try artifactKey(ctx, "artifact", artifact.sha256 orelse artifact.key, artifact.url orelse artifact.key);
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            if (!ctx.cache_store.entryExists(object_key)) {
                var reg = try registry.StaticRegistry.init(ctx.session, base, ctx.target);
                defer reg.deinit();
                const acquired = try reg.acquireArtifact(entry.name, entry.version, artifact.key);
                try buildArtifactObject(ctx, object_key, acquired.bytes, acquired.type orelse "raw");
            }
            manifest = try cachedManifest(ctx, object_key);
            tree_abs = tree;
            const dest = try materializeIntoGeneration(ctx, entry.name, tree);
            env_path = dest;
        },
    }

    // exports・commands は manifest がある場合だけ記録する。
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    var commands: []const npkg_commands.Command = &.{};
    if (manifest) |*m| {
        exports = try resolveExports(ctx, m);
        commands = try collectCommands(ctx, tree_abs, m);
    } else if (tree_abs) |tree| {
        commands = try collectCommands(ctx, tree, null);
    }

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

fn isPackageId(id: []const u8) bool {
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

/// hash 宣言から内容アドレス key を作る。sha256 に正規化できる場合は実ダイ
/// ジェストを key に使い、そうでなければ識別文字列の hash へ退避する。
fn artifactKey(ctx: *Context, prefix: []const u8, declared_hash: []const u8, identity: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    if (lock_model.normalizeSha256(declared_hash, &digest)) {
        const hex = std.fmt.bytesToHex(digest, .lower);
        return try std.fmt.allocPrint(ctx.arena, "{s}-{s}", .{ prefix, hex[0..32] });
    }
    return try shortKey(ctx.arena, prefix, &.{identity});
}

fn rememberKey(ctx: *Context, key: []const u8) !void {
    for (ctx.used_keys.items) |item| {
        if (std.mem.eql(u8, item, key)) return;
    }
    try ctx.used_keys.append(ctx.arena, key);
}

/// git checkout から cache object を構築する。`.git` を除いた作業木を
/// staging へ検証付きで複製し、原子的に公開する。
fn buildGitObject(ctx: *Context, key: []const u8, checkout_dir: []const u8, sub_path: ?[]const u8) Error!void {
    const arena = ctx.arena;
    const src = if (sub_path) |sub|
        try std.fs.path.join(arena, &.{ checkout_dir, sub })
    else
        try arena.dupe(u8, checkout_dir);
    const staging = try std.fs.path.join(arena, &.{ ctx.cache_store.root, cache.staging_dir, key });
    const staging_tree = try std.fs.path.join(arena, &.{ staging, "tree" });
    _ = materialize.copyTree(ctx.gpa, ctx.io, src, staging_tree, .{
        .exclude_names = &.{".git"},
    }) catch |err| return mapTreeError(ctx, err, key);
    ctx.cache_store.publish(key, staging) catch |err| return mapFs(err);
}

/// 取得 bytes から cache object を構築する。`.npkg`（zip）は展開して
/// `tree/` へ、raw は `tree/blob` として保存する。
fn buildArtifactObject(ctx: *Context, key: []const u8, bytes: []const u8, artifact_type: []const u8) Error!void {
    const arena = ctx.arena;
    const staging = try std.fs.path.join(arena, &.{ ctx.cache_store.root, cache.staging_dir, key });
    const tree = try std.fs.path.join(arena, &.{ staging, "tree" });
    std.Io.Dir.cwd().createDirPath(ctx.io, tree) catch |err| return mapFs(err);
    if (std.mem.eql(u8, artifact_type, ".npkg")) {
        // 一時アーカイブは公開対象の staging dir 外（兄弟 path）へ置く。
        // 残った場合も staging 配下なので次回の回収で消える。
        const archive_path = try std.fmt.allocPrint(arena, "{s}.archive", .{staging});
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = archive_path, .data = bytes }) catch |err| return mapFs(err);
        defer std.Io.Dir.cwd().deleteFile(ctx.io, archive_path) catch {};
        zip.extract(ctx.io, archive_path, tree) catch |err| {
            return ctx.session.fail(.invalid_metadata, .artifact, key, "artifact archive failed boundary-checked extraction: {s}", .{@errorName(err)});
        };
    } else {
        const blob = try std.fs.path.join(arena, &.{ tree, "blob" });
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = blob, .data = bytes }) catch |err| return mapFs(err);
    }
    ctx.cache_store.publish(key, staging) catch |err| return mapFs(err);
}

/// cache object 内の manifest を読み直す。`tree/nako.toml` または
/// `tree/NAKO-PKG/METADATA.toml` を探す。無ければ null。
fn cachedManifest(ctx: *Context, key: []const u8) Error!?manifest_mod.Manifest {
    const arena = ctx.arena;
    const tree = (try ctx.objectTree(key)).?;
    const candidates = [_][]const u8{ "nako.toml", "NAKO-PKG/METADATA.toml" };
    for (candidates) |rel| {
        const path = try std.fs.path.join(arena, &.{ tree, rel });
        const limit: std.Io.Limit = if (ctx.session.policy.max_bytes == 0) .unlimited else .limited(ctx.session.policy.max_bytes);
        const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, arena, limit) catch continue;
        var scratch = diag.List.init(ctx.gpa);
        defer scratch.deinit();
        return manifest_mod.parse(arena, bytes, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.session.fail(.invalid_metadata, .manifest, path, "cached manifest at \"{s}\" is invalid", .{path}),
        };
    }
    return null;
}

/// registry artifact の選択。source を最優先、次に native、ESM は profile が
/// 許可する場合のみ。
fn selectArtifact(ctx: *Context, entry: *const lock_model.PackageEntry) ?*const lock_model.Artifact {
    if (entry.artifact("source")) |artifact| return artifact;
    if (entry.artifact("native")) |artifact| return artifact;
    if (std.mem.eql(u8, ctx.runtime.name(), "cnako") or ctx.target.compat_js) {
        if (entry.artifact("ESM")) |artifact| return artifact;
    }
    return null;
}

/// package 名を `.nako` 内 dir 名へ変換する。`[a-z0-9-]` 以外は `-` へ畳み、
/// 空なら hash 名を使う。同一世代内での重複には `-2`・`-3`…を付ける。
fn materializeIntoGeneration(ctx: *Context, package_name: []const u8, tree_abs: []const u8) Error![]const u8 {
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

    const dest = try std.fs.path.join(arena, &.{ ctx.deps_abs, final_name });
    _ = materialize.copyTree(ctx.gpa, ctx.io, tree_abs, dest, .{}) catch |err| return mapTreeError(ctx, err, package_name);
    return try std.fs.path.join(arena, &.{ ctx.generation_rel, "deps", final_name });
}

/// manifest の exports を対象条件で解決し、env.json の `exports` 配列へ
/// 変換する。ESM は profile が許可する場合のみ含める。
fn resolveExports(ctx: *Context, manifest: *const manifest_mod.Manifest) Error!std.ArrayListUnmanaged(environment.ExportRecord) {
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    const prefer_native = std.mem.eql(u8, ctx.runtime.name(), "lnako");
    const target = manifest_mod.ArtifactTarget{
        .runtime = ctx.runtime.name(),
        .os = ctx.target.os,
        .cpu = ctx.target.cpu,
        .abi = ctx.target.abi,
        .compat_js = ctx.target.compat_js,
        .optimize = ctx.target.optimize,
    };
    for (manifest.exports) |*export_decl| {
        const resolution = export_decl.resolve(ctx.arena, target, prefer_native, ctx.session.diagnostics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        } orelse continue;
        if (resolution.kind == .esm and !(std.mem.eql(u8, ctx.runtime.name(), "cnako") or ctx.target.compat_js)) continue;
        try exports.append(ctx.arena, .{
            .name = try ctx.arena.dupe(u8, export_decl.name),
            .path = try ctx.arena.dupe(u8, resolution.target),
        });
    }
    return exports;
}

/// commands.json を package dir から読むか、manifest export の source を
/// 静的走査して生成する。どちらも無い場合は空。
fn collectCommands(ctx: *Context, tree_abs: ?[]const u8, manifest: ?*const manifest_mod.Manifest) Error![]const npkg_commands.Command {
    const arena = ctx.arena;
    if (tree_abs) |tree| {
        const commands_path = try std.fs.path.join(arena, &.{ tree, "NAKO-PKG/commands.json" });
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, commands_path, arena, .limited(16 * 1024 * 1024))) |bytes| {
            var scratch = diag.List.init(ctx.gpa);
            defer scratch.deinit();
            const parsed = npkg_commands.parse(arena, bytes, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ctx.session.fail(.invalid_metadata, .manifest, commands_path, "commands.json in package failed validation", .{}),
            };
            return parsed.commands;
        } else |_| {}
    }
    const m = manifest orelse return &.{};
    if (tree_abs == null) return &.{};

    // export の source path を entry として静的に走査する。
    var entry_paths = std.ArrayListUnmanaged([]const u8).empty;
    for (m.exports) |*export_decl| {
        if (export_decl.path) |path| try entry_paths.append(arena, path);
    }
    if (entry_paths.items.len == 0) return &.{};

    var provider_state = DirSourceProvider{ .io = ctx.io, .root = try arena.dupe(u8, tree_abs.?) };
    var scratch = diag.List.init(ctx.gpa);
    defer scratch.deinit();
    const generated = npkg_commands_gen.generate(arena, provider_state.provider(), entry_paths.items, ctx.session.diagSink(&scratch)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.session.fail(.invalid_metadata, .manifest, m.package.name, "failed to derive commands for package \"{s}\"", .{m.package.name}),
    };
    return generated.commands;
}

/// package dir からファイルを読む `npkg_commands_gen.SourceProvider`。
const DirSourceProvider = struct {
    io: std.Io,
    root: []const u8,

    fn provider(self: *DirSourceProvider) npkg_commands_gen.SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *DirSourceProvider = @ptrCast(@alignCast(context));
        const abs = try std.fs.path.join(allocator, &.{ self.root, path });
        defer allocator.free(abs);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return bytes;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sha256HexAlloc(allocator: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, &hex);
}

const app_manifest =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\license = "MIT"
    \\
;

const lib_manifest =
    \\[package]
    \\name = "lib"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[[exports]]
    \\name = "lib"
    \\path = "src/index.nako3"
    \\
;

/// path 依存1件を持つ最小プロジェクトを作る。戻り値は lock 本文。
fn fixtureLock(allocator: Allocator, manifest_sha: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}
        \\  }},
        \\  "packages": {{
        \\    "pkg:11111111111111111111111111111111": {{
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{manifest_sha});
}

fn writeFixtureProject(temporary: *std.testing.TmpDir, manifest_sha: []const u8) !void {
    const io = testing.io;
    try temporary.dir.createDirPath(io, "deps/lib/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "テストとは\n  戻る\nここまで\n",
    });
    const lock = try fixtureLock(testing.allocator, manifest_sha);
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
}

test "sync は path 依存を参照して schema v1 の環境を構築する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);

    // environment.json を parse して契約フィールドを確認する。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const document = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), document.get("schemaVersion").?.integer);
    try testing.expectEqualStrings("default", document.get("profile").?.string);
    try testing.expectEqualStrings("lnako", document.get("runtime").?.string);
    const lib = document.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    // path 依存は宣言 dir をそのまま参照する。
    try testing.expectEqualStrings("deps/lib", lib.get("path").?.string);

    // lockSha256 は nako.lock 実バイトの SHA-256 と一致する。
    const lock_bytes = try temporary.dir.readFileAlloc(io, "nako.lock", testing.allocator, .unlimited);
    defer testing.allocator.free(lock_bytes);
    const lock_hex = try sha256HexAlloc(testing.allocator, lock_bytes);
    defer testing.allocator.free(lock_hex);
    const expected = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{lock_hex});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, document.get("lockSha256").?.string);

    // `.nako/environment.json` が書かれ、`current` が世代を指す。
    const written = try temporary.dir.readFileAlloc(io, ".nako/environment.json", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(report.environment_json, written);
}

test "sync は manifest との不整合な lock を StaleLock で拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeFixtureProject(&temporary, "0000000000000000000000000000000000000000000000000000000000000000");
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.StaleLock, run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    // 環境は一切構築されない。
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は失敗時に直前の有効環境を保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer first.deinit();
    const first_json = try testing.allocator.dupe(u8, first.environment_json);
    defer testing.allocator.free(first_json);

    // 未知の profile を要求して失敗させる。
    try testing.expectError(error.UnknownProfile, run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
        .profile = "nonexistent",
    }, &list));

    // 直前の environment.json がそのまま残る。
    const written = try temporary.dir.readFileAlloc(io, ".nako/environment.json", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(first_json, written);
}

test "sync は offline で http 依存の未取得を拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    const lock = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}
        \\  }},
        \\  "packages": {{
        \\    "pkg:22222222222222222222222222222222": {{
        \\      "id": "pkg:22222222222222222222222222222222",
        \\      "name": "remote",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "http", "url": "http://127.0.0.1:1/pkg.npkg", "hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": ".npkg", "sha256": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "url": "http://127.0.0.1:1/pkg.npkg" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{manifest_sha});
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.Offline, run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
        .policy = .{ .offline = true },
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は再実行で世代を更新し直前世代を保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    const first_gen = try testing.allocator.dupe(u8, first.generation);
    defer testing.allocator.free(first_gen);
    first.deinit();

    var second = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // 直前世代 dir が残っている。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
}
