//! `NAKO-PKG/METADATA.toml` のモデル・決定的シリアライズ・厳格な解析。
//!
//! 仕様 §3.3 の構造と、種別ごとの `artifact.native` の必須条件を検査する。
//! 解釈は TOML の値をそのまま写し、暗黙の変換（`1.0`→`1`、旧キーの読み替え、
//! 欠落項目の補完）は行わない。`binding` の省略だけは仕様どおり `scoped` と
//! してモデルへ反映する。

const std = @import("std");
const toml = @import("toml.zig");
const toml_write = @import("toml_write.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;

pub const Error = error{
    OutOfMemory,
    InvalidMetadata,
    LegacySchema,
    InvalidSchemaVersion,
    MissingField,
    InvalidFieldType,
    InvalidPackageId,
    InvalidVersion,
    InvalidLicense,
    InvalidRuntime,
    InvalidKind,
    InvalidCapability,
    InvalidAbiVersion,
    InvalidGlibcVersion,
    InvalidTargetTriple,
    InvalidPath,
    InvalidSubpath,
    InvalidExport,
    InvalidBinding,
    UndefinedExportEntry,
    InvalidFeature,
    FeatureCycle,
    InvalidDependency,
    InvalidRange,
    DuplicateDependency,
    DuplicateValue,
};

pub const Package = struct {
    id: []const u8,
    version: []const u8,
    license: []const u8,
    description: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    readme: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
};

pub const Native = struct {
    target_triple: ?[]const u8 = null,
    abi_version: ?u32 = null,
    glibc_min: ?[]const u8 = null,
    library_path: ?[]const u8 = null,
};

pub const Entry = struct {
    subpath: []const u8,
    path: []const u8,
};

pub const Artifact = struct {
    kind: types.Kind,
    runtimes: []const types.Runtime,
    native: ?Native = null,
    entries: []const Entry = &.{},
};

pub const Export = struct {
    subpath: []const u8,
    entry: []const u8,
    binding: types.Binding = .scoped,
};

pub const Engine = struct {
    runtime: types.Runtime,
    range: []const u8,
};

pub const Feature = struct {
    name: []const u8,
    enables: []const []const u8,
};

pub const Model = struct {
    package: Package,
    artifact: Artifact,
    engines: []const Engine = &.{},
    exports: []const Export = &.{},
    features: []const Feature = &.{},
    dependencies: []const types.Dependency = &.{},

    /// 共通 exports のサブパスに対する、このアーティファクトの収録先。
    /// 記録がなければ共通 `entry` を使う。
    pub fn artifactEntry(self: *const Model, subpath: []const u8) ?[]const u8 {
        for (self.artifact.entries) |entry| {
            if (std.mem.eql(u8, entry.subpath, subpath)) return entry.path;
        }
        return null;
    }

    /// サブパスに対応する実ファイル（アーティファクト固有の指定を優先）。
    pub fn selectedEntry(self: *const Model, subpath: []const u8) ?[]const u8 {
        if (self.artifactEntry(subpath)) |path| return path;
        for (self.exports) |export_entry| {
            if (std.mem.eql(u8, export_entry.subpath, subpath)) return export_entry.entry;
        }
        return null;
    }
};

pub const Parsed = struct {
    document: toml.Document,
    model: Model,
};

pub fn parseRuntime(text: []const u8) !types.Runtime {
    if (std.mem.eql(u8, text, "lnako")) return .lnako;
    if (std.mem.eql(u8, text, "cnako")) return .cnako;
    if (std.mem.eql(u8, text, "wnako")) return .wnako;
    return error.InvalidRuntime;
}

pub fn runtimeName(runtime: types.Runtime) []const u8 {
    return switch (runtime) {
        .lnako => "lnako",
        .cnako => "cnako",
        .wnako => "wnako",
    };
}

pub fn runtimeIndex(runtime: types.Runtime) u8 {
    return switch (runtime) {
        .lnako => 0,
        .cnako => 1,
        .wnako => 2,
    };
}

pub fn parseKind(text: []const u8) !types.Kind {
    if (std.mem.eql(u8, text, "universal")) return .universal;
    if (std.mem.eql(u8, text, "esm")) return .esm;
    if (std.mem.eql(u8, text, "native-source")) return .@"native-source";
    if (std.mem.eql(u8, text, "native-prebuilt")) return .@"native-prebuilt";
    return error.InvalidKind;
}

pub fn kindName(kind: types.Kind) []const u8 {
    return switch (kind) {
        .universal => "universal",
        .esm => "esm",
        .@"native-source" => "native-source",
        .@"native-prebuilt" => "native-prebuilt",
    };
}

pub fn bindingName(binding: types.Binding) []const u8 {
    return switch (binding) {
        .scoped => "scoped",
        .global => "global",
    };
}

/// `.` または `./` で始まる公開サブパス。
pub fn validSubpath(text: []const u8) bool {
    if (std.mem.eql(u8, text, ".")) return true;
    if (!std.mem.startsWith(u8, text, "./")) return false;
    return types.validPath(text[2..]);
}

fn capabilityKnown(text: []const u8) bool {
    const known = [_][]const u8{
        "pure-nako", "native", "ffi", "fs", "net", "env", "process", "unsafe",
    };
    for (known) |item| {
        if (std.mem.eql(u8, text, item)) return true;
    }
    return false;
}

pub fn validGlibcVersion(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return false;
        for (part) |byte| {
            if (byte < '0' or byte > '9') return false;
        }
        if (part.len > 1 and part[0] == '0') return false;
    }
    return count >= 2;
}

