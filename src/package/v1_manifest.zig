//! `nako.toml`（パッケージ形式 v1、仕様 §2）の解析と静的検証。
//!
//! 旧 manifest は読み替えない。識別できる旧形式は `error.LegacyManifest`
//! で拒否し、新形式で再作成するよう案内する（Q12）。
//!
//! 返した `Manifest` は TOML のアリーナと入力 `source` のスライスを参照する。
//! `source` は `Manifest.deinit()` まで生存させること。後続の pack は
//! `manifest.doc.root` をそのまま参照できる。

const std = @import("std");
const toml = @import("toml.zig");
const v1 = @import("v1_types.zig");
const semver = @import("semver.zig");

pub const Runtime = v1.Runtime;
pub const Kind = v1.Kind;
pub const Binding = v1.Binding;
pub const Capability = v1.Capability;
pub const Dependency = v1.Dependency;
pub const Artifact = v1.Artifact;

/// ローカル実行用と配布用（pack）で必須欄が異なる。
pub const Mode = enum { local, pack };

pub const ParseError = error{
    OutOfMemory,
    InvalidToml,
    InvalidUtf8,
    LegacyManifest,
    MissingSchemaVersion,
    SchemaVersionNotInteger,
    UnsupportedSchemaVersion,
    UnknownTopLevelKey,
    MissingPackage,
    MissingPackageId,
    MissingPackageVersion,
    MissingPackageLicense,
    InvalidType,
    InvalidPackageId,
    InvalidVersion,
    InvalidLicense,
    InvalidPath,
    InvalidRuntime,
    InvalidCapability,
    InvalidExport,
    InvalidBinding,
    InvalidRange,
    InvalidDependency,
    InvalidAlias,
    InvalidFeatureName,
    InvalidFeatureCycle,
    MissingArtifactField,
    InvalidArtifact,
    InvalidAbiVersion,
    InvalidProfile,
};

pub const Engine = struct {
    runtime: Runtime,
    req: []const u8,
};

pub const ExportEntry = struct {
    subpath: []const u8,
    entry: []const u8,
    binding: Binding = .scoped,
};

pub const Feature = struct {
    name: []const u8,
    enables: []const []const u8,
};

pub const UniversalArtifact = struct {
    include: []const []const u8,
};

pub const EsmArtifact = struct {
    runtimes: []const Runtime,
    entry: []const u8,
    include: []const []const u8,
};

pub const NativeArtifact = struct {
    abi_version: u32,
    source_include: []const []const u8 = &.{},
    prebuilt_lib_name: ?[]const u8 = null,
};

pub const ArtifactSet = struct {
    universal: ?UniversalArtifact = null,
    esm: ?EsmArtifact = null,
    native: ?NativeArtifact = null,
};

pub const Package = struct {
    id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    readme: ?[]const u8 = null,
    license: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    capabilities: []const Capability = &.{},
    engines: []const Engine = &.{},
};

pub const RuntimeDependencies = struct {
    runtime: Runtime,
    dependencies: []const Dependency,
};

pub const Profile = struct {
    name: []const u8,
    runtime: Runtime,
};

