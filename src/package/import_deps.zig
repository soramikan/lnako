//! import 依存の収集（alias → lock package）。`sync` 時に manifest の
//! dependencies 宣言と lock の package 集合を照合し、`environment.json` の
//! dependency 表（`ImportDependency`）を組み立てる。
//! 同期の entry point は `sync.zig`、取得・検証本体は `sync_prepare.zig` にある。

const std = @import("std");
const diag = @import("diagnostics.zig");
const environment = @import("environment.zig");
const import_resolver = @import("import_resolver.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ LockInvalid, OutOfMemory };

// ---------------------------------------------------------------------------
// import 依存の収集（alias → lock package）
// ---------------------------------------------------------------------------

pub const ImportConstraint = union(enum) {
    version: semver.Range,
    path: []const u8,
    git: GitConstraint,
    http: HttpConstraint,

    pub fn matches(self: ImportConstraint, candidate: lock_model.PackageEntry) bool {
        switch (self) {
            .version => |range| {
                const source = candidate.source orelse candidate.resolved_from orelse return false;
                if (source.kind != .registry and source.kind != .static) return false;
                const version = semver.Version.parse(candidate.version) catch return false;
                return range.satisfies(version);
            },
            .path => |path| {
                const source = candidate.source orelse candidate.resolved_from orelse return false;
                return source.kind == .path and source.path != null and std.mem.eql(u8, source.path.?, path);
            },
            .git => |dependency| {
                const source = candidate.source orelse candidate.resolved_from orelse return false;
                if (source.kind != .git or source.url == null or source.commit == null) return false;
                if (!std.mem.eql(u8, source.url.?, dependency.url) or !std.mem.startsWith(u8, source.commit.?, dependency.commit)) return false;
                return optionalStringEql(source.path, dependency.path);
            },
            .http => |dependency| {
                const source = candidate.source orelse candidate.resolved_from orelse return false;
                return source.kind == .http and source.url != null and source.hash != null and
                    std.mem.eql(u8, source.url.?, dependency.url) and lock_model.hashEql(source.hash.?, dependency.hash);
            },
        }
    }
};

fn matchesDependency(
    candidate: lock_model.PackageEntry,
    manifest_key: []const u8,
    constraint: ImportConstraint,
    public_id: ?[]const u8,
) bool {
    if (!constraint.matches(candidate)) return false;
    if (public_id) |id| return std.mem.eql(u8, candidate.id, id);
    return switch (constraint) {
        .version => registryNameMatches(candidate, manifest_key),
        // Non-registry dependency identity is fully determined by its source
        // constraints. The manifest table key need not match [package].name.
        .path, .git, .http => true,
    };
}

fn registryNamePart(manifest_key: []const u8) []const u8 {
    const unscoped = if (std.mem.startsWith(u8, manifest_key, "@")) manifest_key[1..] else manifest_key;
    const slash = std.mem.lastIndexOfScalar(u8, unscoped, '/') orelse return manifest_key;
    return unscoped[slash + 1 ..];
}

fn registryNameMatches(candidate: lock_model.PackageEntry, manifest_key: []const u8) bool {
    if (std.mem.indexOfScalar(u8, manifest_key, '/') == null) return std.mem.eql(u8, candidate.name, manifest_key);
    if (!std.mem.eql(u8, candidate.name, registryNamePart(manifest_key))) return false;
    const source = candidate.source orelse candidate.resolved_from orelse return false;
    if (source.kind != .registry and source.kind != .static) return false;
    const url = source.url orelse return false;
    const owner_name = if (std.mem.startsWith(u8, manifest_key, "@")) manifest_key[1..] else manifest_key;
    if (!std.mem.endsWith(u8, url, owner_name)) return false;
    const prefix_len = url.len - owner_name.len;
    return prefix_len > 0 and url[prefix_len - 1] == '/';
}

fn defaultImportAlias(manifest_key: []const u8, constraint: ImportConstraint) []const u8 {
    return switch (constraint) {
        .version => registryNamePart(manifest_key),
        .path, .git, .http => manifest_key,
    };
}

const GitConstraint = struct { url: []const u8, commit: []const u8, path: ?[]const u8 };
const HttpConstraint = struct { url: []const u8, hash: []const u8 };

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}

