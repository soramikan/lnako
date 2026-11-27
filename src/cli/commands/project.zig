//! プロジェクト依存管理コマンド（`init`/`add`/`remove`/`lock`/`update`/
//! `tree`/`why`/`check`/`cache`）と、`run`/`test`/`build` 前の自動準備。
//!
//! `nako.toml` の編集から依存解決（`nako.lock`）、`.nako` 環境の準備までを
//! 一貫した CLI として提供する。機械可読な結果（JSON）は stdout、診断は
//! stderr へ分離する。

const std = @import("std");
const lnako = @import("lnako");
const edit = @import("project_edit.zig");
const init_cmd = @import("project_init.zig");
const project_plugins = @import("project_plugins.zig");

const diag = lnako.package.diagnostics;
const project = lnako.package.project;
const manifest_mod = lnako.package.manifest;
const lock_model = lnako.package.lock;
const semver = lnako.package.semver;
const cache = lnako.package.cache;
const v1_runtime = lnako.package.v1_runtime;
const v1_entry = @import("v1_entry.zig");

const Allocator = std.mem.Allocator;

const project_flags = @import("project_flags.zig");

// 分割先の実装を同じ名前で参照できるようにする（呼出し側の API は変えない）。
pub const PrepFlags = project_flags.PrepFlags;
pub const flagValue = project_flags.flagValue;
const parsePrepFlags = project_flags.parsePrepFlags;
const rejectInertFlags = project_flags.rejectInertFlags;
pub const extractPrepFlags = project_flags.extractPrepFlags;

// ---------------------------------------------------------------------------
// 共通
// ---------------------------------------------------------------------------

/// CLI 失敗の error 集合。テスト時は process exit の代わりに error を
/// 返して異常路を検証できるようにする（本番では常に exit するため
/// 呼出し側の `return fail(...)` は到達しない）。
pub const CliError = error{ Failed, Usage };

pub fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Failed;
    std.process.exit(1);
}

pub fn failUsage(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Usage;
    std.process.exit(2);
}

/// プロジェクトを `start_dir` から上方探索して読み込む。見つからない・
/// manifest が不正なら診断を出力して失敗する。
pub fn loadProjectOrFail(a: Allocator, io: std.Io, start_dir: []const u8, stderr: *std.Io.Writer) CliError!project.Project {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        return fail(stderr, "nako.toml を読み込めません: {s}\n", .{@errorName(err)});
    };
    const result = loaded orelse return fail(stderr, "このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, result.manifest_path);
        return error.Failed;
    }
    return result;
}

pub fn renderOrFail(diagnostics: *diag.List, stderr: *std.Io.Writer, source_name: []const u8) void {
    if (diagnostics.errorCount() > 0) {
        diagnostics.render(stderr, source_name) catch {};
        stderr.flush() catch {};
    }
}

/// 公開 CLI 入口と、旧内部処理の回帰テストを区別する。公開入口は旧
/// manifest を旧 loader へ渡さず、`legacy_internal` は旧内部処理のテスト
/// だけが使う（本番の dispatch からは到達しない）。
pub const EntryMode = enum { public, legacy_internal };

/// 旧 manifest / 旧 lock 専用コマンドを公開 CLI の v1/旧形式入口へ流さない。
/// `dir` は編集 lock で pin 済みの root handle（あれば）。旧形式は旧 loader
/// で読み替えず、v1 の代替（sync --v1-fixture）だけを案内して拒否する。
pub fn rejectV1LegacyCommand(
    a: Allocator,
    io: std.Io,
    root: []const u8,
    dir: ?*const std.Io.Dir,
    verb: []const u8,
    mode: EntryMode,
    stderr: *std.Io.Writer,
) !void {
    var probe = v1_entry.probe(a, io, root, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fail(stderr, "{s}: nako.toml を読めません: {s}\n", .{ verb, @errorName(err) }),
    };
    defer probe.deinit(a);
    switch (probe) {
        .v1 => {
            const guidance = if (std.mem.eql(u8, verb, "lock"))
                v1_entry.v1_lock_guidance
            else
                v1_entry.legacyOnlyGuidance(verb);
            return fail(stderr, "{s}: v1 プロジェクトでは旧形式専用コマンドを使いません。{s}: {s}\n", .{
                verb,
                guidance,
                root,
            });
        },
        .invalid => |err| return fail(stderr, "{s}: nako.toml が v1 形式として不正です（{s}）: {s}\n", .{
            verb,
            v1_entry.manifestDiagnostic(err),
            root,
        }),
        // 公開 CLI は旧 manifest も旧 loader へ渡さない。旧内部処理の
        // 回帰テストだけが `legacy_internal` で従来経路を使う。
        .legacy => {
            if (mode == .public) {
                return fail(stderr, "{s}: {s}: {s}\n", .{
                    verb,
                    v1_entry.legacy_manifest_message,
                    root,
                });
            }
        },
        .missing => {},
    }
}

/// 編集 lock を持たない参照系コマンド用。プロジェクトが無ければ既存の
/// 読込み側の診断へ委ねる。
pub fn rejectV1LegacyCommandFrom(
    a: Allocator,
    io: std.Io,
    start_dir: []const u8,
    verb: []const u8,
    mode: EntryMode,
    stderr: *std.Io.Writer,
) !void {
    const root = project.findRoot(a, io, start_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    } orelse return;
    defer a.free(root);
    try rejectV1LegacyCommand(a, io, root, null, verb, mode, stderr);
}

fn projectErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProjectNotFound => "プロジェクトが見つかりません",
        error.InvalidManifest => "nako.toml が不正です",
        error.InvalidLock => "nako.lock が不正または破損しています",
        error.LockedNotSatisfied => "nako.lock が不足・陳腐のため --locked を満たせません",
        error.MissingEnvironment => ".nako 環境が不足・不一致です（`lnako sync` を実行してください）",
        error.UntrustedProject => "プロジェクトの書き込み権限検証で拒否しました（--strict-project-trust / LNAKO_PROJECT_TRUST=enforce）",
        error.ResolveFailed => "依存解決に失敗しました",
        error.DependencyCycle => "依存が循環しています",
        error.RegistryRequired => "pkg 依存の解決に registry URL が必要です（--registry または LNAKO_REGISTRY）",
        error.UnsupportedDependency => "lock に表現できない依存形態です",
        error.UnknownProfile => "profile が見つかりません",
        error.Offline => "オフラインモードでは取得できません",
        error.NotFound => "依存を取得できません（上記の診断を参照）",
        error.InvalidSource => "依存の source が不正です（上記の診断を参照）",
        error.InvalidMetadata => "依存のメタデータが不正です（上記の診断を参照）",
        error.ProviderUnavailable => "依存の取得先へ接続できません（上記の診断を参照）",
        error.SourceCollision => "依存の source が衝突しています（上記の診断を参照）",
        error.LockNotFound => "nako.lock が見つかりません（`lnako lock` を実行してください）",
        error.LockInvalid => "nako.lock が不正です",
        error.StaleLock => "nako.lock が manifest と一致しません",
        error.Busy => "別の処理が cache/環境を使用中です",
        else => @errorName(err),
    };
}

pub fn failProject(stderr: *std.Io.Writer, verb: []const u8, err: anyerror, diagnostics: *diag.List, source_name: []const u8) CliError {
    renderOrFail(diagnostics, stderr, source_name);
    return fail(stderr, "{s}: {s}\n", .{ verb, projectErrorMessage(err) });
}

// ---------------------------------------------------------------------------
// lock / update
// ---------------------------------------------------------------------------

