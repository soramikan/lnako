//! プロジェクト依存管理コマンド（`init`/`add`/`remove`/`lock`/`update`/
//! `tree`/`why`/`check`/`cache`）と、`run`/`test`/`build` 前の自動準備。
//!
//! `nako.toml` の編集から依存解決（`nako.lock`）、`.nako` 環境の準備までを
//! 一貫した CLI として提供する。機械可読な結果（JSON）は stdout、診断は
//! stderr へ分離する。

const std = @import("std");
const lnako = @import("lnako");
const edit = @import("project_edit.zig");

const diag = lnako.package.diagnostics;
const project = lnako.package.project;
const manifest_mod = lnako.package.manifest;
const lock_model = lnako.package.lock;
const cache = lnako.package.cache;

const Allocator = std.mem.Allocator;

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

/// `run`/`test`/`build` および lock 系コマンド共通の制御フラグ。
pub const PrepFlags = struct {
    locked: bool = false,
    offline: bool = false,
    no_sync: bool = false,
    profile: ?[]const u8 = null,
    features: std.ArrayList([]const u8) = .empty,
    no_default_features: bool = false,
    registry: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    allow_plaintext_http: bool = false,
    json: bool = false,
    /// `run`/`build --compat-js` の compat 実行。依存解決の ESM 許容と
    /// lock 鮮度入力へ伝える（prep フラグとしては抽出せず呼出し側が
    /// 設定する）。
    compat_js: bool = false,
    /// `build -O` の実効レベル（`"O0"`〜`"O3"`）。依存解決の
    /// optimize-gated 実装選択と lock 鮮度入力へ伝える。null は未指定。
    optimize: ?[]const u8 = null,

    pub fn deinit(self: *PrepFlags, a: Allocator) void {
        self.features.deinit(a);
    }

    pub fn toOptions(self: *const PrepFlags, environ_map: ?*const std.process.Environ.Map) project.PrepareOptions {
        var options = project.PrepareOptions{
            .profile = self.profile,
            .features = self.features.items,
            .no_default_features = self.no_default_features,
            .registry_url = self.registry,
            .cache_root = self.cache_dir,
            // run/test/build・lock 系の要求 runtime は lnako（`lnako sync
            // --runtime` は cli/commands/sync.zig が別途設定する）。
            .requested_runtime = "lnako",
            // engines 照合にこの処理系の version を供給する。未供給だと
            // `engines.nako`/`engines.lnako` 制約が解決へ効かない。
            // `cnako_version` も sync と同じ値を供給する。lock input の
            // version tuple が入口ごとに違うと、`lnako lock` が書いた
            // lock を `lnako sync` が stale 判定して書き戻す往復に
            // なるため、どの入口でも同じ組を記録する。
            .nako_version = lnako.package.semver.Version.parse(project.compat_nako_version) catch null,
            .cnako_version = lnako.package.semver.Version.parse(project.compat_nako_version) catch null,
            .lnako_version = lnako.package.semver.Version.parse(lnako.version) catch null,
            .compat_js = self.compat_js,
            .optimize = self.optimize,
        };
        options.policy.offline = self.offline;
        options.policy.allow_plaintext_http = self.allow_plaintext_http;
        if (options.registry_url == null) {
            if (environ_map) |map| {
                if (map.get("LNAKO_REGISTRY")) |url| options.registry_url = url;
            }
        }
        return options;
    }
};

/// 値を取るフラグの次の引数を値として取り出す。末尾に値が無い場合や、
/// 次の引数が別のオプション（`-` 始まり）なら用法エラーとする。
pub fn flagValue(args: []const []const u8, index: *usize, verb: []const u8, flag: []const u8, stderr: *std.Io.Writer) CliError![]const u8 {
    if (index.* + 1 >= args.len or std.mem.startsWith(u8, args[index.* + 1], "-")) {
        return failUsage(stderr, "{s}: {s} には値が必要です\n", .{ verb, flag });
    }
    index.* += 1;
    return args[index.*];
}

const PrepParseResult = struct { flags: PrepFlags, rest: []const []const u8 };

