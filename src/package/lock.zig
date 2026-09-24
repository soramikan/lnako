const std = @import("std");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const diag = @import("diagnostics.zig");
const model = @import("lock_model.zig");

const Allocator = std.mem.Allocator;

pub const lock_schema_version = model.lock_schema_version;
pub const resolver_version = model.resolver_version;
pub const known_artifact_kinds = model.known_artifact_kinds;
pub const known_profile_runtimes = model.known_profile_runtimes;
pub const known_artifact_types = model.known_artifact_types;
pub const known_implementations = model.known_implementations;
pub const known_profile_os = model.known_profile_os;
pub const known_profile_cpu = model.known_profile_cpu;
pub const known_profile_abi = model.known_profile_abi;
pub const known_optimize = model.known_optimize;
pub const Target = model.Target;
pub const ProfileRecord = model.ProfileRecord;
pub const NamedProfile = model.NamedProfile;
pub const SourceKind = model.SourceKind;
pub const Source = model.Source;
pub const Artifact = model.Artifact;
pub const PeerDependency = model.PeerDependency;
pub const NpmInstance = model.NpmInstance;
pub const PackageEntry = model.PackageEntry;
pub const Input = model.Input;
pub const ProfilePackages = model.ProfilePackages;
pub const Lock = model.Lock;
pub const SharedMismatch = model.SharedMismatch;
pub const serialize = model.serialize;
pub const toBytes = model.toBytes;
pub const sha256Hex = model.sha256Hex;
pub const sharedArtifactMismatch = model.sharedArtifactMismatch;
const packageEntryEql = model.packageEntryEql;
const packageMapsEql = model.packageMapsEql;
const containsString = model.containsString;
const stringLessThan = model.stringLessThan;
const packageLessThan = model.packageLessThan;
const profilePackageLessThan = model.profilePackageLessThan;
const namedProfileLessThan = model.namedProfileLessThan;

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

pub const ParseError = error{ OutOfMemory, InvalidJson, InvalidLock };

const Parser = struct {
    arena: Allocator,
    diagnostics: *diag.List,

    fn report(self: *Parser, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.addFmt(code, .err, path, .{}, format, args);
    }

    fn asObject(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.ObjectMap {
        return switch (value) {
            .object => |object| object,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected object", .{});
                break :blk null;
            },
        };
    }

    fn asArray(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.Array {
        return switch (value) {
            .array => |array| array,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected array", .{});
                break :blk null;
            },
        };
    }

    fn asString(self: *Parser, value: std.json.Value, path: []const u8) !?[]const u8 {
        return switch (value) {
            .string => |text| text,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected string", .{});
                break :blk null;
            },
        };
    }

    fn asBool(self: *Parser, value: std.json.Value, path: []const u8) !?bool {
        return switch (value) {
            .bool => |flag| flag,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected boolean", .{});
                break :blk null;
            },
        };
    }

    fn asU32(self: *Parser, value: std.json.Value, path: []const u8) !?u32 {
        return switch (value) {
            .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected unsigned integer", .{});
                break :blk null;
            },
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected integer", .{});
                break :blk null;
            },
        };
    }

    fn duplicate(self: *Parser, text: []const u8) ![]const u8 {
        return self.arena.dupe(u8, text);
    }

    /// `additionalProperties: false` 相当。未知フィールドを E022 で報告する。
    fn rejectUnknown(self: *Parser, object: std.json.ObjectMap, allowed: []const []const u8, path: []const u8) !void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (containsString(allowed, entry.key_ptr.*)) continue;
            const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try self.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    /// 必須 string フィールドを読む。欠落は E019。
    fn requiredString(self: *Parser, object: std.json.ObjectMap, name: []const u8, path: []const u8) !?[]const u8 {
        const value = object.get(name) orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"{s}\"", .{name});
            return null;
        };
        return self.asString(value, path);
    }
};

fn parseFeatureList(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const []const u8 {
    const array = (try parser.asArray(value, path)) orelse return null;
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = (try parser.asString(item, path)) orelse continue;
        try items.append(parser.arena, try parser.duplicate(text));
    }
    return items.items;
}

fn parseStringList(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const []const u8 {
    const array = (try parser.asArray(value, path)) orelse return null;
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = (try parser.asString(item, path)) orelse continue;
        try items.append(parser.arena, try parser.duplicate(text));
    }
    return items.items;
}

fn parseSource(parser: *Parser, value: std.json.Value, path: []const u8) !?Source {
    const object = (try parser.asObject(value, path)) orelse return null;
    const type_value = object.get("type") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"type\"", .{});
        return null;
    };
    const type_text = (try parser.asString(type_value, path)) orelse return null;

    var source = Source{ .kind = .registry };
    if (std.mem.eql(u8, type_text, "registry")) {
        source.kind = .registry;
    } else if (std.mem.eql(u8, type_text, "static")) {
        source.kind = .static;
    } else if (std.mem.eql(u8, type_text, "git")) {
        source.kind = .git;
    } else if (std.mem.eql(u8, type_text, "http")) {
        source.kind = .http;
    } else if (std.mem.eql(u8, type_text, "path")) {
        source.kind = .path;
    } else {
        try parser.report(diag.E029_INVALID_VALUE, path, "unknown source type \"{s}\"", .{type_text});
        return null;
    }

    const allowed: []const []const u8 = switch (source.kind) {
        .registry, .static => &.{ "type", "url" },
        .git => &.{ "type", "url", "commit", "path" },
        .http => &.{ "type", "url", "hash" },
        .path => &.{ "type", "path", "mutable" },
    };
    try parser.rejectUnknown(object, allowed, path);

    // source 種別ごとの必須フィールド。
    switch (source.kind) {
        .registry, .static => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
        },
        .git => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
            if (try parser.requiredString(object, "commit", path)) |commit| source.commit = try parser.duplicate(commit);
        },
        .http => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
            if (try parser.requiredString(object, "hash", path)) |hash| source.hash = try parser.duplicate(hash);
        },
        .path => {
            if (try parser.requiredString(object, "path", path)) |dep_path| source.path = try parser.duplicate(dep_path);
        },
    }

    if (source.kind == .git) {
        if (object.get("path")) |dep_path_value| {
            if (try parser.asString(dep_path_value, path)) |dep_path| source.path = try parser.duplicate(dep_path);
        }
    }
    if (source.kind == .path) {
        if (object.get("mutable")) |mutable_value| {
            if (try parser.asBool(mutable_value, path)) |mutable| source.mutable = mutable;
        }
        // path 依存は可変参照が既定。
        if (source.mutable == null) source.mutable = true;
    }
    return source;
}

fn parseArtifact(parser: *Parser, key: []const u8, value: std.json.Value, path: []const u8) !?Artifact {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "kind", "type", "sha256", "url" }, path);
    const kind_text = (try parser.requiredString(object, "kind", path)) orelse return null;
    var artifact = Artifact{ .key = try parser.duplicate(key), .kind = try parser.duplicate(kind_text) };
    if (object.get("type")) |type_value| {
        if (try parser.asString(type_value, path)) |artifact_type| artifact.type = try parser.duplicate(artifact_type);
    }
    if (object.get("sha256")) |sha_value| {
        if (try parser.asString(sha_value, path)) |sha256| artifact.sha256 = try parser.duplicate(sha256);
    }
    if (object.get("url")) |url_value| {
        if (try parser.asString(url_value, path)) |url| artifact.url = try parser.duplicate(url);
    }
    return artifact;
}

