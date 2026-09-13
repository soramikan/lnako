const std = @import("std");
const toml = @import("toml.zig");
const semver = @import("semver.zig");
const marker_mod = @import("marker.zig");
const features_mod = @import("features.zig");
const diag = @import("diagnostics.zig");

pub const Position = diag.Position;
pub const FeatureDefinition = features_mod.Definition;
pub const FeatureDefinitions = features_mod.Definitions;
pub const FeatureExpanded = features_mod.Expanded;
pub const Marker = marker_mod.Marker;
pub const MarkerContext = marker_mod.Context;

/// 現在受理する `nako.toml` schema version。
pub const known_schema_version: u32 = 1;

const known_profile_os = [_][]const u8{ "macos", "linux", "windows" };
const known_profile_cpu = [_][]const u8{ "aarch64", "x86_64", "arm", "wasm32" };
const known_profile_abi = [_][]const u8{ "gnu", "msvc", "musl", "none" };
const known_optimize = [_][]const u8{ "O0", "O1", "O2", "O3" };

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

pub const Profile = struct {
    name: []const u8,
    os: []const u8,
    cpu: []const u8,
    abi: []const u8,
    compat_js: bool = false,
    optimize: ?[]const u8 = null,
    position: Position = .{},

    /// marker 評価コンテキストへ変換する。
    pub fn markerContext(self: *const Profile, version: ?semver.Version, features: []const []const u8) MarkerContext {
        return .{
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

pub const Export = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    native: ?[]const u8 = null,
    esm: ?[]const u8 = null,
    position: Position = .{},
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
};

pub const Error = error{ InvalidManifest, OutOfMemory };

/// `nako.toml` テキストを解析し、型付き `Manifest` を返す。
/// 構文・意味上の問題は `diagnostics` に位置付きで記録し、
/// エラーがあれば `error.InvalidManifest` を返す。
/// 返された `Manifest` は `deinit` で全メモリを解放する。
pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostics: *diag.List) Error!Manifest {
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
            try diagnostics.add(code, .err, syntax.message, "nako.toml", syntax.position);
            return error.InvalidManifest;
        },
    };
    errdefer manifest.document.deinit();
    const arena = manifest.document.arena.allocator();
    manifest.features = .empty;
    manifest.dependencies = .{};
    manifest.dev_dependencies = .{};
    manifest.profiles = .empty;

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var validator = Validator{
        .arena = arena,
        .scratch = scratch_arena.allocator(),
        .diagnostics = diagnostics,
        .manifest = &manifest,
    };
    try validator.validateRoot();

    if (diagnostics.hasErrors()) return error.InvalidManifest;
    return manifest;
}

