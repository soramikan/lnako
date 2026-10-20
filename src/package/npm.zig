//! npm 補助依存の取得・文脈別 instance 解決（#53）。
//!
//! - registry / ローカル fixture から packument と tarball を取る
//! - integrity（`sha512-` / `sha256-`）を検証し cache へ格納する
//! - 通常・optional・peer を文脈 (context) ごとに分離する
//! - Node lifecycle script・npm CLI は起動しない
//!
//! QuickJS への ESM 登録は #54。ここでは lock の `npmInstances` と cache まで。

const std = @import("std");
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const cache = @import("cache.zig");
const cache_key = @import("cache_key.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    ResolveFailed,
    OutOfMemory,
    Canceled,
    FileSystem,
} || fetch.Error;

/// nako.toml `dependencies.npm` 1 エントリから起こす root 要求。
pub const RootRequest = struct {
    /// manifest 上のキー（alias）。
    alias: []const u8,
    name: []const u8,
    range: semver.Range,
    range_text: []const u8,
    /// 空なら `name` を文脈とする（SPEC §3.4.2）。
    context: []const u8 = "",
    peer_dependencies: []const PeerReq = &.{},
    optional_peers: []const []const u8 = &.{},
};

pub const PeerReq = struct {
    name: []const u8,
    range: semver.Range,
    range_text: []const u8,
};

pub const ResolvedInstance = struct {
    key: []const u8,
    name: []const u8,
    version: []const u8,
    context: []const u8,
    sha256: []const u8,
    url: []const u8,
    integrity: []const u8,
    peer_dependencies: []const lock_model.PeerDependency,
};

pub const ResolveResult = struct {
    arena: std.heap.ArenaAllocator,
    instances: []const ResolvedInstance,

    pub fn deinit(self: *ResolveResult) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn toLockInstances(self: *const ResolveResult, gpa: Allocator) Allocator.Error![]lock_model.NpmInstance {
        const out = try gpa.alloc(lock_model.NpmInstance, self.instances.len);
        for (self.instances, 0..) |inst, i| {
            const peers = try gpa.alloc(lock_model.PeerDependency, inst.peer_dependencies.len);
            for (inst.peer_dependencies, 0..) |p, j| {
                peers[j] = .{
                    .name = try gpa.dupe(u8, p.name),
                    .requirement = try gpa.dupe(u8, p.requirement),
                };
            }
            out[i] = .{
                .key = try gpa.dupe(u8, inst.key),
                .name = try gpa.dupe(u8, inst.name),
                .version = try gpa.dupe(u8, inst.version),
                .context = if (inst.context.len == 0 or std.mem.eql(u8, inst.context, inst.name))
                    null
                else
                    try gpa.dupe(u8, inst.context),
                .sha256 = try gpa.dupe(u8, inst.sha256),
                .url = try gpa.dupe(u8, inst.url),
                .peer_dependencies = peers,
            };
        }
        return out;
    }
};

/// ローカル fixture または remote registry の版メタ。
pub const VersionMeta = struct {
    version: []const u8,
    dependencies: []const NamedRange = &.{},
    optional_dependencies: []const NamedRange = &.{},
    peer_dependencies: []const NamedRange = &.{},
    /// peerDependenciesMeta.<name>.optional == true 相当。
    optional_peers: []const []const u8 = &.{},
    tarball_url: []const u8,
    integrity: []const u8,
    /// fixture 用。null なら URL から取得する。
    tarball_bytes: ?[]const u8 = null,
};

pub const NamedRange = struct {
    name: []const u8,
    range_text: []const u8,
};

pub const PackageMeta = struct {
    name: []const u8,
    versions: []const VersionMeta,
};

/// 解決に使う npm メタデータ源。テストは `packages` を直接埋め、
/// 本番は packument 取得で埋める。
pub const Catalog = struct {
    packages: std.StringHashMapUnmanaged(PackageMeta) = .empty,

    pub fn deinit(self: *Catalog, gpa: Allocator) void {
        self.packages.deinit(gpa);
    }

    pub fn put(self: *Catalog, gpa: Allocator, meta: PackageMeta) !void {
        try self.packages.put(gpa, meta.name, meta);
    }

    pub fn get(self: *const Catalog, name: []const u8) ?PackageMeta {
        return self.packages.get(name);
    }
};

const Want = struct {
    name: []const u8,
    range: semver.Range,
    range_text: []const u8,
    context: []const u8,
    optional: bool,
    is_peer: bool,
};

const Chosen = struct {
    version: []const u8,
    meta: VersionMeta,
};

