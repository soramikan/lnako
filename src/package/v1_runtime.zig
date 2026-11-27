//! パッケージ仕様 v1 の runtime 接続（`nako.lock` + `.nako/v1` materialize）。
//!
//! このモジュールは新しい lock を書かない。`v1_client` が materialize した
//! `.nako/v1/environment.json` と `nako.lock` を読み、`module_graph` の
//! PackageResolver / DeclaredCommandsProvider へ接続する。
//!
//! 解決規則（§6.1）:
//! - alias 表は宣言元ごとに独立。root は lock `profile.root`、推移は
//!   `profile.edges` の `from == owner key` から作る。
//! - scoped は `{alias}__{命令}`、global は命令名を無修飾で公開する。
//! - global は宣言側の `allow_global_commands` と、推移 import では root の
//!   同じ Package ID への許可の両方を要求する。欠ければ解決を失敗させる。
//! - 異なる Package ID の global 命令名が衝突したら失敗する。
//!
//! 旧 `.nako/environment.json` は読まない。旧 lock（`schemaVersion`）は
//! `v1_lock.parse` が `error.LegacyLock` を返し、読み替えも書き換えもしない。

const std = @import("std");
const module_graph = @import("../semantic/module_graph.zig");
const declared_commands = @import("../semantic/declared_commands.zig");
const types = @import("v1_types.zig");
const v1_imports = @import("v1_imports.zig");
const v1_lock = @import("v1_lock.zig");
const v1_manifest = @import("v1_manifest.zig");
const v1_runtime_freshness = @import("v1_runtime_freshness.zig");
const v1_zip = @import("v1_zip.zig");
const v1_metadata_commands = @import("v1_metadata_commands.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{
    NoV1Environment,
    InvalidEnvironment,
    StaleEnvironment,
    UnsafePackagePath,
    LegacyLock,
    UnsupportedVersion,
    InvalidLock,
    PackageNotFound,
    ExportNotFound,
    AmbiguousImport,
    UndeclaredSubpath,
    GlobalCommandsNotAllowed,
    AmbiguousGlobalCommand,
    /// 必須 COMMANDS.json が無い・壊れている・上限超過、または環境の
    /// exports と一致しない。パッケージ全体の索引への後退は行わない。
    InvalidCommands,
    OutOfMemory,
};

pub const max_pointer_bytes: usize = 64 * 1024;
pub const max_environment_bytes: usize = 16 * 1024 * 1024;
pub const max_lock_bytes: usize = 64 * 1024 * 1024;
/// pack/verify と同じく ZIP の既定展開合計上限で有界にする。COMMANDS.json
/// 固有の小さな上限は設けない（§3.2-4）。
pub const max_commands_bytes: usize = @intCast(v1_zip.default_max_uncompressed_bytes);
pub const max_manifest_bytes: usize = 16 * 1024 * 1024;

pub const Export = struct {
    subpath: []const u8,
    entry: []const u8,
    binding: types.Binding,
};

/// 検証済み `COMMANDS.json` の subpath ごとの global 命令名。global 入口は
/// その subpath が公開する命令だけを可視にする（§3.5・§6.1）。
pub const ExportGlobalCommands = struct {
    subpath: []const u8,
    names: []const []const u8,
};

/// 検証済み `COMMANDS.json` の subpath ごとの宣言命令。同じ package でも
/// `.` と `./client` は別の宣言なので、package 全体へ平坦化しない。
pub const ExportDeclaredCommands = struct {
    subpath: []const u8,
    declared: declared_commands.DeclaredCommands,
};

pub const Package = struct {
    key: []const u8,
    id: []const u8,
    version: []const u8,
    kind: types.Kind,
    sha256: []const u8,
    /// 世代 dir からの検証済み絶対 path。
    root: []const u8,
    exports: []const Export,
    exports_global_commands: bool,
    global_commands: []const []const u8,
    global_commands_by_export: []const ExportGlobalCommands,
    declared_by_export: []const ExportDeclaredCommands,
};

const TableData = struct {
    declarations: []v1_imports.Declaration,
    targets: []usize,
    table: v1_imports.Table,
};