pub fn validAlias(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '/' or byte == '@') return false;
    }
    return true;
}

fn validateRange(allocator: Allocator, text: []const u8) !void {
    var range = try types.parseRange(allocator, text);
    defer range.deinit(allocator);
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.subpath, right.subpath) == .lt;
}

fn exportLessThan(_: void, left: Export, right: Export) bool {
    return std.mem.order(u8, left.subpath, right.subpath) == .lt;
}

fn featureLessThan(_: void, left: Feature, right: Feature) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

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

fn optionalBool(table: *const Table, name: []const u8) !?bool {
    const value = optionalField(table, name) orelse return null;
    return switch (value.kind) {
        .boolean => |boolean| boolean,
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

fn fieldStringArray(allocator: Allocator, table: *const Table, name: []const u8) ![]const []const u8 {
    const value = try field(table, name);
    const array = try asArray(value);
    const result = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |*item, index| {
        result[index] = item.asString() orelse return error.InvalidFieldType;
    }
    return result;
}

fn optionalStringArray(allocator: Allocator, table: *const Table, name: []const u8) !?[]const []const u8 {
    if (optionalField(table, name) == null) return null;
    return try fieldStringArray(allocator, table, name);
}

fn fieldInteger(table: *const Table, name: []const u8) !i64 {
    const value = try field(table, name);
    return switch (value.kind) {
        .integer => |integer| integer,
        else => error.InvalidFieldType,
    };
}

fn optionalInteger(table: *const Table, name: []const u8) !?i64 {
    const value = optionalField(table, name) orelse return null;
    return switch (value.kind) {
        .integer => |integer| integer,
        else => error.InvalidFieldType,
    };
}

/// TOML の値をモデルへ写す。`model_allocator` はモデルの配列を所有し、
/// 文字列は返却する `document` の arena を借用する。
pub fn parse(
    backing_allocator: Allocator,
    source: []const u8,
    model_allocator: Allocator,
) !Parsed {
    const result = try toml.parse(backing_allocator, source);
    var document = switch (result) {
        .ok => |document| document,
        .err => return error.InvalidMetadata,
    };
    errdefer document.deinit();
    const model = try parseModel(model_allocator, &document.root);
    return .{ .document = document, .model = model };
}

fn parseModel(allocator: Allocator, root: *const Table) !Model {
    // 旧形式は TOML のトップレベルキー `schemaVersion`（または
    // `schema-version`）で識別する。説明文・文字列・コメント中の同じ語を
    // 部分一致で拾わない。旧キーは読み替えず、アーカイブ層で
    // error.LegacyArchive に対応させる。
    if (root.contains("schemaVersion") or root.contains("schema-version"))
        return error.LegacySchema;
    const version = try fieldInteger(root, "schema_version");
    if (version != schema_version) return error.InvalidSchemaVersion;

    const package_table = try fieldTable(root, "package");
    const package = Package{
        .id = try fieldString(package_table, "id"),
        .version = try fieldString(package_table, "version"),
        .license = try fieldString(package_table, "license"),
        .description = try optionalString(package_table, "description"),
        .repository = try optionalString(package_table, "repository"),
        .homepage = try optionalString(package_table, "homepage"),
        .readme = try optionalString(package_table, "readme"),
        .keywords = (try optionalStringArray(allocator, package_table, "keywords")) orelse &.{},
        .capabilities = (try optionalStringArray(allocator, package_table, "capabilities")) orelse &.{},
    };

    const artifact_table = try fieldTable(root, "artifact");
    const kind = try parseKind(try fieldString(artifact_table, "kind"));
    const runtime_names = try fieldStringArray(allocator, artifact_table, "runtimes");
    if (runtime_names.len == 0) return error.InvalidRuntime;
    const runtimes = try allocator.alloc(types.Runtime, runtime_names.len);
    for (runtime_names, 0..) |name, index| runtimes[index] = try parseRuntime(name);
    std.mem.sort(types.Runtime, runtimes, {}, struct {
        fn lessThan(_: void, left: types.Runtime, right: types.Runtime) bool {
            return runtimeIndex(left) < runtimeIndex(right);
        }
    }.lessThan);

    var native: ?Native = null;
    if (try optionalTable(artifact_table, "native")) |native_table| {
        const abi_value = try optionalInteger(native_table, "abi_version");
        if (abi_value != null and (abi_value.? < 1 or abi_value.? > std.math.maxInt(u32)))
            return error.InvalidAbiVersion;
        native = .{
            .target_triple = try optionalString(native_table, "target_triple"),
            .abi_version = if (abi_value) |value| @intCast(value) else null,
            .glibc_min = try optionalString(native_table, "glibc_min"),
            .library_path = try optionalString(native_table, "library_path"),
        };
    }

    var entries: []const Entry = &.{};
    if (try optionalTable(artifact_table, "entries")) |entries_table| {
        const list = try allocator.alloc(Entry, entries_table.count());
        var index: usize = 0;
        var iterator = entries_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            list[index] = .{
                .subpath = item.key_ptr.*,
                .path = item.value_ptr.asString() orelse return error.InvalidFieldType,
            };
        }
        std.mem.sort(Entry, list, {}, entryLessThan);
        entries = list;
    }

    var engines: []const Engine = &.{};
    if (try optionalTable(root, "engines")) |engines_table| {
        const list = try allocator.alloc(Engine, engines_table.count());
        var index: usize = 0;
        var iterator = engines_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            list[index] = .{
                .runtime = try parseRuntime(item.key_ptr.*),
                .range = item.value_ptr.asString() orelse return error.InvalidFieldType,
            };
        }
        std.mem.sort(Engine, list, {}, struct {
            fn lessThan(_: void, left: Engine, right: Engine) bool {
                return runtimeIndex(left.runtime) < runtimeIndex(right.runtime);
            }
        }.lessThan);
        engines = list;
    }

    var exports: []const Export = &.{};
    if (try optionalTable(root, "exports")) |exports_table| {
        const list = try allocator.alloc(Export, exports_table.count());
        var index: usize = 0;
        var iterator = exports_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            const value = item.value_ptr;
            const export_table = try asTable(value);
            const binding = if (try optionalString(export_table, "binding")) |text|
                try parseBinding(text)
            else
                types.Binding.scoped;
            list[index] = .{
                .subpath = item.key_ptr.*,
                .entry = try fieldString(export_table, "entry"),
                .binding = binding,
            };
        }
        std.mem.sort(Export, list, {}, exportLessThan);
        exports = list;
    }

    var features: []const Feature = &.{};
    if (try optionalTable(root, "features")) |features_table| {
        const list = try allocator.alloc(Feature, features_table.count());
        var index: usize = 0;
        var iterator = features_table.iterator();
        while (iterator.next()) |item| : (index += 1) {
            list[index] = .{
                .name = item.key_ptr.*,
                .enables = try stringArrayValue(allocator, item.value_ptr),
            };
        }
        std.mem.sort(Feature, list, {}, featureLessThan);
        features = list;
    }

    const dependencies = try parseDependencies(allocator, root);

    const model = Model{
        .package = package,
        .artifact = .{ .kind = kind, .runtimes = runtimes, .native = native, .entries = entries },
        .engines = engines,
        .exports = exports,
        .features = features,
        .dependencies = dependencies,
    };
    try validateModel(allocator, model);
    return model;
}

