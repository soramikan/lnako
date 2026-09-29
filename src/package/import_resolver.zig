//! Lock-bound source package import lookup shared by the compiler entry points.
const std = @import("std");
const module_graph = @import("../semantic/module_graph.zig");
const npkg_files = @import("npkg_files.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const native_store = @import("native_store.zig");
const diag = @import("diagnostics.zig");
const semver = @import("semver.zig");
const project_discovery = @import("project_discovery.zig");
const project_trust = @import("project_trust.zig");

const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

pub fn realPathDirAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var directory = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

/// Find the environment matching the nearest trusted project manifest.
pub fn findProjectRoot(allocator: Allocator, io: std.Io, input_path: []const u8) !?[]u8 {
    return project_discovery.findProjectRoot(allocator, io, input_path);
}

pub const Error = error{
    NoEnvironment,
    InvalidEnvironment,
    PackageNotFound,
    ExportNotFound,
    AmbiguousExport,
    UnsafeExportPath,
};

pub const Resolver = struct {
    io: std.Io,
    project_root: []const u8,
    parsed: std.json.Parsed(Value),
    owned: std.heap.ArenaAllocator,

    pub fn load(allocator: Allocator, io: std.Io, project_root: []const u8) !Resolver {
        var owned = std.heap.ArenaAllocator.init(allocator);
        errdefer owned.deinit();
        const storage = owned.allocator();
        const root = try realPathDirAlloc(storage, io, project_root);
        const env_path = try std.fs.path.join(storage, &.{ root, ".nako", "environment.json" });
        const lock_path = try std.fs.path.join(storage, &.{ root, "nako.lock" });
        const env_bytes = std.Io.Dir.cwd().readFileAlloc(io, env_path, storage, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.NoEnvironment,
            else => return err,
        };
        const lock_bytes = std.Io.Dir.cwd().readFileAlloc(io, lock_path, storage, .limited(64 * 1024 * 1024)) catch return error.InvalidEnvironment;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
        const parsed = std.json.parseFromSlice(Value, storage, env_bytes, .{}) catch return error.InvalidEnvironment;
        const root_object = asObject(parsed.value) orelse {
            parsed.deinit();
            return error.InvalidEnvironment;
        };
        const schema = get(root_object, "schemaVersion") orelse {
            parsed.deinit();
            return error.InvalidEnvironment;
        };
        const lock_sha = get(root_object, "lockSha256") orelse {
            parsed.deinit();
            return error.InvalidEnvironment;
        };
        const packages = get(root_object, "packages") orelse {
            parsed.deinit();
            return error.InvalidEnvironment;
        };
        var declared_digest: [32]u8 = undefined;
        if (schema != .integer or schema.integer != 1 or lock_sha != .string or
            !lock_model.normalizeSha256(lock_sha.string, &declared_digest) or
            !std.mem.eql(u8, &declared_digest, &digest) or packages != .object)
        {
            parsed.deinit();
            return error.InvalidEnvironment;
        }
        try validateEnvironmentLockBinding(storage, io, root, root_object, lock_bytes);
        return .{ .io = io, .project_root = root, .parsed = parsed, .owned = owned };
    }

    pub fn deinit(self: *Resolver) void {
        // Parsed was allocated from `owned`'s arena allocator. Releasing the
        // parent arena reclaims both the parsed JSON arena and its backing bytes.
        self.owned.deinit();
        self.* = undefined;
    }

    pub fn packageResolver(self: *Resolver) module_graph.PackageResolver {
        return .{ .context = self, .resolveFn = resolveCallback };
    }

    fn resolveCallback(context: *anyopaque, allocator: Allocator, importer: []const u8, specifier: []const u8) anyerror!module_graph.ResolvedPackageImport {
        const self: *Resolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, importer, specifier);
    }

    pub fn resolve(self: *Resolver, allocator: Allocator, importer: []const u8, specifier: []const u8) !module_graph.ResolvedPackageImport {
        var temporary_arena = std.heap.ArenaAllocator.init(allocator);
        defer temporary_arena.deinit();
        const temporary = temporary_arena.allocator();
        const reference = if (std.mem.startsWith(u8, specifier, "パッケージ:"))
            specifier["パッケージ:".len..]
        else if (std.mem.startsWith(u8, specifier, "pkg:"))
            specifier["pkg:".len..]
        else
            return error.PackageNotFound;
        if (reference.len == 0) return error.PackageNotFound;

        const root_object = asObject(self.parsed.value) orelse return error.InvalidEnvironment;
        const packages = asObject(get(root_object, "packages") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const canonical_importer = try std.Io.Dir.cwd().realPathFileAlloc(self.io, importer, temporary);
        var owner_key: ?[]const u8 = null;
        const scope_dependencies = if (try self.packageForImporter(temporary, packages, canonical_importer, &owner_key)) |owner|
            get(asObject(owner) orelse return error.InvalidEnvironment, "dependencies")
        else
            get(root_object, "dependencies");
        const dependency_array = if (scope_dependencies) |value| asArray(value) orelse return error.InvalidEnvironment else return error.PackageNotFound;

        // Dependency table keys may themselves contain slashes (for example
        // owner/name). Prefer the longest registered alias prefix so such a key
        // remains addressable without stealing a longer alias for a subpath.
        var selected_alias: ?[]const u8 = null;
        var selected_subpath: ?[]const u8 = null;
        var selected_key: ?[]const u8 = null;
        for (dependency_array.items) |dependency| {
            const dependency_object = asObject(dependency) orelse return error.InvalidEnvironment;
            const dependency_alias = get(dependency_object, "alias") orelse return error.InvalidEnvironment;
            const package_key = get(dependency_object, "package") orelse return error.InvalidEnvironment;
            if (dependency_alias != .string or package_key != .string) return error.InvalidEnvironment;
            const candidate_alias = dependency_alias.string;
            // 空 alias・正規化後に空になる alias（`@` 単体等）は公開
            // namespace を構成できず、plugin 登録名が不定になる環境記録は
            // 改ざん・破損として fail closed で拒否する。
            if (candidate_alias.len == 0 or try hasEmptyNamespace(temporary, candidate_alias)) return error.InvalidEnvironment;

            const candidate_subpath: ?[]const u8 = if (std.mem.eql(u8, reference, candidate_alias))
                null
            else if (reference.len > candidate_alias.len and
                std.mem.startsWith(u8, reference, candidate_alias) and reference[candidate_alias.len] == '/')
                reference[candidate_alias.len + 1 ..]
            else
                continue;
            if (candidate_subpath) |subpath| {
                // `@` を含む公開名（`api@v1` 等）は合法な export/subpath 名。
                // version 指定 `pkg:lib@1.0.0` は alias 直後が `/` でない時点で
                // 上の alias 照合で既に不一致になるため、ここで `@` を拒否する
                // 必要はない。canonical 規則（`..`・絶対path等）のみ検査する。
                if (!npkg_files.isCanonicalPath(subpath)) continue;
            }
            if (selected_alias) |previous_alias| {
                if (candidate_alias.len < previous_alias.len) continue;
                if (candidate_alias.len == previous_alias.len) {
                    if (!std.mem.eql(u8, previous_alias, candidate_alias) or
                        !std.mem.eql(u8, selected_key.?, package_key.string)) return error.PackageNotFound;
                    continue;
                }
            }
            selected_alias = candidate_alias;
            selected_subpath = candidate_subpath;
            selected_key = package_key.string;
        }
        const alias = selected_alias orelse return error.PackageNotFound;
        const subpath = selected_subpath;
        const package_key = selected_key.?;
        const package_value = packages.get(package_key) orelse return error.PackageNotFound;
        const package = asObject(package_value) orelse return error.InvalidEnvironment;
        const package_root_value = get(package, "path") orelse return error.InvalidEnvironment;
        if (package_root_value != .string) return error.InvalidEnvironment;
        const package_root_path = if (std.fs.path.isAbsolute(package_root_value.string))
            try temporary.dupe(u8, package_root_value.string)
        else
            try std.fs.path.resolve(temporary, &.{ self.project_root, package_root_value.string });
        const package_root = try realPathDirAlloc(temporary, self.io, package_root_path);

        const exports_value = get(package, "exports") orelse return error.ExportNotFound;
        const exports = asArray(exports_value) orelse return error.InvalidEnvironment;
        const selected_export = try selectExport(exports.items, subpath);
        const export_object = asObject(selected_export) orelse return error.InvalidEnvironment;
        const export_path_value = get(export_object, "path") orelse return error.InvalidEnvironment;
        if (export_path_value != .string or !npkg_files.isCanonicalPath(export_path_value.string)) return error.UnsafeExportPath;
        const joined = try std.fs.path.join(temporary, &.{ package_root, export_path_value.string });
        const lexical = try std.fs.path.resolve(temporary, &.{joined});
        if (!isWithin(package_root, lexical)) return error.UnsafeExportPath;
        const actual_export = try std.Io.Dir.cwd().realPathFileAlloc(self.io, lexical, temporary);
        if (!isWithin(package_root, actual_export)) return error.UnsafeExportPath;
        const extension = std.fs.path.extension(actual_export);
        if (!isSourceOrPluginExtension(extension)) return error.ExportNotFound;
        const export_name = get(export_object, "name") orelse return error.InvalidEnvironment;
        if (export_name != .string) return error.InvalidEnvironment;
        const canonical_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ package_key, export_name.string });
        errdefer allocator.free(canonical_id);
        const namespace = try namespaceFor(allocator, alias, subpath);
        errdefer allocator.free(namespace);
        // package内scopeの依存importはruntime登録名を所有者keyで修飾する。
        // 別packageのscopeで同じaliasが使われても plugin 登録名
        // （`{owner}__{alias}__{命令}`）が衝突しない。
        const dispatch_namespace: ?[]const u8 = if (owner_key) |key| blk: {
            const scoped_alias = try std.fmt.allocPrint(temporary, "{s}__{s}", .{ key, alias });
            break :blk try namespaceFor(allocator, scoped_alias, subpath);
        } else null;
        errdefer if (dispatch_namespace) |dispatch| allocator.free(dispatch);
        const selected_path = try allocator.dupe(u8, actual_export);
        errdefer allocator.free(selected_path);
        const resolved_package_root = try allocator.dupe(u8, package_root);
        errdefer allocator.free(resolved_package_root);
        return .{ .path = selected_path, .canonical_id = canonical_id, .namespace = namespace, .dispatch_namespace = dispatch_namespace, .package_root = resolved_package_root };
    }

    fn packageForImporter(self: *Resolver, allocator: Allocator, packages: std.json.ObjectMap, importer: []const u8, owner_key: ?*?[]const u8) !?Value {
        var selected: ?Value = null;
        var selected_key: ?[]const u8 = null;
        var selected_root_len: usize = 0;
        var package_map = packages;
        var iterator = package_map.iterator();
        while (iterator.next()) |entry| {
            const object = asObject(entry.value_ptr.*) orelse return error.InvalidEnvironment;
            const path_value = get(object, "path") orelse return error.InvalidEnvironment;
            if (path_value != .string) return error.InvalidEnvironment;
            const root_path = if (std.fs.path.isAbsolute(path_value.string))
                try allocator.dupe(u8, path_value.string)
            else
                try std.fs.path.resolve(allocator, &.{ self.project_root, path_value.string });
            const root = realPathDirAlloc(allocator, self.io, root_path) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            const importer_is_project_source = isWithin(self.project_root, importer);
            const package_is_project_local = isWithin(self.project_root, root) and root.len > self.project_root.len;
            // First keep project-owned source in the root dependency scope. Only
            // environment package roots nested inside the project may override it;
            // an ancestor path dependency (for example /repo for /repo/examples)
            // must not claim the project's own entry file.
            if (importer_is_project_source and !package_is_project_local) continue;
            if (isWithin(root, importer) and root.len > selected_root_len) {
                selected = entry.value_ptr.*;
                selected_key = entry.key_ptr.*;
                selected_root_len = root.len;
            }
        }
        if (owner_key) |key_out| key_out.* = selected_key;
        return selected;
    }
};

