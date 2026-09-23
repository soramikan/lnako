//! `nako.toml` プロジェクトの検出・読込・依存解決・`nako.lock` 生成・
//! `.nako` 環境準備を担うオーケストレーション層。
//!
//! CLI 層（`cli/commands/project.zig`）から呼ばれ、内部では
//! `resolver`（version 解決）・`provider`/`registry`（取得）・`lock`
//! （lock 生成・鮮度判定）・`sync`（環境構築）を接続する。
//!
//! resolver が扱うのは `dependencies.pkg` の辺だけなので、path/git/http
//! 依存はここで取得し、仮想 package id（`path:<key>` 等）を持つ solver
//! node として解決へ組み込む。これにより source 依存の manifest が持つ
//! `dependencies.pkg` も PubGrub の通常辺として解決される。

const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diagnostics.zig");
const cache = @import("cache.zig");
const features_mod = @import("features.zig");
const fetch = @import("fetch.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const sync_mod = @import("sync.zig");

const Allocator = std.mem.Allocator;

pub const manifest_name = "nako.toml";
pub const lock_name = "nako.lock";

pub const Error = error{
    ProjectNotFound,
    InvalidManifest,
    InvalidLock,
    /// `--locked` で lock が不足・陳腐・schema/resolver 不一致。
    LockedNotSatisfied,
    /// `--no-sync` で環境が不足・lock 不一致。
    MissingEnvironment,
    ResolveFailed,
    DependencyCycle,
    /// pkg 依存があるのに registry base URL が未指定。
    RegistryRequired,
    /// 表現できない依存形態（.npkg 内 path 依存等）。
    UnsupportedDependency,
    UnknownProfile,
    FileSystem,
    OutOfMemory,
    Canceled,
} || fetch.Error || sync_mod.Error;

fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FileSystem,
    };
}

// ---------------------------------------------------------------------------
// プロジェクト検出・読込
// ---------------------------------------------------------------------------

/// `nako.toml` を持つプロジェクト。全メモリは内蔵 arena が所有する。
/// arena はヒープ上に確保する。内部オブジェクト（`manifest.document` の
/// arena 等）の child_allocator が arena 自身を指すため、スタック上の
/// arena を返すと関数 return 後に dangling pointer になる。
pub const Project = struct {
    arena: *std.heap.ArenaAllocator,
    /// プロジェクトルートの絶対 path（末尾 separator なし）。
    root: []const u8,
    manifest_path: []const u8,
    manifest_bytes: []const u8,
    /// `sha256:<64hex>`。`lock.Input.manifest_sha256` と同じ表現。
    manifest_sha256: []const u8,
    manifest: manifest_mod.Manifest,

    pub fn deinit(self: *Project) void {
        self.manifest.deinit();
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// `start_dir` から親 dir へ `nako.toml` を探す。見つかった dir の絶対
/// path を `gpa` で返す。見つからなければ null。`start_dir` は存在する
/// dir を想定（存在しない場合は FileSystem 相当の error を返す）。
pub fn findRoot(gpa: Allocator, io: std.Io, start_dir: []const u8) Error!?[]const u8 {
    var dir = try absPath(gpa, io, start_dir);
    defer gpa.free(dir);
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir, manifest_name });
        defer gpa.free(candidate);
        if (fileExists(io, candidate)) {
            return try gpa.dupe(u8, dir);
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        const next = try gpa.dupe(u8, parent);
        gpa.free(dir);
        dir = next;
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 相対 path を cwd 基準の絶対 path へ正規化する。実在しない成分を含んで
/// いてもよい（lexical 正規化のみ）。
fn absPath(gpa: Allocator, io: std.Io, path: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(gpa, &.{path}) catch return error.FileSystem;
    }
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch |err| return mapFs(err);
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path }) catch return error.FileSystem;
}

/// `root`（`nako.toml` を持つ dir）のプロジェクトを読み込む。
pub fn load(gpa: Allocator, io: std.Io, root: []const u8, diagnostics: *diag.List) Error!Project {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const a = arena.allocator();

    const root_abs = try absPath(a, io, root);
    const manifest_path = try std.fs.path.join(a, &.{ root_abs, manifest_name });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.ProjectNotFound,
        else => return mapFs(err),
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha_text = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});

    const errors_before = diagnostics.errorCount();
    var manifest = manifest_mod.parse(a, bytes, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    errdefer manifest.deinit();
    // errorCount は累積のため、この parse が追加した分だけを見る。
    if (diagnostics.errorCount() > errors_before) return error.InvalidManifest;

    return .{
        .arena = arena,
        .root = root_abs,
        .manifest_path = manifest_path,
        .manifest_bytes = bytes,
        .manifest_sha256 = sha_text,
        .manifest = manifest,
    };
}

/// `start_dir` から `nako.toml` を遡ってプロジェクトを読み込む。
/// 見つからなければ null。
pub fn discoverAndLoad(gpa: Allocator, io: std.Io, start_dir: []const u8, diagnostics: *diag.List) Error!?Project {
    const root = (try findRoot(gpa, io, start_dir)) orelse return null;
    defer gpa.free(root);
    return try load(gpa, io, root, diagnostics);
}

// ---------------------------------------------------------------------------
// profile 選択・target
// ---------------------------------------------------------------------------

/// 実行環境に対応する既定 target（manifest が profiles を持たない場合の
/// synthesized default に使う）。
pub fn hostTarget() lock_model.Target {
    return .{
        .os = switch (builtin.os.tag) {
            .macos => "macos",
            .windows => "windows",
            else => "linux",
        },
        .cpu = switch (builtin.cpu.arch) {
            .aarch64 => "aarch64",
            .x86_64 => "x86_64",
            .arm => "arm",
            .wasm32 => "wasm32",
            else => "x86_64",
        },
        .abi = switch (builtin.os.tag) {
            .windows => "msvc",
            else => switch (builtin.abi) {
                .musl => "musl",
                else => "gnu",
            },
        },
    };
}

/// 解決対象となる profile 群。manifest の `[profiles]` が無ければ
/// 実行環境 target を持つ `default` を合成する。
pub fn profilesOf(gpa: Allocator, project: *const Project) Error![]const lock_model.NamedProfile {
    var list: std.ArrayList(lock_model.NamedProfile) = .empty;
    if (project.manifest.profiles.count() == 0) {
        const host = hostTarget();
        try list.append(gpa, .{
            .name = try gpa.dupe(u8, "default"),
            .record = .{
                .runtime = try gpa.dupe(u8, "lnako"),
                .os = host.os,
                .cpu = host.cpu,
                .abi = host.abi,
            },
        });
        return list.items;
    }
    var iterator = project.manifest.profiles.iterator();
    while (iterator.next()) |entry| {
        const p = entry.value_ptr;
        try list.append(gpa, .{
            .name = entry.key_ptr.*,
            .record = .{
                .runtime = p.runtime,
                .os = p.os,
                .cpu = p.cpu,
                .abi = p.abi,
                .compat_js = p.compat_js,
                .optimize = p.optimize,
            },
        });
    }
    std.mem.sort(lock_model.NamedProfile, list.items, {}, struct {
        fn lt(_: void, a: lock_model.NamedProfile, b: lock_model.NamedProfile) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return list.items;
}

/// profile 名を決定する。`requested` が null なら `default`（無ければ
/// 唯一の profile）を選ぶ。
pub fn selectProfile(profiles: []const lock_model.NamedProfile, requested: ?[]const u8, diagnostics: *diag.List) Error![]const u8 {
    if (requested) |name| {
        for (profiles) |profile| {
            if (std.mem.eql(u8, profile.name, name)) return name;
        }
        try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, name, .{}, "profile \"{s}\" is not declared in nako.toml", .{name});
        return error.UnknownProfile;
    }
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, "default")) return profile.name;
    }
    if (profiles.len == 1) return profiles[0].name;
    try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, "default", .{}, "manifest has no \"default\" profile; select one with --profile", .{});
    return error.UnknownProfile;
}

fn recordOf(profiles: []const lock_model.NamedProfile, name: []const u8) ?lock_model.ProfileRecord {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile.record;
    }
    return null;
}

/// 解決 runtime。`any`/`common` は lnako として解決し、provider 側で
/// source 実装のみを許容する（共有 profile の package 集合は両処理系で
/// 動く実装に限定されるべきため）。
fn resolveRuntime(record: lock_model.ProfileRecord) []const u8 {
    const runtime = record.runtime orelse "any";
    if (std.mem.eql(u8, runtime, "lnako") or std.mem.eql(u8, runtime, "cnako")) return runtime;
    return "lnako";
}

