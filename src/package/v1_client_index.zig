//! v1 sparse index の読み込み closure と resolver 型への変換。
//!
//! §4 の index は `v1_index.zig` が解析・検証する。ここはクライアント側の
//! 取得順序だけを担う:
//!
//! - `config.json` → ルート直接依存から推移的に `packages/{scope}/{name}.json`
//!   を読む closure を作る。解決器は graph 全体を必要とするため、選択前に
//!   到達可能な Package ID をすべて読む。
//! - 取得は `v1_client_fixture.Source` のみ（実ネットワークなし）。
//! - 上限（package 数・index 総量・1 ファイル）を超えたら中断する。
//! - 見つからない依存は「未知パッケージ」として解決器へ渡し、解決器の
//!   診断に委ねる（ここでは失敗にしない）。

const std = @import("std");
const types = @import("v1_types.zig");
const index = @import("v1_index.zig");
const resolver = @import("v1_resolver.zig");
const fixture = @import("v1_client_fixture.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidRegistryUrl,
    MissingConfig,
    ConfigMismatch,
    IndexLimit,
    IndexTooLarge,
    OutOfMemory,
};

pub const Limits = struct {
    max_packages: usize = 256,
    max_total_index_bytes: usize = 64 * 1024 * 1024,
    max_index_bytes: usize = 16 * 1024 * 1024,
};