fn validateEnvironmentLockBinding(allocator: Allocator, io: std.Io, project_root: []const u8, environment: std.json.ObjectMap, lock_bytes: []const u8) !void {
    const profile_value = get(environment, "profile") orelse return error.InvalidEnvironment;
    if (profile_value != .string) return error.InvalidEnvironment;
    const environment_packages_value = get(environment, "packages") orelse return error.InvalidEnvironment;
    const environment_packages = asObject(environment_packages_value) orelse return error.InvalidEnvironment;

    const parsed_lock = std.json.parseFromSlice(Value, allocator, lock_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    defer parsed_lock.deinit();
    const lock_root = asObject(parsed_lock.value) orelse return error.InvalidEnvironment;
    const schema_value = get(lock_root, "schemaVersion") orelse return error.InvalidEnvironment;
    if (schema_value != .integer or (schema_value.integer != 1 and schema_value.integer != 2)) return error.InvalidEnvironment;
    const lock_input = asObject(get(lock_root, "input") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
    const input_profile = get(lock_input, "profile") orelse return error.InvalidEnvironment;
    if (input_profile != .string) return error.InvalidEnvironment;

    const locked_packages_value = if (get(lock_root, "profilePackages")) |profile_maps_value| blk: {
        const profile_maps = asObject(profile_maps_value) orelse return error.InvalidEnvironment;
        if (profile_maps.get(profile_value.string)) |selected| break :blk selected;
        break :blk if (std.mem.eql(u8, profile_value.string, input_profile.string))
            get(lock_root, "packages") orelse return error.InvalidEnvironment
        else
            return error.InvalidEnvironment;
    } else blk: {
        if (!std.mem.eql(u8, profile_value.string, input_profile.string)) return error.InvalidEnvironment;
        break :blk get(lock_root, "packages") orelse return error.InvalidEnvironment;
    };
    const locked_packages = asObject(locked_packages_value) orelse return error.InvalidEnvironment;
    if (objectCount(environment_packages) != objectCount(locked_packages)) return error.InvalidEnvironment;
    var materialized_directories = try expectedMaterializedDirectories(allocator, locked_packages);
    defer materialized_directories.deinit();

    const runtime_value = get(environment, "runtime") orelse return error.InvalidEnvironment;
    if (runtime_value != .string or !std.mem.eql(u8, runtime_value.string, "lnako")) return error.InvalidEnvironment;
    const artifact_target = try artifactTargetForProfile(allocator, lock_root, lock_input, profile_value.string, runtime_value.string);

    var root_dependency_ids: ?std.json.Array = null;
    if (schema_value.integer == 2) {
        const root_dependencies = asObject(get(lock_root, "rootDependencies") orelse return error.InvalidEnvironment) orelse return error.InvalidEnvironment;
        const selected_roots = get(root_dependencies, profile_value.string) orelse return error.InvalidEnvironment;
        root_dependency_ids = asArray(selected_roots) orelse return error.InvalidEnvironment;
    }
    try validateRootDependencyBindings(allocator, io, project_root, lock_input, profile_value.string, get(environment, "dependencies"), locked_packages, root_dependency_ids);

    var shared_generation: ?[]const u8 = null;
    var package_iterator = environment_packages.iterator();
    while (package_iterator.next()) |environment_entry| {
        const lock_entry_value = locked_packages.get(environment_entry.key_ptr.*) orelse return error.InvalidEnvironment;
        const lock_entry = asObject(lock_entry_value) orelse return error.InvalidEnvironment;
        const record = asObject(environment_entry.value_ptr.*) orelse return error.InvalidEnvironment;
        const locked_name = get(lock_entry, "name") orelse return error.InvalidEnvironment;
        const locked_version = get(lock_entry, "version") orelse return error.InvalidEnvironment;
        const record_name = get(record, "name") orelse return error.InvalidEnvironment;
        const record_version = get(record, "version") orelse return error.InvalidEnvironment;
        if (locked_name != .string or locked_version != .string or record_name != .string or record_version != .string or
            !std.mem.eql(u8, locked_name.string, record_name.string) or !std.mem.eql(u8, locked_version.string, record_version.string)) return error.InvalidEnvironment;
        if (get(record, "id")) |record_id| {
            if (record_id == .string and !std.mem.eql(u8, record_id.string, environment_entry.key_ptr.*)) return error.InvalidEnvironment;
            if (record_id != .string and record_id != .null) return error.InvalidEnvironment;
        }

        const environment_path = get(record, "path") orelse return error.InvalidEnvironment;
        if (environment_path != .string) return error.InvalidEnvironment;
        const source_value = get(lock_entry, "source") orelse get(lock_entry, "resolvedFrom") orelse return error.InvalidEnvironment;
        const source = asObject(source_value) orelse return error.InvalidEnvironment;
        const source_kind = get(source, "type") orelse return error.InvalidEnvironment;
        if (source_kind != .string) return error.InvalidEnvironment;
        // `mutable = true` の path 依存だけ宣言 dir を生参照する。
        // immutable path は pin 照合済み snapshot を世代内へ複製した path を
        // 記録するため、他の materialized package と同じ世代・境界検証を通す。
        const source_is_mutable_path = std.mem.eql(u8, source_kind.string, "path") and mutable: {
            const mutable_value = get(source, "mutable");
            if (mutable_value) |value| {
                if (value != .bool) return error.InvalidEnvironment;
                break :mutable value.bool;
            }
            break :mutable false;
        };
        const package_root = if (source_is_mutable_path) blk: {
            const declared_path = get(source, "path") orelse return error.InvalidEnvironment;
            if (declared_path != .string or !std.mem.eql(u8, declared_path.string, environment_path.string)) return error.InvalidEnvironment;
            break :blk try actualPackageRoot(allocator, io, project_root, environment_path.string);
        } else blk: {
            const exports_value = get(record, "exports");
            const record_exports = if (exports_value) |value|
                asArray(value) orelse return error.InvalidEnvironment
            else
                std.array_list.Managed(Value).init(allocator);
            defer if (exports_value == null) record_exports.deinit();
            const implementation = requiredString(lock_entry, "implementation");
            // `.nako/native/` を名乗る環境 path は lock 由来の期待 root と
            // 一致する場合に限り native store として検証し、そうでなければ
            // 拒否する（任意 path を native 検証へ通さない）。native export を
            // 公開した package は代表 implementation が source/path でも sync
            // が安定 root を発行するため、env path の prefix で判定する。
            if (std.mem.startsWith(u8, environment_path.string, ".nako/native/")) {
                const expected_native_path = try native_store.expectedRoot(allocator, source, lock_entry) orelse return error.InvalidEnvironment;
                if (!std.mem.eql(u8, environment_path.string, expected_native_path)) return error.InvalidEnvironment;
                break :blk try native_store.validateRoot(allocator, io, project_root, environment_path.string);
            }
            if (record_exports.items.len != 0 and implementation != null and std.mem.eql(u8, implementation.?, "native")) {
                // native 実装の package は sync が常に安定 root を発行する。
                // 世代 path への代替は環境改ざんでしか起きないため拒否する。
                return error.InvalidEnvironment;
            }
            const expected_directory = materialized_directories.get(environment_entry.key_ptr.*) orelse return error.InvalidEnvironment;
            const generation = materializedGeneration(environment_path.string, expected_directory) orelse return error.InvalidEnvironment;
            if (shared_generation) |expected| {
                if (!std.mem.eql(u8, expected, generation)) return error.InvalidEnvironment;
            } else {
                shared_generation = generation;
            }
            break :blk try validateMaterializedRoot(allocator, io, project_root, environment_path.string, generation);
        };
        const exports_value = get(record, "exports");
        const record_exports = if (exports_value) |value|
            asArray(value) orelse return error.InvalidEnvironment
        else
            null;
        if (package_root) |root| {
            // `.nako` 自体がprivateでも、materialized rootまたは配下dirが
            // 共有writableなら export 対象を差し替えて同一 manifest identity
            // を装える。package tree 末端まで書き込み権限を検証する。
            if (try project_trust.hasUnsafeWritableDirectory(allocator, io, root)) return error.InvalidEnvironment;
            try validateEnvironmentExports(allocator, io, root, record, lock_entry, locked_packages, artifact_target, profile_value.string);
        } else if (record_exports) |exports| {
            // A missing materialization is tolerable only for support packages
            // that expose no imports. Exports pointing at absent files would
            // create an environment that validates but cannot resolve imports.
            if (exports.items.len != 0) return error.InvalidEnvironment;
        }

        if (get(record, "dependencies")) |dependencies_value| {
            const dependencies = asArray(dependencies_value) orelse return error.InvalidEnvironment;
            try validateUniqueNamespaceAliases(allocator, dependencies.items);
            const locked_dependencies_value = get(lock_entry, "dependencies") orelse return error.InvalidEnvironment;
            const locked_dependencies = asArray(locked_dependencies_value) orelse return error.InvalidEnvironment;
            for (dependencies.items) |dependency_value| {
                const dependency = asObject(dependency_value) orelse return error.InvalidEnvironment;
                const dependency_package = get(dependency, "package") orelse return error.InvalidEnvironment;
                if (dependency_package != .string or locked_packages.get(dependency_package.string) == null or
                    !arrayContainsString(locked_dependencies, dependency_package.string)) return error.InvalidEnvironment;
            }
        }
    }

    if (get(environment, "dependencies")) |root_dependencies_value| {
        const dependencies = asArray(root_dependencies_value) orelse return error.InvalidEnvironment;
        try validateUniqueNamespaceAliases(allocator, dependencies.items);
        for (dependencies.items) |dependency_value| {
            const dependency = asObject(dependency_value) orelse return error.InvalidEnvironment;
            const package = get(dependency, "package") orelse return error.InvalidEnvironment;
            if (package != .string or locked_packages.get(package.string) == null) return error.InvalidEnvironment;
            if (root_dependency_ids) |allowed| {
                if (!arrayContainsString(allowed, package.string)) return error.InvalidEnvironment;
            }
        }
    }
}

fn expectedMaterializedDirectories(allocator: Allocator, locked_packages: std.json.ObjectMap) !std.StringHashMap([]const u8) {
    var directories = std.StringHashMap([]const u8).init(allocator);
    errdefer directories.deinit();
    var used_names = std.StringHashMap(void).init(allocator);
    defer used_names.deinit();

    const Entry = struct { id: []const u8, value: Value };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var iterator = locked_packages.iterator();
    while (iterator.next()) |entry| try entries.append(allocator, .{ .id = entry.key_ptr.*, .value = entry.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, left: Entry, right: Entry) bool {
            return std.mem.order(u8, left.id, right.id) == .lt;
        }
    }.lessThan);

    for (entries.items) |entry| {
        const lock_entry = asObject(entry.value) orelse return error.InvalidEnvironment;
        const source_value = get(lock_entry, "source") orelse get(lock_entry, "resolvedFrom") orelse return error.InvalidEnvironment;
        const source = asObject(source_value) orelse return error.InvalidEnvironment;
        const kind = get(source, "type") orelse return error.InvalidEnvironment;
        if (kind != .string) return error.InvalidEnvironment;
        // 世代内へ複製するのは `mutable = false` の path 依存も同じ。
        // mutable は宣言 dir を生参照するため deps dir 名を確保しない。
        if (std.mem.eql(u8, kind.string, "path")) {
            const mutable_value = get(source, "mutable");
            const mutable = if (mutable_value) |value| (value == .bool and value.bool) else false;
            if (mutable) continue;
        }

        const name_value = get(lock_entry, "name") orelse return error.InvalidEnvironment;
        if (name_value != .string) return error.InvalidEnvironment;
        const base_name = try sanitizedPackageName(allocator, name_value.string);
        var directory_name = base_name;
        var suffix: u32 = 2;
        while (used_names.contains(directory_name)) : (suffix += 1) {
            directory_name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_name, suffix });
        }
        try used_names.put(directory_name, {});
        try directories.put(entry.id, directory_name);
    }
    return directories;
}

