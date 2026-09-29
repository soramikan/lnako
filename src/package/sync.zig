//! `nako.lock` 駆動の環境同期。lock の package 集合を provider 経由で取得・
//! 検証し、内容アドレス cache へ公開してから `.nako/` 環境を構築する。
//!
//! - `.nako/sync.lock` と `<cache>/cache.lock` の OS lock で並行 sync を直列化
//!   する。どちらも process 終了で自動解放される。
//! - package 内容は staging で検証・展開を完了してから cache `objects/` へ
//!   原子的に公開する。環境は `.nako/staging/<gen>` に構築し、世代 dir への
//!   rename と `environment.json` の原子書換で公開後、`current` を別途更新する。
//! - commit 前の失敗は既存環境を変更しない。commit 後の `current` 公開失敗は
//!   error を返し、state 検査で stale として再試行させる。
//! - `path` 依存は mutable source として宣言 dir をそのまま参照する
//!   （環境側へ複製しない）。cache・他プロジェクトへの波及は copy 経由の
//!   immutable entry 側で防ぐ。

const std = @import("std");
const cache = @import("cache.zig");
const diag = @import("diagnostics.zig");
const environment = @import("environment.zig");
const fetch = @import("fetch.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const path_digest = @import("path_digest.zig");
const prepare = @import("sync_prepare.zig");

const Allocator = std.mem.Allocator;

/// 同期対象 runtime。実体は `sync_prepare.zig` にある。
pub const Runtime = prepare.Runtime;
/// 同期エラー集合。実体は `sync_prepare.zig` にある。
pub const Error = prepare.Error;
/// package id 形式の検証。実体は `sync_prepare.zig` にある。
pub const isPackageId = prepare.isPackageId;
/// manifest 依存宣言の lock 照合制約。実体は `sync_prepare.zig` にある。
pub const ImportConstraint = prepare.ImportConstraint;
/// manifest 依存宣言から import 依存（alias → lock key）を集める。
/// 実体は `sync_prepare.zig` にある。
pub const collectRootDependencyIds = prepare.collectRootDependencyIds;
pub const collectImportDependencies = prepare.collectImportDependencies;
pub const collectImportDependenciesForProfile = prepare.collectImportDependenciesForProfile;
/// scoped alias の重複・namespace 正規化衝突検査付き追加。
/// 実体は `sync_prepare.zig` にある。
pub const appendScopedAlias = prepare.appendScopedAlias;

const mapFs = prepare.mapFs;
const testing = std.testing;
pub const Options = struct {
    /// `nako.lock` と `nako.toml` を持つプロジェクトルート。
    project_root: []const u8 = ".",
    /// pinned プロジェクトルート handle。設定すると lock・manifest・
    /// `.nako`・相対 path 依存の解決を全てこの handle 相対で行い、
    /// `project_root` 文字列は診断表示用としてのみ使う。project root の
    /// rename/replace 競合で別 dir を読み書きしないため、handle を
    /// 持つ呼出し側は必ず渡す。
    project_dir: ?std.Io.Dir = null,
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

/// Path source pin validation delegates to the portable digest implementation.
pub fn mutablePathMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) Error!?[]const u8 {
    return path_digest.mutablePathMismatch(gpa, io, project_root, lock) catch |err| return mapFs(err);
}

pub fn mutablePathsMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, recorded: []const lock_model.MutablePath) Error!?[]const u8 {
    return path_digest.mutablePathsMismatch(gpa, io, project_root, recorded) catch |err| return mapFs(err);
}

pub fn pathPinMismatch(gpa: Allocator, io: std.Io, project_root: []const u8, lock: *const lock_model.Lock) Error!?[]const u8 {
    return path_digest.pathPinMismatch(gpa, io, project_root, lock) catch |err| return mapFs(err);
}

/// pinned `root_dir` handle 相対版。rename/replace 競合時も検査対象は
/// pinned root 配下に留まるため、handle を持つ呼出し側はこちらを使う。
pub fn mutablePathMismatchDir(gpa: Allocator, io: std.Io, root_dir: std.Io.Dir, lock: *const lock_model.Lock) Error!?[]const u8 {
    return path_digest.mutablePathMismatchDir(gpa, io, root_dir, lock) catch |err| return mapFs(err);
}

