const std = @import("std");
const toml = @import("toml.zig");
const semver = @import("semver.zig");
const marker_mod = @import("marker.zig");
const features_mod = @import("features.zig");
const diag = @import("diagnostics.zig");
const manifest_validate = @import("manifest_validate.zig");

pub const Position = diag.Position;
/// パッケージ名規則（`[a-z][a-z0-9-]{0,63}`）の検証。manifest 検証と
/// CLI（`init --name`/`add`）で共有する。
pub const isPackageName = manifest_validate.isPackageName;
pub const FeatureDefinition = features_mod.Definition;
pub const FeatureDefinitions = features_mod.Definitions;
pub const FeatureExpanded = features_mod.Expanded;
pub const Marker = marker_mod.Marker;
pub const MarkerContext = marker_mod.Context;

/// 現在受理する `nako.toml` schema version。
pub const known_schema_version: u32 = 1;
/// `.npkg` の `NAKO-PKG/METADATA.toml` schema version。
/// `SCHEMA_VERSIONS.md` §7 と対応する。
pub const npkg_schema_version: u32 = 1;
/// ネイティブ配布で唯一受理する plugin ABI 名。
pub const known_native_plugin_abi = "lnako_plugin_v1";

pub const known_package_runtime = [_][]const u8{ "lnako", "cnako" };

pub const Engines = struct {
    nako: ?semver.Range = null,
    cnako: ?semver.Range = null,
    lnako: ?semver.Range = null,
    position: Position = .{},
};

pub const Package = struct {
    name: []const u8,
    version: semver.Version,
    license: []const u8,
    id: ?[]const u8 = null,
    description: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    keywords: []const []const u8 = &.{},
    repository: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    nako_version: ?semver.Version = null,
    min_nako_version: ?semver.Version = null,
    schema_version: u32 = known_schema_version,
    runtimes: []const []const u8 = &.{},
    engines: Engines = .{},
    include: ?[]const []const u8 = null,
};

pub const PkgDependency = struct {
    /// 依存名（テーブルキー。公開名または alias 参照先）。
    name: []const u8,
    version: semver.Range,
    version_text: []const u8,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    profile: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    public_id: ?[]const u8 = null,
    prefer_native: bool = false,
    position: Position = .{},
};

pub const NpmDependency = struct {
    name: []const u8,
    version: semver.Range,
    version_text: []const u8,
    context: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    /// peer 名 → version range。
    peer_dependencies: std.StringHashMapUnmanaged(semver.Range) = .empty,
    optional_peers: []const []const u8 = &.{},
    position: Position = .{},
};

pub const PathDependency = struct {
    name: []const u8,
    path: []const u8,
    mutable: bool = false,
    position: Position = .{},
};

pub const GitDependency = struct {
    name: []const u8,
    url: []const u8,
    commit: []const u8,
    path: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    position: Position = .{},
};

pub const HttpDependency = struct {
    name: []const u8,
    url: []const u8,
    hash: []const u8,
    alias: ?[]const u8 = null,
    position: Position = .{},
};

pub const DependencyGroup = struct {
    pkg: std.StringHashMapUnmanaged(PkgDependency) = .empty,
    npm: std.StringHashMapUnmanaged(NpmDependency) = .empty,
    path: std.StringHashMapUnmanaged(PathDependency) = .empty,
    git: std.StringHashMapUnmanaged(GitDependency) = .empty,
    http: std.StringHashMapUnmanaged(HttpDependency) = .empty,
};

/// `.npkg` の `NAKO-PKG/METADATA.toml` として解析した場合のみ設定される
/// メタデータ。`nako.toml` 解析時は null のまま。
pub const Npkg = struct {
    schema_version: u32 = npkg_schema_version,
    /// `nativePluginAbi`。native artifact 宣言が存在する場合必須で、
    /// 値は `lnako_plugin_v1` のみ受理する。
    native_plugin_abi: ?[]const u8 = null,
};