fn artifactTargetForProfile(
    allocator: Allocator,
    lock_root: std.json.ObjectMap,
    lock_input: std.json.ObjectMap,
    profile: []const u8,
    runtime: []const u8,
) !manifest_mod.ArtifactTarget {
    if (!std.mem.eql(u8, runtime, "lnako") and !std.mem.eql(u8, runtime, "cnako")) return error.InvalidEnvironment;
    const input_target = if (get(lock_input, "target")) |value| asObject(value) orelse return error.InvalidEnvironment else null;
    const profiles_value = get(lock_root, "profiles");
    const profile_record = if (profiles_value) |value| blk: {
        const profiles = asObject(value) orelse return error.InvalidEnvironment;
        break :blk if (profiles.get(profile)) |record_value|
            asObject(record_value) orelse return error.InvalidEnvironment
        else
            null;
    } else null;
    // sync の `materializeTarget` と同じ規則: CLI の `--compat-js`/`-O` は
    // lock input の選択 profile にだけ効く。別 profile record の宣言は
    // そのまま使う（input.target へ漏らさない）。
    const input_profile = if (get(lock_input, "profile")) |value|
        if (value == .string) value.string else return error.InvalidEnvironment
    else
        null;
    const is_input_profile = input_profile != null and std.mem.eql(u8, profile, input_profile.?);
    const os = optionalString(profile_record, "os") orelse optionalString(input_target, "os") orelse "";
    const cpu = optionalString(profile_record, "cpu") orelse optionalString(input_target, "cpu") orelse "";
    const abi = optionalString(profile_record, "abi") orelse optionalString(input_target, "abi") orelse "";
    var compat_js = false;
    if (profile_record) |record| {
        if (get(record, "compat-js")) |value| {
            if (value != .bool) return error.InvalidEnvironment;
            compat_js = value.bool;
        }
    }
    // `input.target` の compat-js は lock schema では camelCase の
    // `compatJs` として記録される（kebab の `compat-js` は profile record
    // 側のキー）。sync --compat-js で立てた lock の記録をそのまま復元する。
    if (is_input_profile and input_target != null) {
        if (get(input_target.?, "compatJs")) |value| {
            if (value != .bool) return error.InvalidEnvironment;
            compat_js = compat_js or value.bool;
        }
    }
    const optimize = if (is_input_profile)
        optionalString(input_target, "optimize") orelse "O0"
    else
        optionalString(profile_record, "optimize") orelse "O0";
    // `min-os` 照合に使った OS バージョンは sync の `materializeTarget` と
    // 同じく input target 記録からそのまま復元する。
    const os_version = optionalString(input_target, "osVersion");
    // `version` 条件付き export の marker 評価は sync 側
    // `exportArtifactTarget`（`target.nako_version` を渡す）と同じ値で
    // 行う必要があるため、lock の `input.nakoVersion` を semver で復元する。
    // 記録なしは null（条件不確定＝不適合）、非文字列・解析不能な記録は
    // fail closed で拒否する。
    const nako_version = if (get(lock_input, "nakoVersion")) |value| blk: {
        if (value != .string) return error.InvalidEnvironment;
        break :blk semver.Version.parse(value.string) catch return error.InvalidEnvironment;
    } else null;
    if (profile_record) |record| {
        if (optionalString(record, "runtime")) |declared_runtime| {
            if (!std.mem.eql(u8, declared_runtime, runtime) and
                !std.mem.eql(u8, declared_runtime, "any") and !std.mem.eql(u8, declared_runtime, "common")) return error.InvalidEnvironment;
        }
    }
    _ = allocator;
    return .{ .runtime = runtime, .os = os, .cpu = cpu, .abi = abi, .os_version = os_version, .compat_js = compat_js, .optimize = optimize, .version = nako_version };
}