/// `args` から共通フラグを取り出し、残りの位置引数を返す。
/// 未知オプションは failUsage。
fn parsePrepFlags(a: Allocator, args: []const []const u8, verb: []const u8, stderr: *std.Io.Writer) (CliError || error{OutOfMemory})!PrepParseResult {
    var flags = PrepFlags{};
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            flags.no_sync = true;
        } else if (std.mem.eql(u8, argument, "--profile")) {
            flags.profile = try flagValue(args, &index, verb, "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, verb, "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) try flags.features.append(a, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            flags.registry = try flagValue(args, &index, verb, "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            flags.cache_dir = try flagValue(args, &index, verb, "--package-cache-dir", stderr);
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--json")) {
            flags.json = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "{s}: 不明なオプションです: {s}\n", .{ verb, argument });
        } else {
            try rest.append(a, argument);
        }
    }
    return .{ .flags = flags, .rest = rest.items };
}

/// verb ごとに意味を持つフラグの許可集合。許可外のフラグが指定された
/// 場合は黙って無視せず用法エラーとする。
const FlagMask = struct {
    locked: bool = false,
    offline: bool = false,
    no_sync: bool = false,
    profile: bool = false,
    features: bool = false,
    no_default_features: bool = false,
    registry: bool = false,
    cache_dir: bool = false,
    allow_plaintext_http: bool = false,
    json: bool = false,
};

fn rejectInertFlags(flags: *const PrepFlags, verb: []const u8, comptime allowed: FlagMask, stderr: *std.Io.Writer) CliError!void {
    const bad: ?[]const u8 = if (!allowed.locked and flags.locked)
        "--locked"
    else if (!allowed.offline and flags.offline)
        "--offline"
    else if (!allowed.no_sync and flags.no_sync)
        "--no-sync"
    else if (!allowed.profile and flags.profile != null)
        "--profile"
    else if (!allowed.features and flags.features.items.len > 0)
        "--features"
    else if (!allowed.no_default_features and flags.no_default_features)
        "--no-default-features"
    else if (!allowed.registry and flags.registry != null)
        "--registry"
    else if (!allowed.cache_dir and flags.cache_dir != null)
        "--package-cache-dir"
    else if (!allowed.allow_plaintext_http and flags.allow_plaintext_http)
        "--allow-plaintext-http"
    else if (!allowed.json and flags.json)
        "--json"
    else
        null;
    if (bad) |flag| return failUsage(stderr, "{s}: {s} はこのコマンドでは使えません\n", .{ verb, flag });
}

/// prep 系フラグを `args` から `flags` へ移し、残りの引数配列を返す。
/// 値を取るフラグは値も一緒に消費する。認識しない引数（dncl 系・位置
/// 引数・未知オプション）は残りへ保持し、呼出し側の既存検証に委ねる。
/// `run`/`test`/`build` の自動準備統合用。
/// 値を取るフラグの直後が別のオプション（`-` 始まり）なら値取りこぼし
/// とみなして用法エラーとする（`--profile --dncl` の誤消費を防ぐ）。
pub fn extractPrepFlags(a: Allocator, args: []const []const u8, flags: *PrepFlags, verb: []const u8, stderr: *std.Io.Writer) ![]const []const u8 {
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--locked")) {
            flags.locked = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            flags.offline = true;
        } else if (std.mem.eql(u8, argument, "--no-sync")) {
            flags.no_sync = true;
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            flags.no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            flags.allow_plaintext_http = true;
        } else if (std.mem.eql(u8, argument, "--profile") or
            std.mem.eql(u8, argument, "--features") or
            std.mem.eql(u8, argument, "--registry") or
            std.mem.eql(u8, argument, "--package-cache-dir"))
        {
            const value = try flagValue(args, &index, verb, argument, stderr);
            if (std.mem.eql(u8, argument, "--profile")) {
                flags.profile = value;
            } else if (std.mem.eql(u8, argument, "--features")) {
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |name| {
                    const trimmed = std.mem.trim(u8, name, " ");
                    if (trimmed.len > 0) try flags.features.append(a, trimmed);
                }
            } else if (std.mem.eql(u8, argument, "--registry")) {
                flags.registry = value;
            } else {
                flags.cache_dir = value;
            }
        } else {
            try rest.append(a, argument);
        }
    }
    return rest.items;
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