pub const Profile = struct {
    name: []const u8,
    runtime: []const u8 = "any",
    os: []const u8,
    cpu: []const u8,
    abi: []const u8,
    compat_js: bool = false,
    optimize: ?[]const u8 = null,
    position: Position = .{},

    /// marker 評価コンテキストへ変換する。
    pub fn markerContext(self: *const Profile, version: ?semver.Version, features: []const []const u8) MarkerContext {
        return .{
            .runtime = self.runtime,
            .os = self.os,
            .cpu = self.cpu,
            .abi = self.abi,
            .compat_js = self.compat_js,
            .optimize = self.optimize orelse "O0",
            .version = version,
            .features = features,
        };
    }
};

pub const ResolvedExportKind = enum {
    source,
    native,
    esm,
};

pub const ExportResolution = struct {
    kind: ResolvedExportKind,
    target: []const u8,
};

/// `native`/`esm` artifact の宣言。文字列省略形は `path` のみを持つ。
/// `when` は marker 式、`min_os` は対象 OS の最小バージョン（`14`/`14.0`/
/// `14.0.1` 形式）、`libc` は要求 libc 系、`features` は要求 feature 一覧。
pub const ArtifactDecl = struct {
    path: []const u8,
    when: ?[]const u8 = null,
    min_os: ?[]const u8 = null,
    libc: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    position: Position = .{},

    /// 条件が対象環境へ適用可能か。`when` の marker 式は `target` の
    /// os/cpu/abi/compat-js/features/version で評価する。`min-os`・`libc` は
    /// 宣言があるのに対象側の値が不明な場合は適合を証明できないため不適合
    /// とみなす（保守方向）。`when` の解析失敗は manifest 検証で報告済みの
    /// 前提であり、ここでは不適合として扱う。
    /// `check_features` を false にすると `features` 要件を未評価とみなす。
    /// `when` 式内の `features` 参照も同時に未確定として三値評価し、
    /// 確定条件（os/cpu 等）だけで偽になる式のみ不適合とする。依存解決の
    /// version 候補判定のように、有効 feature 集合が未確定の段階で
    /// feature 条件を理由に候補を落とさないために使う。
    pub fn matchesTarget(self: *const ArtifactDecl, allocator: std.mem.Allocator, target: ArtifactTarget, check_features: bool) !bool {
        if (self.when) |text| {
            var parsed = try marker_mod.parse(allocator, text);
            const ok = switch (parsed) {
                .ok => |*m| blk: {
                    defer m.deinit();
                    if (check_features) {
                        break :blk m.evaluate(target.markerContext()) catch false;
                    }
                    const result = m.evaluatePartial(target.markerContext(), .initOne(.features)) catch .fail;
                    break :blk result != .fail;
                },
                .err => false,
            };
            if (!ok) return false;
        }
        if (self.min_os) |min| {
            const os_version = target.os_version orelse return false;
            const order = compareDottedVersion(os_version, min) orelse return false;
            if (order < 0) return false;
        }
        if (self.libc) |libc| {
            const target_libc = if (target.libc) |l| l else target.abi;
            if (!std.mem.eql(u8, target_libc, libc)) return false;
        }
        if (check_features) {
            for (self.features) |feature| {
                if (!containsString(target.features, feature)) return false;
            }
        }
        return true;
    }
};

/// artifact 条件の照合対象。runtime 選択のみの経路では os/cpu/abi 系は
/// 空のままでよい（その場合 `min-os`/`libc` 付き宣言は不適合となる）。
pub const ArtifactTarget = struct {
    runtime: []const u8,
    os: []const u8 = "",
    cpu: []const u8 = "",
    abi: []const u8 = "",
    os_version: ?[]const u8 = null,
    libc: ?[]const u8 = null,
    compat_js: bool = false,
    optimize: []const u8 = "O0",
    version: ?semver.Version = null,
    features: []const []const u8 = &.{},

    fn markerContext(self: ArtifactTarget) marker_mod.Context {
        return .{
            .runtime = self.runtime,
            .os = self.os,
            .cpu = self.cpu,
            .abi = self.abi,
            .compat_js = self.compat_js,
            .optimize = self.optimize,
            .version = self.version,
            .features = self.features,
        };
    }
};