fn validateEnvironmentExports(
    allocator: Allocator,
    io: std.Io,
    package_root: []const u8,
    record: std.json.ObjectMap,
    lock_entry: std.json.ObjectMap,
    locked_packages: std.json.ObjectMap,
    target: manifest_mod.ArtifactTarget,
    active_profile: []const u8,
) !void {
    const environment_exports_value = get(record, "exports");
    const environment_exports = if (environment_exports_value) |value|
        asArray(value) orelse return error.InvalidEnvironment
    else
        std.array_list.Managed(Value).init(allocator);
    defer if (environment_exports_value == null) environment_exports.deinit();

    // manifest 選択は sync と同じ規則にする。`path` source は宣言 dir の
    // `nako.toml` を使い、残留する生成物 `NAKO-PKG/METADATA.toml` は読まない。
    // materialized `.npkg` artifact 側のみ metadata を優先する。
    const source_kind = blk: {
        const source_value = get(lock_entry, "source") orelse get(lock_entry, "resolvedFrom") orelse break :blk null;
        const source = asObject(source_value) orelse return error.InvalidEnvironment;
        break :blk requiredString(source, "type");
    };
    var manifest = try readPackageManifest(allocator, io, package_root, source_kind == null or !std.mem.eql(u8, source_kind.?, "path"));
    defer if (manifest) |*value| value.deinit();
    const lock_name = requiredString(lock_entry, "name") orelse return error.InvalidEnvironment;
    const lock_version = requiredString(lock_entry, "version") orelse return error.InvalidEnvironment;
    if (manifest) |*value| {
        if (!std.mem.eql(u8, value.package.name, lock_name)) return error.InvalidEnvironment;
        // SemVerは識別子長に上限が無いため、固定bufferへのformatではなく
        // lock側をparseして `same`（build metadata込みの完全等価）で比較する。
        // sync側の manifestMatchesLock と同じ判定規則。
        const locked_version = semver.Version.parse(lock_version) catch return error.InvalidEnvironment;
        if (!value.package.version.same(locked_version)) return error.InvalidEnvironment;
    }

    const implementation = if (get(lock_entry, "implementation")) |value| switch (value) {
        .null => null,
        .string => |text| text,
        else => return error.InvalidEnvironment,
    } else null;
    if (implementation) |kind| {
        if (!std.mem.eql(u8, kind, "source") and !std.mem.eql(u8, kind, "native") and
            !std.mem.eql(u8, kind, "ESM") and !std.mem.eql(u8, kind, "none")) return error.InvalidEnvironment;
    }

    // lock が記録した package 単位の有効 feature を artifact 照合へ反映する。
    // sync 側の `resolveExports` と同じ feature 集合を使わないと、feature
    // 必須の artifact を経由する export が「宣言なし」として不一致になる。
    var package_target = target;
    if (get(lock_entry, "features")) |features_value| {
        const feature_items = asArray(features_value) orelse return error.InvalidEnvironment;
        const feature_names = try allocator.alloc([]const u8, feature_items.items.len);
        for (feature_items.items, 0..) |item, index| {
            if (item != .string) return error.InvalidEnvironment;
            feature_names[index] = item.string;
        }
        package_target.features = feature_names;
    }

    var expected_index: usize = 0;
    var export_provider: ?npkg_commands_gen.DirSourceProvider = null;
    if (manifest) |*value| {
        if (implementation == null or !std.mem.eql(u8, implementation.?, "none")) {
            const prefer_native = if (implementation) |kind| std.mem.eql(u8, kind, "native") else false;
            var diagnostics = diag.List.init(allocator);
            defer diagnostics.deinit();
            for (value.exports) |*export_decl| {
                // 代表実装は各 export の解決結果を縛らない（sync の
                // `resolveExports` と同じ契約）。`native` 選択は
                // `prefer_native` としてのみ効き、source-only export と
                // native export の併記は両方記録される。
                const resolution = try export_decl.resolve(allocator, package_target, prefer_native, &diagnostics) orelse continue;
                if (resolution.kind == .esm and !std.mem.eql(u8, package_target.runtime, "cnako") and !package_target.compat_js) continue;
                if (expected_index >= environment_exports.items.len) return error.InvalidEnvironment;
                const actual = asObject(environment_exports.items[expected_index]) orelse return error.InvalidEnvironment;
                if (!std.mem.eql(u8, requiredString(actual, "name") orelse return error.InvalidEnvironment, export_decl.name) or
                    !std.mem.eql(u8, requiredString(actual, "path") orelse return error.InvalidEnvironment, resolution.target)) return error.InvalidEnvironment;
                if (export_decl.alias) |expected_alias| {
                    if (!std.mem.eql(u8, requiredString(actual, "alias") orelse return error.InvalidEnvironment, expected_alias)) return error.InvalidEnvironment;
                } else if (get(actual, "alias") != null) {
                    return error.InvalidEnvironment;
                }
                // 選択 export の対象 file が package root 境界内に実在することを
                // 確認する。commands.json 経路や native/ESM 宣言はファイル走査を
                // 迂回し得るため、宣言と実体の乖離した環境を受理しない。
                if (export_provider == null) {
                    export_provider = npkg_commands_gen.DirSourceProvider.init(allocator, io, package_root) catch return error.InvalidEnvironment;
                }
                const export_exists = export_provider.?.exists(allocator, resolution.target) catch return error.InvalidEnvironment;
                if (!export_exists) return error.InvalidEnvironment;
                expected_index += 1;
            }
            // 対象targetで解決できないexportをsilent dropしない。宣言された
            // exportがnative条件不適合や非compat-js環境のESM等で選べない
            // packageは環境自体を不適合として拒否する（使用時の
            // ExportNotFoundへ遅延させない）。
            if (diagnostics.errorCount() > 0) return error.InvalidEnvironment;
        }
    }
    if (expected_index != environment_exports.items.len) return error.InvalidEnvironment;
    const locked_dependencies_value = get(lock_entry, "dependencies") orelse return error.InvalidEnvironment;
    const locked_dependencies = asArray(locked_dependencies_value) orelse return error.InvalidEnvironment;
    const parsed_manifest: ?*const manifest_mod.Manifest = if (manifest) |*value| value else null;
    try validateManifestDependencyBindings(allocator, parsed_manifest, get(record, "dependencies"), locked_packages, active_profile, locked_dependencies, false);
}