/// `RootRequest` 群を文脈別に解決し、tarball を検証して cache へ載せる。
pub fn resolve(
    gpa: Allocator,
    session: *fetch.Session,
    catalog: *const Catalog,
    roots: []const RootRequest,
    cache_store: ?*const cache.Store,
    diagnostics: *diag.List,
) Error!ResolveResult {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_impl.deinit();
    const a = arena_impl.allocator();

    var queue: std.ArrayList(Want) = .empty;
    for (roots) |root| {
        const ctx = effectiveContext(root.context, root.name);
        if (ctx.len == 0) {
            try diagnostics.addFmt(diag.E018_INVALID_NPM_CONTEXT, .err, root.alias, .{}, "npm dependency \"{s}\" has an empty context", .{root.alias});
            return error.ResolveFailed;
        }
        try queue.append(a, .{
            .name = try a.dupe(u8, root.name),
            .range = root.range,
            .range_text = try a.dupe(u8, root.range_text),
            .context = try a.dupe(u8, ctx),
            .optional = false,
            .is_peer = false,
        });
        for (root.peer_dependencies) |peer| {
            const optional = isOptionalPeer(root.optional_peers, peer.name);
            try queue.append(a, .{
                .name = try a.dupe(u8, peer.name),
                .range = peer.range,
                .range_text = try a.dupe(u8, peer.range_text),
                .context = try a.dupe(u8, ctx),
                .optional = optional,
                .is_peer = true,
            });
        }
    }

    // key = name \0 context → Chosen
    var chosen: std.StringHashMapUnmanaged(Chosen) = .empty;
    var instances: std.ArrayList(ResolvedInstance) = .empty;

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const want = queue.items[qi];
        const map_key = try contextKey(a, want.name, want.context);

        if (chosen.get(map_key)) |existing| {
            const ver = semver.Version.parse(existing.version) catch {
                try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, want.name, .{}, "invalid resolved npm version \"{s}\"", .{existing.version});
                return error.ResolveFailed;
            };
            if (want.range.satisfies(ver)) continue;
            if (want.is_peer and want.optional) continue;
            if (want.is_peer) {
                try diagnostics.addFmt(
                    diag.E017_NPM_PEER_CONFLICT,
                    .err,
                    want.name,
                    .{},
                    "npm peer \"{s}\"@{s} conflicts with resolved {s}@{s} in context \"{s}\"",
                    .{ want.name, want.range_text, want.name, existing.version, want.context },
                );
                return error.ResolveFailed;
            }
            try diagnostics.addFmt(
                diag.E003_CONFLICTING_VERSIONS,
                .err,
                want.name,
                .{},
                "npm package \"{s}\" requires {s} but context \"{s}\" already selected {s}",
                .{ want.name, want.range_text, want.context, existing.version },
            );
            return error.ResolveFailed;
        }

        const pkg = catalog.get(want.name) orelse {
            if (want.optional) continue;
            try diagnostics.addFmt(
                diag.E013_MISSING_PACKAGE,
                .err,
                want.name,
                .{},
                "npm package \"{s}\" was not found in the catalog",
                .{want.name},
            );
            return error.ResolveFailed;
        };

        const picked = pickVersion(pkg, want.range) orelse {
            if (want.optional) continue;
            if (want.is_peer) {
                try diagnostics.addFmt(
                    diag.E017_NPM_PEER_CONFLICT,
                    .err,
                    want.name,
                    .{},
                    "npm peer \"{s}\"@{s} is not satisfied in context \"{s}\"",
                    .{ want.name, want.range_text, want.context },
                );
                return error.ResolveFailed;
            }
            try diagnostics.addFmt(
                diag.E003_CONFLICTING_VERSIONS,
                .err,
                want.name,
                .{},
                "no version of npm package \"{s}\" satisfies {s}",
                .{ want.name, want.range_text },
            );
            return error.ResolveFailed;
        };

        // 未対応の依存指定（file:/git+/workspace: 等）を黙殺せず診断する。
        try rejectUnsupportedRanges(diagnostics, picked);

        const tarball_owned = try acquireTarball(gpa, session, cache_store, picked);
        defer freeAcquiredTarball(gpa, picked, tarball_owned);
        const tarball = tarball_owned.bytes;
        const sha256 = try fetch.sha256Hex(a, tarball);
        const sha256_field = try std.fmt.allocPrint(a, "sha256:{s}", .{sha256});

        const peers_out = try a.alloc(lock_model.PeerDependency, picked.peer_dependencies.len);
        for (picked.peer_dependencies, 0..) |p, i| {
            peers_out[i] = .{
                .name = try a.dupe(u8, p.name),
                .requirement = try a.dupe(u8, p.range_text),
            };
        }
        std.mem.sort(lock_model.PeerDependency, peers_out, {}, struct {
            fn lt(_: void, x: lock_model.PeerDependency, y: lock_model.PeerDependency) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);

        const key = try instanceKey(a, want.name, picked.version, want.context);
        try instances.append(a, .{
            .key = key,
            .name = try a.dupe(u8, want.name),
            .version = try a.dupe(u8, picked.version),
            .context = try a.dupe(u8, want.context),
            .sha256 = sha256_field,
            .url = try a.dupe(u8, picked.tarball_url),
            .integrity = try a.dupe(u8, picked.integrity),
            .peer_dependencies = peers_out,
        });
        try chosen.put(a, map_key, .{ .version = picked.version, .meta = picked });

        // 通常依存
        for (picked.dependencies) |dep| {
            const range = try parseRangeOrDiagnose(a, diagnostics, dep.name, dep.range_text);
            try queue.append(a, .{
                .name = try a.dupe(u8, dep.name),
                .range = range,
                .range_text = try a.dupe(u8, dep.range_text),
                .context = try a.dupe(u8, want.context),
                .optional = false,
                .is_peer = false,
            });
        }
        for (picked.optional_dependencies) |dep| {
            const range = parseRangeOrDiagnose(a, diagnostics, dep.name, dep.range_text) catch continue;
            try queue.append(a, .{
                .name = try a.dupe(u8, dep.name),
                .range = range,
                .range_text = try a.dupe(u8, dep.range_text),
                .context = try a.dupe(u8, want.context),
                .optional = true,
                .is_peer = false,
            });
        }
        for (picked.peer_dependencies) |dep| {
            const range = try parseRangeOrDiagnose(a, diagnostics, dep.name, dep.range_text);
            try queue.append(a, .{
                .name = try a.dupe(u8, dep.name),
                .range = range,
                .range_text = try a.dupe(u8, dep.range_text),
                .context = try a.dupe(u8, want.context),
                .optional = isOptionalPeer(picked.optional_peers, dep.name),
                .is_peer = true,
            });
        }
    }

    std.mem.sort(ResolvedInstance, instances.items, {}, struct {
        fn lt(_: void, x: ResolvedInstance, y: ResolvedInstance) bool {
            return std.mem.order(u8, x.key, y.key) == .lt;
        }
    }.lt);

    return .{
        .arena = arena_impl,
        .instances = instances.items,
    };
}

