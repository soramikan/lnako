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
const env_state = @import("env_state.zig");
const features_mod = @import("features.zig");
const fetch = @import("fetch.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const materialize = @import("materialize.zig");
const project_identity = @import("project_identity.zig");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const sync_mod = @import("sync.zig");

const Allocator = std.mem.Allocator;

pub const manifest_name = "nako.toml";
pub const lock_name = "nako.lock";

/// 互換対象の公式なでしこ3 version（`engines.nako` 照合・
/// `ナデシコバージョン` 定数と同じ upstream tag）。
pub const compat_nako_version = "3.7.24";

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

pub fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FileSystem,
    };
}

// 環境状態の読み取り検査・manifest/lock 編集の排他 lock・環境準備
// orchestration は `env_state.zig` に分離する。呼出し側が従来どおり
// `project.X` で参照できるよう再エクスポートする。
pub const EditLock = env_state.EditLock;
pub const acquireEditLock = env_state.acquireEditLock;
pub const EnvironmentInfo = env_state.EnvironmentInfo;
pub const readEnvironmentInfo = env_state.readEnvironmentInfo;
pub const generationExists = env_state.generationExists;
pub const CheckInfo = env_state.CheckInfo;
pub const inspectForCheck = env_state.inspectForCheck;
pub const environmentPackagesUsable = env_state.environmentPackagesUsable;
pub const environmentMutablePathsUsable = env_state.environmentMutablePathsUsable;
pub const environmentMatchesLock = env_state.environmentMatchesLock;
pub const PrepOutcome = env_state.PrepOutcome;
pub const ensureEnvironment = env_state.ensureEnvironment;
pub const loadExistingLock = env_state.loadExistingLock;
pub const verifyLocked = env_state.verifyLocked;
pub const loadFreshLock = env_state.loadFreshLock;
pub const lockDigest = env_state.lockDigest;

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
        const candidate_stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return mapFs(err),
        };
        if (candidate_stat) |stat| {
            if (stat.kind != .file) return error.InvalidManifest;
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
/// 合成 profile の runtime は `requested_runtime`（`lnako sync
/// --runtime cnako` 等）を優先し、無指定・未知値は `lnako`。
/// profile を宣言しないプロジェクトを cnako 向けに sync しても
/// lnako 専用の lock にならないようにするため。
pub fn profilesOf(gpa: Allocator, project: *const Project, requested_runtime: ?[]const u8) Error![]const lock_model.NamedProfile {
    var list: std.ArrayList(lock_model.NamedProfile) = .empty;
    if (project.manifest.profiles.count() == 0) {
        const host = hostTarget();
        const runtime = if (requested_runtime) |runtime|
            if (std.mem.eql(u8, runtime, "cnako") or std.mem.eql(u8, runtime, "lnako") or
                std.mem.eql(u8, runtime, "any") or std.mem.eql(u8, runtime, "common")) runtime else "lnako"
        else
            "lnako";
        try list.append(gpa, .{
            .name = try gpa.dupe(u8, "default"),
            .record = .{
                .runtime = try gpa.dupe(u8, runtime),
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

pub fn recordOf(profiles: []const lock_model.NamedProfile, name: []const u8) ?lock_model.ProfileRecord {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile.record;
    }
    return null;
}

/// 解決 runtime。`any`/`common` は lnako として解決し、provider 側で
/// source 実装のみを許容する（共有 profile の package 集合は両処理系で
/// 動く実装に限定されるべきため）。
pub fn resolveRuntime(record: lock_model.ProfileRecord) []const u8 {
    const runtime = record.runtime orelse "any";
    if (std.mem.eql(u8, runtime, "lnako") or std.mem.eql(u8, runtime, "cnako")) return runtime;
    return "lnako";
}

/// `any`/`common` profile は両処理系で動く source 実装のみ許容する。
fn sourceOnly(record: lock_model.ProfileRecord) bool {
    const runtime = record.runtime orelse "any";
    return !(std.mem.eql(u8, runtime, "lnako") or std.mem.eql(u8, runtime, "cnako"));
}

/// engines 照合 version を lock `input` 記録用の文字列へ整形する。
/// 未指定は null（`optEql` で欠落どうしの一致として扱われる）。
pub fn resolveVersionText(a: Allocator, version: ?semver.Version) Error!?[]const u8 {
    const v = version orelse return null;
    return try std.fmt.allocPrint(a, "{f}", .{v});
}

fn resolveTarget(record: lock_model.ProfileRecord, opts: *const PrepareOptions, selected_profile: bool) resolver.Target {
    return .{
        .runtime = resolveRuntime(record),
        .os = record.os,
        .cpu = record.cpu,
        .abi = record.abi,
        .os_version = opts.os_version,
        // CLI の `--compat-js` は選択中 profile の解決だけを変える。
        // profile 宣言の compat-js は、それぞれの profile に適用する。
        .compat_js = (record.compat_js orelse false) or (selected_profile and opts.compat_js),
        // `build -O` は実際に生成するコードのレベルなので profile 宣言
        // より優先する。未指定なら profile の `optimize` を使う。
        .optimize = opts.optimize orelse record.optimize orelse "O0",
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
pub fn expandRootFeatures(
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
pub fn gatedDepNames(gpa: Allocator, manifest: *const manifest_mod.Manifest) Error!std.StringHashMap(void) {
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

pub fn depIsGated(gated: *const std.StringHashMap(void), name: []const u8, alias: ?[]const u8) bool {
    if (gated.contains(name)) return true;
    if (alias) |a| return gated.contains(a);
    return false;
}

pub fn depIsActivated(aliases: *const std.StringHashMap(void), name: []const u8, alias: ?[]const u8) bool {
    if (aliases.contains(name)) return true;
    if (alias) |a| return aliases.contains(a);
    return false;
}

/// 展開済み feature 名と有効化された依存 alias 名（昇順・重複除去）。
/// `lock.Input.features` の記録用。`--features req` のように依存 alias を
/// 直接指定した要求は `expanded.features` に残らず `dependency_aliases`
/// へ入るため、併記しないと直接 alias 有無の差分が鮮度入力から抜け、
/// 別グラフの lock を fresh と誤認する。
pub fn expandedFeatureNames(gpa: Allocator, expanded: *const features_mod.Expanded) Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var iterator = expanded.features.keyIterator();
    while (iterator.next()) |key| try list.append(gpa, key.*);
    var alias_iterator = expanded.dependency_aliases.keyIterator();
    while (alias_iterator.next()) |key| try list.append(gpa, key.*);
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
    /// lock に記録する `pkg:<32hex>` public id。取得済み canonical source
    /// identity から派生させるため、同じ pin の表記揺れは同一 id になる。
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
    /// 依存元 manifest の source 宣言。取得 closure 完了後に解決済み
    /// canonical id へ対応付けて lock `dependencies` を構築する。
    child_works: []const DepWork,
    /// この dep 自身が宣言する source 依存の仮想 id。
    child_ids: []const resolver.PackageId,
    /// この dep manifest が pkg 依存を持つか（registry 必要性の判定用）。
    needs_registry: bool = false,
    /// dep manifest の feature-gated 依存名集合（manifest があるときのみ有効）。
    gated_deps: std.StringHashMap(void) = undefined,
    /// dep manifest の default feature 展開で有効化された依存名集合。
    activated_deps: std.StringHashMap(void) = undefined,
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

pub const SourceDecl = project_identity.SourceDecl;

/// virtual id（source identity）から `pkg:<32hex>` public id を派生する。
fn publicIdFor(gpa: Allocator, id_text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id_text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "pkg:{s}", .{hex[0..32]});
}

pub const publicIdForSourceDecl = project_identity.publicIdForSourceDecl;
pub const publicIdForSourceDeclInPackages = project_identity.publicIdForSourceDeclInPackages;

fn isVirtualId(id_text: []const u8) bool {
    return std.mem.startsWith(u8, id_text, "path:") or
        std.mem.startsWith(u8, id_text, "git:") or
        std.mem.startsWith(u8, id_text, "http:");
}

/// lock `source.path` と同じ正規化を TOML の宣言文字列へ適用する。
/// `./deps/lib` → `deps/lib`、区切りを `/` に揃え、繰り返し separator・
/// `.` 成分・末尾 separator も畳む。`deps//lib` のような非規範形を
/// lock へ記録すると sync の `isCanonicalDepPath` が拒否し、
/// lock 成功・実行失敗の不整合になるため。`..` 成分は宣言者の
/// 正当な選択（`../shared`）として保持し、絶対 path の先頭
/// separator も保持する。
fn isAbsoluteDependencyPath(path: []const u8) bool {
    return provider.isAbsoluteDepPath(path);
}

fn isWindowsDriveRoot(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isWindowsSeparator(path[2]);
}

/// POSIXでは2つの先頭backslashだけではUNCとみなさない。
fn isCompleteBackslashUnc(path: []const u8) bool {
    if (path.len < 5 or path[0] != '\\' or path[1] != '\\') return false;
    var i: usize = 2;
    while (i < path.len and isWindowsSeparator(path[i])) : (i += 1) {}
    const server_start = i;
    while (i < path.len and !isWindowsSeparator(path[i])) : (i += 1) {}
    if (i == server_start or i == path.len) return false;
    while (i < path.len and isWindowsSeparator(path[i])) : (i += 1) {}
    const share_start = i;
    while (i < path.len and !isWindowsSeparator(path[i])) : (i += 1) {}
    return i > share_start;
}

fn canonicalDepSpelling(gpa: Allocator, decl: []const u8) ![]const u8 {
    const windows_drive_root = isWindowsDriveRoot(decl);
    const windows_unc_prefix = decl.len >= 2 and isWindowsSeparator(decl[0]) and isWindowsSeparator(decl[1]);
    const windows_unc_root = windows_unc_prefix and isAbsoluteDependencyPath(decl) and
        (builtin.os.tag == .windows or decl[0] == '\\');
    if ((builtin.os.tag == .windows and isAbsoluteDependencyPath(decl)) or windows_drive_root or windows_unc_root) {
        return try canonicalWindowsDepSpelling(gpa, decl);
    }
    if (windows_unc_prefix and !windows_unc_root and (builtin.os.tag == .windows or decl[0] == '\\')) {
        return try gpa.dupe(u8, decl);
    }
    const text_storage = try gpa.dupe(u8, decl);
    defer gpa.free(text_storage);
    var text = text_storage;
    while (std.mem.startsWith(u8, text, "./")) text = text[2..];
    // POSIX では backslash は通常のファイル名文字なので、separator に
    // 読み替えない。Windows だけ両形式を host path separator に統一する。
    if (builtin.os.tag == .windows) {
        for (text) |*char| {
            if (char.* == '\\') char.* = '/';
        }
    }
    var output: std.ArrayList(u8) = .empty;
    if (text.len > 0 and text[0] == '/') try output.append(gpa, '/');
    var components = std.mem.splitScalar(u8, text, '/');
    var first = output.items.len == 0;
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (!first) try output.append(gpa, '/');
        try output.appendSlice(gpa, component);
        first = false;
    }
    if (output.items.len == 0) try output.append(gpa, '.');
    return try output.toOwnedSlice(gpa);
}

fn canonicalWindowsDepSpelling(gpa: Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    if (text.len >= 2 and isWindowsSeparator(text[0]) and isWindowsSeparator(text[1])) {
        // UNC/device paths retain exactly the leading double separator.
        try output.appendSlice(gpa, "\\\\");
        start = 2;
        while (start < text.len and isWindowsSeparator(text[start])) : (start += 1) {}
    } else if (text.len >= 3 and std.ascii.isAlphabetic(text[0]) and text[1] == ':' and isWindowsSeparator(text[2])) {
        try output.appendSlice(gpa, text[0..2]);
        try output.append(gpa, '\\');
        start = 3;
        while (start < text.len and isWindowsSeparator(text[start])) : (start += 1) {}
    } else {
        return try gpa.dupe(u8, text);
    }

    var components = std.mem.splitAny(u8, text[start..], "/\\");
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\\') try output.append(gpa, '\\');
        try output.appendSlice(gpa, component);
    }
    return output.toOwnedSlice(gpa);
}

fn isWindowsSeparator(char: u8) bool {
    return char == '/' or char == '\\';
}

test "canonicalDepSpelling keeps a leading backslash relative on POSIX" {
    if (builtin.os.tag == .windows) return;
    const path = try canonicalDepSpelling(std.testing.allocator, "\\lib");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("\\lib", path);
    try std.testing.expect(!isAbsoluteDependencyPath("\\lib"));
    const incomplete_unc = try canonicalDepSpelling(std.testing.allocator, "\\\\lib");
    defer std.testing.allocator.free(incomplete_unc);
    try std.testing.expectEqualStrings("\\\\lib", incomplete_unc);
    try std.testing.expect(!isAbsoluteDependencyPath(incomplete_unc));
    const complete_unc = try canonicalDepSpelling(std.testing.allocator, "\\\\server\\share\\lib");
    defer std.testing.allocator.free(complete_unc);
    try std.testing.expectEqualStrings("\\\\server\\share\\lib", complete_unc);
    try std.testing.expect(isAbsoluteDependencyPath(complete_unc));
}

test "canonicalDepSpelling normalizes Windows absolute paths" {
    const drive = try canonicalDepSpelling(std.testing.allocator, "C:\\deps\\\\.\\lib\\");
    defer std.testing.allocator.free(drive);
    try std.testing.expectEqualStrings("C:\\deps\\lib", drive);

    const unc = try canonicalDepSpelling(std.testing.allocator, "\\\\server\\share\\\\lib\\.");
    defer std.testing.allocator.free(unc);
    try std.testing.expectEqualStrings("\\\\server\\share\\lib", unc);
}

test "resolveTarget は CLI compat-js を選択 profile だけに適用する" {
    const opts = PrepareOptions{ .compat_js = true };
    const normal_record = lock_model.ProfileRecord{
        .runtime = "lnako",
        .os = "linux",
        .cpu = "x86_64",
        .abi = "gnu",
    };

    try std.testing.expect(resolveTarget(normal_record, &opts, true).compat_js);
    try std.testing.expect(!resolveTarget(normal_record, &opts, false).compat_js);

    // 明示的な profile 宣言はCLIの選択対象とは独立して維持される。
    const declared_compat = lock_model.ProfileRecord{
        .runtime = "lnako",
        .os = "linux",
        .cpu = "x86_64",
        .abi = "gnu",
        .compat_js = true,
    };
    try std.testing.expect(resolveTarget(declared_compat, &opts, false).compat_js);
}

/// dep の宣言 path を lock 記録用に正規化する。宣言が `base_dir` 相対の
/// 場合（推移的 path 依存）は project 相対または絶対 path へ解決する。
/// root 直下の宣言は `./` 前置と区切りを正規化した宣言値を返す
/// （`./deps/lib` と `deps/lib` が lock・mutablePaths で同一表記になる
/// ようにする）。
fn normalizePathSource(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    if (base_dir == null or isAbsoluteDependencyPath(declared)) return canonicalDepSpelling(gpa, declared);
    const root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    const base = std.fs.path.resolve(gpa, &.{base_dir.?}) catch return error.FileSystem;
    if (std.mem.eql(u8, root, base)) return canonicalDepSpelling(gpa, declared);
    const joined = std.fs.path.resolve(gpa, &.{ base, declared }) catch return error.FileSystem;
    if (std.mem.startsWith(u8, joined, root) and joined.len > root.len and
        (joined[root.len] == '/' or joined[root.len] == std.fs.path.sep))
    {
        return joined[root.len + 1 ..];
    }
    return joined;
}

const GitCheckoutWorkspace = struct {
    key: []const u8,
    path: []const u8,
    root_dir: std.Io.Dir,
    workspace_dir: std.Io.Dir,
};

/// Git workspaceはcache外、checkout読書きはpinned handle経由。
fn gitCheckoutWorkspace(gpa: Allocator, io: std.Io, ctx: *ResolveContext, dep: manifest_mod.GitDependency) Error!GitCheckoutWorkspace {
    if (ctx.cache_store == null) {
        const root = if (ctx.opts.cache_root) |root|
            try gpa.dupe(u8, root)
        else if (try cache.defaultRoot(gpa)) |root|
            root
        else
            try std.fs.path.join(gpa, &.{ ctx.project_root, ".nako", "cache" });
        ctx.cache_store = cache.Store.open(ctx.gpa, io, root) catch |err| return mapFs(err);
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

    // Workspace を選択 cache root の下へ namespaced し、その root handle から
    // no-follow で削除・作成する。別 cache roots が同じ親を共有しても衝突せず、
    // cache root の ACL/permission も継承する。
    var workspace_root_dir = ctx.cache_store.?.openGitWorkspaceRoot() catch |err| return mapFs(err);
    errdefer workspace_root_dir.close(io);
    workspace_root_dir.deleteTree(io, key) catch |err| return mapFs(err);
    workspace_root_dir.createDir(io, key, .default_dir) catch |err| return mapFs(err);
    var workspace_dir = workspace_root_dir.openDir(io, key, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapFs(err);
    errdefer workspace_dir.close(io);

    const workspace = (try ctx.cache_store.?.gitWorkspacePath(gpa, key)) orelse return error.FileSystem;
    if (ctx.cache_store.?.openCheckout(key) catch |err| return mapFs(err)) |cached_checkout| {
        var cached = cached_checkout;
        defer cached.close(io);
        _ = materialize.copyTreeFromDirs(gpa, io, &cached, &workspace_dir, .{}) catch |err| return mapFs(err);
    }
    return .{ .key = key, .path = workspace, .root_dir = workspace_root_dir, .workspace_dir = workspace_dir };
}

/// 既存 lock から public id（`pkg:<32hex>`）の package entry の source を
/// 探す（git の commit 固定・declared-vs-locked source 衝突検査用）。
/// 仮想 id（`git:<key>` 等）ではなく lock 記録上の public id で引く。
fn lockedSourceForWork(ctx: *ResolveContext, work: DepWork) Error!?lock_model.Source {
    const lock = ctx.existing_lock orelse return null;
    for (lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (try declaredSourceIdentityMatches(ctx, source, work)) return source;
    }
    for (lock.profile_packages) |profile| {
        for (profile.packages) |entry| {
            const source = entry.source orelse continue;
            if (try declaredSourceIdentityMatches(ctx, source, work)) return source;
        }
    }
    return null;
}

/// `dep_name`（dep key）または解決済み `public_id` が明示的な update
/// 対象か。update 対象の source 宣言変更は lock との衝突ではなく意図
/// した更新として許容する。CLI は source dependency の dep key、または
/// 既存 lock source の canonical public id を渡す。
fn isUpdateTarget(opts: *const PrepareOptions, dep_name: []const u8, public_id: []const u8) bool {
    if (opts.update_all) return true;
    for (opts.update_targets) |target| {
        if (std.mem.eql(u8, target, dep_name) or std.mem.eql(u8, target, public_id)) return true;
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

/// mutable path 依存の digest 記録対象。`path` は lock `source.path`
/// と同じ表記、`dir` は宣言 dir の絶対 path。
const MutableDep = struct {
    path: []const u8,
    dir: []const u8,
};

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
    /// この project が解決する profile 名の集合。推移的 pkg 依存の
    /// `dep.profile` 制約がいずれかの profile に適格かの判定に使う
    /// （`rootDeps`/`versionMeta` の「現行 profile 名と一致」と同じ
    /// 名前空間）。
    profile_names: std.StringHashMap(void),
    /// `mutable = true` path 依存の宣言 dir。lock `input.mutablePaths`
    /// に記録する内容 digest の計算対象（`{記録 path, 宣言 dir}`）。
    mutable_deps: std.ArrayList(MutableDep) = .empty,
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
        // 解決済み source をもつ既存ノードと照合する。Git abbreviated/full
        // commit や HTTP hash encoding が異なっても同じ pin は再取得しない。
        var existing_it = ctx.locals.iterator();
        var already_present = false;
        while (existing_it.next()) |entry| {
            const source = entry.value_ptr.*.source;
            if (!try declaredSourceIdentityMatches(ctx, source, work)) continue;
            if (!try declaredSourceMatches(ctx, source, work)) {
                try ctx.diagnostics.addFmt(diag.E012_ALIAS_COLLISION, .err, dep_name, .{}, "dependency \"{s}\" resolves to different sources", .{dep_name});
                return error.ResolveFailed;
            }
            already_present = true;
            break;
        }
        if (already_present) continue;

        var local = LocalPackage{
            .id_text = "",
            .public_id = "",
            // 推移的依存では宣言文字列が session arena 由来のため複製する。
            .dep_key = try gpa.dupe(u8, dep_name),
            .kind = work.kind,
            .source = undefined,
            .package_name = try gpa.dupe(u8, dep_name),
            .version_text = "0.0.0",
            .manifest = null,
            .artifact = .{ .key = "source", .kind = "source" },
            .child_works = &.{},
            .child_ids = &.{},
        };

        var child_base_dir: ?[]const u8 = null;
        switch (work.kind) {
            .path => {
                const dep = work.path_dep.?;
                // separator・`.` 成分の正規化は取得前にも適用する。POSIX の
                // backslash は canonicalDepSpelling が通常文字として保持する。
                const acquired_path = try canonicalDepSpelling(gpa, dep.path);
                const acquired = try provider.acquirePath(ctx.session, .{
                    .name = dep.name,
                    .path = acquired_path,
                    .mutable = dep.mutable,
                }, work.base_dir.?);
                const normalized = try normalizePathSource(gpa, acquired_path, work.base_dir, ctx.project_root);
                local.source = .{ .kind = .path, .path = normalized, .mutable = dep.mutable };
                local.manifest = acquired.manifest;
                // path 依存の manifest dir が推移的依存の基準 dir。
                child_base_dir = if (isAbsoluteDependencyPath(acquired_path))
                    try gpa.dupe(u8, acquired_path)
                else
                    try std.fs.path.join(gpa, &.{ work.base_dir.?, acquired_path });
                // `mutable = true` は宣言 dir を生参照する契約のため、
                // manifest だけでなく exports・commands・推移的宣言を含む
                // 内容変更を lock 鮮度入力へ記録する。
                if (dep.mutable) {
                    try ctx.mutable_deps.append(gpa, .{ .path = normalized, .dir = child_base_dir.? });
                }
                // `mutable = false` は tree 内容を hash pin する（spec §3.4.3）。
                // 後の内容変更は lock の鮮度判定・sync 検証で検出される。
                if (!dep.mutable) {
                    const digest = cache.digestTreeFollowingRoot(ctx.io, gpa, child_base_dir.?, &cache.source_pin_exclude) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return ctx.session.fail(.invalid_source, .package, dep_name, "cannot hash path dependency \"{s}\" tree: {s}", .{ dep_name, @errorName(err) }),
                    };
                    local.artifact.sha256 = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
                }
            },
            .git => {
                const dep = work.git_dep.?;
                var checkout = try gitCheckoutWorkspace(gpa, ctx.io, ctx, dep);
                defer checkout.root_dir.close(ctx.io);
                defer checkout.root_dir.deleteTree(ctx.io, checkout.key) catch {};
                defer checkout.workspace_dir.close(ctx.io);
                // cache checkout の検証・清掃・checkout は provider が安全な
                // Git config override の下で実行してから manifest を読む。
                const locked = try lockedSourceForWork(ctx, work);
                const locked_public_id = if (locked) |source|
                    try publicIdFor(gpa, try project_identity.virtualIdForResolvedSource(gpa, source, ctx.project_root))
                else
                    "";
                const updating = isUpdateTarget(ctx.opts, dep_name, locked_public_id);
                if (locked) |locked_source| {
                    if (!updating) try provider.checkLockedSource(ctx.session, .{
                        .kind = .git,
                        .url = dep.url,
                        .commit = dep.commit,
                        .path = dep.path,
                    }, locked_source, dep_name);
                }
                const acquired = try provider.acquireGit(ctx.session, dep, checkout.path, if (updating) null else locked);
                _ = ctx.cache_store.?.replaceCheckout(checkout.key, &checkout.workspace_dir, .{}) catch |err| return mapFs(err);
                local.source = try copySource(gpa, acquired.source);
                local.manifest = acquired.manifest;
                // git 内 package の git/http 依存は取得できるが、path 依存は
                // lock が project 相対で表現できないため後段で拒否する。
                child_base_dir = if (dep.path) |sub|
                    try std.fs.path.join(gpa, &.{ checkout.path, sub })
                else
                    checkout.path;
            },
            .http => {
                const dep = work.http_dep.?;
                const locked = try lockedSourceForWork(ctx, work);
                const locked_public_id = if (locked) |source|
                    try publicIdFor(gpa, try project_identity.virtualIdForResolvedSource(gpa, source, ctx.project_root))
                else
                    "";
                const updating = isUpdateTarget(ctx.opts, dep_name, locked_public_id);
                if (locked) |locked_source| {
                    if (!updating) try provider.checkLockedSource(ctx.session, .{
                        .kind = .http,
                        .url = dep.url,
                        .hash = dep.hash,
                    }, locked_source, dep_name);
                }
                const acquired = try provider.acquireHttp(ctx.session, dep);
                local.source = try copySource(gpa, acquired.source);
                local.source.hash = try project_identity.canonicalHttpHash(gpa, local.source.hash orelse return error.ResolveFailed);
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

        local.id_text = try project_identity.virtualIdForResolvedSource(gpa, local.source, ctx.project_root);
        local.public_id = try publicIdFor(gpa, local.id_text);
        if (ctx.locals.get(local.id_text)) |existing| {
            if (!try declaredSourceMatches(ctx, existing.source, work)) {
                try ctx.diagnostics.addFmt(diag.E012_ALIAS_COLLISION, .err, dep_name, .{}, "dependency \"{s}\" resolves to different sources", .{dep_name});
                return error.ResolveFailed;
            }
            continue;
        }

        if (local.manifest) |*dep_manifest| {
            local.package_name = try gpa.dupe(u8, dep_manifest.package.name);
            local.version_text = try std.fmt.allocPrint(gpa, "{f}", .{dep_manifest.package.version});
            // 取得した依存 manifest の npm 宣言も root と同じく lock
            // 不可能なため拒否する（metaFromManifest は npm 辺を黙って
            // 落とすため、ここで明示失敗させないと必要な推移的依存が
            // lock/環境から欠落する）。
            try rejectNpmDeps(dep_manifest, ctx.diagnostics);

            // 依存側 manifest の source 依存を default feature 展開で評価し
            // closure に追加する（依存側に features 指定口はないため default
            // 展開のみ。dev-dependencies は対象外）。
            var dep_aliases = dep_manifest.dependencyAliases(gpa) catch return error.OutOfMemory;
            // gated/activated は versionMeta で推移的 pkg 辺を絞る際にも
            // 使うため local へ保持する（領域は解決 arena が一括解放）。
            local.gated_deps = try gatedDepNames(gpa, dep_manifest);
            var offender: ?[]const u8 = null;
            var expanded = features_mod.expand(gpa, &dep_manifest.features, &.{}, true, &dep_aliases, &offender) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownFeature => {
                    try ctx.diagnostics.addFmt(diag.E028_UNKNOWN_FEATURE, .err, offender orelse dep_name, .{}, "unknown feature \"{s}\" in dependency \"{s}\"", .{ offender orelse "?", dep_name });
                    return error.ResolveFailed;
                },
                else => {
                    try ctx.diagnostics.addFmt(diag.E027_FEATURE_CYCLE, .err, dep_name, .{}, "invalid feature graph in dependency \"{s}\"", .{dep_name});
                    return error.ResolveFailed;
                },
            };
            local.activated_deps = expanded.dependency_aliases;
            // feature-gated で未 activated の pkg 依存は現行 feature 集合
            // では解決されないため registry を要求しない。
            var pkg_it = dep_manifest.dependencies.pkg.iterator();
            while (pkg_it.next()) |entry| {
                const dep = entry.value_ptr.*;
                // `dep.profile` が解決 profile のいずれにも該当しない
                // 宣言はどのグラフにも現れないため registry を要求しない。
                if (dep.profile) |p| {
                    if (!ctx.profile_names.contains(p)) continue;
                }
                if (depIsGated(&local.gated_deps, dep.name, dep.alias) and !depIsActivated(&local.activated_deps, dep.name, dep.alias)) continue;
                local.needs_registry = true;
            }
            var child_queue: std.ArrayList(DepWork) = .empty;
            try pushGroupDeps(gpa, &child_queue, &dep_manifest.dependencies, &local.gated_deps, &expanded.dependency_aliases, child_base_dir);
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
                try queue.append(gpa, child);
            }
            local.child_works = child_queue.items;
        }

        const entry = try gpa.create(LocalPackage);
        entry.* = local;
        try ctx.locals.put(local.id_text, entry);
        if (local.needs_registry) ctx.needs_registry = true;
    }

    // 依存辺も取得済み canonical source id へ解決する。特に Git の
    // abbreviated/full commit 表記や HTTP hash encoding が異なる場合、
    // 宣言段階で id を作ると実ノードと edge が別 id になってしまう。
    var locals_it = ctx.locals.iterator();
    while (locals_it.next()) |entry| {
        var children: std.ArrayList(resolver.PackageId) = .empty;
        for (entry.value_ptr.*.child_works) |child_works| {
            var child_id: ?[]const u8 = null;
            var candidates = ctx.locals.iterator();
            while (candidates.next()) |candidate| {
                if (try declaredSourceMatches(ctx, candidate.value_ptr.*.source, child_works)) {
                    child_id = candidate.key_ptr.*;
                    break;
                }
            }
            const resolved_id = child_id orelse return ctx.session.fail(.invalid_source, .package, entry.value_ptr.*.dep_key, "dependency \"{s}\" was not resolved", .{entry.value_ptr.*.dep_key});
            try children.append(gpa, .{ .pkg = resolved_id });
        }
        entry.value_ptr.*.child_ids = children.items;
    }

    try detectLocalCycles(gpa, ctx);
}

/// 宣言 source と取得済み source が同じ pin を指すかを取得なしで比較する。
/// Git は完全 commit を宣言 prefix と、HTTP は digest の正規形と比較する。
fn declaredSourceIdentityMatches(ctx: *ResolveContext, source: lock_model.Source, work: DepWork) Error!bool {
    const gpa = ctx.gpa;
    switch (work.kind) {
        .path => {
            const dep = work.path_dep.?;
            if (source.kind != .path) return false;
            const stored = source.path orelse return false;
            const stored_abs = if (isAbsoluteDependencyPath(stored))
                std.fs.path.resolve(gpa, &.{stored}) catch return error.FileSystem
            else
                std.fs.path.resolve(gpa, &.{ ctx.project_root, stored }) catch return error.FileSystem;
            const revisit_abs = if (isAbsoluteDependencyPath(dep.path))
                std.fs.path.resolve(gpa, &.{dep.path}) catch return error.FileSystem
            else
                std.fs.path.resolve(gpa, &.{ work.base_dir orelse ctx.project_root, dep.path }) catch return error.FileSystem;
            return std.mem.eql(u8, stored_abs, revisit_abs);
        },
        .git => {
            const dep = work.git_dep.?;
            if (source.kind != .git or !optEql(source.url, dep.url) or !optEql(source.path, dep.path)) return false;
            const stored_commit = source.commit orelse return false;
            return std.mem.startsWith(u8, stored_commit, dep.commit);
        },
        .http => {
            const dep = work.http_dep.?;
            if (source.kind != .http or !optEql(source.url, dep.url)) return false;
            const stored_hash = source.hash orelse return false;
            const declared_hash = dep.hash;
            if (fetch.normalizeSha256(stored_hash)) |stored| {
                if (fetch.normalizeSha256(declared_hash)) |declared| return std.mem.eql(u8, &stored, &declared);
            }
            if (fetch.normalizeSha512(stored_hash)) |stored| {
                if (fetch.normalizeSha512(declared_hash)) |declared| return std.mem.eql(u8, &stored, &declared);
            }
            return std.mem.eql(u8, stored_hash, declared_hash);
        },
    }
}

fn declaredSourceMatches(ctx: *ResolveContext, source: lock_model.Source, work: DepWork) Error!bool {
    if (!try declaredSourceIdentityMatches(ctx, source, work)) return false;
    return work.kind != .path or (source.mutable orelse false) == work.path_dep.?.mutable;
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
    /// 解決中の profile 名。推移的 pkg 依存の `profile` 制約を
    /// `rootDeps` と同じ条件で絞るために使う。
    profile_name: []const u8 = "",

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
                // any/common profile は cnako 環境へも materialize され得る
                // ので、lnako へ coerce した target だけでなく cnako
                // target にも照合する。`runtimes = ["lnako"]` だけの
                // package を受理して `sync --runtime cnako` で使えない
                // 環境を作らないため。
                if (self.source_only and meta.unavailable_reason == null) {
                    var cnako_target = self.target;
                    cnako_target.runtime = "cnako";
                    const cnako_meta = try resolver.metaFromManifest(gpa, dep_manifest, cnako_target);
                    if (cnako_meta.unavailable_reason) |reason| meta.unavailable_reason = reason;
                }
                // 推移的 pkg 辺を rootDeps と同じ条件で絞る。`dep.profile`
                // は現行 profile 名と一致する場合のみ有効で、feature-gated
                // で未 activated の宣言は除外する。metaFromManifest は両方
                // を評価しないため orchestration 側で落とす。
                if (meta.dependencies.len != 0) {
                    var kept: std.ArrayList(resolver.Dependency) = .empty;
                    for (meta.dependencies) |d| {
                        const decl = dep_manifest.dependencies.pkg.get(d.name) orelse {
                            try kept.append(gpa, d);
                            continue;
                        };
                        if (decl.profile) |p| {
                            if (!std.mem.eql(u8, p, self.profile_name)) continue;
                        }
                        if (depIsGated(&local.gated_deps, decl.name, decl.alias) and
                            !depIsActivated(&local.activated_deps, decl.name, decl.alias)) continue;
                        try kept.append(gpa, d);
                    }
                    meta.dependencies = kept.items;
                }
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
    /// 要求された sync runtime（`lnako sync --runtime`）。manifest が
    /// profile を宣言しない場合の合成 profile runtime に使う。
    requested_runtime: ?[]const u8 = null,
    /// `run`/`build --compat-js` の compat 実行。ESM 実装の許容と
    /// lock 鮮度入力の target に反映する。
    compat_js: bool = false,
    /// `build -O` の最適化レベル（`"O0"`〜`"O3"`）。実装選択と lock
    /// 鮮度入力の target に反映する。null は未指定（profile 宣言を使う）。
    optimize: ?[]const u8 = null,
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

    const profiles = try profilesOf(a, project, opts.requested_runtime);
    const profile = try selectProfile(profiles, opts.profile, diagnostics);
    const record = recordOf(profiles, profile) orelse return error.UnknownProfile;
    var expanded = try expandRootFeatures(a, &project.manifest, opts.features, !opts.no_default_features, diagnostics);
    defer expanded.deinit();
    // npm 依存は lock に表現できないため解決開始前に拒否する。
    try rejectNpmDeps(&project.manifest, diagnostics);
    var input = lock_model.Input{
        .manifest_sha256 = try a.dupe(u8, project.manifest_sha256),
        .profile = try a.dupe(u8, profile),
        .features = try expandedFeatureNames(a, &expanded),
        .target = .{
            .os = try a.dupe(u8, record.os),
            .cpu = try a.dupe(u8, record.cpu),
            .abi = try a.dupe(u8, record.abi),
            // ESM 許容・最適化レベルも実装選択を変える鮮度鍵
            // （resolveTarget と同じ effective 値を記録する）。
            .compat_js = (record.compat_js orelse false) or opts.compat_js,
            .optimize = try a.dupe(u8, opts.optimize orelse record.optimize orelse "O0"),
        },
        // 解決 runtime・engines 照合 version を鮮度鍵へ含める。
        // `--runtime` 切替・コンパイラ更新で lock を再解決するため。
        .runtime = try a.dupe(u8, resolveRuntime(record)),
        .nako_version = try resolveVersionText(a, opts.nako_version),
        .cnako_version = try resolveVersionText(a, opts.cnako_version),
        .lnako_version = try resolveVersionText(a, opts.lnako_version),
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
    // `mutable = true` の path 依存は宣言 dir を生参照する契約のため、
    // `input.mutablePaths` に記録した内容 digest と現行 dir を照合する。
    // 内容が変わっていれば（manifest・exports・推移的宣言・ソースのいずれ
    // でも）再解決し、同一なら既存 lock を再利用する。
    if (freshness == .fresh) {
        if (try sync_mod.mutablePathMismatch(a, io, project.root, &existing.?) != null) {
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
    var profile_names = std.StringHashMap(void).init(a);
    for (profiles) |named| try profile_names.put(named.name, {});
    var ctx = ResolveContext{
        .gpa = a,
        .io = io,
        .session = &session,
        .project_root = project.root,
        .opts = opts,
        .existing_lock = if (existing) |*l| l else null,
        .locals = std.StringHashMap(*LocalPackage).init(a),
        .profile_names = profile_names,
        .diagnostics = diagnostics,
    };
    defer ctx.deinit();
    collectLocals(&ctx, &project.manifest, &expanded.dependency_aliases) catch |err| {
        session.reportDiagnostics(diagnostics) catch {};
        return err;
    };

    // mutable path 依存の内容 digest を lock 入力へ記録する（解決に
    // 参加した宣言のみが ctx.mutable_deps に残る）。build が path 昇順
    // に正規化するため、ここでは宣言順のまま渡す。
    if (ctx.mutable_deps.items.len > 0) {
        var mutable: std.ArrayList(lock_model.MutablePath) = .empty;
        for (ctx.mutable_deps.items) |dep| {
            const digest = cache.digestTreeFollowingRoot(io, a, dep.dir, &cache.source_pin_exclude) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "cannot hash mutable path dependency \"{s}\" tree: {s}", .{ dep.path, @errorName(err) });
                    return error.ResolveFailed;
                },
            };
            try mutable.append(a, .{
                .path = dep.path,
                .sha256 = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)}),
            });
        }
        input.mutable_paths = mutable.items;
    }

    // --- profile ごとに解決 -------------------------------------------------
    var gated_root = try gatedDepNames(a, &project.manifest);
    defer gated_root.deinit();

    // root の有効な pkg 依存があれば registry が必要。feature-gated で
    // 未 activated の宣言は解決対象外なので registry を要求しない。
    // `profile` 制約は rootDeps と同じく「いずれかの profile で有効化
    // される宣言のみ」を数える（全 profile と不一致の宣言は解決され
    // ないため registry を要求しない）。
    var root_needs_registry = false;
    for ([_]*const manifest_mod.DependencyGroup{ &project.manifest.dependencies, &project.manifest.dev_dependencies }) |group| {
        var it = group.pkg.iterator();
        while (it.next()) |entry| {
            const dep = entry.value_ptr.*;
            if (dep.profile) |p| {
                var any_profile = false;
                for (profiles) |named| {
                    if (std.mem.eql(u8, named.name, p)) {
                        any_profile = true;
                        break;
                    }
                }
                if (!any_profile) continue;
            }
            if (depIsGated(&gated_root, dep.name, dep.alias) and !depIsActivated(&expanded.dependency_aliases, dep.name, dep.alias)) continue;
            root_needs_registry = true;
        }
    }
    if (root_needs_registry or ctx.needs_registry) ctx.needs_registry = true;
    if (ctx.needs_registry and opts.registry_url == null) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml", .{}, "registry dependencies require a registry url (--registry or LNAKO_REGISTRY)", .{});
        return error.RegistryRequired;
    }

    var per_profile: std.ArrayList(lock_mod.ProfileInput) = .empty;
    var primary_nodes: []const resolver.PackageNode = &.{};
    for (profiles) |named| {
        var target = resolveTarget(named.record, opts, std.mem.eql(u8, named.name, profile));
        // CLI の `-O` は選択中 profile の実装選択にのみ効く。他 profile
        // は manifest の `optimize` 宣言で解決する（この build の条件を
        // 別 profile の契約へ持ち込まない）。
        if (opts.optimize != null and !std.mem.eql(u8, named.name, profile)) {
            target.optimize = named.record.optimize orelse "O0";
        }
        var composite = Composite{
            .ctx = &ctx,
            .registry = null,
            .source_only = sourceOnly(named.record),
            .locked_index = null,
            .target = target,
            .profile_name = named.name,
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
    const lock_path = try std.fs.path.join(a, &.{ project.root, lock_name });
    // mutable path 依存を持つ lock は毎回再解決するが、結果が同一なら
    // 書き換えない。mtime だけ変わると環境の lockSha256 照合を無意味に
    // 再評価させ、writer 間の edit.lock 競合も増やすため。
    const wrote = blk: {
        if (std.Io.Dir.cwd().readFileAlloc(io, lock_path, a, .limited(64 * 1024 * 1024)) catch null) |old_bytes| {
            if (std.mem.eql(u8, old_bytes, bytes)) break :blk false;
        }
        try writeAtomic(io, lock_path, bytes);
        break :blk true;
    };

    return .{
        .arena = arena_impl,
        .lock = built,
        .wrote = wrote,
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

test {
    _ = @import("project_test.zig");
}