/// Build the root scope's package key set from root-manifest declarations first.
/// Transitive lock entries are not candidates for root aliases unless they match
/// the direct declaration's package identity/source/version constraints.
pub fn collectRootDependencyIds(
    allocator: Allocator,
    lock_entries: []const lock_model.PackageEntry,
    manifest: *const manifest_mod.Manifest,
    diagnostics: *diag.List,
) Error![]const []const u8 {
    return collectRootDependencyIdsForProfile(allocator, lock_entries, manifest, null, diagnostics);
}

pub fn collectRootDependencyIdsForProfile(
    allocator: Allocator,
    lock_entries: []const lock_model.PackageEntry,
    manifest: *const manifest_mod.Manifest,
    active_profile: ?[]const u8,
    diagnostics: *diag.List,
) Error![]const []const u8 {
    var ids = std.ArrayListUnmanaged([]const u8).empty;
    var pkg = manifest.dependencies.pkg.iterator();
    while (pkg.next()) |item| {
        const dependency = item.value_ptr.*;
        if (!dependencyMatchesProfile(dependency.profile, active_profile)) continue;
        try appendCandidateIds(allocator, &ids, lock_entries, dependency.name, .{ .version = dependency.version }, dependency.public_id, diagnostics);
    }
    var path = manifest.dependencies.path.iterator();
    while (path.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendCandidateIds(allocator, &ids, lock_entries, dependency.name, .{ .path = dependency.path }, null, diagnostics);
    }
    var git = manifest.dependencies.git.iterator();
    while (git.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendCandidateIds(allocator, &ids, lock_entries, dependency.name, .{ .git = .{ .url = dependency.url, .commit = dependency.commit, .path = dependency.path } }, null, diagnostics);
    }
    var http = manifest.dependencies.http.iterator();
    while (http.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendCandidateIds(allocator, &ids, lock_entries, dependency.name, .{ .http = .{ .url = dependency.url, .hash = dependency.hash } }, null, diagnostics);
    }
    return try ids.toOwnedSlice(allocator);
}

fn appendCandidateIds(
    allocator: Allocator,
    ids: *std.ArrayListUnmanaged([]const u8),
    lock_entries: []const lock_model.PackageEntry,
    name: []const u8,
    constraint: ImportConstraint,
    public_id: ?[]const u8,
    diagnostics: *diag.List,
) Error!void {
    var root_matches = std.ArrayListUnmanaged([]const u8).empty;
    defer root_matches.deinit(allocator);
    var all_matches = std.ArrayListUnmanaged([]const u8).empty;
    defer all_matches.deinit(allocator);
    for (lock_entries) |candidate| {
        if (!matchesDependency(candidate, name, constraint, public_id)) continue;
        try all_matches.append(allocator, candidate.id);
        if (!hasIncomingLockEdge(lock_entries, candidate.id)) try root_matches.append(allocator, candidate.id);
    }

    // A v1 lock encodes the resolved graph as package->dependency IDs, without
    // a synthetic root node. Its root direct package IDs are therefore graph
    // roots (IDs with no incoming package edge). Prefer those IDs over matching
    // every transitive entry by the manifest's broad version range. If a single
    // matching lock node is shared transitively, it is still unambiguous.
    if (root_matches.items.len == 0 and all_matches.items.len > 1) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml.dependencies", .{}, "dependency key \"{s}\" matches multiple lock packages {s} and {s}; regenerate the lock with schema v2 or specify a public ID", .{ name, all_matches.items[0], all_matches.items[1] });
        return error.LockInvalid;
    }
    const candidates = if (root_matches.items.len != 0) root_matches.items else if (all_matches.items.len == 1) all_matches.items else &.{};
    for (candidates) |candidate_id| {
        var already_added = false;
        for (ids.items) |existing| if (std.mem.eql(u8, existing, candidate_id)) {
            already_added = true;
            break;
        };
        if (!already_added) try ids.append(allocator, candidate_id);
    }
}