const Validator = struct {
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    diagnostics: *diag.List,
    manifest: *Manifest,

    fn report(self: *Validator, code: []const u8, path: []const u8, position: Position, comptime format: []const u8, args: anytype) Error!void {
        try self.diagnostics.addFmt(code, .err, path, position, format, args);
    }

    /// `a.b.c` 形式のフィールドパスを scratch に構築する。
    fn pathOf(self: *Validator, parent: []const u8, key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.scratch, "{s}.{s}", .{ parent, key });
    }

    fn validateRoot(self: *Validator) Error!void {
        const root = &self.manifest.document.root;
        const known = [_][]const u8{ "package", "features", "dependencies", "dev-dependencies", "profiles", "exports" };
        var iterator = root.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            var found = false;
            for (known) |name| {
                if (std.mem.eql(u8, key, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.report(diag.E022_UNKNOWN_FIELD, key, entry.value_ptr.position, "unknown top-level field \"{s}\"", .{key});
            }
        }

        const package_value = root.getPtr("package") orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, "package", .{}, "missing required field \"package\"", .{});
            return;
        };
        const package_table = (try self.expectTable(package_value, "package")) orelse return;
        try self.validatePackage(package_table, package_value.position);
        try self.validateFeatures(root);
        try self.validateDependencySection(root, "dependencies", &self.manifest.dependencies);
        try self.validateDependencySection(root, "dev-dependencies", &self.manifest.dev_dependencies);
        try self.validateProfiles(root);
        try self.validateExports(root);
        try self.checkConflictingVersions();
        try self.checkAliasCollisions();
        try self.checkProfileReferences();
        try self.checkFeatureReferences();
        try self.checkFeatureCycles();
    }

    fn expectTable(self: *Validator, value: *toml.Value, path: []const u8) Error!?*std.StringHashMapUnmanaged(toml.Value) {
        return switch (value.kind) {
            .table => |*table| table,
            else => {
                try self.report(diag.E023_INVALID_TYPE, path, value.position, "expected table for \"{s}\"", .{path});
                return null;
            },
        };
    }

    fn expectString(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8) Error!?[]const u8 {
        const value = table.getPtr(key) orelse return null;
        return switch (value.kind) {
            .string => |text| text,
            else => {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string for \"{s}\"", .{field_path});
                return null;
            },
        };
    }

    fn requireString(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8, parent_position: Position) Error!?[]const u8 {
        const value = table.getPtr(key) orelse {
            const field_path = try self.pathOf(path, key);
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, field_path, parent_position, "missing required field \"{s}\"", .{field_path});
            return null;
        };
        return switch (value.kind) {
            .string => |text| text,
            else => {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string for \"{s}\"", .{field_path});
                return null;
            },
        };
    }

    fn expectBool(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8) Error!?bool {
        const value = table.getPtr(key) orelse return null;
        return switch (value.kind) {
            .boolean => |boolean| boolean,
            else => {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected boolean for \"{s}\"", .{field_path});
                return null;
            },
        };
    }

    fn expectStringList(self: *Validator, value: *toml.Value, path: []const u8) Error![]const []const u8 {
        const array = switch (value.kind) {
            .array => |*array| array,
            else => {
                try self.report(diag.E023_INVALID_TYPE, path, value.position, "expected array for \"{s}\"", .{path});
                return &.{};
            },
        };
        var items = try std.ArrayList([]const u8).initCapacity(self.arena, array.items.len);
        for (array.items) |*item| {
            const text = switch (item.kind) {
                .string => |text| text,
                else => {
                    try self.report(diag.E023_INVALID_TYPE, path, item.position, "expected string item in \"{s}\"", .{path});
                    continue;
                },
            };
            items.appendAssumeCapacity(text);
        }
        return try items.toOwnedSlice(self.arena);
    }

    fn rejectUnknownFields(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, known: []const []const u8) Error!void {
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            var found = false;
            for (known) |name| {
                if (std.mem.eql(u8, key, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E022_UNKNOWN_FIELD, field_path, entry.value_ptr.position, "unknown field \"{s}\"", .{field_path});
            }
        }
    }

    /// `featureList` 型のフィールド。各項目は `featureName` パターンに一致しなければならない。
    fn expectFeatureList(self: *Validator, value: *toml.Value, path: []const u8) Error![]const []const u8 {
        const items = try self.expectStringList(value, path);
        for (items) |item| {
            if (!isFeatureName(item)) {
                try self.report(diag.E029_INVALID_VALUE, path, value.position, "invalid feature name \"{s}\" in \"{s}\"", .{ item, path });
            }
        }
        return items;
    }

    /// `^\d+\.\d+\.\d+$` 形式のバージョンフィールド（schema 上 semver ではなく
    /// パターン制約のため、不一致は E029 として診断する）。
    fn parsePlainVersionField(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8) Error!?semver.Version {
        const value = table.getPtr(key) orelse return null;
        const field_path = try self.pathOf(path, key);
        const text = switch (value.kind) {
            .string => |text| text,
            else => {
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string for \"{s}\"", .{field_path});
                return null;
            },
        };
        return parsePlainVersion(text) orelse {
            try self.report(diag.E029_INVALID_VALUE, field_path, value.position, "invalid version \"{s}\" for \"{s}\", expected x.y.z", .{ text, field_path });
            return null;
        };
    }

    fn validatePackage(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), position: Position) Error!void {
        const path = "package";
        const known = [_][]const u8{ "name", "version", "license", "id", "description", "authors", "keywords", "repository", "homepage", "nako-version", "min-nako-version", "schema-version" };
        try self.rejectUnknownFields(table, path, &known);

        var package = Package{
            .name = "",
            .version = .{ .major = 0, .minor = 0, .patch = 0 },
            .license = "",
        };

        if (try self.requireString(table, "name", path, position)) |name| {
            if (!isPackageName(name)) {
                try self.report(diag.E029_INVALID_VALUE, "package.name", valuePositionOfKey(table, "name"), "invalid package name \"{s}\"", .{name});
            }
            package.name = name;
        }
        if (try self.requireString(table, "version", path, position)) |version_text| {
            package.version = semver.Version.parse(version_text) catch blk: {
                try self.report(diag.E024_INVALID_SEMVER, "package.version", valuePositionOfKey(table, "version"), "invalid semver \"{s}\"", .{version_text});
                break :blk .{ .major = 0, .minor = 0, .patch = 0 };
            };
        }
        if (try self.requireString(table, "license", path, position)) |license| {
            package.license = license;
        }
        if (try self.expectString(table, "id", path)) |id| {
            if (!isPublicId(id)) {
                try self.report(diag.E029_INVALID_VALUE, "package.id", valuePositionOfKey(table, "id"), "invalid public id \"{s}\"", .{id});
            }
            package.id = id;
        }
        package.description = try self.expectString(table, "description", path);
        package.repository = try self.expectString(table, "repository", path);
        package.homepage = try self.expectString(table, "homepage", path);
        // schema は `^\d+\.\d+\.\d+$` を要求する（prerelease 不可・先頭ゼロ許容）。
        if (try self.parsePlainVersionField(table, "nako-version", path)) |version| package.nako_version = version;
        if (try self.parsePlainVersionField(table, "min-nako-version", path)) |version| package.min_nako_version = version;
        if (table.getPtr("authors")) |value| {
            package.authors = try self.expectStringList(value, "package.authors");
        }
        if (table.getPtr("keywords")) |value| {
            package.keywords = try self.expectStringList(value, "package.keywords");
        }
        if (table.getPtr("schema-version")) |value| {
            switch (value.kind) {
                .integer => |integer| {
                    if (integer < 1) {
                        try self.report(diag.E029_INVALID_VALUE, "package.schema-version", value.position, "invalid schema-version {d}", .{integer});
                    } else if (integer > known_schema_version) {
                        // u32 範囲を超える巨大な値も含めて未知 schema version として診断する。
                        try self.report(diag.E001_UNKNOWN_MANIFEST_SCHEMA, "package.schema-version", value.position, "unknown manifest schema version {d}", .{integer});
                    } else {
                        package.schema_version = @intCast(integer);
                    }
                },
                else => try self.report(diag.E023_INVALID_TYPE, "package.schema-version", value.position, "expected integer for \"package.schema-version\"", .{}),
            }
        }
        self.manifest.package = package;
    }

    fn validateFeatures(self: *Validator, root: *std.StringHashMapUnmanaged(toml.Value)) Error!void {
        const value = root.getPtr("features") orelse return;
        const table = (try self.expectTable(value, "features")) orelse return;
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf("features", name);
            if (!isFeatureName(name)) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "invalid feature name \"{s}\"", .{name});
            }
            const items = try self.expectFeatureList(entry.value_ptr, field_path);
            try self.manifest.features.put(self.arena, name, .{ .name = name, .items = items, .position = entry.value_ptr.position });
        }
    }

    fn validateDependencySection(self: *Validator, root: *std.StringHashMapUnmanaged(toml.Value), section: []const u8, group: *DependencyGroup) Error!void {
        const value = root.getPtr(section) orelse return;
        const table = (try self.expectTable(value, section)) orelse return;
        const known_groups = [_][]const u8{ "pkg", "npm", "path", "git", "http" };
        try self.rejectUnknownFields(table, section, &known_groups);
        if (table.getPtr("pkg")) |pkg_value| {
            const pkg_path = try self.pathOf(section, "pkg");
            if (try self.expectTable(pkg_value, pkg_path)) |pkg_table| {
                try self.validatePkgDeps(pkg_table, pkg_path, &group.pkg);
            }
        }
        if (table.getPtr("npm")) |npm_value| {
            const npm_path = try self.pathOf(section, "npm");
            if (try self.expectTable(npm_value, npm_path)) |npm_table| {
                try self.validateNpmDeps(npm_table, npm_path, &group.npm);
            }
        }
        if (table.getPtr("path")) |path_value| {
            const path_path = try self.pathOf(section, "path");
            if (try self.expectTable(path_value, path_path)) |path_table| {
                try self.validatePathDeps(path_table, path_path, &group.path);
            }
        }
        if (table.getPtr("git")) |git_value| {
            const git_path = try self.pathOf(section, "git");
            if (try self.expectTable(git_value, git_path)) |git_table| {
                try self.validateGitDeps(git_table, git_path, &group.git);
            }
        }
        if (table.getPtr("http")) |http_value| {
            const http_path = try self.pathOf(section, "http");
            if (try self.expectTable(http_value, http_path)) |http_table| {
                try self.validateHttpDeps(http_table, http_path, &group.http);
            }
        }
    }

    fn parseRangeField(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8, required: bool, parent_position: Position) Error!?semver.Range {
        const value = table.getPtr(key) orelse {
            if (required) {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E019_REQUIRED_FIELD_MISSING, field_path, parent_position, "missing required field \"{s}\"", .{field_path});
            }
            return null;
        };
        const text = switch (value.kind) {
            .string => |text| text,
            else => {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string for \"{s}\"", .{field_path});
                return null;
            },
        };
        return semver.Range.parse(self.arena, text) catch {
            const field_path = try self.pathOf(path, key);
            try self.report(diag.E025_INVALID_RANGE, field_path, value.position, "invalid version range \"{s}\" for \"{s}\"", .{ text, field_path });
            return null;
        };
    }

    fn validatePkgDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(PkgDependency)) Error!void {
        const known = [_][]const u8{ "version", "features", "default-features", "profile", "alias", "public-id" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf(path, name);
            if (name.len == 0) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "empty dependency name", .{});
            }
            const dep_table = (try self.expectTable(entry.value_ptr, field_path)) orelse continue;
            try self.rejectUnknownFields(dep_table, field_path, &known);
            var dep = PkgDependency{
                .name = name,
                .version = .{ .sets = &.{}, .text = "" },
                .version_text = "",
                .position = entry.value_ptr.position,
            };
            if (try self.parseRangeField(dep_table, "version", field_path, true, entry.value_ptr.position)) |range| {
                dep.version = range;
                dep.version_text = dep_table.getPtr("version").?.kind.string;
            }
            if (dep_table.getPtr("features")) |features_value| {
                dep.features = try self.expectFeatureList(features_value, try self.pathOf(field_path, "features"));
            }
            if (try self.expectBool(dep_table, "default-features", field_path)) |default_features| {
                dep.default_features = default_features;
            }
            dep.profile = try self.expectString(dep_table, "profile", field_path);
            dep.alias = try self.expectString(dep_table, "alias", field_path);
            if (try self.expectString(dep_table, "public-id", field_path)) |public_id| {
                if (!isPublicId(public_id)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "public-id"), valuePositionOfKey(dep_table, "public-id"), "invalid public id \"{s}\"", .{public_id});
                }
                dep.public_id = public_id;
            }
            try map.put(self.arena, name, dep);
        }
    }

    fn validateNpmDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(NpmDependency)) Error!void {
        const known = [_][]const u8{ "version", "context", "features", "peer-dependencies", "optional-peers" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf(path, name);
            if (name.len == 0) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "empty dependency name", .{});
            }
            var dep = NpmDependency{
                .name = name,
                .version = .{ .sets = &.{}, .text = "" },
                .version_text = "",
                .position = entry.value_ptr.position,
            };
            switch (entry.value_ptr.kind) {
                .string => |text| {
                    dep.version_text = text;
                    dep.version = semver.Range.parse(self.arena, text) catch blk: {
                        try self.report(diag.E025_INVALID_RANGE, field_path, entry.value_ptr.position, "invalid version range \"{s}\" for \"{s}\"", .{ text, field_path });
                        break :blk .{ .sets = &.{}, .text = text };
                    };
                },
                .table => |*dep_table| {
                    try self.rejectUnknownFields(dep_table, field_path, &known);
                    if (try self.parseRangeField(dep_table, "version", field_path, true, entry.value_ptr.position)) |range| {
                        dep.version = range;
                        dep.version_text = dep_table.getPtr("version").?.kind.string;
                    }
                    dep.context = try self.expectString(dep_table, "context", field_path);
                    if (dep_table.getPtr("features")) |features_value| {
                        dep.features = try self.expectFeatureList(features_value, try self.pathOf(field_path, "features"));
                    }
                    if (dep_table.getPtr("peer-dependencies")) |peers_value| {
                        const peers_path = try self.pathOf(field_path, "peer-dependencies");
                        if (try self.expectTable(peers_value, peers_path)) |peers| {
                            var peer_iterator = peers.iterator();
                            while (peer_iterator.next()) |peer| {
                                const peer_path = try self.pathOf(peers_path, peer.key_ptr.*);
                                const peer_text = switch (peer.value_ptr.kind) {
                                    .string => |text| text,
                                    else => {
                                        try self.report(diag.E023_INVALID_TYPE, peer_path, peer.value_ptr.position, "expected string for \"{s}\"", .{peer_path});
                                        continue;
                                    },
                                };
                                const peer_range = semver.Range.parse(self.arena, peer_text) catch {
                                    try self.report(diag.E025_INVALID_RANGE, peer_path, peer.value_ptr.position, "invalid version range \"{s}\" for \"{s}\"", .{ peer_text, peer_path });
                                    continue;
                                };
                                try dep.peer_dependencies.put(self.arena, peer.key_ptr.*, peer_range);
                            }
                        }
                    }
                    if (dep_table.getPtr("optional-peers")) |optional_value| {
                        dep.optional_peers = try self.expectStringList(optional_value, try self.pathOf(field_path, "optional-peers"));
                    }
                },
                else => {
                    try self.report(diag.E023_INVALID_TYPE, field_path, entry.value_ptr.position, "expected string or table for \"{s}\"", .{field_path});
                },
            }
            try map.put(self.arena, name, dep);
        }
    }

    fn validatePathDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(PathDependency)) Error!void {
        const known = [_][]const u8{ "path", "mutable" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf(path, name);
            if (name.len == 0) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "empty dependency name", .{});
            }
            const dep_table = (try self.expectTable(entry.value_ptr, field_path)) orelse continue;
            try self.rejectUnknownFields(dep_table, field_path, &known);
            var dep = PathDependency{
                .name = name,
                .path = "",
                .position = entry.value_ptr.position,
            };
            if (try self.requireString(dep_table, "path", field_path, entry.value_ptr.position)) |dep_path| {
                dep.path = dep_path;
            }
            if (try self.expectBool(dep_table, "mutable", field_path)) |mutable| {
                dep.mutable = mutable;
            }
            try map.put(self.arena, name, dep);
        }
    }

    fn validateGitDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(GitDependency)) Error!void {
        const known = [_][]const u8{ "url", "commit", "path", "alias" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf(path, name);
            if (name.len == 0) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "empty dependency name", .{});
            }
            const dep_table = (try self.expectTable(entry.value_ptr, field_path)) orelse continue;
            try self.rejectUnknownFields(dep_table, field_path, &known);
            var dep = GitDependency{
                .name = name,
                .url = "",
                .commit = "",
                .position = entry.value_ptr.position,
            };
            if (try self.requireString(dep_table, "url", field_path, entry.value_ptr.position)) |url| {
                dep.url = url;
            }
            if (try self.requireString(dep_table, "commit", field_path, entry.value_ptr.position)) |commit| {
                if (!isCommitId(commit)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "commit"), valuePositionOfKey(dep_table, "commit"), "invalid commit \"{s}\"", .{commit});
                }
                dep.commit = commit;
            }
            dep.path = try self.expectString(dep_table, "path", field_path);
            dep.alias = try self.expectString(dep_table, "alias", field_path);
            try map.put(self.arena, name, dep);
        }
    }

    fn validateHttpDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(HttpDependency)) Error!void {
        const known = [_][]const u8{ "url", "hash", "alias" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf(path, name);
            if (name.len == 0) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "empty dependency name", .{});
            }
            const dep_table = (try self.expectTable(entry.value_ptr, field_path)) orelse continue;
            try self.rejectUnknownFields(dep_table, field_path, &known);
            var dep = HttpDependency{
                .name = name,
                .url = "",
                .hash = "",
                .position = entry.value_ptr.position,
            };
            if (try self.requireString(dep_table, "url", field_path, entry.value_ptr.position)) |url| {
                dep.url = url;
            }
            if (try self.requireString(dep_table, "hash", field_path, entry.value_ptr.position)) |hash| {
                if (!isHash(hash)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "hash"), valuePositionOfKey(dep_table, "hash"), "invalid hash \"{s}\"", .{hash});
                }
                dep.hash = hash;
            }
            dep.alias = try self.expectString(dep_table, "alias", field_path);
            try map.put(self.arena, name, dep);
        }
    }

    fn validateProfiles(self: *Validator, root: *std.StringHashMapUnmanaged(toml.Value)) Error!void {
        const value = root.getPtr("profiles") orelse return;
        const table = (try self.expectTable(value, "profiles")) orelse return;
        const known = [_][]const u8{ "os", "cpu", "abi", "compat-js", "optimize" };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const field_path = try self.pathOf("profiles", name);
            if (!isFeatureName(name)) {
                try self.report(diag.E029_INVALID_VALUE, field_path, entry.value_ptr.position, "invalid profile name \"{s}\"", .{name});
            }
            const profile_table = (try self.expectTable(entry.value_ptr, field_path)) orelse continue;
            try self.rejectUnknownFields(profile_table, field_path, &known);
            var profile = Profile{
                .name = name,
                .os = "",
                .cpu = "",
                .abi = "",
                .position = entry.value_ptr.position,
            };
            const os = try self.requireString(profile_table, "os", field_path, entry.value_ptr.position);
            const cpu = try self.requireString(profile_table, "cpu", field_path, entry.value_ptr.position);
            const abi = try self.requireString(profile_table, "abi", field_path, entry.value_ptr.position);
            if (os) |text| {
                profile.os = text;
                if (!containsString(&known_profile_os, text)) {
                    try self.report(diag.E014_INVALID_PROFILE, try self.pathOf(field_path, "os"), valuePositionOfKey(profile_table, "os"), "profile \"{s}\" has invalid os \"{s}\"", .{ name, text });
                }
            }
            if (cpu) |text| {
                profile.cpu = text;
                if (!containsString(&known_profile_cpu, text)) {
                    try self.report(diag.E014_INVALID_PROFILE, try self.pathOf(field_path, "cpu"), valuePositionOfKey(profile_table, "cpu"), "profile \"{s}\" has invalid cpu \"{s}\"", .{ name, text });
                }
            }
            if (abi) |text| {
                profile.abi = text;
                if (!containsString(&known_profile_abi, text)) {
                    try self.report(diag.E014_INVALID_PROFILE, try self.pathOf(field_path, "abi"), valuePositionOfKey(profile_table, "abi"), "profile \"{s}\" has invalid abi \"{s}\"", .{ name, text });
                }
            }
            if (try self.expectBool(profile_table, "compat-js", field_path)) |compat_js| {
                profile.compat_js = compat_js;
            }
            if (try self.expectString(profile_table, "optimize", field_path)) |optimize| {
                if (!containsString(&known_optimize, optimize)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "optimize"), valuePositionOfKey(profile_table, "optimize"), "profile \"{s}\" has invalid optimize \"{s}\"", .{ name, optimize });
                }
                profile.optimize = optimize;
            }
            try self.manifest.profiles.put(self.arena, name, profile);
        }
    }

    fn validateExports(self: *Validator, root: *std.StringHashMapUnmanaged(toml.Value)) Error!void {
        const value = root.getPtr("exports") orelse return;
        const array = switch (value.kind) {
            .array => |*array| array,
            else => {
                try self.report(diag.E023_INVALID_TYPE, "exports", value.position, "expected array for \"exports\"", .{});
                return;
            },
        };
        const known = [_][]const u8{ "name", "path", "alias", "native", "esm" };
        var exports = try std.ArrayList(Export).initCapacity(self.arena, array.items.len);
        var names = std.StringHashMap(void).init(self.scratch);
        var has_compat_js = false;
        var profile_iterator = self.manifest.profiles.valueIterator();
        while (profile_iterator.next()) |profile| {
            if (profile.compat_js) has_compat_js = true;
        }
        for (array.items) |*item| {
            const export_table = (try self.expectTable(item, "exports")) orelse continue;
            try self.rejectUnknownFields(export_table, "exports", &known);
            var export_entry = Export{
                .name = "",
                .position = item.position,
            };
            if (try self.requireString(export_table, "name", "exports", item.position)) |name| {
                export_entry.name = name;
                const gop = try names.getOrPut(name);
                if (gop.found_existing) {
                    try self.report(diag.E011_DUPLICATE_EXPORT, "exports", item.position, "duplicate export name \"{s}\"", .{name});
                }
            }
            export_entry.path = try self.expectString(export_table, "path", "exports");
            export_entry.alias = try self.expectString(export_table, "alias", "exports");
            export_entry.native = try self.expectString(export_table, "native", "exports");
            export_entry.esm = try self.expectString(export_table, "esm", "exports");
            if (export_entry.esm != null and !has_compat_js) {
                try self.report(diag.E006_JS_IN_NORMAL_MODE, "exports", item.position, "ESM export \"{s}\" requires compat-js profile", .{export_entry.name});
            }
            exports.appendAssumeCapacity(export_entry);
        }
        self.manifest.exports = try exports.toOwnedSlice(self.arena);
    }

    const SectionRef = struct { section: []const u8, group: *const DependencyGroup };

    fn dependencySections(self: *Validator) [2]SectionRef {
        return .{
            .{ .section = "dependencies", .group = &self.manifest.dependencies },
            .{ .section = "dev-dependencies", .group = &self.manifest.dev_dependencies },
        };
    }

    /// 同一 public-id の version 制約がすべて交差するか確認する。
    /// 先出の制約との比較だけではなく全ペアを検査し、
    /// `>=1 <3` `^1` `^2` のような3者間の衝突も検出する。
    fn checkConflictingVersions(self: *Validator) Error!void {
        for (self.dependencySections()) |ref| {
            const section_path = try self.pathOf(ref.section, "pkg");
            var by_public_id = std.StringHashMap(std.ArrayList(*const PkgDependency)).init(self.scratch);
            var iterator = ref.group.pkg.iterator();
            while (iterator.next()) |entry| {
                const dep = entry.value_ptr;
                const public_id = dep.public_id orelse continue;
                const gop = try by_public_id.getOrPut(public_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                if (dep.version_text.len > 0) {
                    for (gop.value_ptr.items) |existing| {
                        if (existing.version_text.len > 0 and !existing.version.intersects(dep.version)) {
                            const field_path = try self.pathOf(section_path, dep.name);
                            try self.report(diag.E003_CONFLICTING_VERSIONS, field_path, dep.position, "conflicting version constraints for {s}: \"{s}\" vs \"{s}\"", .{ public_id, existing.version_text, dep.version_text });
                        }
                    }
                }
                try gop.value_ptr.append(self.scratch, dep);
            }
        }
    }

    const DepKind = enum { pkg, npm, path, git, http };
    const ClaimKind = enum { entry, alias };
    /// alias 名前空間への登録情報。`own_name`/`group` は登録した依存の所属。
    const AliasClaim = struct { own_name: []const u8, kind: ClaimKind, group: DepKind };

    /// 依存 alias 名前空間の衝突を検出する。feature が参照する
    /// 「エントリ名または `alias`」は同一セクション内で一意でなければならず、
    /// 別グループのエントリ名や他の alias との重複は `E012` とする。
    fn checkAliasCollisions(self: *Validator) Error!void {
        for (self.dependencySections()) |ref| {
            var seen = std.StringHashMap(AliasClaim).init(self.scratch);
            // エントリ名を先に全グループ登録し、次に明示 alias を登録する。
            var pkg_iter = ref.group.pkg.iterator();
            while (pkg_iter.next()) |entry| {
                try self.claimAliasName(&seen, ref.section, entry.key_ptr.*, entry.value_ptr.position, .{ .kind = .entry, .group = .pkg, .own_name = entry.value_ptr.name });
            }
            var npm_iter = ref.group.npm.iterator();
            while (npm_iter.next()) |entry| {
                try self.claimAliasName(&seen, ref.section, entry.key_ptr.*, entry.value_ptr.position, .{ .kind = .entry, .group = .npm, .own_name = entry.value_ptr.name });
            }
            var path_iter = ref.group.path.iterator();
            while (path_iter.next()) |entry| {
                try self.claimAliasName(&seen, ref.section, entry.key_ptr.*, entry.value_ptr.position, .{ .kind = .entry, .group = .path, .own_name = entry.value_ptr.name });
            }
            var git_iter = ref.group.git.iterator();
            while (git_iter.next()) |entry| {
                try self.claimAliasName(&seen, ref.section, entry.key_ptr.*, entry.value_ptr.position, .{ .kind = .entry, .group = .git, .own_name = entry.value_ptr.name });
            }
            var http_iter = ref.group.http.iterator();
            while (http_iter.next()) |entry| {
                try self.claimAliasName(&seen, ref.section, entry.key_ptr.*, entry.value_ptr.position, .{ .kind = .entry, .group = .http, .own_name = entry.value_ptr.name });
            }
            pkg_iter = ref.group.pkg.iterator();
            while (pkg_iter.next()) |entry| {
                if (entry.value_ptr.alias) |alias| {
                    try self.claimAliasName(&seen, ref.section, alias, entry.value_ptr.position, .{ .kind = .alias, .group = .pkg, .own_name = entry.value_ptr.name });
                }
            }
            git_iter = ref.group.git.iterator();
            while (git_iter.next()) |entry| {
                if (entry.value_ptr.alias) |alias| {
                    try self.claimAliasName(&seen, ref.section, alias, entry.value_ptr.position, .{ .kind = .alias, .group = .git, .own_name = entry.value_ptr.name });
                }
            }
            http_iter = ref.group.http.iterator();
            while (http_iter.next()) |entry| {
                if (entry.value_ptr.alias) |alias| {
                    try self.claimAliasName(&seen, ref.section, alias, entry.value_ptr.position, .{ .kind = .alias, .group = .http, .own_name = entry.value_ptr.name });
                }
            }
        }
    }

    /// `name` を alias 名前空間に登録する。依存が自分のエントリ名と
    /// 同じ `alias` を宣言する場合のみ重複登録を見逃す。
    fn claimAliasName(self: *Validator, seen: *std.StringHashMap(AliasClaim), section: []const u8, name: []const u8, position: Position, claim: AliasClaim) Error!void {
        const gop = try seen.getOrPut(name);
        if (gop.found_existing) {
            const existing = gop.value_ptr;
            const self_alias = claim.kind == .alias and existing.kind == .entry and
                existing.group == claim.group and std.mem.eql(u8, existing.own_name, claim.own_name);
            if (!self_alias) {
                try self.report(diag.E012_ALIAS_COLLISION, section, position, "dependency name or alias \"{s}\" is used by multiple dependencies", .{name});
            }
            return;
        }
        gop.value_ptr.* = claim;
    }

    /// 依存 `profile` 参照が定義済み profile 名を指すか確認する。
    fn checkProfileReferences(self: *Validator) Error!void {
        for (self.dependencySections()) |ref| {
            const section_path = try self.pathOf(ref.section, "pkg");
            var iterator = ref.group.pkg.iterator();
            while (iterator.next()) |entry| {
                const dep = entry.value_ptr;
                const profile = dep.profile orelse continue;
                if (!self.manifest.profiles.contains(profile)) {
                    const field_path = try self.pathOf(section_path, dep.name);
                    try self.report(diag.E030_UNKNOWN_PROFILE, try self.pathOf(field_path, "profile"), dep.position, "unknown profile \"{s}\"", .{profile});
                }
            }
        }
    }

    /// feature 定義の各項目が定義済み feature か依存 alias を指すか確認する。
    fn checkFeatureReferences(self: *Validator) Error!void {
        const aliases = try self.manifest.dependencyAliases(self.scratch);
        var iterator = self.manifest.features.iterator();
        while (iterator.next()) |entry| {
            const definition = entry.value_ptr;
            for (definition.items) |item| {
                if (self.manifest.features.contains(item)) continue;
                if (aliases.contains(item)) continue;
                const field_path = try self.pathOf("features", definition.name);
                try self.report(diag.E028_UNKNOWN_FEATURE, field_path, definition.position, "unknown feature \"{s}\" referenced by \"{s}\"", .{ item, definition.name });
            }
        }
    }

    fn checkFeatureCycles(self: *Validator) Error!void {
        if (try features_mod.checkCycles(self.scratch, &self.manifest.features)) |cycle| {
            const position = if (self.manifest.features.get(cycle)) |definition| definition.position else Position{};
            const field_path = try self.pathOf("features", cycle);
            try self.report(diag.E027_FEATURE_CYCLE, field_path, position, "feature cycle involving \"{s}\"", .{cycle});
        }
    }
};

