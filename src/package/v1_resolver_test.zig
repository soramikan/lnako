//! P10 依存解決の適合性テスト（§6.1〜§6.4）。
//! フィクスチャ ID を test 名の先頭に付け、入力と期待結果を直接再現する。

const std = @import("std");
const testing = std.testing;
const types = @import("v1_types.zig");
const resolver = @import("v1_resolver.zig");
const lock_mod = @import("v1_lock.zig");
const selection = @import("v1_selection.zig");

const hash_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn dep(id: []const u8, req: []const u8) types.Dependency {
    return .{ .id = id, .req = req };
}

fn expectResolved(outcome: resolver.Outcome) !*resolver.Graph {
    return switch (outcome) {
        .resolved => |graph| blk: {
            const copy = try testing.allocator.create(resolver.Graph);
            copy.* = graph;
            break :blk copy;
        },
        .failed => |failure| {
            std.debug.print("unexpected failure: {any} id={s} req={s} detail={s}\n", .{ failure.kind, failure.id, failure.req, failure.detail });
            return error.ExpectedResolved;
        },
    };
}

fn expectFailure(outcome: resolver.Outcome, kind: resolver.FailureKind) !resolver.Failure {
    return switch (outcome) {
        .resolved => |graph| blk: {
            var copy = graph;
            copy.deinit();
            break :blk error.ExpectedFailure;
        },
        .failed => |failure| {
            try testing.expectEqual(kind, failure.kind);
            return failure;
        },
    };
}

fn expectNode(graph: *const resolver.Graph, id: []const u8, version: []const u8) !usize {
    for (graph.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, id) and std.mem.eql(u8, node.version, version)) return index;
    }
    std.debug.print("missing node {s}@{s}; got:", .{ id, version });
    for (graph.nodes) |node| std.debug.print(" {s}@{s}", .{ node.id, node.version });
    std.debug.print("\n", .{});
    return error.MissingNode;
}

fn expectOnlyVersion(graph: *const resolver.Graph, id: []const u8, version: []const u8) !void {
    var count: usize = 0;
    for (graph.nodes) |node| {
        if (!std.mem.eql(u8, node.id, id)) continue;
        count += 1;
        try testing.expectEqualStrings(version, node.version);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

/// 実クライアントと同じく `v1_selection` を選択関数として注入する。
const TestSelection = struct {
    target: selection.Target,
    permissions: []const selection.SourcePermission = &.{},
    failure: ?selection.Failure = null,

    fn selectFn(context: ?*anyopaque, id: []const u8, artifacts: []const types.Artifact) anyerror!?usize {
        const self: *TestSelection = @ptrCast(@alignCast(context orelse return null));
        return switch (selection.evaluate(id, artifacts, self.target, self.permissions)) {
            .selected => |index| index,
            .failed => |failure| blk: {
                self.failure = failure;
                break :blk null;
            },
        };
    }
};

fn lockFor(nodes: []const lock_mod.GraphNode) !lock_mod.Lock {
    return lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = nodes,
        .root = &.{},
        .edges = &.{},
    });
}

