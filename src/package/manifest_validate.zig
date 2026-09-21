//! `nako.toml` / `NAKO-PKG/METADATA.toml` の意味検証。
//! `manifest.zig` から分離した Validator 実装。モデル型は manifest.zig を参照する。

const std = @import("std");
const toml = @import("toml.zig");
const semver = @import("semver.zig");
const marker_mod = @import("marker.zig");
const features_mod = @import("features.zig");
const diag = @import("diagnostics.zig");
const manifest_mod = @import("manifest.zig");

const Manifest = manifest_mod.Manifest;
const Npkg = manifest_mod.Npkg;
const Package = manifest_mod.Package;
const Engines = manifest_mod.Engines;
const Profile = manifest_mod.Profile;
const Export = manifest_mod.Export;
const ArtifactDecl = manifest_mod.ArtifactDecl;
const ArtifactTarget = manifest_mod.ArtifactTarget;
const DependencyGroup = manifest_mod.DependencyGroup;
const PkgDependency = manifest_mod.PkgDependency;
const NpmDependency = manifest_mod.NpmDependency;
const PathDependency = manifest_mod.PathDependency;
const GitDependency = manifest_mod.GitDependency;
const HttpDependency = manifest_mod.HttpDependency;
const Position = manifest_mod.Position;
const Mode = manifest_mod.Mode;
const Error = manifest_mod.Error;
const npkg_schema_version = manifest_mod.npkg_schema_version;
const known_schema_version = manifest_mod.known_schema_version;
const known_native_plugin_abi = manifest_mod.known_native_plugin_abi;
const FeatureDefinitions = manifest_mod.FeatureDefinitions;
const FeatureDefinition = manifest_mod.FeatureDefinition;
const known_package_runtime = manifest_mod.known_package_runtime;
const containsString = manifest_mod.containsString;
const compareDottedVersion = manifest_mod.compareDottedVersion;

const known_profile_runtime = [_][]const u8{ "lnako", "cnako", "any", "common" };
const known_profile_os = [_][]const u8{ "macos", "linux", "windows" };
const known_profile_cpu = [_][]const u8{ "aarch64", "x86_64", "arm", "wasm32" };
const known_profile_abi = [_][]const u8{ "gnu", "msvc", "musl", "none" };
const known_optimize = [_][]const u8{ "O0", "O1", "O2", "O3" };

/// `manifest` を検証してフィールドを埋める。エラーは diagnostics へ記録する。
pub fn run(manifest: *Manifest, scratch: std.mem.Allocator, diagnostics: *diag.List, mode: Mode) Error!void {
    var validator = Validator{
        .arena = manifest.arenaAllocator(),
        .scratch = scratch,
        .diagnostics = diagnostics,
        .manifest = manifest,
        .mode = mode,
    };
    try validator.validateRoot();
}