fn runLock(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, mode: EntryMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "lock", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "lock: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // lock は環境構築を行わないため --no-sync は意味を持たない。
    try rejectInertFlags(&flags, "lock", .{
        .locked = true,
        .offline = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .registry = true,
        .cache_dir = true,
        .allow_plaintext_http = true,
        .json = true,
    }, stderr);

    // v1 は編集 lock を取る前に拒否し、.nako も旧 lock も作らない。
    // 取得後にも再検査して、race で v1 へ変わった manifest を旧 loader へ
    // 渡さない。
    try rejectV1LegacyCommandFrom(a, io, start_dir, "lock", mode, stderr);
    // manifest 読込〜lock 公開まで同じ編集 lock を保持し、並行する
    // add/remove/sync/自動準備と lock の書き換えを直列化する。
    var locked = try acquireProjectEditLock(a, io, start_dir, "lock", stderr);
    defer if (locked) |*l| l.deinit(a, io);
    // v1 manifest を旧 loader へ渡さない。v1 の nako.lock は `lnako sync`
    // が生成する（旧仕様の lock を v1 プロジェクトへ書かない）。
    if (locked) |*l| {
        if (l.root_dir) |*dir| {
            var probe = v1_entry.probeDir(a, io, dir) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return fail(stderr, "lock: nako.toml を読めません: {s}\n", .{@errorName(err)}),
            };
            defer probe.deinit(a);
            switch (probe) {
                .v1 => return fail(stderr, "lock: {s}: {s}\n", .{ l.root, v1_entry.v1_lock_guidance }),
                .invalid => |err| return fail(stderr, "lock: nako.toml が v1 形式として不正です（{s}）: {s}\n", .{ v1_entry.manifestDiagnostic(err), l.root }),
                .legacy => {
                    if (mode == .public) return fail(stderr, "lock: {s}: {s}\n", .{ v1_entry.legacy_manifest_message, l.root });
                },
                .missing => {},
            }
        }
    }
    var loaded = if (locked) |*l|
        try loadPinnedProjectOrFail(a, io, l, stderr)
    else
        try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, &loaded, &options, &diagnostics) catch |err| {
            return failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
        };
    }
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, "lock", err, &diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    if (flags.json) {
        try stdout.print("{{\"profile\":\"{s}\",\"packages\":{d},\"wrote\":{s}}}\n", .{ outcome.profile, outcome.lock.packages.len, if (outcome.wrote) "true" else "false" });
        try stdout.flush();
    } else if (outcome.wrote) {
        try stderr.print("lock: {d} 個の package を {s} に記録しました（profile: {s}）\n", .{ outcome.lock.packages.len, project.lock_name, outcome.profile });
        try stderr.flush();
    } else {
        try stderr.print("lock: {s} は最新です（{d} 個の package, profile: {s}）\n", .{ project.lock_name, outcome.lock.packages.len, outcome.profile });
        try stderr.flush();
    }
}

fn runUpdate(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, mode: EntryMode, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "update", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (flags.locked) return failUsage(stderr, "update: --locked と update は両立しません\n", .{});
    try rejectInertFlags(&flags, "update", .{
        .offline = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .registry = true,
        .cache_dir = true,
        .allow_plaintext_http = true,
    }, stderr);

    // v1 は編集 lock を取る前に拒否し、旧 lock の生成も .nako の作成も
    // 行わない。編集 lock 取得後にも再検査し、race で v1 へ変わった
    // manifest を旧 loader へ渡さない。
    try rejectV1LegacyCommandFrom(a, io, start_dir, "update", mode, stderr);
    // lock/update も add/remove と同じ編集 lock で直列化する（manifest
    // 読込〜lock 公開まで）。
    var locked = try acquireProjectEditLock(a, io, start_dir, "update", stderr);
    defer if (locked) |*l| l.deinit(a, io);
    if (locked) |*l| {
        if (l.root_dir) |*dir| try rejectV1LegacyCommand(a, io, l.root, dir, "update", mode, stderr);
    }
    var loaded = if (locked) |*l|
        try loadPinnedProjectOrFail(a, io, l, stderr)
    else
        try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    // 対象名は manifest の宣言依存に限る。未宣言名を黙って成功させない。
    var declared = loaded.manifest.dependencyAliases(a) catch return error.OutOfMemory;
    defer declared.deinit();
    // resolver は dep key（宣言テーブルキー）で照合するため、alias で
    // 指定された対象は dep key へ正規化する（`update <alias>` が実際に
    // その依存の版固定を解除するように）。
    var alias_to_key = std.StringHashMap([]const u8).init(a);
    defer alias_to_key.deinit();
    for ([_]*const manifest_mod.DependencyGroup{ &loaded.manifest.dependencies, &loaded.manifest.dev_dependencies }) |group| {
        var it = group.git.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.alias) |alias| try alias_to_key.put(alias, item.key_ptr.*);
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |item| {
            if (item.value_ptr.alias) |alias| try alias_to_key.put(alias, item.key_ptr.*);
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |item| {
            if (item.value_ptr.alias) |alias| try alias_to_key.put(alias, item.key_ptr.*);
        }
    }
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(a);
    for (parsed.rest) |target| {
        if (!declared.contains(target)) {
            return fail(stderr, "update: {s} は依存にありません\n", .{target});
        }
        const dep_key = alias_to_key.get(target) orelse target;
        // source dependency は dep key を渡す（canonical ID は acquisition
        // 後に決まる）。pkg dependency は public-id/name を resolver へ渡す。
        try targets.append(a, try resolvedIdForDecl(&loaded.manifest, dep_key));
    }
    options.update_targets = targets.items;
    options.update_all = parsed.rest.len == 0;
    // fresh な lock でも再解決して新版を拾うのが update の契約。
    options.force_resolve = true;
    var outcome = project.ensureLock(a, io, &loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, "update", err, &diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    var updated: usize = 0;
    if (outcome.report) |report| {
        for (report.changes) |change| {
            if (change.reason != .unchanged) updated += 1;
        }
    }
    try stderr.print("update: {d} 個の package を更新しました\n", .{updated});
    try stderr.flush();
}

/// update 対象として使う識別子を返す。source dependency は dep key を
/// `isUpdateTarget` に渡し、pkg dependency は resolver の public id/name を使う。
/// 未宣言 key には到達しない前提（呼出し側が宣言集合で検証済み）。
fn resolvedIdForDecl(manifest: *const manifest_mod.Manifest, dep_key: []const u8) ![]const u8 {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        if (group.path.contains(dep_key)) return dep_key;
        if (group.git.contains(dep_key)) return dep_key;
        if (group.http.contains(dep_key)) return dep_key;
        if (group.pkg.get(dep_key)) |dep| {
            // pkg 依存の解決 id は `public-id` 明示または package 名。
            return dep.public_id orelse dep.name;
        }
    }
    return dep_key;
}

// ---------------------------------------------------------------------------
// tree / why
// ---------------------------------------------------------------------------

/// `tree`/`why` 用の lock 取得。問い合わせコマンドは `nako.lock` を
/// 書き換えない（読み取り専用）。lock が無い・陳腐なら必要な操作を
/// 案内して失敗する。
fn lockForQuery(a: Allocator, io: std.Io, loaded: *project.Project, flags: *const PrepFlags, environ_map: ?*const std.process.Environ.Map, verb: []const u8, stderr: *std.Io.Writer) !project.LockOutcome {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = flags.toOptions(environ_map);
    if (flags.locked) {
        project.verifyLocked(a, io, loaded, &options, &diagnostics) catch |err| {
            return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
        };
    }
    return project.loadFreshLock(a, io, loaded, &options, &diagnostics) catch |err| {
        return failProject(stderr, verb, err, &diagnostics, loaded.manifest_path);
    };
}

fn sourceTag(entry: lock_model.PackageEntry) []const u8 {
    const source = entry.source orelse return "registry";
    return switch (source.kind) {
        .path => "path",
        .git => "git",
        .http => "http",
        else => "registry",
    };
}