test "R-04 scoped の同一 Package ID 二版を要求範囲ごとに共存させる" {
    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0" },
        .{ .version = "2.1.0" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try testing.expectEqual(@as(usize, 4), graph.nodes.len);
    _ = try expectNode(graph, "@acme/json", "1.1.0");
    _ = try expectNode(graph, "@acme/json", "2.1.0");
    try testing.expectEqual(@as(usize, 2), graph.rootEdges().len);
    try testing.expectEqual(@as(usize, 2), graph.nodeEdges().len);

    var left_edges: usize = 0;
    var right_edges: usize = 0;
    for (graph.nodeEdges()) |edge| {
        const from = graph.nodes[edge.from.?];
        const to = graph.nodes[edge.to];
        try testing.expectEqualStrings("@acme/json", to.id);
        if (std.mem.eql(u8, from.id, "@acme/left")) {
            left_edges += 1;
            try testing.expectEqualStrings("1.1.0", to.version);
        } else if (std.mem.eql(u8, from.id, "@acme/right")) {
            right_edges += 1;
            try testing.expectEqualStrings("2.1.0", to.version);
        }
    }
    try testing.expectEqual(@as(usize, 1), left_edges);
    try testing.expectEqual(@as(usize, 1), right_edges);
}

test "#8 root の v1 範囲は node-semver の wildcard で候補を選ぶ" {
    const json_versions = [_]resolver.Release{
        .{ .version = "1.0.0" },
        .{ .version = "1.9.9" },
        .{ .version = "2.0.0" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const cases = [_]struct { req: []const u8, expected: []const u8 }{
        .{ .req = "1.x.5", .expected = "1.9.9" },
        .{ .req = "*.1", .expected = "2.0.0" },
        .{ .req = "*.*.*-alpha", .expected = "2.0.0" },
    };
    for (cases) |case| {
        const root = [_]types.Dependency{dep("@acme/json", case.req)};
        {
            const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
            defer {
                graph.deinit();
                testing.allocator.destroy(graph);
            }
            try expectOnlyVersion(graph, "@acme/json", case.expected);
        }
    }
}

test "過大な数値の版が index に混じっても既存版の解決を妨げない" {
    // 公開バージョンとしては構文上有効だが、node-semver の
    // Number.MAX_SAFE_INTEGER 制限で range 照合できない版。
    const json_versions = [_]resolver.Release{
        .{ .version = "1.0.0" },
        .{ .version = "9007199254740992.0.0" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    // 照合できない版は候補から外れ、既存の有効な版はそのまま選べる。
    try expectOnlyVersion(graph, "@acme/json", "1.0.0");

    // 既存版が範囲外なら、過大な版は invalid_release ではなく
    // 単なる候補外として扱い、通常の不一致になる。
    const missing_root = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &missing_root, .index = &index }),
        .no_solution,
    );
}

test "R-05 global 版が二つあり単一版へ収束できない" {
    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0", .exports_global_commands = true, .global_commands = &.{"取得"} },
        .{ .version = "2.1.0", .exports_global_commands = true, .global_commands = &.{"取得2"} },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }),
        .global_version_conflict,
    );
}

test "R-06 別パッケージ間の global 命令名衝突を拒否する" {
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .exports_global_commands = true, .global_commands = &.{"共通取得"} }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .exports_global_commands = true, .global_commands = &.{"共通取得"} }} },
    };
    const root = [_]types.Dependency{
        .{ .id = "@acme/left", .req = "^1.0.0", .allow_global_commands = true },
        .{ .id = "@acme/right", .req = "^1.0.0", .allow_global_commands = true },
    };
    const failure = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }),
        .global_command_conflict,
    );
    try testing.expectEqualStrings("共通取得", failure.req);
}

test "R-09 新規解決は yank 版を除外する" {
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0" },
        .{ .version = "1.2.0", .yanked = true },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    try expectOnlyVersion(graph, "@acme/json", "1.1.0");
    try testing.expectEqual(@as(usize, 0), graph.warnings.len);
}

test "R-09 既存 lock の yank 版はハッシュ一致時だけ再利用し警告する" {
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0" },
        .{
            .version = "1.2.0",
            .yanked = true,
            .artifacts = &.{.{ .kind = .universal, .runtimes = &.{ .lnako, .cnako, .wnako }, .sha256 = hash_a, .hosting = .registry }},
        },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const nodes = [_]lock_mod.GraphNode{
        .{ .id = "@acme/json", .version = "1.2.0", .sha256 = hash_a, .kind = .universal, .global = false },
    };
    var lock = try lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .nodes = &nodes,
        .root = &.{},
        .edges = &.{},
    });
    defer lock.deinit();

    const root = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .lock = &lock,
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    try expectOnlyVersion(graph, "@acme/json", "1.2.0");
    try testing.expectEqual(@as(usize, 1), graph.warnings.len);
    try testing.expectEqual(resolver.WarningKind.yanked_from_lock, graph.warnings[0].kind);
    try testing.expectEqualStrings(hash_a, graph.nodes[0].sha256);
}