fn parseNpmInstance(parser: *Parser, key: []const u8, value: std.json.Value, path: []const u8) !?NpmInstance {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "name", "version", "context", "sha256", "url", "peerDependencies" }, path);
    const name_text = (try parser.requiredString(object, "name", path)) orelse return null;
    const version_text = (try parser.requiredString(object, "version", path)) orelse return null;
    var instance = NpmInstance{
        .key = try parser.duplicate(key),
        .name = try parser.duplicate(name_text),
        .version = try parser.duplicate(version_text),
    };
    if (object.get("context")) |context_value| {
        if (try parser.asString(context_value, path)) |context| instance.context = try parser.duplicate(context);
    }
    if (object.get("sha256")) |sha_value| {
        if (try parser.asString(sha_value, path)) |sha256| instance.sha256 = try parser.duplicate(sha256);
    }
    if (object.get("url")) |url_value| {
        if (try parser.asString(url_value, path)) |url| instance.url = try parser.duplicate(url);
    }
    if (object.get("peerDependencies")) |peers_value| {
        if (try parser.asObject(peers_value, path)) |peers| {
            var list: std.ArrayList(PeerDependency) = .empty;
            var iterator = peers.iterator();
            while (iterator.next()) |entry| {
                const requirement = (try parser.asString(entry.value_ptr.*, path)) orelse continue;
                try list.append(parser.arena, .{
                    .name = try parser.duplicate(entry.key_ptr.*),
                    .requirement = try parser.duplicate(requirement),
                });
            }
            std.mem.sort(PeerDependency, list.items, {}, struct {
                fn lt(_: void, a: PeerDependency, b: PeerDependency) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt);
            instance.peer_dependencies = list.items;
        }
    }
    return instance;
}

fn parsePackageEntry(parser: *Parser, id: []const u8, value: std.json.Value, path: []const u8) !?PackageEntry {
    const object = (try parser.asObject(value, path)) orelse return null;
    const known = [_][]const u8{ "id", "name", "version", "source", "resolvedFrom", "dependencies", "features", "implementation", "artifacts", "npmInstances" };
    var key_iterator = object.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    const name_value = object.get("name") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"name\"", .{});
        return null;
    };
    const version_value = object.get("version") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"version\"", .{});
        return null;
    };
    var entry = PackageEntry{
        .id = try parser.duplicate(id),
        .name = try parser.duplicate((try parser.asString(name_value, path)) orelse return null),
        .version = try parser.duplicate((try parser.asString(version_value, path)) orelse return null),
    };
    const explicit_id = (try parser.requiredString(object, "id", path)) orelse return null;
    if (!std.mem.eql(u8, explicit_id, id)) {
        try parser.report(diag.E029_INVALID_VALUE, path, "package id \"{s}\" does not match map key \"{s}\"", .{ explicit_id, id });
    }
    entry.id = try parser.duplicate(explicit_id);
    const dependencies_value = object.get("dependencies") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"dependencies\"", .{});
        return null;
    };
    if (object.get("source")) |source_value| {
        entry.source = try parseSource(parser, source_value, path);
    }
    if (object.get("resolvedFrom")) |source_value| {
        entry.resolved_from = try parseSource(parser, source_value, path);
    }
    entry.dependencies = (try parseStringList(parser, dependencies_value, path)) orelse &.{};
    if (object.get("features")) |features_value| {
        entry.features = (try parseFeatureList(parser, features_value, path)) orelse &.{};
    }
    if (object.get("implementation")) |implementation_value| {
        if (try parser.asString(implementation_value, path)) |implementation| {
            if (!containsString(&known_implementations, implementation)) {
                try parser.report(diag.E029_INVALID_VALUE, path, "unknown implementation \"{s}\"", .{implementation});
            }
            entry.implementation = try parser.duplicate(implementation);
        }
    }
    if (object.get("artifacts")) |artifacts_value| {
        if (try parser.asObject(artifacts_value, path)) |artifacts| {
            var list: std.ArrayList(Artifact) = .empty;
            var iterator = artifacts.iterator();
            while (iterator.next()) |artifact_entry| {
                if (try parseArtifact(parser, artifact_entry.key_ptr.*, artifact_entry.value_ptr.*, path)) |artifact| {
                    try list.append(parser.arena, artifact);
                }
            }
            std.mem.sort(Artifact, list.items, {}, struct {
                fn lt(_: void, a: Artifact, b: Artifact) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            entry.artifacts = list.items;
        }
    }
    if (object.get("npmInstances")) |npm_value| {
        if (try parser.asObject(npm_value, path)) |instances| {
            var list: std.ArrayList(NpmInstance) = .empty;
            var iterator = instances.iterator();
            while (iterator.next()) |instance_entry| {
                if (try parseNpmInstance(parser, instance_entry.key_ptr.*, instance_entry.value_ptr.*, path)) |instance| {
                    try list.append(parser.arena, instance);
                }
            }
            std.mem.sort(NpmInstance, list.items, {}, struct {
                fn lt(_: void, a: NpmInstance, b: NpmInstance) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            entry.npm_instances = list.items;
        }
    }
    return entry;
}

fn parsePackageMap(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const PackageEntry {
    const object = (try parser.asObject(value, path)) orelse return null;
    var list: std.ArrayList(PackageEntry) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
        if (try parsePackageEntry(parser, entry.key_ptr.*, entry.value_ptr.*, field_path)) |package| {
            try list.append(parser.arena, package);
        }
    }
    std.mem.sort(PackageEntry, list.items, {}, packageLessThan);
    return list.items;
}

fn parseProfile(parser: *Parser, value: std.json.Value, path: []const u8) !?ProfileRecord {
    const object = (try parser.asObject(value, path)) orelse return null;
    const known = [_][]const u8{ "runtime", "os", "cpu", "abi", "compat-js", "optimize" };
    var key_iterator = object.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }
    const os_value = object.get("os") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"os\"", .{});
        return null;
    };
    const cpu_value = object.get("cpu") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"cpu\"", .{});
        return null;
    };
    const abi_value = object.get("abi") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"abi\"", .{});
        return null;
    };
    var profile = ProfileRecord{
        .os = try parser.duplicate((try parser.asString(os_value, path)) orelse return null),
        .cpu = try parser.duplicate((try parser.asString(cpu_value, path)) orelse return null),
        .abi = try parser.duplicate((try parser.asString(abi_value, path)) orelse return null),
    };
    if (object.get("runtime")) |runtime_value| {
        if (try parser.asString(runtime_value, path)) |runtime| profile.runtime = try parser.duplicate(runtime);
    }
    if (object.get("compat-js")) |compat_value| {
        profile.compat_js = try parser.asBool(compat_value, path);
    }
    if (object.get("optimize")) |optimize_value| {
        if (try parser.asString(optimize_value, path)) |optimize| profile.optimize = try parser.duplicate(optimize);
    }
    return profile;
}

