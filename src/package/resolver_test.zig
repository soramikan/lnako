const std = @import("std");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const manifest = @import("manifest.zig");
const diag = @import("diagnostics.zig");

const T = std.testing;
const PackageId = resolver.PackageId;
const Version = resolver.Version;
const Range = resolver.Range;
const Impl = resolver.Impl;

// ---------------------------------------------------------------------------
// test provider
// ---------------------------------------------------------------------------

const Mock = struct {
    const Dep = struct {
        name: []const u8,
        req: []const u8,
        features: []const []const u8 = &.{},
        default_features: bool = true,
        prefer_native: bool = false,
    };
    const Ver = struct {
        version: []const u8,
        deps: []const Dep = &.{},
        features: []const resolver.FeatureDefinition = &.{},
        unavailable: ?[]const u8 = null,
        has_source: bool = true,
        has_native: bool = false,
        has_esm: bool = false,
    };
    const Pkg = struct { name: []const u8, versions: []const Ver };
    const Locked = struct { name: []const u8, version: []const u8 };

    pkgs: []const Pkg,
    locked: []const Locked = &.{},

    fn find(self: *const Mock, name: []const u8) ?*const Pkg {
        for (self.pkgs) |*pkg| {
            if (std.mem.eql(u8, pkg.name, name)) return pkg;
        }
        return null;
    }

    fn findVer(pkg: *const Pkg, version: Version) ?*const Ver {
        for (pkg.versions) |*ver| {
            const parsed = Version.parse(ver.version) catch continue;
            if (Version.cmp(parsed, version) == .eq) return ver;
        }
        return null;
    }
};

fn listVersions(ptr: *anyopaque, gpa: std.mem.Allocator, id: PackageId) anyerror![]const Version {
    const mock: *const Mock = @ptrCast(@alignCast(ptr));
    const name = switch (id) {
        .pkg => |n| n,
        .npm => |n| n.name,
    };
    const pkg = mock.find(name) orelse return error.PackageNotFound;
    const out = try gpa.alloc(Version, pkg.versions.len);
    for (pkg.versions, 0..) |ver, i| out[i] = try Version.parse(ver.version);
    return out;
}

fn versionMeta(ptr: *anyopaque, gpa: std.mem.Allocator, id: PackageId, version: Version) anyerror!resolver.VersionMeta {
    const mock: *const Mock = @ptrCast(@alignCast(ptr));
    const name = switch (id) {
        .pkg => |n| n,
        .npm => |n| n.name,
    };
    const pkg = mock.find(name) orelse return error.PackageNotFound;
    const ver = Mock.findVer(pkg, version) orelse return error.PackageNotFound;
    var deps: std.ArrayList(resolver.Dependency) = .empty;
    for (ver.deps) |dependency| {
        const range = try semver.Range.parse(gpa, dependency.req);
        try deps.append(gpa, .{
            .id = .{ .pkg = dependency.name },
            .constraint = try resolver.rangeFromSemver(gpa, range),
            .name = dependency.name,
            .features = dependency.features,
            .default_features = dependency.default_features,
            .prefer_native = dependency.prefer_native,
            .prerelease_tuples = try resolver.gatedTuples(gpa, range),
        });
    }
    return .{
        .dependencies = deps.items,
        .features = ver.features,
        .unavailable_reason = ver.unavailable,
        .has_source = ver.has_source,
        .has_native = ver.has_native,
        .has_esm = ver.has_esm,
    };
}

fn lockedVersion(ptr: *anyopaque, id: PackageId) ?Version {
    const mock: *const Mock = @ptrCast(@alignCast(ptr));
    const name = switch (id) {
        .pkg => |n| n,
        .npm => |n| n.name,
    };
    for (mock.locked) |locked| {
        if (std.mem.eql(u8, locked.name, name)) return Version.parse(locked.version) catch null;
    }
    return null;
}

const vtable = resolver.Provider.VTable{
    .listVersions = listVersions,
    .versionMeta = versionMeta,
    .lockedVersion = lockedVersion,
};

fn asProvider(mock: *const Mock) resolver.Provider {
    return .{ .ptr = @constCast(mock), .vtable = &vtable };
}

fn dep(gpa: std.mem.Allocator, name: []const u8, req: []const u8) resolver.Dependency {
    const range = semver.Range.parse(gpa, req) catch unreachable;
    return .{
        .id = .{ .pkg = name },
        .constraint = resolver.rangeFromSemver(gpa, range) catch unreachable,
        .name = name,
        .prerelease_tuples = resolver.gatedTuples(gpa, range) catch unreachable,
    };
}

fn solve(gpa: std.mem.Allocator, mock: *const Mock, root_deps: []const resolver.Dependency, opts: resolver.ResolveOptions) !resolver.Resolution {
    return resolver.resolve(gpa, asProvider(mock), root_deps, opts);
}

fn nodesOf(res: *const resolver.Resolution) []const resolver.PackageNode {
    return switch (res.result) {
        .resolved => |nodes| nodes,
        .failed => std.debug.panic("expected success", .{}),
        .cycle => std.debug.panic("expected success, got cycle", .{}),
    };
}