test "R-10 scoped 版と global 版の共存を拒否する" {
    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0" },
        .{ .version = "2.1.0", .exports_global_commands = true, .global_commands = &.{"取得"} },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }),
        .global_version_conflict,
    );
}

test "R-11 交わらない範囲は同一メジャー二版を共存させる" {
    const left_deps = [_]types.Dependency{dep("@acme/json", "~1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "~1.2.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.0.1" },
        .{ .version = "1.2.1" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    try testing.expectEqual(@as(usize, 4), graph.nodes.len);
    _ = try expectNode(graph, "@acme/json", "1.0.1");
    _ = try expectNode(graph, "@acme/json", "1.2.1");
}

test "R-11 両方を満たす版があれば一版に優先する" {
    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.0.1" },
        .{ .version = "1.2.1" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    try testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try expectOnlyVersion(graph, "@acme/json", "1.2.1");
}

test "R-12 ルート直接依存の global 許可がなくても解決自体は成立する" {
    const left_deps = [_]types.Dependency{.{
        .id = "@acme/dsl",
        .req = "^1.0.0",
        .alias = "local_dsl",
        .allow_global_commands = true,
    }};
    const dsl_versions = [_]resolver.Release{
        .{ .version = "1.0.0", .exports_global_commands = true, .global_commands = &.{"HTTP取得"} },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/dsl", .versions = &dsl_versions },
    };
    const root = [_]types.Dependency{dep("@acme/left", "^1.0.0")};
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    _ = try expectNode(graph, "@acme/dsl", "1.0.0");
    try testing.expectEqual(@as(usize, 1), graph.rootEdges().len);
}

test "M-03 と同じ規則で feature の循環を解決時に拒否する" {
    const features = [_]resolver.Feature{
        .{ .name = "default", .enables = &.{"tls"} },
        .{ .name = "tls", .enables = &.{"http3"} },
        .{ .name = "http3", .enables = &.{"tls"} },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .features = &features }};
    const index = [_]resolver.Package{.{ .id = "@acme/cycle", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/cycle", "^1.0.0")};
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }),
        .feature_cycle,
    );
}

test "optional 依存は有効化された feature のときだけ解決する" {
    const optional_deps = [_]types.Dependency{.{
        .id = "@acme/opt",
        .req = "^1.0.0",
        .alias = "opt",
        .optional = true,
    }};
    const features = [_]resolver.Feature{.{ .name = "opt", .enables = &.{} }};
    const main_versions = [_]resolver.Release{.{ .version = "1.0.0", .dependencies = &optional_deps, .features = &features }};
    const opt_versions = [_]resolver.Release{.{ .version = "1.0.0" }};
    const index = [_]resolver.Package{
        .{ .id = "@acme/main", .versions = &main_versions },
        .{ .id = "@acme/opt", .versions = &opt_versions },
    };

    const without = [_]types.Dependency{dep("@acme/main", "^1.0.0")};
    var outcome = try resolver.resolve(testing.allocator, .{ .root = &without, .index = &index });
    switch (outcome) {
        .resolved => |graph| {
            var copy = graph;
            defer copy.deinit();
            try testing.expectEqual(@as(usize, 1), copy.nodes.len);
        },
        .failed => |failure| {
            std.debug.print("optional without failure: {any}\n", .{failure.kind});
            return error.UnexpectedFailure;
        },
    }

    const with_feature = [_]types.Dependency{.{
        .id = "@acme/main",
        .req = "^1.0.0",
        .features = &.{"opt"},
    }};
    outcome = try resolver.resolve(testing.allocator, .{ .root = &with_feature, .index = &index });
    switch (outcome) {
        .resolved => |graph| {
            var copy = graph;
            defer copy.deinit();
            try testing.expectEqual(@as(usize, 2), copy.nodes.len);
            _ = try expectNode(&copy, "@acme/opt", "1.0.0");
        },
        .failed => |failure| {
            std.debug.print("optional with feature failure: {any}\n", .{failure.kind});
            return error.UnexpectedFailure;
        },
    }
}

fn selectFirst(_: ?*anyopaque, _: []const u8, artifacts: []const types.Artifact) anyerror!?usize {
    if (artifacts.len == 0) return null;
    return 0;
}

test "R-04 解決済みグラフから新形式 lock へ選択済み hash を引き継ぐ" {
    const hash_json1 = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const hash_json2 = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
    const hash_left = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
    const hash_right = "sha256:4444444444444444444444444444444444444444444444444444444444444444";
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const left_artifacts = [_]types.Artifact{.{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_left }};
    const right_artifacts = [_]types.Artifact{.{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_right }};
    const json1_artifacts = [_]types.Artifact{.{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_json1 }};
    const json2_artifacts = [_]types.Artifact{.{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_json2 }};
    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.1.0", .artifacts = &json1_artifacts },
        .{ .version = "2.1.0", .artifacts = &json2_artifacts },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps, .artifacts = &left_artifacts }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps, .artifacts = &right_artifacts }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{ dep("@acme/left", "^1.0.0"), dep("@acme/right", "^1.0.0") };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "aarch64-macos-none",
        .artifacts = .{ .selectFn = selectFirst },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    var lock = try graph.toLock();
    defer lock.deinit();
    const profile = lock.findProfile("default").?;
    try testing.expectEqual(@as(usize, 4), profile.nodes.len);
    var json_nodes: usize = 0;
    for (profile.nodes) |node| {
        if (std.mem.eql(u8, node.id, "@acme/json")) {
            json_nodes += 1;
            if (std.mem.eql(u8, node.version, "1.1.0")) try testing.expectEqualStrings(hash_json1, node.sha256);
            if (std.mem.eql(u8, node.version, "2.1.0")) try testing.expectEqualStrings(hash_json2, node.sha256);
        }
    }
    try testing.expectEqual(@as(usize, 2), json_nodes);
    try testing.expectEqual(@as(usize, 2), profile.root.len);
    try testing.expectEqual(@as(usize, 2), profile.edges.len);
}