/// `.` 区切りの数列を辞書順＋数値比較する。`14` と `14.0` は等しい。
/// 数値でない成分を含む場合は `null`。
pub fn compareDottedVersion(a: []const u8, b: []const u8) ?i8 {
    var a_it = std.mem.splitScalar(u8, a, '.');
    var b_it = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_it.next();
        const b_part = b_it.next();
        if (a_part == null and b_part == null) return 0;
        const a_num = if (a_part) |p| std.fmt.parseInt(u64, p, 10) catch return null else 0;
        const b_num = if (b_part) |p| std.fmt.parseInt(u64, p, 10) catch return null else 0;
        if (a_num < b_num) return -1;
        if (a_num > b_num) return 1;
    }
}

/// 宣言リストから対象に適合する最初の artifact を返す。
fn firstMatchingArtifact(decls: []const ArtifactDecl, allocator: std.mem.Allocator, target: ArtifactTarget) !?ArtifactDecl {
    for (decls) |decl| {
        if (try decl.matchesTarget(allocator, target, true)) return decl;
    }
    return null;
}

pub const Export = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    native: []const ArtifactDecl = &.{},
    esm: []const ArtifactDecl = &.{},
    position: Position = .{},

    /// 処理系条件・ネイティブ明示選択フラグ・compat-js条件に基づいてexport実装を選択する。
    /// 共通.nako3ソース（path）が存在する場合は既定で優先選択され、
    /// prefer_native=true が指定された場合のみ高速化用nativeが選択される。
    /// `target` の os/cpu/abi 等が空の場合、`when`/`min-os`/`libc` 付きの
    /// artifact 宣言は適合を証明できないため選択されない。
    pub fn resolve(
        self: *const Export,
        allocator: std.mem.Allocator,
        target: ArtifactTarget,
        prefer_native: bool,
        diagnostics: ?*diag.List,
    ) !?ExportResolution {
        // 対象処理系は公開契約上 lnako / cnako のみ。共通ソース（path）の
        // 有無にかかわらず未知の処理系は E031 で拒否する。
        if (!containsString(&known_package_runtime, target.runtime)) {
            if (diagnostics) |d| {
                try d.addFmt(
                    diag.E031_UNSUPPORTED_RUNTIME,
                    .err,
                    self.name,
                    self.position,
                    "unsupported runtime \"{s}\" for export \"{s}\"",
                    .{ target.runtime, self.name },
                );
            }
            return null;
        }
        const native_decl = try firstMatchingArtifact(self.native, allocator, target);
        const esm_decl = try firstMatchingArtifact(self.esm, allocator, target);
        if (self.path) |p| {
            // 共通ソースは常に利用可能。prefer-native が lnako で明示された
            // 場合のみ native を高速化実装として優先する。
            if (prefer_native and std.mem.eql(u8, target.runtime, "lnako") and native_decl != null) {
                return .{ .kind = .native, .target = native_decl.?.path };
            }
            return .{ .kind = .source, .target = p };
        }
        if (std.mem.eql(u8, target.runtime, "lnako")) {
            if (native_decl) |decl| {
                return .{ .kind = .native, .target = decl.path };
            }
            if (esm_decl) |decl| {
                if (target.compat_js) {
                    return .{ .kind = .esm, .target = decl.path };
                } else {
                    if (diagnostics) |d| {
                        try d.addFmt(
                            diag.E006_JS_IN_NORMAL_MODE,
                            .err,
                            self.name,
                            self.position,
                            "ESM export \"{s}\" requires --compat-js on lnako",
                            .{self.name},
                        );
                    }
                    return null;
                }
            }
            if (self.native.len != 0) {
                // native artifact は宣言されたが対象条件に適合しない。
                if (diagnostics) |d| {
                    try d.addFmt(
                        diag.E015_NATIVE_FOR_INCOMPATIBLE_TARGET,
                        .err,
                        self.name,
                        self.position,
                        "no native artifact of export \"{s}\" matches the target environment",
                        .{self.name},
                    );
                }
                return null;
            }
        } else {
            // cnako は ESM を直接扱えるため、native 併記時も ESM を先に選ぶ。
            if (esm_decl) |decl| {
                return .{ .kind = .esm, .target = decl.path };
            }
            if (self.native.len != 0) {
                if (diagnostics) |d| {
                    try d.addFmt(
                        diag.E031_UNSUPPORTED_RUNTIME,
                        .err,
                        self.name,
                        self.position,
                        "native-only export \"{s}\" is not supported on runtime \"{s}\"",
                        .{ self.name, target.runtime },
                    );
                }
                return null;
            }
        }

        if (diagnostics) |d| {
            try d.addFmt(
                diag.E019_REQUIRED_FIELD_MISSING,
                .err,
                self.name,
                self.position,
                "no target implementation (\"path\", \"native\", or \"esm\") found for export \"{s}\"",
                .{self.name},
            );
        }
        return null;
    }
};