const DependencyConstraint = union(enum) {
    pkg: manifest_mod.PkgDependency,
    path: manifest_mod.PathDependency,
    git: manifest_mod.GitDependency,
    http: manifest_mod.HttpDependency,
};

const DependencyBinding = struct { alias: []const u8, package_id: []const u8 };

/// `active_profile == null` は「無profile環境の検証」を意味し、profile 要求を
/// 持つ依存は一致しない（fail-closed）。sync.zig 側の同名述語は
/// 「profile 選択なしの sync」と解釈して全一致するため null 意味は対称でない。
fn dependencyMatchesProfile(dependency_profile: ?[]const u8, active_profile: ?[]const u8) bool {
    const required = dependency_profile orelse return true;
    const selected = active_profile orelse return false;
    return std.mem.eql(u8, required, selected);
}

fn validateRootDependencyBindings(
    allocator: Allocator,
    io: std.Io,
    project_root: []const u8,
    lock_input: std.json.ObjectMap,
    active_profile: []const u8,
    environment_value: ?Value,
    locked_packages: std.json.ObjectMap,
    allowed_root_ids: ?std.json.Array,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "nako.toml" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return validateManifestDependencyBindings(allocator, null, environment_value, locked_packages, active_profile, allowed_root_ids, allowed_root_ids == null),
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    const expected_hash = requiredString(lock_input, "manifestSha256") orelse return error.InvalidEnvironment;
    var declared_digest: [32]u8 = undefined;
    var actual_digest: [32]u8 = undefined;
    if (!lock_model.normalizeSha256(expected_hash, &declared_digest)) return error.InvalidEnvironment;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual_digest, .{});
    if (!std.mem.eql(u8, &declared_digest, &actual_digest)) return error.InvalidEnvironment;

    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var manifest = manifest_mod.parse(allocator, bytes, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    defer manifest.deinit();
    if (diagnostics.errorCount() > 0) return error.InvalidEnvironment;
    try validateManifestDependencyBindings(allocator, &manifest, environment_value, locked_packages, active_profile, allowed_root_ids, allowed_root_ids == null);
}

