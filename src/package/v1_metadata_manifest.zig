//! v1 のソースマニフェスト（`nako.toml`）から、配布用 METADATA.toml の
//! モデルと収録対象の glob を射影する。
//!
//! 仕様 §2 の pack 用必須欄（`package.id`・公開 `version`・`license`）を
//! 要求し、ローカル専用の省略は受理しない。`dev-dependencies` と `profiles`
//! は配布情報ではないためモデルへ含めない。`runtime-dependencies.<runtime>`
//! は `runtimes = [runtime]` の依存として保持する。
//!
//! マニフェスト全体の検証（未知キー、旧形式、予約 scope など）は P02 の
//! `v1_manifest` が担う。ここでは pack が必要とする部分だけを読み、型違い・
//! 必須欠落を個別の error tag で返す。

const std = @import("std");
const toml = @import("toml.zig");
const types = @import("v1_types.zig");
const metadata = @import("v1_metadata.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    InvalidManifest,
    MissingField,
    InvalidFieldType,
    InvalidPackageId,
    InvalidVersion,
    InvalidLicense,
    InvalidRuntime,
    InvalidKind,
    InvalidInclude,
    InvalidExport,
    InvalidDependency,
    MissingLibraryName,
    MissingLibrary,
    AmbiguousLibrary,
    InvalidTargetTriple,
};

/// pack 時に明示する native-prebuilt の指定。nako.toml の
/// `[artifacts.native]` には triple・glibc 下限が無いため、呼出し側
/// （CI の成果物指定）から渡す。`library_path` は
/// `[artifacts.native].prebuilt_lib_name` から導出できない場合の明示入力で、
/// 指定時は導出より優先する。
pub const NativeOverrides = struct {
    target_triple: ?[]const u8 = null,
    abi_version: ?u32 = null,
    glibc_min: ?[]const u8 = null,
    library_path: ?[]const u8 = null,
};

pub const Projection = struct {
    model: metadata.Model,
    universal_include: []const []const u8 = &.{},
    esm_include: []const []const u8 = &.{},
    esm_entry: ?[]const u8 = null,
    source_include: []const []const u8 = &.{},
};

/// native-source のビルド入力として扱うファイル名。
pub const source_build_file = "build.zig";

const Table = std.StringHashMapUnmanaged(toml.Value);

fn asTable(value: *const toml.Value) !*const Table {
    return switch (value.kind) {
        .table => |*table| table,
        else => error.InvalidFieldType,
    };
}

fn asArray(value: *const toml.Value) !*const std.ArrayList(toml.Value) {
    return switch (value.kind) {
        .array => |*array| array,
        else => error.InvalidFieldType,
    };
}

fn field(table: *const Table, name: []const u8) !*const toml.Value {
    return table.getPtr(name) orelse error.MissingField;
}

fn optionalField(table: *const Table, name: []const u8) ?*const toml.Value {
    return table.getPtr(name);
}

fn fieldString(table: *const Table, name: []const u8) ![]const u8 {
    const value = try field(table, name);
    return value.asString() orelse error.InvalidFieldType;
}

fn optionalString(table: *const Table, name: []const u8) !?[]const u8 {
    const value = optionalField(table, name) orelse return null;
    return value.asString() orelse error.InvalidFieldType;
}

const PrebuiltLibraryStyle = struct {
    prefix: []const u8,
    extension: []const u8,
};

/// `{arch}-{os}-{abi}` の OS から、そのターゲットで慣用的な動的ライブラリの
/// 接頭辞と拡張子を決める。未知の OS は推測せず `null` を返し、呼出し側は
/// 明示 `--library-path` を要求する。
fn prebuiltLibraryStyle(target_triple: []const u8) ?PrebuiltLibraryStyle {
    var parts = std.mem.splitScalar(u8, target_triple, '-');
    _ = parts.next() orelse return null;
    const os = parts.next() orelse return null;
    _ = parts.next() orelse return null;
    if (parts.next() != null) return null;

    if (std.mem.eql(u8, os, "windows")) return .{ .prefix = "", .extension = ".dll" };
    if (std.mem.eql(u8, os, "macos") or
        std.mem.eql(u8, os, "ios") or
        std.mem.eql(u8, os, "tvos") or
        std.mem.eql(u8, os, "watchos") or
        std.mem.eql(u8, os, "visionos") or
        std.mem.eql(u8, os, "xros"))
    {
        return .{ .prefix = "lib", .extension = ".dylib" };
    }
    if (std.mem.eql(u8, os, "linux") or
        std.mem.eql(u8, os, "android") or
        std.mem.eql(u8, os, "freebsd") or
        std.mem.eql(u8, os, "netbsd") or
        std.mem.eql(u8, os, "openbsd") or
        std.mem.eql(u8, os, "dragonfly") or
        std.mem.eql(u8, os, "solaris") or
        std.mem.eql(u8, os, "illumos") or
        std.mem.eql(u8, os, "haiku") or
        std.mem.eql(u8, os, "hurd") or
        std.mem.eql(u8, os, "aix"))
    {
        return .{ .prefix = "lib", .extension = ".so" };
    }
    return null;
}