/// `acquireProjectEditLock` の結果。`guard` が編集 lock、`root`/
/// `root_dir` は lock 取得時に pin した canonical root。`root_dir` を
/// `loadPinnedProjectOrFail`/`loadFromDir` へ渡すと所有権が移り、lock
/// 対象と manifest 読込みが同じ dir に固定される。
pub const PinnedEditLock = struct {
    guard: project.EditLock,
    root: []const u8,
    root_dir: ?std.Io.Dir,

    /// `loadFromDir` へ渡す root handle を取り出す。所有権は呼出し
    /// 先（成功時は `Project`、失敗時は `loadFromDir` の errdefer）へ
    /// 移るため、`deinit` では閉じなくなる。
    pub fn takeDir(self: *PinnedEditLock) std.Io.Dir {
        defer self.root_dir = null;
        return self.root_dir.?;
    }

    pub fn deinit(self: *PinnedEditLock, a: Allocator, io: std.Io) void {
        self.guard.unlock();
        if (self.root_dir) |*dir| dir.close(io);
        a.free(self.root);
    }
};

/// `start_dir` からプロジェクトルートを特定し、manifest/lock 編集の
/// 排他 lock（`.nako/edit.lock`）を取得する。非プロジェクトなら null
/// （`loadProjectOrFail`/`discoverAndLoad` の診断に委ねる）。
/// lock を書き込む全ての verb（lock/update/add/remove/sync/自動準備）は
/// manifest 読込の前に呼び、lock 公開まで保持する。
/// 返す `PinnedEditLock` は root の dir handle を pin 済みのため、root
/// path が rename/置換されても `loadPinnedProjectOrFail` は lock 対象と
/// 同じ dir から manifest を読む。
pub fn acquireProjectEditLock(a: Allocator, io: std.Io, start_dir: []const u8, verb: []const u8, stderr: *std.Io.Writer) !?PinnedEditLock {
    const root = project.findRoot(a, io, start_dir) catch |err| {
        return fail(stderr, "{s}: プロジェクトルートを探索できません: {s}\n", .{ verb, @errorName(err) });
    } orelse return null;
    errdefer a.free(root);
    // lock 取得と manifest 読込みを同じ dir に固定するため、root を
    // ここで open して pin する。findRoot の返す path は realPath 済み
    // で leaf が symlink の正当構成はないため no-follow で開く。
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false }) catch |err| {
        return fail(stderr, "{s}: プロジェクトルートを開けません: {s}\n", .{ verb, @errorName(err) });
    };
    errdefer root_dir.close(io);
    const guard = project.acquireEditLockDir(io, root_dir) catch |err| {
        return fail(stderr, "{s}: 編集ロックを取得できません: {s}\n", .{ verb, @errorName(err) });
    };
    return .{ .guard = guard, .root = root, .root_dir = root_dir };
}

/// `PinnedEditLock` の pin 済み root handle から Project を読み込む
/// （`loadProjectOrFail` の pinned 版）。path を再解決しないため、lock
/// 取得後の root rename/置換で別 dir の manifest を読まない。
/// `locked.root_dir` の所有権は `loadFromDir` 経由で Project へ移る。
pub fn loadPinnedProjectOrFail(a: Allocator, io: std.Io, locked: *PinnedEditLock, stderr: *std.Io.Writer) CliError!project.Project {
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const result = project.loadFromDir(a, io, locked.root, locked.takeDir(), &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, locked.root);
        return fail(stderr, "nako.toml を読み込めません: {s}\n", .{@errorName(err)});
    };
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, result.manifest_path);
        return error.Failed;
    }
    return result;
}

/// 宣言 dep key・alias と解決済み entry id の対応表。dep key と
/// package 名が異なる（alias・同名 package）ときに宣言側の名前を
/// 表示・検索できるようにする。呼出し側が `deinit` する。
pub const DepKeyMaps = struct {
    /// 解決済み entry id → 宣言 dep key（tree の表示用）。
    by_id: std.StringHashMap([]const u8),
    /// dep key または alias → 解決済み entry id（why の検索用）。
    by_name: std.StringHashMap([]const u8),

    pub fn deinit(self: *DepKeyMaps) void {
        self.by_id.deinit();
        self.by_name.deinit();
    }
};

pub fn depKeyIdMap(a: Allocator, manifest: *const manifest_mod.Manifest, root: []const u8, packages: []const lock_model.PackageEntry) !DepKeyMaps {
    var maps = DepKeyMaps{
        .by_id = std.StringHashMap([]const u8).init(a),
        .by_name = std.StringHashMap([]const u8).init(a),
    };
    errdefer maps.deinit();
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var path_it = group.path.iterator();
        while (path_it.next()) |item| {
            const id = (try project.publicIdForSourceDeclInPackages(a, .{ .path = item.value_ptr.* }, root, root, packages)) orelse continue;
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |item| {
            const id = (try project.publicIdForSourceDeclInPackages(a, .{ .git = item.value_ptr.* }, root, root, packages)) orelse continue;
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
            if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, id);
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |item| {
            const id = (try project.publicIdForSourceDeclInPackages(a, .{ .http = item.value_ptr.* }, root, root, packages)) orelse continue;
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
            if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, id);
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |item| {
            // `public-id` 明示宣言は解決済み entry を ID で直接照合する。
            // name 照合では同名 package が複数解決された際に先頭一致を
            // 誤って対応付けてしまうため。
            if (item.value_ptr.public_id) |public_id| {
                for (packages) |entry| {
                    if (!std.mem.eql(u8, entry.id, public_id)) continue;
                    try maps.by_id.put(entry.id, item.key_ptr.*);
                    try maps.by_name.put(item.key_ptr.*, entry.id);
                    if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, entry.id);
                    break;
                }
                continue;
            }
            // `public-id` 未指定の pkg 依存は manifest から public id を
            // 導出できないため、解決済み package 名（宣言名 `name`。
            // `alias` はプログラム側の参照名で package 名ではない）で
            // 対応付ける。
            for (packages) |entry| {
                if (std.mem.eql(u8, entry.name, item.value_ptr.name)) {
                    try maps.by_id.put(entry.id, item.key_ptr.*);
                    try maps.by_name.put(item.key_ptr.*, entry.id);
                    if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, entry.id);
                    break;
                }
            }
        }
    }
    return maps;
}

