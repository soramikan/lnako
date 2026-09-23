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
const npkg_verify = @import("npkg_verify.zig");
const provider = @import("provider.zig");
const resolver = @import("resolver.zig");
const unpack = @import("unpack.zig");

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

/// lock entry の `mutable = false` path source に記録された pin hash。
fn pinnedSourceHash(entry: *const lock_model.PackageEntry) ?[]const u8 {
    for (entry.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.key, "source") and artifact.sha256 != null) return artifact.sha256.?;
    }
    return null;
}

/// lock `input.mutablePaths` に記録された mutable path 依存の内容
/// digest を tree 再計算で照合する。不一致（内容変更・dir 欠落）が
/// あれば最初の記録 path を返す。`mutable = true` は宣言 dir を生参照
/// する契約のため、manifest が同じでも dir 内容が変われば lock・環境を
/// 再生成する必要がある。
pub fn mutablePathMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) Error!?[]const u8 {
    return mutablePathsMismatch(gpa, io, project_root, lock.input.mutable_paths);
}

/// `mutablePathMismatch` の記録配列版。`environment.json` に記録された
/// digest など lock 以外の出典にも使う。
pub fn mutablePathsMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, recorded: []const lock_model.MutablePath) Error!?[]const u8 {
    for (recorded) |mutable| {
        const abs = if (provider.isAbsoluteDepPath(mutable.path))
            mutable.path
        else
            try std.fs.path.join(gpa, &.{ project_root, mutable.path });
        const digest = cache.digestTree(io, gpa, abs, &cache.source_pin_exclude) catch return mutable.path;
        const actual = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
        if (!std.mem.eql(u8, actual, mutable.sha256)) return mutable.path;
    }
    return null;
}