pub const Manifest = struct {
    doc: toml.Document,
    mode: Mode,
    package: Package = .{},
    exports: []const ExportEntry = &.{},
    features: []const Feature = &.{},
    artifacts: ArtifactSet = .{},
    dependencies: []const Dependency = &.{},
    runtime_dependencies: []const RuntimeDependencies = &.{},
    dev_dependencies: []const Dependency = &.{},
    profiles: []const Profile = &.{},

    pub fn deinit(self: *Manifest) void {
        self.doc.deinit();
        self.* = undefined;
    }

    /// 既定入口 `.` を含む公開サブパスの定義を返す。
    pub fn findExport(self: *const Manifest, subpath: []const u8) ?*const ExportEntry {
        for (self.exports) |*entry| {
            if (std.mem.eql(u8, entry.subpath, subpath)) return entry;
        }
        return null;
    }

    /// 完全修飾 Package ID の直接依存を返す。
    pub fn findDependency(self: *const Manifest, id: []const u8) ?*const Dependency {
        return findDependencyIn(self.dependencies, id);
    }

    /// ランタイム固有の直接依存を返す。未宣言なら空。
    pub fn runtimeDependencies(self: *const Manifest, runtime: Runtime) []const Dependency {
        for (self.runtime_dependencies) |item| {
            if (item.runtime == runtime) return item.dependencies;
        }
        return &.{};
    }

    pub fn findRuntimeDependency(self: *const Manifest, runtime: Runtime, id: []const u8) ?*const Dependency {
        return findDependencyIn(self.runtimeDependencies(runtime), id);
    }

    pub fn findDevDependency(self: *const Manifest, id: []const u8) ?*const Dependency {
        return findDependencyIn(self.dev_dependencies, id);
    }

    pub fn findFeature(self: *const Manifest, name: []const u8) ?*const Feature {
        for (self.features) |*feature| {
            if (std.mem.eql(u8, feature.name, name)) return feature;
        }
        return null;
    }

    pub fn findProfile(self: *const Manifest, name: []const u8) ?*const Profile {
        for (self.profiles) |*profile| {
            if (std.mem.eql(u8, profile.name, name)) return profile;
        }
        return null;
    }

    pub fn findEngine(self: *const Manifest, runtime: Runtime) ?Engine {
        for (self.package.engines) |engine| {
            if (engine.runtime == runtime) return engine;
        }
        return null;
    }

    /// `binding = global` の入口が一つでもあるか（仕様 §2）。
    pub fn exportsGlobalCommands(self: *const Manifest) bool {
        for (self.exports) |entry| {
            if (entry.binding == .global) return true;
        }
        return false;
    }

    /// pack と公開に必要な `id`・`version`・`license` がそろっているか。
    pub fn hasPackageIdentity(self: *const Manifest) bool {
        return self.package.id != null and self.package.version != null and self.package.license != null;
    }
};

fn findDependencyIn(list: []const Dependency, id: []const u8) ?*const Dependency {
    for (list) |*dependency| {
        if (std.mem.eql(u8, dependency.id, id)) return dependency;
    }
    return null;
}

/// 依存のローカル解決名（§6.1）。alias がなければ ID の name 部分。
pub fn localName(dependency: *const Dependency) []const u8 {
    if (dependency.alias) |alias| return alias;
    const slash = std.mem.indexOfScalar(u8, dependency.id, '/') orelse return dependency.id;
    return dependency.id[slash + 1 ..];
}

pub const ProfileChoice = struct {
    name: []const u8,
    runtime: Runtime,
};

pub const DependencyError = error{
    OutOfMemory,
    UnknownProfile,
    UnknownFeature,
    DuplicateDependency,
};

/// `--profile` 指定と `[profiles]` から実行 profile を選ぶ（§6.1）。
/// 指定が無い場合は `default`、無ければ唯一の profile を使う。複数あって
/// 既定が無い場合は `UnknownProfile`。
pub fn selectProfile(self: *const Manifest, requested: ?[]const u8) error{UnknownProfile}!ProfileChoice {
    if (requested) |name| {
        const profile = self.findProfile(name) orelse return error.UnknownProfile;
        return .{ .name = profile.name, .runtime = profile.runtime };
    }
    if (self.profiles.len == 0) return .{ .name = "default", .runtime = .lnako };
    if (self.findProfile("default")) |profile| {
        return .{ .name = profile.name, .runtime = profile.runtime };
    }
    if (self.profiles.len == 1) {
        return .{ .name = self.profiles[0].name, .runtime = self.profiles[0].runtime };
    }
    return error.UnknownProfile;
}