fn parseInput(parser: *Parser, value: std.json.Value, path: []const u8) !?Input {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "manifestSha256", "profile", "features", "target", "runtime", "nakoVersion", "cnakoVersion", "lnakoVersion", "mutablePaths" }, path);
    const manifest_value = object.get("manifestSha256") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"manifestSha256\"", .{});
        return null;
    };
    const profile_value = object.get("profile") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"profile\"", .{});
        return null;
    };
    const features_value = object.get("features") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"features\"", .{});
        return null;
    };
    const target_value = object.get("target") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target\"", .{});
        return null;
    };
    const target_object = (try parser.asObject(target_value, path)) orelse return null;
    try parser.rejectUnknown(target_object, &.{ "os", "cpu", "abi", "compatJs", "optimize" }, path);
    const os_value = target_object.get("os") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.os\"", .{});
        return null;
    };
    const cpu_value = target_object.get("cpu") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.cpu\"", .{});
        return null;
    };
    const abi_value = target_object.get("abi") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.abi\"", .{});
        return null;
    };
    var mutable_paths: std.ArrayList(model.MutablePath) = .empty;
    if (object.get("mutablePaths")) |mutable_value| {
        const mutable_path = try std.fmt.allocPrint(parser.arena, "{s}.mutablePaths", .{path});
        if (try parser.asArray(mutable_value, mutable_path)) |array| {
            for (array.items, 0..) |item, index| {
                const item_path = try std.fmt.allocPrint(parser.arena, "{s}[{d}]", .{ mutable_path, index });
                const item_object = (try parser.asObject(item, item_path)) orelse return null;
                try parser.rejectUnknown(item_object, &.{ "path", "sha256" }, item_path);
                const path_value = item_object.get("path") orelse {
                    try parser.report(diag.E019_REQUIRED_FIELD_MISSING, item_path, "missing required field \"path\"", .{});
                    return null;
                };
                const sha_value = item_object.get("sha256") orelse {
                    try parser.report(diag.E019_REQUIRED_FIELD_MISSING, item_path, "missing required field \"sha256\"", .{});
                    return null;
                };
                try mutable_paths.append(parser.arena, .{
                    .path = try parser.duplicate((try parser.asString(path_value, item_path)) orelse return null),
                    .sha256 = try parser.duplicate((try parser.asString(sha_value, item_path)) orelse return null),
                });
            }
        }
    }
    var input = Input{
        .manifest_sha256 = try parser.duplicate((try parser.asString(manifest_value, path)) orelse return null),
        .profile = try parser.duplicate((try parser.asString(profile_value, path)) orelse return null),
        .features = (try parseFeatureList(parser, features_value, path)) orelse &.{},
        .target = .{
            .os = try parser.duplicate((try parser.asString(os_value, path)) orelse return null),
            .cpu = try parser.duplicate((try parser.asString(cpu_value, path)) orelse return null),
            .abi = try parser.duplicate((try parser.asString(abi_value, path)) orelse return null),
            // `--compat-js` で解決した lock のみ記録する任意項目。
            // 欠落は false と同等。記録される場合は bool のみ許容し、
            // 文字列 `"true"` 等を黙って false へ落とさない。
            .compat_js = if (target_object.get("compatJs")) |v|
                (try parser.asBool(v, path)) orelse return null
            else
                false,
            // `-O` で解決した lock のみ記録する任意項目。欠落は O0 と
            // 同等。値は profile の optimize と同じ既知集合に限定する。
            .optimize = if (target_object.get("optimize")) |v| blk: {
                const optimize = (try parser.asString(v, path)) orelse return null;
                if (!containsString(&model.known_optimize, optimize)) {
                    try parser.report(diag.E029_INVALID_VALUE, path, "invalid optimize: {s}", .{optimize});
                    return null;
                }
                break :blk try parser.duplicate(optimize);
            } else "O0",
        },
        .mutable_paths = mutable_paths.items,
    };
    // 解決 runtime・engines 照合 version は任意項目（旧 lock では欠落）。
    if (object.get("runtime")) |runtime_value| {
        if (try parser.asString(runtime_value, path)) |runtime| input.runtime = try parser.duplicate(runtime);
    }
    if (object.get("nakoVersion")) |version_value| {
        if (try parser.asString(version_value, path)) |version| input.nako_version = try parser.duplicate(version);
    }
    if (object.get("cnakoVersion")) |version_value| {
        if (try parser.asString(version_value, path)) |version| input.cnako_version = try parser.duplicate(version);
    }
    if (object.get("lnakoVersion")) |version_value| {
        if (try parser.asString(version_value, path)) |version| input.lnako_version = try parser.duplicate(version);
    }
    return input;
}

/// `nako.lock` バイト列を解析して `Lock` を構築する。構造エラーは診断へ記録し
/// `error.InvalidLock` を返す。未知 schema version は構文上有効なので解析は成功し、
/// `validate` が `E002_UNKNOWN_LOCK_SCHEMA` を報告する。
pub fn parse(gpa: Allocator, bytes: []const u8, diagnostics: *diag.List) ParseError!Lock {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const initial_errors = diagnostics.errorCount();
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var parser = Parser{ .arena = arena.allocator(), .diagnostics = diagnostics };

    const root = (try parser.asObject(parsed.value, "nako.lock")) orelse return error.InvalidLock;
    const known_root = [_][]const u8{ "schemaVersion", "resolverVersion", "input", "packages", "profiles", "profilePackages" };
    var key_iterator = root.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known_root, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.{s}", .{entry.key_ptr.*});
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    const schema_value = root.get("schemaVersion") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"schemaVersion\"", .{});
        return error.InvalidLock;
    };
    const schema_version = (try parser.asU32(schema_value, "nako.lock.schemaVersion")) orelse return error.InvalidLock;

    const resolver_value = root.get("resolverVersion") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"resolverVersion\"", .{});
        return error.InvalidLock;
    };
    const resolver_version_value = (try parser.asU32(resolver_value, "nako.lock.resolverVersion")) orelse return error.InvalidLock;

    const input_value = root.get("input") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"input\"", .{});
        return error.InvalidLock;
    };
    const input = (try parseInput(&parser, input_value, "nako.lock.input")) orelse return error.InvalidLock;

    const packages_value = root.get("packages") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"packages\"", .{});
        return error.InvalidLock;
    };
    const packages = (try parsePackageMap(&parser, packages_value, "nako.lock.packages")) orelse return error.InvalidLock;

    var profiles: std.ArrayList(NamedProfile) = .empty;
    if (root.get("profiles")) |profiles_value| {
        if (try parser.asObject(profiles_value, "nako.lock.profiles")) |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.profiles.{s}", .{entry.key_ptr.*});
                if (try parseProfile(&parser, entry.value_ptr.*, field_path)) |record| {
                    try profiles.append(parser.arena, .{
                        .name = try parser.duplicate(entry.key_ptr.*),
                        .record = record,
                    });
                }
            }
        }
    }
    std.mem.sort(NamedProfile, profiles.items, {}, namedProfileLessThan);

    var profile_packages: std.ArrayList(ProfilePackages) = .empty;
    if (root.get("profilePackages")) |value| {
        if (try parser.asObject(value, "nako.lock.profilePackages")) |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.profilePackages.{s}", .{entry.key_ptr.*});
                if (try parsePackageMap(&parser, entry.value_ptr.*, field_path)) |profile_package_list| {
                    try profile_packages.append(parser.arena, .{
                        .profile = try parser.duplicate(entry.key_ptr.*),
                        .packages = profile_package_list,
                    });
                }
            }
        }
    }
    std.mem.sort(ProfilePackages, profile_packages.items, {}, profilePackageLessThan);

    if (diagnostics.errorCount() > initial_errors) return error.InvalidLock;

    return .{
        .arena = arena,
        .schema_version = schema_version,
        .resolver_version = resolver_version_value,
        .input = input,
        .packages = packages,
        .profiles = profiles.items,
        .profile_packages = profile_packages.items,
    };
}

// ---------------------------------------------------------------------------
// 意味検証
// ---------------------------------------------------------------------------