/// manifest の npm 依存 group から root 要求を集める。
/// 返り値と内部文字列は `gpa` 所有。呼出し側が free する。
pub fn rootsFromManifest(gpa: Allocator, manifest: *const manifest_mod.Manifest) Error![]RootRequest {
    var list: std.ArrayList(RootRequest) = .empty;
    errdefer {
        for (list.items) |root| freeRootRequest(gpa, root);
        list.deinit(gpa);
    }
    for ([_]*const manifest_mod.DependencyGroup{ &manifest.dependencies, &manifest.dev_dependencies }) |group| {
        var it = group.npm.iterator();
        while (it.next()) |entry| {
            const dep = entry.value_ptr.*;
            if (dep.context) |ctx| {
                if (ctx.len == 0) return error.ResolveFailed;
            }
            var peers: std.ArrayList(PeerReq) = .empty;
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

            const peer_slice = try peers.toOwnedSlice(gpa);
            try list.append(gpa, .{
                .alias = try gpa.dupe(u8, entry.key_ptr.*),
                .name = try gpa.dupe(u8, dep.name),
                .range = dep.version,
                .range_text = try gpa.dupe(u8, dep.version_text),
                .context = if (dep.context) |c| try gpa.dupe(u8, c) else "",
                .peer_dependencies = peer_slice,
                .optional_peers = optional_peers,
            });
        }
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeRootRequest(gpa: Allocator, root: RootRequest) void {
    gpa.free(root.alias);
    gpa.free(root.name);
    gpa.free(root.range_text);
    if (root.context.len != 0) gpa.free(root.context);
    for (root.peer_dependencies) |p| {
        gpa.free(p.name);
        gpa.free(p.range_text);
    }
    gpa.free(root.peer_dependencies);
    for (root.optional_peers) |n| gpa.free(n);
    gpa.free(root.optional_peers);
}

pub fn freeRootRequests(gpa: Allocator, roots: []RootRequest) void {
    for (roots) |root| freeRootRequest(gpa, root);
    gpa.free(roots);
}

pub fn effectiveContext(context: []const u8, name: []const u8) []const u8 {
    return if (context.len == 0) name else context;
}

fn contextKey(a: Allocator, name: []const u8, context: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ name, context });
}

fn instanceKey(a: Allocator, name: []const u8, version: []const u8, context: []const u8) ![]u8 {
    if (context.len == 0 or std.mem.eql(u8, context, name)) {
        return std.fmt.allocPrint(a, "{s}@{s}", .{ name, version });
    }
    return std.fmt.allocPrint(a, "{s}@{s}#{s}", .{ name, version, context });
}