/// `active_profile == null` は「profile 選択なしの sync」を意味し、宣言側の
/// profile 制約を適用せず全てに一致する。import_resolver 側の同名述語は
/// 「環境検証時の active profile」で null = 無profile環境とみなし、profile
/// 要求を持つ依存は一致しない（fail-closed）。呼出し側はどちらも現状
/// 非null を渡すため実害はないが、null 意味は対称でない点に注意。
fn dependencyMatchesProfile(dependency_profile: ?[]const u8, active_profile: ?[]const u8) bool {
    const selected = active_profile orelse return true;
    const required = dependency_profile orelse return true;
    return std.mem.eql(u8, required, selected);
}

fn hasIncomingLockEdge(lock_entries: []const lock_model.PackageEntry, package_id: []const u8) bool {
    for (lock_entries) |entry| for (entry.dependencies) |dependency_id| {
        if (std.mem.eql(u8, dependency_id, package_id)) return true;
    };
    return false;
}

/// Declared package-like dependencies are emitted into the owning import scope.
/// NPM dependencies do not provide Nako exports and are intentionally omitted.
pub fn collectImportDependencies(
    allocator: Allocator,
    lock_entries: []const lock_model.PackageEntry,
    allowed_ids: ?[]const []const u8,
    edge_owner: ?[]const u8,
    manifest: *const manifest_mod.Manifest,
    diagnostics: *diag.List,
) Error![]const environment.ImportDependency {
    return collectImportDependenciesForProfile(allocator, lock_entries, allowed_ids, edge_owner, manifest, null, diagnostics);
}

pub fn collectImportDependenciesForProfile(
    allocator: Allocator,
    lock_entries: []const lock_model.PackageEntry,
    allowed_ids: ?[]const []const u8,
    edge_owner: ?[]const u8,
    manifest: *const manifest_mod.Manifest,
    active_profile: ?[]const u8,
    diagnostics: *diag.List,
) Error![]const environment.ImportDependency {
    var result = std.ArrayListUnmanaged(environment.ImportDependency).empty;
    var pkg = manifest.dependencies.pkg.iterator();
    while (pkg.next()) |item| {
        const dependency = item.value_ptr.*;
        if (!dependencyMatchesProfile(dependency.profile, active_profile)) continue;
        try appendImportDependency(allocator, &result, lock_entries, allowed_ids, edge_owner, dependency.name, .{ .version = dependency.version }, dependency.public_id, dependency.alias, hasOwnerNameAliasCollision(manifest, dependency.name, active_profile), diagnostics);
    }
    var path = manifest.dependencies.path.iterator();
    while (path.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendImportDependency(allocator, &result, lock_entries, allowed_ids, edge_owner, dependency.name, .{ .path = dependency.path }, null, null, false, diagnostics);
    }
    var git = manifest.dependencies.git.iterator();
    while (git.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendImportDependency(allocator, &result, lock_entries, allowed_ids, edge_owner, dependency.name, .{ .git = .{ .url = dependency.url, .commit = dependency.commit, .path = dependency.path } }, null, dependency.alias, false, diagnostics);
    }
    var http = manifest.dependencies.http.iterator();
    while (http.next()) |item| {
        const dependency = item.value_ptr.*;
        try appendImportDependency(allocator, &result, lock_entries, allowed_ids, edge_owner, dependency.name, .{ .http = .{ .url = dependency.url, .hash = dependency.hash } }, null, dependency.alias, false, diagnostics);
    }
    return try result.toOwnedSlice(allocator);
}