test "未知 package は unknown_package、不正 range は invalid_range で返す" {
    const root = [_]types.Dependency{dep("@acme/missing", "^1.0.0")};
    const empty_index = [_]resolver.Package{};
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &root, .index = &empty_index }),
        .unknown_package,
    );

    const bad_root = [_]types.Dependency{dep("@acme/any", "not-a-range")};
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{ .root = &bad_root, .index = &empty_index }),
        .invalid_range,
    );
}

test "R-11 複数の要求を満たす低い共通版を一版で優先する" {
    const left_deps = [_]types.Dependency{dep("@acme/json", ">=1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "~1.2.0")};
    const json_versions = [_]resolver.Release{
        .{ .version = "1.2.5" },
        .{ .version = "1.9.0" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    try testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try expectOnlyVersion(graph, "@acme/json", "1.2.5");
}

test "複数 profile の Graph.toLockInput を一つの lock にまとめられる" {
    const empty_root = [_]types.Dependency{};
    const empty_index = [_]resolver.Package{};
    const default_graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .root = &empty_root,
        .index = &empty_index,
    }));
    defer {
        default_graph.deinit();
        testing.allocator.destroy(default_graph);
    }
    const web_graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .profile = "web",
        .runtime = .wnako,
        .root = &empty_root,
        .index = &empty_index,
    }));
    defer {
        web_graph.deinit();
        testing.allocator.destroy(web_graph);
    }
    const inputs = [_]lock_mod.GraphInput{
        try default_graph.toLockInput(default_graph.arena.allocator()),
        try web_graph.toLockInput(web_graph.arena.allocator()),
    };
    var lock = try lock_mod.fromGraphs(testing.allocator, &inputs);
    defer lock.deinit();
    try testing.expectEqual(@as(usize, 2), lock.profiles.len);
    try testing.expectEqualStrings("default", lock.profiles[0].name);
    try testing.expectEqualStrings("web", lock.profiles[1].name);
}

// ---------------------------------------------------------------------------
// #2 lock 固定候補の環境・許可の再評価
// ---------------------------------------------------------------------------

const hash_source = "sha256:5555555555555555555555555555555555555555555555555555555555555555";
const hash_universal = "sha256:6666666666666666666666666666666666666666666666666666666666666666";
const hash_prebuilt = "sha256:7777777777777777777777777777777777777777777777777777777777777777";