fn messageOf(res: *const resolver.Resolution) []const u8 {
    return switch (res.result) {
        .failed => |f| f.message,
        .resolved => std.debug.panic("expected failure", .{}),
        .cycle => std.debug.panic("expected failure, got cycle", .{}),
    };
}

fn cycleOf(res: *const resolver.Resolution) []const resolver.PackageId {
    return switch (res.result) {
        .cycle => |cycle| cycle,
        .resolved => std.debug.panic("expected cycle, got success", .{}),
        .failed => std.debug.panic("expected cycle, got failure", .{}),
    };
}

fn findNode(nodes: []const resolver.PackageNode, name: []const u8) ?*const resolver.PackageNode {
    for (nodes) |*node| {
        if (node.id.eql(.{ .pkg = name })) return node;
    }
    return null;
}

fn versionOf(nodes: []const resolver.PackageNode, name: []const u8) ?Version {
    const node = findNode(nodes, name) orelse return null;
    return node.version;
}

fn expectVersion(nodes: []const resolver.PackageNode, name: []const u8, expected: []const u8) !void {
    const actual = versionOf(nodes, name) orelse return error.MissingPackage;
    // `Version` は `prerelease`/`build` をスライスで持つため、構造体の
    // ポインタ比較ではなく semver 優先順位比較で照合する。
    try T.expect(Version.cmp(actual, try Version.parse(expected)) == .eq);
}

// ---------------------------------------------------------------------------
// basic solving
// ---------------------------------------------------------------------------

test "diamond依存は共通versionを一度だけ解決する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "left", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "shared", .req = ">=1.0.0 <2.0.0" }},
        }} },
        .{ .name = "right", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "shared", .req = ">=1.2.0" }},
        }} },
        .{ .name = "shared", .versions = &.{
            .{ .version = "1.0.0" },
            .{ .version = "1.3.0" },
            .{ .version = "2.0.0" },
        } },
    } };
    const root_deps = [_]resolver.Dependency{
        dep(gpa, "left", "*"),
        dep(gpa, "right", "*"),
    };
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const nodes = nodesOf(&res);
    try expectVersion(nodes, "shared", "1.3.0");
    // diamond でも node は 1 つだけ。
    var count: usize = 0;
    for (nodes) |node| {
        if (node.id.eql(.{ .pkg = "shared" })) count += 1;
    }
    try T.expectEqual(@as(usize, 1), count);
}

test "循環依存はE004相当のcycleとして検出する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "a", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "b", .req = "^1.0.0" }},
        }} },
        .{ .name = "b", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "a", .req = "^1.0.0" }},
        }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "a", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const cycle = cycleOf(&res);
    try T.expect(cycle.len >= 2);
    try T.expect(cycle[0].eql(cycle[cycle.len - 1]));
}

test "深いbacktrackで古いversionを選ぶ" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "top", .versions = &.{
            .{ .version = "1.0.0", .deps = &.{.{ .name = "mid", .req = "^1.0.0" }} },
            .{ .version = "2.0.0", .deps = &.{.{ .name = "mid", .req = "^2.0.0" }} },
        } },
        .{ .name = "mid", .versions = &.{
            .{ .version = "1.0.0", .deps = &.{.{ .name = "leaf", .req = "^1.0.0" }} },
            .{ .version = "2.0.0", .deps = &.{.{ .name = "leaf", .req = ">=9.0.0" }} },
        } },
        .{ .name = "leaf", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "top", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const nodes = nodesOf(&res);
    try expectVersion(nodes, "top", "1.0.0");
    try expectVersion(nodes, "mid", "1.0.0");
    try expectVersion(nodes, "leaf", "1.0.0");
}

test "到達不能versionは解決理由になる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{
            .{ .version = "1.0.0" },
            .{ .version = "2.0.0" },
        } },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "lib", "^3.0.0")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "lib") != null);
    try T.expect(std.mem.indexOf(u8, message, "version solving failed") != null);
}

test "root競合は要求の連鎖を説明する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "a", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "shared", .req = ">=2.0.0" }},
        }} },
        .{ .name = "shared", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "a", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "a") != null);
    try T.expect(std.mem.indexOf(u8, message, "shared") != null);
    try T.expect(std.mem.indexOf(u8, message, "version solving failed") != null);
}

test "存在しないpackageは失敗として説明する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{} };
    const root_deps = [_]resolver.Dependency{dep(gpa, "ghost", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "ghost") != null);
    try T.expect(std.mem.indexOf(u8, message, "doesn't exist") != null);
}

test "既存lockの選択候補を優先する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
        .locked = &.{.{ .name = "lib", .version = "1.0.0" }},
    };
    const root_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    try expectVersion(nodesOf(&res), "lib", "1.0.0");
}

test "unavailableなversionは理由付きで競合説明に出る" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .unavailable = "yanked: CVE-1234",
        }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "yanked: CVE-1234") != null);
}

// ---------------------------------------------------------------------------
// determinism
// ---------------------------------------------------------------------------