pub const Environment = struct {
    gpa: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    lock: v1_lock.Lock,
    project_root: []const u8,
    generation: []const u8,
    generation_dir: []const u8,
    profile: []const u8,
    runtime: types.Runtime,
    target_triple: ?[]const u8,
    lock_sha256: []const u8,
    packages: []Package,
    package_map: std.StringHashMapUnmanaged(usize) = .empty,
    root_table: TableData,
    owner_tables: std.StringHashMapUnmanaged(TableData) = .empty,
    global_names: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Environment) void {
        self.lock.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lockSha256(self: *const Environment) []const u8 {
        return self.lock_sha256;
    }

    pub fn resolver(self: *Environment) module_graph.PackageResolver {
        return .{ .context = self, .resolveFn = resolveCallback };
    }

    pub fn resolveScoped(
        self: *Environment,
        allocator: Allocator,
        importer: []const u8,
        importer_owner: ?[]const u8,
        specifier: []const u8,
    ) anyerror!module_graph.ResolvedPackageImport {
        return resolveScopedInner(self, allocator, importer, importer_owner, specifier);
    }

    pub fn declaredCommands(self: *Environment) module_graph.DeclaredCommandsProvider {
        return .{ .context = self, .exportLookupFn = declaredCallback };
    }
};

pub const LoadOptions = struct {
    /// CLI の `--profile`。environment に記録された profile と一致すること
    /// と、現在の manifest が選ぶ profile の両方を検証する。
    profile: ?[]const u8 = null,
    /// CLI の `--features`。現在の manifest から直接依存を再構成する入力。
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
};

/// `.nako/v1/environment.json` が通常ファイルとして存在するか。
/// 内容の検証はしない（壊れた v1 環境を旧経路へフォールバックさせないための
/// 入口判定だけに使う）。
pub fn environmentPresent(io: std.Io, project_root: []const u8, allocator: Allocator) bool {
    const root = realPathDirAlloc(allocator, io, project_root) catch return false;
    defer allocator.free(root);
    // `.nako/v1` が存在すれば v1 環境の入口とみなす。pointer の欠落・symlink は
    // `load` 側で fail-closed に診断し、旧経路へは落とさない。
    var nako_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false }) catch return false;
    defer nako_dir.close(io);
    const nako_stat = nako_dir.statFile(io, ".nako", .{ .follow_symlinks = false }) catch return false;
    if (nako_stat.kind != .directory) return true;
    var nako = nako_dir.openDir(io, ".nako", .{ .follow_symlinks = false }) catch return true;
    defer nako.close(io);
    const v1_stat = nako.statFile(io, "v1", .{ .follow_symlinks = false }) catch return false;
    if (v1_stat.kind != .directory) return true;
    var v1 = nako.openDir(io, "v1", .{ .follow_symlinks = false }) catch return true;
    defer v1.close(io);
    return true;
}