fn valuePositionOfKey(table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8) Position {
    if (table.getPtr(key)) |value| return value.position;
    return .{};
}

fn containsString(list: []const []const u8, text: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

/// `^\d+\.\d+\.\d+$` を検査して Version を返す。先頭ゼロは schema どおり許容する。
fn parsePlainVersion(text: []const u8) ?semver.Version {
    var parts = std.mem.splitScalar(u8, text, '.');
    var numbers: [3]u64 = undefined;
    for (&numbers) |*number| {
        const part = parts.next() orelse return null;
        if (part.len == 0) return null;
        for (part) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
        }
        number.* = std.fmt.parseInt(u64, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
}

fn isPackageName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (!std.ascii.isLower(text[0])) return false;
    for (text[1..]) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

fn isFeatureName(text: []const u8) bool {
    if (text.len < 2) return false;
    if (!std.ascii.isLower(text[0])) return false;
    for (text[1..]) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

fn isPublicId(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "pkg:")) return false;
    const hex = text[4..];
    if (hex.len != 32) return false;
    for (hex) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn isCommitId(text: []const u8) bool {
    if (text.len < 7 or text.len > 40) return false;
    for (text) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn isHash(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "sha256:")) return text.len == 7 + 64 and isHex(text[7..]);
    if (std.mem.startsWith(u8, text, "sha512:")) return text.len == 7 + 128 and isHex(text[7..]);
    if (std.mem.startsWith(u8, text, "sha256-")) return isBase64Hash(text[7..], 43);
    if (std.mem.startsWith(u8, text, "sha512-")) return isBase64Hash(text[7..], 86);
    return false;
}

fn isHex(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// `sha256-`/`sha512-` のbase64部分（末尾 `=` パディングを含む）を検査する。
fn isBase64Hash(text: []const u8, digits: usize) bool {
    if (text.len != digits + 1 or text[text.len - 1] != '=') return false;
    for (text[0 .. text.len - 1]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/')) return false;
    }
    return true;
}

fn parseOk(allocator: std.mem.Allocator, source: []const u8) !Manifest {
    var list = diag.List.init(allocator);
    defer list.deinit();
    return parse(allocator, source, &list);
}

fn parseErrCode(allocator: std.mem.Allocator, source: []const u8, code: []const u8) !void {
    var list = diag.List.init(allocator);
    defer list.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(allocator, source, &list));
    try std.testing.expect(list.find(code) != null);
}

test "妥当なmanifestを解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "http-kit"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[features]
        \\default = ["client"]
        \\client = []
        \\server = ["client"]
        \\
        \\[dependencies.pkg]
        \\client = { version = ">=1.0.0 <2.0.0", features = ["http"], default-features = false }
        \\
        \\[profiles]
        \\default = { os = "linux", cpu = "x86_64", abi = "gnu" }
        \\
        \\[[exports]]
        \\name = "http-kit"
        \\path = "src/main.nako3"
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("http-kit", manifest.package.name);
    try std.testing.expectEqual(@as(u64, 0), manifest.package.version.major);
    try std.testing.expectEqual(@as(u64, 1), manifest.package.version.minor);
    try std.testing.expectEqualStrings("MIT", manifest.package.license);
    try std.testing.expectEqual(@as(usize, 3), manifest.features.count());
    const client = manifest.dependencies.pkg.get("client").?;
    try std.testing.expect(!client.default_features);
    try std.testing.expect(client.version.satisfies(try semver.Version.parse("1.5.0")));
    try std.testing.expect(!client.version.satisfies(try semver.Version.parse("2.0.0")));
    const profile = manifest.profiles.get("default").?;
    try std.testing.expectEqualStrings("linux", profile.os);
    try std.testing.expectEqual(@as(usize, 1), manifest.exports.len);
    try std.testing.expectEqualStrings("http-kit", manifest.exports[0].name);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var expanded = try manifest.expandFeatures(allocator, &.{}, true, &list);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("default"));
    try std.testing.expect(expanded.contains("client"));
    try std.testing.expect(!expanded.contains("server"));
    try std.testing.expect(!expanded.dependency_aliases.contains("client"));
}