test "#2 lock の native-source も ID と SHA-256 の許可があれば再利用する" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    const permissions = [_]selection.SourcePermission{.{
        .id = "@acme/native",
        .sha256 = hash_source,
    }};
    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
        .permissions = &permissions,
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "aarch64-macos-none",
        .lock = &lock,
        .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try expectOnlyVersion(graph, "@acme/native", "1.0.0");
    try testing.expectEqual(types.Kind.@"native-source", graph.nodes[0].kind.?);
    try testing.expectEqualStrings(hash_source, graph.nodes[0].sha256);
}

test "#2 許可を取り消した lock 候補は universal へフォールバックする" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "aarch64-macos-none",
        .lock = &lock,
        .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try expectOnlyVersion(graph, "@acme/native", "1.0.0");
    try testing.expectEqual(types.Kind.universal, graph.nodes[0].kind.?);
    try testing.expectEqualStrings(hash_universal, graph.nodes[0].sha256);
}

test "#2 許可を取り消した lock 候補に代替がなければ失敗する" {
    const artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
    };
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{
            .root = &root,
            .index = &index,
            .target_triple = "aarch64-macos-none",
            .lock = &lock,
            .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
        }),
        .artifact_selection_failed,
    );
    try testing.expect(context.failure != null);
    try testing.expectEqual(selection.FailureKind.source_permission_required, context.failure.?.kind);
    const diagnostic = try selection.formatFailure(testing.allocator, context.failure.?);
    defer testing.allocator.free(diagnostic);
    try testing.expect(std.mem.indexOf(u8, diagnostic, "native-source") != null);
}

test "#2 yank 済み lock 候補は同じ版の別ハッシュ universal へ切り替えない" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const yanked_artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const newer_artifacts = [_]types.Artifact{
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_a },
    };
    const versions = [_]resolver.Release{
        .{ .version = "1.0.0", .yanked = true, .artifacts = &yanked_artifacts },
        .{ .version = "1.1.0", .artifacts = &newer_artifacts },
    };
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "aarch64-macos-none",
        .lock = &lock,
        .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try expectOnlyVersion(graph, "@acme/native", "1.1.0");
    try testing.expectEqual(types.Kind.universal, graph.nodes[0].kind.?);
    try testing.expectEqualStrings(hash_a, graph.nodes[0].sha256);
    try testing.expectEqual(@as(usize, 0), graph.warnings.len);
}

test "#2 yank 済み lock 候補は代替がなければ別ハッシュ universal を使わず失敗する" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .yanked = true, .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
    };
    const failure = try expectFailure(
        try resolver.resolve(testing.allocator, .{
            .root = &root,
            .index = &index,
            .target_triple = "aarch64-macos-none",
            .lock = &lock,
            .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
        }),
        .artifact_selection_failed,
    );
    try testing.expectEqualStrings("@acme/native", failure.id);
    try testing.expectEqualStrings("1.0.0", failure.req);
    try testing.expect(context.failure != null);
    try testing.expectEqual(selection.FailureKind.source_permission_required, context.failure.?.kind);
}

test "#2 yank 済み lock 候補も hash 一致と許可が揃えば警告付きで再利用する" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{ .kind = .@"native-source", .runtimes = &.{.lnako}, .abi_version = 1, .sha256 = hash_source },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .yanked = true, .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_source,
        .kind = .@"native-source",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    const permissions = [_]selection.SourcePermission{.{ .id = "@acme/native", .sha256 = hash_source }};
    var context = TestSelection{
        .target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null),
        .permissions = &permissions,
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "aarch64-macos-none",
        .lock = &lock,
        .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try expectOnlyVersion(graph, "@acme/native", "1.0.0");
    try testing.expectEqual(types.Kind.@"native-source", graph.nodes[0].kind.?);
    try testing.expectEqualStrings(hash_source, graph.nodes[0].sha256);
    try testing.expectEqual(@as(usize, 1), graph.warnings.len);
    try testing.expectEqual(resolver.WarningKind.yanked_from_lock, graph.warnings[0].kind);
}