fn isOptionalPeer(optional_peers: []const []const u8, name: []const u8) bool {
    for (optional_peers) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

fn pickVersion(pkg: PackageMeta, range: semver.Range) ?VersionMeta {
    var best: ?VersionMeta = null;
    var best_ver: ?semver.Version = null;
    for (pkg.versions) |meta| {
        const ver = semver.Version.parse(meta.version) catch continue;
        if (!range.satisfies(ver)) continue;
        if (best_ver) |cur| {
            if (semver.Version.order(ver, cur) == .gt) {
                best = meta;
                best_ver = ver;
            }
        } else {
            best = meta;
            best_ver = ver;
        }
    }
    return best;
}

fn parseRangeOrDiagnose(a: Allocator, diagnostics: *diag.List, name: []const u8, text: []const u8) Error!semver.Range {
    return semver.Range.parse(a, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diagnostics.addFmt(diag.E025_INVALID_RANGE, .err, name, .{}, "invalid npm version range \"{s}\" for \"{s}\"", .{ text, name });
            return error.ResolveFailed;
        },
    };
}

fn rejectUnsupportedRanges(diagnostics: *diag.List, meta: VersionMeta) Error!void {
    const groups = [_][]const NamedRange{ meta.dependencies, meta.optional_dependencies, meta.peer_dependencies };
    for (groups) |group| {
        for (group) |dep| {
            if (isUnsupportedNpmRange(dep.range_text)) {
                try diagnostics.addFmt(
                    diag.E029_INVALID_VALUE,
                    .err,
                    dep.name,
                    .{},
                    "unsupported npm dependency protocol for \"{s}\": \"{s}\" (file/git/link/workspace are not fetched)",
                    .{ dep.name, dep.range_text },
                );
                return error.ResolveFailed;
            }
        }
    }
}

pub fn isUnsupportedNpmRange(text: []const u8) bool {
    const prefixes = [_][]const u8{ "file:", "link:", "git:", "git+", "workspace:", "http://", "https://", "npm:" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, text, p)) return true;
    }
    return false;
}

const AcquiredBytes = struct {
    bytes: []const u8,
    /// gpa 所有で free が必要か（fixture 埋め込みは false）。
    owned: bool,
};

fn freeAcquiredTarball(gpa: Allocator, meta: VersionMeta, acquired: AcquiredBytes) void {
    _ = meta;
    if (acquired.owned) gpa.free(acquired.bytes);
}

fn acquireTarball(
    gpa: Allocator,
    session: *fetch.Session,
    cache_store: ?*const cache.Store,
    meta: VersionMeta,
) Error!AcquiredBytes {
    // 1) fixture 埋め込み
    if (meta.tarball_bytes) |bytes| {
        try fetch.verifyHash(session, bytes, meta.integrity, meta.tarball_url, .artifact);
        if (cache_store) |store| {
            try publishTarballCache(gpa, session, store, meta, bytes);
        }
        return .{ .bytes = bytes, .owned = false };
    }

    // 2) cache hit
    if (cache_store) |store| {
        const key = try cache_key.artifactKey(gpa, "npm", meta.integrity, meta.tarball_url);
        defer gpa.free(key);
        if (store.readVerifiedSourceArchive(gpa, key, meta.integrity) catch null) |cached| {
            return .{ .bytes = cached, .owned = true };
        }
    }

    // 3) ローカル path（fixture URL が path のとき）
    if (std.mem.startsWith(u8, meta.tarball_url, "file:") or isLocalPath(meta.tarball_url)) {
        const path = if (std.mem.startsWith(u8, meta.tarball_url, "file://"))
            meta.tarball_url["file://".len..]
        else if (std.mem.startsWith(u8, meta.tarball_url, "file:"))
            meta.tarball_url["file:".len..]
        else
            meta.tarball_url;
        const limit: std.Io.Limit = .limited(if (session.policy.max_bytes == 0) std.math.maxInt(usize) else session.policy.max_bytes);
        const bytes = std.Io.Dir.cwd().readFileAlloc(session.io, path, session.allocator(), limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return session.fail(.invalid_source, .artifact, meta.tarball_url, "cannot read npm tarball \"{s}\"", .{meta.tarball_url}),
        };
        // session arena 所有 → free 不要
        try fetch.verifyHash(session, bytes, meta.integrity, meta.tarball_url, .artifact);
        if (cache_store) |store| {
            try publishTarballCache(gpa, session, store, meta, bytes);
        }
        return .{ .bytes = bytes, .owned = false };
    }

    // 4) ネットワーク
    if (session.policy.offline) {
        return session.fail(.offline, .artifact, meta.tarball_url, "npm tarball \"{s}\" is unavailable offline", .{meta.tarball_url});
    }
    const bytes = try fetch.fetchBytes(session, meta.tarball_url, .artifact);
    try fetch.verifyHash(session, bytes, meta.integrity, meta.tarball_url, .artifact);
    if (cache_store) |store| {
        try publishTarballCache(gpa, session, store, meta, bytes);
    }
    // fetchBytes は session arena 所有
    return .{ .bytes = bytes, .owned = false };
}

fn isLocalPath(url: []const u8) bool {
    if (url.len == 0) return false;
    if (url[0] == '/' or url[0] == '.') return true;
    // Windows drive
    if (url.len >= 3 and url[1] == ':' and (url[2] == '/' or url[2] == '\\')) return true;
    return false;
}

