//! `NAKO-PKG/METADATA.toml` のモデル・シリアライズ・解析。
//!
//! METADATA.toml は `nako.toml` の配布向け正規化写像であり、パッケージの
//! 同一性・互換要件・公開 exports・配布可能な依存を記述する。ペイロードの
//! 索引（`files[]`）は含めず、`NAKO-PKG/FILES.toml` が別途 authoritative
//! な索引となる。`dev-dependencies`/`profiles` は配布情報でないため含まない。
//!
//! 解析は manifest の npkg モード（`manifest.parseNpkgMetadata`）を再利用し、
//! `schemaVersion`/`nativePluginAbi` を `Manifest.npkg` に保持する。
//!
//! 形式は `docs/package-system/SPECIFICATION.md` §6.2、
//! `tools/package-system/schema/npkg-metadata.schema.json` に対応する。

const std = @import("std");
const toml_write = @import("toml_write.zig");
const manifest_mod = @import("manifest.zig");
const diag = @import("diagnostics.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

pub const Manifest = manifest_mod.Manifest;
pub const ArtifactDecl = manifest_mod.ArtifactDecl;
pub const schema_version: u32 = manifest_mod.npkg_schema_version;

/// METADATA.toml を解析する。`manifest.npkg` に `.npkg` メタデータが
/// 設定される。失敗時は `error.InvalidManifest`。
pub const parse = manifest_mod.parseNpkgMetadata;

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sortedKeys(allocator: Allocator, map: anytype) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var iterator = map.keyIterator();
    while (iterator.next()) |key| try keys.append(allocator, key.*);
    const result = try keys.toOwnedSlice(allocator);
    std.mem.sort([]const u8, result, {}, stringLessThan);
    return result;
}

/// semver 範囲・バージョンを `"..."` フィールドとして書き出す。
/// semver 文字集合に TOML エスケープ対象は含まれない。
fn writeVersionField(writer: *std.Io.Writer, key: []const u8, version: semver.Version) !void {
    try toml_write.writeKey(writer, key);
    try writer.writeAll(" = \"");
    try version.format(writer);
    try writer.writeAll("\"\n");
}

fn writeOptionalStringField(writer: *std.Io.Writer, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| try toml_write.writeStringField(writer, key, text);
}

fn writeOptionalArrayField(writer: *std.Io.Writer, key: []const u8, items: []const []const u8) !void {
    if (items.len > 0) try toml_write.writeStringArrayField(writer, key, items);
}

fn writeEngineFields(writer: *std.Io.Writer, engines: manifest_mod.Engines) !void {
    if (engines.nako) |range| try toml_write.writeStringField(writer, "nako", range.text);
    if (engines.cnako) |range| try toml_write.writeStringField(writer, "cnako", range.text);
    if (engines.lnako) |range| try toml_write.writeStringField(writer, "lnako", range.text);
}

/// `native`/`esm` 宣言を正規化して書き出す。条件を持たない単一宣言は
/// 文字列省略形、それ以外は `{ path, when?, min-os?, libc?, features? }` の
/// インラインテーブル配列とする（宣言順は保持）。
fn writeArtifactDecls(writer: *std.Io.Writer, key: []const u8, decls: []const ArtifactDecl) !void {
    if (decls.len == 0) return;
    const simple = decls.len == 1 and decls[0].when == null and decls[0].min_os == null and
        decls[0].libc == null and decls[0].features.len == 0;
    if (simple) {
        try toml_write.writeStringField(writer, key, decls[0].path);
        return;
    }
    try toml_write.writeKey(writer, key);
    try writer.writeAll(" = [");
    for (decls, 0..) |decl, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll("{ ");
        try toml_write.writeInlineStringField(writer, true, "path", decl.path);
        if (decl.when) |when| {
            try toml_write.writeInlineStringField(writer, false, "when", when);
        }
        if (decl.min_os) |min_os| {
            try toml_write.writeInlineStringField(writer, false, "min-os", min_os);
        }
        if (decl.libc) |libc| {
            try toml_write.writeInlineStringField(writer, false, "libc", libc);
        }
        if (decl.features.len > 0) {
            try toml_write.writeInlineStringArrayField(writer, false, "features", decl.features);
        }
        try writer.writeAll(" }");
    }
    try writer.writeAll("]\n");
}