fn stringArrayValue(allocator: Allocator, value: *const toml.Value) ![]const []const u8 {
    const array = try asArray(value);
    const result = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |*item, index| {
        result[index] = item.asString() orelse return error.InvalidFieldType;
    }
    return result;
}

fn parseBinding(text: []const u8) !types.Binding {
    if (std.mem.eql(u8, text, "scoped")) return .scoped;
    if (std.mem.eql(u8, text, "global")) return .global;
    return error.InvalidBinding;
}

fn parseDependencies(allocator: Allocator, root: *const Table) ![]const types.Dependency {
    const value = optionalField(root, "dependencies") orelse return &.{};
    const array = try asArray(value);
    const list = try allocator.alloc(types.Dependency, array.items.len);
    for (array.items, 0..) |*item, index| {
        const table = try asTable(item);
        const id = try fieldString(table, "id");
        const req = try fieldString(table, "req");
        const features = (try optionalStringArray(allocator, table, "features")) orelse &.{};
        const runtimes_names = (try optionalStringArray(allocator, table, "runtimes")) orelse &.{};
        const runtimes = try allocator.alloc(types.Runtime, runtimes_names.len);
        for (runtimes_names, 0..) |name, runtime_i| runtimes[runtime_i] = try parseRuntime(name);
        std.mem.sort(types.Runtime, runtimes, {}, struct {
            fn lessThan(_: void, left: types.Runtime, right: types.Runtime) bool {
                return runtimeIndex(left) < runtimeIndex(right);
            }
        }.lessThan);
        list[index] = .{
            .id = id,
            .req = req,
            .alias = try optionalString(table, "alias"),
            .features = features,
            .default_features = (try optionalBool(table, "default_features")) orelse true,
            .optional = (try optionalBool(table, "optional")) orelse false,
            .runtimes = runtimes,
            .allow_global_commands = (try optionalBool(table, "allow_global_commands")) orelse false,
        };
    }
    sortDependencies(list);
    return list;
}