fn serialize(allocator: std.mem.Allocator, res: *const resolver.Resolution) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const nodes = nodesOf(res);
    for (nodes) |node| {
        try out.print(allocator, "{f}@{f} impl={s} features=[", .{ node.id, node.version, @tagName(node.implementation) });
        for (node.features, 0..) |feature, i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, feature);
        }
        try out.appendSlice(allocator, "] deps=[");
        for (node.dependencies, 0..) |d, i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            try out.print(allocator, "{f}", .{d});
        }
        try out.appendSlice(allocator, "]\n");
    }
    return out.items;
}

test "同一入力の反復実行で同一解と同一説明を得る" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "a", .versions = &.{
            .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = "^1.0.0" }} },
            .{ .version = "2.0.0", .deps = &.{.{ .name = "c", .req = "^1.0.0" }} },
        } },
        .{ .name = "b", .versions = &.{
            .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = "<1.5.0" }} },
        } },
        .{ .name = "c", .versions = &.{
            .{ .version = "1.0.0" },
            .{ .version = "1.4.0" },
            .{ .version = "1.6.0" },
        } },
    } };
    const root_deps = [_]resolver.Dependency{
        dep(gpa, "a", "*"),
        dep(gpa, "b", "*"),
    };
    var first: ?[]const u8 = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var res = try solve(gpa, &mock, &root_deps, .{});
        defer res.deinit();
        const text = try serialize(gpa, &res);
        if (first) |f| {
            try T.expectEqualStrings(f, text);
        } else {
            first = try gpa.dupe(u8, text);
        }
    }
}

test "競合説明も反復実行で同一になる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "a", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "c", .req = ">=2.0.0" }},
        }} },
        .{ .name = "b", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "c", .req = "<2.0.0" }},
        }} },
        .{ .name = "c", .versions = &.{
            .{ .version = "1.0.0" },
            .{ .version = "2.0.0" },
        } },
    } };
    const root_deps = [_]resolver.Dependency{
        dep(gpa, "a", "*"),
        dep(gpa, "b", "*"),
    };
    var first: ?[]const u8 = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var res = try solve(gpa, &mock, &root_deps, .{});
        defer res.deinit();
        const message = messageOf(&res);
        if (first) |f| {
            try T.expectEqualStrings(f, message);
        } else {
            first = try gpa.dupe(u8, message);
        }
    }
}

// ---------------------------------------------------------------------------
// features
// ---------------------------------------------------------------------------

test "feature有効時のみ推移依存を取り込む" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "tls", .req = "*" }},
            .features = &.{
                .{ .name = "default", .items = &.{} },
                .{ .name = "secure", .items = &.{"tls"} },
            },
        }} },
        .{ .name = "tls", .versions = &.{.{ .version = "1.0.0" }} },
    } };

    // feature 無効: gated 依存 tls は解決対象外。
    const off_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var off = try solve(gpa, &mock, &off_deps, .{});
    defer off.deinit();
    try T.expect(versionOf(nodesOf(&off), "tls") == null);
    try T.expect(findNode(nodesOf(&off), "lib") != null);

    // feature 有効: tls を取り込む。
    var on_dep = dep(gpa, "lib", "*");
    on_dep.features = &.{"secure"};
    const on_deps = [_]resolver.Dependency{on_dep};
    var on = try solve(gpa, &mock, &on_deps, .{});
    defer on.deinit();
    try expectVersion(nodesOf(&on), "tls", "1.0.0");
    const lib = findNode(nodesOf(&on), "lib").?;
    var saw_secure = false;
    for (lib.features) |feature| {
        if (std.mem.eql(u8, feature, "secure")) saw_secure = true;
    }
    try T.expect(saw_secure);
}

test "feature起点の競合理由を説明できる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "tls", .req = "^2.0.0" }},
            .features = &.{.{ .name = "secure", .items = &.{"tls"} }},
        }} },
        .{ .name = "tls", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    var root_dep = dep(gpa, "lib", "*");
    root_dep.features = &.{"secure"};
    const root_deps = [_]resolver.Dependency{root_dep};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "tls") != null);
    try T.expect(std.mem.indexOf(u8, message, "version solving failed") != null);
}

test "feature統合は和集合で有効化する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "mid", .req = "*" }},
        }} },
        .{ .name = "mid", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "shared", .req = "*", .features = &.{"x"} }},
        }} },
        .{ .name = "shared", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "x-only", .req = "*" }},
            .features = &.{.{ .name = "x", .items = &.{"x-only"} }},
        }} },
        .{ .name = "x-only", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const nodes = nodesOf(&res);
    // 初回解では shared の feature x が未確定だが、収束後に x-only が取り込まれる。
    try expectVersion(nodes, "x-only", "1.0.0");
    const shared = findNode(nodes, "shared").?;
    var saw_x = false;
    for (shared.features) |feature| {
        if (std.mem.eql(u8, feature, "x")) saw_x = true;
    }
    try T.expect(saw_x);
}