fn validateManifestDependencyBindings(
    allocator: Allocator,
    manifest: ?*const manifest_mod.Manifest,
    environment_value: ?Value,
    locked_packages: std.json.ObjectMap,
    active_profile: ?[]const u8,
    allowed_ids: ?std.json.Array,
    infer_root_ids: bool,
) !void {
    var expected = std.StringHashMap([]const u8).init(allocator);
    defer expected.deinit();
    if (manifest) |value| {
        var pkg_iterator = value.dependencies.pkg.iterator();
        while (pkg_iterator.next()) |item| {
            const dependency = item.value_ptr.*;
            if (!dependencyMatchesProfile(dependency.profile, active_profile)) continue;
            const target = try findManifestDependencyTarget(allocator, locked_packages, allowed_ids, infer_root_ids, dependency.name, .{ .pkg = dependency }, dependency.public_id) orelse continue;
            try appendExpectedBinding(allocator, &expected, dependency.name, target);
            if (dependency.alias) |alias| {
                try appendExpectedBinding(allocator, &expected, alias, target);
            } else {
                const derived = registryNamePart(dependency.name);
                if (!hasDerivedAliasCollision(value, dependency.name, derived, active_profile)) try appendExpectedBinding(allocator, &expected, derived, target);
            }
        }
        var path_iterator = value.dependencies.path.iterator();
        while (path_iterator.next()) |item| {
            const dependency = item.value_ptr.*;
            const target = try findManifestDependencyTarget(allocator, locked_packages, allowed_ids, infer_root_ids, dependency.name, .{ .path = dependency }, null) orelse continue;
            try appendExpectedBinding(allocator, &expected, dependency.name, target);
        }
        var git_iterator = value.dependencies.git.iterator();
        while (git_iterator.next()) |item| {
            const dependency = item.value_ptr.*;
            const target = try findManifestDependencyTarget(allocator, locked_packages, allowed_ids, infer_root_ids, dependency.name, .{ .git = dependency }, null) orelse continue;
            try appendExpectedBinding(allocator, &expected, dependency.name, target);
            if (dependency.alias) |alias| try appendExpectedBinding(allocator, &expected, alias, target);
        }
        var http_iterator = value.dependencies.http.iterator();
        while (http_iterator.next()) |item| {
            const dependency = item.value_ptr.*;
            const target = try findManifestDependencyTarget(allocator, locked_packages, allowed_ids, infer_root_ids, dependency.name, .{ .http = dependency }, null) orelse continue;
            try appendExpectedBinding(allocator, &expected, dependency.name, target);
            if (dependency.alias) |alias| try appendExpectedBinding(allocator, &expected, alias, target);
        }
    }

    const actual = if (environment_value) |value| asArray(value) orelse return error.InvalidEnvironment else std.array_list.Managed(Value).init(allocator);
    defer if (environment_value == null) actual.deinit();
    if (manifest == null) {
        var seen_aliases = std.StringHashMap(void).init(allocator);
        defer seen_aliases.deinit();
        for (actual.items) |entry_value| {
            const entry = asObject(entry_value) orelse return error.InvalidEnvironment;
            const alias = requiredString(entry, "alias") orelse return error.InvalidEnvironment;
            const package_id = requiredString(entry, "package") orelse return error.InvalidEnvironment;
            if (locked_packages.get(package_id) == null or seen_aliases.contains(alias)) return error.InvalidEnvironment;
            if (allowed_ids) |allowed| if (!arrayContainsString(allowed, package_id)) return error.InvalidEnvironment;
            try seen_aliases.put(alias, {});
        }
        return;
    }
    if (actual.items.len != expected.count()) return error.InvalidEnvironment;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (actual.items) |entry_value| {
        const entry = asObject(entry_value) orelse return error.InvalidEnvironment;
        const alias = requiredString(entry, "alias") orelse return error.InvalidEnvironment;
        const package_id = requiredString(entry, "package") orelse return error.InvalidEnvironment;
        const expected_package = expected.get(alias) orelse return error.InvalidEnvironment;
        if (!std.mem.eql(u8, expected_package, package_id) or seen.contains(alias)) return error.InvalidEnvironment;
        try seen.put(alias, {});
    }
}

pub fn findManifestDependencyTarget(
    allocator: Allocator,
    locked_packages: std.json.ObjectMap,
    allowed_ids: ?std.json.Array,
    infer_root_ids: bool,
    name: []const u8,
    constraint: DependencyConstraint,
    public_id: ?[]const u8,
) !?[]const u8 {
    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer matches.deinit(allocator);
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots.deinit(allocator);
    var iterator = locked_packages.iterator();
    while (iterator.next()) |entry| {
        const lock_entry = asObject(entry.value_ptr.*) orelse return error.InvalidEnvironment;
        if (!matchesManifestDependency(entry.key_ptr.*, lock_entry, name, constraint, public_id)) continue;
        try matches.append(allocator, entry.key_ptr.*);
        if (allowed_ids) |allowed| {
            if (arrayContainsString(allowed, entry.key_ptr.*)) try roots.append(allocator, entry.key_ptr.*);
        } else if (infer_root_ids and !hasIncomingLockEdge(locked_packages, entry.key_ptr.*)) {
            try roots.append(allocator, entry.key_ptr.*);
        }
    }
    // 有効な依存宣言に対して lock 側の一致候補が一つも無いのは lock・環境・
    // manifest の不整合（profile 不一致の依存は呼出し側が既に skip 済み）。
    // alias 欠落の環境を「依存なし」として受理しない。
    if (matches.items.len == 0) return error.InvalidEnvironment;
    if (allowed_ids != null and roots.items.len == 0) return error.InvalidEnvironment;
    const candidates = if (allowed_ids != null) roots.items else if (roots.items.len != 0) roots.items else if (matches.items.len == 1) matches.items else &.{};
    if (candidates.len == 0) return null;
    if (candidates.len != 1) return error.InvalidEnvironment;
    return candidates[0];
}

