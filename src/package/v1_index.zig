//! Sparse Index JSON（nako-registry `docs/specification.md` §4）の所有型解析。
//!
//! - `GET /index/v1/config.json`（§4.2）を `parseConfig` で解析する。
//! - `GET /index/v1/packages/{scope}/{name}.json`（§4.3）を `parsePackage` で
//!   解析する。
//! - 解析結果は入力バイト列を参照せず、返した値の arena が全フィールドを所有
//!   する。呼び出し側は `deinit` まで有効な値として扱える。
//! - schema（`schemas/v1/sparse-index-config.schema.json`、
//!   `sparse-index-package.schema.json`）の型・必須項目・kind ごとの
//!   `target` 規則を検査する。schema が追加プロパティを許す箇所は将来の
//!   拡張を拒否しない。
//! - §4.2 の配信元検査（同一オリジン・基底パス・許可ホスト）は取得時に
//!   `v1_download.zig` が行う。ここでは URL が HTTPS として構文的に正しい
//!   ことだけを検査する。
//! - 旧 index 形式の互換読み取り・自動変換は行わない（Q12）。

const std = @import("std");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// 解析・検証の失敗理由。フィールド単位の詳細は持たず、契約違反の種類を
/// 識別できる最小限のタグに分ける。
pub const Error = error{
    /// JSON として不正、root が object 以外、または重複キー。
    InvalidJson,
    /// `schema_version` が整数 1 でない（`1.0` の float も含む）。
    UnsupportedSchemaVersion,
    /// schema の必須項目がない。
    MissingField,
    /// 項目の型・値・kind ごとの組み合わせが schema / §4 に適合しない。
    InvalidField,
    /// 同じ `versions[].version` が二つ以上ある。
    DuplicateVersion,
    OutOfMemory,
};

/// `features` の 1 項目。`default` も通常の feature 名として保持する。
pub const Feature = struct {
    name: []const u8,
    enables: []const []const u8 = &.{},
};

/// `engines` の 1 項目。`range` は node-semver 7.7.4 の範囲構文。
pub const Engine = struct {
    runtime: types.Runtime,
    range: []const u8,
};

/// `provenance`（§4.3）。`verified` だけが必須。
pub const Provenance = struct {
    verified: bool = false,
    provider: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    repository_id: ?[]const u8 = null,
    commit_sha: ?[]const u8 = null,
    workflow_ref: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

/// インデックスの 1 版（§4.3）。共有契約のフィールド名は P10 solver と
/// 共通で、既定値つきの追加フィールドだけをここで足す。
pub const Release = struct {
    version: []const u8,
    yanked: bool = false,
    exports_global_commands: bool = false,
    global_commands: []const []const u8 = &.{},
    dependencies: []const types.Dependency = &.{},
    artifacts: []const types.Artifact = &.{},

    published_at: []const u8 = "",
    yank_reason: ?[]const u8 = null,
    license: []const u8 = "",
    capabilities: []const []const u8 = &.{},
    engines: []const Engine = &.{},
    features: []const Feature = &.{},
    provenance: ?Provenance = null,
};

/// パッケージ単位のインデックス（§4.3）。`arena` は `parsePackage` が設定し、
/// 外部で組み立てた値では null のままにできる。
pub const Package = struct {
    id: []const u8,
    versions: []const Release,
    scope_id: []const u8 = "",
    updated_at: []const u8 = "",
    deprecated: ?[]const u8 = null,
    schema_version: u32 = 1,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Package) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }

    /// バージョン文字列に一致する版を返す。重複は `parsePackage` が拒否する。
    pub fn findRelease(self: *const Package, version: []const u8) ?*const Release {
        for (self.versions) |*release| {
            if (std.mem.eql(u8, release.version, version)) return release;
        }
        return null;
    }
};

/// `config.json`（§4.2）の所有型。
pub const Config = struct {
    registry_id: []const u8 = "",
    api_base_url: []const u8 = "",
    artifact_base_url: []const u8 = "",
    allowed_external_hosts: []const []const u8 = &.{},
    schema_version: u32 = 1,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }

    /// 外部配信を許可するホストか。ホスト名は大文字小文字を区別しない。
    pub fn allowsExternalHost(self: *const Config, host: []const u8) bool {
        for (self.allowed_external_hosts) |allowed| {
            if (std.ascii.eqlIgnoreCase(allowed, host)) return true;
        }
        return false;
    }
};

