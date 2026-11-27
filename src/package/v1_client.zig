//! v1 クライアント pipeline（P10 接続）。
//!
//! ローカルの固定 fixture（`v1_client_fixture`）から §4 index を読み、
//! 新 manifest（`v1_manifest`）の直接依存を `v1_resolver` で解決し、
//! 選択アーティファクトを `v1_download` の URL/hash 検証つきで取得して、
//! 新しい `nako.lock`（`v1_lock` + `v1_client_lock`）と `.nako/v1`
//! 環境（`v1_client_env` / `v1_client_materialize`）を原子的に公開する。
//!
//! 順序の契約:
//! 1. manifest を v1 として解析（旧形式は `LegacyManifest`）。
//! 2. index を推移的に読み、解決する（既存 lock は版の優先にだけ使う）。
//! 3. 新 lock の各ノードを index と照合する（`v1_lock.verify`）。
//! 4. 全ノードの実バイト列を取得し、index と lock の **両方** の SHA-256 を
//!    照合する。1 つでも不一致ならアーカイブを開かない。
//! 5. 検証済みアーカイブだけを staging に展開し、世代 dir を rename した
//!    後に `nako.lock`、最後に `.nako/v1/environment.json` を atomic に
//!    置換する。途中で失敗したら旧 lock と旧 pointer を維持する。
//!
//! 実ネットワーク・公開 API は対象外。`fixture_root` が必須。

const std = @import("std");
const builtin = @import("builtin");