/// 型付き manifest。`document` のアリーナが全文字列・コンテナ
/// （`Range` の内部バッファ、feature 定義、依存 map 等）を所有する。
/// 個別フィールドを `deinit`/`free` してはならず、解放は `Manifest.deinit` のみ。
/// `deinit` まですべてのフィールドは有効。
pub const Manifest = struct {
    document: toml.Document,
    package: Package,
    features: FeatureDefinitions,
    dependencies: DependencyGroup,
    dev_dependencies: DependencyGroup,
    profiles: std.StringHashMapUnmanaged(Profile),
    exports: []Export,
    /// `parseNpkgMetadata` で解析した場合のみ設定される `.npkg` メタデータ。
    npkg: ?Npkg = null,

    pub fn deinit(self: *Manifest) void {
        self.document.deinit();
        self.* = undefined;
    }

    /// manifest 内の値を追加割当てするためのアリーナアロケータ。
    pub fn arenaAllocator(self: *Manifest) std.mem.Allocator {
        return self.document.arena.allocator();
    }

    /// 依存 alias 集合（dependencies と dev-dependencies の全グループのエントリ名
    /// と明示的 `alias`）を `allocator` で構築する。呼出し側が `deinit` する。
    pub fn dependencyAliases(self: *const Manifest, allocator: std.mem.Allocator) !std.StringHashMap(void) {
        var aliases = std.StringHashMap(void).init(allocator);
        errdefer aliases.deinit();
        for ([_]*const DependencyGroup{ &self.dependencies, &self.dev_dependencies }) |group| {
            var pkg_keys = group.pkg.keyIterator();
            while (pkg_keys.next()) |key| try aliases.put(key.*, {});
            var npm_keys = group.npm.keyIterator();
            while (npm_keys.next()) |key| try aliases.put(key.*, {});
            var path_keys = group.path.keyIterator();
            while (path_keys.next()) |key| try aliases.put(key.*, {});
            var git_keys = group.git.keyIterator();
            while (git_keys.next()) |key| try aliases.put(key.*, {});
            var http_keys = group.http.keyIterator();
            while (http_keys.next()) |key| try aliases.put(key.*, {});
            var pkg_values = group.pkg.valueIterator();
            while (pkg_values.next()) |dep| {
                if (dep.alias) |alias| try aliases.put(alias, {});
            }
            var git_values = group.git.valueIterator();
            while (git_values.next()) |dep| {
                if (dep.alias) |alias| try aliases.put(alias, {});
            }
            var http_values = group.http.valueIterator();
            while (http_values.next()) |dep| {
                if (dep.alias) |alias| try aliases.put(alias, {});
            }
        }
        return aliases;
    }

    /// 要求された feature 集合を展開する。`use_default` が真なら `default`
    /// feature も要求集合に含める。エラーは `diagnostics` に位置付きで記録する。
    /// 返り値は `allocator` 所有で `deinit` が必要。キー/値は manifest の
    /// アリーナを参照するため `Expanded` は `Manifest` より先に `deinit` する。
    pub fn expandFeatures(
        self: *const Manifest,
        allocator: std.mem.Allocator,
        requested: []const []const u8,
        use_default: bool,
        diagnostics: *diag.List,
    ) !FeatureExpanded {
        var aliases = try self.dependencyAliases(allocator);
        defer aliases.deinit();
        var offender: ?[]const u8 = null;
        return features_mod.expand(allocator, &self.features, requested, use_default, &aliases, &offender) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FeatureCycle => {
                const name = offender orelse "?";
                const position = if (self.features.get(name)) |definition| definition.position else Position{};
                try diagnostics.addFmt(diag.E027_FEATURE_CYCLE, .err, "features", position, "feature cycle involving \"{s}\"", .{name});
                return error.InvalidManifest;
            },
            error.UnknownFeature => {
                const name = offender orelse "?";
                const position = if (self.features.get(name)) |definition| definition.position else Position{};
                try diagnostics.addFmt(diag.E028_UNKNOWN_FEATURE, .err, "features", position, "unknown feature \"{s}\"", .{name});
                return error.InvalidManifest;
            },
        };
    }

    /// 対象処理系（"lnako" または "cnako"）がパッケージの対応処理系（runtimes）と適合するか検証する。
    /// 未宣言（空配列）の場合は両処理系に適合するものとみなす。未知の処理系名は
    /// runtimes の宣言有無にかかわらず E031 とする。
    pub fn checkRuntime(self: *const Manifest, target_runtime: []const u8, diagnostics: *diag.List, position: Position) !bool {
        if (!containsString(&known_package_runtime, target_runtime)) {
            try diagnostics.addFmt(
                diag.E031_UNSUPPORTED_RUNTIME,
                .err,
                "package.runtimes",
                position,
                "unsupported runtime \"{s}\"",
                .{target_runtime},
            );
            return false;
        }
        if (self.package.runtimes.len == 0) return true;
        for (self.package.runtimes) |r| {
            if (std.mem.eql(u8, r, target_runtime)) return true;
        }
        try diagnostics.addFmt(
            diag.E031_UNSUPPORTED_RUNTIME,
            .err,
            "package.runtimes",
            position,
            "package \"{s}\" does not support runtime \"{s}\"",
            .{ self.package.name, target_runtime },
        );
        return false;
    }

    /// エンジン要件（[package.engines]）が現在の言語・処理系バージョンと適合するか検証する。
    /// 判定対象バージョンが null（不明）のキーは未検査として扱い、`E032_ENGINE_MISMATCH` を
    /// 報告しない。制約を強制するには呼び出し側が各バージョンを提供する必要がある。
    pub fn checkEngines(
        self: *const Manifest,
        nako_ver: ?semver.Version,
        cnako_ver: ?semver.Version,
        lnako_ver: ?semver.Version,
        diagnostics: *diag.List,
        position: Position,
    ) !bool {
        var ok = true;
        if (self.package.engines.nako) |range| {
            if (nako_ver) |ver| {
                if (!range.satisfies(ver)) {
                    try diagnostics.addFmt(
                        diag.E032_ENGINE_MISMATCH,
                        .err,
                        "package.engines.nako",
                        position,
                        "nako version {d}.{d}.{d} does not satisfy required range \"{s}\"",
                        .{ ver.major, ver.minor, ver.patch, range.text },
                    );
                    ok = false;
                }
            }
        }
        if (self.package.engines.cnako) |range| {
            if (cnako_ver) |ver| {
                if (!range.satisfies(ver)) {
                    try diagnostics.addFmt(
                        diag.E032_ENGINE_MISMATCH,
                        .err,
                        "package.engines.cnako",
                        position,
                        "cnako version {d}.{d}.{d} does not satisfy required range \"{s}\"",
                        .{ ver.major, ver.minor, ver.patch, range.text },
                    );
                    ok = false;
                }
            }
        }
        if (self.package.engines.lnako) |range| {
            if (lnako_ver) |ver| {
                if (!range.satisfies(ver)) {
                    try diagnostics.addFmt(
                        diag.E032_ENGINE_MISMATCH,
                        .err,
                        "package.engines.lnako",
                        position,
                        "lnako version {d}.{d}.{d} does not satisfy required range \"{s}\"",
                        .{ ver.major, ver.minor, ver.patch, range.text },
                    );
                    ok = false;
                }
            }
        }
        return ok;
    }
};