/// `prebuilt_lib_name` はパスではなくファイル名として扱う。パス区切りや
/// 拡張子の不一致は、収録先を推測しない印として `AmbiguousLibrary` にする。
fn validPrebuiltLibraryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\:") != null) return false;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// `[artifacts.native].prebuilt_lib_name` とターゲット triple から、
/// `native/<ライブラリファイル名>` を導出する。名前が `lib` で始まらない
/// Unix 系では `lib` を補い、Windows では補わない。既知の拡張子を持つ名前は
/// そのまま使い、ターゲットと一致しない拡張子は曖昧として拒否する。
fn derivePrebuiltLibraryPath(
    allocator: Allocator,
    target_triple: []const u8,
    name: []const u8,
) ![]const u8 {
    if (!types.validTargetTriple(target_triple)) return error.InvalidTargetTriple;
    if (!validPrebuiltLibraryName(name)) return error.AmbiguousLibrary;
    const style = prebuiltLibraryStyle(target_triple) orelse return error.AmbiguousLibrary;

    var file_name = name;
    const extension = std.fs.path.extension(name);
    if (extension.len > 0) {
        if (!std.ascii.eqlIgnoreCase(extension, style.extension))
            return error.AmbiguousLibrary;
    } else {
        const prefix = if (std.mem.startsWith(u8, name, "lib")) "" else style.prefix;
        file_name = try std.mem.concat(allocator, u8, &.{ prefix, name, style.extension });
    }
    return std.fmt.allocPrint(allocator, "native/{s}", .{file_name});
}

fn optionalBool(table: *const Table, name: []const u8) !?bool {
    const value = optionalField(table, name) orelse return null;
    return switch (value.kind) {
        .boolean => |flag| flag,
        else => error.InvalidFieldType,
    };
}

fn fieldInteger(table: *const Table, name: []const u8) !i64 {
    const value = try field(table, name);
    return switch (value.kind) {
        .integer => |number| number,
        else => error.InvalidFieldType,
    };
}

fn optionalInteger(table: *const Table, name: []const u8) !?i64 {
    const value = optionalField(table, name) orelse return null;
    return switch (value.kind) {
        .integer => |number| number,
        else => error.InvalidFieldType,
    };
}

fn fieldTable(table: *const Table, name: []const u8) !*const Table {
    return asTable(try field(table, name));
}

fn optionalTable(table: *const Table, name: []const u8) !?*const Table {
    const value = optionalField(table, name) orelse return null;
    return asTable(value);
}

fn stringArray(allocator: Allocator, table: *const Table, name: []const u8) ![]const []const u8 {
    const value = try field(table, name);
    const array = try asArray(value);
    const result = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |*item, index| {
        result[index] = item.asString() orelse return error.InvalidFieldType;
    }
    return result;
}

fn optionalStringArray(allocator: Allocator, table: *const Table, name: []const u8) ![]const []const u8 {
    if (optionalField(table, name) == null) return &.{};
    return try stringArray(allocator, table, name);
}

fn parseRuntime(text: []const u8) !types.Runtime {
    return metadata.parseRuntime(text);
}

fn parseBinding(text: []const u8) !types.Binding {
    if (std.mem.eql(u8, text, "scoped")) return .scoped;
    if (std.mem.eql(u8, text, "global")) return .global;
    return error.InvalidFieldType;
}

fn validSubpath(text: []const u8) bool {
    return metadata.validSubpath(text);
}

fn validateInclude(patterns: []const []const u8) !void {
    for (patterns) |pattern| {
        if (pattern.len == 0) return error.InvalidInclude;
        if (pattern[0] == '/' or std.mem.indexOfScalar(u8, pattern, '\\') != null)
            return error.InvalidInclude;
        if (pattern[pattern.len - 1] == '/') return error.InvalidInclude;
        var segments = std.mem.splitScalar(u8, pattern, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0) return error.InvalidInclude;
            if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
                return error.InvalidInclude;
            for (segment) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.InvalidInclude;
            }
        }
    }
}