test "推移的に要求されたfeatureが次反復で推移依存を追加する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "left", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "lib", .req = "*", .features = &.{"a"} }},
        }} },
        .{ .name = "right", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "lib", .req = "*", .features = &.{"b"} }},
        }} },
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{
                .{ .name = "dep-a", .req = "*" },
                .{ .name = "dep-b", .req = "*" },
            },
            .features = &.{
                .{ .name = "a", .items = &.{"dep-a"} },
                .{ .name = "b", .items = &.{"dep-b"} },
            },
        }} },
        .{ .name = "dep-a", .versions = &.{.{ .version = "1.0.0" }} },
        .{ .name = "dep-b", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    const root_deps = [_]resolver.Dependency{
        dep(gpa, "left", "*"),
        dep(gpa, "right", "*"),
    };
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const nodes = nodesOf(&res);
    try expectVersion(nodes, "dep-a", "1.0.0");
    try expectVersion(nodes, "dep-b", "1.0.0");
    const lib = findNode(nodes, "lib").?;
    try T.expectEqual(@as(usize, 2), lib.features.len);
}

// ---------------------------------------------------------------------------
// runtime / engines / OS / source-native
// ---------------------------------------------------------------------------

fn parseManifest(allocator: std.mem.Allocator, source: []const u8) !manifest.Manifest {
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    return manifest.parse(allocator, source, &diagnostics);
}

test "default-features=falseは推移依存を無効化する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{
                .{ .name = "default-dep", .req = "*" },
                .{ .name = "secure-dep", .req = "*" },
            },
            .features = &.{
                .{ .name = "default", .items = &.{"default-dep"} },
                .{ .name = "secure", .items = &.{"secure-dep"} },
            },
        }} },
        .{ .name = "default-dep", .versions = &.{.{ .version = "1.0.0" }} },
        .{ .name = "secure-dep", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    var root_dep = dep(gpa, "lib", "*");
    root_dep.default_features = false;
    root_dep.features = &.{"secure"};
    const root_deps = [_]resolver.Dependency{root_dep};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const nodes = nodesOf(&res);
    try T.expect(versionOf(nodes, "default-dep") == null);
    try expectVersion(nodes, "secure-dep", "1.0.0");
}

test "semver rangeをpubgrub区間へ正しく変換する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct {
        req: []const u8,
        matching: []const []const u8,
        non_matching: []const []const u8,
    }{
        .{ .req = "*", .matching = &.{ "0.0.0", "9.9.9" }, .non_matching = &.{} },
        .{ .req = "^1.2.3", .matching = &.{ "1.2.3", "1.9.9" }, .non_matching = &.{ "1.2.2", "2.0.0" } },
        .{ .req = ">1.0.0 <=2.0.0", .matching = &.{ "1.0.1", "2.0.0" }, .non_matching = &.{ "1.0.0", "2.0.1" } },
        .{ .req = "<1.0.0 || >=2.0.0", .matching = &.{ "0.9.9", "2.0.0" }, .non_matching = &.{ "1.0.0", "1.5.0" } },
        .{ .req = "1.2", .matching = &.{ "1.2.0", "1.2.9" }, .non_matching = &.{"1.3.0"} },
        .{ .req = "~1.2.3", .matching = &.{ "1.2.3", "1.2.9" }, .non_matching = &.{"1.3.0"} },
    };
    for (cases) |case| {
        const parsed = try semver.Range.parse(gpa, case.req);
        const range = try resolver.rangeFromSemver(gpa, parsed);
        for (case.matching) |text| {
            try T.expect(range.contains(try Version.parse(text)));
        }
        for (case.non_matching) |text| {
            try T.expect(!range.contains(try Version.parse(text)));
        }
    }
    // `sets.len == 0` は全 version 一致のセンチネル。
    const sentinel = semver.Range{ .sets = &.{}, .text = "" };
    try T.expect((try resolver.rangeFromSemver(gpa, sentinel)).isAny());
}

test "深いfeature連鎖でもスタックを消費しない" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const depth = 4096;
    const features = try gpa.alloc(resolver.FeatureDefinition, depth);
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "f{d:0>4}", .{i});
        const items = try gpa.alloc([]const u8, 1);
        if (i + 1 < depth) {
            items[0] = try std.fmt.allocPrint(gpa, "f{d:0>4}", .{i + 1});
        } else {
            items[0] = "leaf";
        }
        features[i] = .{ .name = name, .items = items };
    }
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "leaf", .req = "*" }},
            .features = features,
        }} },
        .{ .name = "leaf", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    var root_dep = dep(gpa, "lib", "*");
    root_dep.features = &.{"f0000"};
    const root_deps = [_]resolver.Dependency{root_dep};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    try expectVersion(nodesOf(&res), "leaf", "1.0.0");
}