/// `pkg:<32桁小文字16進>` 形式かを判定する。JSON Schema の packageId pattern と
/// 同じ受理集合を Zig 側でも要求する。
fn isValidPublicId(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "pkg:") or text.len != "pkg:".len + 32) return false;
    for (text["pkg:".len..]) |ch| {
        const digit = ch >= '0' and ch <= '9';
        const lower_hex = ch >= 'a' and ch <= 'f';
        if (!digit and !lower_hex) return false;
    }
    return true;
}

fn validatePackageSet(packages: []const PackageEntry, exists: *const std.StringHashMapUnmanaged(void), profile: ?ProfileRecord, path: []const u8, diagnostics: *diag.List) !void {
    const esm_allowed = if (profile) |record| record.allowsEsm() else false;
    for (packages) |package| {
        const package_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ path, package.id });
        defer diagnostics.allocator.free(package_path);
        const artifacts_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts", .{package_path});
        defer diagnostics.allocator.free(artifacts_path);
        if (!isValidPublicId(package.id)) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, package_path, .{}, "invalid package id \"{s}\" (expected pkg:<32hex>)", .{package.id});
        }
        _ = semver.Version.parse(package.version) catch {
            try diagnostics.addFmt(diag.E024_INVALID_SEMVER, .err, package_path, .{}, "invalid package version \"{s}\" (not semver)", .{package.version});
        };
        if (package.artifacts.len == 0) {
            try diagnostics.addFmt(diag.E008_MISSING_ARTIFACT, .err, artifacts_path, .{}, "package {s} has no artifacts", .{package.id});
        }
        var has_esm = false;
        for (package.artifacts) |artifact| {
            if (!artifact.isKnownKind()) {
                const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                defer diagnostics.allocator.free(artifact_path);
                try diagnostics.addFmt(diag.E007_UNKNOWN_ARTIFACT_KIND, .err, artifact_path, .{}, "unknown artifact kind \"{s}\" at {s}.artifacts.{s}", .{ artifact.kind, package_path, artifact.key });
            }
            if (std.mem.eql(u8, artifact.kind, "ESM")) has_esm = true;
            if (artifact.type) |artifact_type| {
                if (!containsString(&known_artifact_types, artifact_type)) {
                    const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                    defer diagnostics.allocator.free(artifact_path);
                    try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, artifact_path, .{}, "unknown artifact type \"{s}\"", .{artifact_type});
                }
            }
        }
        if (has_esm and !esm_allowed) {
            try diagnostics.addFmt(diag.E006_JS_IN_NORMAL_MODE, .err, artifacts_path, .{}, "ESM artifact selected without compat-js profile", .{});
        }
        // 選択された実装種別に対応する artifact が存在しなければ同期できない。
        if (package.implementation) |implementation| {
            if (!containsString(&known_implementations, implementation)) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, package_path, .{}, "unknown implementation \"{s}\"", .{implementation});
            } else if (!std.mem.eql(u8, implementation, "none") and !package.hasKind(implementation)) {
                try diagnostics.addFmt(diag.E008_MISSING_ARTIFACT, .err, artifacts_path, .{}, "selected implementation \"{s}\" has no matching artifact", .{implementation});
            }
        }
        for (package.dependencies) |dependency| {
            const dependencies_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.dependencies", .{package_path});
            defer diagnostics.allocator.free(dependencies_path);
            if (!isValidPublicId(dependency)) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, dependencies_path, .{}, "invalid dependency id \"{s}\" (expected pkg:<32hex>)", .{dependency});
            }
            if (!exists.contains(dependency)) {
                try diagnostics.addFmt(diag.E013_MISSING_PACKAGE, .err, dependencies_path, .{}, "dependency {s} not found in lock packages", .{dependency});
            }
        }
    }
}

fn buildIdSet(gpa: Allocator, packages: []const PackageEntry) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (packages) |package| {
        try set.put(gpa, package.id, {});
    }
    return set;
}

const KnownField = struct {
    name: []const u8,
    value: []const u8,
    known: []const []const u8,
};

fn validateKnownFields(fields: []const KnownField, base: []const u8, label: []const u8, diagnostics: *diag.List) !void {
    for (fields) |field| {
        if (containsString(field.known, field.value)) continue;
        const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ base, field.name });
        defer diagnostics.allocator.free(path);
        try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, path, .{}, "{s} has invalid {s}: {s}", .{ label, field.name, field.value });
    }
}

/// profile 条件の runtime・os・cpu・abi・optimize を manifest と同じ既知値で検証する。
fn validateProfileRecord(name: []const u8, record: ProfileRecord, diagnostics: *diag.List) !void {
    const base = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profiles.{s}", .{name});
    defer diagnostics.allocator.free(base);

    if (record.runtime) |runtime| {
        if (!containsString(&known_profile_runtimes, runtime)) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.runtime", .{base});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, path, .{}, "profile \"{s}\" has invalid runtime: {s}", .{ name, runtime });
        }
    }
    try validateKnownFields(&.{
        .{ .name = "os", .value = record.os, .known = &known_profile_os },
        .{ .name = "cpu", .value = record.cpu, .known = &known_profile_cpu },
        .{ .name = "abi", .value = record.abi, .known = &known_profile_abi },
    }, base, "profile", diagnostics);
    // optimize は JSON Schema / manifest と同じく E029 で報告する。
    if (record.optimize) |optimize| {
        if (!containsString(&known_optimize, optimize)) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.optimize", .{base});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "profile \"{s}\" has invalid optimize: {s}", .{ name, optimize });
        }
    }
}

fn validateTarget(target: Target, path: []const u8, diagnostics: *diag.List) !void {
    try validateKnownFields(&.{
        .{ .name = "os", .value = target.os, .known = &known_profile_os },
        .{ .name = "cpu", .value = target.cpu, .known = &known_profile_cpu },
        .{ .name = "abi", .value = target.abi, .known = &known_profile_abi },
    }, path, "input.target", diagnostics);
}