fn dependencyLessThan(_: void, left: types.Dependency, right: types.Dependency) bool {
    const by_id = std.mem.order(u8, left.id, right.id);
    if (by_id != .eq) return by_id == .lt;
    if (left.runtimes.len != right.runtimes.len) return left.runtimes.len < right.runtimes.len;
    for (left.runtimes, right.runtimes) |left_runtime, right_runtime| {
        if (left_runtime != right_runtime) return metadata.runtimeIndex(left_runtime) < metadata.runtimeIndex(right_runtime);
    }
    return std.mem.order(u8, left.req, right.req) == .lt;
}

fn parseDependencyValue(
    allocator: Allocator,
    id: []const u8,
    value: *const toml.Value,
    runtimes: []const types.Runtime,
) !types.Dependency {
    var dependency = types.Dependency{ .id = id, .req = "", .runtimes = runtimes };
    switch (value.kind) {
        .string => |req| dependency.req = req,
        .table => |*table| {
            dependency.req = try fieldString(table, "version");
            dependency.alias = try optionalString(table, "alias");
            dependency.features = try optionalStringArray(allocator, table, "features");
            if (try optionalBool(table, "default_features")) |flag| {
                dependency.default_features = flag;
            } else if (try optionalBool(table, "default-features")) |flag| {
                dependency.default_features = flag;
            }
            dependency.optional = (try optionalBool(table, "optional")) orelse false;
            dependency.allow_global_commands =
                (try optionalBool(table, "allow_global_commands")) orelse false;
        },
        else => return error.InvalidFieldType,
    }
    if (!types.validId(id)) return error.InvalidDependency;
    if (dependency.req.len == 0) return error.InvalidDependency;
    return dependency;
}

fn collectDependencies(allocator: Allocator, root: *const Table) ![]const types.Dependency {
    var list: std.ArrayList(types.Dependency) = .empty;
    errdefer list.deinit(allocator);
    if (try optionalTable(root, "dependencies")) |dependencies| {
        var iterator = dependencies.iterator();
        while (iterator.next()) |item| {
            try list.append(allocator, try parseDependencyValue(
                allocator,
                item.key_ptr.*,
                item.value_ptr,
                &.{},
            ));
        }
    }
    if (try optionalTable(root, "runtime-dependencies")) |runtime_table| {
        var runtime_iterator = runtime_table.iterator();
        while (runtime_iterator.next()) |item| {
            const runtime = try parseRuntime(item.key_ptr.*);
            const dependency_table = try asTable(item.value_ptr);
            const runtimes = try allocator.alloc(types.Runtime, 1);
            runtimes[0] = runtime;
            var iterator = dependency_table.iterator();
            while (iterator.next()) |dependency_item| {
                try list.append(allocator, try parseDependencyValue(
                    allocator,
                    dependency_item.key_ptr.*,
                    dependency_item.value_ptr,
                    runtimes,
                ));
            }
        }
    }
    const result = try list.toOwnedSlice(allocator);
    std.mem.sort(types.Dependency, result, {}, dependencyLessThan);
    return result;
}