/// `config.json` を解析する。成功時は入力 `text` を参照しない。
pub fn parseConfig(gpa: Allocator, text: []const u8) Error!Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root = try parseRoot(allocator, text);
    const object = try asObject(root);

    try requireSchemaVersion(object);
    const registry_id = try requiredString(object, "registry_id");
    if (registry_id.len == 0) return error.InvalidField;

    const api_base_url = try requiredString(object, "api_base_url");
    if (!validAbsoluteUri(api_base_url)) return error.InvalidField;

    const artifact_base_url = try requiredString(object, "artifact_base_url");
    if (!validArtifactBaseUrl(artifact_base_url)) return error.InvalidField;

    const hosts_value = object.get("allowed_external_hosts") orelse return error.MissingField;
    const hosts_array = try asArray(hosts_value);
    var hosts: std.ArrayList([]const u8) = .empty;
    for (hosts_array.items) |item| {
        const host = switch (item) {
            .string => |value| value,
            else => return error.InvalidField,
        };
        if (!validHostname(host)) return error.InvalidField;
        try hosts.append(allocator, host);
    }

    var config: Config = .{
        .registry_id = registry_id,
        .api_base_url = api_base_url,
        .artifact_base_url = artifact_base_url,
        .allowed_external_hosts = try hosts.toOwnedSlice(allocator),
    };
    config.arena = arena;
    return config;
}

/// `packages/{scope}/{name}.json` を解析する。成功時は入力 `text` を参照しない。
pub fn parsePackage(gpa: Allocator, text: []const u8) Error!Package {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root = try parseRoot(allocator, text);
    const object = try asObject(root);

    try requireSchemaVersion(object);
    const id = try requiredString(object, "id");
    if (!types.validId(id)) return error.InvalidField;

    const scope_id = try requiredString(object, "scope_id");
    if (scope_id.len == 0) return error.InvalidField;

    const updated_at = try requiredString(object, "updated_at");
    if (!validUtcTimestamp(updated_at)) return error.InvalidField;

    const deprecated = try optionalString(object, "deprecated");

    const versions_value = object.get("versions") orelse return error.MissingField;
    const versions_array = try asArray(versions_value);
    var versions: std.ArrayList(Release) = .empty;
    for (versions_array.items) |item| {
        const release = try parseRelease(allocator, item);
        if (findReleaseIn(versions.items, release.version) != null) return error.DuplicateVersion;
        try versions.append(allocator, release);
    }

    var package: Package = .{
        .id = id,
        .versions = try versions.toOwnedSlice(allocator),
        .scope_id = scope_id,
        .updated_at = updated_at,
        .deprecated = deprecated,
    };
    package.arena = arena;
    return package;
}

fn findReleaseIn(versions: []const Release, version: []const u8) ?usize {
    for (versions, 0..) |release, index| {
        if (std.mem.eql(u8, release.version, version)) return index;
    }
    return null;
}

fn parseRelease(allocator: Allocator, value: Value) Error!Release {
    const object = try asObject(value);

    const version = try requiredString(object, "version");
    if (!types.validPublicVersion(version)) return error.InvalidField;

    const published_at = try requiredString(object, "published_at");
    if (!validUtcTimestamp(published_at)) return error.InvalidField;

    const yanked = try requiredBool(object, "yanked");
    const yank_reason = try optionalString(object, "yank_reason");
    if (yanked) {
        const reason = yank_reason orelse return error.MissingField;
        if (std.mem.trim(u8, reason, " \t\n\r").len == 0) return error.InvalidField;
    }

    const license = try requiredString(object, "license");
    if (license.len == 0) return error.InvalidField;

    const capabilities = try parseCapabilities(allocator, object);
    const engines = try parseEngines(allocator, object);
    const exports_global_commands = try requiredBool(object, "exports_global_commands");
    const global_commands = try parseStringArray(allocator, object, "global_commands", .required);
    if (!exports_global_commands and global_commands.len > 0) return error.InvalidField;
    const features = try parseFeatures(allocator, object);
    const dependencies = try parseDependencies(allocator, object);
    const provenance = try parseProvenance(object);
    const artifacts = try parseArtifacts(allocator, object);

    // `advisories` は schema 上 array。中身の構造は未定義なので型だけ検査する。
    if (object.get("advisories")) |advisories| {
        _ = try asArray(advisories);
    }

    return .{
        .version = version,
        .yanked = yanked,
        .exports_global_commands = exports_global_commands,
        .global_commands = global_commands,
        .dependencies = dependencies,
        .artifacts = artifacts,
        .published_at = published_at,
        .yank_reason = yank_reason,
        .license = license,
        .capabilities = capabilities,
        .engines = engines,
        .features = features,
        .provenance = provenance,
    };
}