test "feature経由の依存aliasを展開する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "app"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[features]
        \\web = ["reqwest"]
        \\
        \\[dependencies.pkg]
        \\reqwest = { version = "^1.0.0" }
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();

    var list = diag.List.init(allocator);
    defer list.deinit();
    var expanded = try manifest.expandFeatures(allocator, &.{"web"}, false, &list);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("web"));
    try std.testing.expect(expanded.dependency_aliases.contains("reqwest"));
}

test "必須フィールド欠落を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[features]\naa = []\n", diag.E019_REQUIRED_FIELD_MISSING);
    try parseErrCode(allocator, "[package]\nversion = \"1.0.0\"\nlicense = \"MIT\"\n", diag.E019_REQUIRED_FIELD_MISSING);
    try parseErrCode(allocator, "[dependencies.pkg]\nreq = {}\n", diag.E019_REQUIRED_FIELD_MISSING);
}

test "TOML構文エラーとUTF-8を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package\nname = \"a\"\n", diag.E020_INVALID_TOML);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nname = \"b\"\n", diag.E020_INVALID_TOML);
    try parseErrCode(allocator, "[package]\nname = \"\xff\"\n", diag.E021_INVALID_UTF8);
}

test "未知フィールドと型不一致を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nweird = 1\n", diag.E022_UNKNOWN_FIELD);
    try parseErrCode(allocator, "surprise = 1\n[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n", diag.E022_UNKNOWN_FIELD);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = 3\n", diag.E023_INVALID_TYPE);
    try parseErrCode(allocator, "package = 1\n", diag.E023_INVALID_TYPE);
}