pub const Source = struct {
    arena: Allocator,
    io: std.Io,
    fixture: fixture.Source,
    registry_base: []const u8,
    config: index.Config,
    limits: Limits,
    packages: std.StringHashMap(*index.Package),
    order: std.ArrayList(*index.Package),
    missing: std.StringHashMap(void),
    total_bytes: usize = 0,

    /// `registry_url` は `https://host[/prefix]`。末尾 `/index/v1` も許容する。
    /// fixture root は `v1_client_fixture.Source.open` と同じ規則。
    pub fn init(
        arena: Allocator,
        io: std.Io,
        fixture_root: []const u8,
        registry_url: []const u8,
        limits: Limits,
    ) !Source {
        const base = try normalizeRegistryUrl(arena, registry_url);
        var source = Source{
            .arena = arena,
            .io = io,
            .fixture = try fixture.Source.open(io, fixture_root, .{}),
            .registry_base = base,
            .config = undefined,
            .limits = limits,
            .packages = std.StringHashMap(*index.Package).init(arena),
            .order = .empty,
            .missing = std.StringHashMap(void).init(arena),
        };
        errdefer source.fixture.deinit();

        const config_url = try std.fmt.allocPrint(arena, "{s}/index/v1/config.json", .{base});
        const response = source.fixture.get(arena, config_url) catch |err| switch (err) {
            error.FixtureNotFound => return error.MissingConfig,
            else => return err,
        };
        if (response.status != 200) return error.MissingConfig;
        if (response.body.len > limits.max_index_bytes) return error.IndexTooLarge;
        source.total_bytes = response.body.len;
        source.config = index.parseConfig(arena, response.body) catch return error.ConfigMismatch;
        return source;
    }

    pub fn deinit(self: *Source) void {
        for (self.order.items) |package| package.deinit();
        self.packages.deinit();
        self.missing.deinit();
        self.order.deinit(self.arena);
        self.fixture.deinit();
        self.* = undefined;
    }

    /// ルート直接依存から到達可能な Package ID をすべて読む。
    pub fn loadClosure(self: *Source, roots: []const types.Dependency, runtime: types.Runtime) !void {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.arena);
        for (roots) |dependency| try queue.append(self.arena, dependency.id);

        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const id = queue.items[cursor];
            if (self.packages.contains(id) or self.missing.contains(id)) continue;
            if (self.packages.count() >= self.limits.max_packages) return error.IndexLimit;

            const loaded = try self.loadPackage(id);
            if (!loaded) {
                try self.missing.put(try self.arena.dupe(u8, id), {});
                continue;
            }
            const package = self.packages.get(id).?;
            for (package.versions) |release| {
                for (release.dependencies) |dependency| {
                    if (!runtimeApplies(dependency.runtimes, runtime)) continue;
                    if (self.packages.contains(dependency.id) or self.missing.contains(dependency.id)) continue;
                    try queue.append(self.arena, dependency.id);
                }
            }
        }
    }

    fn loadPackage(self: *Source, id: []const u8) !bool {
        if (!types.validId(id)) return error.ConfigMismatch;
        const slash = std.mem.indexOfScalar(u8, id, '/') orelse return error.ConfigMismatch;
        const scope = id[1..slash];
        const name = id[slash + 1 ..];
        const url = try std.fmt.allocPrint(self.arena, "{s}/index/v1/packages/{s}/{s}.json", .{ self.registry_base, scope, name });
        const response = self.fixture.get(self.arena, url) catch |err| switch (err) {
            error.FixtureNotFound => return false,
            else => return err,
        };
        if (response.status == 404) return false;
        if (response.status != 200) return error.ConfigMismatch;
        if (response.body.len > self.limits.max_index_bytes) return error.IndexTooLarge;
        if (self.total_bytes + response.body.len > self.limits.max_total_index_bytes) return error.IndexTooLarge;
        self.total_bytes += response.body.len;

        const package = try self.arena.create(index.Package);
        errdefer self.arena.destroy(package);
        package.* = index.parsePackage(self.arena, response.body) catch return error.ConfigMismatch;
        if (!std.mem.eql(u8, package.id, id)) {
            package.deinit();
            return error.ConfigMismatch;
        }
        try self.packages.put(try self.arena.dupe(u8, id), package);
        try self.order.append(self.arena, package);
        return true;
    }

    /// 解決器へ渡す index。Package ID 昇順で決定的。
    pub fn resolverPackages(self: *Source) ![]resolver.Package {
        const items = try self.arena.alloc(resolver.Package, self.order.items.len);
        for (self.order.items, 0..) |package, package_index| {
            const releases = try self.arena.alloc(resolver.Release, package.versions.len);
            for (package.versions, 0..) |release, release_index| {
                const features = try self.arena.alloc(resolver.Feature, release.features.len);
                for (release.features, 0..) |feature, feature_index| {
                    features[feature_index] = .{
                        .name = feature.name,
                        .enables = feature.enables,
                    };
                }
                releases[release_index] = .{
                    .version = release.version,
                    .yanked = release.yanked,
                    .exports_global_commands = release.exports_global_commands,
                    .global_commands = release.global_commands,
                    .dependencies = release.dependencies,
                    .artifacts = release.artifacts,
                    .features = features,
                };
            }
            items[package_index] = .{ .id = package.id, .versions = releases };
        }
        std.mem.sort(resolver.Package, items, {}, struct {
            fn lessThan(_: void, a: resolver.Package, b: resolver.Package) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lessThan);
        return items;
    }

    pub fn releaseFor(self: *Source, id: []const u8, version: []const u8) ?*const index.Release {
        const package = self.packages.get(id) orelse return null;
        return package.findRelease(version);
    }

    /// ノードが固定した (kind, sha256) に一致する artifact を返す。
    pub fn artifactFor(
        self: *Source,
        id: []const u8,
        version: []const u8,
        kind: types.Kind,
        sha256: []const u8,
    ) ?*const types.Artifact {
        const release = self.releaseFor(id, version) orelse return null;
        for (release.artifacts) |*artifact| {
            if (artifact.kind != kind) continue;
            if (std.mem.eql(u8, artifact.sha256, sha256)) return artifact;
        }
        return null;
    }

    /// 解決・lock 照合用の (id, version, yanked, global, artifacts) 一覧。
    pub fn lockReleases(self: *Source, allocator: Allocator) ![]const v1_lock.IndexRelease {
        var list: std.ArrayList(v1_lock.IndexRelease) = .empty;
        for (self.order.items) |package| {
            for (package.versions) |release| {
                const artifacts = try allocator.alloc(v1_lock.IndexArtifact, release.artifacts.len);
                for (release.artifacts, 0..) |artifact, artifact_index| {
                    artifacts[artifact_index] = .{ .kind = artifact.kind, .sha256 = artifact.sha256 };
                }
                try list.append(allocator, .{
                    .id = package.id,
                    .version = release.version,
                    .yanked = release.yanked,
                    .exports_global_commands = release.exports_global_commands,
                    .artifacts = artifacts,
                });
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

const v1_lock = @import("v1_lock.zig");

fn normalizeRegistryUrl(arena: Allocator, registry_url: []const u8) ![]const u8 {
    const uri = std.Uri.parse(registry_url) catch return error.InvalidRegistryUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidRegistryUrl;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidRegistryUrl;
    }
    var trimmed = std.mem.trimEnd(u8, registry_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/index/v1")) trimmed = trimmed[0 .. trimmed.len - "/index/v1".len];
    if (trimmed.len == 0) return error.InvalidRegistryUrl;
    return arena.dupe(u8, trimmed);
}

fn runtimeApplies(runtimes: []const types.Runtime, runtime: types.Runtime) bool {
    if (runtimes.len == 0) return true;
    for (runtimes) |candidate| {
        if (candidate == runtime) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

const config_json =
    \\{
    \\  "schema_version": 1,
    \\  "registry_id": "nako-official",
    \\  "api_base_url": "https://api.registry.example.invalid/v1",
    \\  "artifact_base_url": "https://cdn.example.invalid/artifacts",
    \\  "allowed_external_hosts": ["repo.example.invalid"]
    \\}
;

fn packageJson(id: []const u8, version: []const u8, dependency: ?[]const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schema_version": 1,
        \\  "id": "{s}",
        \\  "scope_id": "01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d",
        \\  "updated_at": "2026-11-27T13:30:00Z",
        \\  "deprecated": null,
        \\  "versions": [{{
        \\    "version": "{s}",
        \\    "published_at": "2026-11-27T13:30:00Z",
        \\    "yanked": false,
        \\    "yank_reason": null,
        \\    "license": "MIT",
        \\    "capabilities": ["pure-nako"],
        \\    "engines": {{"lnako": ">=0.2.0"}},
        \\    "exports_global_commands": false,
        \\    "global_commands": [],
        \\    "features": {{"default": []}},
        \\    "dependencies": [{{"id": "{s}", "req": "^1.0.0", "features": [], "default_features": true, "optional": false, "runtimes": ["lnako"]}}],
        \\    "provenance": {{"verified": true}},
        \\    "artifacts": [{{
        \\      "kind": "universal",
        \\      "runtimes": ["lnako", "cnako", "wnako"],
        \\      "target": null,
        \\      "hosting": "registry",
        \\      "url": "https://cdn.example.invalid/artifacts/demo.npkg",
        \\      "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        \\      "size": 3
        \\    }}],
        \\    "advisories": []
        \\  }}]
        \\}}
    , .{ id, version, dependency orelse "@acme/inner" });
}

fn writeFixture(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test "index の closure を推移的に読み、resolver 型へ決定的に変換する" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try writeFixture(temporary.dir, io, "index/v1/config.json", config_json);
    const outer = try packageJson("@acme/outer", "1.0.0", "@acme/inner");
    defer testing.allocator.free(outer);
    const inner = try packageJson("@acme/inner", "1.0.0", null);
    defer testing.allocator.free(inner);
    try writeFixture(temporary.dir, io, "index/v1/packages/acme/outer.json", outer);
    try writeFixture(temporary.dir, io, "index/v1/packages/acme/inner.json", inner);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var source = try Source.init(a, io, root, "https://registry.example.invalid", .{});
    defer source.deinit();
    try source.loadClosure(&.{
        .{ .id = "@acme/outer", .req = "^1.0.0" },
    }, .lnako);

    try testing.expectEqual(@as(usize, 2), source.order.items.len);
    const packages = try source.resolverPackages();
    try testing.expectEqual(@as(usize, 2), packages.len);
    try testing.expectEqualStrings("@acme/inner", packages[0].id);
    try testing.expectEqualStrings("@acme/outer", packages[1].id);
    try testing.expectEqualStrings("@acme/inner", packages[1].versions[0].dependencies[0].id);
}

test "未知の依存は missing に記録し、config 不在は失敗する" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try writeFixture(temporary.dir, io, "index/v1/config.json", config_json);
    const outer = try packageJson("@acme/outer", "1.0.0", "@acme/missing");
    defer testing.allocator.free(outer);
    try writeFixture(temporary.dir, io, "index/v1/packages/acme/outer.json", outer);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var source = try Source.init(a, io, root, "https://registry.example.invalid", .{});
    defer source.deinit();
    try source.loadClosure(&.{
        .{ .id = "@acme/outer", .req = "^1.0.0" },
    }, .lnako);
    try testing.expect(source.missing.contains("@acme/missing"));
    try testing.expectEqual(@as(usize, 1), source.order.items.len);

    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_root = try empty.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(empty_root);
    try testing.expectError(error.MissingConfig, Source.init(a, io, empty_root, "https://registry.example.invalid", .{}));
    try testing.expectError(error.InvalidRegistryUrl, Source.init(a, io, root, "http://registry.example.invalid", .{}));
}