fn parseCapabilities(allocator: Allocator, object: ObjectMap) Error![]const []const u8 {
    const value = object.get("capabilities") orelse return error.MissingField;
    const array = try asArray(value);
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = switch (item) {
            .string => |slice| slice,
            else => return error.InvalidField,
        };
        if (!isCapability(text)) return error.InvalidField;
        try items.append(allocator, text);
    }
    return items.toOwnedSlice(allocator);
}

fn isCapability(text: []const u8) bool {
    const known = [_][]const u8{
        "pure-nako", "native", "ffi", "fs", "net", "env", "process", "unsafe",
    };
    for (known) |candidate| if (std.mem.eql(u8, candidate, text)) return true;
    return false;
}

fn parseEngines(allocator: Allocator, object: ObjectMap) Error![]const Engine {
    const value = object.get("engines") orelse return error.MissingField;
    const map = try asObject(value);
    var engines: std.ArrayList(Engine) = .empty;
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const runtime = runtimeFromName(entry.key_ptr.*) orelse return error.InvalidField;
        const range_text = switch (entry.value_ptr.*) {
            .string => |slice| slice,
            else => return error.InvalidField,
        };
        try validateRange(allocator, range_text);
        try engines.append(allocator, .{ .runtime = runtime, .range = range_text });
    }
    return engines.toOwnedSlice(allocator);
}

fn runtimeFromName(name: []const u8) ?types.Runtime {
    if (std.mem.eql(u8, name, "lnako")) return .lnako;
    if (std.mem.eql(u8, name, "cnako")) return .cnako;
    if (std.mem.eql(u8, name, "wnako")) return .wnako;
    return null;
}

fn parseFeatures(allocator: Allocator, object: ObjectMap) Error![]const Feature {
    const value = object.get("features") orelse return error.MissingField;
    const map = try asObject(value);
    var features: std.ArrayList(Feature) = .empty;
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const enables = switch (entry.value_ptr.*) {
            .array => |array| array,
            else => return error.InvalidField,
        };
        var names: std.ArrayList([]const u8) = .empty;
        for (enables.items) |item| {
            const name = switch (item) {
                .string => |slice| slice,
                else => return error.InvalidField,
            };
            try names.append(allocator, name);
        }
        try features.append(allocator, .{
            .name = entry.key_ptr.*,
            .enables = try names.toOwnedSlice(allocator),
        });
    }
    return features.toOwnedSlice(allocator);
}

fn parseDependencies(allocator: Allocator, object: ObjectMap) Error![]const types.Dependency {
    const value = object.get("dependencies") orelse return error.MissingField;
    const array = try asArray(value);
    var dependencies: std.ArrayList(types.Dependency) = .empty;
    for (array.items) |item| {
        try dependencies.append(allocator, try parseDependency(allocator, item));
    }
    return dependencies.toOwnedSlice(allocator);
}