test "無効なsemverと範囲を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0\"\nlicense = \"MIT\"\n", diag.E024_INVALID_SEMVER);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[dependencies.pkg]\nreq = { version = \">=\" }\n", diag.E025_INVALID_RANGE);
}

test "未知のschema versionを診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 99\n", diag.E001_UNKNOWN_MANIFEST_SCHEMA);
    // u32 範囲を超える巨大な値も E001 とする。
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 99999999999\n", diag.E001_UNKNOWN_MANIFEST_SCHEMA);
    // 0 は schema の minimum 違反で E029。
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\nschema-version = 0\n", diag.E029_INVALID_VALUE);
}

test "無効なprofileを診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[profiles]\np = { os = " ++ "\"freebsd\"" ++ ", cpu = \"x86_64\", abi = \"gnu\" }\n", diag.E014_INVALID_PROFILE);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[profiles]\np = { os = \"linux\", cpu = \"x86_64\", abi = \"gnu\", optimize = \"O9\" }\n", diag.E029_INVALID_VALUE);
}

test "export重複とESM制約を診断する" {
    const allocator = std.testing.allocator;
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[[exports]]\nname = \"x\"\n[[exports]]\nname = \"x\"\n", diag.E011_DUPLICATE_EXPORT);
    try parseErrCode(allocator, "[package]\nname = \"a\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[[exports]]\nname = \"x\"\nesm = \"m.mjs\"\n", diag.E006_JS_IN_NORMAL_MODE);

    // compat-js profile があれば ESM export は受理される。
    const ok_source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[profiles]
        \\web = { os = "linux", cpu = "x86_64", abi = "gnu", compat-js = true }
        \\[[exports]]
        \\name = "x"
        \\esm = "m.mjs"
        \\
    ;
    var manifest = try parseOk(allocator, ok_source);
    defer manifest.deinit();
}