/// `any`/`common` profile は両処理系で動く source 実装のみ許容する。
fn sourceOnly(record: lock_model.ProfileRecord) bool {
    const runtime = record.runtime orelse "any";
    return !(std.mem.eql(u8, runtime, "lnako") or std.mem.eql(u8, runtime, "cnako"));
}

fn resolveTarget(record: lock_model.ProfileRecord, opts: *const PrepareOptions) resolver.Target {
    return .{
        .runtime = resolveRuntime(record),
        .os = record.os,
        .cpu = record.cpu,
        .abi = record.abi,
        .os_version = opts.os_version,
        .compat_js = record.compat_js orelse false,
        .optimize = record.optimize orelse "O0",
        .nako_version = opts.nako_version,
        .cnako_version = opts.cnako_version,
        .lnako_version = opts.lnako_version,
    };
}

// ---------------------------------------------------------------------------
// feature 展開・依存 gate
// ---------------------------------------------------------------------------

/// root manifest の feature 要求を展開する。`expanded.features` のキー集合
/// が lock `input.features` に記録される。失敗は E027/E028 診断付きで
/// `ResolveFailed`。
fn expandRootFeatures(
    gpa: Allocator,
    manifest: *const manifest_mod.Manifest,
    requested: []const []const u8,
    use_default: bool,
    diagnostics: *diag.List,
) Error!features_mod.Expanded {
    var aliases = manifest.dependencyAliases(gpa) catch return error.OutOfMemory;
    defer aliases.deinit();
    var offender: ?[]const u8 = null;
    return features_mod.expand(gpa, &manifest.features, requested, use_default, &aliases, &offender) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FeatureCycle => {
            try diagnostics.addFmt(diag.E027_FEATURE_CYCLE, .err, offender orelse "", .{}, "feature cycle involving \"{s}\"", .{offender orelse ""});
            return error.ResolveFailed;
        },
        error.UnknownFeature => {
            try diagnostics.addFmt(diag.E028_UNKNOWN_FEATURE, .err, offender orelse "", .{}, "unknown feature \"{s}\"", .{offender orelse ""});
            return error.ResolveFailed;
        },
    };
}

/// feature 定義から参照される依存 alias 名（= 無効化可能な gated 依存の
/// 名前空間）を集める。`item` が定義済み feature 名のものは feature 参照
/// なので対象外。
fn gatedDepNames(gpa: Allocator, manifest: *const manifest_mod.Manifest) Error!std.StringHashMap(void) {
    var gated = std.StringHashMap(void).init(gpa);
    errdefer gated.deinit();
    var iterator = manifest.features.iterator();
    while (iterator.next()) |entry| {
        for (entry.value_ptr.items) |item| {
            if (manifest.features.contains(item)) continue;
            try gated.put(item, {});
        }
    }
    return gated;
}

fn depIsGated(gated: *const std.StringHashMap(void), name: []const u8, alias: ?[]const u8) bool {
    if (gated.contains(name)) return true;
    if (alias) |a| return gated.contains(a);
    return false;
}

fn depIsActivated(aliases: *const std.StringHashMap(void), name: []const u8, alias: ?[]const u8) bool {
    if (aliases.contains(name)) return true;
    if (alias) |a| return aliases.contains(a);
    return false;
}

/// 展開済み feature 名（昇順・重複除去）。`lock.Input.features` の記録用。
fn expandedFeatureNames(gpa: Allocator, expanded: *const features_mod.Expanded) Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var iterator = expanded.features.keyIterator();
    while (iterator.next()) |key| try list.append(gpa, key.*);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return list.items;
}

// ---------------------------------------------------------------------------
// source 依存（path/git/http）の取得 closure
// ---------------------------------------------------------------------------

const LocalKind = enum { path, git, http };

/// 取得済みの source 依存。仮想 package id `path:<key>` 等で solver node
/// として解決に参加し、lock entry の source/artifact もここから作る。
const LocalPackage = struct {
    id_text: []const u8,
    /// lock に記録する `pkg:<32hex>` public id。宣言キーから決定論的に
    /// 派生させ、同一宣言の版更新では id が変わらないようにする。
    public_id: []const u8,
    dep_key: []const u8,
    kind: LocalKind,
    /// lock に記録する source identity（path は project 基準へ正規化済み）。
    source: lock_model.Source,
    /// dep manifest の package.name。manifest が無い取得（raw http）は dep key。
    package_name: []const u8,
    version_text: []const u8,
    manifest: ?manifest_mod.Manifest,
    artifact: lock_model.Artifact,
    /// この dep 自身が宣言する source 依存の仮想 id（lock `dependencies` へ追加）。
    child_ids: []const resolver.PackageId,
    /// この dep manifest が pkg 依存を持つか（registry 必要性の判定用）。
    needs_registry: bool = false,
};

const DepWork = struct {
    kind: LocalKind,
    /// 依存宣言。union で group ごとの構造体を保持する。
    path_dep: ?manifest_mod.PathDependency = null,
    git_dep: ?manifest_mod.GitDependency = null,
    http_dep: ?manifest_mod.HttpDependency = null,
    /// path 解決・lock source 正規化の基準 dir。null は http 内 package 等
    /// ファイル位置を持たない宣言元。
    base_dir: ?[]const u8,
};

/// 宣言された source 依存。virtual id / public id 導出の入力。
pub const SourceDecl = union(enum) {
    path: manifest_mod.PathDependency,
    git: manifest_mod.GitDependency,
    http: manifest_mod.HttpDependency,
};

/// dep の宣言 path を id 用に正規化する。`base_dir`（宣言 manifest の
/// dir）基準で解決し、project 配下なら project 相対・外なら絶対 path
/// へ揃える。`./deps/a` と `deps/a` のような綴り差や、異なる親 manifest
/// からの宣言が同一 dir を指す場合に同じ identity へ集約される。
fn canonicalPathForId(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    const abs = if (provider.isAbsoluteDepPath(declared))
        std.fs.path.resolve(gpa, &.{declared}) catch return error.FileSystem
    else
        std.fs.path.resolve(gpa, &.{ base_dir orelse project_root, declared }) catch return error.FileSystem;
    errdefer gpa.free(abs);
    const root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    defer gpa.free(root);
    if (std.mem.startsWith(u8, abs, root) and abs.len > root.len and
        (abs[root.len] == '/' or abs[root.len] == std.fs.path.sep))
    {
        const rel = try gpa.dupe(u8, abs[root.len + 1 ..]);
        gpa.free(abs);
        return rel;
    }
    return abs;
}

/// source 宣言の正規化 identity（virtual id）。宣言キーではなく解決済み
/// source identity から導くため、異なる親 manifest が同じローカル名で
/// 別 source を宣言しても衝突せず、同一 source を指す宣言は同じ
/// package に集約される（推移的 dep key の名前空間分離）。
fn virtualIdForDecl(gpa: Allocator, decl: SourceDecl, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    const identity_source: lock_model.Source = switch (decl) {
        .path => |dep| .{
            .kind = .path,
            .path = try canonicalPathForId(gpa, dep.path, base_dir, project_root),
        },
        .git => |dep| .{ .kind = .git, .url = dep.url, .commit = dep.commit, .path = dep.path },
        .http => |dep| .{ .kind = .http, .url = dep.url, .hash = dep.hash },
    };
    return provider.identityText(gpa, identity_source);
}

fn virtualIdForWork(gpa: Allocator, work: DepWork, project_root: []const u8) Error![]const u8 {
    const decl: SourceDecl = switch (work.kind) {
        .path => .{ .path = work.path_dep.? },
        .git => .{ .git = work.git_dep.? },
        .http => .{ .http = work.http_dep.? },
    };
    return virtualIdForDecl(gpa, decl, work.base_dir, project_root);
}

/// virtual id（source identity）から `pkg:<32hex>` public id を派生する。
fn publicIdFor(gpa: Allocator, id_text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id_text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "pkg:{s}", .{hex[0..32]});
}

/// 宣言 source から lock 内の public id を導出する。`tree`/`why` が
/// 宣言 dep key と解決済み package を対応付けるために使う。
/// `base_dir` は宣言 manifest の dir（root 直下の宣言は project_root）。
pub fn publicIdForSourceDecl(gpa: Allocator, decl: SourceDecl, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    const id_text = try virtualIdForDecl(gpa, decl, base_dir, project_root);
    return publicIdFor(gpa, id_text);
}

fn isVirtualId(id_text: []const u8) bool {
    return std.mem.startsWith(u8, id_text, "path:") or
        std.mem.startsWith(u8, id_text, "git:") or
        std.mem.startsWith(u8, id_text, "http:");
}