const Validator = struct {
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    diagnostics: *diag.List,
    manifest: *Manifest,
    mode: Mode = .manifest,

    fn report(self: *Validator, code: []const u8, path: []const u8, position: Position, comptime format: []const u8, args: anytype) Error!void {
        try self.diagnostics.addFmt(code, .err, path, position, format, args);
    }

    /// `a.b.c` 形式のフィールドパスを scratch に構築する。
    fn pathOf(self: *Validator, parent: []const u8, key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.scratch, "{s}.{s}", .{ parent, key });
    }

    fn validateRoot(self: *Validator) Error!void {
        const root = &self.manifest.document.root;
        const known = switch (self.mode) {
            .manifest => [_][]const u8{ "package", "features", "dependencies", "dev-dependencies", "profiles", "exports" },
            .npkg_metadata => [_][]const u8{ "schemaVersion", "nativePluginAbi", "package", "features", "dependencies", "exports" },
        };
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

        const npkg_fields = if (self.mode == .npkg_metadata) try self.validateNpkgFields(root) else null;
        if (npkg_fields) |fields| self.manifest.npkg = fields;

        const package_value = root.getPtr("package") orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, "package", .{}, "missing required field \"package\"", .{});
            return;
        };
        const package_table = (try self.expectTable(package_value, "package")) orelse return;
        try self.validatePackage(package_table, package_value.position);
        try self.validateFeatures(root);
        try self.validateDependencySection(root, "dependencies", &self.manifest.dependencies);
        if (self.mode == .manifest) {
            try self.validateDependencySection(root, "dev-dependencies", &self.manifest.dev_dependencies);
            try self.validateProfiles(root);
        }
        try self.validateExports(root);
        if (self.mode == .npkg_metadata) try self.checkNativePluginAbi();
        try self.checkConflictingVersions();
        try self.checkAliasCollisions();
        try self.checkProfileReferences();
        try self.checkFeatureReferences();
        try self.checkFeatureCycles();
    }

    /// `.npkg` モードのトップレベル `schemaVersion`/`nativePluginAbi` を読む。
    /// 必須欠落・型違反・未知 schema version は diagnostics へ記録する。
    fn validateNpkgFields(self: *Validator, root: *std.StringHashMapUnmanaged(toml.Value)) Error!?Npkg {
        var npkg = Npkg{};
        const version_value = root.getPtr("schemaVersion") orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, "schemaVersion", .{}, "missing required field \"schemaVersion\"", .{});
            return null;
        };
        switch (version_value.kind) {
            .integer => |number| {
                if (number <= 0 or number > std.math.maxInt(u32)) {
                    try self.report(diag.E023_INVALID_TYPE, "schemaVersion", version_value.position, "expected positive integer schemaVersion", .{});
                } else if (number != npkg_schema_version) {
                    try self.report(diag.E035_UNKNOWN_NPKG_SCHEMA, "schemaVersion", version_value.position, "unsupported METADATA.toml schemaVersion {d} (expected {d})", .{ number, npkg_schema_version });
                } else {
                    npkg.schema_version = @intCast(number);
                }
            },
            else => {
                try self.report(diag.E023_INVALID_TYPE, "schemaVersion", version_value.position, "expected integer schemaVersion", .{});
            },
        }
        if (root.getPtr("nativePluginAbi")) |abi_value| {
            switch (abi_value.kind) {
                .string => |abi| {
                    npkg.native_plugin_abi = abi;
                    if (!std.mem.eql(u8, abi, known_native_plugin_abi)) {
                        try self.report(diag.E029_INVALID_VALUE, "nativePluginAbi", abi_value.position, "unknown native plugin ABI \"{s}\" (expected \"{s}\")", .{ abi, known_native_plugin_abi });
                    }
                },
                else => {
                    try self.report(diag.E023_INVALID_TYPE, "nativePluginAbi", abi_value.position, "expected string \"nativePluginAbi\"", .{});
                },
            }
        }
        return npkg;
    }

    /// `.npkg` モードで、native artifact 宣言を持つ export があれば
    /// `nativePluginAbi` を必須とする（SPECIFICATION §6.2）。
    fn checkNativePluginAbi(self: *Validator) Error!void {
        var has_native = false;
        for (self.manifest.exports) |export_entry| {
            if (export_entry.native.len != 0) {
                has_native = true;
                break;
            }
        }
        const npkg = self.manifest.npkg orelse return;
        if (has_native and npkg.native_plugin_abi == null) {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, "nativePluginAbi", .{}, "native artifacts declared but required field \"nativePluginAbi\" is missing", .{});
        }
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

    /// `native`/`esm` フィールドを artifact 宣言列へ変換する。受理する形は
    /// 文字列省略形、宣言テーブル、またはその配列。戻り値のスライスと
    /// 各 `features` は arena 確保。
    fn expectArtifactDecls(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), key: []const u8, path: []const u8) Error![]const ArtifactDecl {
        const value = table.getPtr(key) orelse return &.{};
        const field_path = try self.pathOf(path, key);
        switch (value.kind) {
            .string => |text| {
                const decls = try self.arena.alloc(ArtifactDecl, 1);
                decls[0] = .{ .path = text, .position = value.position };
                return decls;
            },
            .table => {
                const decls = try self.arena.alloc(ArtifactDecl, 1);
                decls[0] = try self.parseArtifactDecl(value, field_path);
                return decls;
            },
            .array => |*array| {
                if (array.items.len == 0) {
                    try self.report(diag.E029_INVALID_VALUE, field_path, value.position, "\"{s}\" must not be an empty array", .{field_path});
                    return &.{};
                }
                const decls = try self.arena.alloc(ArtifactDecl, array.items.len);
                for (array.items, 0..) |*item, index| {
                    decls[index] = try self.parseArtifactDecl(item, field_path);
                }
                return decls;
            },
            else => {
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string, table, or array for \"{s}\"", .{field_path});
                return &.{};
            },
        }
    }

    /// artifact 宣言の1要素（文字列またはテーブル）を `ArtifactDecl` へ変換する。
    /// 不正要素は既定値（空pathの宣言）を返し、診断のみ記録する。
    fn parseArtifactDecl(self: *Validator, value: *toml.Value, field_path: []const u8) Error!ArtifactDecl {
        switch (value.kind) {
            .string => |text| {
                if (text.len == 0) {
                    try self.report(diag.E029_INVALID_VALUE, field_path, value.position, "\"{s}\" must not be an empty path", .{field_path});
                }
                return .{ .path = text, .position = value.position };
            },
            .table => |*decl_table| {
                const known = [_][]const u8{ "path", "when", "min-os", "libc", "features" };
                try self.rejectUnknownFields(decl_table, field_path, &known);
                var decl = ArtifactDecl{
                    .path = "",
                    .position = value.position,
                };
                if (try self.requireString(decl_table, "path", field_path, value.position)) |text| {
                    if (text.len == 0) {
                        const item_path = try self.pathOf(field_path, "path");
                        try self.report(diag.E029_INVALID_VALUE, item_path, value.position, "\"{s}.path\" must not be empty", .{field_path});
                    }
                    decl.path = text;
                }
                if (try self.expectString(decl_table, "when", field_path)) |text| {
                    var parsed = try marker_mod.parse(self.scratch, text);
                    switch (parsed) {
                        .ok => |*m| m.deinit(),
                        .err => |*syntax_error| {
                            const item_path = try self.pathOf(field_path, "when");
                            try self.report(diag.E026_INVALID_MARKER, item_path, value.position, "invalid marker expression in \"{s}.when\": {s}", .{ field_path, syntax_error.message });
                        },
                    }
                    decl.when = text;
                }
                if (try self.expectString(decl_table, "min-os", field_path)) |text| {
                    if (compareDottedVersion(text, text) == null) {
                        const item_path = try self.pathOf(field_path, "min-os");
                        try self.report(diag.E029_INVALID_VALUE, item_path, value.position, "invalid min-os \"{s}\" (expected dotted numeric version)", .{text});
                    }
                    decl.min_os = text;
                }
                if (try self.expectString(decl_table, "libc", field_path)) |text| {
                    if (!containsString(&known_profile_abi, text)) {
                        const item_path = try self.pathOf(field_path, "libc");
                        try self.report(diag.E029_INVALID_VALUE, item_path, value.position, "invalid libc \"{s}\"", .{text});
                    }
                    decl.libc = text;
                }
                if (decl_table.getPtr("features")) |features_value| {
                    const item_path = try self.pathOf(field_path, "features");
                    decl.features = try self.expectFeatureList(features_value, item_path);
                }
                return decl;
            },
            else => {
                try self.report(diag.E023_INVALID_TYPE, field_path, value.position, "expected string or table item in \"{s}\"", .{field_path});
                return .{ .path = "", .position = value.position };
            },
        }
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
        // `schema-version`・`include` は manifest 専用で、配布メタデータの
        // 正規形・JSON Schema（npkg-metadata.schema.json）には存在しない。
        // npkg_metadata モードでは未知フィールドとして拒否し、両検証を
        // 一致させる。
        const known: []const []const u8 = switch (self.mode) {
            .manifest => &.{ "name", "version", "license", "id", "description", "authors", "keywords", "repository", "homepage", "nako-version", "min-nako-version", "schema-version", "runtimes", "engines", "include" },
            .npkg_metadata => &.{ "name", "version", "license", "id", "description", "authors", "keywords", "repository", "homepage", "nako-version", "min-nako-version", "runtimes", "engines" },
        };
        try self.rejectUnknownFields(table, path, known);

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
            // Version.parse の error 集合は InvalidSemver のみ（確保しない）。
            package.version = semver.Version.parse(version_text) catch blk: {
                try self.report(diag.E024_INVALID_SEMVER, "package.version", valuePositionOfKey(table, "version"), "invalid semver \"{s}\"", .{version_text});
                break :blk .{ .major = 0, .minor = 0, .patch = 0 };
            };
        }
        if (try self.requireString(table, "license", path, position)) |license| {
            // schema は `type: string` のため値の妥当性をここで検査する。
            // SPDX expression の構文のみを検査し、識別子が SPDX 公式一覧へ
            // 登録済みかは問わない。
            if (!isLicenseExpression(license)) {
                try self.report(diag.E029_INVALID_VALUE, "package.license", valuePositionOfKey(table, "license"), "invalid license expression \"{s}\"", .{license});
            }
            package.license = license;
        }
        if (try self.expectString(table, "id", path)) |id| {
            if (!isPublicId(id)) {
                try self.report(diag.E029_INVALID_VALUE, "package.id", valuePositionOfKey(table, "id"), "invalid public id \"{s}\"", .{id});
            }
            package.id = id;
        }
        package.description = try self.expectString(table, "description", path);
        for ([_][]const u8{ "repository", "homepage" }) |key| {
            if (try self.expectString(table, key, path)) |uri| {
                // schema は `format: "uri"` を要求する。
                if (!isUri(uri)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf("package", key), valuePositionOfKey(table, key), "invalid uri \"{s}\"", .{uri});
                }
                if (std.mem.eql(u8, key, "repository")) package.repository = uri else package.homepage = uri;
            }
        }
        // schema は `^\d+\.\d+\.\d+$` を要求する（prerelease 不可・先頭ゼロ許容）。
        if (try self.parsePlainVersionField(table, "nako-version", path)) |version| package.nako_version = version;
        if (try self.parsePlainVersionField(table, "min-nako-version", path)) |version| package.min_nako_version = version;
        if (table.getPtr("authors")) |value| {
            package.authors = try self.expectStringList(value, "package.authors");
        }
        if (table.getPtr("keywords")) |value| {
            package.keywords = try self.expectStringList(value, "package.keywords");
        }
        if (table.getPtr("runtimes")) |value| {
            // 明示的な空配列は「対応処理系なし」を意味するため、未指定
            // （両対応）と区別して拒否する。
            const is_empty_array = switch (value.kind) {
                .array => |array| array.items.len == 0,
                else => false,
            };
            if (is_empty_array) {
                try self.report(diag.E029_INVALID_VALUE, "package.runtimes", value.position, "package.runtimes must contain at least one runtime", .{});
            }
            const runtimes = try self.expectStringList(value, "package.runtimes");
            for (runtimes) |r| {
                if (!containsString(&known_package_runtime, r)) {
                    try self.report(diag.E029_INVALID_VALUE, "package.runtimes", value.position, "invalid runtime \"{s}\" in package.runtimes", .{r});
                }
            }
            package.runtimes = runtimes;
        }
        if (table.getPtr("engines")) |value| {
            const engines_path = "package.engines";
            if (try self.expectTable(value, engines_path)) |engines_table| {
                const known_engines = [_][]const u8{ "nako", "cnako", "lnako" };
                try self.rejectUnknownFields(engines_table, engines_path, &known_engines);
                package.engines.position = value.position;
                if (try self.parseRangeField(engines_table, "nako", engines_path, false, value.position)) |range| {
                    package.engines.nako = range;
                }
                if (try self.parseRangeField(engines_table, "cnako", engines_path, false, value.position)) |range| {
                    package.engines.cnako = range;
                }
                if (try self.parseRangeField(engines_table, "lnako", engines_path, false, value.position)) |range| {
                    package.engines.lnako = range;
                }
            }
        }
        if (self.mode == .manifest) {
            if (table.getPtr("include")) |value| {
                package.include = try self.expectStringList(value, "package.include");
            }
        }
        if (self.mode == .manifest) {
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
        return semver.Range.parse(self.arena, text) catch |err| switch (err) {
            // 資源枯渇を入力エラーへ変換しない。
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const field_path = try self.pathOf(path, key);
                try self.report(diag.E025_INVALID_RANGE, field_path, value.position, "invalid version range \"{s}\" for \"{s}\"", .{ text, field_path });
                return null;
            },
        };
    }

    fn validatePkgDeps(self: *Validator, table: *std.StringHashMapUnmanaged(toml.Value), path: []const u8, map: *std.StringHashMapUnmanaged(PkgDependency)) Error!void {
        const known = [_][]const u8{ "version", "features", "default-features", "profile", "alias", "public-id", "prefer-native" };
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
            if (try self.expectBool(dep_table, "prefer-native", field_path)) |prefer_native| {
                dep.prefer_native = prefer_native;
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
                    dep.version = semver.Range.parse(self.arena, text) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => blk: {
                            try self.report(diag.E025_INVALID_RANGE, field_path, entry.value_ptr.position, "invalid version range \"{s}\" for \"{s}\"", .{ text, field_path });
                            break :blk .{ .sets = &.{}, .text = text };
                        },
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
                                const peer_range = semver.Range.parse(self.arena, peer_text) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    else => {
                                        try self.report(diag.E025_INVALID_RANGE, peer_path, peer.value_ptr.position, "invalid version range \"{s}\" for \"{s}\"", .{ peer_text, peer_path });
                                        continue;
                                    },
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
                if (!isUri(url)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "url"), valuePositionOfKey(dep_table, "url"), "invalid uri \"{s}\"", .{url});
                }
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
                if (!isUri(url)) {
                    try self.report(diag.E029_INVALID_VALUE, try self.pathOf(field_path, "url"), valuePositionOfKey(dep_table, "url"), "invalid uri \"{s}\"", .{url});
                }
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
        const known = [_][]const u8{ "runtime", "os", "cpu", "abi", "compat-js", "optimize" };
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
            if (try self.expectString(profile_table, "runtime", field_path)) |runtime_text| {
                if (!containsString(&known_profile_runtime, runtime_text)) {
                    try self.report(diag.E014_INVALID_PROFILE, try self.pathOf(field_path, "runtime"), valuePositionOfKey(profile_table, "runtime"), "profile \"{s}\" has invalid runtime \"{s}\"", .{ name, runtime_text });
                }
                profile.runtime = runtime_text;
            }
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
        // 未指定の runtimes は lnako / cnako の両対応を意味するため cnako 対応。
        // cnako 対応パッケージは ESM を直接利用できる有効な経路を持つ。
        var supports_cnako = self.manifest.package.runtimes.len == 0;
        for (self.manifest.package.runtimes) |r| {
            if (std.mem.eql(u8, r, "cnako")) supports_cnako = true;
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
            export_entry.native = try self.expectArtifactDecls(export_table, "native", "exports");
            export_entry.esm = try self.expectArtifactDecls(export_table, "esm", "exports");
            // artifact の features は [features] で定義済みの名だけを指す。
            // 未定義名は有効 feature 集合へ入る経路が無く、常に不適合な
            // 宣言（=検証不能なパッケージ）になるためここで拒否する。
            for ([_][]const ArtifactDecl{ export_entry.native, export_entry.esm }) |decls| {
                for (decls) |decl| {
                    for (decl.features) |feature| {
                        if (!self.manifest.features.contains(feature)) {
                            try self.report(diag.E028_UNKNOWN_FEATURE, "exports", decl.position, "unknown feature \"{s}\" in artifact condition", .{feature});
                        }
                    }
                }
            }
            // lnako 通常モードで ESM が選択されるのは「path も native も無い」
            // 場合のみ（path があれば共通ソース、native があれば native を選択）。
            // cnako 対応（runtimes 未指定・cnako を含む）または compat-js profile
            // なら ESM を利用できる経路があるため受理し、lnako 専用パッケージで
            // 通常モードに限って E006 を報告する。cnako profile はパッケージが
            // cnako 対応の場合にのみ有効な経路であり、runtimes で cnako を
            // 否定している矛盾した宣言では数えない。実行時は Export.resolve が
            // 対象 runtime へ E006 を報告する。
            if (export_entry.esm.len != 0 and export_entry.path == null and export_entry.native.len == 0 and
                !has_compat_js and !supports_cnako)
            {
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

    /// 同一 public-id の version 制約すべてを同時に満たすバージョンが
    /// 存在するか確認する。二者間の交差判定だけでは OR 範囲を含む
    /// 3者以上の衝突を検出できないため、public-id 毎に制約の積集合を
    /// AND 比較子集合の OR リストとして保持する。
    fn checkConflictingVersions(self: *Validator) Error!void {
        // 1 public-id あたりに保持する積集合パス数の上限。各依存の OR
        // 選択肢数の積に比例して増え得るため、近似判定の消費を抑える。
        const max_joint_paths = 1024;
        const JointState = struct {
            paths: std.ArrayList([]const []const semver.Comparator) = .empty,
            /// パス数上限で絞り込みを打ち切ったか。打ち切った積集合は
            /// 部分集合しか保持しないため後続の依存で空になり得るが、
            /// それは打ち切りによる偽の衝突であり得る。以後の絞り込みを
            /// 行わず「非空のまま」とみなす（見逃し方向にのみ影響する）。
            saturated: bool = false,
        };
        // 二者間の交差だけでは全制約の共通候補の存在を保証しないため
        // （OR 範囲で各ペアが別の選択肢で交差し得る）、public-id 毎に
        // 積集合を保持する。各パスは依存毎に選んだ AND 比較子集合の
        // 列で、prerelease ゲートは構成集合毎に評価する必要があるため
        // 併合済みの平坦な集合は保持しない。開発解決では通常依存と
        // dev-dependencies の両方が同じ public-id に効くため、
        // 積集合はセクションをまたいで共有する。
        var by_public_id = std.StringHashMap(JointState).init(self.scratch);
        for (self.dependencySections()) |ref| {
            const section_path = try self.pathOf(ref.section, "pkg");
            // 反復順を宣言順に揃えて JS バリデータと結果を一致させる。
            var ordered: std.ArrayList(*const PkgDependency) = .empty;
            var iterator = ref.group.pkg.iterator();
            while (iterator.next()) |entry| try ordered.append(self.scratch, entry.value_ptr);
            std.mem.sort(*const PkgDependency, ordered.items, {}, struct {
                fn lessThan(_: void, a: *const PkgDependency, b: *const PkgDependency) bool {
                    return a.position.offset < b.position.offset;
                }
            }.lessThan);
            for (ordered.items) |dep| {
                const public_id = dep.public_id orelse continue;
                // version 欠落・不正（E019/E025 で報告済み）は無制約として
                // 扱い、空の外積による誤診を避ける。`version = ""` のような
                // match-all 範囲は `sets = [[]]` で表現され通常通り参加する。
                if (dep.version.sets.len == 0) continue;
                const gop = try by_public_id.getOrPut(public_id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                if (gop.value_ptr.saturated) continue;
                // 積集合が空リストのときは新しい制約の集合をそのまま採用する。
                if (gop.value_ptr.paths.items.len == 0) {
                    for (dep.version.sets) |set| {
                        if (gop.value_ptr.paths.items.len >= max_joint_paths) {
                            gop.value_ptr.saturated = true;
                            break;
                        }
                        const path = try self.scratch.alloc([]const semver.Comparator, 1);
                        path[0] = set;
                        try gop.value_ptr.paths.append(self.scratch, path);
                    }
                    continue;
                }
                var next: std.ArrayList([]const []const semver.Comparator) = .empty;
                var capped = false;
                for (gop.value_ptr.paths.items) |path| {
                    for (dep.version.sets) |set| {
                        const merged = try std.mem.concat(self.scratch, []const semver.Comparator, &.{ path, &.{set} });
                        if (semver.jointSetsIntersect(merged)) {
                            try next.append(self.scratch, merged);
                            if (next.items.len >= max_joint_paths) {
                                capped = true;
                                break;
                            }
                        }
                    }
                    if (capped) break;
                }
                if (next.items.len == 0) {
                    const field_path = try self.pathOf(section_path, dep.name);
                    try self.report(diag.E003_CONFLICTING_VERSIONS, field_path, dep.position, "conflicting version constraints for {s}: \"{s}\" leaves no common version", .{ public_id, dep.version_text });
                } else if (capped) {
                    gop.value_ptr.saturated = true;
                } else {
                    gop.value_ptr.paths = next;
                }
            }
        }
    }

    const DepKind = enum { pkg, npm, path, git, http };
    const ClaimKind = enum { entry, alias };
    /// alias 名前空間への登録情報。`own_name`/`group` は登録した依存の所属。
    const AliasClaim = struct { own_name: []const u8, kind: ClaimKind, group: DepKind };

    /// 依存 alias 名前空間の衝突を検出する。feature が参照する
    /// 「エントリ名または `alias`」の名前空間は dependencies /
    /// dev-dependencies で統合されるため、セクションをまたぐ重複を含めて
    /// 一意でなければならず、重複は `E012` とする。
    fn checkAliasCollisions(self: *Validator) Error!void {
        var seen = std.StringHashMap(AliasClaim).init(self.scratch);
        defer seen.deinit();
        for (self.dependencySections()) |ref| {
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

/// `format: "uri"` を検証する。RFC 3986 の絶対 URI の部分集合で、
/// scheme `[a-zA-Z][a-zA-Z0-9+.-]*:` と、空白・制御文字を含まない
/// 非空の残部を要求する（残部の文字構成までは検査しない）。
/// JS バリデータの `isUri` と同一の判定。
fn isUri(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    const scheme = text[0..colon];
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) return false;
    }
    const rest = text[colon + 1 ..];
    if (rest.len == 0) return false;
    for (rest) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
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

/// `package.license` を検証する。SPDX license expression の構文
/// （識別子・`+` 接尾・`WITH` 例外・`AND`/`OR` 結合・括弧）のみ検査し、
/// 識別子が SPDX 公式一覧に登録済みかは検査しない。
/// `UNLICENSED`/`Proprietary` も識別子として構文上受理される。
/// JS バリデータの `isLicenseExpression` と同一の判定。
fn isLicenseExpression(text: []const u8) bool {
    var i: usize = 0;
    if (!licenseExpr(text, &i, 0)) return false;
    licenseSkipWs(text, &i);
    return i == text.len;
}

fn licenseSkipWs(text: []const u8, i: *usize) void {
    while (i.* < text.len and (text[i.*] == ' ' or text[i.*] == '\t')) i.* += 1;
}

/// 空白と括弧をデリミタとする1トークンを読み進めて返す。
fn licenseToken(text: []const u8, i: *usize) ?[]const u8 {
    licenseSkipWs(text, i);
    const start = i.*;
    while (i.* < text.len and text[i.*] != ' ' and text[i.*] != '\t' and
        text[i.*] != '(' and text[i.*] != ')') i.* += 1;
    if (i.* == start) return null;
    return text[start..i.*];
}

/// license-id / LicenseRef / 例外識別子。文字集合は `[A-Za-z0-9.-]` で、
/// `allow_plus` のとき末尾に1つだけ `+` 接尾を許容する（`WITH` の例外
/// 識別子には `+` を許容しない）。`:` を含むトークンは
/// `DocumentRef-<id>:LicenseRef-<id>` 複合形のみ許容し、Ref 形には
/// `+` 接尾を付けられない。予約語 `AND`/`OR`/`WITH` は識別子に使えない。
fn isLicenseId(token: []const u8, allow_plus: bool) bool {
    var t = token;
    const had_plus = t.len > 0 and t[t.len - 1] == '+';
    if (allow_plus and had_plus) t = t[0 .. t.len - 1];
    if (t.len == 0) return false;
    if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
        // コロンは DocumentRef 複合形の区切り専用で、`+` 接尾は付けられない。
        if (had_plus) return false;
        const doc = t[0..colon];
        const ref = t[colon + 1 ..];
        return std.mem.startsWith(u8, doc, "DocumentRef-") and
            std.mem.startsWith(u8, ref, "LicenseRef-") and
            isLicenseIdPart(doc["DocumentRef-".len..]) and
            isLicenseIdPart(ref["LicenseRef-".len..]);
    }
    if (!isLicenseIdPart(t)) return false;
    if (std.mem.startsWith(u8, t, "LicenseRef-")) {
        // LicenseRef 単体は非空の idstring が必要で、`+` 接尾も付けられない。
        if (had_plus or t.len == "LicenseRef-".len) return false;
    }
    // `DocumentRef-` 接頭辞は複合形でのみ意味を持つため、単体でも
    // 空 idstring は受理しない（非空なら通常識別子として扱う）。
    if (t.len == "DocumentRef-".len and std.mem.startsWith(u8, t, "DocumentRef-")) return false;
    return !std.mem.eql(u8, t, "AND") and !std.mem.eql(u8, t, "OR") and !std.mem.eql(u8, t, "WITH");
}

/// 識別子の構成要素（`[A-Za-z0-9.-]+`、非空）。
fn isLicenseIdPart(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-')) return false;
    }
    return true;
}

/// 括弧のネスト上限。再帰によるスタック消費を抑える（32段で十分）。
const max_license_depth = 32;

fn licenseExpr(text: []const u8, i: *usize, depth: usize) bool {
    if (!licenseTerm(text, i, depth)) return false;
    while (true) {
        const save = i.*;
        const op = licenseToken(text, i) orelse {
            i.* = save;
            return true;
        };
        if (!std.mem.eql(u8, op, "AND") and !std.mem.eql(u8, op, "OR")) {
            i.* = save;
            return true;
        }
        if (!licenseTerm(text, i, depth)) return false;
    }
}

fn licenseTerm(text: []const u8, i: *usize, depth: usize) bool {
    licenseSkipWs(text, i);
    if (i.* < text.len and text[i.*] == '(') {
        if (depth >= max_license_depth) return false;
        i.* += 1;
        if (!licenseExpr(text, i, depth + 1)) return false;
        licenseSkipWs(text, i);
        if (i.* >= text.len or text[i.*] != ')') return false;
        i.* += 1;
        return true;
    }
    const id = licenseToken(text, i) orelse return false;
    if (!isLicenseId(id, true)) return false;
    const save = i.*;
    if (licenseToken(text, i)) |next| {
        if (std.mem.eql(u8, next, "WITH")) {
            const exception = licenseToken(text, i) orelse return false;
            // 例外識別子は `+` 接尾・`:`（DocumentRef 複合形）を許容しない。
            return isLicenseId(exception, false) and std.mem.indexOfScalar(u8, exception, ':') == null;
        }
    }
    i.* = save;
    return true;
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