fn dependencyLessThan(_: void, left: types.Dependency, right: types.Dependency) bool {
    const by_id = std.mem.order(u8, left.id, right.id);
    if (by_id != .eq) return by_id == .lt;
    if (left.runtimes.len != right.runtimes.len) return left.runtimes.len < right.runtimes.len;
    for (left.runtimes, right.runtimes) |left_runtime, right_runtime| {
        if (left_runtime != right_runtime) return runtimeIndex(left_runtime) < runtimeIndex(right_runtime);
    }
    return std.mem.order(u8, left.req, right.req) == .lt;
}

fn sortDependencies(dependencies: []types.Dependency) void {
    std.mem.sort(types.Dependency, dependencies, {}, dependencyLessThan);
}

fn hasDuplicateStrings(items: []const []const u8) bool {
    for (items, 0..) |item, index| {
        for (items[index + 1 ..]) |other| {
            if (std.mem.eql(u8, item, other)) return true;
        }
    }
    return false;
}

fn featureIndex(features: []const Feature, name: []const u8) ?usize {
    for (features, 0..) |feature, index| {
        if (std.mem.eql(u8, feature.name, name)) return index;
    }
    return null;
}

fn visitFeature(
    features: []const Feature,
    index: usize,
    state: []u8,
    depth: usize,
) !void {
    if (depth > 1024) return error.FeatureCycle;
    if (state[index] == 1) return error.FeatureCycle;
    if (state[index] == 2) return;
    state[index] = 1;
    for (features[index].enables) |target| {
        const target_index = featureIndex(features, target) orelse return error.InvalidFeature;
        try visitFeature(features, target_index, state, depth + 1);
    }
    state[index] = 2;
}