/// dep の宣言 path を lock 記録用に正規化する。宣言が `base_dir` 相対の
/// 場合（推移的 path 依存）は project 相対または絶対 path へ解決する。
/// root 直下の宣言は `base_dir == project_root` なので宣言値をそのまま返す。
fn normalizePathSource(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    if (base_dir == null or provider.isAbsoluteDepPath(declared)) return declared;
    const root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    const base = std.fs.path.resolve(gpa, &.{base_dir.?}) catch return error.FileSystem;
    if (std.mem.eql(u8, root, base)) return declared;
    const joined = std.fs.path.resolve(gpa, &.{ base, declared }) catch return error.FileSystem;
    if (std.mem.startsWith(u8, joined, root) and joined.len > root.len and
        (joined[root.len] == '/' or joined[root.len] == std.fs.path.sep))
    {
        return joined[root.len + 1 ..];
    }
    return joined;
}

/// 解決に必要な git checkout dir。cache を必要なときだけ開く。
fn gitCheckoutDir(gpa: Allocator, io: std.Io, ctx: *ResolveContext, dep: manifest_mod.GitDependency) Error![]const u8 {
    if (ctx.cache_store == null) {
        const root = if (ctx.opts.cache_root) |root|
            try gpa.dupe(u8, root)
        else if (try cache.defaultRoot(gpa)) |root|
            root
        else
            try std.fs.path.join(gpa, &.{ ctx.project_root, ".nako", "cache" });
        ctx.cache_store = cache.Store.open(ctx.gpa, io, root) catch |err| return mapFs(err);
        // checkout dir を変異させる（clone/fetch/checkout）間は共有 cache
        // の OS lock を保持し、並行する lock/update の解決と直列化する。
        // sync 側が既に取っている契約と同じにする。
        ctx.cache_guard = ctx.cache_store.?.lockWait() catch |err| return mapFs(err);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("git");
    for ([_][]const u8{ dep.url, dep.path orelse "" }) |part| {
        hasher.update(&[_]u8{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const key = try std.fmt.allocPrint(gpa, "git-{s}", .{hex[0..16]});
    const dir = (try ctx.cache_store.?.checkoutPath(gpa, key)) orelse
        return error.FileSystem;
    return dir;
}

/// 既存 lock から public id（`pkg:<32hex>`）の package entry の source を
/// 探す（git の commit 固定・declared-vs-locked source 衝突検査用）。
/// 仮想 id（`git:<key>` 等）ではなく lock 記録上の public id で引く。
fn lockedSourceFor(existing: ?*const lock_model.Lock, public_id: []const u8) ?lock_model.Source {
    const lock = existing orelse return null;
    for (lock.packages) |*entry| {
        if (std.mem.eql(u8, entry.id, public_id)) return entry.source;
    }
    for (lock.profile_packages) |profile| {
        for (profile.packages) |*entry| {
            if (std.mem.eql(u8, entry.id, public_id)) return entry.source;
        }
    }
    return null;
}

/// `dep_name`（dep key）が明示的な update 対象か。update 対象の source
/// 宣言変更は lock との衝突ではなく意図した更新として許容する。
fn isUpdateTarget(opts: *const PrepareOptions, dep_name: []const u8) bool {
    if (opts.update_all) return true;
    for (opts.update_targets) |target| {
        if (std.mem.eql(u8, target, dep_name)) return true;
    }
    return false;
}

/// session arena 上の `Source` を outcome arena へ複製する。lock に記録
/// される文字列は session より長生きする必要があるため。
fn copySource(a: Allocator, source: lock_model.Source) Error!lock_model.Source {
    return .{
        .kind = source.kind,
        .url = if (source.url) |v| try a.dupe(u8, v) else null,
        .hash = if (source.hash) |v| try a.dupe(u8, v) else null,
        .commit = if (source.commit) |v| try a.dupe(u8, v) else null,
        .path = if (source.path) |v| try a.dupe(u8, v) else null,
        .mutable = source.mutable,
    };
}

const ResolveContext = struct {
    gpa: Allocator,
    io: std.Io,
    session: *fetch.Session,
    project_root: []const u8,
    opts: *const PrepareOptions,
    existing_lock: ?*const lock_model.Lock,
    locals: std.StringHashMap(*LocalPackage),
    cache_store: ?cache.Store = null,
    /// git checkout を共有 cache 内で変異させる間の排他 guard。
    cache_guard: ?cache.LockGuard = null,
    needs_registry: bool = false,
    diagnostics: *diag.List,

    fn deinit(self: *ResolveContext) void {
        if (self.cache_guard) |*guard| guard.unlock();
        if (self.cache_store) |*store| store.deinit();
    }
};

/// 依存 group 内の source 依存を work queue へ追加する。feature で gated
/// かつ未活性のものは除く。
fn pushGroupDeps(
    gpa: Allocator,
    queue: *std.ArrayList(DepWork),
    group: *const manifest_mod.DependencyGroup,
    gated: *const std.StringHashMap(void),
    activated: *const std.StringHashMap(void),
    base_dir: ?[]const u8,
) Error!void {
    var path_it = group.path.iterator();
    while (path_it.next()) |entry| {
        const dep = entry.value_ptr.*;
        if (depIsGated(gated, dep.name, null) and !depIsActivated(activated, dep.name, null)) continue;
        try queue.append(gpa, .{ .kind = .path, .path_dep = dep, .base_dir = base_dir });
    }
    var git_it = group.git.iterator();
    while (git_it.next()) |entry| {
        const dep = entry.value_ptr.*;
        if (depIsGated(gated, dep.name, dep.alias) and !depIsActivated(activated, dep.name, dep.alias)) continue;
        try queue.append(gpa, .{ .kind = .git, .git_dep = dep, .base_dir = base_dir });
    }
    var http_it = group.http.iterator();
    while (http_it.next()) |entry| {
        const dep = entry.value_ptr.*;
        if (depIsGated(gated, dep.name, dep.alias) and !depIsActivated(activated, dep.name, dep.alias)) continue;
        try queue.append(gpa, .{ .kind = .http, .http_dep = dep, .base_dir = base_dir });
    }
}

/// manifest 内 package が持つ依存のうち pkg 依存が1つでもあれば true。
fn hasPkgDeps(manifest: *const manifest_mod.Manifest) bool {
    var it = manifest.dependencies.pkg.iterator();
    return it.next() != null;
}

/// source 依存の取得 closure を構築する。root manifest の依存（通常・dev）
/// から開始し、取得した dep manifest の source 依存を推移的にたどる。
/// feature gate は宣言元 manifest の有効 feature（依存側は default のみ）
/// で評価する。
fn collectLocals(ctx: *ResolveContext, root: *const manifest_mod.Manifest, activated_root: *const std.StringHashMap(void)) Error!void {
    const gpa = ctx.gpa;
    var queue: std.ArrayList(DepWork) = .empty;
    var gated_root = try gatedDepNames(gpa, root);
    defer gated_root.deinit();
    try pushGroupDeps(gpa, &queue, &root.dependencies, &gated_root, activated_root, ctx.project_root);
    try pushGroupDeps(gpa, &queue, &root.dev_dependencies, &gated_root, activated_root, ctx.project_root);

    while (queue.items.len > 0) {
        const work = queue.pop().?;
        const dep_name = switch (work.kind) {
            .path => work.path_dep.?.name,
            .git => work.git_dep.?.name,
            .http => work.http_dep.?.name,
        };
        // virtual id は宣言キーでなく正規化済み source identity。同名 dep
        // key を別 source に割り当てる推移的宣言は別 package として解決
        // され、同一 source は同じ id に集約される（E012 は同一 id に
        // mutable 等の矛盾する宣言が来た場合のみ）。
        const id_text = try virtualIdForWork(gpa, work, ctx.project_root);

        if (ctx.locals.get(id_text)) |existing| {
            // 再訪問（diamond・cycle）: 同一 source identity への再宣言
            // なら既存 local を再利用する。id は source identity 由来な
            // のでここに来る宣言の source は一致済みで、残る差分（path
            // の mutable フラグ等）だけ比較する。再取得を伴わないため
            // cycle でも有限に止まる。
            if (!try declaredSourceMatches(ctx, existing, work)) {
                try ctx.diagnostics.addFmt(diag.E012_ALIAS_COLLISION, .err, dep_name, .{}, "dependency \"{s}\" resolves to different sources", .{dep_name});
                return error.ResolveFailed;
            }
            continue;
        }

        var local = LocalPackage{
            .id_text = id_text,
            .public_id = try publicIdFor(gpa, id_text),
            // 推移的依存では宣言文字列が session arena 由来のため複製する。
            .dep_key = try gpa.dupe(u8, dep_name),
            .kind = work.kind,
            .source = undefined,
            .package_name = try gpa.dupe(u8, dep_name),
            .version_text = "0.0.0",
            .manifest = null,
            .artifact = .{ .key = "source", .kind = "source" },
            .child_ids = &.{},
        };

        var child_base_dir: ?[]const u8 = null;
        switch (work.kind) {
            .path => {
                const dep = work.path_dep.?;
                const acquired = try provider.acquirePath(ctx.session, dep, work.base_dir.?);
                const normalized = try normalizePathSource(gpa, dep.path, work.base_dir, ctx.project_root);
                local.source = .{ .kind = .path, .path = normalized, .mutable = dep.mutable };
                local.manifest = acquired.manifest;
                // path 依存の manifest dir が推移的依存の基準 dir。
                child_base_dir = if (provider.isAbsoluteDepPath(dep.path))
                    try gpa.dupe(u8, dep.path)
                else
                    try std.fs.path.join(gpa, &.{ work.base_dir.?, dep.path });
                // `mutable = false` は tree 内容を hash pin する（spec §3.4.3）。
                // 後の内容変更は lock の鮮度判定・sync 検証で検出される。
                if (!dep.mutable) {
                    const digest = cache.digestTree(ctx.io, gpa, child_base_dir.?) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return ctx.session.fail(.invalid_source, .package, dep_name, "cannot hash path dependency \"{s}\" tree: {s}", .{ dep_name, @errorName(err) }),
                    };
                    local.artifact.sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
                }
            },
            .git => {
                const dep = work.git_dep.?;
                const checkout = try gitCheckoutDir(gpa, ctx.io, ctx, dep);
                const locked = lockedSourceFor(ctx.existing_lock, local.public_id);
                if (locked) |locked_source| {
                    // dep key が同じまま url/commit/subdir が変わった宣言は
                    // 別 source への暗黙切替として衝突とする。明示的な
                    // update 対象は宣言変更を許容する。
                    if (!isUpdateTarget(ctx.opts, dep_name)) {
                        try provider.checkLockedSource(ctx.session, .{
                            .kind = .git,
                            .url = dep.url,
                            .commit = dep.commit,
                            .path = dep.path,
                        }, locked_source, dep_name);
                    }
                }
                const acquired = try provider.acquireGit(ctx.session, dep, checkout, locked);
                local.source = try copySource(gpa, acquired.source);
                local.manifest = acquired.manifest;
                // git 内 package の git/http 依存は取得できるが、path 依存は
                // lock が project 相対で表現できないため後段で拒否する。
                child_base_dir = if (dep.path) |sub|
                    try std.fs.path.join(gpa, &.{ checkout, sub })
                else
                    checkout;
            },
            .http => {
                const dep = work.http_dep.?;
                if (lockedSourceFor(ctx.existing_lock, local.public_id)) |locked_source| {
                    if (!isUpdateTarget(ctx.opts, dep_name)) {
                        try provider.checkLockedSource(ctx.session, .{
                            .kind = .http,
                            .url = dep.url,
                            .hash = dep.hash,
                        }, locked_source, dep_name);
                    }
                }
                const acquired = try provider.acquireHttp(ctx.session, dep);
                local.source = try copySource(gpa, acquired.source);
                local.manifest = acquired.manifest;
                if (acquired.artifact_sha256) |sha| {
                    local.artifact = .{
                        .key = "source",
                        .kind = "source",
                        .type = if (acquired.artifact_type) |t| try gpa.dupe(u8, t) else null,
                        .sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{sha}),
                        .url = try gpa.dupe(u8, dep.url),
                    };
                }
            },
        }

        if (local.manifest) |*dep_manifest| {
            local.package_name = try gpa.dupe(u8, dep_manifest.package.name);
            local.version_text = try std.fmt.allocPrint(gpa, "{f}", .{dep_manifest.package.version});
            if (hasPkgDeps(dep_manifest)) local.needs_registry = true;

            // 依存側 manifest の source 依存を default feature 展開で評価し
            // closure に追加する（依存側に features 指定口はないため default
            // 展開のみ。dev-dependencies は対象外）。
            var dep_aliases = dep_manifest.dependencyAliases(gpa) catch return error.OutOfMemory;
            var gated = try gatedDepNames(gpa, dep_manifest);
            defer gated.deinit();
            var offender: ?[]const u8 = null;
            var expanded = features_mod.expand(gpa, &dep_manifest.features, &.{}, true, &dep_aliases, &offender) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try ctx.diagnostics.addFmt(diag.E027_FEATURE_CYCLE, .err, dep_name, .{}, "invalid feature graph in dependency \"{s}\"", .{dep_name});
                    return error.ResolveFailed;
                },
            };
            var children: std.ArrayList(resolver.PackageId) = .empty;
            var child_queue: std.ArrayList(DepWork) = .empty;
            try pushGroupDeps(gpa, &child_queue, &dep_manifest.dependencies, &gated, &expanded.dependency_aliases, child_base_dir);
            for (child_queue.items) |child| {
                // .npkg（http 由来）内の path 依存は lock が project 相対で
                // 表現できないため拒否する。
                if (child.kind == .path and work.kind == .http) {
                    return ctx.session.fail(.invalid_source, .package, dep_name, "http dependency \"{s}\" declares a path dependency, which cannot be locked", .{dep_name});
                }
                // git 由来 package 内の path 依存は checkout 内に留まる場合
                // だけ lock 表現できる。簡潔さのため現状は拒否する。
                if (child.kind == .path and work.kind == .git) {
                    return ctx.session.fail(.invalid_source, .package, dep_name, "git dependency \"{s}\" declares a path dependency, which cannot be locked", .{dep_name});
                }
                const child_id = try virtualIdForWork(gpa, child, ctx.project_root);
                try children.append(gpa, .{ .pkg = child_id });
                try queue.append(gpa, child);
            }
            local.child_ids = children.items;
        }

        const entry = try gpa.create(LocalPackage);
        entry.* = local;
        try ctx.locals.put(id_text, entry);
        if (local.needs_registry) ctx.needs_registry = true;
    }

    try detectLocalCycles(gpa, ctx);
}