test "同一public-idの衝突するversion制約を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, source, diag.E003_CONFLICTING_VERSIONS);

    // 交差する制約は受理する。
    const ok_source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = ">=2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    var manifest = try parseOk(allocator, ok_source);
    defer manifest.deinit();
}

test "feature循環を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\aa = ["bb"]
        \\bb = ["aa"]
        \\
    ;
    try parseErrCode(allocator, source, diag.E027_FEATURE_CYCLE);
}

test "未知featureと未知profile参照を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\web = ["missing-dep"]
        \\
    ;
    try parseErrCode(allocator, source, diag.E028_UNKNOWN_FEATURE);

    const bad_profile =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1", profile = "nope" }
        \\
    ;
    try parseErrCode(allocator, bad_profile, diag.E030_UNKNOWN_PROFILE);
}

test "npm依存の文字列短縮形とテーブル形を解析する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.npm]
        \\leftpad = "^1.0.0"
        \\express = { version = "^4.0.0", context = "web", peer-dependencies = { ws = "^8" }, optional-peers = ["debug"] }
        \\
    ;
    var manifest = try parseOk(allocator, source);
    defer manifest.deinit();
    const leftpad = manifest.dependencies.npm.get("leftpad").?;
    try std.testing.expect(leftpad.version.satisfies(try semver.Version.parse("1.2.0")));
    const express = manifest.dependencies.npm.get("express").?;
    try std.testing.expectEqualStrings("web", express.context.?);
    try std.testing.expect(express.peer_dependencies.contains("ws"));
    try std.testing.expectEqual(@as(usize, 1), express.optional_peers.len);
}