pub const Error = error{ InvalidManifest, OutOfMemory };

/// 検証モード。`.npkg_metadata` は `NAKO-PKG/METADATA.toml` の文法で、
/// `schemaVersion`/`nativePluginAbi` を受理し、`dev-dependencies`・
/// `profiles` はトップレベルフィールド集合に含まない。
pub const Mode = enum { manifest, npkg_metadata };

/// `nako.toml` テキストを解析し、型付き `Manifest` を返す。
/// 構文・意味上の問題は `diagnostics` に位置付きで記録し、
/// この呼出しで新たに error が追加された場合のみ
/// `error.InvalidManifest` を返す。`diagnostics` は複数入力の
/// 結果を集約してよく、既存の error は今回の成否に影響しない。
/// 返された `Manifest` は `deinit` で全メモリを解放する。
pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostics: *diag.List) Error!Manifest {
    return parseMode(allocator, source, diagnostics, .manifest, "nako.toml");
}

/// `NAKO-PKG/METADATA.toml` テキストを解析し、型付き `Manifest` を返す。
/// `manifest.npkg` に `.npkg` メタデータが設定される。
/// 失敗時は `error.InvalidManifest`（diagnostics に位置付きで記録）。
pub fn parseNpkgMetadata(allocator: std.mem.Allocator, source: []const u8, diagnostics: *diag.List) Error!Manifest {
    return parseMode(allocator, source, diagnostics, .npkg_metadata, "METADATA.toml");
}