fn publishTarballCache(
    gpa: Allocator,
    session: *fetch.Session,
    store: *const cache.Store,
    meta: VersionMeta,
    bytes: []const u8,
) Error!void {
    const key = try cache_key.artifactKey(gpa, "npm", meta.integrity, meta.tarball_url);
    defer gpa.free(key);
    if (store.entryExists(key)) return;
    // publishStaging は tree/ を必須とする。npm tarball 本体は source.archive に置き、
    // tree は raw blob のみ（unpack / ESM 登録は #54）。
    var staging = store.openStaging(key) catch |err| return mapCache(err);
    var staging_open = true;
    defer if (staging_open) staging.close(session.io);
    staging.createDir(session.io, "tree", .default_dir) catch |err| return mapCache(err);
    staging.writeFile(session.io, .{ .sub_path = "source.archive", .data = bytes }) catch |err| return mapCache(err);
    var tree = staging.openDir(session.io, "tree", .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapCache(err);
    defer tree.close(session.io);
    tree.writeFile(session.io, .{ .sub_path = "blob", .data = bytes }) catch |err| return mapCache(err);
    staging.close(session.io);
    staging_open = false;
    store.publishStaging(key) catch |err| return mapCache(err);
}

fn mapCache(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FileSystem,
    };
}

pub const default_registry_url = "https://registry.npmjs.org";

/// registry から不足分の packument を取り `catalog` を埋める。
/// `names` は解決に必要な npm package 名。再帰依存は resolve 側で増えるため、
/// 呼出し側は不足時に再度呼ぶか、`fillCatalogForRoots` を使う。
pub fn fetchMissingPackuments(
    gpa: Allocator,
    session: *fetch.Session,
    catalog: *Catalog,
    names: []const []const u8,
    registry_base: []const u8,
    diagnostics: *diag.List,
) Error!void {
    for (names) |name| {
        if (catalog.get(name) != null) continue;
        const encoded = try encodeNpmName(gpa, name);
        defer gpa.free(encoded);
        const base = std.mem.trimEnd(u8, registry_base, "/");
        const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, encoded });
        defer gpa.free(url);
        const bytes = fetch.fetchBytes(session, url, .package) catch |err| {
            try diagnostics.addFmt(
                diag.E013_MISSING_PACKAGE,
                .err,
                name,
                .{},
                "failed to fetch npm packument for \"{s}\" from \"{s}\": {s}",
                .{ name, url, @errorName(err) },
            );
            return error.ResolveFailed;
        };
        const meta = try parsePackument(gpa, session.allocator(), bytes, name, diagnostics);
        try catalog.put(gpa, meta);
    }
}

/// roots の closure を満たすまで packument を繰り返し取得する。
pub fn fillCatalogForRoots(
    gpa: Allocator,
    session: *fetch.Session,
    catalog: *Catalog,
    roots: []const RootRequest,
    registry_base: []const u8,
    diagnostics: *diag.List,
) Error!void {
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(gpa);
    for (roots) |root| {
        try pending.append(gpa, root.name);
        for (root.peer_dependencies) |p| try pending.append(gpa, p.name);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var i: usize = 0;
    while (i < pending.items.len) : (i += 1) {
        const name = pending.items[i];
        if (seen.contains(name)) continue;
        try seen.put(gpa, name, {});
        if (catalog.get(name) == null) {
            try fetchMissingPackuments(gpa, session, catalog, &.{name}, registry_base, diagnostics);
        }
        const pkg = catalog.get(name) orelse continue;
        // 全 version の依存名を候補に入れる（範囲選定前でも packument は name 単位）。
        for (pkg.versions) |ver| {
            for (ver.dependencies) |d| try pending.append(gpa, d.name);
            for (ver.optional_dependencies) |d| try pending.append(gpa, d.name);
            for (ver.peer_dependencies) |d| try pending.append(gpa, d.name);
        }
    }
}

fn encodeNpmName(gpa: Allocator, name: []const u8) ![]u8 {
    // scoped: @scope/name → @scope%2Fname
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        return std.fmt.allocPrint(gpa, "{s}%2F{s}", .{ name[0..slash], name[slash + 1 ..] });
    }
    return try gpa.dupe(u8, name);
}