/// lock 内 `mutable = false` path 依存の pin hash を tree 再計算で照合する。
/// 不一致（内容変更・hash 未記録・tree 破損・dir 欠落）があれば最初の
/// dep 名を返す。path は `project_root` 基準で解決する。
pub fn pathPinMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) Error!?[]const u8 {
    var sets: std.ArrayList([]const lock_model.PackageEntry) = .empty;
    defer sets.deinit(gpa);
    try sets.append(gpa, lock.packages);
    for (lock.profile_packages) |profile| try sets.append(gpa, profile.packages);
    // profile 間で同じ entry が重複しても照合結果は同じため dedupe しない。
    for (sets.items) |set| {
        for (set) |*entry| {
            const source = entry.source orelse continue;
            if (source.kind != .path or (source.mutable orelse false)) continue;
            const rel = source.path orelse return entry.name;
            const recorded = pinnedSourceHash(entry) orelse return entry.name;
            const abs = if (provider.isAbsoluteDepPath(rel))
                rel
            else
                try std.fs.path.join(gpa, &.{ project_root, rel });
            const digest = cache.digestTree(io, gpa, abs, &cache.source_pin_exclude) catch return entry.name;
            const actual = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
            if (!std.mem.eql(u8, actual, recorded)) return entry.name;
        }
    }
    return null;
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

    // `mutable = false` の path pin も照合する。pin 不一致の lock で環境を
    // 構築すると lock が pin した内容と異なる tree を参照するため stale
    // として拒否する（`lnako lock` で再解決してから sync する）。
    if (try pathPinMismatch(arena, io, project_abs, &lock)) |name| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of pinned path dependency \"{s}\" does not match nako.lock; re-resolve the lock before sync", .{name});
        return error.StaleLock;
    }
    // `mutable = true` の path 依存も内容 digest で照合する。宣言 dir の
    // 内容が lock 記録時と変わっていれば、記録時のグラフを前提にした環境
    // は構築しない。
    if (try mutablePathMismatch(arena, io, project_abs, &lock)) |path| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of mutable path dependency \"{s}\" does not match nako.lock; re-resolve the lock before sync", .{path});
        return error.StaleLock;
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
        // mutable path 依存の metadata（exports/commands）は環境へ
        // snapshot するため、宣言 dir の digest を記録して再解決を要さない
        // metadata-only 変更でも環境の陳腐化を検出できるようにする。
        .mutable_paths = lock.input.mutable_paths,
    }, &json_buffer.writer) catch |err| switch (err) {
        // Allocating writer の WriteFailed は arena 確保の失敗。
        error.WriteFailed => return error.OutOfMemory,
        else => return mapFs(err),
    };

    // 直前の公開環境が参照する世代を environment.json からも復元する。
    // env.json 公開後・current 更新前の中断では current が古い世代を
    // 指したまま残るため、両者を keep して実際の直前世代を消さない。
    const published_generation = env_store.readPublishedGeneration(arena) catch null;

    // staging 世代 dir を env/ へ rename し、environment.json・current を
    // 原子的に切り替える。ここまで来る前に失敗した場合、既存環境は無変更。
    env_store.commit(generation.generation, json_buffer.written()) catch |err| return mapFs(err);
    // environment.json 公開後に current の更新だけ失敗しても、公開済み環境を
    // 巻き戻せない。current は世代整理と次回 sync のヒントに過ぎず、実際の
    // 参照世代は environment.json から復元する（中断時と同じ状態）ため、
    // ここでの失敗は成功扱いとする。
    env_store.writeCurrent(generation.generation) catch {};

    // 前世代は使用中の可能性があるため、現行・直前・公開環境の参照世代を
    // 残して整理する。参照世代を特定できない場合（env.json 破損等）は
    // 使用中の世代を誤削除しないよう整理自体を見送る。
    var keep = std.ArrayListUnmanaged([]const u8).empty;
    try keep.append(arena, generation.generation);
    if (previous_generation) |previous| {
        if (!std.mem.eql(u8, previous, generation.generation)) {
            try keep.append(arena, previous);
        }
    }
    var can_prune = previous_generation != null;
    if (published_generation) |published| {
        can_prune = true;
        if (!std.mem.eql(u8, published, generation.generation)) {
            try keep.append(arena, published);
        }
    } else if ((env_store.readEnvironmentJson(arena) catch null) == null) {
        // environment.json が無ければ公開環境の consumer はいない。
        can_prune = true;
    }
    if (can_prune) {
        _ = env_store.pruneGenerations(keep.items) catch {};
    }

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
    var verified_commands: ?[]const npkg_commands.Command = null;

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
            const acquired = try provider.acquirePath(ctx.session, .{
                .name = entry.name,
                .path = rel,
                .mutable = source.mutable orelse false,
            }, ctx.project_abs);
            manifest = acquired.manifest;
            // mutable source は宣言 dir を生参照する。環境側へ複製すると
            // 編集が反映されず mutable の契約を壊す。
            env_path = try arena.dupe(u8, rel);
            // commands 走査用には絶対 path を使う（env.json には宣言 path）。
            tree_abs = if (provider.isAbsoluteDepPath(rel))
                try arena.dupe(u8, rel)
            else
                try std.fs.path.join(arena, &.{ ctx.project_abs, rel });
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
            // lock の固定 commit から決定的な object key を先に計算する。
            // 検証済み object があれば checkout・Git 起動・clone/fetch を
            // 経由せず materialize できる（offline でも checkout 不要）。
            const object_key = try shortKey(arena, "git", &.{ url, commit, source.path orelse "" });
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            const verified_hit = (ctx.cache_store.verifyEntry(arena, object_key) catch false) and ctx.cache_store.entryExists(object_key);
            if (!verified_hit) {
                // digest 不一致（改変）または不完全な entry は除去して再構築。
                if (ctx.cache_store.entryExists(object_key)) {
                    ctx.cache_store.removeEntry(object_key) catch |err| return mapFs(err);
                }
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
                // 取得結果が lock の固定 commit と一致することを確認する。
                const resolved_commit = acquired.source.commit orelse commit;
                if (!std.mem.eql(u8, resolved_commit, commit)) {
                    return ctx.session.fail(.source_collision, .repository, url, "git source of \"{s}\" resolved to {s}, lock expects {s}", .{ entry.name, resolved_commit, commit });
                }
                try buildGitObject(ctx, object_key, checkout_dir, source.path);
            } else {
                manifest = if (try cachedManifest(ctx, object_key)) |cached| cached.manifest else null;
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
            const object_key = try artifactKey(arena, "http", declared_hash, url);
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            const verified_hit = (ctx.cache_store.verifyEntry(arena, object_key) catch false) and ctx.cache_store.entryExists(object_key);
            if (!verified_hit) {
                if (ctx.cache_store.entryExists(object_key)) {
                    ctx.cache_store.removeEntry(object_key) catch |err| return mapFs(err);
                }
                const acquired = try provider.acquireHttp(ctx.session, .{
                    .name = entry.name,
                    .url = url,
                    .hash = declared_hash,
                });
                manifest = acquired.manifest;
                const prepared = try buildArtifactObject(ctx, object_key, acquired.artifact_bytes.?, acquired.artifact_type orelse "raw", entry);
                applyPrepared(&manifest, &verified_commands, prepared);
            }
            // cache 命中時は object から manifest を読み直す。`.npkg` 由来なら
            // 公開時と今回の target が異なり得るため適合を再検証する（miss の
            // tar.gz/raw でも公開済み tree から manifest を拾う）。
            manifest = manifest orelse try checkedCachedManifest(ctx, object_key, entry);
            tree_abs = tree;
            const dest = try materializeIntoGeneration(ctx, entry.name, tree);
            env_path = dest;
        },
        .registry, .static => {
            // lock が記録する `source.url` は package 固有 URL であり、
            // registry ルートではない。同期時は index を引き直さず、
            // lock の artifact URL・hash・type を直接使って取得・検証する。
            const artifact = selectArtifact(ctx, entry) orelse
                return ctx.session.fail(.not_found, .artifact, entry.name, "package \"{s}\" has no artifact for runtime \"{s}\"", .{ entry.name, ctx.runtime.name() });
            const url = artifact.url orelse
                return ctx.session.fail(.invalid_source, .artifact, entry.name, "artifact \"{s}\" of \"{s}\" has no url", .{ artifact.key, entry.name });
            const object_key = try artifactKey(arena, "artifact", artifact.sha256 orelse artifact.key, url);
            try rememberKey(ctx, object_key);
            const tree = (try ctx.objectTree(object_key)).?;
            const verified_hit = (ctx.cache_store.verifyEntry(arena, object_key) catch false) and ctx.cache_store.entryExists(object_key);
            if (!verified_hit) {
                if (ctx.cache_store.entryExists(object_key)) {
                    ctx.cache_store.removeEntry(object_key) catch |err| return mapFs(err);
                }
                const bytes = try fetch.fetchBytes(ctx.session, url, .artifact);
                if (artifact.sha256) |expected| {
                    try fetch.verifyHash(ctx.session, bytes, expected, url, .artifact);
                }
                const prepared = try buildArtifactObject(ctx, object_key, bytes, artifact.type orelse "raw", entry);
                applyPrepared(&manifest, &verified_commands, prepared);
            }
            // http 経路と同じく cache 命中の `.npkg` 由来 manifest は現在
            // target への適合を再検証する。
            manifest = manifest orelse try checkedCachedManifest(ctx, object_key, entry);
            tree_abs = tree;
            const dest = try materializeIntoGeneration(ctx, entry.name, tree);
            env_path = dest;
        },
    }

    // exports・commands は manifest がある場合だけ記録する。
    // `.npkg` を verify した経路では検証済み model をそのまま使う。
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    if (manifest) |*m| {
        exports = try resolveExports(ctx, m, entry.implementation);
    }
    const commands: []const npkg_commands.Command = verified_commands orelse blk: {
        if (manifest) |*m| break :blk try collectCommands(ctx, tree_abs, m);
        if (tree_abs) |tree| break :blk try collectCommands(ctx, tree, null);
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
/// 空・末尾 separator・`.` 成分・途中の空成分・制御文字。
fn isCanonicalDepPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[path.len - 1] == '/' or path[path.len - 1] == '\\') return false;
    const starts_sep = path[0] == '/' or path[0] == '\\';
    var components = std.mem.splitAny(u8, path, "/\\");
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