/// lock の意味的な整合性を検証する。既知の診断は SPECIFICATION.md §8 と対応する。
pub fn validate(lock: *const Lock, diagnostics: *diag.List) !void {
    if (lock.schema_version != lock_schema_version) {
        try diagnostics.addFmt(diag.E002_UNKNOWN_LOCK_SCHEMA, .err, "nako.lock.schemaVersion", .{}, "unknown lock schema version {d}", .{lock.schema_version});
    }

    var profile_names: std.StringHashMapUnmanaged(void) = .empty;
    defer profile_names.deinit(diagnostics.allocator);
    for (lock.profiles) |profile| {
        const gop = try profile_names.getOrPut(diagnostics.allocator, profile.name);
        if (gop.found_existing) {
            const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profiles.{s}", .{profile.name});
            defer diagnostics.allocator.free(path);
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, path, .{}, "duplicate profile \"{s}\"", .{profile.name});
        }
        try validateProfileRecord(profile.name, profile.record, diagnostics);
    }

    // `input.target` も profile と同じ既知値集合で検証する。
    try validateTarget(lock.input.target, "nako.lock.input.target", diagnostics);

    var id_set = try buildIdSet(diagnostics.allocator, lock.packages);
    defer id_set.deinit(diagnostics.allocator);

    if (lock.profileRecord(lock.input.profile) == null) {
        try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, "nako.lock.input.profile", .{}, "unknown profile \"{s}\"", .{lock.input.profile});
    }
    const selected = lock.profileRecord(lock.input.profile);
    // 選択 profile の環境条件は `input.target` と一致していなければならない。
    if (selected) |record| {
        if (!std.mem.eql(u8, record.os, lock.input.target.os) or
            !std.mem.eql(u8, record.cpu, lock.input.target.cpu) or
            !std.mem.eql(u8, record.abi, lock.input.target.abi))
        {
            try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, "nako.lock.input.target", .{}, "input.target does not match profile \"{s}\" os/cpu/abi", .{lock.input.profile});
        }
    }
    try validatePackageSet(lock.packages, &id_set, if (selected) |record| record.* else null, "nako.lock.packages", diagnostics);

    var profile_package_names: std.StringHashMapUnmanaged(void) = .empty;
    defer profile_package_names.deinit(diagnostics.allocator);
    for (lock.profile_packages) |profile| {
        var profile_id_set = try buildIdSet(diagnostics.allocator, profile.packages);
        defer profile_id_set.deinit(diagnostics.allocator);
        const profile_path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profilePackages.{s}", .{profile.profile});
        defer diagnostics.allocator.free(profile_path);
        const gop = try profile_package_names.getOrPut(diagnostics.allocator, profile.profile);
        if (gop.found_existing) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, profile_path, .{}, "duplicate profilePackages entry \"{s}\"", .{profile.profile});
        }
        const record = lock.profileRecord(profile.profile);
        if (record == null) {
            try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, profile_path, .{}, "unknown profile \"{s}\"", .{profile.profile});
        }
        // `packages` は選択された `input.profile` のグラフの正本である。
        // profilePackages に同じ profile がある場合は一致を要求する。
        if (record != null and std.mem.eql(u8, profile.profile, lock.input.profile) and !packageMapsEql(lock.packages, profile.packages)) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, profile_path, .{}, "profilePackages.{s} does not match packages", .{profile.profile});
        }
        try validatePackageSet(profile.packages, &profile_id_set, if (record) |value| value.* else null, profile_path, diagnostics);
    }

    // 複数 profile 形式では `profiles` と `profilePackages` の名前集合が一致
    // しなければならない（片方向の欠落を許すと既存版取得や差分が空になる）。
    // 欠落は直前の集合一致検査と同じ E029 に統一する。`input.profile` 自体が
    // 未定義の場合は上の profileRecord 検査が E030 を報告する。
    // 単一 profile 形式（profilePackages が空）はこの制約の対象外。
    if (lock.profile_packages.len > 0) {
        for (lock.profiles) |profile| {
            var found = false;
            for (lock.profile_packages) |entry| {
                if (std.mem.eql(u8, entry.profile, profile.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.profilePackages", .{}, "profilePackages is missing profile \"{s}\"", .{profile.name});
            }
        }
    }

    // lnako/cnako が共用する同一 ID・版の source artifact は同じ hash で
    // 参照しなければならない。
    if (sharedArtifactMismatch(lock)) |mismatch| {
        try diagnostics.addFmt(diag.E009_HASH_MISMATCH, .err, "nako.lock.profilePackages", .{}, "source artifact hash differs across profiles for {s}@{s}", .{ mismatch.id, mismatch.version });
    }
}

// ---------------------------------------------------------------------------
// 鮮度判定・resolver 互換性
// ---------------------------------------------------------------------------

pub const Freshness = enum {
    fresh,
    missing,
    stale_schema,
    stale_resolver,
    stale_manifest,
    stale_profile,
    stale_features,
    stale_target,
};

/// 既存 lock と現在の入力条件を比較し、再解決が必要かを判定する。
/// manifest 変更は依存宣言変更を含むため再解決契機となる。path ソース本文の
/// 編集は root manifest の SHA-256 を変えないため、ここでは stale にならない。
pub fn checkFreshness(existing: ?*const Lock, current: Input) Freshness {
    const lock = existing orelse return .missing;
    if (lock.schema_version != lock_schema_version) return .stale_schema;
    if (lock.resolver_version != resolver_version) return .stale_resolver;
    if (!std.mem.eql(u8, lock.input.manifest_sha256, current.manifest_sha256)) return .stale_manifest;
    if (!std.mem.eql(u8, lock.input.profile, current.profile)) return .stale_profile;
    if (!Input.sameFeatures(lock.input, current)) return .stale_features;
    if (!Target.eql(lock.input.target, current.target)) return .stale_target;
    // 解決 runtime・engines 照合 version も鮮度鍵。`--runtime` 切替や
    // コンパイラ更新は engines 照合結果・package 選択を変え得るため、
    // 記録と一致しなければ stale として再解決する（未記録の旧 lock も
    // null ≠ 値で不一致になる）。
    if (!model.optEql(lock.input.runtime, current.runtime) or
        !model.optEql(lock.input.nako_version, current.nako_version) or
        !model.optEql(lock.input.cnako_version, current.cnako_version) or
        !model.optEql(lock.input.lnako_version, current.lnako_version)) return .stale_target;
    return .fresh;
}

/// `--locked` 時の契約。lock 不足・未知 schema・resolver 不一致・陳腐化は
/// 無変更で失敗させる（`error.LockedNotSatisfied`）。
///
/// これは入力メタデータ（`manifestSha256`・`profile`・`features`・`target`）の
/// 鮮度のみを判定し、`validate` の意味検証は含まない。呼出し側は意味検証を
/// 先に行うこと。manifest 変更は全 profile に影響する `manifestSha256` の
/// 変化として、別 profile の選択は `input.profile` の変化として検出する。
pub const LockedError = error{LockedNotSatisfied};

pub fn requireFresh(existing: ?*const Lock, current: Input) LockedError!void {
    if (checkFreshness(existing, current) != .fresh) return error.LockedNotSatisfied;
}

// ---------------------------------------------------------------------------
// 既存版優先・部分更新
// ---------------------------------------------------------------------------

/// 既存 lock の版優先インデックス。`update_targets` に一致した package だけ
/// 優先固定を解除し、それ以外は既存版を候補として固定する。
pub const LockedIndex = struct {
    arena: std.heap.ArenaAllocator,
    versions: std.StringHashMapUnmanaged(resolver.Version) = .empty,
    unlocked: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *LockedIndex) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// resolver の `Provider.lockedVersion` から呼ぶ。`id.pkg` のみ対象。
    pub fn get(self: *const LockedIndex, id: resolver.PackageId) ?resolver.Version {
        const name = switch (id) {
            .pkg => |value| value,
            .npm => return null,
        };
        return self.versions.get(name);
    }

    pub fn isUnlocked(self: *const LockedIndex, name: []const u8) bool {
        return self.unlocked.contains(name);
    }
};

/// 更新対象名（package id または name）が `targets` に含まれるか。
fn isUpdateTarget(entry: PackageEntry, targets: []const []const u8) bool {
    for (targets) |target| {
        if (std.mem.eql(u8, target, entry.id) or std.mem.eql(u8, target, entry.name)) return true;
    }
    return false;
}