fn runTree(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, mode: EntryMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "tree", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "tree: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // tree は読み取り専用の問い合わせ。lock 鮮度入力と検証に関係する
    // フラグのみ受け付ける。
    try rejectInertFlags(&flags, "tree", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
    }, stderr);

    try rejectV1LegacyCommandFrom(a, io, start_dir, "tree", mode, stderr);
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = try lockForQuery(a, io, &loaded, &flags, environ_map, "tree", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    var maps = try depKeyIdMap(a, &loaded.manifest, loaded.root, packages);
    defer maps.deinit();
    // 選択 profile・feature 集合で無効化される宣言は root に含めない。
    // `rootDeps`/`collectLocals` と同じ gated/activated 判定を使い、
    // 無効な宣言が推移的に存在する同名 package を誤って直接依存として
    // 表示しないようにする。
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const query_options = flags.toOptions(environ_map);
    var gated = try project.gatedDepNames(a, &loaded.manifest);
    defer gated.deinit();
    var expanded = project.expandRootFeatures(a, &loaded.manifest, query_options.features, !query_options.no_default_features, &diagnostics) catch |err| {
        return failProject(stderr, "tree", err, &diagnostics, loaded.manifest_path);
    };
    defer expanded.deinit();
    try stdout.print("{s} {f} (profile: {s})\n", .{ loaded.manifest.package.name, loaded.manifest.package.version, outcome.profile });
    // root は manifest の宣言依存から決める。直接依存が他の直接依存の
    // 子でもある場合に「被参照だから非 root」で落とすと宣言 graph が
    // 歪むため、dep key → 解決済み entry の対応表で列挙する。
    var root_keys: std.ArrayList([]const u8) = .empty;
    defer root_keys.deinit(a);
    const activated = &expanded.dependency_aliases;
    for ([_]*const manifest_mod.DependencyGroup{ &loaded.manifest.dependencies, &loaded.manifest.dev_dependencies }) |group| {
        var it = group.path.iterator();
        while (it.next()) |item| {
            const dep = item.value_ptr.*;
            if (project.depIsGated(&gated, dep.name, null) and !project.depIsActivated(activated, dep.name, null)) continue;
            try root_keys.append(a, item.key_ptr.*);
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |item| {
            const dep = item.value_ptr.*;
            if (project.depIsGated(&gated, dep.name, dep.alias) and !project.depIsActivated(activated, dep.name, dep.alias)) continue;
            try root_keys.append(a, item.key_ptr.*);
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |item| {
            const dep = item.value_ptr.*;
            if (project.depIsGated(&gated, dep.name, dep.alias) and !project.depIsActivated(activated, dep.name, dep.alias)) continue;
            try root_keys.append(a, item.key_ptr.*);
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |item| {
            const dep = item.value_ptr.*;
            // rootDeps と同じく profile 制約のある宣言は選択 profile
            // に一致する場合のみ有効とする。
            if (dep.profile) |p| {
                if (!std.mem.eql(u8, p, outcome.profile)) continue;
            }
            if (project.depIsGated(&gated, dep.name, dep.alias) and !project.depIsActivated(activated, dep.name, dep.alias)) continue;
            try root_keys.append(a, item.key_ptr.*);
        }
    }
    std.mem.sort([]const u8, root_keys.items, {}, struct {
        fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lt);
    var printed_any = false;
    var seen_roots = std.StringHashMap(void).init(a);
    defer seen_roots.deinit();
    for (root_keys.items) |key| {
        const id = maps.by_name.get(key) orelse continue;
        // 同一 entry を指す dep key が複数あっても root は一度だけ出す。
        if (seen_roots.contains(id)) continue;
        try seen_roots.put(id, {});
        const entry = findEntry(packages, id) orelse continue;
        printed_any = true;
        try printTreeNode(a, stdout, packages, entry, "", true, &.{}, maps.by_id.get(entry.id));
    }
    // manifest に宣言の無い package（純粋な推移的 graph のみ等）や
    // 宣言と lock が食い違う場合の fallback として、root が一つも
    // 出なければ全 package を列挙する。
    if (!printed_any) {
        for (packages) |entry| {
            try printTreeNode(a, stdout, packages, entry, "", true, &.{}, maps.by_id.get(entry.id));
        }
    }
    try stdout.flush();
}

fn findEntry(packages: []const lock_model.PackageEntry, id: []const u8) ?lock_model.PackageEntry {
    for (packages) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// tree 表示の再帰深さ上限。`seen` は経路上の祖先 id なので
/// `seen.len` がそのまま深さになる。resolver 生成の graph では
/// 実際にこの深さへ達しないが、細工した lock でも stack を使い切ら
/// ないよう上限を設ける。
const max_tree_depth = 128;

fn printTreeNode(a: Allocator, stdout: *std.Io.Writer, packages: []const lock_model.PackageEntry, entry: lock_model.PackageEntry, prefix: []const u8, last: bool, seen: []const []const u8, label: ?[]const u8) !void {
    const branch = if (last) "└── " else "├── ";
    if (label != null and !std.mem.eql(u8, label.?, entry.name)) {
        // dep key（宣言名）と package 名が異なる場合は両方表示する。
        try stdout.print("{s}{s}{s} -> {s} {s} [{s}{s}]\n", .{ prefix, branch, label.?, entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    } else {
        try stdout.print("{s}{s}{s} {s} [{s}{s}]\n", .{ prefix, branch, entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    }
    for (seen) |id| {
        if (std.mem.eql(u8, id, entry.id)) return;
    }
    var next_seen: std.ArrayList([]const u8) = .empty;
    try next_seen.appendSlice(a, seen);
    try next_seen.append(a, entry.id);
    if (next_seen.items.len >= max_tree_depth) {
        try stdout.print("{s}    └── … (深さ上限)\n", .{prefix});
        return;
    }
    const child_prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, if (last) "    " else "│   " });
    for (entry.dependencies, 0..) |dep_id, i| {
        const child = findEntry(packages, dep_id) orelse continue;
        const last_child = i == entry.dependencies.len - 1;
        // 循環辺は再帰せず (cycle) として表示する。
        var in_seen = false;
        for (next_seen.items) |id| {
            if (std.mem.eql(u8, id, dep_id)) {
                in_seen = true;
                break;
            }
        }
        if (in_seen) {
            const child_branch = if (last_child) "└── " else "├── ";
            try stdout.print("{s}{s}{s} {s} (cycle)\n", .{ child_prefix, child_branch, child.name, child.version });
            continue;
        }
        try printTreeNode(a, stdout, packages, child, child_prefix, last_child, next_seen.items, null);
    }
}

fn runWhy(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, mode: EntryMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "why", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len == 0) return failUsage(stderr, "why: パッケージ名が必要です\n", .{});
    if (parsed.rest.len > 1) return failUsage(stderr, "why: 不明な引数です: {s}\n", .{parsed.rest[1]});
    try rejectInertFlags(&flags, "why", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
    }, stderr);
    const name = parsed.rest[0];

    try rejectV1LegacyCommandFrom(a, io, start_dir, "why", mode, stderr);
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
    defer loaded.deinit();
    var outcome = try lockForQuery(a, io, &loaded, &flags, environ_map, "why", stderr);
    defer outcome.deinit();

    const packages = outcome.lock.packagesForProfile(outcome.profile) orelse outcome.lock.packages;
    // 宣言 dep key・alias の対応表を優先する。package 名がたまたま他の
    // 宣言 dep key と一致する場合に、名前一致で誤った entry を拾わない
    // ようにする。
    var maps = try depKeyIdMap(a, &loaded.manifest, loaded.root, packages);
    defer maps.deinit();
    var target: ?lock_model.PackageEntry = null;
    if (maps.by_name.get(name)) |id| {
        target = findEntry(packages, id);
    }
    if (target == null) {
        for (packages) |entry| {
            if (std.mem.eql(u8, entry.name, name) or std.mem.eql(u8, entry.id, name)) {
                target = entry;
                break;
            }
        }
    }
    const entry = target orelse return fail(stderr, "why: {s} は解決済み依存にありません\n", .{name});

    // 選択 profile・feature 集合で無効化される宣言は「直接宣言」の
    // 理由として報告しない（その宣言は今回のグラフを導入していない）。
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const query_options = flags.toOptions(environ_map);
    var gated = try project.gatedDepNames(a, &loaded.manifest);
    defer gated.deinit();
    var expanded = project.expandRootFeatures(a, &loaded.manifest, query_options.features, !query_options.no_default_features, &diagnostics) catch |err| {
        return failProject(stderr, "why", err, &diagnostics, loaded.manifest_path);
    };
    defer expanded.deinit();

    try stdout.print("{s} {s} [{s}{s}]\n", .{ entry.name, entry.version, sourceTag(entry), if (entry.implementation) |impl| std.fmt.allocPrint(a, ", {s}", .{impl}) catch "" else "" });
    // manifest の直接宣言かを確認する。
    const declared_section = try manifestDeclares(a, &loaded.manifest, loaded.root, packages, &entry, name, outcome.profile, &gated, &expanded.dependency_aliases);
    if (declared_section) |declared| {
        try stdout.print("  理由: {s}（直接宣言）\n", .{declared});
    }
    // 逆依存（この package を必要とする他 package）を列挙する。
    var found_dependent = false;
    for (packages) |parent| {
        for (parent.dependencies) |dep_id| {
            if (!std.mem.eql(u8, dep_id, entry.id)) continue;
            try stdout.print("  理由: {s} {s} の依存として導入\n", .{ parent.name, parent.version });
            found_dependent = true;
        }
    }
    if (!found_dependent and declared_section == null) {
        try stdout.print("  理由: 解決グラフに含まれます（参照元は lock に記録されていません）\n", .{});
    }
    try stdout.flush();
}

/// manifest が `name`（dep key または解決済み package 名）を直接宣言
/// しているか。宣言されていれば `dependencies.path` のような節名を返す。
/// dep key と package 名が異なる場合は `dep key` を併記する。
/// 選択 profile・feature で無効化される宣言（`dep:` gated で未活性、
/// `profile` 制約が不一致）は導入理由にならないため除外する。
pub fn manifestDeclares(a: Allocator, manifest: *const manifest_mod.Manifest, root: []const u8, packages: []const lock_model.PackageEntry, resolved: *const lock_model.PackageEntry, name: []const u8, profile: []const u8, gated: *const std.StringHashMap(void), activated: *const std.StringHashMap(void)) !?[]const u8 {
    const groups = [_]struct { prefix: []const u8, group: *const manifest_mod.DependencyGroup }{
        .{ .prefix = "dependencies", .group = &manifest.dependencies },
        .{ .prefix = "dev-dependencies", .group = &manifest.dev_dependencies },
    };
    for (groups) |item| {
        const group = item.group;
        var path_it = group.path.iterator();
        while (path_it.next()) |dep| {
            const d = dep.value_ptr.*;
            if (project.depIsGated(gated, d.name, null) and !project.depIsActivated(activated, d.name, null)) continue;
            if (try declaredMatch(a, packages, .{ .path = d }, "path", item.prefix, dep.key_ptr.*, null, name, resolved.id, root)) |text| return text;
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |dep| {
            const d = dep.value_ptr.*;
            if (project.depIsGated(gated, d.name, d.alias) and !project.depIsActivated(activated, d.name, d.alias)) continue;
            if (try declaredMatch(a, packages, .{ .git = d }, "git", item.prefix, dep.key_ptr.*, d.alias, name, resolved.id, root)) |text| return text;
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |dep| {
            const d = dep.value_ptr.*;
            if (project.depIsGated(gated, d.name, d.alias) and !project.depIsActivated(activated, d.name, d.alias)) continue;
            if (try declaredMatch(a, packages, .{ .http = d }, "http", item.prefix, dep.key_ptr.*, d.alias, name, resolved.id, root)) |text| return text;
        }
        var pkg_it = group.pkg.iterator();
        while (pkg_it.next()) |dep| {
            const d = dep.value_ptr.*;
            // rootDeps と同じく `profile` 制約が選択 profile と一致しない
            // 宣言・feature-gated で未活性の宣言は除外する。
            if (d.profile) |p| {
                if (!std.mem.eql(u8, p, profile)) continue;
            }
            if (project.depIsGated(gated, d.name, d.alias) and !project.depIsActivated(activated, d.name, d.alias)) continue;
            // `public-id` 明示の宣言は解決 id が一致する場合のみ直接
            // 宣言とする。同名の推移的 package（別 public id）を dep
            // key の名前一致で直接宣言と誤報しないため、名前照合より
            // 先に public-id を確認する。
            if (d.public_id) |public_id| {
                if (!std.mem.eql(u8, public_id, resolved.id)) continue;
                return try std.fmt.allocPrint(a, "{s}.pkg", .{item.prefix});
            }
            // pkg の dep key は宣言 package 名そのもの。alias は
            // プログラム側の参照名なので別名として照合する。
            // `why pkg:<id>` で引かれた場合も entry の name で直接宣言
            // と判定する。
            if (std.mem.eql(u8, dep.key_ptr.*, name) or std.mem.eql(u8, dep.key_ptr.*, resolved.name))
                return try std.fmt.allocPrint(a, "{s}.pkg", .{item.prefix});
            if (d.alias) |alias| {
                if (std.mem.eql(u8, alias, name)) return try std.fmt.allocPrint(a, "{s}.pkg（alias: {s} → {s}）", .{ item.prefix, alias, dep.key_ptr.* });
            }
        }
        var npm_it = group.npm.iterator();
        while (npm_it.next()) |dep| {
            if (std.mem.eql(u8, dep.key_ptr.*, name)) return try std.fmt.allocPrint(a, "{s}.npm", .{item.prefix});
        }
    }
    return null;
}

/// source 系 dep（path/git/http）の dep key・alias・解決済み package 名が
/// `name` と一致するか調べ、該当すれば節名テキストを返す。
fn declaredMatch(a: Allocator, packages: []const lock_model.PackageEntry, decl: project.SourceDecl, kind: []const u8, prefix: []const u8, dep_key: []const u8, alias: ?[]const u8, name: []const u8, resolved_id: []const u8, root: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, dep_key, name)) return try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, kind });
    if (alias) |al| {
        if (std.mem.eql(u8, al, name)) return try std.fmt.allocPrint(a, "{s}.{s}（alias: {s} → {s}）", .{ prefix, kind, al, dep_key });
    }
    const id = (try project.publicIdForSourceDeclInPackages(a, decl, root, root, packages)) orelse return null;
    // `why pkg:<id>` のように解決済み id で照合された場合も直接宣言と
    // 判定する（id が宣言 source と一致すれば dep key 併記で返す）。
    if (std.mem.eql(u8, id, resolved_id)) return try std.fmt.allocPrint(a, "{s}.{s}（dep key: {s}）", .{ prefix, kind, dep_key });
    const entry = findEntry(packages, id) orelse return null;
    if (!std.mem.eql(u8, entry.name, name)) return null;
    return try std.fmt.allocPrint(a, "{s}.{s}（dep key: {s}）", .{ prefix, kind, dep_key });
}

// ---------------------------------------------------------------------------
// check（副作用なし）
// ---------------------------------------------------------------------------

/// 既存環境が現行 lock と整合するか検査する。`.nako` を作成しない。
/// 環境が current のときは命令 metadata の静的検査も行う（Issue #52）。
pub fn checkProject(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    return checkProjectMode(a, io, args, start_dir, environ_map, .public, stdout, stderr);
}

fn checkProjectMode(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, mode: EntryMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "check", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "check: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // check は副作用なしの検査コマンド。sync・取得系フラグは意味を持た
    // ないため拒否する。`--strict-sharing` は命令 metadata の未検査を
    // E033 で失敗させる（共用保証の厳格検査）。`--load-plugins` は plugin
    // を実際にロードして実登録照合を行う（opt-in）。
    try rejectInertFlags(&flags, "check", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .json = true,
        .strict_sharing = true,
        .load_plugins = true,
        .strict_project_trust = true,
        .no_project_trust_warning = true,
    }, stderr);

    try rejectV1LegacyCommandFrom(a, io, start_dir, "check", mode, stderr);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    // 共有 writable の扱いは他コマンドと同じフラグ/環境変数で決める。
    // check は discovery 自体で trust 検査を行い、`.enforce` なら拒否する。
    var writable_warning = false;
    const found = project.discoverAndLoadWithMode(a, io, start_dir, &diagnostics, flags.writableMode(environ_map), &writable_warning) catch |err| {
        return failProject(stderr, "check", err, &diagnostics, ".");
    };
    if (writable_warning) {
        try stderr.print("警告: プロジェクト配置の書き込み権限が共有されています（停止は --strict-project-trust、非表示は --no-project-trust-warning）: {s}\n", .{start_dir});
        try stderr.flush();
    }
    const loaded = found orelse return fail(stderr, "check: このディレクトリはプロジェクトではありません（nako.toml が見つかりません）\n", .{});
    var project_var = loaded;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        return error.Failed;
    }

    var options = flags.toOptions(environ_map);
    // --locked は lock の無変更検証を強制する（check 自体は書き込まない
    // ため verifyLocked と矛盾しない）。
    if (flags.locked) {
        project.verifyLocked(a, io, &project_var, &options, &diagnostics) catch |err| {
            return failProject(stderr, "check", err, &diagnostics, project_var.manifest_path);
        };
    }
    const inspect = project.inspectForCheck(a, io, &project_var, &options, &diagnostics) catch |err| {
        return failProject(stderr, "check", err, &diagnostics, project_var.manifest_path);
    };
    const lock_state: []const u8 = switch (inspect.lock_state) {
        .missing => "missing",
        .invalid => "invalid",
        .fresh => "fresh",
        .stale => "stale",
    };

    var needed: std.ArrayList([]const u8) = .empty;
    if (inspect.lock_state != .fresh) try needed.append(a, "lnako lock");
    // lock が陳腐なら環境も再構築が必要（lock だけ更新して環境が旧
    // グラフを指し続ける状態を「同期済み」と案内しない）。
    if (inspect.lock_state != .fresh or !inspect.environment_current) try needed.append(a, "lnako sync");

    // feature 影響は環境 graph の root 依存と突き合わせて求める。lock が
    // 現行 manifest と選択フラグに一致する（fresh）ときだけ、選択と環境が
    // 同じ入力であることを保証できるため、stale 中は出さない（前回選択で
    // materialize された graph を現行選択の結果として見せない）。
    const feature_manifest: ?*const manifest_mod.Manifest =
        if (inspect.lock_state == .fresh) &project_var.manifest else null;

    // OS 条件評価の target。check は現行 profile の解決結果（runtime・
    // os/cpu/abi・言語バージョン）を使う。fresh lock の `input.target` とは
    // 鮮度比較で一致するため、ここで lock を読み直す必要はない。
    // lock が陳腐なときの環境に入っている実装は現行選択の target で選ばれて
    // いないため、条件評価は unknown（target なし）に留める。
    const check_target: ?lnako.package.command_conditions.Target = if (inspect.lock_state == .fresh)
        .{
            .runtime = inspect.runtime,
            .os = inspect.target.os,
            .cpu = inspect.target.cpu,
            .abi = inspect.target.abi,
            .os_version = inspect.target.os_version,
            .compat_js = inspect.target.compat_js,
            .optimize = inspect.target.optimize,
            .version = if (inspect.nako_version) |text| semver.Version.parse(text) catch null else null,
        }
    else
        null;

    // 命令 metadata 静的検査。環境が current のときのみ（stale/missing は
    // 索引が信頼できないため skipped）。再代入ではなく if 式で初期化し、
    // inspectEnvironmentDir が OOM で失敗しても defer が未初期化の
    // ArenaAllocator を二重解放しないようにする。
    var command_report = if (inspect.environment_current)
        try lnako.package.command_inspect.inspectEnvironmentDir(
            a,
            io,
            project_var.root_dir,
            .{
                .strict_sharing = flags.strict_sharing,
                .manifest = feature_manifest,
                .features = .{
                    .requested = flags.features.items,
                    .use_default_features = !flags.no_default_features,
                },
                .target = check_target,
                // check は自身で target を決める。null は「現行選択で未評価」
                // の意味であり、陳腐な lock の target へフォールバックしない。
                .target_from_lock = false,
            },
            &diagnostics,
        )
    else
        lnako.package.command_inspect.Report{ .arena = std.heap.ArenaAllocator.init(a) };
    defer command_report.deinit();

    // plugin 実登録照合（`--load-plugins` 指定時のみ）。plugin を実際に
    // ロードして登録された command（名前・助詞・arity）と宣言 metadata を
    // 照合し、不一致を E029 系の診断として報告する。ロードできない
    // package は不一致にせず未検査として記録する。
    var registration_report: ?lnako.package.plugin_registration.Report = null;
    defer if (registration_report) |*report| report.deinit();
    if (flags.load_plugins and inspect.environment_current) {
        registration_report = try project_plugins.runPluginRegistrationCheck(
            a,
            io,
            &project_var,
            .{ .compat_js_available = lnako.compat.quickjs.available() },
        );
        if (registration_report) |*report| {
            try lnako.package.plugin_registration.addDiagnostics(report, &diagnostics);
        }
    }

    // 名前空間 alias の error 診断は --json でも機械可読な結果を失わないよう、
    // JSON を出力した後に失敗を返す。テキストモードは従来どおり先に失敗する。
    const has_errors = diagnostics.errorCount() > 0;
    if (has_errors and !flags.json) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        return error.Failed;
    }

    const sharing = lnako.package.command_inspect.sharingText(command_report.sharing);

    if (flags.json) {
        var needed_json: std.ArrayList(u8) = .empty;
        for (needed.items, 0..) |cmd, i| {
            if (i > 0) try needed_json.appendSlice(a, ",");
            try needed_json.appendSlice(a, try std.fmt.allocPrint(a, "\"{s}\"", .{cmd}));
        }
        var uninspected_json: std.ArrayList(u8) = .empty;
        for (command_report.uninspected, 0..) |item, i| {
            if (i > 0) try uninspected_json.appendSlice(a, ",");
            const pkg_json = try std.json.Stringify.valueAlloc(a, item.package_key, .{});
            try uninspected_json.appendSlice(a, try std.fmt.allocPrint(
                a,
                "{{\"package\":{s},\"reason\":\"{s}\"}}",
                .{ pkg_json, item.reasonText() },
            ));
        }
        const conditions_json = try lnako.package.command_conditions.conditionsJson(a, command_report.conditions);
        defer a.free(conditions_json);
        const namespace_json = try lnako.package.namespace_check.summaryJson(
            a,
            command_report.alias_count,
            command_report.namespace_issues,
            if (command_report.namespace_scanned) command_report.namespace_scan_complete else null,
            command_report.namespace_scan_reason,
        );
        defer a.free(namespace_json);
        // feature 定義が無い / manifest 未供給なら key 自体を出さない。
        const features_json: []const u8 = if (command_report.features) |impact|
            try std.fmt.allocPrint(a, ",\"features\":{s}", .{try lnako.package.command_inspect.featureImpactJson(a, impact)})
        else
            "";
        // `--load-plugins` 未指定なら key 自体を出さない（未検査を主張しない）。
        const registration_json: []const u8 = if (registration_report) |*report|
            try lnako.package.plugin_registration.summaryJson(a, report)
        else
            "";
        try stdout.print(
            "{{\"schemaVersion\":1,\"manifest\":\"ok\",\"lock\":\"{s}\",\"environment\":\"{s}\",\"needed\":[{s}],\"commands\":{{\"sharing\":\"{s}\",\"inspected\":{d},\"uninspected\":[{s}],\"collisions\":{d},\"mismatches\":{d},\"conditions\":{s},\"namespaces\":{s}}}{s}{s}}}\n",
            .{
                lock_state,
                if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale",
                needed_json.items,
                sharing,
                command_report.inspected_count,
                uninspected_json.items,
                command_report.collision_count,
                command_report.mismatch_count,
                conditions_json,
                namespace_json,
                features_json,
                registration_json,
            },
        );
        try stdout.flush();
        if (has_errors) {
            renderOrFail(&diagnostics, stderr, project_var.manifest_path);
            return error.Failed;
        }
    } else {
        try stdout.print("プロジェクト: {s}（{s}）\n", .{ project_var.manifest.package.name, project_var.root });
        try stdout.print("  nako.toml: OK\n", .{});
        try stdout.print("  nako.lock: {s}\n", .{lock_state});
        try stdout.print("  .nako 環境: {s}\n", .{if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale"});
        try stdout.print("  命令検査: {s}（inspected={d}, uninspected={d}, collisions={d}, mismatches={d}）\n", .{
            sharing,
            command_report.inspected_count,
            command_report.uninspectedCount(),
            command_report.collision_count,
            command_report.mismatch_count,
        });
        if (command_report.uninspected.len > 0) {
            for (command_report.uninspected) |item| {
                try stdout.print("    未検査: {s} ({s})\n", .{ item.package_key, item.reasonText() });
            }
        }
        // package 宣言命令の OS 条件と、現在の target での利用可否。
        if (command_report.conditions.len > 0) {
            if (check_target) |target| {
                try stdout.print("  命令 OS 条件: 対象 OS={s}\n", .{target.os});
            } else {
                try stdout.print("  命令 OS 条件: 対象 OS=不明（lock が陳腐なため未評価）\n", .{});
            }
            for (command_report.conditions) |condition| {
                try stdout.print("    {s}: {s}（{s}）\n", .{
                    condition.package_key,
                    condition.condition,
                    switch (condition.availability) {
                        .available => "利用可能",
                        .unavailable => "利用不可",
                        .unknown => "不明",
                    },
                });
            }
        }
        // namespace alias の診断（空・重複・不正文字・予約語・既存 module 衝突）。
        if (command_report.inspected and
            (command_report.alias_count > 0 or command_report.namespace_issues.len > 0 or
                !command_report.namespace_scan_complete))
        {
            try stdout.print("  名前空間: alias {d} 件（問題 {d} 件）", .{
                command_report.alias_count,
                command_report.namespace_issues.len,
            });
            if (!command_report.namespace_scan_complete) {
                try stdout.print("（module 衝突検査は未検査: {s}）", .{
                    command_report.namespace_scan_reason orelse "列挙が不完全です",
                });
            }
            try stdout.print("\n", .{});
            for (command_report.namespace_issues) |issue| {
                try stdout.print("    名前空間 alias: {s} [{s}] {s}\n", .{
                    issue.scope,
                    lnako.package.namespace_check.kindText(issue.kind),
                    issue.detail,
                });
            }
        }
        // plugin 実登録照合の結果（`--load-plugins` 指定時のみ表示）。
        if (registration_report) |*report| {
            try stdout.print("  plugin 実登録照合: {d} 件（照合済み {d} / 不一致 {d}）\n", .{
                report.packages.len,
                project_plugins.matchedPackageCount(report),
                report.mismatchCount(),
            });
            for (report.packages) |*package| {
                if (!package.inspected) {
                    // 未検査は不一致にしないため、状態だけを明示する。
                    try stdout.print("    未検査: {s} ({s})\n", .{ package.package_key, package.status.text() });
                    continue;
                }
                if (package.declared_only.len == 0 and package.registered_only.len == 0 and
                    package.shape_mismatches.len == 0)
                {
                    try stdout.print("    {s}: 一致（{d} 件）\n", .{ package.package_key, package.matched_count });
                    continue;
                }
                try stdout.print("    {s}:\n", .{package.package_key});
                for (package.declared_only) |command| {
                    try stdout.print("      宣言のみ（実登録に無い）: {s}\n", .{command.name});
                }
                for (package.registered_only) |name| {
                    try stdout.print("      実登録のみ（宣言に無い）: {s}\n", .{name});
                }
                for (package.shape_mismatches) |mismatch| {
                    try stdout.print("      {s} 不一致: {s}\n", .{ mismatch.kind.text(), mismatch.name });
                }
            }
        }
        if (command_report.features) |impact| {
            try stdout.print("  feature 影響: 選択=[{s}]\n", .{
                try lnako.package.command_inspect.joinNames(a, impact.selected),
            });
            if (impact.common_roots.len > 0) {
                try stdout.print("    共通依存: {s}\n", .{
                    try lnako.package.command_inspect.joinNames(a, impact.common_roots),
                });
            }
            for (impact.dedicated) |feature| {
                try stdout.print("    専用依存: {s} → {s}", .{
                    feature.name,
                    try lnako.package.command_inspect.joinNames(a, feature.roots),
                });
                if (feature.packages.len > 0) {
                    try stdout.print("（推移: {s}）", .{
                        try lnako.package.command_inspect.joinNames(a, feature.packages),
                    });
                }
                try stdout.print("\n", .{});
            }
        }
        if (needed.items.len > 0) {
            try stdout.print("  必要な操作:", .{});
            for (needed.items) |cmd| try stdout.print(" {s};", .{cmd});
            try stdout.print("\n", .{});
        }
        try stdout.flush();
    }
}

// ---------------------------------------------------------------------------
// cache
// ---------------------------------------------------------------------------

fn runCache(a: Allocator, io: std.Io, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) return failUsage(stderr, "cache: サブコマンドが必要です（dir|clean）\n", .{});
    const verb = args[0];
    var cache_dir: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            cache_dir = try flagValue(args, &index, "cache", "--package-cache-dir", stderr);
        } else {
            return failUsage(stderr, "cache: 不明な引数です: {s}\n", .{argument});
        }
    }
    const default_root = try cache.defaultRoot(a);
    defer if (default_root) |r| a.free(r);
    const root = cache_dir orelse default_root orelse
        return fail(stderr, "cache: キャッシュディレクトリを決定できません（--package-cache-dir を指定してください）\n", .{});
    if (std.mem.eql(u8, verb, "dir")) {
        try stdout.print("{s}\n", .{root});
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, verb, "clean")) {
        var store = cache.Store.open(a, io, root) catch |err| {
            return fail(stderr, "cache: キャッシュを開けません: {s}\n", .{@errorName(err)});
        };
        defer store.deinit();
        var guard = store.lockWait() catch {
            return fail(stderr, "cache: 別の処理がキャッシュを使用中です\n", .{});
        };
        defer guard.unlock();
        const removed = store.cleanAll() catch |err| {
            return fail(stderr, "cache: クリーンに失敗しました: {s}\n", .{@errorName(err)});
        };
        try stderr.print("cache: {d} 個の entry を削除しました\n", .{removed});
        try stderr.flush();
        return;
    }
    return failUsage(stderr, "cache: 不明なサブコマンドです: {s}（dir|clean）\n", .{verb});
}