fn writePkgDependency(writer: *std.Io.Writer, dep: manifest_mod.PkgDependency) !void {
    try toml_write.writeKey(writer, dep.name);
    try writer.writeAll(" = { ");
    try toml_write.writeInlineStringField(writer, true, "version", dep.version_text);
    if (dep.features.len > 0) try toml_write.writeInlineStringArrayField(writer, false, "features", dep.features);
    if (!dep.default_features) try toml_write.writeInlineBoolField(writer, false, "default-features", false);
    if (dep.profile) |profile| try toml_write.writeInlineStringField(writer, false, "profile", profile);
    if (dep.alias) |alias| try toml_write.writeInlineStringField(writer, false, "alias", alias);
    if (dep.public_id) |public_id| try toml_write.writeInlineStringField(writer, false, "public-id", public_id);
    if (dep.prefer_native) try toml_write.writeInlineBoolField(writer, false, "prefer-native", true);
    try writer.writeAll(" }\n");
}

fn writeNpmDependency(allocator: Allocator, writer: *std.Io.Writer, dep: manifest_mod.NpmDependency) !void {
    try toml_write.writeKey(writer, dep.name);
    try writer.writeAll(" = { ");
    try toml_write.writeInlineStringField(writer, true, "version", dep.version_text);
    if (dep.context) |context| try toml_write.writeInlineStringField(writer, false, "context", context);
    if (dep.features.len > 0) try toml_write.writeInlineStringArrayField(writer, false, "features", dep.features);
    if (dep.peer_dependencies.count() > 0) {
        try writer.writeAll(", peer-dependencies = { ");
        const peers = try sortedKeys(allocator, dep.peer_dependencies);
        defer allocator.free(peers);
        for (peers, 0..) |name, index| {
            if (index > 0) try writer.writeAll(", ");
            try toml_write.writeKey(writer, name);
            try writer.writeAll(" = ");
            try toml_write.writeString(writer, dep.peer_dependencies.get(name).?.text);
        }
        try writer.writeAll(" }");
    }
    if (dep.optional_peers.len > 0) try toml_write.writeInlineStringArrayField(writer, false, "optional-peers", dep.optional_peers);
    try writer.writeAll(" }\n");
}

fn writePathDependency(writer: *std.Io.Writer, dep: manifest_mod.PathDependency) !void {
    try toml_write.writeKey(writer, dep.name);
    try writer.writeAll(" = { ");
    try toml_write.writeInlineStringField(writer, true, "path", dep.path);
    if (dep.mutable) try toml_write.writeInlineBoolField(writer, false, "mutable", true);
    try writer.writeAll(" }\n");
}

fn writeGitDependency(writer: *std.Io.Writer, dep: manifest_mod.GitDependency) !void {
    try toml_write.writeKey(writer, dep.name);
    try writer.writeAll(" = { ");
    try toml_write.writeInlineStringField(writer, true, "url", dep.url);
    try toml_write.writeInlineStringField(writer, false, "commit", dep.commit);
    if (dep.path) |path| try toml_write.writeInlineStringField(writer, false, "path", path);
    if (dep.alias) |alias| try toml_write.writeInlineStringField(writer, false, "alias", alias);
    try writer.writeAll(" }\n");
}

fn writeHttpDependency(writer: *std.Io.Writer, dep: manifest_mod.HttpDependency) !void {
    try toml_write.writeKey(writer, dep.name);
    try writer.writeAll(" = { ");
    try toml_write.writeInlineStringField(writer, true, "url", dep.url);
    try toml_write.writeInlineStringField(writer, false, "hash", dep.hash);
    if (dep.alias) |alias| try toml_write.writeInlineStringField(writer, false, "alias", alias);
    try writer.writeAll(" }\n");
}

fn writeDependencies(allocator: Allocator, writer: *std.Io.Writer, group: manifest_mod.DependencyGroup) !void {
    if (group.pkg.count() > 0) {
        try toml_write.writeSectionHeader(writer, "dependencies.pkg");
        const keys = try sortedKeys(allocator, group.pkg);
        defer allocator.free(keys);
        for (keys) |key| try writePkgDependency(writer, group.pkg.get(key).?);
        try writer.writeByte('\n');
    }
    if (group.npm.count() > 0) {
        try toml_write.writeSectionHeader(writer, "dependencies.npm");
        const keys = try sortedKeys(allocator, group.npm);
        defer allocator.free(keys);
        for (keys) |key| try writeNpmDependency(allocator, writer, group.npm.get(key).?);
        try writer.writeByte('\n');
    }
    if (group.path.count() > 0) {
        try toml_write.writeSectionHeader(writer, "dependencies.path");
        const keys = try sortedKeys(allocator, group.path);
        defer allocator.free(keys);
        for (keys) |key| try writePathDependency(writer, group.path.get(key).?);
        try writer.writeByte('\n');
    }
    if (group.git.count() > 0) {
        try toml_write.writeSectionHeader(writer, "dependencies.git");
        const keys = try sortedKeys(allocator, group.git);
        defer allocator.free(keys);
        for (keys) |key| try writeGitDependency(writer, group.git.get(key).?);
        try writer.writeByte('\n');
    }
    if (group.http.count() > 0) {
        try toml_write.writeSectionHeader(writer, "dependencies.http");
        const keys = try sortedKeys(allocator, group.http);
        defer allocator.free(keys);
        for (keys) |key| try writeHttpDependency(writer, group.http.get(key).?);
        try writer.writeByte('\n');
    }
}