test "#2 lock の native-prebuilt が現在の triple と合わなければ universal へ切り替える" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{
            .kind = .@"native-prebuilt",
            .runtimes = &.{.lnako},
            .target_triple = "aarch64-macos-none",
            .abi_version = 1,
            .sha256 = hash_prebuilt,
        },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_prebuilt,
        .kind = .@"native-prebuilt",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 1, .max = 1 }, "2.31"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
        .root = &root,
        .index = &index,
        .target_triple = "x86_64-linux-gnu",
        .lock = &lock,
        .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
    }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try expectOnlyVersion(graph, "@acme/native", "1.0.0");
    try testing.expectEqual(types.Kind.universal, graph.nodes[0].kind.?);
    try testing.expectEqualStrings(hash_universal, graph.nodes[0].sha256);
}

test "#2 lock の native-prebuilt は ABI と glibc の期限切れでも再選択する" {
    const runtimes = [_]types.Runtime{ .lnako, .cnako, .wnako };
    const artifacts = [_]types.Artifact{
        .{
            .kind = .@"native-prebuilt",
            .runtimes = &.{.lnako},
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.28",
            .sha256 = hash_prebuilt,
        },
        .{ .kind = .universal, .runtimes = &runtimes, .sha256 = hash_universal },
    };
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_prebuilt,
        .kind = .@"native-prebuilt",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    const targets = [_]selection.Target{
        // ABI 2 のホストには ABI 1 の固定候補を再利用しない。
        selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 2, .max = 2 }, "2.31"),
        // glibc 2.28 下限を満たさないホストでも固定候補を再利用しない。
        selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 1, .max = 1 }, "2.17"),
    };
    for (targets) |target| {
        var context = TestSelection{ .target = target };
        const graph = try expectResolved(try resolver.resolve(testing.allocator, .{
            .root = &root,
            .index = &index,
            .target_triple = "x86_64-linux-gnu",
            .lock = &lock,
            .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
        }));
        defer {
            graph.deinit();
            testing.allocator.destroy(graph);
        }
        try expectOnlyVersion(graph, "@acme/native", "1.0.0");
        try testing.expectEqual(types.Kind.universal, graph.nodes[0].kind.?);
        try testing.expectEqualStrings(hash_universal, graph.nodes[0].sha256);
    }
}

test "#2 期限切れの lock 候補に代替がなければ失敗する" {
    const artifacts = [_]types.Artifact{.{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "aarch64-macos-none",
        .abi_version = 1,
        .sha256 = hash_prebuilt,
    }};
    const versions = [_]resolver.Release{.{ .version = "1.0.0", .artifacts = &artifacts }};
    const index = [_]resolver.Package{.{ .id = "@acme/native", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/native", "^1.0.0")};

    const nodes = [_]lock_mod.GraphNode{.{
        .id = "@acme/native",
        .version = "1.0.0",
        .sha256 = hash_prebuilt,
        .kind = .@"native-prebuilt",
        .global = false,
    }};
    var lock = try lockFor(&nodes);
    defer lock.deinit();

    var context = TestSelection{
        .target = selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 1, .max = 1 }, "2.31"),
    };
    _ = try expectFailure(
        try resolver.resolve(testing.allocator, .{
            .root = &root,
            .index = &index,
            .target_triple = "x86_64-linux-gnu",
            .lock = &lock,
            .artifacts = .{ .ctx = &context, .selectFn = TestSelection.selectFn },
        }),
        .artifact_selection_failed,
    );
    try testing.expect(context.failure != null);
    try testing.expectEqual(selection.FailureKind.no_compatible_artifact, context.failure.?.kind);
    const diagnostic = try selection.formatFailure(testing.allocator, context.failure.?);
    defer testing.allocator.free(diagnostic);
    try testing.expect(std.mem.indexOf(u8, diagnostic, "x86_64-linux-gnu") != null);
}

// ---------------------------------------------------------------------------
// #7 深さの異なるダイヤモンドの共通版優先
// ---------------------------------------------------------------------------