// ---------------------------------------------------------------------------
// run/test/build 自動準備
// ---------------------------------------------------------------------------

/// 入力ファイル（またはディレクトリ）がプロジェクト配下なら依存準備を
/// 行う。`--locked`/`--offline`/`--no-sync` の禁止事項を守る。
/// プロジェクト外なら何もしない。
pub fn prepareForExecution(
    a: Allocator,
    io: std.Io,
    input: []const u8,
    flags: *const PrepFlags,
    environ_map: ?*const std.process.Environ.Map,
    verb: []const u8,
    stderr: *std.Io.Writer,
) !void {
    // v1 入口は fixture を引数で受けるため、旧 registry/cache 設定は使わない。
    _ = environ_map;
    const start_dir = inputDir(a, io, input) catch return;
    defer a.free(start_dir);
    // --no-sync は読み取り専用のため lock 不要。自動準備は lock と
    // manifest を書き換え得るため、読込前に編集 lock を取る。
    var locked: ?PinnedEditLock = null;
    if (!flags.no_sync) {
        locked = try acquireProjectEditLock(a, io, start_dir, verb, stderr);
    }
    defer if (locked) |*l| l.deinit(a, io);
    // manifest を先に分類し、旧 manifest を旧 loader へ渡さない（Q12）。
    // 旧形式は再作成を案内して拒否し、v1 は依存が無ければ環境なしで受理、
    // 依存があって環境が無ければ fixture 指定の sync を案内する。
    var discovered_root: ?[]const u8 = null;
    defer if (discovered_root) |root| a.free(@constCast(root));
    const project_root: ?[]const u8 = if (locked) |*l| l.root else blk: {
        discovered_root = project.findRoot(a, io, start_dir) catch null;
        break :blk if (discovered_root) |root| root else null;
    };
    if (project_root) |root| {
        const probe_dir: ?*const std.Io.Dir = if (locked) |*l| blk: {
            if (l.root_dir) |*dir| break :blk dir;
            break :blk null;
        } else null;
        var probe = v1_entry.probe(a, io, root, probe_dir) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return fail(stderr, "{s}: nako.toml を読めません: {s}\n", .{ verb, @errorName(err) }),
        };
        defer probe.deinit(a);
        switch (probe) {
            .missing => {},
            .legacy => return fail(stderr, "{s}: {s}: {s}\n", .{ verb, v1_entry.legacy_manifest_message, root }),
            .invalid => |err| return fail(stderr, "{s}: nako.toml が v1 形式として不正です（{s}）: {s}\n", .{ verb, v1_entry.manifestDiagnostic(err), root }),
            .v1 => |*v1| {
                if (v1_runtime.environmentPresent(io, root, a)) {
                    try prepareV1Execution(a, io, root, flags, verb, stderr);
                } else {
                    const needs = v1_entry.needsEnvironment(a, &v1.manifest, verb, .{
                        .profile = flags.profile,
                        .features = flags.features.items,
                        .no_default_features = flags.no_default_features,
                    }) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        error.UnknownProfile => return fail(stderr, "{s}: profile が見つかりません（--profile を指定してください）\n", .{verb}),
                        error.UnknownFeature => return fail(stderr, "{s}: 要求した feature は宣言されていません\n", .{verb}),
                        error.DuplicateDependency => return fail(stderr, "{s}: 同じ Package ID が dependencies と runtime-dependencies に異なる内容で宣言されています\n", .{verb}),
                    };
                    if (needs) return fail(stderr, "{s}: {s}: {s}\n", .{ verb, v1_entry.sync_fixture_guidance, root });
                }
            },
        }
        return;
    }
    // 非プロジェクト: 従来どおり何もしない。
}