fn parseDependency(allocator: Allocator, value: Value) Error!types.Dependency {
    const object = try asObject(value);
    const id = try requiredString(object, "id");
    if (!types.validId(id)) return error.InvalidField;
    const req = try requiredString(object, "req");
    try validateRange(allocator, req);

    const alias = if (object.get("alias")) |alias_value| switch (alias_value) {
        .string => |slice| if (slice.len == 0) return error.InvalidField else slice,
        else => return error.InvalidField,
    } else null;

    const features = try parseStringArray(allocator, object, "features", .optional);
    const default_features = try optionalBool(object, "default_features", true);
    const optional = try optionalBool(object, "optional", false);
    const runtimes = try parseDependencyRuntimes(allocator, object);
    const allow_global_commands = try optionalBool(object, "allow_global_commands", false);

    return .{
        .id = id,
        .req = req,
        .alias = alias,
        .features = features,
        .default_features = default_features,
        .optional = optional,
        .runtimes = runtimes,
        .allow_global_commands = allow_global_commands,
    };
}

fn parseDependencyRuntimes(allocator: Allocator, object: ObjectMap) Error![]const types.Runtime {
    const value = object.get("runtimes") orelse return &.{};
    const array = try asArray(value);
    if (array.items.len == 0) return error.InvalidField;
    var runtimes: std.ArrayList(types.Runtime) = .empty;
    for (array.items) |item| {
        const text = switch (item) {
            .string => |slice| slice,
            else => return error.InvalidField,
        };
        const runtime = runtimeFromName(text) orelse return error.InvalidField;
        for (runtimes.items) |existing| if (existing == runtime) return error.InvalidField;
        try runtimes.append(allocator, runtime);
    }
    return runtimes.toOwnedSlice(allocator);
}

fn parseProvenance(object: ObjectMap) Error!Provenance {
    const value = object.get("provenance") orelse return error.MissingField;
    const map = try asObject(value);
    return .{
        .verified = try requiredBool(map, "verified"),
        .provider = try optionalNonEmptyString(map, "provider"),
        .repository = blk: {
            const repository = try optionalNonEmptyString(map, "repository");
            if (repository) |text| {
                if (!validAbsoluteUri(text)) return error.InvalidField;
            }
            break :blk repository;
        },
        .repository_id = try optionalNonEmptyString(map, "repository_id"),
        .commit_sha = try optionalNonEmptyString(map, "commit_sha"),
        .workflow_ref = try optionalNonEmptyString(map, "workflow_ref"),
        .run_id = try optionalNonEmptyString(map, "run_id"),
    };
}

fn parseArtifacts(allocator: Allocator, object: ObjectMap) Error![]const types.Artifact {
    const value = object.get("artifacts") orelse return error.MissingField;
    const array = try asArray(value);
    if (array.items.len == 0) return error.InvalidField;
    var artifacts: std.ArrayList(types.Artifact) = .empty;
    for (array.items) |item| {
        try artifacts.append(allocator, try parseArtifact(allocator, item));
    }
    return artifacts.toOwnedSlice(allocator);
}

fn parseArtifact(allocator: Allocator, value: Value) Error!types.Artifact {
    const object = try asObject(value);
    const kind = try parseKind(object);
    const runtimes = try parseArtifactRuntimes(allocator, object, kind);

    var target_triple: ?[]const u8 = null;
    var abi_version: ?u32 = null;
    var glibc_min: ?[]const u8 = null;

    const target_value = object.get("target") orelse return error.MissingField;
    switch (kind) {
        .universal, .esm => {
            if (target_value != .null) return error.InvalidField;
        },
        .@"native-source" => {
            const target = try asObject(target_value);
            abi_version = try requiredAbiVersion(target);
            if (target.get("target_triple") != null or target.get("glibc_min") != null) {
                return error.InvalidField;
            }
        },
        .@"native-prebuilt" => {
            const target = try asObject(target_value);
            const triple = try requiredString(target, "target_triple");
            if (!types.validTargetTriple(triple)) return error.InvalidField;
            abi_version = try requiredAbiVersion(target);
            const is_glibc = std.mem.endsWith(u8, triple, "-linux-gnu");
            if (is_glibc) {
                const version_text = try requiredString(target, "glibc_min");
                if (!types.validGlibcVersion(version_text)) return error.InvalidField;
                glibc_min = version_text;
            } else if (target.get("glibc_min") != null) {
                return error.InvalidField;
            }
            target_triple = triple;
        },
    }

    const hosting_text = try requiredString(object, "hosting");
    const hosting: @TypeOf(@as(types.Artifact, undefined).hosting) = if (std.mem.eql(u8, hosting_text, "registry"))
        .registry
    else if (std.mem.eql(u8, hosting_text, "external"))
        .external
    else
        return error.InvalidField;

    const url = try requiredString(object, "url");
    if (!validHttpsUrl(url)) return error.InvalidField;

    const sha256 = try requiredString(object, "sha256");
    if (!types.validHash(sha256)) return error.InvalidField;

    const size = try requiredUnsigned(object, "size");

    return .{
        .kind = kind,
        .runtimes = runtimes,
        .target_triple = target_triple,
        .abi_version = abi_version,
        .glibc_min = glibc_min,
        .sha256 = sha256,
        .url = url,
        .size = size,
        .hosting = hosting,
    };
}