/// `.nako/v1/environment.json` を読む。v1 環境が無ければ null。
pub fn load(gpa: Allocator, io: std.Io, project_root: []const u8, options: LoadOptions) anyerror!?Environment {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root = realPathDirAlloc(allocator, io, project_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => {
            arena.deinit();
            return null;
        },
        else => return error.InvalidEnvironment,
    };
    const pointer_bytes = readFileUnder(io, allocator, root, &.{ ".nako", "v1", "environment.json" }, max_pointer_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            arena.deinit();
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };
    const generation = parsePointer(allocator, pointer_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvironment,
    };

    const generation_rel = [_][]const u8{ ".nako", "v1", "generations", generation };
    const generation_dir = std.fs.path.join(allocator, &.{ root, generation_rel[0], generation_rel[1], generation_rel[2], generation_rel[3] }) catch return error.OutOfMemory;
    verifyDirectoryNoFollow(io, root, &generation_rel) catch return error.UnsafePackagePath;

    const env_bytes = readFileUnder(io, allocator, root, &.{ ".nako", "v1", "generations", generation, "environment.json" }, max_environment_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.StaleEnvironment,
        else => return error.InvalidEnvironment,
    };
    const parsed_value = std.json.parseFromSliceLeaky(Value, allocator, env_bytes, .{}) catch return error.InvalidEnvironment;
    const object = asObject(parsed_value) orelse return error.InvalidEnvironment;
    try rejectUnknown(object, &.{ "schema_version", "generation", "profile", "runtime", "target_triple", "lock_sha256", "packages" });
    if (try requiredInt(object, "schema_version") != 1) return error.InvalidEnvironment;
    const env_generation = try requiredString(object, "generation");
    if (!std.mem.eql(u8, env_generation, generation)) return error.InvalidEnvironment;
    const profile_name = try requiredString(object, "profile");
    if (options.profile) |expected| {
        if (!std.mem.eql(u8, expected, profile_name)) return error.StaleEnvironment;
    }
    const runtime = parseRuntime(try requiredString(object, "runtime")) catch return error.InvalidEnvironment;
    if (runtime != .lnako) return error.InvalidEnvironment;
    const target_triple = if (object.get("target_triple")) |value| try asString(value) else null;
    if (target_triple) |triple| {
        if (!types.validTargetTriple(triple)) return error.InvalidEnvironment;
    }
    const env_lock_sha = try requiredString(object, "lock_sha256");
    if (!types.validHash(env_lock_sha)) return error.InvalidEnvironment;

    const lock_bytes = readFileUnder(io, allocator, root, &.{"nako.lock"}, max_lock_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StaleEnvironment,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    var declared_hash_buf: [71]u8 = undefined;
    const actual_lock_sha = formatHash(&declared_hash_buf, digest);
    if (!std.mem.eql(u8, actual_lock_sha, env_lock_sha)) return error.StaleEnvironment;

    var lock = v1_lock.parse(gpa, lock_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LegacyLock => return error.LegacyLock,
        error.UnsupportedVersion => return error.UnsupportedVersion,
        error.InvalidLock, error.MissingArtifact => return error.InvalidLock,
    };
    errdefer lock.deinit();
    const profile = lock.findProfile(profile_name) orelse return error.StaleEnvironment;
    if (profile.runtime != runtime) return error.StaleEnvironment;
    if (!optionalStringEql(profile.target_triple, target_triple)) return error.StaleEnvironment;

    // 現在の manifest・選択 profile・feature 選択から直接依存の宣言を
    // 作り直し、lock の root と一致することを確認する。削除した依存や
    // 取り消した alias / allow_global_commands を古い lock から復活させない。
    {
        var freshness_arena = std.heap.ArenaAllocator.init(gpa);
        defer freshness_arena.deinit();
        const freshness_allocator = freshness_arena.allocator();
        const manifest_source = readFileUnder(io, freshness_allocator, root, &.{"nako.toml"}, max_manifest_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return error.StaleEnvironment,
            else => return error.InvalidEnvironment,
        };
        const manifest = v1_manifest.parse(freshness_allocator, manifest_source, .local) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidEnvironment,
        };
        v1_runtime_freshness.verify(freshness_allocator, &manifest, profile, .{
            .profile = options.profile,
            .features = options.features,
            .no_default_features = options.no_default_features,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.StaleEnvironment,
        };
    }

    const packages_json = try requiredArray(object, "packages");
    var packages: std.ArrayList(Package) = .empty;
    var package_map: std.StringHashMapUnmanaged(usize) = .empty;
    for (packages_json.items) |package_value| {
        const package_object = asObject(package_value) orelse return error.InvalidEnvironment;
        try rejectUnknown(package_object, &.{ "id", "version", "kind", "sha256", "root", "exports", "exports_global_commands", "global_commands" });
        const id = try requiredString(package_object, "id");
        if (!types.validId(id)) return error.InvalidEnvironment;
        const version = try requiredString(package_object, "version");
        if (!types.validPublicVersion(version)) return error.InvalidEnvironment;
        const key = std.fmt.allocPrint(allocator, "{s}@{s}", .{ id, version }) catch return error.OutOfMemory;
        if (package_map.contains(key)) return error.InvalidEnvironment;
        const kind = parseKind(try requiredString(package_object, "kind")) catch return error.InvalidEnvironment;
        const sha = try requiredString(package_object, "sha256");
        if (!types.validHash(sha)) return error.InvalidEnvironment;
        const root_rel = try requiredString(package_object, "root");
        if (!types.validPath(root_rel)) return error.UnsafePackagePath;
        const package_root = try resolvePackageRoot(allocator, io, root, generation_dir, root_rel);
        const exports = try parseExports(allocator, package_object);
        const exports_global = try requiredBool(package_object, "exports_global_commands");
        const global_commands = try parseStringArray(allocator, package_object, "global_commands");
        for (global_commands) |name| {
            if (name.len == 0) return error.InvalidEnvironment;
        }
        const loaded_commands = try loadDeclaredCommands(
            allocator,
            io,
            package_root,
            exports,
            exports_global,
        );
        const index = packages.items.len;
        try packages.append(allocator, .{
            .key = key,
            .id = id,
            .version = version,
            .kind = kind,
            .sha256 = sha,
            .root = package_root,
            .exports = exports,
            .exports_global_commands = exports_global,
            .global_commands = global_commands,
            .global_commands_by_export = loaded_commands.global_by_export,
            .declared_by_export = loaded_commands.declared_by_export,
        });
        try package_map.put(allocator, key, index);
    }

    // lock node と materialize 済み package は 1:1。余剰・欠落・不明項目は
    // 環境の再生成を要求する（古い環境を黙って使わない）。
    if (profile.nodes.len != packages.items.len) return error.StaleEnvironment;
    for (profile.nodes) |node| {
        const index = package_map.get(node.key) orelse return error.StaleEnvironment;
        const package = packages.items[index];
        if (!std.mem.eql(u8, package.id, node.id) or
            !std.mem.eql(u8, package.version, node.version) or
            !std.mem.eql(u8, package.sha256, node.sha256) or
            package.kind != node.kind)
            return error.StaleEnvironment;
        if (package.exports_global_commands != node.global) return error.StaleEnvironment;
        var has_global_export = false;
        for (package.exports) |export_entry| {
            if (export_entry.binding == .global) has_global_export = true;
        }
        if (has_global_export != package.exports_global_commands) return error.StaleEnvironment;
    }

    const root_table = try buildTable(allocator, profile.root, packages.items, package_map, null);
    var owner_tables: std.StringHashMapUnmanaged(TableData) = .empty;
    for (profile.nodes) |node| {
        var edges: std.ArrayList(v1_lock.Edge) = .empty;
        defer edges.deinit(allocator);
        for (profile.edges) |edge| {
            if (edge.from) |from| {
                if (std.mem.eql(u8, from, node.key)) try edges.append(allocator, edge);
            }
        }
        const table = try buildTable(allocator, edges.items, packages.items, package_map, node.key);
        try owner_tables.put(allocator, node.key, table);
    }

    return .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .lock = lock,
        .project_root = root,
        .generation = generation,
        .generation_dir = generation_dir,
        .profile = profile_name,
        .runtime = runtime,
        .target_triple = target_triple,
        .lock_sha256 = try allocator.dupe(u8, env_lock_sha),
        .packages = try packages.toOwnedSlice(allocator),
        .package_map = package_map,
        .root_table = root_table,
        .owner_tables = owner_tables,
    };
}