fn hasOwnerNameAliasCollision(manifest: *const manifest_mod.Manifest, name: []const u8, active_profile: ?[]const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') == null) return false;
    const derived_alias = registryNamePart(name);
    return mapHasAliasCollision(manifest_mod.PkgDependency, manifest.dependencies.pkg, name, derived_alias, true, active_profile) or
        mapHasAliasCollision(manifest_mod.PathDependency, manifest.dependencies.path, null, derived_alias, false, active_profile) or
        mapHasAliasCollision(manifest_mod.GitDependency, manifest.dependencies.git, null, derived_alias, false, active_profile) or
        mapHasAliasCollision(manifest_mod.HttpDependency, manifest.dependencies.http, null, derived_alias, false, active_profile);
}

fn mapHasAliasCollision(comptime Dependency: type, dependencies: std.StringHashMapUnmanaged(Dependency), current_key: ?[]const u8, alias: []const u8, scoped_registry_keys: bool, active_profile: ?[]const u8) bool {
    var iterator = dependencies.iterator();
    while (iterator.next()) |item| {
        if (comptime @hasField(Dependency, "profile")) {
            if (!dependencyMatchesProfile(item.value_ptr.profile, active_profile)) continue;
        }
        if (current_key) |key| if (std.mem.eql(u8, item.key_ptr.*, key)) continue;
        if (std.mem.eql(u8, item.key_ptr.*, alias)) return true;
        if (comptime @hasField(Dependency, "alias")) {
            if (@field(item.value_ptr.*, "alias")) |explicit_alias| {
                if (std.mem.eql(u8, explicit_alias, alias)) return true;
            }
        }
        if (scoped_registry_keys and std.mem.indexOfScalar(u8, item.key_ptr.*, '/') != null and
            std.mem.eql(u8, registryNamePart(item.key_ptr.*), alias)) return true;
    }
    return false;
}

fn appendImportDependency(
    allocator: Allocator,
    result: *std.ArrayListUnmanaged(environment.ImportDependency),
    lock_entries: []const lock_model.PackageEntry,
    allowed_ids: ?[]const []const u8,
    edge_owner: ?[]const u8,
    name: []const u8,
    constraint: ImportConstraint,
    public_id: ?[]const u8,
    extra_alias: ?[]const u8,
    suppress_derived_alias: bool,
    diagnostics: *diag.List,
) Error!void {
    var target: ?[]const u8 = null;
    var ambiguous_with: ?[]const u8 = null;
    for (lock_entries) |candidate| {
        if (allowed_ids) |ids| {
            var direct = false;
            for (ids) |id| if (std.mem.eql(u8, id, candidate.id)) {
                direct = true;
                break;
            };
            if (!direct) continue;
        }
        if (!matchesDependency(candidate, name, constraint, public_id)) continue;
        if (target) |previous| {
            if (!std.mem.eql(u8, previous, candidate.id) and ambiguous_with == null) ambiguous_with = candidate.id;
        } else {
            target = candidate.id;
        }
    }
    if (ambiguous_with) |other_id| {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml.dependencies", .{}, "dependency key \"{s}\" matches multiple lock packages {s} and {s}", .{ name, target.?, other_id });
        return error.LockInvalid;
    }
    if (target == null) {
        // In schema-v2, the allowed edge list is authoritative. A matching
        // package omitted from it means the lock cannot bind that declared
        // dependency for the owning manifest scope.
        if (allowed_ids != null) for (lock_entries) |candidate| {
            if (!matchesDependency(candidate, name, constraint, public_id)) continue;
            if (edge_owner) |owner| {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "dependency key \"{s}\" matches lock package {s}, but that package is not declared in the dependencies of package \"{s}\"", .{ name, candidate.id, owner });
            } else {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.rootDependencies", .{}, "root dependency key \"{s}\" matches lock package {s}, but that package is not declared in rootDependencies for the active profile", .{ name, candidate.id });
            }
            return error.LockInvalid;
        };
        // 一致候補が lock 内に一つも無い場合も同様に不整合。宣言が有効な依存
        // （profile 不一致は呼出し側が既に skip）に対して lock が package を
        // 提供しないのは manifest と lock の乖離であり、alias を欠落させた
        // 環境を公開してはならない。
        if (edge_owner) |owner| {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock", .{}, "dependency key \"{s}\" has no matching lock package for the dependencies of package \"{s}\"", .{ name, owner });
        } else {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.lock.rootDependencies", .{}, "root dependency key \"{s}\" has no matching lock package", .{name});
        }
        return error.LockInvalid;
    }
    const package_key = target.?;
    // Manifest table keys are valid dependency aliases in their own right.
    // Preserve them even when an explicit alias is also declared.
    try appendScopedAlias(allocator, result, name, package_key, diagnostics);
    if (extra_alias) |alias| {
        try appendScopedAlias(allocator, result, alias, package_key, diagnostics);
    } else if (!suppress_derived_alias) {
        try appendDerivedScopedAlias(allocator, result, defaultImportAlias(name, constraint), package_key, diagnostics);
    }
}