/// 種別・runtimes・native・exports・feature・依存の静的検査。
pub fn validateModel(allocator: Allocator, model: Model) !void {
    if (!types.validId(model.package.id)) return error.InvalidPackageId;
    if (!types.validPublicVersion(model.package.version)) return error.InvalidVersion;
    if (model.package.license.len == 0 or !types.validLicense(model.package.license))
        return error.InvalidLicense;
    if (hasDuplicateStrings(model.package.keywords)) return error.DuplicateValue;
    for (model.package.capabilities) |capability| {
        if (!capabilityKnown(capability)) return error.InvalidCapability;
    }
    if (hasDuplicateStrings(model.package.capabilities)) return error.DuplicateValue;

    if (model.artifact.runtimes.len == 0) return error.InvalidRuntime;
    for (model.artifact.runtimes, 0..) |runtime, index| {
        if (index > 0 and model.artifact.runtimes[index - 1] == runtime) return error.InvalidRuntime;
    }
    switch (model.artifact.kind) {
        .universal => {
            if (model.artifact.runtimes.len != 3) return error.InvalidRuntime;
            if (model.artifact.native != null) return error.InvalidMetadata;
        },
        .esm => {
            for (model.artifact.runtimes) |runtime| {
                if (runtime == .lnako) return error.InvalidRuntime;
            }
            if (model.artifact.native != null) return error.InvalidMetadata;
        },
        .@"native-source" => {
            if (model.artifact.runtimes.len != 1 or model.artifact.runtimes[0] != .lnako)
                return error.InvalidRuntime;
            const native = model.artifact.native orelse return error.MissingField;
            if (native.abi_version == null) return error.MissingField;
            if (native.glibc_min != null) return error.InvalidGlibcVersion;
            if (native.target_triple) |triple| {
                if (!types.validTargetTriple(triple)) return error.InvalidTargetTriple;
            }
            if (native.library_path) |path| {
                if (!types.validPath(path)) return error.InvalidPath;
            }
        },
        .@"native-prebuilt" => {
            if (model.artifact.runtimes.len != 1 or model.artifact.runtimes[0] != .lnako)
                return error.InvalidRuntime;
            const native = model.artifact.native orelse return error.MissingField;
            const triple = native.target_triple orelse return error.MissingField;
            if (!types.validTargetTriple(triple)) return error.InvalidTargetTriple;
            const abi = native.abi_version orelse return error.MissingField;
            if (abi < 1) return error.InvalidAbiVersion;
            const library_path = native.library_path orelse return error.MissingField;
            if (!types.validPath(library_path)) return error.InvalidPath;
            const gnu = std.mem.endsWith(u8, triple, "-linux-gnu");
            if (gnu) {
                const glibc = native.glibc_min orelse return error.MissingField;
                if (!validGlibcVersion(glibc)) return error.InvalidGlibcVersion;
            } else if (native.glibc_min != null) {
                return error.InvalidGlibcVersion;
            }
        },
    }

    if (model.exports.len == 0) return error.MissingField;
    for (model.exports, 0..) |export_entry, index| {
        if (!validSubpath(export_entry.subpath)) return error.InvalidSubpath;
        if (index > 0 and std.mem.eql(u8, model.exports[index - 1].subpath, export_entry.subpath))
            return error.DuplicateValue;
        if (!types.validPath(export_entry.entry)) return error.InvalidPath;
    }
    for (model.artifact.entries, 0..) |entry, index| {
        if (!validSubpath(entry.subpath)) return error.InvalidSubpath;
        if (index > 0 and std.mem.eql(u8, model.artifact.entries[index - 1].subpath, entry.subpath))
            return error.DuplicateValue;
        if (!types.validPath(entry.path)) return error.InvalidPath;
        var declared = false;
        for (model.exports) |export_entry| {
            if (std.mem.eql(u8, export_entry.subpath, entry.subpath)) declared = true;
        }
        if (!declared) return error.UndefinedExportEntry;
    }
    for (model.engines, 0..) |engine, index| {
        if (index > 0 and model.engines[index - 1].runtime == engine.runtime)
            return error.DuplicateValue;
        validateRange(allocator, engine.range) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidRange,
        };
    }
    for (model.features, 0..) |feature, index| {
        if (feature.name.len == 0) return error.InvalidFeature;
        if (index > 0 and std.mem.eql(u8, model.features[index - 1].name, feature.name))
            return error.DuplicateValue;
        if (hasDuplicateStrings(feature.enables)) return error.DuplicateValue;
    }
    const states = try allocator.alloc(u8, model.features.len);
    defer allocator.free(states);
    @memset(states, 0);
    for (model.features, 0..) |_, index| try visitFeature(model.features, index, states, 0);

    for (model.dependencies, 0..) |dependency, index| {
        if (!types.validId(dependency.id)) return error.InvalidDependency;
        if (dependency.req.len == 0) return error.InvalidRange;
        validateRange(allocator, dependency.req) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidRange,
        };
        if (dependency.alias) |alias| {
            if (!validAlias(alias)) return error.InvalidDependency;
        }
        for (dependency.features) |feature| {
            if (feature.len == 0) return error.InvalidFeature;
        }
        if (hasDuplicateStrings(dependency.features)) return error.DuplicateValue;
        if (index > 0) {
            const previous = model.dependencies[index - 1];
            if (std.mem.eql(u8, previous.id, dependency.id) and
                std.mem.eql(u8, previous.req, dependency.req) and
                sameRuntimes(previous.runtimes, dependency.runtimes))
            {
                return error.DuplicateDependency;
            }
        }
    }
}