/// git source の repo 内 subdir が規範的な相対 path か。repo 境界内だけを
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
    const staging = try std.fs.path.join(arena, &.{ ctx.cache_store.root, cache.staging_dir, key });
    const tree = try std.fs.path.join(arena, &.{ staging, "tree" });
    std.Io.Dir.cwd().createDirPath(ctx.io, tree) catch |err| return mapFs(err);
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
        // 一時アーカイブ・展開先は公開対象の staging dir 外（兄弟 path）へ
        // 置く。残った場合も staging 配下なので次回の回収で消える。
        const archive_path = try std.fmt.allocPrint(arena, "{s}.archive", .{staging});
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = archive_path, .data = bytes }) catch |err| return mapFs(err);
        defer std.Io.Dir.cwd().deleteFile(ctx.io, archive_path) catch {};
        const extract_dir = try std.fmt.allocPrint(arena, "{s}.extract", .{staging});
        defer std.Io.Dir.cwd().deleteTree(ctx.io, extract_dir) catch {};
        zip.extract(ctx.io, archive_path, extract_dir) catch |err| {
            return ctx.session.fail(.invalid_metadata, .artifact, key, "artifact archive failed boundary-checked extraction: {s}", .{@errorName(err)});
        };
        _ = materialize.copyTree(ctx.gpa, ctx.io, extract_dir, tree, .{}) catch |err| return mapTreeError(ctx, err, key);
    } else if (std.mem.eql(u8, artifact_type, "tar.gz") or std.mem.eql(u8, artifact_type, "npm-tarball")) {
        // npm-tarball は `package/` 前置を持つため先頭成分を除外する。
        const extract_dir = try std.fmt.allocPrint(arena, "{s}.extract", .{staging});
        defer std.Io.Dir.cwd().deleteTree(ctx.io, extract_dir) catch {};
        unpack.extractTarGz(arena, ctx.io, bytes, extract_dir, .{
            .strip_components = if (std.mem.eql(u8, artifact_type, "npm-tarball")) 1 else 0,
        }) catch |err| return mapUnpackError(ctx, err, key);
        _ = materialize.copyTree(ctx.gpa, ctx.io, extract_dir, tree, .{}) catch |err| return mapTreeError(ctx, err, key);
    } else if (std.mem.eql(u8, artifact_type, "raw")) {
        const blob = try std.fs.path.join(arena, &.{ tree, "blob" });
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = blob, .data = bytes }) catch |err| return mapFs(err);
    } else {
        // lock が受理する既知 type でも未対応のものは成功扱いにしない。
        return ctx.session.fail(.invalid_metadata, .artifact, key, "unsupported artifact type \"{s}\" for \"{s}\"", .{ artifact_type, key });
    }
    ctx.cache_store.publish(key, staging) catch |err| return mapFs(err);
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
    const tree = (try ctx.objectTree(key)).?;
    // 両方ある package では配布向け正規化済みの METADATA.toml が正本。
    const candidates = [_]struct { rel: []const u8, npkg: bool }{
        .{ .rel = "NAKO-PKG/METADATA.toml", .npkg = true },
        .{ .rel = "nako.toml", .npkg = false },
    };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(arena, &.{ tree, candidate.rel });
        const limit: std.Io.Limit = if (ctx.session.policy.max_bytes == 0) .unlimited else .limited(ctx.session.policy.max_bytes);
        const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, arena, limit) catch continue;
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