fn parsePointer(allocator: Allocator, bytes: []const u8) ![]u8 {
    const parsed_value = std.json.parseFromSliceLeaky(Value, allocator, bytes, .{}) catch return error.InvalidEnvironment;
    const object = asObject(parsed_value) orelse return error.InvalidEnvironment;
    try rejectUnknown(object, &.{ "schema_version", "generation" });
    if (try requiredInt(object, "schema_version") != 1) return error.InvalidEnvironment;
    const generation = try requiredString(object, "generation");
    if (!validGeneration(generation)) return error.InvalidEnvironment;
    return allocator.dupe(u8, generation);
}

pub fn validGeneration(text: []const u8) bool {
    if (text.len != 20 or !std.mem.startsWith(u8, text, "gen-")) return false;
    for (text[4..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn parseExports(allocator: Allocator, object: std.json.ObjectMap) ![]Export {
    const exports_value = try requiredArray(object, "exports");
    if (exports_value.items.len == 0) return error.InvalidEnvironment;
    var result: std.ArrayList(Export) = .empty;
    for (exports_value.items) |value| {
        const export_object = asObject(value) orelse return error.InvalidEnvironment;
        try rejectUnknown(export_object, &.{ "subpath", "entry", "binding" });
        const subpath = try requiredString(export_object, "subpath");
        if (!validSubpath(subpath)) return error.InvalidEnvironment;
        const entry = try requiredString(export_object, "entry");
        if (!types.validPath(entry)) return error.UnsafePackagePath;
        const binding = parseBinding(try requiredString(export_object, "binding")) catch return error.InvalidEnvironment;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing.subpath, subpath)) return error.InvalidEnvironment;
        }
        try result.append(allocator, .{
            .subpath = try allocator.dupe(u8, subpath),
            .entry = try allocator.dupe(u8, entry),
            .binding = binding,
        });
    }
    return result.toOwnedSlice(allocator);
}

fn validSubpath(text: []const u8) bool {
    if (std.mem.eql(u8, text, ".")) return true;
    if (!std.mem.startsWith(u8, text, "./") or text.len == 2) return false;
    return types.validPath(text[2..]);
}

