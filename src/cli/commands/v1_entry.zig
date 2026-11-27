//! `nako.toml` の v1 入口判定と、旧形式を旧経路へ流さないための診断。
//!
//! `sync` と `run`/`build`/`test` の自動準備は、このモジュールで manifest を
//! 先に分類する。旧 manifest は読み替えず再作成を案内し（Q12）、v1 manifest
//! は旧 `project.load` へ渡さない。v1 で依存が無いローカルプロジェクトは
//! 環境なしで受理し、依存があるのに v1 環境が無い場合は fixture 指定の
//! `sync` を案内する（旧 `nako.lock` / `.nako` へはフォールバックしない）。
//!
//! 判定は pin 済みの root handle 相対で行える。root path の rename/置換で
//! 別 dir の manifest を読まないよう、呼出し側は保持中の handle を渡す。

const std = @import("std");
const lnako = @import("lnako");

const v1_manifest = lnako.package.v1_manifest;

/// `v1_manifest` の読み取り上限と同じ値。ここでは v1 入口判定だけを行う。
pub const max_manifest_bytes: usize = 16 * 1024 * 1024;

pub const ManifestProbe = union(enum) {
    /// `nako.toml` が無い。
    missing,
    /// 旧形式（識別可能）。読み替えない。
    legacy,
    /// schema_version = 1 を意図したが v1 として不正。
    invalid: v1_manifest.ParseError,
    /// v1 manifest。`source` は `manifest` が参照するため一緒に保持する。
    v1: struct {
        manifest: v1_manifest.Manifest,
        source: []u8,
    },

    pub fn deinit(self: *ManifestProbe, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .v1 => |*value| {
                value.manifest.deinit();
                allocator.free(value.source);
            },
            else => {},
        }
    }
};

/// 旧 manifest の再作成案内。暗黙変換は行わない（仕様 §2、Q12）。
pub const legacy_manifest_message =
    "旧形式の nako.toml を検出しました。v1 では先頭の `schema_version = 1` と" ++
    " [package]（配布時は id/version/license）が必要です。旧形式は読み替えず、" ++
    "暗黙の変換も行わないため、nako.toml を v1 形式で再作成してください";

/// v1 の依存環境が無いときの案内。fixture 指定の sync を通常経路にする。
pub const sync_fixture_guidance =
    "v1 の依存環境（nako.lock と .nako/v1）がありません。旧 nako.lock / .nako へは" ++
    "フォールバックしません。プロジェクトルートで `lnako sync --v1-fixture <fixture-dir>`" ++
    " を実行してください";

/// v1 プロジェクトで旧 lock 生成コマンドを使わないための案内。
pub const v1_lock_guidance =
    "v1 プロジェクトの nako.lock は `lnako sync --v1-fixture <fixture-dir>` が生成します。" ++
    " `lnako lock` は旧形式専用のため v1 では使いません";

/// v1 プロジェクトで旧 manifest / 旧 lock 専用コマンドを使わないための案内。
/// 旧形式の読み替えや暗黙変換は行わず、v1 で使える代替だけを示す。
pub fn legacyOnlyGuidance(verb: []const u8) []const u8 {
    if (std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "remove")) {
        return "v1 の依存は nako.toml の [dependencies] を直接編集し、" ++
            "`lnako sync --v1-fixture <fixture-dir>` で nako.lock を生成してください" ++
            "（`lnako add`/`remove` は旧 manifest 専用です）";
    }
    if (std.mem.eql(u8, verb, "update")) {
        return "v1 の依存更新は nako.toml を編集して" ++
            " `lnako sync --v1-fixture <fixture-dir>` で再解決してください" ++
            "（`lnako update` は旧 lock 専用です）";
    }
    if (std.mem.eql(u8, verb, "tree") or std.mem.eql(u8, verb, "why")) {
        return "v1 の依存グラフ表示は未対応です。解決結果は" ++
            " `lnako sync --v1-fixture <fixture-dir>` が生成する nako.lock と" ++
            " .nako/v1 に記録されます（旧 lock を読み替える `tree`/`why` は使いません）";
    }
    if (std.mem.eql(u8, verb, "check")) {
        return "v1 の lock 一致検査は" ++
            " `lnako sync --v1-fixture <fixture-dir> --locked` を使ってください" ++
            "（`lnako check` は旧環境専用です）";
    }
    return "旧 manifest / 旧 lock 専用コマンドのため v1 では使いません。" ++
        " `lnako sync --v1-fixture <fixture-dir>` を使ってください";
}