/// v1 環境の実行前検証。lock と materialize 済み世代の対応を確認し、
/// 旧 `.nako/environment.json` へのフォールバックは行わない。
/// 現時点では既存環境の検証のみを行い、再生成は `lnako sync --v1-fixture <fixture-dir>`（P10
/// client）に委ねる。自動再生成を接続する場合はここで client pipeline を
/// 呼ぶ。
fn prepareV1Execution(
    a: Allocator,
    io: std.Io,
    project_root: []const u8,
    flags: *const PrepFlags,
    verb: []const u8,
    stderr: *std.Io.Writer,
) !void {
    var environment = v1_runtime.load(a, io, project_root, flags.v1LoadOptions()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.LegacyLock => return fail(stderr, "{s}: 旧形式の nako.lock です。v1 の lock を再作成してください（`lnako sync --v1-fixture <fixture-dir>`）: {s}\n", .{ verb, project_root }),
        error.StaleEnvironment => return fail(stderr, "{s}: v1 環境が nako.lock / materialize と一致しません（`lnako sync --v1-fixture <fixture-dir>` で再生成してください）: {s}\n", .{ verb, project_root }),
        else => return fail(stderr, "{s}: v1 パッケージ環境を検証できません（`lnako sync --v1-fixture <fixture-dir>` で再生成してください）: {s} ({s})\n", .{ verb, project_root, @errorName(err) }),
    };
    if (environment) |*env| {
        defer env.deinit();
        if (flags.no_sync) {
            stderr.print("{s}: v1 パッケージ環境を確認しました（profile: {s}）\n", .{ verb, env.profile }) catch {};
            stderr.flush() catch {};
        }
        return;
    }
    return fail(stderr, "{s}: v1 環境を読み込めません（`lnako sync --v1-fixture <fixture-dir>` を実行してください）: {s}\n", .{ verb, project_root });
}