/// packument JSON を `PackageMeta` へ。文字列は `arena` 所有。
pub fn parsePackument(
    gpa: Allocator,
    arena: Allocator,
    bytes: []const u8,
    expected_name: []const u8,
    diagnostics: *diag.List,
) Error!PackageMeta {
    _ = gpa;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, expected_name, .{}, "npm packument for \"{s}\" is not valid JSON", .{expected_name});
        return error.ResolveFailed;
    };
    // arena 所有の Value は個別 deinit 不要（session/outcome arena 寿命）。
    const root = parsed.value;
    if (root != .object) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, expected_name, .{}, "npm packument for \"{s}\" is not an object", .{expected_name});
        return error.ResolveFailed;
    }
    const versions_val = root.object.get("versions") orelse {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, expected_name, .{}, "npm packument for \"{s}\" has no versions", .{expected_name});
        return error.ResolveFailed;
    };
    if (versions_val != .object) {
        try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, expected_name, .{}, "npm packument versions for \"{s}\" is not an object", .{expected_name});
        return error.ResolveFailed;
    }
    var list: std.ArrayList(VersionMeta) = .empty;
    var it = versions_val.object.iterator();
    while (it.next()) |entry| {
        const ver_obj = entry.value_ptr.*;
        if (ver_obj != .object) continue;
        const version_text = entry.key_ptr.*;
        _ = semver.Version.parse(version_text) catch continue;
        const dist = ver_obj.object.get("dist") orelse continue;
        if (dist != .object) continue;
        const tarball = switch (dist.object.get("tarball") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const integrity = blk: {
            if (dist.object.get("integrity")) |integ| {
                switch (integ) {
                    .string => |s| break :blk s,
                    else => {},
                }
            }
            // shasum (sha1) は受理しない。integrity 必須。
            continue;
        };
        if (!fetch.isSupportedHash(integrity) and !std.mem.startsWith(u8, integrity, "sha512-") and !std.mem.startsWith(u8, integrity, "sha256-")) {
            // sha512- base64 は isSupportedHash が受理する。
            continue;
        }
        const deps = try parseNamedRanges(arena, ver_obj.object.get("dependencies"));
        const opt_deps = try parseNamedRanges(arena, ver_obj.object.get("optionalDependencies"));
        const peers = try parseNamedRanges(arena, ver_obj.object.get("peerDependencies"));
        const opt_peers = try parseOptionalPeers(arena, ver_obj.object.get("peerDependenciesMeta"));
        try list.append(arena, .{
            .version = try arena.dupe(u8, version_text),
            .dependencies = deps,
            .optional_dependencies = opt_deps,
            .peer_dependencies = peers,
            .optional_peers = opt_peers,
            .tarball_url = try arena.dupe(u8, tarball),
            .integrity = try arena.dupe(u8, integrity),
            .tarball_bytes = null,
        });
    }
    if (list.items.len == 0) {
        try diagnostics.addFmt(diag.E013_MISSING_PACKAGE, .err, expected_name, .{}, "npm packument for \"{s}\" has no usable versions with integrity", .{expected_name});
        return error.ResolveFailed;
    }
    return .{
        .name = try arena.dupe(u8, expected_name),
        .versions = list.items,
    };
}

fn parseNamedRanges(arena: Allocator, value: ?std.json.Value) ![]const NamedRange {
    const obj = value orelse return &.{};
    if (obj != .object) return &.{};
    var list: std.ArrayList(NamedRange) = .empty;
    var it = obj.object.iterator();
    while (it.next()) |entry| {
        const range_text = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        try list.append(arena, .{
            .name = try arena.dupe(u8, entry.key_ptr.*),
            .range_text = try arena.dupe(u8, range_text),
        });
    }
    return list.items;
}

fn parseOptionalPeers(arena: Allocator, value: ?std.json.Value) ![]const []const u8 {
    const obj = value orelse return &.{};
    if (obj != .object) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = obj.object.iterator();
    while (it.next()) |entry| {
        const meta = entry.value_ptr.*;
        if (meta != .object) continue;
        const opt = meta.object.get("optional") orelse continue;
        const is_opt = switch (opt) {
            .bool => |b| b,
            else => false,
        };
        if (!is_opt) continue;
        try list.append(arena, try arena.dupe(u8, entry.key_ptr.*));
    }
    return list.items;
}