fn parseKind(object: ObjectMap) Error!types.Kind {
    const text = try requiredString(object, "kind");
    if (std.mem.eql(u8, text, "universal")) return .universal;
    if (std.mem.eql(u8, text, "esm")) return .esm;
    if (std.mem.eql(u8, text, "native-source")) return .@"native-source";
    if (std.mem.eql(u8, text, "native-prebuilt")) return .@"native-prebuilt";
    return error.InvalidField;
}

fn parseArtifactRuntimes(allocator: Allocator, object: ObjectMap, kind: types.Kind) Error![]const types.Runtime {
    const value = object.get("runtimes") orelse return error.MissingField;
    const array = try asArray(value);
    if (array.items.len == 0) return error.InvalidField;

    var runtimes: std.ArrayList(types.Runtime) = .empty;
    for (array.items) |item| {
        const text = switch (item) {
            .string => |slice| slice,
            else => return error.InvalidField,
        };
        const runtime = runtimeFromName(text) orelse return error.InvalidField;
        for (runtimes.items) |existing| if (existing == runtime) return error.InvalidField;
        try runtimes.append(allocator, runtime);
    }
    const result = try runtimes.toOwnedSlice(allocator);

    switch (kind) {
        .universal => {
            if (result.len != 3) return error.InvalidField;
            for ([_]types.Runtime{ .lnako, .cnako, .wnako }) |required| {
                if (!hasRuntime(result, required)) return error.InvalidField;
            }
        },
        .esm => {
            for (result) |runtime| {
                if (runtime == .lnako) return error.InvalidField;
            }
        },
        .@"native-source", .@"native-prebuilt" => {
            if (result.len != 1 or result[0] != .lnako) return error.InvalidField;
        },
    }
    return result;
}

fn hasRuntime(runtimes: []const types.Runtime, runtime: types.Runtime) bool {
    for (runtimes) |item| if (item == runtime) return true;
    return false;
}

fn requiredAbiVersion(object: ObjectMap) Error!u32 {
    const value = try requiredUnsigned(object, "abi_version");
    if (value > std.math.maxInt(u32)) return error.InvalidField;
    return @intCast(value);
}

fn validateRange(allocator: Allocator, text: []const u8) Error!void {
    const range = types.parseRange(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidField,
    };
    // arena 所有なので解放しない。構文検証だけが目的。
    _ = range;
}

const StringMode = enum { required, optional };

fn parseStringArray(
    allocator: Allocator,
    object: ObjectMap,
    key: []const u8,
    mode: StringMode,
) Error![]const []const u8 {
    const value = object.get(key) orelse return switch (mode) {
        .required => error.MissingField,
        .optional => &.{},
    };
    const array = try asArray(value);
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = switch (item) {
            .string => |slice| slice,
            else => return error.InvalidField,
        };
        try items.append(allocator, text);
    }
    return items.toOwnedSlice(allocator);
}

fn parseRoot(allocator: Allocator, text: []const u8) Error!Value {
    return std.json.parseFromSliceLeaky(Value, allocator, text, .{
        // 入力バイト列は解析後に呼び出し側が解放し得るため、文字列は常に複製する。
        .allocate = .alloc_always,
        // `1.0` を integer 1 と取り違えない。
        .parse_numbers = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn requireSchemaVersion(object: ObjectMap) Error!void {
    const value = object.get("schema_version") orelse return error.MissingField;
    return switch (value) {
        .integer => |number| if (number != 1) error.UnsupportedSchemaVersion,
        // `1.0` の float や文字列は整数 1 ではない。
        else => error.UnsupportedSchemaVersion,
    };
}

fn asObject(value: Value) Error!ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidField,
    };
}

fn asArray(value: Value) Error!std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidField,
    };
}

