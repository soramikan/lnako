//! ensureLock 向け npm root 収集・resolve・lock carrier 配線。
//!
//! `project.zig` から分離。呼出し側は `project.ensureLock` 経由のみ。
//! provider 本体は `npm.zig`、ここは Project/ResolveContext との接合。

const std = @import("std");
const diag = @import("diagnostics.zig");
const cache = @import("cache.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const npm_mod = @import("npm.zig");
const project_mod = @import("project.zig");

const Allocator = std.mem.Allocator;

const Error = project_mod.Error;
const Project = project_mod.Project;
const ResolveContext = project_mod.ResolveContext;
const PrepareOptions = project_mod.PrepareOptions;
const depIsGated = project_mod.depIsGated;
const depIsActivated = project_mod.depIsActivated;

pub fn collectNpmRootsImpl(
    gpa: Allocator,
    project: *const Project,
    ctx: *const ResolveContext,
    gated_root: *const std.StringHashMap(void),
    activated_root: *const std.StringHashMap(void),
) Error![]npm_mod.RootRequest {
    var list: std.ArrayList(npm_mod.RootRequest) = .empty;
    errdefer {
        for (list.items) |r| npm_mod.freeRootRequest(gpa, r);
        list.deinit(gpa);
    }
    // root: dependencies + dev_dependencies（いずれも feature ゲートを適用）
    try appendNpmRootsFromGroup(gpa, &list, &project.manifest.dependencies, gated_root, activated_root);
    try appendNpmRootsFromGroup(gpa, &list, &project.manifest.dev_dependencies, gated_root, activated_root);
    // path 依存: dependencies のみ（dev は消費側で解決しない）
    var it = ctx.locals.iterator();
    while (it.next()) |entry| {
        const local = entry.value_ptr.*;
        if (local.manifest) |*m| {
            try appendNpmRootsFromGroup(gpa, &list, &m.dependencies, &local.gated_deps, &local.activated_deps);
        }
    }
    return try list.toOwnedSlice(gpa);
}

pub fn appendNpmRootsFromGroup(
    gpa: Allocator,
    list: *std.ArrayList(npm_mod.RootRequest),
    group: *const manifest_mod.DependencyGroup,
    gated: *const std.StringHashMap(void),
    activated: *const std.StringHashMap(void),
) Error!void {
    const chunk = try npmRootsFromGroupFiltered(gpa, group, gated, activated);
    defer gpa.free(chunk);
    for (chunk) |r| try list.append(gpa, r);
}

pub fn npmRootsFromGroupFiltered(
    gpa: Allocator,
    group: *const manifest_mod.DependencyGroup,
    gated: *const std.StringHashMap(void),
    activated: *const std.StringHashMap(void),
) Error![]npm_mod.RootRequest {
    // rootsFromManifest と同じ構造だが group 1 つ + feature filter。
    var list: std.ArrayList(npm_mod.RootRequest) = .empty;
    errdefer {
        for (list.items) |root| npm_mod.freeRootRequest(gpa, root);
        list.deinit(gpa);
    }
    var it = group.npm.iterator();
    while (it.next()) |entry| {
        const alias = entry.key_ptr.*;
        const dep = entry.value_ptr.*;
        if (depIsGated(gated, dep.name, alias) and !depIsActivated(activated, dep.name, alias)) {
            continue;
        }
        if (dep.context) |ctx| {
            if (ctx.len == 0) return error.ResolveFailed;
        }
        var peers: std.ArrayList(npm_mod.PeerReq) = .empty;
        errdefer {
            for (peers.items) |p| {
                gpa.free(p.name);
                gpa.free(p.range_text);
            }
            peers.deinit(gpa);
        }
        var peer_it = dep.peer_dependencies.iterator();
        while (peer_it.next()) |peer| {
            const range_text = try gpa.dupe(u8, peer.value_ptr.text);
            try peers.append(gpa, .{
                .name = try gpa.dupe(u8, peer.key_ptr.*),
                .range = peer.value_ptr.*,
                .range_text = range_text,
            });
        }
        const optional_peers = try gpa.alloc([]const u8, dep.optional_peers.len);
        errdefer {
            for (optional_peers) |n| gpa.free(n);
            gpa.free(optional_peers);
        }
        for (dep.optional_peers, 0..) |name, i| optional_peers[i] = try gpa.dupe(u8, name);
        try list.append(gpa, .{
            .alias = try gpa.dupe(u8, alias),
            .name = try gpa.dupe(u8, dep.name),
            .range = dep.version,
            .range_text = try gpa.dupe(u8, dep.version_text),
            .context = if (dep.context) |c| try gpa.dupe(u8, c) else "",
            .peer_dependencies = try peers.toOwnedSlice(gpa),
            .optional_peers = optional_peers,
        });
    }
    return try list.toOwnedSlice(gpa);
}

/// 解決した npm instance を lock へ載せる。
/// root 用 carrier package は implementation=none + static source とし、
/// sync が実 tree を materialize しない（空 env record のみ）。
/// 既存 package がある場合も carrier を 1 つ追加して npmInstances を集約する
/// （宣言元 package への分散は #53 残ゲート）。
pub fn attachRootNpmInstances(
    lock: *lock_model.Lock,
    project: *const Project,
    instances: []const lock_model.NpmInstance,
) Error!void {
    if (instances.len == 0) return;
    const a = lock.arena.allocator();
    const name = project.manifest.package.name;
    const version_text = try std.fmt.allocPrint(a, "{f}", .{project.manifest.package.version});
    const id_text = try std.fmt.allocPrint(a, "npm-root:{s}@{s}", .{ name, version_text });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id_text, &digest, .{});
    const public_id = try std.fmt.allocPrint(a, "pkg:{s}", .{std.fmt.bytesToHex(digest, .lower)[0..32]});

    const npm_copy = try a.alloc(lock_model.NpmInstance, instances.len);
    for (instances, 0..) |inst, i| {
        const peers = try a.alloc(lock_model.PeerDependency, inst.peer_dependencies.len);
        for (inst.peer_dependencies, 0..) |p, j| {
            peers[j] = .{
                .name = try a.dupe(u8, p.name),
                .requirement = try a.dupe(u8, p.requirement),
            };
        }
        npm_copy[i] = .{
            .key = try a.dupe(u8, inst.key),
            .name = try a.dupe(u8, inst.name),
            .version = try a.dupe(u8, inst.version),
            .context = if (inst.context) |c| try a.dupe(u8, c) else null,
            .sha256 = if (inst.sha256) |s| try a.dupe(u8, s) else null,
            .url = if (inst.url) |u| try a.dupe(u8, u) else null,
            .peer_dependencies = peers,
        };
    }
    std.mem.sort(lock_model.NpmInstance, npm_copy, {}, struct {
        fn lt(_: void, x: lock_model.NpmInstance, y: lock_model.NpmInstance) bool {
            return std.mem.order(u8, x.key, y.key) == .lt;
        }
    }.lt);

    // empty blob sha256（validate は artifacts 必須、sync は implementation=none で空 materialize）
    const empty_sha = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const artifacts = try a.alloc(lock_model.Artifact, 1);
    artifacts[0] = .{
        .key = try a.dupe(u8, "source"),
        .kind = try a.dupe(u8, "source"),
        .type = try a.dupe(u8, "raw"),
        .sha256 = try a.dupe(u8, empty_sha),
    };
    const src = lock_model.Source{
        .kind = .static,
        .url = try a.dupe(u8, "lnako:npm-root-carrier"),
    };

    const entry = lock_model.PackageEntry{
        .id = public_id,
        .name = try a.dupe(u8, name),
        .version = version_text,
        .source = src,
        .resolved_from = src,
        .implementation = try a.dupe(u8, "none"),
        .artifacts = artifacts,
        .npm_instances = npm_copy,
    };

    const new_pkgs = try a.alloc(lock_model.PackageEntry, lock.packages.len + 1);
    new_pkgs[0] = entry;
    @memcpy(new_pkgs[1..], lock.packages);
    lock.packages = new_pkgs;

    if (lock.profile_packages.len > 0) {
        const new_pp = try a.alloc(lock_model.ProfilePackages, lock.profile_packages.len);
        for (lock.profile_packages, 0..) |pp, i| {
            const pkgs = try a.alloc(lock_model.PackageEntry, pp.packages.len + 1);
            pkgs[0] = entry;
            @memcpy(pkgs[1..], pp.packages);
            new_pp[i] = .{ .profile = pp.profile, .packages = pkgs };
        }
        lock.profile_packages = new_pp;
    }
}