fn exportLessThan(_: void, a: manifest_mod.Export, b: manifest_mod.Export) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// `manifest` から METADATA.toml を決定的に書き出す。フィールド順は固定、
/// map 由来の項目はバイト順ソート、exports は名前順。同一モデルからは
/// 常に同一バイト列になる。
pub fn emit(allocator: Allocator, manifest: *const Manifest, writer: *std.Io.Writer) !void {
    var has_native = false;
    for (manifest.exports) |export_entry| {
        if (export_entry.native.len != 0) has_native = true;
    }

    try toml_write.writeIntegerField(writer, "schemaVersion", schema_version);
    if (has_native) {
        const abi = if (manifest.npkg) |npkg| npkg.native_plugin_abi orelse manifest_mod.known_native_plugin_abi else manifest_mod.known_native_plugin_abi;
        try toml_write.writeStringField(writer, "nativePluginAbi", abi);
    }
    try writer.writeByte('\n');

    const package = manifest.package;
    try toml_write.writeSectionHeader(writer, "package");
    try toml_write.writeStringField(writer, "name", package.name);
    try writeVersionField(writer, "version", package.version);
    try toml_write.writeStringField(writer, "license", package.license);
    try writeOptionalStringField(writer, "id", package.id);
    try writeOptionalStringField(writer, "description", package.description);
    try writeOptionalArrayField(writer, "authors", package.authors);
    try writeOptionalArrayField(writer, "keywords", package.keywords);
    try writeOptionalStringField(writer, "repository", package.repository);
    try writeOptionalStringField(writer, "homepage", package.homepage);
    if (package.nako_version) |version| try writeVersionField(writer, "nako-version", version);
    if (package.min_nako_version) |version| try writeVersionField(writer, "min-nako-version", version);
    try writeOptionalArrayField(writer, "runtimes", package.runtimes);

    const engines = package.engines;
    if (engines.nako != null or engines.cnako != null or engines.lnako != null) {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "package.engines");
        try writeEngineFields(writer, engines);
    }

    if (manifest.features.count() > 0) {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "features");
        const keys = try sortedKeys(allocator, manifest.features);
        defer allocator.free(keys);
        for (keys) |key| {
            try toml_write.writeStringArrayField(writer, key, manifest.features.get(key).?.items);
        }
    }

    if (manifest.dependencies.pkg.count() > 0 or manifest.dependencies.npm.count() > 0 or
        manifest.dependencies.path.count() > 0 or manifest.dependencies.git.count() > 0 or
        manifest.dependencies.http.count() > 0)
    {
        try writer.writeByte('\n');
        try writeDependencies(allocator, writer, manifest.dependencies);
    }

    if (manifest.exports.len > 0) {
        const sorted = try allocator.dupe(manifest_mod.Export, manifest.exports);
        defer allocator.free(sorted);
        std.mem.sort(manifest_mod.Export, sorted, {}, exportLessThan);
        try writer.writeByte('\n');
        for (sorted) |export_entry| {
            try toml_write.writeArraySectionHeader(writer, "exports");
            try toml_write.writeStringField(writer, "name", export_entry.name);
            try writeOptionalStringField(writer, "alias", export_entry.alias);
            try writeOptionalStringField(writer, "path", export_entry.path);
            try writeArtifactDecls(writer, "native", export_entry.native);
            try writeArtifactDecls(writer, "esm", export_entry.esm);
            try writer.writeByte('\n');
        }
    }
}

/// METADATA.toml を `[]u8` として生成する。呼出し側が free する。
pub fn toBytes(allocator: Allocator, manifest: *const Manifest) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try emit(allocator, manifest, &output.writer);
    return output.toOwnedSlice();
}

test {
    _ = @import("npkg_test.zig");
}