pub fn inputDir(a: Allocator, io: std.Io, input: []const u8) ![]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, input, .{}) catch {
        const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
        return a.dupe(u8, dir);
    };
    // 実在する入力は symlink の可能性があるため実体へ解決してから扱う。
    // 表記側の dir/親 dir は別 project（または project 外）を指し得る
    // ため、そのまま探索すると誤った lock/環境を準備する（file 入力は
    // リンク先の親、directory 入力はリンク先自身が正しい起点）。
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.Io.Dir.cwd().realPathFile(io, input, &path_buf) catch {
        const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
        return a.dupe(u8, dir);
    };
    if (stat.kind == .directory) return a.dupe(u8, path_buf[0..resolved]);
    const dir = std.fs.path.dirname(path_buf[0..resolved]) orelse return a.dupe(u8, ".");
    return a.dupe(u8, dir);
}

// ---------------------------------------------------------------------------
// ディスパッチ
// ---------------------------------------------------------------------------

pub fn run(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    return runIn(allocator, io, verb, args, ".", environ_map, stdout, stderr);
}

/// `start_dir` を起点にプロジェクトを探索してコマンドを実行する。
/// 公開 CLI の入口で、旧 manifest / 旧 lock は移行案内して拒否する。
/// テストから任意の作業ディレクトリで駆動できるよう分離してある。
pub fn runIn(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    start_dir: []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    return runInMode(allocator, io, verb, args, start_dir, environ_map, .public, stdout, stderr);
}