/// 再訪問した dep の宣言 source が既存 local と一致するかを、取得を伴わず
/// 宣言値から比較する。path は解決後の絶対 path、git は url+subdir、
/// http は url(+hash) で比較する。
fn declaredSourceMatches(ctx: *ResolveContext, existing: *const LocalPackage, work: DepWork) Error!bool {
    const gpa = ctx.gpa;
    const source = existing.source;
    switch (work.kind) {
        .path => {
            const dep = work.path_dep.?;
            if (source.kind != .path) return false;
            // 記録形式が宣言位置で異なるため（root 直下は宣言値、推移的は
            // project 相対/絶対へ正規化）、解決後の絶対 path で比較する。
            const stored = source.path orelse return false;
            const stored_abs = if (provider.isAbsoluteDepPath(stored))
                std.fs.path.resolve(gpa, &.{stored}) catch return error.FileSystem
            else
                std.fs.path.resolve(gpa, &.{ ctx.project_root, stored }) catch return error.FileSystem;
            const revisit_abs = if (provider.isAbsoluteDepPath(dep.path))
                std.fs.path.resolve(gpa, &.{dep.path}) catch return error.FileSystem
            else
                std.fs.path.resolve(gpa, &.{ work.base_dir orelse ctx.project_root, dep.path }) catch return error.FileSystem;
            return std.mem.eql(u8, stored_abs, revisit_abs) and
                (source.mutable orelse false) == dep.mutable;
        },
        .git => {
            const dep = work.git_dep.?;
            if (source.kind != .git or !optEql(source.url, dep.url) or !optEql(source.path, dep.path)) return false;
            // 記録 commit は完全 SHA、宣言は prefix（[0-9a-f]{7,40}）の
            // ため前方一致で比較する（acquireGit の pin 判定と同じ契約）。
            const stored_commit = source.commit orelse return false;
            return std.mem.startsWith(u8, stored_commit, dep.commit);
        },
        .http => {
            const dep = work.http_dep.?;
            return source.kind == .http and
                optEql(source.url, dep.url) and
                optEql(source.hash, dep.hash);
        },
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// locals の子辺 graph 上で依存 cycle を検出する。path 依存同士の相互
/// 参照等は solver node に到達しないためここで E004 とする。
fn detectLocalCycles(gpa: Allocator, ctx: *ResolveContext) Error!void {
    // 1=gray（探索中）/2=black（完了）
    var state = std.StringHashMap(u8).init(gpa);
    defer state.deinit();
    const Frame = struct { id: []const u8, next: usize };
    var frames: std.ArrayList(Frame) = .empty;

    var it = ctx.locals.iterator();
    while (it.next()) |entry| {
        if (state.contains(entry.key_ptr.*)) continue;
        try state.put(entry.key_ptr.*, 1);
        frames.clearRetainingCapacity();
        try frames.append(gpa, .{ .id = entry.key_ptr.*, .next = 0 });
        while (frames.items.len > 0) {
            const top = &frames.items[frames.items.len - 1];
            const local = ctx.locals.get(top.id) orelse {
                _ = frames.pop();
                continue;
            };
            if (top.next >= local.child_ids.len) {
                try state.put(top.id, 2);
                _ = frames.pop();
                continue;
            }
            const child_text = try std.fmt.allocPrint(gpa, "{f}", .{local.child_ids[top.next]});
            top.next += 1;
            if (state.get(child_text)) |s| {
                if (s == 1) {
                    // 後退辺 = cycle。frames 上の当該 node からの経路を出す。
                    var start: usize = 0;
                    for (frames.items, 0..) |f, i| {
                        if (std.mem.eql(u8, f.id, child_text)) start = i;
                    }
                    var message: std.ArrayList(u8) = .empty;
                    for (frames.items[start..], 0..) |f, i| {
                        if (i > 0) try message.appendSlice(gpa, " -> ");
                        try message.appendSlice(gpa, f.id);
                    }
                    try message.appendSlice(gpa, " -> ");
                    try message.appendSlice(gpa, child_text);
                    try ctx.diagnostics.addFmt(diag.E004_DEPENDENCY_CYCLE, .err, child_text, .{}, "dependency cycle: {s}", .{message.items});
                    return error.DependencyCycle;
                }
                continue;
            }
            try state.put(child_text, 1);
            try frames.append(gpa, .{ .id = child_text, .next = 0 });
        }
    }
}

// ---------------------------------------------------------------------------
// composite provider / details source
// ---------------------------------------------------------------------------

const Composite = struct {
    ctx: *ResolveContext,
    registry: ?*registry.StaticRegistry,
    /// 解決対象 profile で source 実装のみ許容するか（any/common）。
    source_only: bool,
    locked_index: ?*const lock_mod.LockedIndex,
    /// `metaFromManifest` 用の profile target。
    target: resolver.Target,

    fn provider(self: *Composite) resolver.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .listVersions = listVersions,
                .versionMeta = versionMeta,
                .lockedVersion = lockedVersion,
            },
        };
    }

    fn detailsSource(self: *Composite) lock_mod.DetailsSource {
        return .{ .context = self, .getFn = getDetails };
    }

    fn stripImpls(self: *const Composite, meta: *resolver.VersionMeta) void {
        if (!self.source_only) return;
        meta.has_native = false;
        meta.has_esm = false;
        if (!meta.has_source and meta.unavailable_reason == null) {
            meta.unavailable_reason = "package has no shared source implementation for an any/common profile";
        }
    }

    fn listVersions(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId) anyerror![]const resolver.Version {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return error.PackageNotFound,
        };
        if (isVirtualId(name)) {
            const local = self.ctx.locals.get(name) orelse return error.PackageNotFound;
            const version = resolver.Version.parse(local.version_text) catch return error.PackageNotFound;
            const out = try gpa.alloc(resolver.Version, 1);
            out[0] = version;
            return out;
        }
        const reg = self.registry orelse return error.RegistryRequired;
        return reg.provider().listVersions(gpa, id);
    }

    fn versionMeta(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId, version: resolver.Version) anyerror!resolver.VersionMeta {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return .{ .unavailable_reason = "npm dependencies are not resolved by the project resolver" },
        };
        if (isVirtualId(name)) {
            const local = self.ctx.locals.get(name) orelse
                return .{ .unavailable_reason = "dependency source was not acquired" };
            var meta: resolver.VersionMeta = undefined;
            if (local.manifest) |*dep_manifest| {
                meta = try resolver.metaFromManifest(gpa, dep_manifest, self.target);
            } else {
                // manifest を持たない取得（raw http 等）は source 実装のみ。
                meta = .{ .has_source = true };
            }
            self.stripImpls(&meta);
            return meta;
        }
        const reg = self.registry orelse return error.RegistryRequired;
        var meta = try reg.provider().versionMeta(gpa, id, version);
        self.stripImpls(&meta);
        return meta;
    }

    fn lockedVersion(ptr: *anyopaque, id: resolver.PackageId) ?resolver.Version {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        if (isVirtualId(switch (id) {
            .pkg => |pkg| pkg,
            .npm => return null,
        })) return null;
        const index = self.locked_index orelse return null;
        return index.get(id);
    }

    fn getDetails(context: *anyopaque, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?lock_mod.PackageDetails {
        const self: *Composite = @ptrCast(@alignCast(context));
        if (isVirtualId(id)) {
            const local = self.ctx.locals.get(id) orelse return null;
            const artifacts = try gpa.alloc(lock_model.Artifact, 1);
            artifacts[0] = local.artifact;
            return .{
                .public_id = local.public_id,
                .name = local.package_name,
                .source = local.source,
                .artifacts = artifacts,
            };
        }
        const reg = self.registry orelse return null;
        return reg.detailsSource().get(gpa, id, version);
    }
};