fn buildTable(
    allocator: Allocator,
    edges: []const v1_lock.Edge,
    packages: []const Package,
    package_map: std.StringHashMapUnmanaged(usize),
    owner: ?[]const u8,
) !TableData {
    var declarations: std.ArrayList(v1_imports.Declaration) = .empty;
    var targets: std.ArrayList(usize) = .empty;
    for (edges) |edge| {
        const target_index = package_map.get(edge.to) orelse return error.StaleEnvironment;
        const target = packages[target_index];
        var export_entries: std.ArrayList(v1_imports.ExportEntry) = .empty;
        for (target.exports) |export_entry| {
            try export_entries.append(allocator, .{
                .subpath = export_entry.subpath,
                .binding = export_entry.binding,
            });
        }
        try declarations.append(allocator, .{
            .id = edge.id,
            .alias = edge.alias,
            .allow_global_commands = edge.allow_global_commands,
            .exports = try export_entries.toOwnedSlice(allocator),
        });
        try targets.append(allocator, target_index);
    }
    const declaration_slice = try declarations.toOwnedSlice(allocator);
    const target_slice = try targets.toOwnedSlice(allocator);
    return .{
        .declarations = declaration_slice,
        .targets = target_slice,
        .table = v1_imports.Table.init(owner, declaration_slice),
    };
}

fn resolveCallback(context: *anyopaque, allocator: Allocator, importer: []const u8, importer_owner: ?[]const u8, specifier: []const u8) anyerror!module_graph.ResolvedPackageImport {
    const self: *Environment = @ptrCast(@alignCast(context));
    return resolveScopedInner(self, allocator, importer, importer_owner, specifier);
}

fn declaredCallback(context: *anyopaque, _: Allocator, package_owner: []const u8, export_subpath: ?[]const u8) anyerror!?declared_commands.DeclaredCommands {
    const self: *Environment = @ptrCast(@alignCast(context));
    const index = self.package_map.get(package_owner) orelse return null;
    // 入口が分からない import に package 全体の宣言を返さない。平坦化した
    // 索引は同名・異なる形状の別入口を取り違える。
    const subpath = export_subpath orelse return error.InvalidCommands;
    for (self.packages[index].declared_by_export) |entry| {
        if (std.mem.eql(u8, entry.subpath, subpath)) return entry.declared;
    }
    return error.InvalidCommands;
}

fn resolveScopedInner(
    self: *Environment,
    allocator: Allocator,
    importer: []const u8,
    importer_owner: ?[]const u8,
    specifier: []const u8,
) !module_graph.ResolvedPackageImport {
    const reference = stripPrefix(specifier) orelse return error.PackageNotFound;
    if (reference.len == 0) return error.PackageNotFound;

    const owner_key: ?[]const u8 = if (importer_owner) |owner| blk: {
        if (!self.package_map.contains(owner)) return error.StaleEnvironment;
        break :blk owner;
    } else packageForImporter(self, allocator, importer) catch null;
    const table_data = if (owner_key) |owner|
        self.owner_tables.get(owner) orelse return error.StaleEnvironment
    else
        self.root_table;

    const resolved = table_data.table.resolve(reference) catch |err| switch (err) {
        error.AmbiguousImport => return error.AmbiguousImport,
        error.UndeclaredSubpath => return error.UndeclaredSubpath,
        else => return error.PackageNotFound,
    };
    if (resolved.declaration_index >= table_data.targets.len) return error.StaleEnvironment;
    const target_index = table_data.targets[resolved.declaration_index];
    const target = self.packages[target_index];
    const export_entry = findExport(target.exports, resolved.subpath) orelse return error.ExportNotFound;

    if (resolved.binding != export_entry.binding) return error.StaleEnvironment;
    const node = findNode(&self.lock, self.profile, target.key) orelse return error.StaleEnvironment;

    var globals: std.ArrayList(module_graph.GlobalCommand) = .empty;
    if (resolved.binding == .global) {
        if (!resolved.allow_global_commands) return error.GlobalCommandsNotAllowed;
        if (owner_key != null and !self.root_table.table.allowsGlobalCommands(resolved.id)) {
            return error.GlobalCommandsNotAllowed;
        }
        if (!node.global) return error.StaleEnvironment;
        const export_global_commands = globalCommandsForExport(target, resolved.subpath) orelse
            return error.InvalidCommands;
        for (export_global_commands) |name| {
            if (self.global_names.get(name)) |existing| {
                if (!std.mem.eql(u8, existing, target.key)) return error.AmbiguousGlobalCommand;
            } else {
                try self.global_names.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, name), target.key);
            }
            try globals.append(allocator, .{ .name = try allocator.dupe(u8, name) });
        }
    }

    const lexical = try std.fs.path.join(allocator, &.{ target.root, export_entry.entry });
    const absolute = try std.fs.path.resolve(allocator, &.{lexical});
    if (!isWithin(target.root, absolute)) return error.UnsafePackagePath;
    try verifyRegularFileNoFollow(self.io, allocator, target.root, export_entry.entry);
    const actual = std.Io.Dir.cwd().realPathFileAlloc(self.io, absolute, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageNotFound,
    };
    if (!isWithin(target.root, actual)) return error.UnsafePackagePath;

    const namespace = try namespaceFor(allocator, resolved.local_name, resolved.subpath);
    const dispatch_namespace: ?[]const u8 = if (owner_key) |owner|
        try dispatchNamespace(allocator, owner, resolved.local_name, resolved.subpath)
    else
        null;
    const canonical_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target.key, resolved.subpath });
    return .{
        .path = actual,
        .canonical_id = canonical_id,
        .namespace = namespace,
        .dispatch_namespace = dispatch_namespace,
        .package_root = try allocator.dupe(u8, target.root),
        .package_owner = try allocator.dupe(u8, target.key),
        .export_subpath = try allocator.dupe(u8, resolved.subpath),
        .global_commands = try globals.toOwnedSlice(allocator),
    };
}