fn matchesManifestDependency(
    package_id: []const u8,
    lock_entry: std.json.ObjectMap,
    name: []const u8,
    constraint: DependencyConstraint,
    public_id: ?[]const u8,
) bool {
    const source_value = get(lock_entry, "source") orelse get(lock_entry, "resolvedFrom") orelse return false;
    const source = asObject(source_value) orelse return false;
    const kind = requiredString(source, "type") orelse return false;
    return switch (constraint) {
        .pkg => |dependency| {
            if (!std.mem.eql(u8, kind, "registry") and !std.mem.eql(u8, kind, "static")) return false;
            const version_text = requiredString(lock_entry, "version") orelse return false;
            const version = semver.Version.parse(version_text) catch return false;
            if (!dependency.version.satisfies(version)) return false;
            if (public_id) |id| return std.mem.eql(u8, package_id, id);
            const package_name = requiredString(lock_entry, "name") orelse return false;
            if (std.mem.indexOfScalar(u8, name, '/') == null) return std.mem.eql(u8, package_name, name);
            if (!std.mem.eql(u8, package_name, registryNamePart(name))) return false;
            const url = requiredString(source, "url") orelse return false;
            const owner_name = if (std.mem.startsWith(u8, name, "@")) name[1..] else name;
            if (!std.mem.endsWith(u8, url, owner_name)) return false;
            const prefix_len = url.len - owner_name.len;
            return prefix_len > 0 and url[prefix_len - 1] == '/';
        },
        .path => |dependency| blk: {
            if (!std.mem.eql(u8, kind, "path")) break :blk false;
            const source_path = requiredString(source, "path") orelse break :blk false;
            break :blk std.mem.eql(u8, source_path, dependency.path);
        },
        .git => |dependency| {
            if (!std.mem.eql(u8, kind, "git")) return false;
            const url = requiredString(source, "url") orelse return false;
            const commit = requiredString(source, "commit") orelse return false;
            return std.mem.eql(u8, url, dependency.url) and std.mem.startsWith(u8, commit, dependency.commit) and
                optionalStringEql(optionalString(source, "path"), dependency.path);
        },
        .http => |dependency| {
            if (!std.mem.eql(u8, kind, "http")) return false;
            const url = requiredString(source, "url") orelse return false;
            const hash = requiredString(source, "hash") orelse return false;
            return std.mem.eql(u8, url, dependency.url) and lock_model.hashEql(hash, dependency.hash);
        },
    };
}

fn hasIncomingLockEdge(locked_packages: std.json.ObjectMap, package_id: []const u8) bool {
    var iterator = locked_packages.iterator();
    while (iterator.next()) |entry| {
        const lock_entry = asObject(entry.value_ptr.*) orelse continue;
        const dependencies_value = get(lock_entry, "dependencies") orelse continue;
        const dependencies = asArray(dependencies_value) orelse continue;
        if (arrayContainsString(dependencies, package_id)) return true;
    }
    return false;
}

fn appendExpectedBinding(allocator: Allocator, bindings: *std.StringHashMap([]const u8), alias: []const u8, package_id: []const u8) !void {
    if (bindings.get(alias)) |existing| {
        if (!std.mem.eql(u8, existing, package_id)) return error.InvalidEnvironment;
        return;
    }
    try bindings.put(try allocator.dupe(u8, alias), package_id);
}

fn hasDerivedAliasCollision(manifest: *const manifest_mod.Manifest, current_key: []const u8, alias: []const u8, active_profile: ?[]const u8) bool {
    var pkg_iterator = manifest.dependencies.pkg.iterator();
    while (pkg_iterator.next()) |item| {
        if (!dependencyMatchesProfile(item.value_ptr.profile, active_profile)) continue;
        if (std.mem.eql(u8, item.key_ptr.*, current_key)) continue;
        if (std.mem.eql(u8, item.key_ptr.*, alias) or (item.value_ptr.alias != null and std.mem.eql(u8, item.value_ptr.alias.?, alias))) return true;
        if (std.mem.indexOfScalar(u8, item.key_ptr.*, '/') != null and std.mem.eql(u8, registryNamePart(item.key_ptr.*), alias)) return true;
    }
    var path_iterator = manifest.dependencies.path.iterator();
    while (path_iterator.next()) |item| if (std.mem.eql(u8, item.key_ptr.*, alias)) return true;
    var git_iterator = manifest.dependencies.git.iterator();
    while (git_iterator.next()) |item| {
        if (std.mem.eql(u8, item.key_ptr.*, alias) or (item.value_ptr.alias != null and std.mem.eql(u8, item.value_ptr.alias.?, alias))) return true;
    }
    var http_iterator = manifest.dependencies.http.iterator();
    while (http_iterator.next()) |item| {
        if (std.mem.eql(u8, item.key_ptr.*, alias) or (item.value_ptr.alias != null and std.mem.eql(u8, item.value_ptr.alias.?, alias))) return true;
    }
    return false;
}

fn registryNamePart(name: []const u8) []const u8 {
    const unscoped = if (std.mem.startsWith(u8, name, "@")) name[1..] else name;
    const slash = std.mem.lastIndexOfScalar(u8, unscoped, '/') orelse return name;
    return unscoped[slash + 1 ..];
}

fn readPackageManifest(allocator: Allocator, io: std.Io, package_root: []const u8, prefer_npkg_metadata: bool) !?manifest_mod.Manifest {
    const Candidate = struct { path: []const u8, npkg: bool };
    const candidates: []const Candidate = if (prefer_npkg_metadata)
        &.{
            .{ .path = "NAKO-PKG/METADATA.toml", .npkg = true },
            .{ .path = "nako.toml", .npkg = false },
        }
    else
        &.{
            .{ .path = "nako.toml", .npkg = false },
        };
    for (candidates) |candidate| {
        const manifest_path = try std.fs.path.join(allocator, &.{ package_root, candidate.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidEnvironment,
        };
        var diagnostics = diag.List.init(allocator);
        defer diagnostics.deinit();
        var parsed = (if (candidate.npkg)
            manifest_mod.parseNpkgMetadata(allocator, bytes, &diagnostics)
        else
            manifest_mod.parse(allocator, bytes, &diagnostics)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidEnvironment,
        };
        if (diagnostics.errorCount() > 0) {
            parsed.deinit();
            return error.InvalidEnvironment;
        }
        return parsed;
    }
    return null;
}

fn actualPackageRoot(allocator: Allocator, io: std.Io, project_root: []const u8, path: []const u8) !?[]const u8 {
    const package_path = if (std.fs.path.isAbsolute(path))
        path
    else
        try std.fs.path.resolve(allocator, &.{ project_root, path });
    return realPathDirAlloc(allocator, io, package_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidEnvironment,
    };
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| return if (right) |right_value| std.mem.eql(u8, left_value, right_value) else false;
    return right == null;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = get(object, key) orelse return null;
    return if (value == .string) value.string else null;
}

/// 公開namespaceはaliasを識別子化して生成するため、正規化後に一致する異名
/// alias（`my-util` と `my_util`、`1pkg` と `_1pkg` など）は同じ修飾名
/// namespace を占有する。同一scope内で正規化aliasが別packageを指すと
/// `{ns}__{名}` が両packageに解釈され得るため拒否する。同一packageへの
/// 複数aliasは冗長だが解決結果が一意なため許容する。
fn validateUniqueNamespaceAliases(allocator: Allocator, dependencies: []Value) !void {
    var normalized_aliases = std.StringHashMap([]const u8).init(allocator);
    defer {
        var keys = normalized_aliases.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        normalized_aliases.deinit();
    }
    for (dependencies) |dependency_value| {
        const dependency = asObject(dependency_value) orelse return error.InvalidEnvironment;
        const alias = requiredString(dependency, "alias") orelse return error.InvalidEnvironment;
        const package = requiredString(dependency, "package") orelse return error.InvalidEnvironment;
        const normalized = try namespaceFor(allocator, alias, null);
        // 正規化後に空になる alias は plugin 登録名を構成できない。
        if (normalized.len == 0) {
            allocator.free(normalized);
            return error.InvalidEnvironment;
        }
        const entry = try normalized_aliases.getOrPut(normalized);
        if (entry.found_existing) {
            allocator.free(normalized);
            if (!std.mem.eql(u8, entry.value_ptr.*, package)) return error.InvalidEnvironment;
        } else {
            entry.value_ptr.* = package;
        }
    }
}

fn optionalString(object: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = if (object) |record| get(record, key) orelse return null else return null;
    return if (value == .string) value.string else null;
}

fn objectCount(object: std.json.ObjectMap) usize {
    var count: usize = 0;
    var iterator = object.iterator();
    while (iterator.next()) |_| count += 1;
    return count;
}

fn arrayContainsString(values: std.json.Array, expected: []const u8) bool {
    for (values.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, expected)) return true;
    }
    return false;
}