test "prereleaseはreleaseより低優先で選択される" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{
            .{ .version = "1.0.0" },
            .{ .version = "2.0.0-alpha" },
        } },
    } };
    // 制約が両方を許す場合は release が勝つ。
    const any_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var any_res = try solve(gpa, &mock, &any_deps, .{});
    defer any_res.deinit();
    try expectVersion(nodesOf(&any_res), "lib", "1.0.0");

    // prerelease しか許さない制約では prerelease が選ばれる。
    const pre_deps = [_]resolver.Dependency{dep(gpa, "lib", ">=2.0.0-alpha")};
    var pre_res = try solve(gpa, &mock, &pre_deps, .{});
    defer pre_res.deinit();
    try expectVersion(nodesOf(&pre_res), "lib", "2.0.0-alpha");
}

test "要求featureを持たない版は選択せず別版へbacktrackする" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{
            .{ .version = "1.0.0", .features = &.{.{ .name = "secure", .items = &.{} }} },
            .{ .version = "2.0.0", .features = &.{} },
        } },
    } };
    var root_dep = dep(gpa, "lib", "*");
    root_dep.features = &.{"secure"};
    const root_deps = [_]resolver.Dependency{root_dep};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    // 2.0.0 は secure を持たないため unavailable となり 1.0.0 が選ばれる。
    try expectVersion(nodesOf(&res), "lib", "1.0.0");
}

test "どの版も要求featureを提供しない場合は競合として失敗する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{
            .{ .version = "1.0.0", .features = &.{} },
            .{ .version = "2.0.0", .features = &.{} },
        } },
    } };
    var root_dep = dep(gpa, "lib", "*");
    root_dep.features = &.{"secure"};
    const root_deps = [_]resolver.Dependency{root_dep};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "version solving failed") != null);
}

test "未知のruntimeはSourceがあっても選択不能になる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "index"
        \\path = "src/index.nako3"
        \\
    );
    defer m.deinit();
    const meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "cnkoa" });
    try T.expect(meta.unavailable_reason != null);
    try T.expectEqual(Impl.none, resolver.chooseImplementation(meta, .{ .runtime = "cnkoa" }, false));
    // 既知 runtime では共通 source が選ばれる。
    const lnako_meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako" });
    try T.expect(lnako_meta.unavailable_reason == null);
}

test "明示的に許可されていないprereleaseしかない場合は解決失敗する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{.{ .version = "1.0.0-alpha" }} },
    } };
    // `*` は prerelease 比較子を持たないため 1.0.0-alpha を許可しない。
    const root_deps = [_]resolver.Dependency{dep(gpa, "lib", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "version solving failed") != null);
}

test "prereleaseを許可しない制約が併存するとprereleaseは選べない" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "lib", .versions = &.{
            .{ .version = "2.0.0-alpha" },
            .{ .version = "2.0.0" },
        } },
    } };
    // `*` は prerelease を許可しないため、>=2.0.0-alpha が許可しても全体では
    // prerelease を選べず、release の 2.0.0 が選ばれる。
    const root_deps = [_]resolver.Dependency{
        dep(gpa, "lib", "*"),
        dep(gpa, "lib", ">=2.0.0-alpha"),
    };
    var res = try solve(gpa, &mock, &root_deps, .{});
    defer res.deinit();
    try expectVersion(nodesOf(&res), "lib", "2.0.0");
}

test "runtime不適合はunavailable理由になる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\runtimes = ["cnako"]
        \\
        \\[[exports]]
        \\name = "index"
        \\path = "src/index.nako3"
        \\
    );
    defer m.deinit();
    const meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako" });
    try T.expect(meta.unavailable_reason != null);
    const cnako_meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "cnako" });
    try T.expect(cnako_meta.unavailable_reason == null);
}

test "engines不適合はunavailable理由になる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[package.engines]
        \\lnako = ">=2.0.0"
        \\
        \\[[exports]]
        \\name = "index"
        \\path = "src/index.nako3"
        \\
    );
    defer m.deinit();
    const old = try resolver.metaFromManifest(gpa, &m, .{
        .runtime = "lnako",
        .lnako_version = try semver.Version.parse("1.0.0"),
    });
    try T.expect(old.unavailable_reason != null);
    const new = try resolver.metaFromManifest(gpa, &m, .{
        .runtime = "lnako",
        .lnako_version = try semver.Version.parse("2.1.0"),
    });
    try T.expect(new.unavailable_reason == null);
}

test "OS不適合はproviderのunavailable理由として伝わる" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "native-only", .versions = &.{
            .{ .version = "1.0.0", .unavailable = "no artifact for windows-x86_64-msvc" },
            .{ .version = "2.0.0", .unavailable = "no artifact for windows-x86_64-msvc" },
        } },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "native-only", "*")};
    var res = try solve(gpa, &mock, &root_deps, .{ .target = .{ .os = "windows", .cpu = "x86_64", .abi = "msvc" } });
    defer res.deinit();
    const message = messageOf(&res);
    try T.expect(std.mem.indexOf(u8, message, "no artifact for windows-x86_64-msvc") != null);
}