/// integrity 文字列（`sha512-<b64>`）を tarball bytes から作る（fixture 用）。
pub fn integritySha512(gpa: Allocator, bytes: []const u8) ![]u8 {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    var encoded: [88]u8 = undefined;
    const encoded_slice = std.base64.standard.Encoder.encode(&encoded, &digest);
    return std.fmt.allocPrint(gpa, "sha512-{s}", .{encoded_slice});
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

fn emptyTarball(gpa: Allocator) ![]u8 {
    // minimal gzip empty tar is overkill; zero bytes with matching integrity works for resolve path.
    return try gpa.dupe(u8, "npm-fixture-body");
}

fn catalogWith(
    gpa: Allocator,
    name: []const u8,
    version: []const u8,
    deps: []const NamedRange,
    opt_deps: []const NamedRange,
    peers: []const NamedRange,
    opt_peers: []const []const u8,
    bytes: []const u8,
) !Catalog {
    const integ = try integritySha512(gpa, bytes);
    var cat: Catalog = .{};
    const versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(versions);
    versions[0] = .{
        .version = version,
        .dependencies = deps,
        .optional_dependencies = opt_deps,
        .peer_dependencies = peers,
        .optional_peers = opt_peers,
        .tarball_url = try std.fmt.allocPrint(gpa, "fixture://{s}-{s}.tgz", .{ name, version }),
        .integrity = integ,
        .tarball_bytes = bytes,
    };
    try cat.put(gpa, .{ .name = name, .versions = versions });
    return cat;
}

test "npm: 同一 helper を文脈ごとに別 version で選ぶ" {
    const gpa = testing.allocator;
    var session = fetch.Session.init(gpa, testing.io, .{});
    defer session.deinit();
    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();

    const body_a = try emptyTarball(gpa);
    defer gpa.free(body_a);
    const body_b = try gpa.dupe(u8, "npm-fixture-body-v2");
    defer gpa.free(body_b);

    const integ_a = try integritySha512(gpa, body_a);
    defer gpa.free(integ_a);
    const integ_b = try integritySha512(gpa, body_b);
    defer gpa.free(integ_b);

    var cat: Catalog = .{};
    defer cat.deinit(gpa);
    const versions = try gpa.alloc(VersionMeta, 2);
    defer gpa.free(versions);
    versions[0] = .{
        .version = "1.0.0",
        .tarball_url = "fixture://helper-1.0.0.tgz",
        .integrity = integ_a,
        .tarball_bytes = body_a,
    };
    versions[1] = .{
        .version = "2.0.0",
        .tarball_url = "fixture://helper-2.0.0.tgz",
        .integrity = integ_b,
        .tarball_bytes = body_b,
    };
    try cat.put(gpa, .{ .name = "helper", .versions = versions });

    var range1 = try semver.Range.parse(gpa, "^1.0.0");
    defer range1.deinit(gpa);
    var range2 = try semver.Range.parse(gpa, "^2.0.0");
    defer range2.deinit(gpa);
    const roots = [_]RootRequest{
        .{ .alias = "helper-a", .name = "helper", .range = range1, .range_text = "^1.0.0", .context = "caller-a" },
        .{ .alias = "helper-b", .name = "helper", .range = range2, .range_text = "^2.0.0", .context = "caller-b" },
    };

    var result = try resolve(gpa, &session, &cat, &roots, null, &diagnostics);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.instances.len);
    try testing.expectEqualStrings("helper@1.0.0#caller-a", result.instances[0].key);
    try testing.expectEqualStrings("helper@2.0.0#caller-b", result.instances[1].key);
}

test "npm: 必須 peer 衝突は E017、optional peer 欠落は成功" {
    const gpa = testing.allocator;
    var session = fetch.Session.init(gpa, testing.io, .{});
    defer session.deinit();
    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();

    const body = try emptyTarball(gpa);
    defer gpa.free(body);
    const integ = try integritySha512(gpa, body);
    defer gpa.free(integ);

    var cat: Catalog = .{};
    defer cat.deinit(gpa);

    const plugin_versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(plugin_versions);
    plugin_versions[0] = .{
        .version = "1.0.0",
        .peer_dependencies = &[_]NamedRange{.{ .name = "host", .range_text = "^2.0.0" }},
        .tarball_url = "fixture://plugin-1.0.0.tgz",
        .integrity = integ,
        .tarball_bytes = body,
    };
    try cat.put(gpa, .{ .name = "plugin", .versions = plugin_versions });

    const host_versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(host_versions);
    host_versions[0] = .{
        .version = "1.0.0",
        .tarball_url = "fixture://host-1.0.0.tgz",
        .integrity = integ,
        .tarball_bytes = body,
    };
    try cat.put(gpa, .{ .name = "host", .versions = host_versions });

    var range_plugin = try semver.Range.parse(gpa, "1.0.0");
    defer range_plugin.deinit(gpa);
    var range_host = try semver.Range.parse(gpa, "1.0.0");
    defer range_host.deinit(gpa);
    // 必須 peer: host@^2 が必要だが host@1 を同文脈に入れる → 衝突
    {
        var d = diag.List.init(gpa);
        defer d.deinit();
        const roots = [_]RootRequest{
            .{ .alias = "plugin", .name = "plugin", .range = range_plugin, .range_text = "1.0.0", .context = "app" },
            .{ .alias = "host", .name = "host", .range = range_host, .range_text = "1.0.0", .context = "app" },
        };
        try testing.expectError(error.ResolveFailed, resolve(gpa, &session, &cat, &roots, null, &d));
        try testing.expect(d.find(diag.E017_NPM_PEER_CONFLICT) != null);
    }

    // optional peer のみ → host が無くても成功
    {
        var d = diag.List.init(gpa);
        defer d.deinit();
        const opt_versions = try gpa.alloc(VersionMeta, 1);
        defer gpa.free(opt_versions);
        opt_versions[0] = .{
            .version = "1.0.0",
            .peer_dependencies = &[_]NamedRange{.{ .name = "missing-peer", .range_text = "^1.0.0" }},
            .optional_peers = &[_][]const u8{"missing-peer"},
            .tarball_url = "fixture://opt-1.0.0.tgz",
            .integrity = integ,
            .tarball_bytes = body,
        };
        try cat.put(gpa, .{ .name = "opt-plugin", .versions = opt_versions });
        const roots = [_]RootRequest{
            .{ .alias = "opt", .name = "opt-plugin", .range = range_plugin, .range_text = "1.0.0" },
        };
        var result = try resolve(gpa, &session, &cat, &roots, null, &d);
        defer result.deinit();
        try testing.expectEqual(@as(usize, 1), result.instances.len);
    }
}