fn materializedGeneration(path: []const u8, path_directory: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) return null;
    var components = std.mem.splitAny(u8, path, "/\\");
    const root = components.next() orelse return null;
    const env = components.next() orelse return null;
    const generation = components.next() orelse return null;
    const deps = components.next() orelse return null;
    const dirname = components.next() orelse return null;
    if (components.next() != null or !std.mem.eql(u8, root, ".nako") or !std.mem.eql(u8, env, "env") or
        !std.mem.eql(u8, deps, "deps") or !validGenerationName(generation) or !std.mem.eql(u8, dirname, path_directory)) return null;
    return generation;
}

fn sanitizedPackageName(allocator: Allocator, name: []const u8) Allocator.Error![]u8 {
    var sanitized: std.ArrayList(u8) = .empty;
    for (name) |byte| {
        try sanitized.append(allocator, if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') std.ascii.toLower(byte) else '-');
    }
    const trimmed = std.mem.trim(u8, sanitized.items, "-");
    if (trimmed.len != 0) return try allocator.dupe(u8, trimmed);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "pkg-{s}", .{hex[0..8]});
}

fn validGenerationName(generation: []const u8) bool {
    if (!std.mem.startsWith(u8, generation, "gen-")) return false;
    const suffix = generation[4..];
    if (suffix.len == 0 or suffix.len > 64) return false;
    for (suffix) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    return true;
}

fn validateMaterializedRoot(allocator: Allocator, io: std.Io, project_root: []const u8, path: []const u8, generation: []const u8) !?[]const u8 {
    const package_path = try std.fs.path.resolve(allocator, &.{ project_root, path });
    const deps_path = try std.fs.path.join(allocator, &.{ project_root, ".nako", "env", generation, "deps" });
    const actual_package = realPathDirAlloc(allocator, io, package_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return error.InvalidEnvironment,
    };
    const actual_deps = realPathDirAlloc(allocator, io, deps_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return error.InvalidEnvironment,
    };
    if (!isWithin(project_root, actual_deps) or !isWithin(actual_deps, actual_package)) return error.InvalidEnvironment;
    return actual_package;
}

pub fn selectExport(exports: []const Value, subpath: ?[]const u8) !Value {
    var selected: ?Value = null;
    var count: usize = 0;
    for (exports) |export_value| {
        const object = asObject(export_value) orelse return error.InvalidEnvironment;
        const name_value = get(object, "name") orelse return error.InvalidEnvironment;
        const alias_value = get(object, "alias");
        if (name_value != .string or (alias_value != null and alias_value.? != .string)) return error.InvalidEnvironment;
        // Root package imports select the declared default below. The dependency
        // alias is not an export selector: an export may independently publish
        // the same alias for a different subpath.
        const matches = if (subpath) |path|
            std.mem.eql(u8, name_value.string, path) or (alias_value != null and std.mem.eql(u8, alias_value.?.string, path))
        else
            false;
        if (matches) {
            selected = export_value;
            count += 1;
        }
    }
    if (count == 1) return selected.?;
    if (count > 1) return error.AmbiguousExport;
    if (subpath == null) {
        var default_export: ?Value = null;
        var default_count: usize = 0;
        for (exports) |export_value| {
            const object = asObject(export_value) orelse return error.InvalidEnvironment;
            const name = get(object, "name") orelse return error.InvalidEnvironment;
            const path = get(object, "path") orelse return error.InvalidEnvironment;
            if (name != .string or path != .string) return error.InvalidEnvironment;
            if (std.mem.eql(u8, name.string, "main") or std.mem.eql(u8, name.string, "index")) {
                default_export = export_value;
                default_count += 1;
            }
        }
        if (default_count == 1) return default_export.?;
        if (default_count > 1) return error.AmbiguousExport;

        default_export = null;
        default_count = 0;
        for (exports) |export_value| {
            const object = asObject(export_value) orelse return error.InvalidEnvironment;
            const path = get(object, "path") orelse return error.InvalidEnvironment;
            if (path != .string) return error.InvalidEnvironment;
            const basename = std.fs.path.basename(path.string);
            if (std.mem.eql(u8, basename, "main.nako3") or std.mem.eql(u8, basename, "index.nako3")) {
                default_export = export_value;
                default_count += 1;
            }
        }
        if (default_count == 1) return default_export.?;
        if (default_count > 1) return error.AmbiguousExport;
        if (exports.len == 1) return exports[0];
    }
    return error.ExportNotFound;
}

/// alias の公開namespace部分が正規化後に空になるか（`@` 単体や空文字列）。
/// 空になる alias は plugin 登録名 `{namespace}__{命令}` を構成できないため
/// 発行・読込・解決の全経路で拒否対象。
pub fn hasEmptyNamespace(allocator: Allocator, alias: []const u8) Allocator.Error!bool {
    const normalized = try namespaceFor(allocator, alias, null);
    defer allocator.free(normalized);
    return normalized.len == 0;
}

pub fn namespaceFor(allocator: Allocator, alias: []const u8, subpath: ?[]const u8) Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const namespace_alias = if (std.mem.startsWith(u8, alias, "@")) alias[1..] else alias;
    try appendNamespacePart(&result, allocator, namespace_alias, true);
    if (subpath) |path| {
        try result.appendSlice(allocator, "__");
        try appendNamespacePart(&result, allocator, path, false);
    }
    return result.toOwnedSlice(allocator);
}

fn appendNamespacePart(result: *std.ArrayList(u8), allocator: Allocator, part: []const u8, ensure_start: bool) Allocator.Error!void {
    var at_start = ensure_start;
    for (part) |byte| {
        if (byte == '/') {
            try result.appendSlice(allocator, "__");
        } else {
            const identifier_byte = if ((byte >= 'a' and byte <= 'z') or
                (byte >= 'A' and byte <= 'Z') or
                (byte >= '0' and byte <= '9') or byte == '_' or byte >= 0x80)
                byte
            else
                '_';
            if (at_start and identifier_byte >= '0' and identifier_byte <= '9') {
                try result.append(allocator, '_');
            }
            try result.append(allocator, identifier_byte);
            at_start = false;
        }
    }
}

fn isSourceOrPluginExtension(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2") or
        std.ascii.eqlIgnoreCase(extension, ".js") or
        std.ascii.eqlIgnoreCase(extension, ".mjs") or
        std.ascii.eqlIgnoreCase(extension, ".dylib") or
        std.ascii.eqlIgnoreCase(extension, ".so") or
        std.ascii.eqlIgnoreCase(extension, ".dll");
}

pub fn isWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

pub fn asObject(value: Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

pub fn asArray(value: Value) ?std.array_list.Managed(Value) {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

pub fn get(object: std.json.ObjectMap, key: []const u8) ?Value {
    return object.get(key);
}

test {
    _ = @import("import_resolver_test.zig");
}