fn findNode(lock: *const v1_lock.Lock, profile_name: []const u8, key: []const u8) ?*const v1_lock.Node {
    const profile = lock.findProfile(profile_name) orelse return null;
    for (profile.nodes) |*node| {
        if (std.mem.eql(u8, node.key, key)) return node;
    }
    return null;
}

fn findExport(exports: []const Export, subpath: []const u8) ?Export {
    for (exports) |export_entry| {
        if (std.mem.eql(u8, export_entry.subpath, subpath)) return export_entry;
    }
    return null;
}

fn stripPrefix(specifier: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, specifier, "パッケージ:")) return specifier["パッケージ:".len..];
    if (std.mem.startsWith(u8, specifier, "pkg:")) return specifier["pkg:".len..];
    return null;
}

fn packageForImporter(self: *Environment, allocator: Allocator, importer: []const u8) !?[]const u8 {
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, importer, allocator) catch return null;
    var selected: ?[]const u8 = null;
    var selected_len: usize = 0;
    for (self.packages) |package| {
        if (isWithin(package.root, canonical) and package.root.len > selected_len) {
            selected = package.key;
            selected_len = package.root.len;
        }
    }
    return selected;
}

fn realPathDirAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var directory = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (root.len == 0 or path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path[root.len] == std.fs.path.sep;
}

fn namespaceFor(allocator: Allocator, local_name: []const u8, subpath: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const alias = if (std.mem.startsWith(u8, local_name, "@")) local_name[1..] else local_name;
    try appendNamespacePart(&result, allocator, alias, true);
    if (!std.mem.eql(u8, subpath, ".")) {
        try result.appendSlice(allocator, "__");
        try appendNamespacePart(&result, allocator, subpath[2..], false);
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

fn dispatchNamespace(allocator: Allocator, owner: []const u8, local_name: []const u8, subpath: []const u8) ![]u8 {
    const public = try namespaceFor(allocator, local_name, subpath);
    defer allocator.free(public);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ owner, public });
}

fn parseRuntime(text: []const u8) !types.Runtime {
    if (std.mem.eql(u8, text, "lnako")) return .lnako;
    if (std.mem.eql(u8, text, "cnako")) return .cnako;
    if (std.mem.eql(u8, text, "wnako")) return .wnako;
    return error.InvalidEnvironment;
}

fn parseKind(text: []const u8) !types.Kind {
    if (std.mem.eql(u8, text, "universal")) return .universal;
    if (std.mem.eql(u8, text, "esm")) return .esm;
    if (std.mem.eql(u8, text, "native-source")) return .@"native-source";
    if (std.mem.eql(u8, text, "native-prebuilt")) return .@"native-prebuilt";
    return error.InvalidEnvironment;
}

fn parseBinding(text: []const u8) !types.Binding {
    if (std.mem.eql(u8, text, "scoped")) return .scoped;
    if (std.mem.eql(u8, text, "global")) return .global;
    return error.InvalidEnvironment;
}

fn formatHash(buffer: *[71]u8, digest: [32]u8) []const u8 {
    const hex = "0123456789abcdef";
    buffer[0..7].* = "sha256:".*;
    for (digest, 0..) |byte, index| {
        buffer[7 + index * 2] = hex[byte >> 4];
        buffer[8 + index * 2] = hex[byte & 0x0f];
    }
    return buffer[0..71];
}

// ---------------------------------------------------------------------------
// 安全なファイル読み取り
// ---------------------------------------------------------------------------