// ---------------------------------------------------------------------------
// lock 生成
// ---------------------------------------------------------------------------

pub const PrepareOptions = struct {
    /// 選択 profile。null なら default。
    profile: ?[]const u8 = null,
    /// 要求 feature 名。
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
    /// 更新対象（package id/name）。`update_all` が真なら無視。
    update_targets: []const []const u8 = &.{},
    /// 既存 lock の版優先を全解除する（`lnako update` 無指定）。
    update_all: bool = false,
    /// `lnako lock` 系で既存版を優先するか。false は update_all と同等。
    prefer_locked: bool = true,
    /// fresh な lock でも再解決する（`lnako update`）。
    force_resolve: bool = false,
    prefer_oldest: bool = false,
    registry_url: ?[]const u8 = null,
    cache_root: ?[]const u8 = null,
    policy: fetch.Policy = .{},
    /// engines 照合の対象 version。null は未検査。
    os_version: ?[]const u8 = null,
    nako_version: ?semver.Version = null,
    cnako_version: ?semver.Version = null,
    lnako_version: ?semver.Version = null,
};

pub const LockOutcome = struct {
    arena: *std.heap.ArenaAllocator,
    /// 最終的な lock（新規生成または既存のまま）。
    lock: lock_model.Lock,
    /// nako.lock を書き換えたか。
    wrote: bool,
    /// 既存 lock と新 lock の差分。wrote=false なら null。
    report: ?lock_mod.UpdateReport = null,
    /// 解決前の鮮度判定結果。
    freshness: lock_mod.Freshness,
    /// 選択された profile 名。
    profile: []const u8,

    pub fn deinit(self: *LockOutcome) void {
        self.lock.deinit();
        if (self.report) |*report| report.deinit();
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// `nako.lock` のバイト列を読む。無ければ null。
fn readLockBytes(gpa: Allocator, io: std.Io, project_root: []const u8) Error!?[]const u8 {
    const path = try std.fs.path.join(gpa, &.{ project_root, lock_name });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => return mapFs(err),
    };
}

/// 既存 lock を parse+validate する。無ければ null。破損は診断付きで
/// `InvalidLock`。
fn loadExistingLock(gpa: Allocator, io: std.Io, project_root: []const u8, diagnostics: *diag.List) Error!?lock_model.Lock {
    const bytes = (try readLockBytes(gpa, io, project_root)) orelse return null;
    const errors_before = diagnostics.errorCount();
    var parsed = lock_mod.parse(gpa, bytes, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLock,
    };
    errdefer parsed.deinit();
    lock_mod.validate(&parsed, diagnostics) catch return error.OutOfMemory;
    // errorCount は累積のため、この検査が追加した分だけを見る。
    if (diagnostics.errorCount() > errors_before) return error.InvalidLock;
    return parsed;
}

/// manifest の npm 依存宣言を拒否する。npm 解決器は未実装のため、lock
/// へ黙って落とすのではなく診断で明示して失敗にする。
fn rejectNpmDeps(manifest: *const manifest_mod.Manifest, diagnostics: *diag.List) Error!void {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var it = group.npm.iterator();
        while (it.next()) |entry| {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, entry.key_ptr.*, .{}, "npm dependency \"{s}\" cannot be locked (npm dependencies are not supported)", .{entry.key_ptr.*});
            return error.UnsupportedDependency;
        }
    }
}