fn sameRuntimes(left: []const types.Runtime, right: []const types.Runtime) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_runtime, right_runtime| {
        if (left_runtime != right_runtime) return false;
    }
    return true;
}

/// SPDX 式に現れる `LicenseRef-...` を重複なく昇順で返す。本文の同梱検査は
/// アーカイブ検証が行う（`licenseRefPath`）。
pub fn licenseRefs(allocator: Allocator, license: []const u8) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer refs.deinit(allocator);
    var index: usize = 0;
    while (index < license.len) {
        if (std.mem.startsWith(u8, license[index..], "LicenseRef-")) {
            const start = index;
            const boundary = index == 0 or blk: {
                const previous = license[index - 1];
                break :blk !(std.ascii.isAlphanumeric(previous) or previous == '.' or previous == '-');
            };
            if (!boundary) {
                index += "LicenseRef-".len;
                continue;
            }
            var end = index + "LicenseRef-".len;
            while (end < license.len) : (end += 1) {
                const byte = license[end];
                const idstring = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
                if (!idstring) break;
            }
            if (end > start + "LicenseRef-".len) {
                try refs.append(allocator, license[start..end]);
            }
            index = end;
            continue;
        }
        index += 1;
    }
    std.mem.sort([]const u8, refs.items, {}, stringLessThan);
    var unique: usize = 0;
    for (refs.items) |item| {
        if (unique > 0 and std.mem.eql(u8, refs.items[unique - 1], item)) continue;
        refs.items[unique] = item;
        unique += 1;
    }
    refs.shrinkRetainingCapacity(unique);
    return refs.toOwnedSlice(allocator);
}

/// `LicenseRef-Demo` に対応する本文のアーカイブ内パス。
pub fn licenseRefPath(allocator: Allocator, reference: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "LICENSES/{s}.txt", .{reference});
}