fn requiredString(object: ObjectMap, key: []const u8) Error![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn optionalString(object: ObjectMap, key: []const u8) Error!?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn optionalNonEmptyString(object: ObjectMap, key: []const u8) Error!?[]const u8 {
    const text = try optionalString(object, key);
    if (text) |slice| if (slice.len == 0) return error.InvalidField;
    return text;
}

fn requiredBool(object: ObjectMap, key: []const u8) Error!bool {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidField,
    };
}

fn optionalBool(object: ObjectMap, key: []const u8, default: bool) Error!bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidField,
    };
}

fn requiredUnsigned(object: ObjectMap, key: []const u8) Error!u64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |number| if (number < 0) error.InvalidField else @intCast(number),
        // `1.0` や `1e3` は整数ではない。number_string は i64 を超えた値。
        else => error.InvalidField,
    };
}

/// RFC 3339 の UTC 表現（`Z` / `z` / `+00:00`）。schema の utcTimestamp に合わせる。
pub fn validUtcTimestamp(text: []const u8) bool {
    if (text.len < 20) return false;
    if (!digits(text, 0, 4)) return false;
    if (text[4] != '-') return false;
    if (!digits(text, 5, 2)) return false;
    if (text[7] != '-') return false;
    if (!digits(text, 8, 2)) return false;
    if (text[10] != 'T' and text[10] != 't') return false;
    if (!digits(text, 11, 2)) return false;
    if (text[13] != ':') return false;
    if (!digits(text, 14, 2)) return false;
    if (text[16] != ':') return false;
    if (!digits(text, 17, 2)) return false;

    const year = parseNumber(text[0..4]).?;
    const month = parseNumber(text[5..7]).?;
    const day = parseNumber(text[8..10]).?;
    const hour = parseNumber(text[11..13]).?;
    const minute = parseNumber(text[14..16]).?;
    const second = parseNumber(text[17..19]).?;
    if (month < 1 or month > 12) return false;
    if (day < 1 or day > daysInMonth(year, month)) return false;
    if (hour > 23 or minute > 59 or second > 60) return false;

    var index: usize = 19;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        if (index == start) return false;
    }
    if (index >= text.len) return false;
    if (text[index] == 'Z' or text[index] == 'z') return index + 1 == text.len;
    if (index + 6 == text.len and std.mem.eql(u8, text[index .. index + 6], "+00:00")) return true;
    return false;
}

fn digits(text: []const u8, start: usize, count: usize) bool {
    if (start + count > text.len) return false;
    for (text[start .. start + count]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn parseNumber(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

/// `https://host/...` の構文検査。§4.2 の配信元制約はここでは課さない。
pub fn validHttpsUrl(text: []const u8) bool {
    if (!hasNoWhitespace(text)) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null) return false;
    const host = hostText(uri) orelse return false;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '%') != null) return false;
    return true;
}

fn validArtifactBaseUrl(text: []const u8) bool {
    if (!validHttpsUrl(text)) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (uri.query != null or uri.fragment != null) return false;
    return pathHasNoDotSegments(componentText(uri.path));
}

fn validAbsoluteUri(text: []const u8) bool {
    if (!hasNoWhitespace(text)) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (uri.scheme.len == 0) return false;
    return true;
}

fn hasNoWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return false;
    }
    return true;
}

fn hostText(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    return componentText(host);
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |text| text,
    };
}

fn pathHasNoDotSegments(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// DNS ホスト名（ポート・scheme・ワイルドカードを含まない）。
pub fn validHostname(text: []const u8) bool {
    if (text.len == 0 or text.len > 253) return false;
    if (text[0] == '.' or text[text.len - 1] == '.') return false;
    var labels = std.mem.splitScalar(u8, text, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
        }
    }
    return true;
}

test {
    _ = @import("v1_index_test.zig");
}