fn readFileUnder(io: std.Io, allocator: Allocator, base: []const u8, relative: []const []const u8, max_bytes: usize) ![]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, base, .{ .follow_symlinks = false });
    defer dir.close(io);
    var index: usize = 0;
    while (index + 1 < relative.len) : (index += 1) {
        const component = relative[index];
        if (!validComponent(component)) return error.InvalidEnvironment;
        const stat = dir.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
        if (stat.kind != .directory) return error.NotDir;
        const next = try dir.openDir(io, component, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    const name = relative[relative.len - 1];
    if (!validComponent(name)) return error.InvalidEnvironment;
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    if (stat.kind != .file) return error.NotDir;
    return dir.readFileAlloc(io, name, allocator, .limited(max_bytes));
}

fn verifyDirectoryNoFollow(io: std.Io, base: []const u8, relative: []const []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, base, .{ .follow_symlinks = false });
    defer dir.close(io);
    for (relative) |component| {
        if (!validComponent(component)) return error.InvalidEnvironment;
        const stat = dir.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
        if (stat.kind != .directory) return error.NotDir;
        const next = try dir.openDir(io, component, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
}

fn verifyRegularFileNoFollow(io: std.Io, allocator: Allocator, base: []const u8, relative: []const u8) !void {
    _ = allocator;
    var dir = try std.Io.Dir.openDirAbsolute(io, base, .{ .follow_symlinks = false });
    defer dir.close(io);
    var parts = std.mem.splitScalar(u8, relative, '/');
    var component_opt = parts.next();
    while (component_opt) |component| {
        const next = parts.next();
        if (!validComponent(component)) return error.InvalidEnvironment;
        if (next == null) {
            const stat = dir.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
            if (stat.kind != .file) return error.NotDir;
            return;
        }
        const stat = dir.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
        if (stat.kind != .directory) return error.NotDir;
        const child = try dir.openDir(io, component, .{ .follow_symlinks = false });
        dir.close(io);
        dir = child;
        component_opt = next;
    }
    return error.InvalidEnvironment;
}

fn validComponent(component: []const u8) bool {
    return component.len > 0 and
        !std.mem.eql(u8, component, ".") and
        !std.mem.eql(u8, component, "..") and
        std.mem.indexOfScalar(u8, component, '\\') == null;
}

fn resolvePackageRoot(allocator: Allocator, io: std.Io, project_root: []const u8, generation_dir: []const u8, relative: []const u8) ![]const u8 {
    const joined = try std.fs.path.join(allocator, &.{ generation_dir, relative });
    const absolute = try std.fs.path.resolve(allocator, &.{joined});
    if (!isWithin(generation_dir, absolute)) return error.UnsafePackagePath;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, relative, '/');
    while (iterator.next()) |part| try parts.append(allocator, part);
    try verifyDirectoryNoFollow(io, generation_dir, parts.items);
    const actual = realPathDirAlloc(allocator, io, absolute) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StaleEnvironment,
    };
    if (!isWithin(project_root, actual) or !isWithin(generation_dir, actual)) {
        return error.UnsafePackagePath;
    }
    return actual;
}

// ---------------------------------------------------------------------------
// COMMANDS.json（scoped 命令の宣言索引）
// ---------------------------------------------------------------------------

/// `NAKO-PKG/COMMANDS.json` v1（`schema_version` + `exports`）を
/// `semantic.DeclaredCommands` へ写す。
///
/// v1 の `commands[]` は `{name, kind, args:[{name, josi}], ...}` を持ち、
/// 変数・定数は `constants[]` に分かれる。`kind` が関数か変数かを決めるので
/// あって、`args`/`josi` の空さで決めてはならない（0 引数関数を変数と
/// 誤分類しない）。必須ファイルの欠落・破損・上限超過、および環境の
/// `exports` との不一致は拒否し、package 全体の索引へ後退しない。
const LoadedCommands = struct {
    declared_by_export: []const ExportDeclaredCommands = &.{},
    global_by_export: []const ExportGlobalCommands = &.{},
};

fn globalCommandsForExport(package: Package, subpath: []const u8) ?[]const []const u8 {
    for (package.global_commands_by_export) |entry| {
        if (std.mem.eql(u8, entry.subpath, subpath)) return entry.names;
    }
    return null;
}

/// METADATA/environment の exports と COMMANDS の exports を突き合わせる。
/// キー集合・binding・`exports_global_commands` のどれかが欠けたら拒否する。
fn validateCommandsExports(
    exports: []const Export,
    exports_global_commands: bool,
    model: v1_metadata_commands.Model,
) !void {
    if (model.exports_global_commands != exports_global_commands) return error.InvalidCommands;
    if (model.exports.len != exports.len) return error.InvalidCommands;
    for (exports) |export_entry| {
        const command_export = model.findExport(export_entry.subpath) orelse
            return error.InvalidCommands;
        if (command_export.binding != export_entry.binding) return error.InvalidCommands;
    }
}