/// `nako.toml` を v1 入口として分類する。`dir` を渡した場合はその handle
/// 相対で読み、渡さない場合は `project_root` を no-follow で開く。
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    dir: ?*const std.Io.Dir,
) !ManifestProbe {
    if (dir) |existing| return probeDir(allocator, io, existing);
    var owned = std.Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer owned.close(io);
    return probeDir(allocator, io, &owned);
}

/// 保持中の dir handle 相対で `nako.toml` を分類する。
pub fn probeDir(allocator: std.mem.Allocator, io: std.Io, dir: *const std.Io.Dir) !ManifestProbe {
    const source = dir.readFileAlloc(io, "nako.toml", allocator, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        // 上限超過・読取り不能は v1 以前の manifest として扱わない。
        error.StreamTooLong => return .{ .invalid = error.InvalidToml },
        else => return err,
    };
    errdefer allocator.free(source);

    const manifest = v1_manifest.parse(allocator, source, .local) catch |err| switch (err) {
        error.LegacyManifest => {
            allocator.free(source);
            return .legacy;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            allocator.free(source);
            return .{ .invalid = err };
        },
    };
    return .{ .v1 = .{ .manifest = manifest, .source = source } };
}

/// `needsEnvironment` へ渡す選択入力。`prepareForExecution` が検証する
/// `--profile` / `--features` / `--no-default-features` と同じ値。
pub const EnvironmentInputs = struct {
    profile: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
};

/// `run`/`build`/`test` が v1 環境（lock と materialize 済み世代）を必要と
/// するか。選択 profile と feature 選択で実際に適用される直接依存だけを
/// `v1_manifest.effectiveRootDependencies` で求め、未選択の runtime 依存や
/// optional 依存では lock を要求しない。`test` も公開対象グラフ
/// （`dependencies` と選択 runtime の `runtime-dependencies`）だけを見る。
/// `dev-dependencies` は公開用 manifest／解決グラフに含めないため、その宣言
/// だけでは環境を要求しない。`verb` は既存呼出しとの互換のため受け取る。
pub fn needsEnvironment(
    allocator: std.mem.Allocator,
    manifest: *const v1_manifest.Manifest,
    verb: []const u8,
    inputs: EnvironmentInputs,
) !bool {
    _ = verb;
    const choice = try v1_manifest.selectProfile(manifest, inputs.profile);
    // 返る依存スライスは一時領域で足りる。manifest 側の宣言は参照のまま。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const roots = try v1_manifest.effectiveRootDependencies(
        manifest,
        arena.allocator(),
        choice.runtime,
        inputs.features,
        inputs.no_default_features,
    );
    return roots.len > 0;
}

/// CLI がそのまま表示できる v1 manifest の診断文。
pub fn manifestDiagnostic(err: anyerror) []const u8 {
    return v1_manifest.diagnostic(err) orelse @errorName(err);
}