/// 既存 lock の package 版を優先固定するインデックスを作る。`update_targets`
/// が空なら全 package を固定し、指定があれば一致した package だけ解除する。
/// 解決対象 profile のグラフを使い、`id` と `name` の両方で引けるようにする
/// （resolver は manifest 上の package 名で `lockedVersion` を問い合わせる）。
pub fn buildLockedIndex(gpa: Allocator, existing: ?*const Lock, profile: []const u8, update_targets: []const []const u8) !LockedIndex {
    var index = LockedIndex{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer index.arena.deinit();
    // allocator は index.arena 自身を指す。ローカル arena の snapshot を
    // 先に取ると deinit が確保分を解放できないため、必ず index.arena から作る。
    const allocator = index.arena.allocator();
    const lock = existing orelse return index;
    // profilePackages に無い profile へは他 profile の版を流用しない。
    const packages = lock.packagesForProfile(profile) orelse return index;

    for (packages) |entry| {
        if (isUpdateTarget(entry, update_targets)) {
            try index.unlocked.put(allocator, try allocator.dupe(u8, entry.id), {});
            try index.unlocked.put(allocator, try allocator.dupe(u8, entry.name), {});
            continue;
        }
        // semver.Version は prerelease/build を入力文字列から借用するため、
        // index の arena に複製した文字列を解析して所有権を index に閉じる。
        const version_text = try allocator.dupe(u8, entry.version);
        const version = resolver.Version.parse(version_text) catch return error.InvalidLockVersion;
        try index.versions.put(allocator, try allocator.dupe(u8, entry.id), version);
        if (!std.mem.eql(u8, entry.name, entry.id)) {
            try index.versions.put(allocator, try allocator.dupe(u8, entry.name), version);
        }
    }
    return index;
}

// ---------------------------------------------------------------------------
// 部分更新の差分と理由
// ---------------------------------------------------------------------------

pub const ChangeReason = enum {
    unchanged,
    added,
    removed,
    updated_direct,
    updated_indirect,
};

pub const Change = struct {
    id: []const u8,
    name: []const u8,
    reason: ChangeReason,
    from_version: ?[]const u8 = null,
    to_version: ?[]const u8 = null,
    /// この変更を必要とした変更元 package id（昇順）。空なら直接対象または新規。
    caused_by: []const []const u8 = &.{},

    pub fn isChanged(self: Change) bool {
        return self.reason != .unchanged;
    }
};

pub const UpdateReport = struct {
    arena: std.heap.ArenaAllocator,
    changes: []const Change = &.{},

    pub fn deinit(self: *UpdateReport) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn significantCount(self: *const UpdateReport) usize {
        var count: usize = 0;
        for (self.changes) |change| {
            if (change.isChanged()) count += 1;
        }
        return count;
    }

    pub fn find(self: *const UpdateReport, id: []const u8) ?*const Change {
        for (self.changes) |*change| {
            if (std.mem.eql(u8, change.id, id)) return change;
        }
        return null;
    }

    /// 決定的な日本語説明を書き出す。
    pub fn explain(self: *const UpdateReport, writer: *std.Io.Writer) !void {
        for (self.changes) |change| {
            if (!change.isChanged()) continue;
            switch (change.reason) {
                .unchanged => {},
                .added => try writer.print("追加 {s} {s}\n", .{ change.name, change.to_version orelse "" }),
                .removed => try writer.print("削除 {s} {s}\n", .{ change.name, change.from_version orelse "" }),
                .updated_direct => try writer.print("更新(直接指定) {s} {s} -> {s}\n", .{ change.name, change.from_version orelse "", change.to_version orelse "" }),
                .updated_indirect => try writer.print("更新(間接) {s} {s} -> {s}", .{ change.name, change.from_version orelse "", change.to_version orelse "" }),
            }
            if (change.reason == .updated_indirect) {
                try writer.writeAll(" from [");
                for (change.caused_by, 0..) |cause, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(cause);
                }
                try writer.writeAll("]");
                try writer.writeByte('\n');
            }
        }
    }
};

fn collectParentMap(gpa: Allocator, packages: []const PackageEntry, map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8))) !void {
    for (packages) |package| {
        for (package.dependencies) |dependency| {
            const gop = try map.getOrPut(gpa, dependency);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var found = false;
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, package.id)) {
                    found = true;
                    break;
                }
            }
            if (!found) try gop.value_ptr.append(gpa, package.id);
        }
    }
}

fn parentListContains(list: []const []const u8, id: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn packagesOrEmpty(lock: ?*const Lock, profile: []const u8) []const PackageEntry {
    const value = lock orelse return &.{};
    return value.packagesForProfile(profile) orelse &.{};
}

/// 指定 profile の 2 つの lock の差分を取り、部分更新で必要になった変更理由を
/// 説明できる `UpdateReport` を返す。複数 profile を収録した lock では profile
/// ごとに呼び出す。`update_targets` は直接指定された更新対象。
pub fn diff(gpa: Allocator, previous: ?*const Lock, next: *const Lock, profile: []const u8, update_targets: []const []const u8) !UpdateReport {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const previous_packages = packagesOrEmpty(previous, profile);
    const next_packages = next.packagesForProfile(profile) orelse &.{};

    var previous_by_id: std.StringHashMapUnmanaged(PackageEntry) = .empty;
    for (previous_packages) |entry| try previous_by_id.put(allocator, entry.id, entry);
    var next_by_id: std.StringHashMapUnmanaged(PackageEntry) = .empty;
    for (next_packages) |entry| try next_by_id.put(allocator, entry.id, entry);

    var ids: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (next_packages) |entry| {
        if (seen.contains(entry.id)) continue;
        try seen.put(allocator, entry.id, {});
        try ids.append(allocator, entry.id);
    }
    for (previous_packages) |entry| {
        if (seen.contains(entry.id)) continue;
        try seen.put(allocator, entry.id, {});
        try ids.append(allocator, entry.id);
    }
    std.mem.sort([]const u8, ids.items, {}, stringLessThan);

    // 旧グラフと新グラフの親辺は分離して保持する。削除の説明には旧グラフを、
    // 追加・更新の原因探索には更新後も実在する新グラフの辺だけを使い、切れた
    // 経路を原因として誤報告しない。
    var previous_parents: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    try collectParentMap(allocator, previous_packages, &previous_parents);
    var next_parents: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    try collectParentMap(allocator, next_packages, &next_parents);

    var changes: std.ArrayList(Change) = .empty;
    var change_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (ids.items) |id| {
        const old_entry = previous_by_id.get(id);
        const new_entry = next_by_id.get(id);
        if (old_entry == null and new_entry == null) continue;

        var reason: ChangeReason = .unchanged;
        if (old_entry == null) {
            reason = .added;
        } else if (new_entry == null) {
            reason = .removed;
        } else if (!packageEntryEql(old_entry.?, new_entry.?)) {
            // version だけでなく feature 統合・implementation・artifact・依存辺の
            // 変化も lock の内容変化として報告対象にする。
            const direct = isUpdateTarget(old_entry.?, update_targets) or isUpdateTarget(new_entry.?, update_targets);
            reason = if (direct) .updated_direct else .updated_indirect;
        }

        const name = if (new_entry) |entry| entry.name else if (old_entry) |entry| entry.name else id;
        const owned_id = try allocator.dupe(u8, id);
        try change_index.put(allocator, owned_id, changes.items.len);
        try changes.append(allocator, .{
            .id = owned_id,
            .name = try allocator.dupe(u8, name),
            .reason = reason,
            .from_version = if (old_entry) |entry| try allocator.dupe(u8, entry.version) else null,
            .to_version = if (new_entry) |entry| try allocator.dupe(u8, entry.version) else null,
        });
    }

    // 変更理由は直接親だけでなく、未変更の中間 package を越えて祖先まで辿る。
    // 最初に到達した「変更済み」の祖先（直接更新対象を含む）を原因として収集し、
    // 循環・重複に備えて訪問済み集合を使う。
    // レポートは lock の arena に依存せず単独で使えるよう、参照文字列も複製する。
    for (changes.items) |*change| {
        if (change.reason == .unchanged or change.reason == .updated_direct) continue;
        var causes: std.ArrayList([]const u8) = .empty;
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        const parent_map = if (change.reason == .removed) &previous_parents else &next_parents;
        if (parent_map.get(change.id)) |list| {
            for (list.items) |parent| try stack.append(allocator, parent);
        }
        while (stack.pop()) |candidate| {
            if (std.mem.eql(u8, candidate, change.id)) continue;
            const gop = try visited.getOrPut(allocator, candidate);
            if (gop.found_existing) continue;
            gop.value_ptr.* = {};
            const index = change_index.get(candidate) orelse continue;
            if (changes.items[index].reason == .unchanged) {
                // 未変更の中間 package は同じグラフの辺だけをさらに上へ辿る。
                if (parent_map.get(candidate)) |list| {
                    for (list.items) |parent| try stack.append(allocator, parent);
                }
                continue;
            }
            if (!parentListContains(causes.items, candidate)) {
                try causes.append(allocator, try allocator.dupe(u8, candidate));
            }
        }
        std.mem.sort([]const u8, causes.items, {}, stringLessThan);
        change.caused_by = causes.items;
    }

    return .{ .arena = arena, .changes = changes.items };
}

// ---------------------------------------------------------------------------
// resolver 解決結果からの lock 生成
// ---------------------------------------------------------------------------

pub const PackageDetails = struct {
    public_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    source: ?Source = null,
    resolved_from: ?Source = null,
    artifacts: []const Artifact = &.{},
    npm_instances: []const NpmInstance = &.{},
};

/// lock 生成に必要な source/artifact metadata を返す契約。取得 provider (#47)
/// が実装し、lock 層は解決 core から分離する。排他的 profile では同じ Public
/// ID に異なる版を許すため、artifact 選択は `id` だけでなく `version` でも引く。
pub const DetailsSource = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?PackageDetails,

    pub fn get(self: DetailsSource, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?PackageDetails {
        return self.getFn(self.context, gpa, id, version);
    }
};

fn formatPackageId(allocator: Allocator, id: resolver.PackageId) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{id});
}