test "共通source既定とnative明示を選択する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "sqlite"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "index"
        \\path = "src/index.nako3"
        \\native = "libsqlite.dylib"
        \\
    );
    defer m.deinit();

    // 既定: 共通 source。
    const default_meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako" });
    try T.expectEqual(Impl.source, resolver.chooseImplementation(default_meta, .{ .runtime = "lnako" }, false));
    // prefer-native 明示 (lnako): native。
    try T.expectEqual(Impl.native, resolver.chooseImplementation(default_meta, .{ .runtime = "lnako" }, true));
    // cnako は prefer-native を無視して source。
    try T.expectEqual(Impl.source, resolver.chooseImplementation(default_meta, .{ .runtime = "cnako" }, true));

    // 解決結果へ反映される。
    const mock = Mock{ .pkgs = &.{
        .{ .name = "sqlite", .versions = &.{.{
            .version = "1.0.0",
            .has_source = true,
            .has_native = true,
        }} },
    } };
    const plain = dep(gpa, "sqlite", "*");
    const plain_deps = [_]resolver.Dependency{plain};
    var plain_res = try solve(gpa, &mock, &plain_deps, .{});
    defer plain_res.deinit();
    try T.expectEqual(Impl.source, findNode(nodesOf(&plain_res), "sqlite").?.implementation);

    var prefer = dep(gpa, "sqlite", "*");
    prefer.prefer_native = true;
    const prefer_deps = [_]resolver.Dependency{prefer};
    var prefer_res = try solve(gpa, &mock, &prefer_deps, .{});
    defer prefer_res.deinit();
    const node = findNode(nodesOf(&prefer_res), "sqlite").?;
    try T.expectEqual(Impl.native, node.implementation);
    try T.expect(node.prefer_native);
}

test "native専用packageはcnakoで解決不能" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "native-only"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "plugin"
        \\native = "libnative.dylib"
        \\
    );
    defer m.deinit();
    const lnako_meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako" });
    try T.expect(lnako_meta.unavailable_reason == null);
    const cnako_meta = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "cnako" });
    try T.expect(cnako_meta.unavailable_reason != null);
}

test "ESM専用packageは通常lnakoで解決不能・compat-jsで解決可能" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var m = try parseManifest(gpa,
        \\[package]
        \\name = "esm-only"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "index"
        \\esm = "src/index.mjs"
        \\
    );
    defer m.deinit();
    const normal = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako" });
    try T.expect(normal.unavailable_reason != null);
    const compat = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "lnako", .compat_js = true });
    try T.expect(compat.unavailable_reason == null);
    const cnako = try resolver.metaFromManifest(gpa, &m, .{ .runtime = "cnako" });
    try T.expect(cnako.unavailable_reason == null);
}

// ---------------------------------------------------------------------------
// brute-force oracle
// ---------------------------------------------------------------------------

fn rngVersion(gpa: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "0.{d}.0", .{index + 1});
}

fn oracleExists(
    gpa: std.mem.Allocator,
    n_pkgs: usize,
    versions: [][]const Version,
    deps: [][][]const usize,
    dep_ranges: [][][]const semver.Range,
    unavailable: [][]const bool,
    root_targets: []const usize,
    root_ranges: []const semver.Range,
) !bool {
    _ = gpa;
    const combo = try std.heap.page_allocator.alloc(?usize, n_pkgs);
    defer std.heap.page_allocator.free(combo);

    const total_subsets = @as(usize, 1) << @intCast(n_pkgs);
    var mask: usize = 0;
    while (mask < total_subsets) : (mask += 1) {
        var space: usize = 1;
        var any = false;
        for (0..n_pkgs) |p| {
            if (mask & (@as(usize, 1) << @intCast(p)) == 0) continue;
            any = true;
            var avail: usize = 0;
            for (unavailable[p]) |u| {
                if (!u) avail += 1;
            }
            if (avail == 0) {
                space = 0;
                break;
            }
            space *= avail;
        }
        if (!any or space == 0) continue;

        var i: usize = 0;
        outer: while (i < space) : (i += 1) {
            var rem = i;
            for (0..n_pkgs) |p| {
                if (mask & (@as(usize, 1) << @intCast(p)) == 0) {
                    combo[p] = null;
                    continue;
                }
                var avail: std.ArrayList(usize) = .empty;
                defer avail.deinit(std.heap.page_allocator);
                for (unavailable[p], 0..) |u, vi| {
                    if (!u) try avail.append(std.heap.page_allocator, vi);
                }
                combo[p] = avail.items[rem % avail.items.len];
                rem /= avail.items.len;
            }
            for (root_targets, root_ranges) |target, range| {
                const sel = combo[target] orelse continue :outer;
                if (!range.satisfies(versions[target][sel].toSemver())) continue :outer;
            }
            for (0..n_pkgs) |p| {
                const sel = combo[p] orelse continue;
                for (deps[p][sel], dep_ranges[p][sel]) |target, range| {
                    const dsel = combo[target] orelse continue :outer;
                    if (!range.satisfies(versions[target][dsel].toSemver())) continue :outer;
                }
            }
            return true;
        }
    }
    return false;
}