pub fn mutablePathsMismatchDir(gpa: Allocator, io: std.Io, root_dir: std.Io.Dir, recorded: []const lock_model.MutablePath) Error!?[]const u8 {
    return path_digest.mutablePathsMismatchDir(gpa, io, root_dir, recorded) catch |err| return mapFs(err);
}

pub fn pathPinMismatchDir(gpa: Allocator, io: std.Io, root_dir: std.Io.Dir, lock: *const lock_model.Lock) Error!?[]const u8 {
    return path_digest.pathPinMismatchDir(gpa, io, root_dir, lock) catch |err| return mapFs(err);
}

/// `project_dir` 相対の `nako.toml` の SHA-256 が
/// `lock.input.manifest_sha256` と一致するか。`FileNotFound` は `.absent`
/// （manifest 無しの lock 駆動用途を区別するため呼出し側に返す）。その他の
/// 読取失敗は生の error で伝播する。pinned handle 相対で読むため、
/// project root の rename/replace に追従しない。
const ManifestFreshness = enum { absent, fresh, stale };

fn manifestFreshness(io: std.Io, arena: Allocator, project_dir: std.Io.Dir, lock: *const lock_model.Lock) !ManifestFreshness {
    const bytes = project_dir.readFileAlloc(io, "nako.toml", arena, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    if (!lock_model.normalizeSha256(lock.input.manifest_sha256, &expected) or
        !std.mem.eql(u8, &actual, &expected)) return .stale;
    return .fresh;
}

/// `nako.lock` を読み、環境を同期する。失敗時は `session` 由来の診断を
/// `diagnostics` へ転写して error を返す。commit 前の失敗は直前環境を変更しない。
/// commit 後の current 公開失敗では error を返し、state 検査で stale として再試行させる。
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
    // `project_dir` が指定された場合、以降の lock・manifest・`.nako`・
    // 相対 path 依存の全操作をこの pinned handle 相対で行う。`project_abs`
    // は診断表示・lock 内絶対 path 記録用で、handle の実体 path から取る。
    var project_dir = if (options.project_dir) |dir|
        dir.openDir(io, ".", .{ .follow_symlinks = false }) catch |err| return mapFs(err)
    else
        std.Io.Dir.cwd().openDir(io, options.project_root, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.LockNotFound,
            else => return mapFs(err),
        };
    defer project_dir.close(io);
    const project_abs: []const u8 = project_dir.realPathFileAlloc(io, ".", arena) catch |err| switch (err) {
        else => return mapFs(err),
    };
    const lock_bytes = project_dir.readFileAlloc(io, "nako.lock", arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
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
    // 不整合になるのを防ぐ。省略できるのは `FileNotFound`（manifest 無しの
    // lock 駆動用途）だけで、dir 化・読取不能・size 上限超過などその他の
    // 失敗は manifest の有無と鮮度を確定できないため同期を失敗させる。
    const manifest_state = manifestFreshness(io, arena, project_dir, &lock) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "cannot read nako.toml for lock manifest verification: {s}", .{@errorName(err)});
            return mapFs(err);
        },
    };
    if (manifest_state == .stale) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "lock input manifestSha256 does not match nako.toml; re-resolve the lock before sync", .{});
        return error.StaleLock;
    }

    // `mutable = false` の path pin も照合する。pin 不一致の lock で環境を
    // 構築すると lock が pin した内容と異なる tree を参照するため stale
    // として拒否する（`lnako lock` で再解決してから sync する）。
    if (try pathPinMismatchDir(arena, io, project_dir, &lock)) |name| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of pinned path dependency \"{s}\" does not match nako.lock; re-resolve the lock before sync", .{name});
        return error.StaleLock;
    }
    // `mutable = true` の path 依存も内容 digest で照合する。宣言 dir の
    // 内容が lock 記録時と変わっていれば、記録時のグラフを前提にした環境
    // は構築しない。
    if (try mutablePathMismatchDir(arena, io, project_dir, &lock)) |path| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of mutable path dependency \"{s}\" does not match nako.lock; re-resolve the lock before sync", .{path});
        return error.StaleLock;
    }

    // root manifest は鮮度が確定した場合だけ parse する。依存宣言から
    // import 依存（alias → lock key）を収集して環境へ記録するため。
    // 読取と parse の間の書換えは公開直前の再照合で検出する。
    var root_manifest: ?manifest_mod.Manifest = null;
    defer if (root_manifest) |*manifest| manifest.deinit();
    if (manifest_state == .fresh) {
        const manifest_bytes = project_dir.readFileAlloc(io, "nako.toml", arena, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return mapFs(err),
        };
        root_manifest = manifest_mod.parse(arena, manifest_bytes, diagnostics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LockInvalid,
        };
        if (diagnostics.errorCount() > 0) return error.LockInvalid;
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
    var env_store = environment.Store.openDir(gpa, io, project_dir, project_abs) catch |err| return mapFs(err);
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
    var generation = env_store.newGeneration(arena) catch |err| return mapFs(err);
    var generation_dir_open = true;
    defer {
        if (generation_dir_open) generation.dir.close(io);
    }
    generation.dir.createDirPath(io, "deps") catch |err| return mapFs(err);
    var deps_dir = generation.dir.openDir(io, "deps", .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    var deps_dir_open = true;
    defer {
        if (deps_dir_open) deps_dir.close(io);
    }
    // env.json に記録する世代相対 path は環境 artifact の canonical 形式として
    // 常に `/` 区切りで構築する（`std.fs.path.join` は Windows で `\` になり、
    // resolver の prefix 比較・fixture・lock 記録と不一致になる）。
    // filesystem 操作には使わず、`.nako/env/<gen>` の論理名として扱う。
    const generation_rel = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ environment.dir_name, environment.env_dir, generation.generation });
    const workspace_name = try std.fmt.allocPrint(arena, ".lnako-work-{s}", .{generation.generation});
    var workspace_dir = environment.openManagedChildDir(project_dir, io, workspace_name, true) catch |err| return mapFs(err);
    defer environment.deleteTreeChecked(project_dir, io, workspace_name) catch {};
    defer workspace_dir.close(io);

    // root manifest の依存宣言を import 依存へ集める。schema v2 の lock
    // は rootDependencies で宣言順序を記録する。v1 lock（記録無し）は
    // lock entry 走査で再構成し、一意に定まらない場合は拒否する。
    const root_dependencies = if (root_manifest) |*manifest| blk: {
        const direct_ids = if (lock.rootDependenciesForProfile(profile)) |ids|
            ids
        else
            prepare.collectRootDependencyIdsForProfile(arena, entries, manifest, profile, diagnostics) catch |err| switch (err) {
                error.LockInvalid => {
                    if (!diagnostics.hasErrors()) try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.rootDependencies", .{}, "legacy lock does not record the root dependency edge and has multiple matching package nodes; regenerate the lock with schema v2", .{});
                    return error.LockInvalid;
                },
                else => return err,
            };
        break :blk try prepare.collectImportDependenciesForProfile(arena, entries, direct_ids, null, manifest, profile, diagnostics);
    } else &.{};
    var ctx = prepare.Context{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .session = &session,
        .cache_store = &cache_store,
        .project_abs = project_abs,
        .project_dir = project_dir,
        .lock = &lock,
        .deps_dir = deps_dir,
        .workspace_dir = workspace_dir,
        .generation_rel = generation_rel,
        .runtime = options.runtime,
        .selected_profile = profile,
        .diagnostics = diagnostics,
        .lock_entries = entries,
        .root_dependencies = root_dependencies,
        .target = prepare.materializeTarget(profile, record, &lock.input, options.runtime),
    };

    // --- package の取得・検証・materialize ---------------------------------
    var records = std.ArrayListUnmanaged(environment.PackageRecord).empty;
    for (entries) |*entry| {
        const record_value = prepare.preparePackage(&ctx, entry) catch |err| {
            // provider 由来の失敗は session.failures に分類付きで記録済み。
            session.reportDiagnostics(diagnostics) catch {};
            return err;
        };
        try records.append(arena, record_value);
    }

    // path 依存の pin/digest は事前にも照合しているが、その後
    // `preparePackage` が manifest・exports・commands を同じ dir から
    // 再読している。検査と読取の間（または読取中）に内容が変わると
    // lock が pin した snapshot と異なる metadata で環境を公開してしまう
    // ため、構築した metadata が今も pin と一致するか公開直前に再照合する。
    // 不一致は新環境を公開せず失敗させる（sync を再実行すれば現在内容で
    // 再照合される）。
    if (try pathPinMismatchDir(arena, io, project_dir, &lock)) |name| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of pinned path dependency \"{s}\" changed while syncing; re-resolve the lock before sync", .{name});
        return error.StaleLock;
    }
    if (try mutablePathMismatchDir(arena, io, project_dir, &lock)) |path| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "content of mutable path dependency \"{s}\" changed while syncing; re-resolve the lock before sync", .{path});
        return error.StaleLock;
    }
    // root manifest も再照合する。package 取得・展開中に外部エディタ等が
    // `nako.toml` を保存・削除すると、開始時点の manifest とは別の宣言に
    // 基づく環境を公開してしまうため。manifest 無しの lock 駆動用途では
    // 再照合しない。
    if (manifest_state != .absent) {
        const current_manifest = manifestFreshness(io, arena, project_dir, &lock) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "cannot re-read nako.toml for publish-time manifest verification: {s}", .{@errorName(err)});
                return mapFs(err);
            },
        };
        if (current_manifest != .fresh) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "nako.toml changed while syncing; re-resolve the lock before sync", .{});
            return error.StaleLock;
        }
    }

    // --- 環境の公開 ---------------------------------------------------------
    var json_buffer: std.Io.Writer.Allocating = .init(arena);
    environment.emit(arena, .{
        .lock_sha256 = lock_sha256,
        .profile = profile,
        .runtime = options.runtime.name(),
        .packages = records.items,
        .dependencies = ctx.root_dependencies,
        // mutable path 依存の metadata（exports/commands）は環境へ
        // snapshot するため、宣言 dir の digest を記録して再解決を要さない
        // metadata-only 変更でも環境の陳腐化を検出できるようにする。
        .mutable_paths = lock.input.mutable_paths,
    }, &json_buffer.writer) catch |err| switch (err) {
        // Allocating writer の WriteFailed は arena 確保の失敗。
        error.WriteFailed => return error.OutOfMemory,
        else => return mapFs(err),
    };

    if (json_buffer.written().len > environment.max_environment_bytes) {
        return session.fail(.too_large, .package, "environment.json", "generated environment.json exceeds the {d} byte reader limit", .{environment.max_environment_bytes});
    }

    // 直前の公開環境が参照する世代を environment.json からも復元する。
    // env.json 公開後・current 更新前の中断では current が古い世代を
    // 指したまま残るため、両者を keep して実際の直前世代を消さない。
    const published_generation = env_store.readPublishedGeneration(arena) catch null;

    // Windowsは開いたdirectory handleをrenameできないため、staging世代と
    // 子のdeps handleを先に閉じる。commit失敗時にもdeferで二重closeしない。
    deps_dir.close(io);
    deps_dir_open = false;
    generation.dir.close(io);
    generation_dir_open = false;

    // staging 世代 dir と environment.json を commit する。commit 前に失敗すれば
    // 既存環境は無変更。current は別ファイルなので、この2操作は一括 atomic ではない。
    env_store.commit(generation.generation, json_buffer.written()) catch |err| return mapFs(err);
    // env_state は current が公開済み世代を指すことを要求する。公開失敗は
    // 成功扱いせず伝播し、state 検査で stale として後続 sync に再試行させる。
    env_store.writeCurrent(generation.generation) catch |err| return mapFs(err);

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

test "immutable path pin hash comparison normalizes lock representations" {
    const digest = [_]u8{0x5a} ** 32;
    const hex = std.fmt.bytesToHex(digest, .lower);
    try testing.expect(path_digest.pinHashMatches(digest, &hex));

    var encoded: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    var sri_buffer: ["sha256-".len + 44]u8 = undefined;
    const sri = try std.fmt.bufPrint(&sri_buffer, "sha256-{s}", .{encoded});
    try testing.expect(path_digest.pinHashMatches(digest, sri));

    var other = digest;
    other[0] ^= 1;
    try testing.expect(!path_digest.pinHashMatches(other, &hex));
    try testing.expect(!path_digest.pinHashMatches(digest, "invalid"));
}
test {
    _ = @import("sync_test.zig");
}