/// manifest の export を `implementation`（lock が記録した解決結果）に合わせて
/// 選択し、env.json の `exports` 配列へ変換する。`native` は prefer-native
/// として resolve へ渡し、ESM は profile が許可する場合のみ含める。`none`
/// は実装を持たないため空を返す。
fn resolveExports(ctx: *Context, manifest: *const manifest_mod.Manifest, implementation: ?[]const u8) Error!std.ArrayListUnmanaged(environment.ExportRecord) {
    var exports = std.ArrayListUnmanaged(environment.ExportRecord).empty;
    if (implementation) |impl| {
        if (std.mem.eql(u8, impl, "none")) return exports;
    }
    const prefer_native = if (implementation) |impl| std.mem.eql(u8, impl, "native") else false;
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
        // lock が記録した実装と食い違う export は含めない。`source` 選択の
        // package で native/ESM を記録すると展開物と env.json が不整合になる。
        if (implementation) |impl| {
            if (std.mem.eql(u8, impl, "source") and resolution.kind != .source) continue;
            if (std.mem.eql(u8, impl, "native") and resolution.kind != .native) continue;
            if (std.mem.eql(u8, impl, "ESM") and resolution.kind != .esm) continue;
        }
        if (resolution.kind == .esm and !(std.mem.eql(u8, ctx.runtime.name(), "cnako") or ctx.target.compat_js)) continue;
        try exports.append(ctx.arena, .{
            .name = try ctx.arena.dupe(u8, export_decl.name),
            .alias = if (export_decl.alias) |alias| try ctx.arena.dupe(u8, alias) else null,
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
        .data = "●テストとは\n  戻る\nここまで\n",
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
    // export の source を静的走査して公開命令を記録する（path 依存でも
    // 宣言 dir を絶対化して commands 生成へ渡す）。
    const commands = lib.get("commands").?.array;
    try testing.expectEqual(@as(usize, 1), commands.items.len);
    try testing.expectEqualStrings("テスト", commands.items[0].object.get("name").?.string);

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

test "sync は current が欠損しても公開済み世代を environment.json から保持する" {
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

    // current 更新失敗・中断と同等の状態（公開済みだが current が無い）。
    try temporary.dir.deleteFile(io, ".nako/current");

    var second = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // current が無くても environment.json の参照から前世代が保持される。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
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