fn parseMode(allocator: std.mem.Allocator, source: []const u8, diagnostics: *diag.List, mode: Mode, display_name: []const u8) Error!Manifest {
    var manifest = switch (try toml.parse(allocator, source)) {
        .ok => |document| Manifest{
            .document = document,
            .package = undefined,
            .features = undefined,
            .dependencies = undefined,
            .dev_dependencies = undefined,
            .profiles = undefined,
            .exports = &.{},
        },
        .err => |syntax| {
            const code = if (std.mem.indexOf(u8, syntax.message, "UTF-8") != null) diag.E021_INVALID_UTF8 else diag.E020_INVALID_TOML;
            try diagnostics.add(code, .err, syntax.message, display_name, syntax.position);
            return error.InvalidManifest;
        },
    };
    errdefer manifest.document.deinit();
    manifest.features = .empty;
    manifest.dependencies = .{};
    manifest.dev_dependencies = .{};
    manifest.profiles = .empty;

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    // 呼出し前から残っている error は今回の成否に数えない
    // （診断リストが複数入力の結果を集約する場合があるため）。
    const prior_errors = diagnostics.errorCount();
    try manifest_validate.run(&manifest, scratch_arena.allocator(), diagnostics, mode);

    if (diagnostics.errorCount() > prior_errors) return error.InvalidManifest;
    return manifest;
}

pub fn containsString(list: []const []const u8, text: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

test {
    _ = @import("manifest_test.zig");
}