fn appendDerivedScopedAlias(
    allocator: Allocator,
    result: *std.ArrayListUnmanaged(environment.ImportDependency),
    alias: []const u8,
    package_key: []const u8,
    diagnostics: *diag.List,
) Error!void {
    for (result.items) |existing| {
        if (!std.mem.eql(u8, existing.alias, alias)) continue;
        if (std.mem.eql(u8, existing.package_key, package_key)) return;
        // Never replace a table key or explicit alias with a derived short
        // alias. The manifest-level collision check suppresses ambiguous
        // derived aliases before this point.
        return;
    }
    try appendScopedAlias(allocator, result, alias, package_key, diagnostics);
}

pub fn appendScopedAlias(
    allocator: Allocator,
    result: *std.ArrayListUnmanaged(environment.ImportDependency),
    alias: []const u8,
    package_key: []const u8,
    diagnostics: *diag.List,
) Error!void {
    // 公開namespaceはaliasを識別子化して生成するため、正規化後に一致する異名
    // alias（`my-util` と `my_util` など）は同じ修飾名namespaceを占有する。
    // 別packageを指す正規化衝突は環境側で `{ns}__{名}` が両packageに解釈
    // され得るため、発行段階で拒否する。
    const normalized = try import_resolver.namespaceFor(allocator, alias, null);
    defer allocator.free(normalized);
    // 正規化後に空になる alias（`@` 単体等）は公開 namespace を構成できず、
    // native plugin 登録は空 namespace を拒否・ESM は無修飾登録へ落ちて
    // 解析器の `{ns}__{名}` 参照と乖離する。発行段階で拒否する。
    if (normalized.len == 0) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml.dependencies", .{}, "dependency alias \"{s}\" normalizes to an empty namespace", .{alias});
        return error.LockInvalid;
    }
    for (result.items) |existing| {
        if (std.mem.eql(u8, existing.alias, alias)) {
            if (std.mem.eql(u8, existing.package_key, package_key)) return;
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml.dependencies", .{}, "dependency alias \"{s}\" conflicts between lock packages {s} and {s}", .{ alias, existing.package_key, package_key });
            return error.LockInvalid;
        }
        const existing_normalized = try import_resolver.namespaceFor(allocator, existing.alias, null);
        defer allocator.free(existing_normalized);
        if (!std.mem.eql(u8, existing_normalized, normalized)) continue;
        if (std.mem.eql(u8, existing.package_key, package_key)) continue;
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, "nako.toml.dependencies", .{}, "dependency alias \"{s}\" conflicts with \"{s}\" between lock packages {s} and {s}", .{ alias, existing.alias, existing.package_key, package_key });
        return error.LockInvalid;
    }
    try result.append(allocator, .{ .alias = alias, .package_key = package_key });
}