/// 旧形式専用の内部処理を検証するテスト専用入口。公開 CLI の dispatch
/// からは呼ばず、本番では panic する。旧型・旧 lock の内部回帰テストと、
/// 公開入口の guard テストを混同しないために分離する。
pub fn runInLegacyInternalForTest(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    start_dir: []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (!@import("builtin").is_test) @panic("runInLegacyInternalForTest is test-only");
    return runInMode(allocator, io, verb, args, start_dir, environ_map, .legacy_internal, stdout, stderr);
}

fn runInMode(
    allocator: Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    start_dir: []const u8,
    environ_map: ?*const std.process.Environ.Map,
    mode: EntryMode,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (std.mem.eql(u8, verb, "init")) return init_cmd.runInit(allocator, io, args, start_dir, stderr);
    if (std.mem.eql(u8, verb, "add")) return edit.runAdd(allocator, io, args, start_dir, environ_map, mode, stderr);
    if (std.mem.eql(u8, verb, "remove") or std.mem.eql(u8, verb, "rm")) return edit.runRemove(allocator, io, args, start_dir, environ_map, mode, stderr);
    if (std.mem.eql(u8, verb, "lock")) return runLock(allocator, io, args, start_dir, environ_map, mode, stdout, stderr);
    if (std.mem.eql(u8, verb, "update")) return runUpdate(allocator, io, args, start_dir, environ_map, mode, stderr);
    if (std.mem.eql(u8, verb, "tree")) return runTree(allocator, io, args, start_dir, environ_map, mode, stdout, stderr);
    if (std.mem.eql(u8, verb, "why")) return runWhy(allocator, io, args, start_dir, environ_map, mode, stdout, stderr);
    if (std.mem.eql(u8, verb, "check")) return checkProjectMode(allocator, io, args, start_dir, environ_map, mode, stdout, stderr);
    if (std.mem.eql(u8, verb, "cache")) return runCache(allocator, io, args, stdout, stderr);
    return failUsage(stderr, "不明なプロジェクトコマンドです: {s}\n", .{verb});
}

test {
    _ = @import("project_test.zig");
    _ = @import("project_v1_entry_test.zig");
    _ = @import("v1_entry.zig");
}
