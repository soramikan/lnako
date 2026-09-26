//! Lock-bound source package import lookup shared by the compiler entry points.
const std = @import("std");
const module_graph = @import("../semantic/module_graph.zig");
const npkg_files = @import("npkg_files.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const native_store = @import("native_store.zig");
const diag = @import("diagnostics.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn realPathDirAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var directory = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

fn temporaryDirRealPathAlloc(allocator: Allocator, io: std.Io, base: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var directory = if (std.mem.eql(u8, sub_path, ".")) base else try base.openDir(io, sub_path, .{});
    defer if (!std.mem.eql(u8, sub_path, ".")) directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

/// Find the nearest project environment containing the input source. Relative and
/// absolute input paths are canonicalized from cwd before searching parent dirs.
pub fn findProjectRoot(allocator: Allocator, io: std.Io, input_path: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    // resolve() canonicalizes components but does not anchor a relative path at
    // cwd. realPathFileAlloc both makes it absolute and follows directory links.
    const absolute_input = try std.Io.Dir.cwd().realPathFileAlloc(io, input_path, temporary);
    var current = std.fs.path.dirname(absolute_input) orelse absolute_input;
    while (true) {
        const environment_path = try std.fs.path.join(temporary, &.{ current, ".nako", "environment.json" });
        if (std.Io.Dir.cwd().access(io, environment_path, .{})) |_| {
            return try allocator.dupe(u8, current);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
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

    fn resolve(self: *Resolver, allocator: Allocator, importer: []const u8, specifier: []const u8) !module_graph.ResolvedPackageImport {
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
        const scope_dependencies = if (try self.packageForImporter(temporary, packages, canonical_importer)) |owner|
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
            if (candidate_alias.len == 0) continue;

            const candidate_subpath: ?[]const u8 = if (std.mem.eql(u8, reference, candidate_alias))
                null
            else if (reference.len > candidate_alias.len and
                std.mem.startsWith(u8, reference, candidate_alias) and reference[candidate_alias.len] == '/')
                reference[candidate_alias.len + 1 ..]
            else
                continue;
            if (candidate_subpath) |subpath| {
                if (std.mem.indexOfScalar(u8, subpath, '@') != null or !npkg_files.isCanonicalPath(subpath)) continue;
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
        const selected_path = try allocator.dupe(u8, actual_export);
        return .{ .path = selected_path, .canonical_id = canonical_id, .namespace = namespace };
    }

    fn packageForImporter(self: *Resolver, allocator: Allocator, packages: std.json.ObjectMap, importer: []const u8) !?Value {
        var selected: ?Value = null;
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
                selected_root_len = root.len;
            }
        }
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
        const package_root = if (std.mem.eql(u8, source_kind.string, "path")) blk: {
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
            if (record_exports.items.len != 0 and implementation != null and std.mem.eql(u8, implementation.?, "native")) {
                const expected_native_path = try native_store.expectedRoot(allocator, source, lock_entry) orelse return error.InvalidEnvironment;
                if (!std.mem.eql(u8, environment_path.string, expected_native_path)) return error.InvalidEnvironment;
                break :blk try native_store.validateRoot(allocator, io, project_root, environment_path.string);
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
        if (package_root) |root| {
            try validateEnvironmentExports(allocator, io, root, record, lock_entry, locked_packages, artifact_target, profile_value.string);
        }

        if (get(record, "dependencies")) |dependencies_value| {
            const dependencies = asArray(dependencies_value) orelse return error.InvalidEnvironment;
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
        if (std.mem.eql(u8, kind.string, "path")) continue;

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
    const os = optionalString(profile_record, "os") orelse optionalString(input_target, "os") orelse "";
    const cpu = optionalString(profile_record, "cpu") orelse optionalString(input_target, "cpu") orelse "";
    const abi = optionalString(profile_record, "abi") orelse optionalString(input_target, "abi") orelse "";
    const compat_js = if (profile_record) |record| blk: {
        if (get(record, "compat-js")) |value| {
            if (value != .bool) return error.InvalidEnvironment;
            break :blk value.bool;
        }
        break :blk false;
    } else false;
    const optimize = optionalString(profile_record, "optimize") orelse "O0";
    if (profile_record) |record| {
        if (optionalString(record, "runtime")) |declared_runtime| {
            if (!std.mem.eql(u8, declared_runtime, runtime) and
                !std.mem.eql(u8, declared_runtime, "any") and !std.mem.eql(u8, declared_runtime, "common")) return error.InvalidEnvironment;
        }
    }
    _ = allocator;
    return .{ .runtime = runtime, .os = os, .cpu = cpu, .abi = abi, .compat_js = compat_js, .optimize = optimize };
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

    var manifest = try readPackageManifest(allocator, io, package_root);
    defer if (manifest) |*value| value.deinit();
    const lock_name = requiredString(lock_entry, "name") orelse return error.InvalidEnvironment;
    const lock_version = requiredString(lock_entry, "version") orelse return error.InvalidEnvironment;
    if (manifest) |*value| {
        if (!std.mem.eql(u8, value.package.name, lock_name)) return error.InvalidEnvironment;
        var version_buffer: [64]u8 = undefined;
        var version_writer: std.Io.Writer = .fixed(&version_buffer);
        value.package.version.format(&version_writer) catch return error.InvalidEnvironment;
        if (!std.mem.eql(u8, version_writer.buffered(), lock_version)) return error.InvalidEnvironment;
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

    var expected_index: usize = 0;
    if (manifest) |*value| {
        if (implementation == null or !std.mem.eql(u8, implementation.?, "none")) {
            const prefer_native = if (implementation) |kind| std.mem.eql(u8, kind, "native") else false;
            var diagnostics = diag.List.init(allocator);
            defer diagnostics.deinit();
            for (value.exports) |*export_decl| {
                const resolution = try export_decl.resolve(allocator, target, prefer_native, &diagnostics) orelse continue;
                if (implementation) |kind| {
                    if (std.mem.eql(u8, kind, "source") and resolution.kind != .source) continue;
                    if (std.mem.eql(u8, kind, "native") and resolution.kind != .native) continue;
                    if (std.mem.eql(u8, kind, "ESM") and resolution.kind != .esm) continue;
                }
                if (resolution.kind == .esm and !std.mem.eql(u8, target.runtime, "cnako") and !target.compat_js) continue;
                if (expected_index >= environment_exports.items.len) return error.InvalidEnvironment;
                const actual = asObject(environment_exports.items[expected_index]) orelse return error.InvalidEnvironment;
                if (!std.mem.eql(u8, requiredString(actual, "name") orelse return error.InvalidEnvironment, export_decl.name) or
                    !std.mem.eql(u8, requiredString(actual, "path") orelse return error.InvalidEnvironment, resolution.target)) return error.InvalidEnvironment;
                if (export_decl.alias) |expected_alias| {
                    if (!std.mem.eql(u8, requiredString(actual, "alias") orelse return error.InvalidEnvironment, expected_alias)) return error.InvalidEnvironment;
                } else if (get(actual, "alias") != null) {
                    return error.InvalidEnvironment;
                }
                expected_index += 1;
            }
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
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
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

fn findManifestDependencyTarget(
    allocator: Allocator,
    locked_packages: std.json.ObjectMap,
    allowed_ids: ?std.json.Array,
    infer_root_ids: bool,
    name: []const u8,
    constraint: DependencyConstraint,
    public_id: ?[]const u8,
) !?[]const u8 {
    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
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

fn readPackageManifest(allocator: Allocator, io: std.Io, package_root: []const u8) !?manifest_mod.Manifest {
    const candidates = [_]struct { path: []const u8, npkg: bool }{
        .{ .path = "NAKO-PKG/METADATA.toml", .npkg = true },
        .{ .path = "nako.toml", .npkg = false },
    };
    for (candidates) |candidate| {
        const manifest_path = try std.fs.path.join(allocator, &.{ package_root, candidate.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
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

fn selectExport(exports: []const Value, subpath: ?[]const u8) !Value {
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

fn namespaceFor(allocator: Allocator, alias: []const u8, subpath: ?[]const u8) Allocator.Error![]u8 {
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

fn isWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

fn asObject(value: Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(value: Value) ?std.array_list.Managed(Value) {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn get(object: std.json.ObjectMap, key: []const u8) ?Value {
    return object.get(key);
}

test "package dependency照合は選択profileのlock edge外を候補にしない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const locked_json =
        \\{"pkg:other-profile":{"name":"conditional-lib","version":"2.0.0","source":{"type":"registry","url":"https://example.invalid/conditional-lib"},"dependencies":[]},"pkg:current-edge":{"name":"unrelated","version":"1.0.0","source":{"type":"registry","url":"https://example.invalid/unrelated"},"dependencies":[]}}
    ;
    const parsed_lock = try std.json.parseFromSlice(Value, allocator, locked_json, .{});
    defer parsed_lock.deinit();
    const locked_packages = asObject(parsed_lock.value).?;
    const edges_json = "[\"pkg:current-edge\"]";
    const parsed_edges = try std.json.parseFromSlice(Value, allocator, edges_json, .{});
    defer parsed_edges.deinit();
    const allowed_edges = asArray(parsed_edges.value).?;
    const version_range = try semver.Range.parse(allocator, "2.0.0");
    const dependency = manifest_mod.PkgDependency{
        .name = "conditional-lib",
        .version = version_range,
        .version_text = "2.0.0",
        .profile = "windows",
    };

    const target = try findManifestDependencyTarget(
        allocator,
        locked_packages,
        allowed_edges,
        false,
        dependency.name,
        .{ .pkg = dependency },
        null,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), target);
}

test "package importは公開export名とaliasだけを選択しpath traversalを拒否する" {
    const json =
        \\[ {"name":"main","path":"src/main.nako3"},{"name":"utility","alias":"math","path":"src/utility.nako3"},{"name":"vector","path":"src/vector.nako3"}]
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const exports = asArray(parsed.value).?.items;
    const main = try selectExport(exports, null);
    try std.testing.expectEqualStrings("src/main.nako3", get(asObject(main).?, "path").?.string);
    const utility = try selectExport(exports, "math");
    try std.testing.expectEqualStrings("src/utility.nako3", get(asObject(utility).?, "path").?.string);
    const vector = try selectExport(exports, "vector");
    try std.testing.expectEqualStrings("src/vector.nako3", get(asObject(vector).?, "path").?.string);
    try std.testing.expectError(error.ExportNotFound, selectExport(exports, "private"));
    try std.testing.expect(!npkg_files.isCanonicalPath("../outside.nako3"));
}

test "既定exportはmainまたはindexという公開名をファイル名より優先する" {
    const json =
        \\[ {"name":"main","path":"src/main.nako3"}, {"name":"helpers","path":"helpers/index.nako3"} ]
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const selected = try selectExport(asArray(parsed.value).?.items, null);
    try std.testing.expectEqualStrings("main", get(asObject(selected).?, "name").?.string);
}

test "package alias内の識別子不適合文字を参照可能なnamespaceへ変換する" {
    const normalized = try namespaceFor(std.testing.allocator, "my-util", null);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("my_util", normalized);

    const scoped = try namespaceFor(std.testing.allocator, "@alice/my-util", "sub-path");
    defer std.testing.allocator.free(scoped);
    try std.testing.expectEqualStrings("alice__my_util__sub_path", scoped);
}

test "package import path containmentはprefix類似directoryを通さない" {
    const allocator = std.testing.allocator;
    const root = try std.fs.path.join(allocator, &.{ "tmp", "pkg" });
    defer allocator.free(root);
    const nested = try std.fs.path.join(allocator, &.{ root, "src", "index.nako3" });
    defer allocator.free(nested);
    const sibling = try std.fs.path.join(allocator, &.{ "tmp", "pkg-evil", "index.nako3" });
    defer allocator.free(sibling);
    try std.testing.expect(isWithin(root, nested));
    try std.testing.expect(!isWithin(root, sibling));
}

test "環境JSONのrootとpackage scopeでalias・subpathを解決しlock hashを検証する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/math/src");
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/dependency");
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/main.nako3", .data = "" });
    const root_manifest =
        \\[package]
        \\name = "app"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\math = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\windows-math = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111", profile = "windows", alias = "win-math" }
        \\"alice/lib" = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\alice = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222" }
        \\"@alice/tool" = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\
        \\[profiles.windows]
        \\os = "windows"
        \\cpu = "x86_64"
        \\abi = "msvc"
        \\
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = root_manifest });
    var root_manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root_manifest, &root_manifest_digest, .{});
    const root_manifest_sha256 = std.fmt.bytesToHex(root_manifest_digest, .lower);
    const lock_json_template = "{\"schemaVersion\":2,\"resolverVersion\":1,\"input\":{\"manifestSha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"profile\":\"default\",\"features\":[],\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:11111111111111111111111111111111\":{\"id\":\"pkg:11111111111111111111111111111111\",\"name\":\"math\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/math\"},\"dependencies\":[\"pkg:22222222222222222222222222222222\",\"pkg:33333333333333333333333333333333\"]},\"pkg:22222222222222222222222222222222\":{\"id\":\"pkg:22222222222222222222222222222222\",\"name\":\"dependency\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/dependency\"},\"dependencies\":[]},\"pkg:33333333333333333333333333333333\":{\"id\":\"pkg:33333333333333333333333333333333\",\"name\":\"missing\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/missing\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[\"pkg:11111111111111111111111111111111\",\"pkg:22222222222222222222222222222222\"]}}";
    const lock_json = try std.mem.replaceOwned(u8, allocator, lock_json_template, "0000000000000000000000000000000000000000000000000000000000000000", &root_manifest_sha256);
    defer allocator.free(lock_json);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_json });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/nako.toml", .data =
        \\[package]
        \\name = "math"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\dependency = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222", alias = "dep" }
        \\windows-dependency = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222", profile = "windows", alias = "win-dependency" }
        \\missing = { version = "1.0.0", public-id = "pkg:33333333333333333333333333333333" }
        \\
        \\[profiles.windows]
        \\os = "windows"
        \\cpu = "x86_64"
        \\abi = "msvc"
        \\
        \\[[exports]]
        \\name = "main"
        \\alias = "math"
        \\path = "src/main.nako3"
        \\[[exports]]
        \\name = "vector"
        \\path = "vector.nako3"
        \\[[exports]]
        \\name = "escape"
        \\path = "src/escape.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/dependency/nako.toml", .data =
        \\[package]
        \\name = "dependency"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/src/main.nako3", .data = "A=1\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/vector.nako3", .data = "B=2\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/dependency/index.nako3", .data = "C=3\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "outside.nako3", .data = "OUTSIDE=1\n" });
    const outside_path = try temporary.dir.realPathFileAlloc(io, "outside.nako3", allocator);
    defer allocator.free(outside_path);
    temporary.dir.symLink(io, outside_path, ".nako/env/gen-test/deps/math/src/escape.nako3", .{}) catch return error.SkipZigTest;
    temporary.dir.symLink(io, "math", ".nako/env/gen-test/deps/math-link", .{}) catch return error.SkipZigTest;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_json, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"math\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"alice/lib\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"lib\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"alice\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"@alice/tool\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"tool\",\"package\":\"pkg:11111111111111111111111111111111\"}}],\"packages\":{{\"pkg:11111111111111111111111111111111\":{{\"id\":\"pkg:11111111111111111111111111111111\",\"name\":\"math\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/math\",\"exports\":[{{\"name\":\"main\",\"alias\":\"math\",\"path\":\"src/main.nako3\"}},{{\"name\":\"vector\",\"path\":\"vector.nako3\"}},{{\"name\":\"escape\",\"path\":\"src/escape.nako3\"}}],\"dependencies\":[{{\"alias\":\"dependency\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"dep\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"missing\",\"package\":\"pkg:33333333333333333333333333333333\"}}]}},\"pkg:22222222222222222222222222222222\":{{\"id\":\"pkg:22222222222222222222222222222222\",\"name\":\"dependency\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/dependency\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}]}},\"pkg:33333333333333333333333333333333\":{{\"id\":\"pkg:33333333333333333333333333333333\",\"name\":\"missing\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/missing\",\"exports\":[],\"dependencies\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(json);
    const project_root = try temporaryDirRealPathAlloc(allocator, io, temporary.dir, ".");
    defer allocator.free(project_root);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/private.nako3", .data = "PRIVATE=1\\n" });
    const tampered_root_alias_json = try std.mem.replaceOwned(u8, allocator, json, "\"alias\":\"math\",\"package\":\"pkg:11111111111111111111111111111111\"", "\"alias\":\"math\",\"package\":\"pkg:22222222222222222222222222222222\"");
    defer allocator.free(tampered_root_alias_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_root_alias_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_package_alias_json = try std.mem.replaceOwned(u8, allocator, json, "\"alias\":\"dep\",\"package\":\"pkg:22222222222222222222222222222222\"", "\"alias\":\"dep\",\"package\":\"pkg:33333333333333333333333333333333\"");
    defer allocator.free(tampered_package_alias_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_package_alias_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_export_json = try std.mem.replaceOwned(u8, allocator, json, "\"path\":\"src/main.nako3\"", "\"path\":\"private.nako3\"");
    defer allocator.free(tampered_export_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_export_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_json = try std.mem.replaceOwned(u8, allocator, json, ".nako/env/gen-test/deps/math", "../outside");
    defer allocator.free(tampered_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_id_json = try std.mem.replaceOwned(u8, allocator, json, "pkg:11111111111111111111111111111111", "pkg:not-locked-id");
    defer allocator.free(tampered_id_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_id_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = json });
    const canonical_hash = try std.fmt.allocPrint(allocator, "sha256:{s}", .{lock_hex});
    defer allocator.free(canonical_hash);
    const base64_buffer = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
    defer allocator.free(base64_buffer);
    const base64_hash = std.base64.standard.Encoder.encode(base64_buffer, &digest);
    const sri_hash = try std.fmt.allocPrint(allocator, "sha256-{s}", .{base64_hash});
    defer allocator.free(sri_hash);
    const hash_variants = [_][]const u8{ canonical_hash, lock_hex[0..], sri_hash };
    for (hash_variants) |hash_text| {
        const variant_json = try std.mem.replaceOwned(u8, allocator, json, canonical_hash, hash_text);
        defer allocator.free(variant_json);
        try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = variant_json });
        var hash_resolver = try Resolver.load(allocator, io, project_root);
        hash_resolver.deinit();
    }
    const cnako_environment = try std.mem.replaceOwned(u8, allocator, json, "\"runtime\":\"lnako\"", "\"runtime\":\"cnako\"");
    defer allocator.free(cnako_environment);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = cnako_environment });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = json });
    temporary.dir.symLink(io, project_root, ".project-link", .{ .is_directory = true }) catch return error.SkipZigTest;
    const project_alias = try std.fs.path.join(allocator, &.{ project_root, ".project-link" });
    defer allocator.free(project_alias);

    var resolver = try Resolver.load(allocator, io, project_alias);
    defer resolver.deinit();
    const root_entry = try std.fs.path.join(allocator, &.{ project_root, "main.nako3" });
    defer allocator.free(root_entry);
    const detected_root = (try findProjectRoot(allocator, io, root_entry)).?;
    defer allocator.free(detected_root);
    try std.testing.expectEqualStrings(project_root, detected_root);
    const cwd = try realPathDirAlloc(allocator, io, ".");
    defer allocator.free(cwd);
    try std.testing.expect(std.mem.startsWith(u8, project_root, cwd));
    try std.testing.expect(project_root.len > cwd.len and std.fs.path.isSep(project_root[cwd.len]));
    const relative_directory = project_root[cwd.len + 1 ..];
    const relative_main = try std.fs.path.join(allocator, &.{ relative_directory, "main.nako3" });
    defer allocator.free(relative_main);
    const relative_nested = try std.fs.path.join(allocator, &.{ relative_directory, "src", "main.nako3" });
    defer allocator.free(relative_nested);
    const relative_inputs = [_][]const u8{ relative_main, relative_nested };
    for (relative_inputs) |relative_input| {
        const found_root = (try findProjectRoot(allocator, io, relative_input)) orelse return error.ProjectRootNotFound;
        defer allocator.free(found_root);
        try std.testing.expectEqualStrings(project_root, found_root);
    }
    const math_import = try resolver.resolve(allocator, root_entry, "パッケージ:math");
    defer allocator.free(math_import.path);
    defer allocator.free(math_import.canonical_id);
    defer allocator.free(math_import.namespace);
    const expected_math_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "math", "src", "main.nako3" });
    defer allocator.free(expected_math_path);
    try std.testing.expect(std.mem.endsWith(u8, math_import.path, expected_math_path));
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/main", math_import.canonical_id);
    try std.testing.expectEqualStrings("math", math_import.namespace);
    try std.testing.expectError(error.PackageNotFound, resolver.resolve(allocator, root_entry, "pkg:win-math"));
    try std.testing.expectError(error.PackageNotFound, resolver.resolve(allocator, math_import.path, "pkg:win-dependency"));
    const owner_name_import = try resolver.resolve(allocator, root_entry, "pkg:alice/lib");
    defer allocator.free(owner_name_import.path);
    defer allocator.free(owner_name_import.canonical_id);
    defer allocator.free(owner_name_import.namespace);
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/main", owner_name_import.canonical_id);
    try std.testing.expectEqualStrings("alice__lib", owner_name_import.namespace);
    const scoped_owner_import = try resolver.resolve(allocator, root_entry, "pkg:@alice/tool");
    defer allocator.free(scoped_owner_import.path);
    defer allocator.free(scoped_owner_import.canonical_id);
    defer allocator.free(scoped_owner_import.namespace);
    try std.testing.expectEqualStrings("alice__tool", scoped_owner_import.namespace);
    const scoped_subpath_import = try resolver.resolve(allocator, root_entry, "pkg:alice/lib/vector");
    defer allocator.free(scoped_subpath_import.path);
    defer allocator.free(scoped_subpath_import.canonical_id);
    defer allocator.free(scoped_subpath_import.namespace);
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/vector", scoped_subpath_import.canonical_id);
    try std.testing.expectEqualStrings("alice__lib__vector", scoped_subpath_import.namespace);
    const vector_import = try resolver.resolve(allocator, root_entry, "pkg:math/vector");
    defer allocator.free(vector_import.path);
    defer allocator.free(vector_import.canonical_id);
    defer allocator.free(vector_import.namespace);
    const expected_vector_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "math", "vector.nako3" });
    defer allocator.free(expected_vector_path);
    try std.testing.expect(std.mem.endsWith(u8, vector_import.path, expected_vector_path));
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/vector", vector_import.canonical_id);
    try std.testing.expectEqualStrings("math__vector", vector_import.namespace);
    const nested_import = try resolver.resolve(allocator, math_import.path, "パッケージ:dep");
    defer allocator.free(nested_import.path);
    defer allocator.free(nested_import.canonical_id);
    defer allocator.free(nested_import.namespace);
    const expected_nested_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "dependency", "index.nako3" });
    defer allocator.free(expected_nested_path);
    try std.testing.expect(std.mem.endsWith(u8, nested_import.path, expected_nested_path));
    try std.testing.expectEqualStrings("pkg:22222222222222222222222222222222/index", nested_import.canonical_id);
    try std.testing.expectEqualStrings("dep", nested_import.namespace);
    try std.testing.expectError(error.PackageNotFound, resolver.resolve(allocator, root_entry, "パッケージ:dep"));
    try std.testing.expectError(error.PackageNotFound, resolver.resolve(allocator, root_entry, "パッケージ:math@1.0.0"));
    try std.testing.expectError(error.PackageNotFound, resolver.resolve(allocator, root_entry, "パッケージ:math/../private"));
    try std.testing.expectError(error.UnsafeExportPath, resolver.resolve(allocator, root_entry, "パッケージ:math/escape"));
}

test "realpath importerとproject entry優先でancestor package scopeを誤選択しない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "repo/examples/.nako/env/gen-test/deps/root-util");
    try temporary.dir.createDirPath(io, "repo/parent-util");
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/main.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/parent-util/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/env/gen-test/deps/root-util/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/nako.toml", .data =
        \\[package]
        \\name = "ancestor"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.path]
        \\util = { path = "../parent-util" }
        \\[[exports]]
        \\name = "main"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/parent-util/nako.toml", .data =
        \\[package]
        \\name = "parent-util"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/env/gen-test/deps/root-util/nako.toml", .data =
        \\[package]
        \\name = "root-util"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    const lock_json = "{\"schemaVersion\":2,\"resolverVersion\":1,\"input\":{\"manifestSha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"profile\":\"default\",\"features\":[],\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:ancestor\":{\"id\":\"pkg:ancestor\",\"name\":\"ancestor\",\"version\":\"1.0.0\",\"source\":{\"type\":\"path\",\"path\":\"..\"},\"dependencies\":[\"pkg:parent-util\"]},\"pkg:root-util\":{\"id\":\"pkg:root-util\",\"name\":\"root-util\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/root-util\"},\"dependencies\":[]},\"pkg:parent-util\":{\"id\":\"pkg:parent-util\",\"name\":\"parent-util\",\"version\":\"1.0.0\",\"source\":{\"type\":\"path\",\"path\":\"../parent-util\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[\"pkg:root-util\"]}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/nako.lock", .data = lock_json });
    const parent_entry = try temporary.dir.realPathFileAlloc(io, "repo/index.nako3", allocator);
    defer allocator.free(parent_entry);
    temporary.dir.symLink(io, parent_entry, "repo/examples/parent-link.nako3", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_json, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"util\",\"package\":\"pkg:root-util\"}}],\"packages\":{{\"pkg:ancestor\":{{\"id\":\"pkg:ancestor\",\"name\":\"ancestor\",\"version\":\"1.0.0\",\"path\":\"..\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}],\"dependencies\":[{{\"alias\":\"util\",\"package\":\"pkg:parent-util\"}}]}},\"pkg:root-util\":{{\"id\":\"pkg:root-util\",\"name\":\"root-util\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/root-util\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}],\"dependencies\":[]}},\"pkg:parent-util\":{{\"id\":\"pkg:parent-util\",\"name\":\"parent-util\",\"version\":\"1.0.0\",\"path\":\"../parent-util\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}],\"dependencies\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(json);
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/environment.json", .data = json });
    const project_root = try temporaryDirRealPathAlloc(allocator, io, temporary.dir, "repo/examples");
    defer allocator.free(project_root);
    const root_entry = try temporary.dir.realPathFileAlloc(io, "repo/examples/main.nako3", allocator);
    defer allocator.free(root_entry);
    const symlink_importer = try std.fs.path.join(allocator, &.{ project_root, "parent-link.nako3" });
    defer allocator.free(symlink_importer);

    var resolver = try Resolver.load(allocator, io, project_root);
    defer resolver.deinit();
    const project_import = try resolver.resolve(allocator, root_entry, "pkg:util");
    defer allocator.free(project_import.path);
    defer allocator.free(project_import.canonical_id);
    defer allocator.free(project_import.namespace);
    const expected_root_util = try std.fs.path.join(allocator, &.{ "root-util", "index.nako3" });
    defer allocator.free(expected_root_util);
    try std.testing.expect(std.mem.endsWith(u8, project_import.path, expected_root_util));

    const package_import = try resolver.resolve(allocator, symlink_importer, "pkg:util");
    defer allocator.free(package_import.path);
    defer allocator.free(package_import.canonical_id);
    defer allocator.free(package_import.namespace);
    const expected_parent_util = try std.fs.path.join(allocator, &.{ "parent-util", "index.nako3" });
    defer allocator.free(expected_parent_util);
    try std.testing.expect(std.mem.endsWith(u8, package_import.path, expected_parent_util));
}