const types = @import("v1_types.zig");
const v1_manifest = @import("v1_manifest.zig");
const v1_lock = @import("v1_lock.zig");
const v1_resolver = @import("v1_resolver.zig");
const v1_selection = @import("v1_selection.zig");
const v1_download = @import("v1_download.zig");
const client_fixture = @import("v1_client_fixture.zig");
const client_lock = @import("v1_client_lock.zig");
const client_index = @import("v1_client_index.zig");
const client_env = @import("v1_client_env.zig");
const client_materialize = @import("v1_client_materialize.zig");
const native_source = @import("v1_native_source.zig");
const environment = @import("environment.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Runtime = types.Runtime;
pub const SourcePermission = v1_selection.SourcePermission;
pub const legacyLockMessage = client_lock.legacyMessage;

pub const max_manifest_bytes: usize = 16 * 1024 * 1024;

pub const Error = error{
    ProjectNotFound,
    LegacyManifest,
    InvalidManifest,
    UnknownProfile,
    UnknownFeature,
    DuplicateDependency,
    FixtureSourceRequired,
    InvalidRegistryUrl,
    ResolveFailed,
    LockIndexMismatch,
    LockedNotSatisfied,
    LegacyLock,
    MissingArtifact,
    ArtifactTooLarge,
    EnvironmentInvalid,
    /// 検証済み ZIP の global フラグ・命令名集合が index の宣言と一致しない。
    GlobalCommandsMismatch,
    NoPackages,
    OutOfMemory,
};

pub const Limits = struct {
    max_manifest_bytes: usize = max_manifest_bytes,
    /// `.npkg` 1 個の上限（圧縮後）。§3.2 の既定 25 MiB。
    max_artifact_bytes: usize = 25 * 1024 * 1024,
    /// 1 回の sync で取得する実バイト列の合計上限。
    max_total_artifact_bytes: usize = 100 * 1024 * 1024,
    index: client_index.Limits = .{},
};

pub const Options = struct {
    /// プロジェクトルート（`findRoot` 済みの絶対 path でもよい）。
    project_root: []const u8 = ".",
    /// pin 済みのルート handle。設定すると manifest・lock・`.nako` の
    /// 読み書きをこの handle 相対で行う。所有権は呼び出し側に残る。
    project_dir: ?std.Io.Dir = null,
    /// ローカル fixture のルート。v1 では必須。
    fixture_root: ?[]const u8 = null,
    /// index の基底 URL（`https://host[/prefix]`）。
    registry_url: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    /// `--runtime`。null なら profile 宣言（無ければ lnako）。
    runtime: ?types.Runtime = null,
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
    /// lock を書き換えない。現在の manifest と一致しなければ失敗する。
    locked: bool = false,
    /// profile が一致していても再解決して lock を書き直す。
    force_resolve: bool = false,
    /// 同一世代の環境が完成していれば展開を省略する。
    reuse_environment: bool = true,
    target_triple: ?[]const u8 = null,
    abi_min: u32 = 1,
    abi_max: u32 = 1,
    glibc: ?[]const u8 = null,
    /// `native-source` のローカルビルド許可（ルートが ID と SHA-256 で固定）。
    source_permissions: []const v1_selection.SourcePermission = &.{},
    /// 許可済み `native-source` のビルド規約。既定はホストの `zig build`。
    native_source: native_source.Options = .{},
    /// native-source のビルドへ渡す親環境。指定時は
    /// `ZIG_GLOBAL_CACHE_DIR` だけを staging 内へ向けた複製を作る。
    environ_map: ?*const std.process.Environ.Map = null,
    materializer: client_materialize.Materializer = .{},
    limits: Limits = .{},
    /// テスト専用: active pointer の置換直前に失敗させ、公開のロールバック
    /// を検証する。通常の CLI からは設定しない。
    test_fail_pointer: bool = false,
};

pub const Report = struct {
    arena: *std.heap.ArenaAllocator,
    root: []const u8,
    profile: []const u8,
    runtime: types.Runtime,
    generation: []const u8,
    /// 公開した世代の `environment.json` と同一バイト列（`--json` 用）。
    environment_json: []const u8,
    lock_wrote: bool,
    lock_sha256: []const u8,
    package_count: usize,
    warnings: []const []const u8,
    reused_environment: bool,

    pub fn deinit(self: *Report) void {
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// `nako.toml` が v1 かどうかを、旧経路へ入る前に判定する。
/// 旧形式（識別可能）は false。壊れた v1 は true を返し、v1 側で詳細診断する。
pub fn isV1Manifest(allocator: Allocator, io: std.Io, root_dir: std.Io.Dir) !bool {
    const bytes = readManifest(allocator, io, root_dir, max_manifest_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = v1_manifest.parse(allocator, bytes, .local) catch |err| switch (err) {
        error.LegacyManifest => return false,
        else => return std.mem.indexOf(u8, bytes, "schema_version") != null,
    };
    parsed.deinit();
    return true;
}

pub const Project = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    root: []const u8,
    root_dir: std.Io.Dir,
    manifest_path: []const u8,
    manifest_bytes: []const u8,
    manifest: v1_manifest.Manifest,

    pub fn deinit(self: *Project) void {
        self.manifest.deinit();
        self.root_dir.close(self.io);
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// ルートを検出して v1 manifest を読む。`root_dir` を渡した場合はその
/// handle の所有権を引き継ぐ（成功時 Project、失敗時は close）。
pub fn loadProject(
    allocator: Allocator,
    io: std.Io,
    project_root: []const u8,
    provided_dir: ?std.Io.Dir,
) !Project {
    const root_abs = if (provided_dir != null)
        try allocator.dupe(u8, project_root)
    else blk: {
        const found = try findProjectRoot(allocator, io, project_root);
        break :blk found orelse return error.ProjectNotFound;
    };
    defer allocator.free(root_abs);

    var dir = provided_dir orelse std.Io.Dir.cwd().openDir(io, root_abs, .{
        .iterate = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectNotFound,
        else => return err,
    };
    errdefer dir.close(io);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    const root = try a.dupe(u8, root_abs);
    const bytes = try readManifest(a, io, dir, max_manifest_bytes);
    const manifest = v1_manifest.parse(a, bytes, .local) catch |err| switch (err) {
        error.LegacyManifest => return error.LegacyManifest,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    return .{
        .arena = arena,
        .io = io,
        .root = root,
        .root_dir = dir,
        .manifest_path = try std.fs.path.join(a, &.{ root, "nako.toml" }),
        .manifest_bytes = bytes,
        .manifest = manifest,
    };
}

/// `start` から親へ `nako.toml` を探し、実在 root を絶対 path で返す。
/// symlink 経由の綴り揺れを避けるため realPath に固定する。
fn findProjectRoot(allocator: Allocator, io: std.Io, start: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectNotFound,
        else => return err,
    };
    defer allocator.free(cwd);
    var dir = try std.fs.path.resolve(allocator, if (std.fs.path.isAbsolute(start))
        &.{start}
    else
        &.{ cwd, start });
    defer allocator.free(dir);
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir, "nako.toml" });
        defer allocator.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |found| {
            if (found.kind != .file) return error.InvalidManifest;
            const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, dir, allocator) catch |err| switch (err) {
                error.FileNotFound => return error.ProjectNotFound,
                else => return err,
            };
            defer allocator.free(resolved);
            return try allocator.dupe(u8, resolved);
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        const next = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = next;
    }
}

fn readManifest(allocator: Allocator, io: std.Io, dir: std.Io.Dir, max_bytes: usize) ![]u8 {
    const stat = dir.statFile(io, "nako.toml", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.InvalidManifest;
    if (stat.kind != .file) return error.InvalidManifest;
    if (stat.size > max_bytes) return error.InvalidManifest;
    const file = try dir.openFile(io, "nako.toml", .{ .follow_symlinks = false });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidManifest,
        else => return err,
    };
    if (bytes.len > max_bytes) {
        allocator.free(bytes);
        return error.InvalidManifest;
    }
    return bytes;
}

const SelectionContext = struct {
    target: v1_selection.Target,
    permissions: []const v1_selection.SourcePermission,
    failure: ?v1_selection.Failure = null,

    fn selectFn(context: ?*anyopaque, id: []const u8, artifacts: []const types.Artifact) anyerror!?usize {
        const self: *SelectionContext = @ptrCast(@alignCast(context orelse return null));
        return switch (v1_selection.evaluate(id, artifacts, self.target, self.permissions)) {
            .selected => |index| index,
            .failed => |failure| blk: {
                self.failure = failure;
                break :blk null;
            },
        };
    }
};

const Fetched = struct {
    node: *const v1_lock.Node,
    artifact: *const types.Artifact,
    bytes: []u8,
    sha256: [32]u8,
};

pub fn run(allocator: Allocator, io: std.Io, options: Options, diagnostics: *@import("diagnostics.zig").List) !Report {
    // `project_dir` の所有権は run が引き継ぐ。project 読込より前に失敗する
    // 経路（fixture/registry 未指定）でも handle を閉じる。
    var pending_dir = options.project_dir;
    errdefer if (pending_dir) |dir| dir.close(io);

    const fixture_root = options.fixture_root orelse return error.FixtureSourceRequired;
    const registry_url = options.registry_url orelse return error.InvalidRegistryUrl;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    const provided_dir = pending_dir;
    pending_dir = null; // 所有権は loadProject へ（成功/失敗とも消費する）。
    var project = try loadProject(a, io, options.project_root, provided_dir);
    defer project.deinit();

    const choice = v1_manifest.selectProfile(&project.manifest, options.profile) catch |err| {
        try addDiagnostic(diagnostics, "nako.toml", "profile を解決できません（--profile を指定してください）");
        return err;
    };
    const runtime = options.runtime orelse choice.runtime;

    const roots = v1_manifest.effectiveRootDependencies(&project.manifest, a, runtime, options.features, options.no_default_features) catch |err| {
        switch (err) {
            error.UnknownFeature => try addDiagnostic(diagnostics, "nako.toml", "要求した feature は宣言されていません"),
            error.DuplicateDependency => try addDiagnostic(diagnostics, "nako.toml", "同じ Package ID が dependencies と runtime-dependencies に異なる内容で宣言されています"),
            else => {},
        }
        return err;
    };

    var index_source = client_index.Source.init(a, io, fixture_root, registry_url, options.limits.index) catch |err| {
        try addDiagnostic(diagnostics, "index", switch (err) {
            error.MissingConfig => "index/v1/config.json を fixture から取得できません",
            error.ConfigMismatch => "index/v1/config.json が §4 と一致しません",
            error.InvalidRegistryUrl => "registry URL は HTTPS の絶対 URL で指定してください",
            else => "index を取得できません",
        });
        return err;
    };
    defer index_source.deinit();
    index_source.loadClosure(roots, runtime) catch |err| {
        try addDiagnostic(diagnostics, "index", switch (err) {
            error.IndexLimit => "index のパッケージ数が上限を超えました",
            error.IndexTooLarge => "index の合計サイズが上限を超えました",
            error.ConfigMismatch => "index の内容が §4 と一致しません",
            else => "index を取得できません",
        });
        return err;
    };

    var existing_lock: ?v1_lock.Lock = client_lock.readDir(a, io, project.root_dir) catch |err| switch (err) {
        error.LegacyLock => {
            try addDiagnostic(diagnostics, "nako.lock", client_lock.legacyMessage());
            return error.LegacyLock;
        },
        else => return err,
    };
    defer if (existing_lock) |*lock| lock.deinit();

    const host = try hostTarget(a, options);
    const permissions = options.source_permissions;
    var selection = SelectionContext{
        .target = switch (runtime) {
            .lnako => v1_selection.Target.forLnako(host.triple, .{ .min = options.abi_min, .max = options.abi_max }, host.glibc),
            else => v1_selection.Target.forRuntime(runtime),
        },
        .permissions = permissions,
    };

    const resolver_packages = try index_source.resolverPackages();
    const outcome = try v1_resolver.resolve(a, .{
        .profile = choice.name,
        .runtime = runtime,
        .target_triple = if (runtime == .lnako) host.triple else null,
        .root = roots,
        .index = resolver_packages,
        .lock = if (existing_lock) |*lock| lock else null,
        .lock_profile = choice.name,
        .artifacts = .{ .ctx = &selection, .selectFn = SelectionContext.selectFn },
    });

    var graph = switch (outcome) {
        .resolved => |resolved| resolved,
        .failed => |failure| {
            const detail = try describeFailure(a, failure, selection.failure);
            try addDiagnostic(diagnostics, "nako.toml", detail);
            return error.ResolveFailed;
        },
    };
    defer graph.deinit();

    var warnings: std.ArrayList([]const u8) = .empty;
    for (graph.warnings) |warning| {
        if (warning.kind == .yanked_from_lock) {
            try warnings.append(a, try std.fmt.allocPrint(a, "yanked 版 {s} {s} を既存 lock から使用します", .{ warning.id, warning.version }));
        }
    }

    var new_lock = try graph.toLock();
    defer new_lock.deinit();

    var merged_lock: ?v1_lock.Lock = null;
    defer if (merged_lock) |*lock| lock.deinit();

    const existing_profile: ?*const v1_lock.Profile = if (existing_lock) |*lock| lock.findProfile(choice.name) else null;
    const same_profile = if (existing_profile) |profile| client_lock.profileEqual(profile.*, new_lock.profiles[0]) else false;

    var chosen: *const v1_lock.Lock = undefined;
    var lock_wrote = false;
    if (existing_lock != null and same_profile and !options.force_resolve) {
        chosen = &existing_lock.?;
    } else if (options.locked) {
        try addDiagnostic(diagnostics, "nako.lock", "現在の nako.toml / index と一致する lock がないため --locked を満たせません");
        return error.LockedNotSatisfied;
    } else if (existing_lock != null) {
        merged_lock = try client_lock.mergeLock(a, &existing_lock.?, &new_lock);
        chosen = &merged_lock.?;
        lock_wrote = true;
    } else {
        chosen = &new_lock;
        lock_wrote = true;
    }

    // 既存 lock の生バイト列は一度だけ読み、lock を書き換えない場合の
    // digest と、公開失敗時の rollback の両方で同じ読み取り結果を使う。
    // 論理 lock が同じでも、受理済みの空白などでディスク上のバイト列は
    // canonical 表現と異なり得る。環境は実際の lock バイト列で照合される
    // ため、ここで canonical 列をハッシュしてはならない。
    const previous_lock_bytes: ?[]u8 = if (existing_lock != null)
        try readLockBytes(a, io, project.root_dir) orelse return error.InvalidLock
    else
        null;

    // lock_wrote=false ではディスク上の生バイト列、true では実際に書く
    // canonical 列をハッシュする。どちらも環境の lock_sha256 と一致させる。
    const written_lock_bytes: ?[]u8 = if (lock_wrote) try client_lock.toBytes(chosen, a) else null;
    const lock_sha256 = try sha256Text(a, written_lock_bytes orelse previous_lock_bytes orelse return error.InvalidLock);

    // 選択 profile だけを index と照合する（保持した他 profile は現在の
    // index closure に含まれないため、ここでは検証対象にしない）。
    const one_profile = [1]v1_lock.Profile{chosen.findProfile(choice.name).?.*};
    var lock_view: v1_lock.Lock = undefined;
    lock_view.profiles = @constCast(&one_profile);
    const lock_releases = try index_source.lockReleases(a);
    const lock_report = try v1_lock.verify(a, &lock_view, lock_releases, .{});
    if (lock_report.failure) |failure| {
        const detail = try std.fmt.allocPrint(a, "lock と index が一致しません: {s} {s}@{s}", .{
            @tagName(failure.kind), failure.id, failure.version,
        });
        try addDiagnostic(diagnostics, "nako.lock", detail);
        return error.LockIndexMismatch;
    }
    for (lock_report.warnings) |warning| {
        if (warning.kind == .yanked_node) {
            try warnings.append(a, try std.fmt.allocPrint(a, "yanked 版 {s} {s} を既存 lock から使用します", .{ warning.id, warning.version }));
        }
    }

    const profile = chosen.findProfile(choice.name).?;

    // --- 取得と SHA-256 照合（アーカイブを開く前） --------------------------
    var fetched: std.ArrayList(Fetched) = .empty;
    var total_artifact_bytes: usize = 0;
    for (profile.nodes) |*node| {
        const artifact = index_source.artifactFor(node.id, node.version, node.kind, node.sha256) orelse {
            try addDiagnostic(diagnostics, "nako.lock", "選択したアーティファクトが index にありません");
            return error.MissingArtifact;
        };
        const result = v1_download.fetch(a, .{ .context = &index_source.fixture, .function = fetchViaFixture }, .{
            .config = &index_source.config,
            .artifact = artifact.*,
            .options = .{
                .max_bytes = options.limits.max_artifact_bytes,
                .lock_sha256 = node.sha256,
            },
        }) catch |err| {
            const detail = try std.fmt.allocPrint(a, "取得またはハッシュ照合に失敗しました（{s}）: {s} {s}", .{
                @errorName(err), node.id, node.version,
            });
            try addDiagnostic(diagnostics, "index", detail);
            return switch (err) {
                error.TooLarge => error.ArtifactTooLarge,
                else => err,
            };
        };
        total_artifact_bytes += result.bytes.len;
        if (total_artifact_bytes > options.limits.max_total_artifact_bytes) {
            var mutable = result;
            mutable.deinit(a);
            return error.ArtifactTooLarge;
        }
        try fetched.append(a, .{
            .node = node,
            .artifact = artifact,
            .bytes = result.bytes,
            .sha256 = result.sha256,
        });
    }

    var known_packages: std.ArrayList(client_env.Package) = .empty;
    for (fetched.items) |item| {
        try known_packages.append(a, .{
            .id = item.node.id,
            .version = item.node.version,
            .kind = item.node.kind,
            .sha256 = item.node.sha256,
            .root = try packagesRoot(a, item.node.sha256),
        });
    }
    const generation = try client_env.generationName(a, choice.name, lock_sha256, known_packages.items);

    var store = try client_env.Store.open(io, project.root_dir);
    defer store.deinit();

    var reused_environment = false;
    if (options.reuse_environment and !lock_wrote) {
        if (try store.readPointer(a)) |pointer| {
            if (std.mem.eql(u8, pointer, generation)) {
                // 壊れた世代は失敗にせず作り直す。index の global 宣言が
                // 変わった場合も再利用せず、下の materialize で ZIP と照合する。
                // 同じ SHA-256 のまま index の runtime/native 属性が変わった
                // 場合も、実取得済み ZIP を materialize と同じ検証へ通して
                // からでなければ再利用しない（全再展開はしない）。
                const reusable = blk: {
                    var loaded = (store.load(a) catch break :blk false) orelse break :blk false;
                    defer loaded.deinit();
                    if (!(std.mem.eql(u8, loaded.profile, choice.name) and
                        std.mem.eql(u8, loaded.lock_sha256, lock_sha256) and
                        std.mem.eql(u8, loaded.generation, generation)))
                    {
                        break :blk false;
                    }
                    if (loaded.packages.len != fetched.items.len) break :blk false;
                    for (fetched.items) |item| {
                        const package = findLoadedPackage(loaded.packages, item.node) orelse break :blk false;
                        const release = index_source.releaseFor(item.node.id, item.node.version) orelse break :blk false;
                        if (release.exports_global_commands != package.exports_global_commands) break :blk false;
                        if (!sameGlobalCommandSet(release.global_commands, package.global_commands)) break :blk false;

                        var verified = client_materialize.verifyArtifact(
                            a,
                            item.artifact,
                            .{
                                .id = item.node.id,
                                .version = item.node.version,
                                .kind = item.node.kind,
                                .runtime = runtime,
                            },
                            item.bytes,
                        ) catch |err| {
                            try addDiagnostic(diagnostics, "index", "index の runtime/native 情報が検証済み ZIP と一致しません（公開しません）");
                            return err;
                        };
                        defer verified.deinit();
                        const described = try client_materialize.describe(&verified, a, a);
                        if (release.exports_global_commands != described.exports_global_commands or
                            !sameGlobalCommandSet(release.global_commands, described.global_commands))
                        {
                            try addDiagnostic(diagnostics, "index", "index の global 情報が検証済み ZIP と一致しません（公開しません）");
                            return error.GlobalCommandsMismatch;
                        }
                    }
                    break :blk true;
                };
                if (reusable) reused_environment = true;
            }
        }
    }

    var environment_json: []const u8 = undefined;
    if (reused_environment) {
        environment_json = try store.readGenerationJson(a, generation);
    } else {
        const staging_name = try stagingName(a, generation);
        var staging = try store.openStaging(generation);
        var staging_open = true;
        errdefer {
            if (staging_open) staging.close(io);
            environment.deleteTreeChecked(store.v1, io, staging_name) catch {};
        }

        const packages_dir = try environment.openManagedChildDir(staging, io, client_env.packages_dir, false);
        var packages_dir_open = true;
        defer if (packages_dir_open) packages_dir.close(io);

        var packages: std.ArrayList(client_env.Package) = .empty;
        for (fetched.items) |item| {
            const hex = item.node.sha256[7..];
            const package_dir = try environment.openManagedChildDir(packages_dir, io, hex, false);
            var package_dir_open = true;
            defer if (package_dir_open) package_dir.close(io);

            var result = try options.materializer.materialize(
                io,
                a,
                item.artifact,
                .{
                    .id = item.node.id,
                    .version = item.node.version,
                    .kind = item.node.kind,
                    .runtime = runtime,
                },
                item.bytes,
                package_dir,
                a,
            );

            // index の global 宣言は解決・衝突判定に使われる。検証済み ZIP の
            // 導出値と公開前に照合し、食い違う世代を lock/環境へ出さない。
            const release = index_source.releaseFor(item.node.id, item.node.version) orelse {
                try addDiagnostic(diagnostics, "index", "選択した版が index にありません");
                return error.MissingArtifact;
            };
            if (release.exports_global_commands != result.exports_global_commands or
                !sameGlobalCommandSet(release.global_commands, result.global_commands))
            {
                try addDiagnostic(diagnostics, "index", "index の global 情報が検証済み ZIP と一致しません（公開しません）");
                return error.GlobalCommandsMismatch;
            }

            // 許可済み native-source は、取得・lock 照合を終えた実バイト列の
            // 展開後にだけビルドする。ビルド関数自身が ID + SHA-256 の許可を
            // 再検査し、成果物を export の "." へ接続する。
            if (item.node.kind == .@"native-source") {
                var native_options = options.native_source;
                native_options.environ_map = options.environ_map;
                result.exports = native_source.build(
                    a,
                    io,
                    native_options,
                    package_dir,
                    item.node.id,
                    item.node.sha256,
                    permissions,
                    result.exports,
                ) catch |err| {
                    const detail = try std.fmt.allocPrint(a, "native-source のローカルビルドに失敗しました（{s}）: {s} {s}", .{
                        @errorName(err), item.node.id, item.node.version,
                    });
                    try addDiagnostic(diagnostics, "nako.lock", detail);
                    return err;
                };
            }

            package_dir.close(io);
            package_dir_open = false;

            try packages.append(a, .{
                .id = item.node.id,
                .version = item.node.version,
                .kind = item.node.kind,
                .sha256 = item.node.sha256,
                .root = try packagesRoot(a, item.node.sha256),
                .exports = result.exports,
                .exports_global_commands = result.exports_global_commands,
                .global_commands = result.global_commands,
            });
        }
        packages_dir.close(io);
        packages_dir_open = false;

        const env_document = client_env.Environment{
            .generation = generation,
            .profile = choice.name,
            .runtime = runtime,
            .target_triple = if (runtime == .lnako) host.triple else null,
            .lock_sha256 = lock_sha256,
            .packages = packages.items,
        };
        const env_bytes = try client_env.emit(a, &env_document);
        if (env_bytes.len > client_env.max_environment_bytes) return error.EnvironmentInvalid;
        try staging.writeFile(io, .{ .sub_path = client_env.generation_file, .data = env_bytes });

        // 公開順は「世代 rename → lock → active pointer」。rename が失敗しても
        // lock をまだ書いていないため、旧 lock と旧環境はそのまま読める。
        const active_generation = store.readPointer(a) catch null;
        const replacing_active = if (active_generation) |active|
            std.mem.eql(u8, active, generation)
        else
            false;

        // 同名世代の置換では lock digest が変わらない（世代名は lock_sha256 を
        // 含む）。rename 失敗時に旧環境と lock を一致させるため、この場合だけ
        // lock を先に置く。
        var lock_published = false;
        if (lock_wrote and replacing_active) {
            try client_lock.writeCanonicalDir(io, project.root_dir, written_lock_bytes.?);
            lock_published = true;
        }

        const created = store.commitStaging(generation, &staging, env_bytes) catch |err| {
            staging_open = false;
            return err;
        };
        staging_open = false;
        _ = created;

        if (lock_wrote and !lock_published) {
            try client_lock.writeCanonicalDir(io, project.root_dir, written_lock_bytes.?);
        }

        // active pointer の置換が失敗したら、先に書いた新 lock を旧内容へ
        // 戻す。新世代 dir は active でないため、旧 pointer と旧 lock だけで
        // 旧プロジェクトをそのまま読める。
        if (options.test_fail_pointer) {
            if (lock_wrote and !lock_published) {
                rollbackLock(io, project.root_dir, previous_lock_bytes) catch |rollback_err| {
                    try addDiagnostic(diagnostics, "nako.lock", "公開失敗後に旧 lock を復元できませんでした");
                    return rollback_err;
                };
            }
            return error.InjectedPublishFailure;
        }
        store.writePointer(generation) catch |err| {
            if (lock_wrote and !lock_published) {
                rollbackLock(io, project.root_dir, previous_lock_bytes) catch |rollback_err| {
                    try addDiagnostic(diagnostics, "nako.lock", "公開失敗後に旧 lock を復元できませんでした");
                    return rollback_err;
                };
            }
            return err;
        };
        environment_json = env_bytes;
    }

    if (reused_environment and lock_wrote) {
        // 通常は lock_wrote が真なら世代を作り直すため到達しない。将来の
        // 再利用条件変更に備えて lock だけは必ず反映する。
        try client_lock.writeCanonicalDir(io, project.root_dir, written_lock_bytes.?);
    }

    return .{
        .arena = arena,
        .root = try a.dupe(u8, project.root),
        .profile = try a.dupe(u8, choice.name),
        .runtime = runtime,
        .generation = generation,
        .environment_json = environment_json,
        .lock_wrote = lock_wrote,
        .lock_sha256 = lock_sha256,
        .package_count = fetched.items.len,
        .warnings = try warnings.toOwnedSlice(a),
        .reused_environment = reused_environment,
    };
}

fn packagesRoot(allocator: Allocator, sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "packages/{s}", .{sha256[7..]});
}

fn findLoadedPackage(packages: []const client_env.Package, node: *const v1_lock.Node) ?client_env.Package {
    for (packages) |package| {
        if (std.mem.eql(u8, package.id, node.id) and
            std.mem.eql(u8, package.version, node.version) and
            std.mem.eql(u8, package.sha256, node.sha256))
        {
            return package;
        }
    }
    return null;
}

/// `nako.lock` の生バイト列（存在しなければ null）。lock を書き換えない
/// 場合の digest 計算と、rollback で canonical 化し直さず公開前のファイル
/// 内容をそのまま戻すために使う。
fn readLockBytes(allocator: Allocator, io: std.Io, project_dir: std.Io.Dir) !?[]u8 {
    const stat = project_dir.statFile(io, client_lock.lock_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.UnsafeLockFile;
    if (stat.kind != .file) return error.InvalidLockFile;
    if (stat.size > client_lock.max_lock_bytes) return error.LockTooLarge;
    return try project_dir.readFileAlloc(io, client_lock.lock_name, allocator, .limited(client_lock.max_lock_bytes));
}

/// 公開失敗時に `nako.lock` を旧内容へ戻す。旧 lock が無ければ新規作成分を
/// 削除する。呼び出し側は lock を書いた後、pointer を置換する前にだけ使う。
fn rollbackLock(io: std.Io, project_dir: std.Io.Dir, previous: ?[]const u8) !void {
    if (previous) |bytes| {
        try client_lock.writeCanonicalDir(io, project_dir, bytes);
        return;
    }
    project_dir.deleteFile(io, client_lock.lock_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn stagingName(allocator: Allocator, generation: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".staging-{s}", .{generation});
}

fn fetchViaFixture(context: ?*anyopaque, allocator: Allocator, url: []const u8) anyerror!v1_download.Response {
    const source: *client_fixture.Source = @ptrCast(@alignCast(context orelse return error.FixtureNotFound));
    const response = try source.get(allocator, url);
    return .{ .status = response.status, .location = response.location, .body = response.body };
}

fn sha256Text(allocator: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

const HostTarget = struct {
    triple: []const u8,
    /// GNU Linux の `native-prebuilt` 選択に渡す実ホストの glibc。
    /// 非 GNU、または明示指定が無い非 Linux では null。
    glibc: ?[]const u8 = null,
};

fn hostTarget(allocator: Allocator, options: Options) !HostTarget {
    if (options.target_triple) |triple| {
        if (!types.validTargetTriple(triple)) return error.InvalidRegistryUrl;
        return .{ .triple = triple, .glibc = options.glibc };
    }
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        else => "none",
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .arm => "arm",
        .wasm32 => "wasm32",
        else => "x86_64",
    };
    const abi = if (std.mem.eql(u8, os, "windows"))
        "msvc"
    else if (std.mem.eql(u8, os, "linux"))
        switch (builtin.abi) {
            .musl => "musl",
            .none => "none",
            else => "gnu",
        }
    else
        "none";
    const triple = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ arch, os, abi });
    // 通常 CLI では `--glibc` を要求しない。GNU Linux の実ホスト版を
    // ここで取得し、同じ triple・実 ABI の prebuilt 選択へ渡す。
    const glibc = options.glibc orelse
        if (std.mem.eql(u8, abi, "gnu")) try detectHostGlibc(allocator) else null;
    return .{ .triple = triple, .glibc = glibc };
}

/// GNU Linux ホストの glibc 版（例 `2.39`）。それ以外の target では null。
/// 非 GNU target では `gnu_get_libc_version` を参照しないよう、comptime で
/// 分岐して不要なシンボルを持ち込まない。
fn detectHostGlibc(allocator: Allocator) !?[]const u8 {
    if (comptime builtin.os.tag == .linux and builtin.abi == .gnu) {
        const version = gnu_get_libc_version() orelse return null;
        return try allocator.dupe(u8, std.mem.span(version));
    }
    return null;
}

extern "c" fn gnu_get_libc_version() ?[*:0]const u8;

fn describeFailure(
    allocator: Allocator,
    failure: v1_resolver.Failure,
    selection_failure: ?v1_selection.Failure,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    switch (failure.kind) {
        .unknown_package => try writer.print("未知のパッケージです: {s}（{s}）", .{ failure.id, failure.req }),
        .no_solution => try writer.print("依存を解決できません: {s} {s}", .{ failure.id, failure.req }),
        .global_version_conflict => try writer.print("global 命令を持つ {s} を単一版に収束できません", .{failure.id}),
        .global_command_conflict => try writer.print("global 命令名が衝突します: {s}", .{failure.id}),
        .invalid_range => try writer.print("バージョン範囲が不正です: {s} {s}", .{ failure.id, failure.req }),
        .invalid_release => try writer.print("index の版が不正です: {s} {s}", .{ failure.id, failure.req }),
        .feature_cycle => try writer.print("feature が循環しています: {s}", .{failure.id}),
        .unknown_feature => try writer.print("未知の feature です: {s} {s}", .{ failure.id, failure.req }),
        .artifact_selection_failed => {
            if (selection_failure) |detail| {
                const text = v1_selection.formatFailure(allocator, detail) catch null;
                if (text) |message| {
                    try writer.writeAll(message);
                } else {
                    try writer.print("適合するアーティファクトがありません: {s} {s}", .{ failure.id, failure.req });
                }
            } else {
                try writer.print("適合するアーティファクトがありません: {s} {s}", .{ failure.id, failure.req });
            }
        },
    }
    if (failure.detail.len > 0) try writer.print(" ({s})", .{failure.detail});
    return output.toOwnedSlice();
}

fn addDiagnostic(diagnostics: *@import("diagnostics.zig").List, path: []const u8, message: []const u8) !void {
    try diagnostics.addFmt(@import("diagnostics.zig").E029_INVALID_VALUE, .err, path, .{}, "{s}", .{message});
}

/// global 命令名を集合として比較する。index と ZIP の並び順は契約では
/// 固定されないため、順序ではなく要素の一致だけを見る。
fn sameGlobalCommandSet(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left) |name| {
        var found = false;
        for (right) |other| {
            if (std.mem.eql(u8, name, other)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// 選択済み profile の edge（alias・global 許可）を runtime 側で使うための
/// lock 読み出し。旧 lock は `error.LegacyLock`。
pub const Lock = v1_lock.Lock;
pub fn loadLock(allocator: Allocator, io: std.Io, project_dir: std.Io.Dir) !?Lock {
    return client_lock.readDir(allocator, io, project_dir);
}

/// `.nako/v1` の環境を読み、実在を検証する。旧 `.nako/environment.json` は
/// 読まない（v1 未実行なら null）。
pub fn loadEnvironment(allocator: Allocator, io: std.Io, project_dir: std.Io.Dir) !?client_env.Environment {
    var store = (try client_env.Store.openExisting(io, project_dir)) orelse return null;
    defer store.deinit();
    return store.load(allocator);
}

pub const LoadedEnvironment = client_env.Environment;

test "isV1Manifest は v1 と旧 manifest を識別し、symlink manifest を拒否する" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "schema_version = 1\n[package]\nid = \"@acme/app\"\nversion = \"0.1.0\"\nlicense = \"MIT\"\n",
    });
    try testing.expect(try isV1Manifest(testing.allocator, io, temporary.dir));

    try temporary.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n",
    });
    try testing.expect(!try isV1Manifest(testing.allocator, io, temporary.dir));

    if (@import("builtin").os.tag != .windows) {
        try temporary.dir.writeFile(io, .{ .sub_path = "real.toml", .data = "schema_version = 1\n" });
        try temporary.dir.deleteFile(io, "nako.toml");
        try temporary.dir.symLink(io, "real.toml", "nako.toml", .{});
        try testing.expectError(error.InvalidManifest, isV1Manifest(testing.allocator, io, temporary.dir));
    }
}

test "v1 の既定 profile は合成され、不明 profile は拒否される" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var manifest = try v1_manifest.parse(arena.allocator(), "schema_version = 1\n[package]\n", .local);
    defer manifest.deinit();
    const default = try v1_manifest.selectProfile(&manifest, null);
    try testing.expectEqualStrings("default", default.name);
    try testing.expectEqual(types.Runtime.lnako, default.runtime);
    try testing.expectError(error.UnknownProfile, v1_manifest.selectProfile(&manifest, "windows"));
}

test {
    _ = @import("v1_client_e2e_test.zig");
}