test "小規模グラフを全探索oracleと差分比較する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var case: usize = 0;
    while (case < 200) : (case += 1) {
        const n_pkgs = 2 + random.uintLessThan(usize, 4);
        const max_vers = 1 + random.uintLessThan(usize, 3);

        const names = try gpa.alloc([]const u8, n_pkgs);
        for (names, 0..) |*name, p| name.* = try std.fmt.allocPrint(gpa, "p{d}", .{p});

        // generate versions and per-version dependency request strings
        const versions = try gpa.alloc([]const Version, n_pkgs);
        const dep_targets = try gpa.alloc([][]const usize, n_pkgs);
        const dep_ranges = try gpa.alloc([][]const semver.Range, n_pkgs);
        const unavailable = try gpa.alloc([]const bool, n_pkgs);
        const mock_pkgs = try gpa.alloc(Mock.Pkg, n_pkgs);
        const mock_vers = try gpa.alloc([]Mock.Ver, n_pkgs);

        for (0..n_pkgs) |p| {
            const n_vers = 1 + random.uintLessThan(usize, max_vers);
            const vers = try gpa.alloc(Version, n_vers);
            const targets = try gpa.alloc([]const usize, n_vers);
            const ranges = try gpa.alloc([]const semver.Range, n_vers);
            const unav = try gpa.alloc(bool, n_vers);
            const mvers = try gpa.alloc(Mock.Ver, n_vers);
            for (0..n_vers) |vi| {
                vers[vi] = try Version.parse(try rngVersion(gpa, vi));
                var target_list: std.ArrayList(usize) = .empty;
                var range_list: std.ArrayList(semver.Range) = .empty;
                var mock_deps: std.ArrayList(Mock.Dep) = .empty;
                for (0..n_pkgs) |d| {
                    // 依存を低位 index の package に限り、oracle を DAG に保つ
                    // （resolver は循環を E004 として失敗にする）。
                    if (d >= p) continue;
                    if (random.float(f32) >= 0.35) continue;
                    const req_text: []const u8 = switch (random.uintLessThan(u8, 7)) {
                        0 => "*",
                        1 => try std.fmt.allocPrint(gpa, ">=0.{d}.0", .{1 + random.uintLessThan(usize, vi + 1)}),
                        2 => try std.fmt.allocPrint(gpa, "<0.{d}.0", .{1 + random.uintLessThan(usize, n_vers)}),
                        3 => try std.fmt.allocPrint(gpa, "0.{d}.0", .{1 + random.uintLessThan(usize, n_vers)}),
                        4 => try std.fmt.allocPrint(gpa, ">0.{d}.0", .{random.uintLessThan(usize, n_vers)}),
                        5 => try std.fmt.allocPrint(gpa, "<=0.{d}.0", .{1 + random.uintLessThan(usize, n_vers)}),
                        else => try std.fmt.allocPrint(gpa, "0.{d}.0 || 0.{d}.0", .{
                            1 + random.uintLessThan(usize, n_vers),
                            1 + random.uintLessThan(usize, n_vers),
                        }),
                    };
                    const parsed = try semver.Range.parse(gpa, req_text);
                    try target_list.append(gpa, d);
                    try range_list.append(gpa, parsed);
                    try mock_deps.append(gpa, .{ .name = names[d], .req = req_text });
                }
                targets[vi] = target_list.items;
                ranges[vi] = range_list.items;
                unav[vi] = random.float(f32) < 0.1;
                mvers[vi] = .{
                    .version = try rngVersion(gpa, vi),
                    .deps = mock_deps.items,
                    .unavailable = if (unav[vi]) "generated-unavailable" else null,
                };
            }
            versions[p] = vers;
            dep_targets[p] = targets;
            dep_ranges[p] = ranges;
            unavailable[p] = unav;
            mock_vers[p] = mvers;
            mock_pkgs[p] = .{ .name = names[p], .versions = mock_vers[p] };
        }

        // root requests
        var root_targets: std.ArrayList(usize) = .empty;
        var root_ranges: std.ArrayList(semver.Range) = .empty;
        var root_deps: std.ArrayList(resolver.Dependency) = .empty;
        var used = std.AutoHashMap(usize, void).init(gpa);
        const n_root = 1 + random.uintLessThan(usize, n_pkgs);
        for (0..n_root) |_| {
            const d = random.uintLessThan(usize, n_pkgs);
            if (used.contains(d)) continue;
            try used.put(d, {});
            const req_text: []const u8 = switch (random.uintLessThan(u8, 5)) {
                0 => "*",
                1 => ">=0.1.0",
                2 => "<0.2.0",
                3 => "<=0.2.0",
                else => ">0.1.0",
            };
            try root_targets.append(gpa, d);
            try root_ranges.append(gpa, try semver.Range.parse(gpa, req_text));
            try root_deps.append(gpa, dep(gpa, names[d], req_text));
        }

        const mock = Mock{ .pkgs = mock_pkgs };
        var res = try solve(gpa, &mock, root_deps.items, .{});
        defer res.deinit();

        const exists = try oracleExists(
            gpa,
            n_pkgs,
            versions,
            dep_targets,
            dep_ranges,
            unavailable,
            root_targets.items,
            root_ranges.items,
        );

        switch (res.result) {
            .resolved => |nodes| {
                if (!exists) return error.TestUnexpectedResult;
                try verifyResolved(nodes, n_pkgs, names, versions, dep_targets, dep_ranges, unavailable, root_targets.items, root_ranges.items);
            },
            .failed => {
                if (exists) {
                    std.debug.print("case {d}: solver failed but oracle found a solution\n", .{case});
                    return error.TestUnexpectedResult;
                }
            },
            .cycle => {
                // 生成した graph は cycle を持たないため到達しない。
                return error.TestUnexpectedResult;
            },
        }
    }
}