fn collectFeatures(allocator: Allocator, root: *const Table) ![]const metadata.Feature {
    const table = (try optionalTable(root, "features")) orelse return &.{};
    const features = try allocator.alloc(metadata.Feature, table.count());
    var index: usize = 0;
    var iterator = table.iterator();
    while (iterator.next()) |item| : (index += 1) {
        const array = try asArray(item.value_ptr);
        const enables = try allocator.alloc([]const u8, array.items.len);
        for (array.items, 0..) |*value, target_index| {
            enables[target_index] = value.asString() orelse return error.InvalidFieldType;
        }
        features[index] = .{ .name = item.key_ptr.*, .enables = enables };
    }
    std.mem.sort(metadata.Feature, features, {}, struct {
        fn lessThan(_: void, left: metadata.Feature, right: metadata.Feature) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);
    return features;
}

/// マニフェストを pack 用に射影する。`allocator` はモデルの配列を所有し、
/// 文字列は `document` を借用する。
pub fn project(
    allocator: Allocator,
    document: *const toml.Document,
    kind: types.Kind,
    native_overrides: NativeOverrides,
    esm_runtimes_override: ?[]const types.Runtime,
) !Projection {
    const root = &document.root;
    const schema_version = try fieldInteger(root, "schema_version");
    if (schema_version != metadata.schema_version) return error.InvalidManifest;
    const package_table = try fieldTable(root, "package");
    if (package_table.getPtr("name") != null and package_table.getPtr("id") == null)
        return error.InvalidManifest;
    const id = try fieldString(package_table, "id");
    const version = try fieldString(package_table, "version");
    const license = try fieldString(package_table, "license");
    if (!types.validId(id)) return error.InvalidPackageId;
    if (!types.validPublicVersion(version)) return error.InvalidVersion;
    if (!types.validLicense(license)) return error.InvalidLicense;

    const package = metadata.Package{
        .id = id,
        .version = version,
        .license = license,
        .description = try optionalString(package_table, "description"),
        .repository = try optionalString(package_table, "repository"),
        .homepage = try optionalString(package_table, "homepage"),
        .readme = try optionalString(package_table, "readme"),
        .keywords = try optionalStringArray(allocator, package_table, "keywords"),
        .capabilities = try optionalStringArray(allocator, package_table, "capabilities"),
    };

    var engines: []const metadata.Engine = &.{};
    if (try optionalTable(package_table, "engines")) |engines_table| {
        const list = try allocator.alloc(metadata.Engine, engines_table.count());
        var index: usize = 0;
        var iterator = engines_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            list[index] = .{
                .runtime = try parseRuntime(item.key_ptr.*),
                .range = item.value_ptr.asString() orelse return error.InvalidFieldType,
            };
        }
        std.mem.sort(metadata.Engine, list, {}, struct {
            fn lessThan(_: void, left: metadata.Engine, right: metadata.Engine) bool {
                return metadata.runtimeIndex(left.runtime) < metadata.runtimeIndex(right.runtime);
            }
        }.lessThan);
        engines = list;
    }

    const exports_table = (try optionalTable(root, "exports")) orelse return error.MissingField;
    const exports = try allocator.alloc(metadata.Export, exports_table.count());
    {
        var index: usize = 0;
        var iterator = exports_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            if (!validSubpath(item.key_ptr.*)) return error.InvalidExport;
            const export_table = try asTable(item.value_ptr);
            const binding = if (try optionalString(export_table, "binding")) |text|
                try parseBinding(text)
            else
                types.Binding.scoped;
            exports[index] = .{
                .subpath = item.key_ptr.*,
                .entry = try fieldString(export_table, "entry"),
                .binding = binding,
            };
        }
        std.mem.sort(metadata.Export, exports, {}, struct {
            fn lessThan(_: void, left: metadata.Export, right: metadata.Export) bool {
                return std.mem.order(u8, left.subpath, right.subpath) == .lt;
            }
        }.lessThan);
    }

    const artifacts_table = (try optionalTable(root, "artifacts")) orelse return error.MissingField;
    var universal_include: []const []const u8 = &.{};
    if (try optionalTable(artifacts_table, "universal")) |universal| {
        universal_include = try optionalStringArray(allocator, universal, "include");
        try validateInclude(universal_include);
    }
    var esm_include: []const []const u8 = &.{};
    var esm_entry: ?[]const u8 = null;
    var esm_runtimes_buffer: []types.Runtime = &.{};
    if (try optionalTable(artifacts_table, "esm")) |esm| {
        esm_include = try optionalStringArray(allocator, esm, "include");
        try validateInclude(esm_include);
        esm_entry = try optionalString(esm, "entry");
        const runtime_names = try optionalStringArray(allocator, esm, "runtimes");
        if (runtime_names.len > 0) {
            esm_runtimes_buffer = try allocator.alloc(types.Runtime, runtime_names.len);
            for (runtime_names, 0..) |name, index| esm_runtimes_buffer[index] = try parseRuntime(name);
        }
    }
    var source_include: []const []const u8 = &.{};
    var manifest_abi: ?u32 = null;
    var prebuilt_lib_name: ?[]const u8 = null;
    if (try optionalTable(artifacts_table, "native")) |native| {
        source_include = try optionalStringArray(allocator, native, "source_include");
        try validateInclude(source_include);
        if (try optionalInteger(native, "abi_version")) |abi| {
            if (abi < 1 or abi > std.math.maxInt(u32)) return error.InvalidFieldType;
            manifest_abi = @intCast(abi);
        }
        if (try optionalString(native, "prebuilt_lib_name")) |name| {
            if (name.len == 0) return error.InvalidFieldType;
            prebuilt_lib_name = name;
        }
    }

    var artifact = metadata.Artifact{
        .kind = kind,
        .runtimes = &.{},
        .native = null,
        .entries = &.{},
    };
    switch (kind) {
        .universal => {
            if (universal_include.len == 0) return error.InvalidInclude;
            artifact.runtimes = try allocator.dupe(types.Runtime, &.{ .lnako, .cnako, .wnako });
        },
        .esm => {
            if (esm_entry == null) return error.MissingField;
            if (!types.validPath(esm_entry.?)) return error.InvalidExport;
            const runtimes: []const types.Runtime = esm_runtimes_override orelse esm_runtimes_buffer;
            if (runtimes.len == 0) return error.InvalidRuntime;
            const sorted_runtimes = try allocator.dupe(types.Runtime, runtimes);
            std.mem.sort(types.Runtime, sorted_runtimes, {}, struct {
                fn lessThan(_: void, left: types.Runtime, right: types.Runtime) bool {
                    return metadata.runtimeIndex(left) < metadata.runtimeIndex(right);
                }
            }.lessThan);
            artifact.runtimes = sorted_runtimes;
            const entries = try allocator.alloc(metadata.Entry, 1);
            entries[0] = .{ .subpath = ".", .path = esm_entry.? };
            artifact.entries = entries;
        },
        .@"native-source" => {
            artifact.runtimes = try allocator.dupe(types.Runtime, &.{.lnako});
            const abi = native_overrides.abi_version orelse manifest_abi orelse
                return error.MissingField;
            artifact.native = .{ .abi_version = abi };
        },
        .@"native-prebuilt" => {
            artifact.runtimes = try allocator.dupe(types.Runtime, &.{.lnako});
            const target_triple = native_overrides.target_triple orelse return error.MissingField;
            const library_path = native_overrides.library_path orelse blk: {
                const name = prebuilt_lib_name orelse return error.MissingLibraryName;
                break :blk try derivePrebuiltLibraryPath(allocator, target_triple, name);
            };
            artifact.native = .{
                .target_triple = target_triple,
                .abi_version = native_overrides.abi_version orelse manifest_abi orelse
                    return error.MissingField,
                .glibc_min = native_overrides.glibc_min,
                .library_path = library_path,
            };
            // 共通 exports はそのまま残し、既定入口 "." だけをこの
            // アーティファクト固有のライブラリへ結ぶ。クライアントは
            // 記録のないサブパスに共通 entry を使う（§3.3）。
            for (exports) |export_entry| {
                if (!std.mem.eql(u8, export_entry.subpath, ".")) continue;
                const entries = try allocator.alloc(metadata.Entry, 1);
                entries[0] = .{ .subpath = ".", .path = library_path };
                artifact.entries = entries;
                break;
            }
        },
    }

    const model = metadata.Model{
        .package = package,
        .artifact = artifact,
        .engines = engines,
        .exports = exports,
        .features = try collectFeatures(allocator, root),
        .dependencies = try collectDependencies(allocator, root),
    };
    try metadata.validateModel(allocator, model);

    return .{
        .model = model,
        .universal_include = universal_include,
        .esm_include = esm_include,
        .esm_entry = esm_entry,
        .source_include = source_include,
    };
}

/// native-source の種別固有入口（`artifact.entries`）を、アーカイブ内の
/// 一意なビルド入力へ投影する。共通の `exports`・`engines`・`dependencies`
/// は変更せず、選択したサブパスの収録先だけを `path` に差し替える。
///
/// `path` は `source_include` に一致した実在の `build.zig` を呼出し側が
/// 選んで渡す。複数候補の解決はここでは行わない（推測しない）。
pub fn projectSourceBuildEntry(
    allocator: Allocator,
    projection: *Projection,
    path: []const u8,
) !void {
    if (projection.model.artifact.kind != .@"native-source") return error.InvalidKind;
    if (!types.validPath(path)) return error.InvalidExport;
    if (!std.mem.eql(u8, std.fs.path.basename(path), source_build_file))
        return error.InvalidExport;
    const entries = try allocator.alloc(metadata.Entry, projection.model.exports.len);
    for (projection.model.exports, 0..) |export_entry, index| {
        entries[index] = .{ .subpath = export_entry.subpath, .path = path };
    }
    projection.model.artifact.entries = entries;
}