test "npm: integrity 不一致は失敗し script 相当の副作用を起こさない" {
    const gpa = testing.allocator;
    var session = fetch.Session.init(gpa, testing.io, .{});
    defer session.deinit();
    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();

    const body = try emptyTarball(gpa);
    defer gpa.free(body);
    const other = try gpa.dupe(u8, "different-body");
    defer gpa.free(other);
    const wrong_integ = try integritySha512(gpa, other);
    defer gpa.free(wrong_integ);
    var cat: Catalog = .{};
    defer cat.deinit(gpa);
    const versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(versions);
    versions[0] = .{
        .version = "1.0.0",
        .tarball_url = "fixture://bad.tgz",
        .integrity = wrong_integ,
        .tarball_bytes = body,
    };
    try cat.put(gpa, .{ .name = "bad", .versions = versions });
    var range = try semver.Range.parse(gpa, "1.0.0");
    defer range.deinit(gpa);
    const roots = [_]RootRequest{
        .{ .alias = "bad", .name = "bad", .range = range, .range_text = "1.0.0" },
    };
    try testing.expectError(error.HashMismatch, resolve(gpa, &session, &cat, &roots, null, &diagnostics));
}

test "npm: 未対応 protocol 依存を診断する" {
    const gpa = testing.allocator;
    var session = fetch.Session.init(gpa, testing.io, .{});
    defer session.deinit();
    var diagnostics = diag.List.init(gpa);
    defer diagnostics.deinit();
    const body = try emptyTarball(gpa);
    defer gpa.free(body);
    const integ = try integritySha512(gpa, body);
    defer gpa.free(integ);
    var cat: Catalog = .{};
    defer cat.deinit(gpa);
    const versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(versions);
    versions[0] = .{
        .version = "1.0.0",
        .dependencies = &[_]NamedRange{.{ .name = "local", .range_text = "file:../local" }},
        .tarball_url = "fixture://x.tgz",
        .integrity = integ,
        .tarball_bytes = body,
    };
    try cat.put(gpa, .{ .name = "x", .versions = versions });
    var range = try semver.Range.parse(gpa, "1.0.0");
    defer range.deinit(gpa);
    const roots = [_]RootRequest{.{ .alias = "x", .name = "x", .range = range, .range_text = "1.0.0" }};
    try testing.expectError(error.ResolveFailed, resolve(gpa, &session, &cat, &roots, null, &diagnostics));
    try testing.expect(diagnostics.find(diag.E029_INVALID_VALUE) != null);
}

test "npm: cache があれば offline で再取得できる" {
    const gpa = testing.allocator;
    const io = testing.io;
    var temporary = test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache_root);
    var store = try cache.Store.open(gpa, io, cache_root);
    defer store.deinit();

    const body = try emptyTarball(gpa);
    defer gpa.free(body);
    const integ = try integritySha512(gpa, body);
    defer gpa.free(integ);

    var cat: Catalog = .{};
    defer cat.deinit(gpa);
    const versions = try gpa.alloc(VersionMeta, 1);
    defer gpa.free(versions);
    versions[0] = .{
        .version = "1.0.0",
        .tarball_url = "fixture://cached-1.0.0.tgz",
        .integrity = integ,
        .tarball_bytes = body,
    };
    try cat.put(gpa, .{ .name = "cached", .versions = versions });

    var range = try semver.Range.parse(gpa, "1.0.0");
    defer range.deinit(gpa);
    const roots = [_]RootRequest{.{ .alias = "cached", .name = "cached", .range = range, .range_text = "1.0.0" }};

    {
        var session = fetch.Session.init(gpa, io, .{});
        defer session.deinit();
        var d = diag.List.init(gpa);
        defer d.deinit();
        var result = try resolve(gpa, &session, &cat, &roots, &store, &d);
        defer result.deinit();
        try testing.expectEqual(@as(usize, 1), result.instances.len);
    }

    // 埋め込み bytes を外し offline で cache のみ
    versions[0].tarball_bytes = null;
    {
        var session = fetch.Session.init(gpa, io, .{ .offline = true });
        defer session.deinit();
        var d = diag.List.init(gpa);
        defer d.deinit();
        var result = try resolve(gpa, &session, &cat, &roots, &store, &d);
        defer result.deinit();
        try testing.expectEqual(@as(usize, 1), result.instances.len);
        try testing.expect(std.mem.startsWith(u8, result.instances[0].sha256, "sha256:"));
    }
}