/// 解決済 node 群から package entry 群を構築する。entry の `id` と
/// `dependencies` は Public ID へ解決して記録する（resolver id と
/// `DetailsSource.public_id` が異なる場合も依存辺を Public ID へ張り替える）。
pub fn buildPackages(allocator: Allocator, nodes: []const resolver.PackageNode, details: DetailsSource) ![]const PackageEntry {
    // 先に resolver id → Public ID の対応と version ごとの details を確定する。
    const Info = struct {
        node: *const resolver.PackageNode,
        id_text: []const u8,
        version_text: []const u8,
        detail: ?PackageDetails,
    };
    var infos: std.ArrayList(Info) = .empty;
    var public_ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    // 異なる resolver id が同じ Public ID を指すと lock の package map が
    // 重複キーになり再解析できないため、衝突は明示エラーにする。
    var public_owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (nodes) |*node| {
        const id_text = try formatPackageId(allocator, node.id);
        const version_text = try std.fmt.allocPrint(allocator, "{f}", .{node.version});
        const detail = try details.get(allocator, id_text, version_text);
        const public_id = if (detail) |value| if (value.public_id) |value_id| try allocator.dupe(u8, value_id) else id_text else id_text;
        if (public_owners.get(public_id)) |owner| {
            if (!std.mem.eql(u8, owner, id_text)) return error.DuplicatePublicId;
        } else {
            try public_owners.put(allocator, public_id, id_text);
        }
        try public_ids.put(allocator, id_text, public_id);
        try infos.append(allocator, .{
            .node = node,
            .id_text = id_text,
            .version_text = version_text,
            .detail = detail,
        });
    }

    var list: std.ArrayList(PackageEntry) = .empty;
    for (infos.items) |info| {
        var dependencies: std.ArrayList([]const u8) = .empty;
        for (info.node.dependencies) |dependency| {
            const dep_text = try formatPackageId(allocator, dependency);
            try dependencies.append(allocator, public_ids.get(dep_text) orelse dep_text);
        }
        std.mem.sort([]const u8, dependencies.items, {}, stringLessThan);

        const public_id = public_ids.get(info.id_text).?;
        var entry = PackageEntry{
            .id = public_id,
            .name = if (info.detail) |value| if (value.name) |name| try allocator.dupe(u8, name) else public_id else public_id,
            .version = info.version_text,
            .dependencies = dependencies.items,
            .features = try canonicalFeatures(allocator, info.node.features),
            .implementation = implementationName(info.node.implementation),
        };
        if (info.detail) |value| {
            entry.source = if (value.source) |source| try dupSourceOwned(allocator, source) else null;
            entry.resolved_from = if (value.resolved_from) |source| try dupSourceOwned(allocator, source) else null;
            entry.artifacts = try sortedArtifacts(allocator, value.artifacts);
            entry.npm_instances = try sortedNpmInstances(allocator, value.npm_instances);
        }
        try list.append(allocator, entry);
    }
    std.mem.sort(PackageEntry, list.items, {}, packageLessThan);
    return list.items;
}

/// resolver の実装選択を lock 表記（artifact kind と揃えた `ESM`）へ変換する。
fn implementationName(implementation: resolver.Impl) []const u8 {
    return switch (implementation) {
        .none => "none",
        .source => "source",
        .native => "native",
        .esm => "ESM",
    };
}

/// `Source` の全文字列を `allocator` へ複製する。path 依存は可変参照が既定
/// のため、`mutable` 未指定なら true を補う。
fn dupSourceOwned(allocator: Allocator, source: Source) !Source {
    return .{
        .kind = source.kind,
        .url = if (source.url) |value| try allocator.dupe(u8, value) else null,
        .hash = if (source.hash) |value| try allocator.dupe(u8, value) else null,
        .commit = if (source.commit) |value| try allocator.dupe(u8, value) else null,
        .path = if (source.path) |value| try allocator.dupe(u8, value) else null,
        .mutable = if (source.kind == .path) source.mutable orelse true else source.mutable,
    };
}

fn dupArtifact(allocator: Allocator, artifact: Artifact) !Artifact {
    return .{
        .key = try allocator.dupe(u8, artifact.key),
        .kind = try allocator.dupe(u8, artifact.kind),
        .type = if (artifact.type) |value| try allocator.dupe(u8, value) else null,
        .sha256 = if (artifact.sha256) |value| try allocator.dupe(u8, value) else null,
        .url = if (artifact.url) |value| try allocator.dupe(u8, value) else null,
    };
}

fn dupPeerDependency(allocator: Allocator, peer: PeerDependency) !PeerDependency {
    return .{
        .name = try allocator.dupe(u8, peer.name),
        .requirement = try allocator.dupe(u8, peer.requirement),
    };
}