fn loadDeclaredCommands(
    allocator: Allocator,
    io: std.Io,
    package_root: []const u8,
    exports: []const Export,
    exports_global_commands: bool,
) !LoadedCommands {
    const bytes = readFileUnder(io, allocator, package_root, &.{ "NAKO-PKG", "COMMANDS.json" }, max_commands_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommands,
    };
    const parsed_value = std.json.parseFromSliceLeaky(Value, allocator, bytes, .{}) catch
        return error.InvalidCommands;
    const model = v1_metadata_commands.buildModel(allocator, parsed_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommands,
    };
    try validateCommandsExports(exports, exports_global_commands, model);

    var declared_by_export: std.ArrayList(ExportDeclaredCommands) = .empty;
    var global_by_export: std.ArrayList(ExportGlobalCommands) = .empty;
    for (model.exports) |export_entry| {
        var commands: std.ArrayList(declared_commands.DeclaredCommand) = .empty;
        var complete = true;
        for (export_entry.commands) |command| {
            const variable = commandKindIsVariable(command.kind) orelse {
                // 意味を決められない kind を関数/変数のどちらかへ推測しない。
                complete = false;
                continue;
            };
            if (variable) {
                if (command.args.len != 0) {
                    complete = false;
                    continue;
                }
                try commands.append(allocator, .{
                    .name = command.name,
                    .variable = true,
                });
                continue;
            }
            const args = try allocator.alloc([]const u8, command.args.len);
            const josi = try allocator.alloc([]const u8, command.args.len);
            for (command.args, 0..) |arg, index| {
                args[index] = arg.name;
                josi[index] = try commandArgJosi(allocator, arg.josi);
            }
            try commands.append(allocator, .{
                .name = command.name,
                .args = args,
                .josi = josi,
                .variable = false,
            });
        }
        for (export_entry.constants) |name| {
            if (name.len == 0) {
                complete = false;
                continue;
            }
            try commands.append(allocator, .{
                .name = name,
                .variable = true,
            });
        }
        try declared_by_export.append(allocator, .{
            .subpath = export_entry.subpath,
            .declared = .{
                .available = complete,
                .commands = try commands.toOwnedSlice(allocator),
            },
        });
        if (export_entry.binding != .global) continue;
        var export_global_names: std.ArrayList([]const u8) = .empty;
        for (export_entry.commands) |command| {
            try export_global_names.append(allocator, command.name);
        }
        try global_by_export.append(allocator, .{
            .subpath = export_entry.subpath,
            .names = try export_global_names.toOwnedSlice(allocator),
        });
    }
    return .{
        .declared_by_export = try declared_by_export.toOwnedSlice(allocator),
        .global_by_export = try global_by_export.toOwnedSlice(allocator),
    };
}

/// v1 `commands[].kind` の分類。`null` は未対応 kind（推測しない）。
fn commandKindIsVariable(kind: []const u8) ?bool {
    if (std.mem.eql(u8, kind, "function")) return false;
    if (std.mem.eql(u8, kind, "variable") or std.mem.eql(u8, kind, "constant")) return true;
    return null;
}

/// 1 仮引数の v1 `josi` 候補を `semantic.DeclaredCommand.josi` の表現へ写す。
/// 複数候補はユーザー定義関数と同じ `|` 区切りで保持する。候補なしは空文字列。
fn commandArgJosi(allocator: Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) return "";
    if (items.len == 1) return items[0];
    var joined: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, index| {
        if (index > 0) try joined.append(allocator, '|');
        try joined.appendSlice(allocator, item);
    }
    return joined.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn asObject(value: Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn asString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidEnvironment,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidEnvironment;
    return asString(value);
}

fn requiredInt(object: std.json.ObjectMap, key: []const u8) !i64 {
    return switch (object.get(key) orelse return error.InvalidEnvironment) {
        .integer => |number| number,
        else => error.InvalidEnvironment,
    };
}

fn requiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    return switch (object.get(key) orelse return error.InvalidEnvironment) {
        .bool => |value| value,
        else => error.InvalidEnvironment,
    };
}

fn requiredArray(object: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return switch (object.get(key) orelse return error.InvalidEnvironment) {
        .array => |array| array,
        else => error.InvalidEnvironment,
    };
}

fn parseStringArray(allocator: Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidEnvironment,
    };
    var result: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        try result.append(allocator, try allocator.dupe(u8, try asString(item)));
    }
    return result.toOwnedSlice(allocator);
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidEnvironment;
    }
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

test {
    _ = @import("v1_runtime_test.zig");
}