fn expectSharedEdges(graph: *const resolver.Graph, version: []const u8) !void {
    var left_edges: usize = 0;
    var relay_edges: usize = 0;
    for (graph.nodeEdges()) |edge| {
        if (!std.mem.eql(u8, edge.id, "@acme/shared")) continue;
        const from = graph.nodes[edge.from.?];
        const to = graph.nodes[edge.to];
        try testing.expectEqualStrings(version, to.version);
        if (std.mem.eql(u8, from.id, "@acme/left")) left_edges += 1;
        if (std.mem.eql(u8, from.id, "@acme/relay")) relay_edges += 1;
    }
    try testing.expectEqual(@as(usize, 1), left_edges);
    try testing.expectEqual(@as(usize, 1), relay_edges);
}

test "#7 深さの異なるダイヤモンドでも共通版を一版に固定する" {
    const left_deps = [_]types.Dependency{dep("@acme/shared", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/relay", "^1.0.0")};
    const relay_deps = [_]types.Dependency{dep("@acme/shared", "~1.0.0")};
    const shared_versions = [_]resolver.Release{
        .{ .version = "1.0.1" },
        .{ .version = "1.2.1" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/relay", .versions = &.{.{ .version = "1.0.0", .dependencies = &relay_deps }} },
        .{ .id = "@acme/shared", .versions = &shared_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try expectOnlyVersion(graph, "@acme/shared", "1.0.1");
    try expectSharedEdges(graph, "1.0.1");
}

test "#7 深いダイヤモンドでも global は単一版に収束させる" {
    const left_deps = [_]types.Dependency{dep("@acme/shared", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/relay", "^1.0.0")};
    const relay_deps = [_]types.Dependency{dep("@acme/shared", "~1.0.0")};
    const shared_versions = [_]resolver.Release{
        .{ .version = "1.0.1", .exports_global_commands = true, .global_commands = &.{"共通命令"} },
        .{ .version = "1.2.1", .exports_global_commands = true, .global_commands = &.{"共通命令"} },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/relay", .versions = &.{.{ .version = "1.0.0", .dependencies = &relay_deps }} },
        .{ .id = "@acme/shared", .versions = &shared_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try expectOnlyVersion(graph, "@acme/shared", "1.0.1");
    try expectSharedEdges(graph, "1.0.1");
    var global_count: usize = 0;
    for (graph.nodes) |node| {
        if (node.global) global_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), global_count);
}

test "#7 同一メジャーで交差しない scoped 要求も二版を残す" {
    const left_deps = [_]types.Dependency{dep("@acme/shared", "~1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/relay", "^1.0.0")};
    const relay_deps = [_]types.Dependency{dep("@acme/shared", "~1.2.0")};
    const shared_versions = [_]resolver.Release{
        .{ .version = "1.0.1" },
        .{ .version = "1.2.1" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/relay", .versions = &.{.{ .version = "1.0.0", .dependencies = &relay_deps }} },
        .{ .id = "@acme/shared", .versions = &shared_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try testing.expectEqual(@as(usize, 5), graph.nodes.len);
    _ = try expectNode(graph, "@acme/shared", "1.0.1");
    _ = try expectNode(graph, "@acme/shared", "1.2.1");
}

test "#7 交差しない scoped 要求は深いダイヤモンドでも複数版を残す" {
    const left_deps = [_]types.Dependency{dep("@acme/shared", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/relay", "^1.0.0")};
    const relay_deps = [_]types.Dependency{dep("@acme/shared", "~2.0.0")};
    const shared_versions = [_]resolver.Release{
        .{ .version = "1.0.1" },
        .{ .version = "2.0.1" },
    };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/relay", .versions = &.{.{ .version = "1.0.0", .dependencies = &relay_deps }} },
        .{ .id = "@acme/shared", .versions = &shared_versions },
    };
    const root = [_]types.Dependency{
        dep("@acme/left", "^1.0.0"),
        dep("@acme/right", "^1.0.0"),
    };
    const graph = try expectResolved(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    try testing.expectEqual(@as(usize, 5), graph.nodes.len);
    _ = try expectNode(graph, "@acme/shared", "1.0.1");
    _ = try expectNode(graph, "@acme/shared", "2.0.1");
}