fn dupNpmInstance(allocator: Allocator, instance: NpmInstance) !NpmInstance {
    const peers = try allocator.alloc(PeerDependency, instance.peer_dependencies.len);
    for (instance.peer_dependencies, 0..) |peer, index| {
        peers[index] = try dupPeerDependency(allocator, peer);
    }
    std.mem.sort(PeerDependency, peers, {}, struct {
        fn lt(_: void, a: PeerDependency, b: PeerDependency) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return .{
        .key = try allocator.dupe(u8, instance.key),
        .name = try allocator.dupe(u8, instance.name),
        .version = try allocator.dupe(u8, instance.version),
        .context = if (instance.context) |value| try allocator.dupe(u8, value) else null,
        .sha256 = if (instance.sha256) |value| try allocator.dupe(u8, value) else null,
        .url = if (instance.url) |value| try allocator.dupe(u8, value) else null,
        .peer_dependencies = peers,
    };
}

fn sortedArtifacts(allocator: Allocator, items: []const Artifact) ![]const Artifact {
    const out = try allocator.alloc(Artifact, items.len);
    for (items, 0..) |item, index| out[index] = try dupArtifact(allocator, item);
    std.mem.sort(Artifact, out, {}, struct {
        fn lt(_: void, a: Artifact, b: Artifact) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return out;
}

fn sortedNpmInstances(allocator: Allocator, items: []const NpmInstance) ![]const NpmInstance {
    const out = try allocator.alloc(NpmInstance, items.len);
    for (items, 0..) |item, index| out[index] = try dupNpmInstance(allocator, item);
    std.mem.sort(NpmInstance, out, {}, struct {
        fn lt(_: void, a: NpmInstance, b: NpmInstance) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return out;
}

/// 単一 profile の lock を構築する。`profiles` は収録する profile 条件。
pub fn build(gpa: Allocator, input: Input, profiles: []const NamedProfile, nodes: []const resolver.PackageNode, details: DetailsSource) !Lock {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const owned_input = Input{
        .manifest_sha256 = try allocator.dupe(u8, input.manifest_sha256),
        .profile = try allocator.dupe(u8, input.profile),
        .features = try canonicalFeatures(allocator, input.features),
        .target = .{
            .os = try allocator.dupe(u8, input.target.os),
            .cpu = try allocator.dupe(u8, input.target.cpu),
            .abi = try allocator.dupe(u8, input.target.abi),
            .compat_js = input.target.compat_js,
            .optimize = try allocator.dupe(u8, input.target.optimize),
        },
        .runtime = try dupeOpt(allocator, input.runtime),
        .nako_version = try dupeOpt(allocator, input.nako_version),
        .cnako_version = try dupeOpt(allocator, input.cnako_version),
        .lnako_version = try dupeOpt(allocator, input.lnako_version),
        .mutable_paths = try canonicalMutablePaths(allocator, input.mutable_paths),
    };

    var owned_profiles: std.ArrayList(NamedProfile) = .empty;
    for (profiles) |profile| {
        try owned_profiles.append(allocator, .{
            .name = try allocator.dupe(u8, profile.name),
            .record = try dupProfile(allocator, profile.record),
        });
    }
    std.mem.sort(NamedProfile, owned_profiles.items, {}, namedProfileLessThan);

    const packages = try buildPackages(allocator, nodes, details);

    return .{
        .arena = arena,
        .input = owned_input,
        .packages = packages,
        .profiles = owned_profiles.items,
    };
}

/// 複数 profile の解決結果を一つの lock に集約する。`primary` は
/// `input.profile` の package グラフ、`per_profile` は全 profile の解決結果。
pub fn buildMulti(
    gpa: Allocator,
    input: Input,
    profiles: []const NamedProfile,
    per_profile: []const ProfileInput,
    details: DetailsSource,
) !Lock {
    // `input.profile` の解決結果がちょうど1つ必要。欠落・重複は生成物が
    // 選択済みグラフを失うか重複するため、生成前に拒否する。
    var primary_count: usize = 0;
    for (per_profile) |profile_input| {
        if (std.mem.eql(u8, profile_input.profile, input.profile)) primary_count += 1;
    }
    if (primary_count != 1) return error.InvalidPrimaryProfile;

    // `profiles` と `per_profile` の名前集合は一対一で一致しなければならない。
    // 重複名は profilePackages の重複キーを、欠落・未知は宣言との不整合を招く。
    for (profiles, 0..) |profile, index| {
        for (profiles[index + 1 ..]) |other| {
            if (std.mem.eql(u8, profile.name, other.name)) return error.InvalidProfileSet;
        }
    }
    for (per_profile, 0..) |profile_input, index| {
        var declared = false;
        for (profiles) |profile| {
            if (std.mem.eql(u8, profile.name, profile_input.profile)) declared = true;
        }
        if (!declared) return error.InvalidProfileSet;
        for (per_profile[index + 1 ..]) |other| {
            if (std.mem.eql(u8, profile_input.profile, other.profile)) return error.InvalidProfileSet;
        }
    }
    if (per_profile.len != profiles.len) return error.InvalidProfileSet;

    var lock = try build(gpa, input, profiles, &.{}, details);
    errdefer lock.deinit();
    const allocator = lock.arena.allocator();

    var profile_packages: std.ArrayList(ProfilePackages) = .empty;
    for (per_profile) |profile_input| {
        const packages = try buildPackages(allocator, profile_input.nodes, details);
        try profile_packages.append(allocator, .{
            .profile = try allocator.dupe(u8, profile_input.profile),
            .packages = packages,
        });
        if (std.mem.eql(u8, profile_input.profile, input.profile)) lock.packages = packages;
    }
    std.mem.sort(ProfilePackages, profile_packages.items, {}, profilePackageLessThan);
    lock.profile_packages = profile_packages.items;
    return lock;
}

pub const ProfileInput = struct {
    profile: []const u8,
    nodes: []const resolver.PackageNode,
};

/// mutable path digest を複製し、path 昇順ソートと重複除去を行う。
/// 同じ依存集合から常に同じ lock バイト列を得るための正規化。
fn canonicalMutablePaths(allocator: Allocator, items: []const model.MutablePath) ![]const model.MutablePath {
    const out = try allocator.alloc(model.MutablePath, items.len);
    for (items, 0..) |item, index| {
        out[index] = .{
            .path = try allocator.dupe(u8, item.path),
            .sha256 = try allocator.dupe(u8, item.sha256),
        };
    }
    std.mem.sort(model.MutablePath, out, {}, struct {
        fn lt(_: void, a: model.MutablePath, b: model.MutablePath) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    var unique_len: usize = 0;
    for (out) |item| {
        if (unique_len > 0 and std.mem.eql(u8, out[unique_len - 1].path, item.path)) continue;
        out[unique_len] = item;
        unique_len += 1;
    }
    return out[0..unique_len];
}

/// feature 名を複製し、昇順ソートと重複除去を行う。同じ feature 集合から
/// 常に同じ lock バイト列を得るための正規化。
fn canonicalFeatures(allocator: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| out[index] = try allocator.dupe(u8, item);
    std.mem.sort([]const u8, out, {}, stringLessThan);
    var unique_len: usize = 0;
    for (out) |item| {
        if (unique_len > 0 and std.mem.eql(u8, out[unique_len - 1], item)) continue;
        out[unique_len] = item;
        unique_len += 1;
    }
    return out[0..unique_len];
}

fn dupeOpt(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn dupProfile(allocator: Allocator, record: ProfileRecord) !ProfileRecord {
    return .{
        .runtime = if (record.runtime) |value| try allocator.dupe(u8, value) else null,
        .os = try allocator.dupe(u8, record.os),
        .cpu = try allocator.dupe(u8, record.cpu),
        .abi = try allocator.dupe(u8, record.abi),
        .compat_js = record.compat_js,
        .optimize = if (record.optimize) |value| try allocator.dupe(u8, value) else null,
    };
}

// ---------------------------------------------------------------------------
// 複数 profile の共用 artifact 整合性
// ---------------------------------------------------------------------------

test {
    _ = @import("lock_test.zig");
}