test "v1 入口: v1 manifest を local として受理し、旧 manifest と区別する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const v1_source = "schema_version = 1\n[package]\n";
    var manifest = try v1_manifest.parse(a, v1_source, .local);
    defer manifest.deinit();
    try std.testing.expect(!try needsEnvironment(a, &manifest, "run", .{}));
    try std.testing.expect(!try needsEnvironment(a, &manifest, "test", .{}));

    const with_deps = "schema_version = 1\n[package]\n[dependencies]\n\"@acme/json\" = \"^1.0.0\"\n";
    var dep_manifest = try v1_manifest.parse(a, with_deps, .local);
    defer dep_manifest.deinit();
    try std.testing.expect(try needsEnvironment(a, &dep_manifest, "run", .{}));
    try std.testing.expect(try needsEnvironment(a, &dep_manifest, "test", .{}));

    const legacy = "[package]\nname = \"demo\"\nversion = \"1.0.0\"\n";
    try std.testing.expectError(error.LegacyManifest, v1_manifest.parse(a, legacy, .local));
    try std.testing.expect(std.mem.indexOf(u8, legacy_manifest_message, "再作成") != null);
    try std.testing.expect(std.mem.indexOf(u8, sync_fixture_guidance, "--v1-fixture") != null);
}

test "v1 入口: 未選択の runtime 依存と optional 依存では環境を要求しない" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    // 別 runtime 専用の依存だけを持つプロジェクト（M-05 相当）。既定の
    // lnako profile では適用されないため lock を要求しない。
    const other_runtime =
        \\schema_version = 1
        \\[package]
        \\[runtime-dependencies.cnako]
        \\"@acme/cnako-only" = "^1.0.0"
        \\
    ;
    var node_manifest = try v1_manifest.parse(a, other_runtime, .local);
    defer node_manifest.deinit();
    try std.testing.expect(!try needsEnvironment(a, &node_manifest, "run", .{}));
    try std.testing.expect(!try needsEnvironment(a, &node_manifest, "test", .{}));

    // optional 依存は feature で有効化したときだけ適用される。
    const optional =
        \\schema_version = 1
        \\[package]
        \\[features]
        \\default = []
        \\extra = ["dep:json"]
        \\[dependencies]
        \\"@acme/json" = { version = "^1.0.0", optional = true }
        \\
    ;
    var optional_manifest = try v1_manifest.parse(a, optional, .local);
    defer optional_manifest.deinit();
    try std.testing.expect(!try needsEnvironment(a, &optional_manifest, "run", .{}));
    try std.testing.expect(!try needsEnvironment(a, &optional_manifest, "run", .{
        .no_default_features = true,
    }));
    try std.testing.expect(try needsEnvironment(a, &optional_manifest, "run", .{
        .features = &.{"extra"},
    }));

    // profile ごとの runtime 依存も、選択 profile の runtime だけを見る。
    const profiles =
        \\schema_version = 1
        \\[package]
        \\[runtime-dependencies.wnako]
        \\"@acme/web" = "^1.0.0"
        \\[profiles.default]
        \\runtime = "lnako"
        \\[profiles.web]
        \\runtime = "wnako"
        \\
    ;
    var profile_manifest = try v1_manifest.parse(a, profiles, .local);
    defer profile_manifest.deinit();
    try std.testing.expect(!try needsEnvironment(a, &profile_manifest, "run", .{}));
    try std.testing.expect(try needsEnvironment(a, &profile_manifest, "run", .{
        .profile = "web",
    }));
}

test "v1 入口: dev-dependencies の宣言だけでは test も環境を要求しない" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const dev_only =
        \\schema_version = 1
        \\[package]
        \\[dev-dependencies]
        \\"@acme/test-kit" = "^1.0.0"
        \\
    ;
    var manifest = try v1_manifest.parse(a, dev_only, .local);
    defer manifest.deinit();
    try std.testing.expect(!try needsEnvironment(a, &manifest, "run", .{}));
    try std.testing.expect(!try needsEnvironment(a, &manifest, "test", .{}));

    // 公開対象の直接依存があれば test も従来どおり環境を要求する。
    const with_public_dep =
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/runtime" = "^1.0.0"
        \\[dev-dependencies]
        \\"@acme/test-kit" = "^1.0.0"
        \\
    ;
    var public_manifest = try v1_manifest.parse(a, with_public_dep, .local);
    defer public_manifest.deinit();
    try std.testing.expect(try needsEnvironment(a, &public_manifest, "test", .{}));
}