fn verifyResolved(
    nodes: []const resolver.PackageNode,
    n_pkgs: usize,
    names: []const []const u8,
    versions: [][]const Version,
    dep_targets: [][][]const usize,
    dep_ranges: [][][]const semver.Range,
    unavailable: [][]const bool,
    root_targets: []const usize,
    root_ranges: []const semver.Range,
) !void {
    const selected = try std.heap.page_allocator.alloc(?Version, n_pkgs);
    defer std.heap.page_allocator.free(selected);
    for (selected) |*slot| slot.* = null;
    for (nodes) |node| {
        const name = switch (node.id) {
            .pkg => |n| n,
            .npm => unreachable,
        };
        for (names, 0..) |candidate, p| {
            if (std.mem.eql(u8, candidate, name)) selected[p] = node.version;
        }
    }
    for (root_targets, root_ranges) |target, range| {
        const sel = selected[target] orelse return error.MissingRootDep;
        try T.expect(range.satisfies(sel.toSemver()));
    }
    for (nodes) |node| {
        const name = switch (node.id) {
            .pkg => |n| n,
            .npm => unreachable,
        };
        const p = blk: {
            for (names, 0..) |candidate, idx| {
                if (std.mem.eql(u8, candidate, name)) break :blk idx;
            }
            return error.UnknownPackage;
        };
        const vi = blk: {
            for (versions[p], 0..) |ver, idx| {
                if (Version.cmp(ver, node.version) == .eq) break :blk idx;
            }
            return error.SelectedUnlisted;
        };
        try T.expect(!unavailable[p][vi]);
        for (dep_targets[p][vi], dep_ranges[p][vi]) |target, range| {
            const sel = selected[target] orelse return error.MissingDep;
            try T.expect(range.satisfies(sel.toSemver()));
        }
    }
}

// ---------------------------------------------------------------------------
// scale and allocation failure
// ---------------------------------------------------------------------------

test "大きな合成グラフを決定的に解決する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const count = 256;
    const names = try gpa.alloc([]const u8, count);
    const pkgs = try gpa.alloc(Mock.Pkg, count);
    const vers = try gpa.alloc([]Mock.Ver, count);
    const mvers = try gpa.alloc([4]Mock.Ver, count);
    for (0..count) |i| {
        names[i] = try std.fmt.allocPrint(gpa, "p{d:0>4}", .{i});
    }
    for (0..count) |i| {
        var versions: [4]Mock.Ver = undefined;
        for (0..4) |v| {
            const ver_text = try std.fmt.allocPrint(gpa, "1.{d}.0", .{v});
            var deps: std.ArrayList(Mock.Dep) = .empty;
            if (i + 1 < count) {
                // 古い version ほど次の package への制約が広い。
                const req_text = if (v == 3) "^1.0.0" else try std.fmt.allocPrint(gpa, ">={d}.0.0", .{v});
                try deps.append(gpa, .{ .name = names[i + 1], .req = req_text });
            }
            versions[v] = .{ .version = ver_text, .deps = deps.items };
        }
        mvers[i] = versions;
        vers[i] = &mvers[i];
        pkgs[i] = .{ .name = names[i], .versions = vers[i] };
    }
    const mock = Mock{ .pkgs = pkgs };
    const root_deps = [_]resolver.Dependency{dep(gpa, names[0], "*")};
    var first: ?[]const u8 = null;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        var res = try solve(gpa, &mock, &root_deps, .{});
        defer res.deinit();
        try T.expectEqual(@as(usize, count), nodesOf(&res).len);
        const text = try serialize(gpa, &res);
        if (first) |f| {
            try T.expectEqualStrings(f, text);
        } else {
            first = try gpa.dupe(u8, text);
        }
    }
}

test "allocation failureでリークせず停止する" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const mock = Mock{ .pkgs = &.{
        .{ .name = "a", .versions = &.{.{
            .version = "1.0.0",
            .deps = &.{.{ .name = "b", .req = "*" }},
        }} },
        .{ .name = "b", .versions = &.{.{ .version = "1.0.0" }} },
    } };
    const root_deps = [_]resolver.Dependency{dep(gpa, "a", "*")};

    var fail_index: usize = 0;
    var saw_oom = false;
    var saw_success = false;
    while (fail_index < 400) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(T.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var res = solve(allocator, &mock, &root_deps, .{}) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                continue;
            },
            else => return err,
        };
        saw_success = true;
        res.deinit();
    }
    try T.expect(saw_oom);
    try T.expect(saw_success);
}