test "alias衝突を診断する" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = "^1", alias = "shared" }
        \\two = { version = "^2", alias = "shared" }
        \\
    ;
    try parseErrCode(allocator, source, diag.E012_ALIAS_COLLISION);

    // alias が他の依存エントリ名と衝突しても E012。
    const entry_collision =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1", alias = "other" }
        \\other = { version = "^2" }
        \\
    ;
    try parseErrCode(allocator, entry_collision, diag.E012_ALIAS_COLLISION);

    // git 依存の alias も同じ名前空間で検査する。
    const git_collision =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\req = { version = "^1" }
        \\[dependencies.git]
        \\lib = { url = "https://example.com/lib.git", commit = "0123456", alias = "req" }
        \\
    ;
    try parseErrCode(allocator, git_collision, diag.E012_ALIAS_COLLISION);
}

test "同一public-idの3者間衝突とfeature名規則を診断する" {
    const allocator = std.testing.allocator;
    // `>=1 <3` は `^1`/`^2` のどちらとも交差するが `^1` と `^2` は互いに衝突する。
    const three_way =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\one = { version = ">=1.0.0 <3.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\two = { version = "^1.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\three = { version = "^2.0.0", public-id = "pkg:0123456789abcdef0123456789abcdef" }
        \\
    ;
    try parseErrCode(allocator, three_way, diag.E003_CONFLICTING_VERSIONS);

    // feature 定義の項目は featureName パターンに一致しなければならない。
    const bad_item =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[features]
        \\web = ["!!"]
        \\
    ;
    try parseErrCode(allocator, bad_item, diag.E029_INVALID_VALUE);

    // nako-version は `^\d+\.\d+\.\d+$` 形式のみ受理する。
    const bad_nako_version =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\nako-version = "1.2.3-alpha"
        \\
    ;
    try parseErrCode(allocator, bad_nako_version, diag.E029_INVALID_VALUE);
    const ok_nako_version =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\nako-version = "3.7.24"
        \\min-nako-version = "3.7.0"
        \\
    ;
    var manifest = try parseOk(allocator, ok_nako_version);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(u64, 7), manifest.package.nako_version.?.minor);

    // path/git/http 依存の空名も拒否する。
    const empty_path_name =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.path]
        \\"" = { path = "x" }
        \\
    ;
    try parseErrCode(allocator, empty_path_name, diag.E029_INVALID_VALUE);
}