/// `nako.toml` の依存宣言のうち mutable path 依存があれば true（--locked
/// 時の E016 説明用）。
fn hasMutablePathDep(manifest: *const manifest_mod.Manifest) bool {
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var it = group.path.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.mutable) return true;
        }
    }
    return false;
}

/// lock の freshness 判定に使う入力（manifest hash・profile・features・
/// target）を組み立てる。features の各名前は manifest の定義を指すため
/// `project` が生きている間だけ有効。
fn lockInputFor(a: Allocator, project: *const Project, opts: *const PrepareOptions, diagnostics: *diag.List) Error!lock_model.Input {
    const profiles = try profilesOf(a, project);
    const profile = try selectProfile(profiles, opts.profile, diagnostics);
    const record = recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try expandRootFeatures(a, &project.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    return .{
        .manifest_sha256 = project.manifest_sha256,
        .profile = profile,
        .features = try expandedFeatureNames(a, &expanded),
        .target = .{ .os = record.os, .cpu = record.cpu, .abi = record.abi },
    };
}

/// `--locked` の契約を検証する。lock 不足・陳腐・schema/resolver 不一致は
/// `LockedNotSatisfied`。可変 path 依存が再解決を要求する場合は E016 を
/// 報告する。lock の意味検証は `loadExistingLock` で済んでいる前提。
pub fn verifyLocked(
    gpa: Allocator,
    io: std.Io,
    project: *const Project,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
) Error!void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const input = try lockInputFor(a, project, opts, diagnostics);

    var existing = try loadExistingLock(a, io, project.root, diagnostics);
    defer if (existing) |*lock| lock.deinit();
    const freshness = lock_mod.checkFreshness(if (existing) |*l| l else null, input);
    if (freshness != .fresh) {
        // E016 は manifest 変更により mutable path 依存の再解決が必要に
        // なる場合に限定する（lock 欠落・target/features 変更は E029）。
        if (freshness == .stale_manifest and hasMutablePathDep(&project.manifest)) {
            try diagnostics.addFmt(diag.E016_UNLOCKED_MUTABLE_PATH, .err, "nako.toml", .{}, "a mutable path dependency requires re-resolution but --locked forbids it", .{});
        } else {
            const reason: []const u8 = switch (freshness) {
                .missing => "nako.lock is missing",
                .stale_schema => "nako.lock has an unknown schemaVersion",
                .stale_resolver => "nako.lock was written by a different resolver version",
                .stale_manifest => "nako.toml changed since nako.lock was written",
                .stale_profile => "the selected profile differs from nako.lock",
                .stale_features => "the selected features differ from nako.lock",
                .stale_target => "the resolved target differs from nako.lock",
                .fresh => unreachable,
            };
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, lock_name, .{}, "{s} and --locked forbids updating it", .{reason});
        }
        return error.LockedNotSatisfied;
    }
    // `mutable = false` の pin hash も検証する（内容変更は --locked で
    // 再記録できないため失敗とする）。
    if (existing) |*l| {
        if (try sync_mod.pathPinMismatch(a, io, project.root, l)) |name| {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, lock_name, .{}, "content of pinned path dependency \"{s}\" changed and --locked forbids re-locking", .{name});
            return error.LockedNotSatisfied;
        }
    }
}

/// `tree`/`why` など問い合わせ系コマンドのための読み取り専用 lock 取得。
/// `nako.lock` を一切書き換えない。lock 不在は `LockNotFound`、陳腐
/// （manifest/feature/target 不一致・pin hash 不一致）は `StaleLock` を
/// 診断付きで返す。`--locked` 指定時は呼出し側で先に `verifyLocked` を
/// 実行すること（両者とも書き込みを伴わない）。
pub fn loadFreshLock(
    gpa: Allocator,
    io: std.Io,
    project: *const Project,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
) Error!LockOutcome {
    const arena_impl = try gpa.create(std.heap.ArenaAllocator);
    arena_impl.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_impl.deinit();
        gpa.destroy(arena_impl);
    }
    const a = arena_impl.allocator();

    const input = try lockInputFor(a, project, opts, diagnostics);
    var existing = try loadExistingLock(a, io, project.root, diagnostics);
    if (existing == null) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, lock_name, .{}, "nako.lock is missing; run `lnako lock` first", .{});
        return error.LockNotFound;
    }
    const freshness = lock_mod.checkFreshness(&existing.?, input);
    if (freshness != .fresh) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, lock_name, .{}, "nako.lock is stale; run `lnako lock` to update it", .{});
        return error.StaleLock;
    }
    if (try sync_mod.pathPinMismatch(a, io, project.root, &existing.?)) |name| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, lock_name, .{}, "content of pinned path dependency \"{s}\" does not match nako.lock; run `lnako lock`", .{name});
        return error.StaleLock;
    }
    const moved = existing.?;
    existing = null; // 所有権は戻り値へ。
    return .{
        .arena = arena_impl,
        .lock = moved,
        .wrote = false,
        .freshness = .fresh,
        .profile = input.profile,
    };
}