fn projectErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProjectNotFound => "プロジェクトが見つかりません",
        error.InvalidManifest => "nako.toml が不正です",
        error.InvalidLock => "nako.lock が不正または破損しています",
        error.LockedNotSatisfied => "nako.lock が不足・陳腐のため --locked を満たせません",
        error.MissingEnvironment => ".nako 環境が不足・不一致です（`lnako sync` を実行してください）",
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

fn runLock(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
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

    // manifest 読込〜lock 公開まで同じ編集 lock を保持し、並行する
    // add/remove/sync/自動準備と lock の書き換えを直列化する。
    var guard = try acquireProjectEditLock(a, io, start_dir, "lock", stderr);
    defer if (guard) |*g| g.unlock();
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
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

fn runUpdate(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stderr: *std.Io.Writer) !void {
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

    // lock/update も add/remove と同じ編集 lock で直列化する（manifest
    // 読込〜lock 公開まで）。
    var guard = try acquireProjectEditLock(a, io, start_dir, "update", stderr);
    defer if (guard) |*g| g.unlock();
    var loaded = try loadProjectOrFail(a, io, start_dir, stderr);
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
        // 解決済み public id へ正規化する。dep key 名空間と lock entry の
        // id 名空間が異なる（source 依存は `pkg:<32hex>`、pkg 依存は
        // `public-id` 明示の場合がある）ため、dep key のまま渡すと
        // source 依存の版固定解除・宣言変更許容が効かない。
        try targets.append(a, try resolvedIdForDecl(a, &loaded.manifest, loaded.root, dep_key));
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

/// 宣言 dep key が解決後に持つ lock entry id（public id）を返す。
/// `update` の対象指定を id 名空間へ写像するために使う。npm 依存や
/// 未宣言 key には到達しない前提（呼出し側が宣言集合で検証済み）。
fn resolvedIdForDecl(a: Allocator, manifest: *const manifest_mod.Manifest, root: []const u8, dep_key: []const u8) ![]const u8 {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        if (group.path.get(dep_key)) |dep| {
            return project.publicIdForSourceDecl(a, .{ .path = dep }, root, root);
        }
        if (group.git.get(dep_key)) |dep| {
            return project.publicIdForSourceDecl(a, .{ .git = dep }, root, root);
        }
        if (group.http.get(dep_key)) |dep| {
            return project.publicIdForSourceDecl(a, .{ .http = dep }, root, root);
        }
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

/// `start_dir` からプロジェクトルートを特定し、manifest/lock 編集の
/// 排他 lock（`.nako/edit.lock`）を取得する。非プロジェクトなら null
/// （`loadProjectOrFail`/`discoverAndLoad` の診断に委ねる）。
/// lock を書き込む全ての verb（lock/update/add/remove/sync/自動準備）は
/// manifest 読込の前に呼び、lock 公開まで保持する。
fn acquireProjectEditLock(a: Allocator, io: std.Io, start_dir: []const u8, verb: []const u8, stderr: *std.Io.Writer) !?project.EditLock {
    const root = project.findRoot(a, io, start_dir) catch |err| {
        return fail(stderr, "{s}: プロジェクトルートを探索できません: {s}\n", .{ verb, @errorName(err) });
    } orelse return null;
    defer a.free(root);
    const guard = project.acquireEditLock(a, io, root) catch |err| {
        return fail(stderr, "{s}: 編集ロックを取得できません: {s}\n", .{ verb, @errorName(err) });
    };
    return guard;
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
            const id = try project.publicIdForSourceDecl(a, .{ .path = item.value_ptr.* }, root, root);
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
        }
        var git_it = group.git.iterator();
        while (git_it.next()) |item| {
            const id = try project.publicIdForSourceDecl(a, .{ .git = item.value_ptr.* }, root, root);
            try maps.by_id.put(id, item.key_ptr.*);
            try maps.by_name.put(item.key_ptr.*, id);
            if (item.value_ptr.alias) |alias| try maps.by_name.put(alias, id);
        }
        var http_it = group.http.iterator();
        while (http_it.next()) |item| {
            const id = try project.publicIdForSourceDecl(a, .{ .http = item.value_ptr.* }, root, root);
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

fn runTree(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
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

fn runWhy(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
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
    const id = try project.publicIdForSourceDecl(a, decl, root, root);
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
pub fn checkProject(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const parsed = try parsePrepFlags(a, args, "check", stderr);
    var flags = parsed.flags;
    defer flags.deinit(a);
    if (parsed.rest.len > 0) return failUsage(stderr, "check: 不明な引数です: {s}\n", .{parsed.rest[0]});
    // check は副作用なしの検査コマンド。sync・取得系フラグは意味を持た
    // ないため拒否する。
    try rejectInertFlags(&flags, "check", .{
        .locked = true,
        .profile = true,
        .features = true,
        .no_default_features = true,
        .json = true,
    }, stderr);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const found = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        return failProject(stderr, "check", err, &diagnostics, ".");
    };
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

    if (flags.json) {
        var needed_json: std.ArrayList(u8) = .empty;
        for (needed.items, 0..) |cmd, i| {
            if (i > 0) try needed_json.appendSlice(a, ",");
            try needed_json.appendSlice(a, try std.fmt.allocPrint(a, "\"{s}\"", .{cmd}));
        }
        try stdout.print("{{\"schemaVersion\":1,\"manifest\":\"ok\",\"lock\":\"{s}\",\"environment\":\"{s}\",\"needed\":[{s}]}}\n", .{
            lock_state,
            if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale",
            needed_json.items,
        });
        try stdout.flush();
    } else {
        try stdout.print("プロジェクト: {s}（{s}）\n", .{ project_var.manifest.package.name, project_var.root });
        try stdout.print("  nako.toml: OK\n", .{});
        try stdout.print("  nako.lock: {s}\n", .{lock_state});
        try stdout.print("  .nako 環境: {s}\n", .{if (inspect.environment == null) "missing" else if (inspect.environment_current) "current" else "stale"});
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
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    const start_dir = inputDir(a, io, input) catch return;
    defer a.free(start_dir);
    // --no-sync は読み取り専用のため lock 不要。自動準備は lock と
    // manifest を書き換え得るため、読込前に編集 lock を取る。
    var guard: ?project.EditLock = null;
    if (!flags.no_sync) {
        guard = try acquireProjectEditLock(a, io, start_dir, verb, stderr);
    }
    defer if (guard) |*g| g.unlock();
    // 探索自体の失敗（破損した manifest 等）は黙って実行しない。
    const loaded = project.discoverAndLoad(a, io, start_dir, &diagnostics) catch |err| {
        renderOrFail(&diagnostics, stderr, start_dir);
        return fail(stderr, "{s}: プロジェクトを読み込めません: {s}\n", .{ verb, @errorName(err) });
    };
    const found = loaded orelse return; // 非プロジェクト: 従来動作
    var project_var = found;
    defer project_var.deinit();
    if (diagnostics.errorCount() > 0) {
        renderOrFail(&diagnostics, stderr, project_var.manifest_path);
        return error.Failed;
    }

    var options = flags.toOptions(environ_map);
    // --locked は --no-sync と併用されても必ず検証する（書き込みを伴わ
    // ない静的検査のため sync 禁止と矛盾しない）。
    if (flags.locked) {
        project.verifyLocked(a, io, &project_var, &options, &diagnostics) catch |err| {
            return failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
        };
    }
    if (flags.no_sync) {
        // 自動準備禁止: 既存環境だけを静的検査する。
        try ensureEnvironmentUsable(a, io, &project_var, &options, &diagnostics, verb, stderr);
        return;
    }
    const outcome = project.ensureEnvironment(a, io, &project_var, &options, &diagnostics) catch |err| {
        return failProject(stderr, verb, err, &diagnostics, project_var.manifest_path);
    };
    if (outcome.synced or outcome.lock_wrote) {
        stderr.print("{s}: 依存環境を準備しました（profile: {s}）\n", .{ verb, outcome.profile }) catch {};
        stderr.flush() catch {};
    }
}

/// `--no-sync` 時の静的環境検査。lock が現在の manifest/profile/features/
/// target に対して fresh であること（読み取り専用）と `.nako` の整合を
/// 確認し、不足があれば必要な操作を診断して失敗する。
/// `ensureEnvironment` と同じ profile・runtime 条件で環境を照合する
/// （profile は `loadFreshLock` が manifest から解決した実 profile）。
fn ensureEnvironmentUsable(a: Allocator, io: std.Io, loaded: *project.Project, options: *const project.PrepareOptions, diagnostics: *diag.List, verb: []const u8, stderr: *std.Io.Writer) !void {
    // lock の意味検証と manifest/profile/features/target に対する鮮度検査
    // を書き込みなしで行う（pin hash 不一致もここで検出される）。
    // lock だけを見て env を受理すると manifest 変更後の古い lock+env を
    // そのまま通してしまうため、鮮度検証は省略できない。
    var outcome = project.loadFreshLock(a, io, loaded, options, diagnostics) catch |err| {
        return failProject(stderr, verb, err, diagnostics, loaded.manifest_path);
    };
    defer outcome.deinit();
    var digest: [32]u8 = undefined;
    const has_lock = project.lockDigest(a, io, loaded.root, &digest) catch false;
    const env = project.readEnvironmentInfo(a, io, loaded.root) catch null;
    const env_ok = has_lock and env != null and
        project.environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1 and
        // schema v1 の profile/runtime は必須項目。欠落・型違いの環境は
        // 選択 profile/runtime を証明できないため不一致として拒否する。
        (env.?.profile != null and std.mem.eql(u8, env.?.profile.?, outcome.profile)) and
        (env.?.runtime != null and std.mem.eql(u8, env.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致とする。
        (env.?.generation != null and project.generationExists(io, loaded.root, env.?.generation.?)) and
        // packages 記録・実体の欠落も不一致とする（内容検証）。
        (project.environmentPackagesUsable(a, io, loaded.root, &outcome.lock, outcome.profile) catch false) and
        // metadata-only な mutable path 変更で環境 snapshot が陳腐化した
        // 場合も不一致とする（環境記録の digest と現行 dir を照合）。
        (project.environmentMutablePathsUsable(a, io, loaded.root, env.?, &outcome.lock) catch false);
    if (!env_ok) {
        if (env == null) {
            return fail(stderr, "{s}: .nako 環境がありません（--no-sync のため自動準備しません。`lnako sync` を実行してください）\n", .{verb});
        } else {
            return fail(stderr, "{s}: .nako 環境が nako.lock と一致しません（`lnako sync` で再構築してください）\n", .{verb});
        }
    }
}

fn inputDir(a: Allocator, io: std.Io, input: []const u8) ![]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, input, .{}) catch {
        const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
        return a.dupe(u8, dir);
    };
    if (stat.kind == .directory) return a.dupe(u8, input);
    const dir = std.fs.path.dirname(input) orelse return a.dupe(u8, ".");
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
    if (std.mem.eql(u8, verb, "init")) return edit.runInit(allocator, io, args, start_dir, stderr);
    if (std.mem.eql(u8, verb, "add")) return edit.runAdd(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "remove") or std.mem.eql(u8, verb, "rm")) return edit.runRemove(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "lock")) return runLock(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "update")) return runUpdate(allocator, io, args, start_dir, environ_map, stderr);
    if (std.mem.eql(u8, verb, "tree")) return runTree(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "why")) return runWhy(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "check")) return checkProject(allocator, io, args, start_dir, environ_map, stdout, stderr);
    if (std.mem.eql(u8, verb, "cache")) return runCache(allocator, io, args, stdout, stderr);
    return failUsage(stderr, "不明なプロジェクトコマンドです: {s}\n", .{verb});
}

test {
    _ = @import("project_test.zig");
}