/// モデルを決定的な METADATA.toml へ書き出す。キー順・配列順を固定する。
pub fn emit(allocator: Allocator, model: Model) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer output.deinit();
    const writer = &output.writer;

    try toml_write.writeIntegerField(writer, "schema_version", schema_version);
    try writer.writeByte('\n');
    try toml_write.writeSectionHeader(writer, "package");
    try toml_write.writeStringField(writer, "id", model.package.id);
    try toml_write.writeStringField(writer, "version", model.package.version);
    if (model.package.description) |text| try toml_write.writeStringField(writer, "description", text);
    try toml_write.writeStringField(writer, "license", model.package.license);
    if (model.package.repository) |text| try toml_write.writeStringField(writer, "repository", text);
    if (model.package.homepage) |text| try toml_write.writeStringField(writer, "homepage", text);
    if (model.package.readme) |text| try toml_write.writeStringField(writer, "readme", text);
    if (model.package.keywords.len > 0)
        try toml_write.writeStringArrayField(writer, "keywords", model.package.keywords);
    if (model.package.capabilities.len > 0)
        try toml_write.writeStringArrayField(writer, "capabilities", model.package.capabilities);
    try writer.writeByte('\n');

    try toml_write.writeSectionHeader(writer, "artifact");
    try toml_write.writeStringField(writer, "kind", kindName(model.artifact.kind));
    const runtime_names = try allocator.alloc([]const u8, model.artifact.runtimes.len);
    defer allocator.free(runtime_names);
    for (model.artifact.runtimes, 0..) |runtime, index| runtime_names[index] = runtimeName(runtime);
    try toml_write.writeStringArrayField(writer, "runtimes", runtime_names);
    if (model.artifact.native) |native| {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "artifact.native");
        if (native.target_triple) |text| try toml_write.writeStringField(writer, "target_triple", text);
        if (native.abi_version) |abi| try toml_write.writeIntegerField(writer, "abi_version", abi);
        if (native.glibc_min) |text| try toml_write.writeStringField(writer, "glibc_min", text);
        if (native.library_path) |text| try toml_write.writeStringField(writer, "library_path", text);
    }
    if (model.artifact.entries.len > 0) {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "artifact.entries");
        for (model.artifact.entries) |entry| {
            try toml_write.writeKey(writer, entry.subpath);
            try writer.writeAll(" = ");
            try toml_write.writeString(writer, entry.path);
            try writer.writeByte('\n');
        }
    }

    if (model.engines.len > 0) {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "engines");
        for (model.engines) |engine| {
            try toml_write.writeStringField(writer, runtimeName(engine.runtime), engine.range);
        }
    }

    try writer.writeByte('\n');
    try toml_write.writeSectionHeader(writer, "exports");
    for (model.exports) |export_entry| {
        try toml_write.writeKey(writer, export_entry.subpath);
        try writer.writeAll(" = { ");
        try toml_write.writeInlineStringField(writer, true, "entry", export_entry.entry);
        try toml_write.writeInlineStringField(writer, false, "binding", bindingName(export_entry.binding));
        try writer.writeAll(" }\n");
    }

    if (model.features.len > 0) {
        try writer.writeByte('\n');
        try toml_write.writeSectionHeader(writer, "features");
        for (model.features) |feature| {
            try toml_write.writeStringArrayField(writer, feature.name, feature.enables);
        }
    }

    for (model.dependencies) |dependency| {
        try writer.writeByte('\n');
        try toml_write.writeArraySectionHeader(writer, "dependencies");
        try toml_write.writeStringField(writer, "id", dependency.id);
        try toml_write.writeStringField(writer, "req", dependency.req);
        try toml_write.writeStringArrayField(writer, "features", dependency.features);
        try toml_write.writeBoolField(writer, "default_features", dependency.default_features);
        try toml_write.writeBoolField(writer, "optional", dependency.optional);
        if (dependency.runtimes.len > 0) {
            const names = try allocator.alloc([]const u8, dependency.runtimes.len);
            defer allocator.free(names);
            for (dependency.runtimes, 0..) |runtime, index| names[index] = runtimeName(runtime);
            try toml_write.writeStringArrayField(writer, "runtimes", names);
        }
        if (dependency.alias) |alias| try toml_write.writeStringField(writer, "alias", alias);
        if (dependency.allow_global_commands)
            try toml_write.writeBoolField(writer, "allow_global_commands", true);
    }
    return output.toOwnedSlice();
}