/// 既存 lock の鮮度を確認し、stale/missing なら全 profile を解決して
/// `nako.lock` を原子的に書き換える。`opts.locked` は呼出し側で先に
/// `verifyLocked` へ流すこと（ここでは解決を行わない）。
pub fn ensureLock(
    gpa: Allocator,
    io: std.Io,
    project: *const Project,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
) Error!LockOutcome {
    const arena_impl = try gpa.create(std.heap.ArenaAllocator);
    arena_impl.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_impl.deinit();
        gpa.destroy(arena_impl);
    }
    const a = arena_impl.allocator();

    const profiles = try profilesOf(a, project);
    const profile = try selectProfile(profiles, opts.profile, diagnostics);
    const record = recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try expandRootFeatures(a, &project.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    // npm 依存は lock に表現できないため解決開始前に拒否する。
    try rejectNpmDeps(&project.manifest, diagnostics);
    const input = lock_model.Input{
        .manifest_sha256 = try a.dupe(u8, project.manifest_sha256),
        .profile = try a.dupe(u8, profile),
        .features = try expandedFeatureNames(a, &expanded),
        .target = .{
            .os = try a.dupe(u8, record.os),
            .cpu = try a.dupe(u8, record.cpu),
            .abi = try a.dupe(u8, record.abi),
        },
    };

    var existing = try loadExistingLock(a, io, project.root, diagnostics);
    defer if (existing) |*l| l.deinit();
    var freshness = lock_mod.checkFreshness(if (existing) |*l| l else null, input);
    // `mutable = false` の path 依存は内容 hash で pin する。fresh であっても
    // pin 不一致なら lock を作り直す。
    if (freshness == .fresh) {
        if (try sync_mod.pathPinMismatch(a, io, project.root, &existing.?) != null) {
            freshness = .stale_manifest;
        }
    }
    if (freshness == .fresh and !opts.force_resolve) {
        const moved = existing.?;
        existing = null; // 所有権は戻り値へ。defer の deinit を防ぐ。
        return .{
            .arena = arena_impl,
            .lock = moved,
            .wrote = false,
            .freshness = .fresh,
            .profile = try a.dupe(u8, profile),
        };
    }

    // --- source 依存の取得 closure（profile 共通） --------------------------
    var session = fetch.Session.init(gpa, io, opts.policy);
    defer session.deinit();
    session.diagnostics = diagnostics;
    var ctx = ResolveContext{
        .gpa = a,
        .io = io,
        .session = &session,
        .project_root = project.root,
        .opts = opts,
        .existing_lock = if (existing) |*l| l else null,
        .locals = std.StringHashMap(*LocalPackage).init(a),
        .diagnostics = diagnostics,
    };
    defer ctx.deinit();
    collectLocals(&ctx, &project.manifest, &expanded.dependency_aliases) catch |err| {
        session.reportDiagnostics(diagnostics) catch {};
        return err;
    };

    // root の pkg 依存があれば registry が必要。
    var root_needs_registry = false;
    for ([_]*const manifest_mod.DependencyGroup{ &project.manifest.dependencies, &project.manifest.dev_dependencies }) |group| {
        var it = group.pkg.iterator();
        if (it.next() != null) root_needs_registry = true;
    }
    if (root_needs_registry or ctx.needs_registry) ctx.needs_registry = true;
    if (ctx.needs_registry and opts.registry_url == null) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "registry dependencies require a registry url (--registry or LNAKO_REGISTRY)", .{});
        return error.RegistryRequired;
    }

    // --- profile ごとに解決 -------------------------------------------------
    var gated_root = try gatedDepNames(a, &project.manifest);
    defer gated_root.deinit();

    var per_profile: std.ArrayList(lock_mod.ProfileInput) = .empty;
    var primary_nodes: []const resolver.PackageNode = &.{};
    for (profiles) |named| {
        const target = resolveTarget(named.record, opts);
        var composite = Composite{
            .ctx = &ctx,
            .registry = null,
            .source_only = sourceOnly(named.record),
            .locked_index = null,
            .target = target,
        };
        var reg: ?registry.StaticRegistry = null;
        defer if (reg) |*r| r.deinit();
        if (ctx.needs_registry) {
            // index 取得は lazy（loadIndex）で instance ごとに1度。target
            // が profile ごとに異なるため instance は共有できない。
            reg = registry.StaticRegistry.init(&session, opts.registry_url.?, target) catch |err| {
                session.reportDiagnostics(diagnostics) catch {};
                return err;
            };
        }
        composite.registry = if (reg) |*r| r else null;
        var locked_index: ?lock_mod.LockedIndex = null;
        defer if (locked_index) |*index| index.deinit();
        if (opts.prefer_locked and !opts.update_all) {
            locked_index = lock_mod.buildLockedIndex(a, if (existing) |*l| l else null, named.name, opts.update_targets) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidLock,
            };
        }
        composite.locked_index = if (locked_index) |*index| index else null;

        const root_deps = try rootDeps(a, &ctx, &project.manifest, named.name, &gated_root, &expanded.dependency_aliases);
        // `resolution` は `a`（outcome arena）で確保される。`defer deinit`
        // は各 profile 反復で実行されるが、arena の部分 free は no-op な
        // ため、`primary_nodes`/`per_profile` が参照する node の
        // `dependencies`/`id`/`version`/`features` は loop 後も有効。
        var resolution = resolver.resolve(a, composite.provider(), root_deps, .{
            .target = target,
            .prefer_oldest = opts.prefer_oldest,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFeatureGraph, error.FeatureIterationExceeded => {
                try diagnostics.addFmt(diag.E027_FEATURE_CYCLE, .err, named.name, .{}, "feature requirements did not converge for profile \"{s}\"", .{named.name});
                return error.ResolveFailed;
            },
            else => {
                session.reportDiagnostics(diagnostics) catch {};
                return error.ResolveFailed;
            },
        };
        defer resolution.deinit();
        const nodes = switch (resolution.result) {
            .resolved => |resolved| resolved,
            .failed => |failure| {
                try diagnostics.addFmt(diag.E003_CONFLICTING_VERSIONS, .err, named.name, .{}, "{s}", .{failure.message});
                session.reportDiagnostics(diagnostics) catch {};
                return error.ResolveFailed;
            },
            .cycle => |cycle| {
                var message: std.ArrayList(u8) = .empty;
                for (cycle, 0..) |id, index| {
                    if (index > 0) try message.appendSlice(a, " -> ");
                    try message.appendSlice(a, try std.fmt.allocPrint(a, "{f}", .{id}));
                }
                try diagnostics.addFmt(diag.E004_DEPENDENCY_CYCLE, .err, named.name, .{}, "dependency cycle: {s}", .{message.items});
                return error.DependencyCycle;
            },
        };

        // 仮想 node の `dependencies` に source 依存の子辺を補う。
        const fixed = try appendSourceEdges(a, &ctx, nodes);
        if (std.mem.eql(u8, named.name, input.profile)) primary_nodes = fixed;
        try per_profile.append(a, .{ .profile = named.name, .nodes = fixed });
    }

    // --- lock 生成・書込 ----------------------------------------------------
    var composite_details = Composite{
        .ctx = &ctx,
        .registry = null,
        .source_only = false,
        .locked_index = null,
        .target = .{},
    };
    var reg_details: ?registry.StaticRegistry = null;
    defer if (reg_details) |*r| r.deinit();
    if (ctx.needs_registry) {
        // lock 詳細取得用は target 非依存（`.{}`）。index は lazy 取得で
        // details 呼出しが無ければ fetch も発生しない。
        reg_details = registry.StaticRegistry.init(&session, opts.registry_url.?, .{}) catch |err| {
            session.reportDiagnostics(diagnostics) catch {};
            return err;
        };
    }
    composite_details.registry = if (reg_details) |*r| r else null;

    var built = if (profiles.len == 1)
        lock_mod.build(a, input, profiles, primary_nodes, composite_details.detailsSource()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                session.reportDiagnostics(diagnostics) catch {};
                return error.ResolveFailed;
            },
        }
    else
        lock_mod.buildMulti(a, input, profiles, per_profile.items, composite_details.detailsSource()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                session.reportDiagnostics(diagnostics) catch {};
                return error.ResolveFailed;
            },
        };
    errdefer built.deinit();

    var report = try lock_mod.diff(a, if (existing) |*l| l else null, &built, input.profile, opts.update_targets);
    errdefer report.deinit();

    const bytes = lock_mod.toBytes(&built, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileSystem,
    };
    try writeAtomic(io, try std.fs.path.join(a, &.{ project.root, lock_name }), bytes);

    return .{
        .arena = arena_impl,
        .lock = built,
        .wrote = true,
        .report = report,
        .freshness = freshness,
        .profile = try a.dupe(u8, profile),
    };
}

/// root manifest の依存宣言から solver の root deps を組み立てる。
/// `dep.profile` 制限・feature gate・feature 有効化を適用する。
fn rootDeps(
    gpa: Allocator,
    ctx: *ResolveContext,
    manifest: *const manifest_mod.Manifest,
    profile: []const u8,
    gated: *const std.StringHashMap(void),
    activated: *const std.StringHashMap(void),
) Error![]const resolver.Dependency {
    var deps: std.ArrayList(resolver.Dependency) = .empty;
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var it = group.pkg.iterator();
        while (it.next()) |entry| {
            const dep = entry.value_ptr.*;
            if (dep.profile) |p| {
                if (!std.mem.eql(u8, p, profile)) continue;
            }
            if (depIsGated(gated, dep.name, dep.alias) and !depIsActivated(activated, dep.name, dep.alias)) continue;
            try deps.append(gpa, .{
                .id = .{ .pkg = dep.public_id orelse dep.name },
                .constraint = try resolver.rangeFromSemver(gpa, dep.version),
                .name = dep.name,
                .alias = dep.alias,
                .features = dep.features,
                .default_features = dep.default_features,
                .prefer_native = dep.prefer_native,
                .semver_range = dep.version,
            });
        }
    }
    // 仮想 source node。default feature 展開で依存側 manifest の
    // feature 条件を評価させるため default_features=true にする。
    var local_it = ctx.locals.iterator();
    while (local_it.next()) |entry| {
        try deps.append(gpa, .{
            .id = .{ .pkg = entry.key_ptr.* },
            .constraint = .any,
            .name = entry.value_ptr.*.dep_key,
            .default_features = true,
        });
    }
    std.mem.sort(resolver.Dependency, deps.items, {}, struct {
        fn lt(_: void, a: resolver.Dependency, b: resolver.Dependency) bool {
            return resolver.PackageId.lessThan(a.id, b.id);
        }
    }.lt);
    return deps.items;
}

/// 解決済み node の `dependencies` に source 依存の子 id を追加した
/// 新しい配列を返す。
fn appendSourceEdges(gpa: Allocator, ctx: *ResolveContext, nodes: []const resolver.PackageNode) Error![]const resolver.PackageNode {
    const fixed = try gpa.dupe(resolver.PackageNode, nodes);
    for (fixed) |*node| {
        const id_text = try std.fmt.allocPrint(gpa, "{f}", .{node.id});
        const local = ctx.locals.get(id_text) orelse continue;
        if (local.child_ids.len == 0) continue;
        const merged = try gpa.alloc(resolver.PackageId, node.dependencies.len + local.child_ids.len);
        @memcpy(merged[0..node.dependencies.len], node.dependencies);
        @memcpy(merged[node.dependencies.len..], local.child_ids);
        node.dependencies = merged;
    }
    return fixed;
}

/// ファイルを原子的に書き換える（tmp + rename）。
fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) Error!void {
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch |err| return mapFs(err);
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, bytes) catch |err| return mapFs(err);
    atomic.replace(io) catch |err| return mapFs(err);
}

// ---------------------------------------------------------------------------
// 環境状態の検査（副作用なし）
// ---------------------------------------------------------------------------

pub const EnvironmentInfo = struct {
    schema_version: i64 = 0,
    lock_sha256: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    /// `.nako/current` の世代名（あれば）。
    generation: ?[]const u8 = null,
    packages: usize = 0,
};