/// 現在の manifest・選択 runtime・feature 選択から、ルートの解決表に載る
/// 直接依存を返す（§6.1）。`dependencies` と選択 runtime の
/// `runtime-dependencies` だけを使い、推移依存は含めない。
/// 返すスライスと内部で使う名前は `allocator` が所有するため、呼出し側は
/// arena を渡すこと。
pub fn effectiveRootDependencies(
    self: *const Manifest,
    allocator: std.mem.Allocator,
    runtime: Runtime,
    requested_features: []const []const u8,
    no_default_features: bool,
) DependencyError![]const Dependency {
    var active = std.StringHashMap(void).init(allocator);
    defer active.deinit();
    if (!no_default_features) try activateRootFeature(allocator, self, "default", &active, 0);
    for (requested_features) |feature| {
        try activateRootFeature(allocator, self, feature, &active, 0);
    }

    var list: std.ArrayList(Dependency) = .empty;
    for (self.dependencies) |dependency| {
        try appendRootDependency(allocator, &list, dependency, runtime, &active);
    }
    for (self.runtimeDependencies(runtime)) |dependency| {
        try appendRootDependency(allocator, &list, dependency, runtime, &active);
    }
    std.mem.sort(Dependency, list.items, {}, struct {
        fn lessThan(_: void, a: Dependency, b: Dependency) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(allocator);
}

fn activateRootFeature(
    allocator: std.mem.Allocator,
    manifest: *const Manifest,
    name: []const u8,
    active: *std.StringHashMap(void),
    depth: usize,
) DependencyError!void {
    if (depth > 64) return error.UnknownFeature;
    if (active.contains(name)) return;
    try active.put(try allocator.dupe(u8, name), {});
    const feature = manifest.findFeature(name) orelse {
        // `default` は feature 表に無くても既定として扱う（Cargo と同じ）。
        if (std.mem.eql(u8, name, "default")) return;
        return error.UnknownFeature;
    };
    for (feature.enables) |enabled| {
        // `dep:<name>` は optional 依存を有効にするマーカーで、feature 名
        // ではない。`dep:<name>/<feature>` も依存側の feature 指定として
        // ルート feature の再帰には含めない。
        if (std.mem.startsWith(u8, enabled, "dep:")) {
            if (!active.contains(enabled)) try active.put(try allocator.dupe(u8, enabled), {});
            continue;
        }
        if (std.mem.indexOfScalar(u8, enabled, '/') != null) continue;
        try activateRootFeature(allocator, manifest, enabled, active, depth + 1);
    }
}

fn appendRootDependency(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Dependency),
    dependency: Dependency,
    runtime: Runtime,
    active: *std.StringHashMap(void),
) DependencyError!void {
    if (dependency.optional) {
        const local = localName(&dependency);
        var enabled = active.contains(local);
        if (!enabled) {
            const dep_key = try std.fmt.allocPrint(allocator, "dep:{s}", .{local});
            enabled = active.contains(dep_key);
        }
        if (!enabled) return;
    }
    for (list.items) |existing| {
        if (!std.mem.eql(u8, existing.id, dependency.id)) continue;
        if (dependencyEqual(existing, dependency)) return;
        return error.DuplicateDependency;
    }
    // runtime-dependencies の項目は宣言 runtime で絞り込まれている。
    if (dependency.runtimes.len > 0) {
        var applies = false;
        for (dependency.runtimes) |candidate| {
            if (candidate == runtime) applies = true;
        }
        if (!applies) return;
    }
    try list.append(allocator, dependency);
}

fn dependencyEqual(a: Dependency, b: Dependency) bool {
    if (!std.mem.eql(u8, a.id, b.id) or !std.mem.eql(u8, a.req, b.req)) return false;
    if (!optionalStringEqual(a.alias, b.alias)) return false;
    if (a.features.len != b.features.len) return false;
    for (a.features, b.features) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    if (a.default_features != b.default_features or a.optional != b.optional) return false;
    if (a.allow_global_commands != b.allow_global_commands) return false;
    if (a.runtimes.len != b.runtimes.len) return false;
    for (a.runtimes, b.runtimes) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// `nako.toml` を解析し、型付きの `Manifest` を返す。
pub fn parse(allocator: std.mem.Allocator, source: []const u8, mode: Mode) ParseError!Manifest {
    const parsed = toml.parse(allocator, source) catch return error.OutOfMemory;
    var doc = switch (parsed) {
        .ok => |document| document,
        .err => |syntax| return if (std.mem.indexOf(u8, syntax.message, "UTF-8") != null)
            error.InvalidUtf8
        else
            error.InvalidToml,
    };
    var doc_owned = true;
    errdefer if (doc_owned) doc.deinit();

    if (looksLegacy(&doc.root)) return error.LegacyManifest;

    const schema_value = doc.root.getPtr("schema_version") orelse return error.MissingSchemaVersion;
    switch (schema_value.kind) {
        .integer => |value| {
            if (value != 1) return error.UnsupportedSchemaVersion;
        },
        .float => return error.SchemaVersionNotInteger,
        else => return error.InvalidType,
    }

    if (hasUnknownTopLevelKey(&doc.root)) return error.UnknownTopLevelKey;

    const package_table_value = doc.root.getPtr("package") orelse return error.MissingPackage;
    const package_table = package_table_value.asTable() orelse return error.InvalidType;

    // doc のアリーナ状態を Manifest へ移してから派生データを確保する。
    // 先に doc を複製してから別のアリーナ状態で確保すると、deinit が
    // 複製後に確保した領域を解放できない。
    var manifest = Manifest{ .doc = doc, .mode = mode };
    doc_owned = false;
    errdefer manifest.deinit();
    const arena = manifest.doc.allocator();
    manifest.package = try parsePackage(arena, package_table, mode);
    manifest.exports = try parseExports(arena, &manifest.doc.root);
    manifest.features = try parseFeatures(arena, &manifest.doc.root);
    manifest.artifacts = try parseArtifacts(arena, &manifest.doc.root);
    manifest.dependencies = try parseDependencySection(arena, &manifest.doc.root, "dependencies", null);
    manifest.runtime_dependencies = try parseRuntimeDependencies(arena, &manifest.doc.root);
    manifest.dev_dependencies = try parseDependencySection(arena, &manifest.doc.root, "dev-dependencies", null);
    manifest.profiles = try parseProfiles(arena, &manifest.doc.root);
    try validateFeatureCycles(arena, manifest.features);
    return manifest;
}

const top_level_keys = [_][]const u8{
    "schema_version",
    "package",
    "exports",
    "features",
    "artifacts",
    "dependencies",
    "runtime-dependencies",
    "dev-dependencies",
    "profiles",
};

fn hasUnknownTopLevelKey(root: *const std.StringHashMapUnmanaged(toml.Value)) bool {
    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        if (!v1.containsString(&top_level_keys, entry.key_ptr.*)) return true;
    }
    return false;
}

/// 旧形式の識別。`package.name`・`schema-version`・`schemaVersion` は
/// 新形式に存在せず、暗黙変換しない（Q12）。
fn looksLegacy(root: *const std.StringHashMapUnmanaged(toml.Value)) bool {
    if (root.getPtr("schema-version") != null or root.getPtr("schemaVersion") != null) return true;
    const package_value = root.getPtr("package") orelse return false;
    const table = package_value.asTable() orelse return false;
    if (table.getPtr("schema-version") != null or table.getPtr("schemaVersion") != null) return true;
    return table.getPtr("name") != null;
}

fn parsePackage(arena: std.mem.Allocator, table: *std.StringHashMapUnmanaged(toml.Value), mode: Mode) ParseError!Package {
    var package = Package{};

    if (table.getPtr("id")) |value| {
        const text = try expectString(value);
        if (!v1.validId(text)) return error.InvalidPackageId;
        package.id = text;
    }
    if (table.getPtr("version")) |value| {
        const text = try expectString(value);
        if (!v1.validPublicVersion(text)) return error.InvalidVersion;
        package.version = text;
    }
    if (table.getPtr("license")) |value| {
        const text = try expectString(value);
        if (!v1.validLicense(text)) return error.InvalidLicense;
        package.license = text;
    }
    if (table.getPtr("description")) |value| package.description = try expectString(value);
    if (table.getPtr("repository")) |value| package.repository = try expectString(value);
    if (table.getPtr("homepage")) |value| package.homepage = try expectString(value);
    if (table.getPtr("readme")) |value| {
        const text = try expectString(value);
        if (!v1.validPath(text)) return error.InvalidPath;
        package.readme = text;
    }
    if (table.getPtr("keywords")) |value| package.keywords = try parseStringArray(arena, value);
    if (table.getPtr("capabilities")) |value| package.capabilities = try parseCapabilities(arena, value);
    if (table.getPtr("engines")) |value| package.engines = try parseEngines(arena, value);

    if (mode == .pack) {
        if (package.id == null) return error.MissingPackageId;
        if (package.version == null) return error.MissingPackageVersion;
        if (package.license == null) return error.MissingPackageLicense;
    }
    return package;
}

fn parseCapabilities(arena: std.mem.Allocator, value: *const toml.Value) ParseError![]const Capability {
    const array = value.asArray() orelse return error.InvalidType;
    var list: std.ArrayList(Capability) = .empty;
    for (array.items) |item| {
        const text = try expectString(&item);
        const capability = v1.parseCapability(text) orelse return error.InvalidCapability;
        try list.append(arena, capability);
    }
    return list.toOwnedSlice(arena);
}

fn parseEngines(arena: std.mem.Allocator, value: *const toml.Value) ParseError![]const Engine {
    const table = value.asTable() orelse return error.InvalidType;
    var list: std.ArrayList(Engine) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const runtime = v1.parseRuntime(entry.key_ptr.*) orelse return error.InvalidRuntime;
        const req = try expectString(entry.value_ptr);
        if (!v1.validRange(arena, req)) return error.InvalidRange;
        try list.append(arena, .{ .runtime = runtime, .req = req });
    }
    std.mem.sort(Engine, list.items, {}, struct {
        fn lessThan(_: void, a: Engine, b: Engine) bool {
            return @backingInt(a.runtime) < @backingInt(b.runtime);
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

fn parseExports(arena: std.mem.Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const ExportEntry {
    const value = root.getPtr("exports") orelse return &.{};
    const table = value.asTable() orelse return error.InvalidType;
    var list: std.ArrayList(ExportEntry) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const subpath = entry.key_ptr.*;
        if (!validSubpath(subpath)) return error.InvalidExport;
        const item = entry.value_ptr.asTable() orelse return error.InvalidType;
        const entry_value = item.getPtr("entry") orelse return error.InvalidExport;
        const path = try expectString(entry_value);
        if (!v1.validPath(path)) return error.InvalidPath;
        var binding: Binding = .scoped;
        if (item.getPtr("binding")) |binding_value| {
            const text = try expectString(binding_value);
            binding = v1.parseBinding(text) orelse return error.InvalidBinding;
        }
        try list.append(arena, .{ .subpath = subpath, .entry = path, .binding = binding });
    }
    std.mem.sort(ExportEntry, list.items, {}, struct {
        fn lessThan(_: void, a: ExportEntry, b: ExportEntry) bool {
            return std.mem.order(u8, a.subpath, b.subpath) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

/// `.` または `./` で始まる公開サブパス。
pub fn validSubpath(subpath: []const u8) bool {
    if (std.mem.eql(u8, subpath, ".")) return true;
    if (!std.mem.startsWith(u8, subpath, "./")) return false;
    return v1.validPath(subpath[2..]);
}

fn parseFeatures(arena: std.mem.Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const Feature {
    const value = root.getPtr("features") orelse return &.{};
    const table = value.asTable() orelse return error.InvalidType;
    var list: std.ArrayList(Feature) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!v1.validFeatureName(name)) return error.InvalidFeatureName;
        const enables = try parseFeatureList(arena, entry.value_ptr);
        try list.append(arena, .{ .name = name, .enables = enables });
    }
    std.mem.sort(Feature, list.items, {}, struct {
        fn lessThan(_: void, a: Feature, b: Feature) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

fn parseFeatureList(arena: std.mem.Allocator, value: *const toml.Value) ParseError![]const []const u8 {
    const array = value.asArray() orelse return error.InvalidType;
    var list: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = try expectString(&item);
        if (!v1.validFeatureName(text)) return error.InvalidFeatureName;
        try list.append(arena, text);
    }
    return list.toOwnedSlice(arena);
}

fn validateFeatureCycles(arena: std.mem.Allocator, features: []const Feature) ParseError!void {
    if (features.len == 0) return;
    var index_by_name: std.StringHashMapUnmanaged(usize) = .empty;
    for (features, 0..) |feature, index| {
        try index_by_name.put(arena, feature.name, index);
    }
    const state = try arena.alloc(u8, features.len);
    @memset(state, 0);
    for (features, 0..) |_, index| {
        if (state[index] == 0) try visitFeature(features, &index_by_name, state, index);
    }
}

fn visitFeature(
    features: []const Feature,
    index_by_name: *const std.StringHashMapUnmanaged(usize),
    state: []u8,
    index: usize,
) ParseError!void {
    state[index] = 1; // visiting
    for (features[index].enables) |name| {
        const target = index_by_name.get(name) orelse continue;
        if (state[target] == 1) return error.InvalidFeatureCycle;
        if (state[target] == 0) try visitFeature(features, index_by_name, state, target);
    }
    state[index] = 2; // done
}

fn parseArtifacts(arena: std.mem.Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError!ArtifactSet {
    const value = root.getPtr("artifacts") orelse return .{};
    const table = value.asTable() orelse return error.InvalidType;
    var artifacts = ArtifactSet{};
    if (table.getPtr("universal")) |universal_value| {
        const universal = universal_value.asTable() orelse return error.InvalidType;
        const include_value = universal.getPtr("include") orelse return error.MissingArtifactField;
        artifacts.universal = .{ .include = try parseGlobArray(arena, include_value) };
    }
    if (table.getPtr("esm")) |esm_value| {
        const esm = esm_value.asTable() orelse return error.InvalidType;
        const runtimes_value = esm.getPtr("runtimes") orelse return error.MissingArtifactField;
        const runtimes = try parseRuntimes(arena, runtimes_value, false);
        const entry_value = esm.getPtr("entry") orelse return error.MissingArtifactField;
        const entry_text = try expectString(entry_value);
        if (!v1.validPath(entry_text)) return error.InvalidPath;
        const include_value = esm.getPtr("include") orelse return error.MissingArtifactField;
        artifacts.esm = .{
            .runtimes = runtimes,
            .entry = entry_text,
            .include = try parseGlobArray(arena, include_value),
        };
    }
    if (table.getPtr("native")) |native_value| {
        const native = native_value.asTable() orelse return error.InvalidType;
        const abi_value = native.getPtr("abi_version") orelse return error.MissingArtifactField;
        const abi_version = try parseAbiVersion(abi_value);
        var source_include: []const []const u8 = &.{};
        if (native.getPtr("source_include")) |include_value| {
            source_include = try parseGlobArray(arena, include_value);
        }
        var prebuilt_lib_name: ?[]const u8 = null;
        if (native.getPtr("prebuilt_lib_name")) |name_value| {
            const text = try expectString(name_value);
            if (text.len == 0) return error.InvalidArtifact;
            prebuilt_lib_name = text;
        }
        artifacts.native = .{
            .abi_version = abi_version,
            .source_include = source_include,
            .prebuilt_lib_name = prebuilt_lib_name,
        };
    }
    return artifacts;
}

fn parseRuntimes(arena: std.mem.Allocator, value: *const toml.Value, allow_lnako: bool) ParseError![]const Runtime {
    const array = value.asArray() orelse return error.InvalidType;
    if (array.items.len == 0) return error.InvalidArtifact;
    var list: std.ArrayList(Runtime) = .empty;
    for (array.items) |item| {
        const text = try expectString(&item);
        const runtime = v1.parseRuntime(text) orelse return error.InvalidRuntime;
        if (!allow_lnako and runtime == .lnako) return error.InvalidRuntime;
        for (list.items) |existing| {
            if (existing == runtime) return error.InvalidArtifact;
        }
        try list.append(arena, runtime);
    }
    return list.toOwnedSlice(arena);
}

fn parseAbiVersion(value: *const toml.Value) ParseError!u32 {
    return switch (value.kind) {
        .integer => |number| blk: {
            if (number < 1 or number > std.math.maxInt(u32)) return error.InvalidAbiVersion;
            break :blk @intCast(number);
        },
        else => error.InvalidType,
    };
}

fn parseGlobArray(arena: std.mem.Allocator, value: *const toml.Value) ParseError![]const []const u8 {
    const array = value.asArray() orelse return error.InvalidType;
    var list: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = try expectString(&item);
        if (!v1.validGlobPattern(text)) return error.InvalidPath;
        try list.append(arena, text);
    }
    return list.toOwnedSlice(arena);
}

fn parseDependencySection(
    arena: std.mem.Allocator,
    root: *const std.StringHashMapUnmanaged(toml.Value),
    key: []const u8,
    runtime_override: ?Runtime,
) ParseError![]const Dependency {
    const value = root.getPtr(key) orelse return &.{};
    const table = value.asTable() orelse return error.InvalidType;
    return parseDependencies(arena, table, runtime_override);
}

fn parseDependencies(
    arena: std.mem.Allocator,
    table: *std.StringHashMapUnmanaged(toml.Value),
    runtime_override: ?Runtime,
) ParseError![]const Dependency {
    var list: std.ArrayList(Dependency) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const id = entry.key_ptr.*;
        if (!v1.validId(id)) return error.InvalidDependency;
        var dependency = Dependency{ .id = id, .req = "" };
        switch (entry.value_ptr.kind) {
            .string => |req| dependency.req = req,
            .table => {
                const dependency_table = entry.value_ptr.asTable().?;
                const version_value = dependency_table.getPtr("version") orelse return error.InvalidDependency;
                dependency.req = try expectString(version_value);
                if (dependency_table.getPtr("alias")) |alias_value| {
                    const alias = try expectString(alias_value);
                    if (!v1.validAlias(alias)) return error.InvalidAlias;
                    dependency.alias = alias;
                }
                if (dependency_table.getPtr("features")) |features_value| {
                    dependency.features = try parseFeatureList(arena, features_value);
                }
                if (dependency_table.getPtr("default_features")) |flag| {
                    dependency.default_features = try expectBool(flag);
                }
                if (dependency_table.getPtr("optional")) |flag| {
                    dependency.optional = try expectBool(flag);
                }
                if (dependency_table.getPtr("allow_global_commands")) |flag| {
                    dependency.allow_global_commands = try expectBool(flag);
                }
            },
            else => return error.InvalidType,
        }
        if (!v1.validRange(arena, dependency.req)) return error.InvalidRange;
        if (runtime_override) |runtime| {
            dependency.runtimes = try arena.dupe(Runtime, &.{runtime});
        }
        try list.append(arena, dependency);
    }
    std.mem.sort(Dependency, list.items, {}, struct {
        fn lessThan(_: void, a: Dependency, b: Dependency) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

fn parseRuntimeDependencies(arena: std.mem.Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const RuntimeDependencies {
    const value = root.getPtr("runtime-dependencies") orelse return &.{};
    const table = value.asTable() orelse return error.InvalidType;
    var list: std.ArrayList(RuntimeDependencies) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const runtime = v1.parseRuntime(entry.key_ptr.*) orelse return error.InvalidRuntime;
        const dependencies_table = entry.value_ptr.asTable() orelse return error.InvalidType;
        const dependencies = try parseDependencies(arena, dependencies_table, runtime);
        try list.append(arena, .{ .runtime = runtime, .dependencies = dependencies });
    }
    std.mem.sort(RuntimeDependencies, list.items, {}, struct {
        fn lessThan(_: void, a: RuntimeDependencies, b: RuntimeDependencies) bool {
            return @backingInt(a.runtime) < @backingInt(b.runtime);
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

fn parseProfiles(arena: std.mem.Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const Profile {
    const value = root.getPtr("profiles") orelse return &.{};
    const table = value.asTable() orelse return error.InvalidType;
    var list: std.ArrayList(Profile) = .empty;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!v1.validLocalName(name)) return error.InvalidProfile;
        const profile_table = entry.value_ptr.asTable() orelse return error.InvalidType;
        const runtime_value = profile_table.getPtr("runtime") orelse return error.InvalidProfile;
        const runtime_text = try expectString(runtime_value);
        const runtime = v1.parseRuntime(runtime_text) orelse return error.InvalidRuntime;
        try list.append(arena, .{ .name = name, .runtime = runtime });
    }
    std.mem.sort(Profile, list.items, {}, struct {
        fn lessThan(_: void, a: Profile, b: Profile) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(arena);
}

fn expectString(value: *const toml.Value) ParseError![]const u8 {
    return value.asString() orelse error.InvalidType;
}

fn expectBool(value: *const toml.Value) ParseError!bool {
    return switch (value.kind) {
        .boolean => |flag| flag,
        else => error.InvalidType,
    };
}

fn parseStringArray(arena: std.mem.Allocator, value: *const toml.Value) ParseError![]const []const u8 {
    const array = value.asArray() orelse return error.InvalidType;
    var list: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        try list.append(arena, try expectString(&item));
    }
    return list.toOwnedSlice(arena);
}

/// CLI がそのまま表示できる安定した診断文。未知の error は null。
pub fn diagnostic(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidToml => "invalid TOML syntax",
        error.InvalidUtf8 => "nako.toml is not valid UTF-8",
        error.LegacyManifest => "legacy nako.toml is not supported; recreate it with schema_version = 1 and package.id/version/license (automatic conversion is not performed)",
        error.MissingSchemaVersion => "missing top-level schema_version = 1",
        error.SchemaVersionNotInteger => "schema_version must be the TOML integer 1 (1.0 is a float)",
        error.UnsupportedSchemaVersion => "unsupported schema_version (expected 1)",
        error.UnknownTopLevelKey => "unknown top-level key in nako.toml",
        error.MissingPackage => "missing required [package] table",
        error.MissingPackageId => "pack requires package.id",
        error.MissingPackageVersion => "pack requires package.version",
        error.MissingPackageLicense => "pack requires package.license",
        error.InvalidType => "invalid TOML type for a manifest field",
        error.InvalidPackageId => "package.id must be @{scope}/{name}",
        error.InvalidVersion => "package.version must be a public SemVer 2.0.0 version without build metadata",
        error.InvalidLicense => "package.license must be a valid SPDX expression (License List 3.27.0)",
        error.InvalidPath => "invalid relative path",
        error.InvalidRuntime => "unknown runtime (expected lnako, cnako, or wnako)",
        error.InvalidCapability => "unknown capability",
        error.InvalidExport => "invalid exports entry (expected \".\" or \"./subpath\" with entry)",
        error.InvalidBinding => "binding must be scoped or global",
        error.InvalidRange => "invalid node-semver range",
        error.InvalidDependency => "invalid dependency ID or missing version",
        error.InvalidAlias => "invalid dependency alias",
        error.InvalidFeatureName => "invalid feature name",
        error.InvalidFeatureCycle => "feature definitions contain a cycle",
        error.MissingArtifactField => "missing required artifact field",
        error.InvalidArtifact => "invalid artifact declaration",
        error.InvalidAbiVersion => "abi_version must be a positive 32-bit integer",
        error.InvalidProfile => "profile requires a valid runtime",
        else => null,
    };
}

test {
    _ = @import("v1_manifest_test.zig");
}