/// cwd から上方向に `tools/package-system/conformance` を持つリポジトリルートを探す。
/// `zig build test`（プロジェクトルートが cwd）でも `zig test` を
/// サブディレクトリから直接実行しても動作する。
fn openRepoRoot(io: std.Io) !std.Io.Dir {
    const probe = "tools/package-system/conformance/valid/manifest/minimal/nako.toml";
    var buffer: [256]u8 = undefined;
    var prefix: []const u8 = ".";
    for (0..8) |_| {
        var candidate = try std.Io.Dir.cwd().openDir(io, prefix, .{});
        if (candidate.openFile(io, probe, .{})) |file| {
            file.close(io);
            return candidate;
        } else |_| {
            candidate.close(io);
        }
        prefix = std.fmt.bufPrint(&buffer, "{s}/..", .{prefix}) catch return error.FileNotFound;
    }
    return error.FileNotFound;
}

// `tools/package-system/conformance` の manifest fixture を Zig 側でも検証する。
// 期待コードは同ディレクトリの expected.json から読み取る。
test "manifest適合fixtureを検証する" {
    const allocator = std.testing.allocator;
    var repo = try openRepoRoot(std.testing.io);
    defer repo.close(std.testing.io);
    const cases = [_]struct { path: []const u8, expected_code: ?[]const u8 }{
        .{ .path = "tools/package-system/conformance/valid/manifest/minimal/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/features/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/npm-aux/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/path-git/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/valid/manifest/profiles/nako.toml", .expected_code = null },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-schema/nako.toml", .expected_code = diag.E001_UNKNOWN_MANIFEST_SCHEMA },
        .{ .path = "tools/package-system/conformance/invalid/manifest/conflicting-version/nako.toml", .expected_code = diag.E003_CONFLICTING_VERSIONS },
        .{ .path = "tools/package-system/conformance/invalid/manifest/duplicate-exports/nako.toml", .expected_code = diag.E011_DUPLICATE_EXPORT },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-profile/nako.toml", .expected_code = diag.E014_INVALID_PROFILE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/js-without-compat-js/nako.toml", .expected_code = diag.E006_JS_IN_NORMAL_MODE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/missing-package/nako.toml", .expected_code = diag.E019_REQUIRED_FIELD_MISSING },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-field/nako.toml", .expected_code = diag.E022_UNKNOWN_FIELD },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-type/nako.toml", .expected_code = diag.E023_INVALID_TYPE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-value/nako.toml", .expected_code = diag.E029_INVALID_VALUE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-semver/nako.toml", .expected_code = diag.E024_INVALID_SEMVER },
        .{ .path = "tools/package-system/conformance/invalid/manifest/invalid-range/nako.toml", .expected_code = diag.E025_INVALID_RANGE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/alias-collision/nako.toml", .expected_code = diag.E012_ALIAS_COLLISION },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-feature/nako.toml", .expected_code = diag.E028_UNKNOWN_FEATURE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/feature-cycle/nako.toml", .expected_code = diag.E027_FEATURE_CYCLE },
        .{ .path = "tools/package-system/conformance/invalid/manifest/unknown-profile/nako.toml", .expected_code = diag.E030_UNKNOWN_PROFILE },
    };
    for (cases) |case| {
        const source = try repo.readFileAlloc(std.testing.io, case.path, allocator, .limited(1 << 20));
        defer allocator.free(source);
        var list = diag.List.init(allocator);
        defer list.deinit();
        const result = parse(allocator, source, &list);
        if (case.expected_code) |code| {
            try std.testing.expectError(error.InvalidManifest, result);
            if (list.find(code) == null) {
                std.debug.print("{s}: expected diagnostic {s}, got:", .{ case.path, code });
                for (list.items.items) |item| std.debug.print(" {s}", .{item.code});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            }
        } else {
            var manifest = result catch |err| {
                std.debug.print("{s}: unexpected error {s}, diagnostics:", .{ case.path, @errorName(err) });
                for (list.items.items) |item| std.debug.print(" {s}", .{item.code});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            };
            defer manifest.deinit();
        }
    }
}