/// `.nako/environment.json` を読む。無ければ null。読み取りのみで
/// `.nako` を作成しない（check/--no-sync の副作用なし契約）。
pub fn readEnvironmentInfo(gpa: Allocator, io: std.Io, project_root: []const u8) Error!?EnvironmentInfo {
    const path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "environment.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => return mapFs(err),
    };
    defer gpa.free(bytes);
    var info = EnvironmentInfo{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidLock;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLock;
    const obj = parsed.value.object;
    if (obj.get("schemaVersion")) |v| {
        if (v == .integer) info.schema_version = v.integer;
    }
    if (obj.get("lockSha256")) |v| {
        if (v == .string) info.lock_sha256 = try gpa.dupe(u8, v.string);
    }
    if (obj.get("profile")) |v| {
        if (v == .string) info.profile = try gpa.dupe(u8, v.string);
    }
    if (obj.get("runtime")) |v| {
        if (v == .string) info.runtime = try gpa.dupe(u8, v.string);
    }
    if (obj.get("packages")) |v| {
        if (v == .object) info.packages = v.object.count();
    }
    const current_path = try std.fs.path.join(gpa, &.{ project_root, ".nako", "current" });
    defer gpa.free(current_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, current_path, gpa, .limited(4096)) catch null) |current| {
        defer gpa.free(current);
        const name = std.mem.trim(u8, current, " \t\r\n");
        if (name.len > 0) info.generation = try gpa.dupe(u8, name);
    }
    return info;
}

/// `.nako/env/<generation>` dir が実在するか。`environment.json` だけ残って
/// 参照世代が消えた状態を stale として扱うための検査。世代名に path 成分が
/// 混じった細工した `current` は拒否する。
pub fn generationExists(io: std.Io, project_root: []const u8, generation: []const u8) bool {
    if (generation.len == 0 or generation.len > 256) return false;
    for (generation) |ch| {
        // `.` を含む世代名は存在しない（`..` による dir 外参照を拒否）。
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    var buffer: [512]u8 = undefined;
    const rel = std.fmt.bufPrint(&buffer, ".nako" ++ std.fs.path.sep_str ++ "env" ++ std.fs.path.sep_str ++ "{s}", .{generation}) catch return false;
    var path_buffer: [4096]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ project_root, rel }) catch return false;
    std.Io.Dir.cwd().access(io, abs, .{}) catch return false;
    return true;
}

/// `lnako check` / cnako `--no-sync` のための静的検査結果。
/// ファイルシステムを一切変更しない。
pub const CheckInfo = struct {
    /// `nako.lock` の状態。
    lock_state: enum { missing, invalid, fresh, stale },
    /// 読めた lock の鮮度（invalid/missing では未使用）。
    freshness: lock_mod.Freshness = .missing,
    /// `.nako/environment.json` の内容。無ければ null。
    environment: ?EnvironmentInfo,
    /// 環境が現行 lock と整合するか。
    environment_current: bool,
};

/// manifest・lock・環境を読み取り専用で検査する。`.nako` を含め
/// ファイルシステムへ一切書き込まない。
pub fn inspectForCheck(
    gpa: Allocator,
    io: std.Io,
    project: *const Project,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
) Error!CheckInfo {
    var info = CheckInfo{ .lock_state = .missing, .environment = null, .environment_current = false };

    const profiles = try profilesOf(gpa, project);
    const profile = try selectProfile(profiles, opts.profile, diagnostics);
    const record = recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try expandRootFeatures(gpa, &project.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    const input = lock_model.Input{
        .manifest_sha256 = project.manifest_sha256,
        .profile = profile,
        .features = try expandedFeatureNames(gpa, &expanded),
        .target = .{ .os = record.os, .cpu = record.cpu, .abi = record.abi },
    };

    var existing = loadExistingLock(gpa, io, project.root, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            info.lock_state = .invalid;
            return info;
        },
    };
    defer if (existing) |*l| l.deinit();
    if (existing == null) {
        info.freshness = .missing;
    } else {
        info.freshness = lock_mod.checkFreshness(&existing.?, input);
        // `mutable = false` の pin hash 不一致も stale とする。
        if (info.freshness == .fresh and
            (try sync_mod.pathPinMismatch(gpa, io, project.root, &existing.?)) != null)
        {
            info.freshness = .stale_manifest;
        }
        info.lock_state = if (info.freshness == .fresh) .fresh else .stale;
    }

    info.environment = try readEnvironmentInfo(gpa, io, project.root);
    var digest: [32]u8 = undefined;
    const has_lock = try lockDigest(gpa, io, project.root, &digest);
    // ensureEnvironment と同じ整合条件で判定する（lock digest・schema・
    // 選択 profile・runtime・参照世代 dir の実在）。
    info.environment_current = has_lock and info.environment != null and
        environmentMatchesLock(info.environment.?, &digest) and
        info.environment.?.schema_version == 1 and
        (info.environment.?.profile == null or std.mem.eql(u8, info.environment.?.profile.?, profile)) and
        (info.environment.?.runtime == null or std.mem.eql(u8, info.environment.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致とする。
        (info.environment.?.generation != null and generationExists(io, project.root, info.environment.?.generation.?));
    return info;
}

/// `nako.lock` ファイル本体の SHA-256（正規化済み 32byte digest）。
pub fn lockDigest(gpa: Allocator, io: std.Io, project_root: []const u8, out: *[32]u8) Error!bool {
    const bytes = (try readLockBytes(gpa, io, project_root)) orelse return false;
    std.crypto.hash.sha2.Sha256.hash(bytes, out, .{});
    return true;
}

/// 環境の `lockSha256` が現行 `nako.lock` と一致するか。
pub fn environmentMatchesLock(info: EnvironmentInfo, lock_digest: *const [32]u8) bool {
    const recorded = info.lock_sha256 orelse return false;
    var expected: [32]u8 = undefined;
    return lock_model.normalizeSha256(recorded, &expected) and
        std.mem.eql(u8, &expected, lock_digest);
}

// ---------------------------------------------------------------------------
// 環境準備（ensureLock → 必要なら sync）
// ---------------------------------------------------------------------------

pub const PrepOutcome = struct {
    /// lock が新規書込・更新されたか。
    lock_wrote: bool = false,
    /// 今回 sync を実行したか。
    synced: bool = false,
    /// `.nako` の絶対 path（環境が存在する場合）。
    environment_root: ?[]const u8 = null,
    /// sync の世代名。
    generation: ?[]const u8 = null,
    profile: []const u8 = "",
    /// 直前の環境が不足・不一致だったか。
    was_stale: bool = false,
};

/// lock を最新化し、`.nako` 環境が現行 lock と一致しない場合のみ
/// `sync.run` を実行する。`--no-sync` 呼び出し側は本関数を呼ばず
/// `readEnvironmentInfo` で既存環境を検査する。
pub fn ensureEnvironment(
    gpa: Allocator,
    io: std.Io,
    project: *const Project,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
) Error!PrepOutcome {
    var outcome = PrepOutcome{};
    var lock_outcome = try ensureLock(gpa, io, project, opts, diagnostics);
    defer lock_outcome.deinit();
    outcome.lock_wrote = lock_outcome.wrote;
    // lock_outcome の arena は defer で破棄されるため、gpa 側へ複製する。
    outcome.profile = try gpa.dupe(u8, lock_outcome.profile);

    var digest: [32]u8 = undefined;
    const has_lock = try lockDigest(gpa, io, project.root, &digest);
    const env = try readEnvironmentInfo(gpa, io, project.root);
    const env_ok = has_lock and env != null and
        environmentMatchesLock(env.?, &digest) and
        env.?.schema_version == 1 and
        (env.?.profile == null or std.mem.eql(u8, env.?.profile.?, lock_outcome.profile)) and
        (env.?.runtime == null or std.mem.eql(u8, env.?.runtime.?, "lnako")) and
        // 参照世代 dir が消えた環境は不一致として sync し直す。
        (env.?.generation != null and generationExists(io, project.root, env.?.generation.?));
    if (env_ok) {
        outcome.environment_root = try std.fs.path.join(gpa, &.{ project.root, ".nako" });
        outcome.generation = env.?.generation;
        return outcome;
    }
    outcome.was_stale = env != null;

    var report = try sync_mod.run(gpa, io, .{
        .project_root = project.root,
        .profile = lock_outcome.profile,
        .runtime = .lnako,
        .cache_root = opts.cache_root,
        .policy = opts.policy,
    }, diagnostics);
    outcome.synced = true;
    outcome.environment_root = try gpa.dupe(u8, report.environment_root);
    outcome.generation = try gpa.dupe(u8, report.generation);
    report.deinit();
    return outcome;
}

test {
    _ = @import("project_test.zig");
}