pub fn resolveNpmForLock(
    gpa: Allocator,
    session: *fetch.Session,
    cache_store: ?*const cache.Store,
    project: *const Project,
    ctx: *const ResolveContext,
    opts: *const PrepareOptions,
    diagnostics: *diag.List,
    gated_root: *const std.StringHashMap(void),
    activated_root: *const std.StringHashMap(void),
) Error!?npm_mod.ResolveResult {
    const roots = collectNpmRootsImpl(gpa, project, ctx, gated_root, activated_root) catch |err| {
        if (err == error.ResolveFailed) {
            try diagnostics.addFmt(diag.E018_INVALID_NPM_CONTEXT, .err, "nako.toml", .{}, "npm dependency has an empty context", .{});
        }
        return err;
    };
    defer npm_mod.freeRootRequests(gpa, roots);
    if (roots.len == 0) return null;

    var owned_catalog: npm_mod.Catalog = .{};
    defer owned_catalog.deinit(gpa);
    const catalog: *const npm_mod.Catalog = if (opts.npm_catalog) |c| c else blk: {
        const base = opts.npm_registry_url orelse npm_mod.default_registry_url;
        npm_mod.fillCatalogForRoots(gpa, session, &owned_catalog, roots, base, diagnostics) catch |err| {
            session.reportDiagnostics(diagnostics) catch {};
            return err;
        };
        break :blk &owned_catalog;
    };

    const result = npm_mod.resolve(gpa, session, catalog, roots, cache_store, diagnostics) catch |err| {
        session.reportDiagnostics(diagnostics) catch {};
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.FileSystem => error.FileSystem,
            error.HashMismatch => error.ResolveFailed,
            error.Offline => error.ResolveFailed,
            else => error.ResolveFailed,
        };
    };
    return result;
}
