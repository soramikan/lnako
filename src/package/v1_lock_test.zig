//! P10 lock の適合性テスト（§6.4・R-09・R-11・D-09・D-10）。

const std = @import("std");
const testing = std.testing;
const types = @import("v1_types.zig");
const lock_mod = @import("v1_lock.zig");

const hash_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const hash_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const hash_d = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

fn node(id: []const u8, version: []const u8, sha256: []const u8, global: bool) lock_mod.GraphNode {
    return .{ .id = id, .version = version, .sha256 = sha256, .kind = .universal, .global = global };
}

fn edge(
    from: ?lock_mod.NodeRef,
    to: lock_mod.NodeRef,
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8,
) lock_mod.GraphEdge {
    return .{
        .from = from,
        .to = to,
        .id = id,
        .req = req,
        .alias = alias,
        .features = &.{},
        .runtimes = &.{ .lnako, .cnako, .wnako },
    };
}

fn release(id: []const u8, version: []const u8, artifacts: []const lock_mod.IndexArtifact) lock_mod.IndexRelease {
    return .{ .id = id, .version = version, .exports_global_commands = false, .artifacts = artifacts };
}

test "D-09 既存 lock の同一 ID 二版を別ノード・別配布物へ保持する" {
    const json_101 = lock_mod.NodeRef{ .id = "@acme/json", .version = "1.0.1" };
    const json_121 = lock_mod.NodeRef{ .id = "@acme/json", .version = "1.2.1" };
    const left_ref = lock_mod.NodeRef{ .id = "@acme/left", .version = "1.0.0" };
    const right_ref = lock_mod.NodeRef{ .id = "@acme/right", .version = "1.0.0" };

    const nodes = [_]lock_mod.GraphNode{
        node("@acme/left", "1.0.0", hash_c, false),
        node("@acme/right", "1.0.0", hash_d, false),
        node("@acme/json", "1.0.1", hash_a, false),
        node("@acme/json", "1.2.1", hash_b, false),
    };
    const root = [_]lock_mod.GraphEdge{
        edge(null, left_ref, "@acme/left", "^1.0.0", null),
        edge(null, right_ref, "@acme/right", "^1.0.0", null),
    };
    const edges = [_]lock_mod.GraphEdge{
        edge(left_ref, json_101, "@acme/json", "~1.0.0", null),
        edge(right_ref, json_121, "@acme/json", "~1.2.0", null),
    };
    var lock = try lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &nodes,
        .root = &root,
        .edges = &edges,
    });
    defer lock.deinit();

    const artifacts_c = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_c }};
    const artifacts_d = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_d }};
    const artifacts_a = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_a }};
    const artifacts_b = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_b }};
    const index = [_]lock_mod.IndexRelease{
        release("@acme/left", "1.0.0", &artifacts_c),
        release("@acme/right", "1.0.0", &artifacts_d),
        release("@acme/json", "1.0.1", &artifacts_a),
        release("@acme/json", "1.2.1", &artifacts_b),
    };
    const actual = [_]lock_mod.ActualHash{
        .{ .key = "@acme/left@1.0.0", .sha256 = hash_c },
        .{ .key = "@acme/right@1.0.0", .sha256 = hash_d },
        .{ .key = "@acme/json@1.0.1", .sha256 = hash_a },
        .{ .key = "@acme/json@1.2.1", .sha256 = hash_b },
    };
    const report = try lock_mod.verify(testing.allocator, &lock, &index, .{
        .actual_hashes = &actual,
        .require_actual = true,
    });
    defer testing.allocator.free(report.warnings);
    try testing.expect(report.failure == null);
    try testing.expectEqual(@as(usize, 0), report.warnings.len);

    const profile = lock.findProfile("default").?;
    var json_nodes: usize = 0;
    for (profile.nodes) |entry| {
        if (!std.mem.eql(u8, entry.id, "@acme/json")) continue;
        json_nodes += 1;
    }
    try testing.expectEqual(@as(usize, 2), json_nodes);
    try testing.expectEqual(@as(usize, 2), profile.edges.len);

    // 同じ lock を決定的に書き出し、再解析して同じノード・辺になる。
    const bytes = try lock_mod.toBytes(&lock, testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try lock_mod.parse(testing.allocator, bytes);
    defer parsed.deinit();
    const parsed_bytes = try lock_mod.toBytes(&parsed, testing.allocator);
    defer testing.allocator.free(parsed_bytes);
    try testing.expectEqualStrings(bytes, parsed_bytes);

    const parsed_profile = parsed.findProfile("default").?;
    try testing.expectEqual(@as(usize, 4), parsed_profile.nodes.len);
    try testing.expectEqual(@as(usize, 2), parsed_profile.root.len);
    try testing.expectEqual(@as(usize, 2), parsed_profile.edges.len);
    try testing.expectEqualStrings("aarch64-macos-none", parsed_profile.target_triple.?);

    // 実バイト列が lock と違えば展開前に拒否する。
    const tampered = [_]lock_mod.ActualHash{
        .{ .key = "@acme/json@1.0.1", .sha256 = hash_b },
    };
    const bad = try lock_mod.verify(testing.allocator, &lock, &index, .{ .actual_hashes = &tampered, .require_actual = false });
    defer testing.allocator.free(bad.warnings);
    try testing.expect(bad.failure != null);
    try testing.expectEqual(lock_mod.VerifyFailureKind.actual_hash_mismatch, bad.failure.?.kind);
}

test "D-10 旧 lock は LegacyLock として拒否し再作成を案内する" {
    // D-10 が指定する lnako 032020f0 の実フィクスチャをそのまま読む。
    const io = testing.io;
    const legacy = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tools/package-system/conformance/valid/lock/simple-v2/nako.lock",
        testing.allocator,
        .limited(1024 * 1024),
    );
    defer testing.allocator.free(legacy);
    try testing.expect(std.mem.indexOf(u8, legacy, "\"schemaVersion\": 2") != null);
    try testing.expect(lock_mod.detectLegacy(legacy));
    try testing.expectError(error.LegacyLock, lock_mod.parse(testing.allocator, legacy));
    try testing.expect(std.mem.indexOf(u8, lock_mod.legacyMessage(), "再作成") != null);
    try testing.expect(std.mem.indexOf(u8, lock_mod.legacyMessage(), "自動変換は行いません") != null);
}

test "公開バージョンは数値幅非依存でlockへ往復できる" {
    const nodes = [_]lock_mod.GraphNode{
        node("@acme/huge", "9007199254740992.0.0-rc.1", hash_a, false),
    };
    var lock = try lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &nodes,
        .root = &.{},
        .edges = &.{},
    });
    defer lock.deinit();

    const bytes = try lock_mod.toBytes(&lock, testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try lock_mod.parse(testing.allocator, bytes);
    defer parsed.deinit();
    const profile = parsed.findProfile("default") orelse return error.TestExpectedProfile;
    try testing.expectEqual(@as(usize, 1), profile.nodes.len);
    try testing.expectEqualStrings("9007199254740992.0.0-rc.1", profile.nodes[0].version);
}

test "R-09 yank 版の lock 照合は警告を返しハッシュ不一致は失敗する" {
    const nodes = [_]lock_mod.GraphNode{
        node("@acme/json", "1.2.0", hash_a, false),
    };
    const root = [_]lock_mod.GraphEdge{
        edge(null, .{ .id = "@acme/json", .version = "1.2.0" }, "@acme/json", "^1.0.0", null),
    };
    var lock = try lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .nodes = &nodes,
        .root = &root,
        .edges = &.{},
    });
    defer lock.deinit();

    const index = [_]lock_mod.IndexRelease{.{
        .id = "@acme/json",
        .version = "1.2.0",
        .yanked = true,
        .artifacts = &.{.{ .kind = .universal, .sha256 = hash_a }},
    }};
    const actual = [_]lock_mod.ActualHash{.{ .key = "@acme/json@1.2.0", .sha256 = hash_a }};
    const report = try lock_mod.verify(testing.allocator, &lock, &index, .{
        .actual_hashes = &actual,
        .require_actual = true,
    });
    defer testing.allocator.free(report.warnings);
    try testing.expect(report.failure == null);
    try testing.expectEqual(@as(usize, 1), report.warnings.len);
    try testing.expectEqual(lock_mod.VerifyWarningKind.yanked_node, report.warnings[0].kind);

    const wrong = [_]lock_mod.IndexRelease{.{
        .id = "@acme/json",
        .version = "1.2.0",
        .yanked = true,
        .artifacts = &.{.{ .kind = .universal, .sha256 = hash_b }},
    }};
    const bad = try lock_mod.verify(testing.allocator, &lock, &wrong, .{});
    defer testing.allocator.free(bad.warnings);
    try testing.expect(bad.failure != null);
    try testing.expectEqual(lock_mod.VerifyFailureKind.artifact_hash_mismatch, bad.failure.?.kind);
}

test "新形式 lock の未知フィールド・不正ハッシュ・未解決参照を拒否する" {
    const good =
        \\{
        \\  "schema_version": 1,
        \\  "profiles": [{
        \\    "name": "default",
        \\    "runtime": "lnako",
        \\    "nodes": [{
        \\      "key": "@acme/json@1.0.0",
        \\      "id": "@acme/json",
        \\      "version": "1.0.0",
        \\      "sha256": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\      "kind": "universal",
        \\      "global": false
        \\    }],
        \\    "root": [{
        \\      "to": "@acme/json@1.0.0",
        \\      "id": "@acme/json",
        \\      "req": "^1.0.0",
        \\      "features": [],
        \\      "default_features": true,
        \\      "optional": false,
        \\      "allow_global_commands": false,
        \\      "runtimes": ["lnako"]
        \\    }],
        \\    "edges": []
        \\  }]
        \\}
    ;
    var parsed = try lock_mod.parse(testing.allocator, good);
    defer parsed.deinit();
    try testing.expect(parsed.findProfile("default") != null);

    const unknown_field =
        \\{"schema_version":1,"profiles":[],"extra":true}
    ;
    try testing.expectError(error.InvalidLock, lock_mod.parse(testing.allocator, unknown_field));

    const bad_hash =
        \\{"schema_version":1,"profiles":[{"name":"default","runtime":"lnako","nodes":[{"key":"@acme/json@1.0.0","id":"@acme/json","version":"1.0.0","sha256":"sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","kind":"universal","global":false}],"root":[],"edges":[]}]}
    ;
    try testing.expectError(error.InvalidLock, lock_mod.parse(testing.allocator, bad_hash));

    const dangling =
        \\{"schema_version":1,"profiles":[{"name":"default","runtime":"lnako","nodes":[],"root":[{"to":"@acme/json@1.0.0","id":"@acme/json","req":"^1.0.0","features":[],"runtimes":[]}],"edges":[]}]}
    ;
    try testing.expectError(error.InvalidLock, lock_mod.parse(testing.allocator, dangling));
}

test "新形式 lock は複数 profile を名前順に保持し重複を拒否する" {
    const inputs = [_]lock_mod.GraphInput{
        .{ .profile = "web", .runtime = .wnako, .nodes = &.{}, .root = &.{}, .edges = &.{} },
        .{ .profile = "default", .runtime = .lnako, .nodes = &.{}, .root = &.{}, .edges = &.{} },
    };
    var lock = try lock_mod.fromGraphs(testing.allocator, &inputs);
    defer lock.deinit();
    try testing.expectEqual(@as(usize, 2), lock.profiles.len);
    try testing.expectEqualStrings("default", lock.profiles[0].name);
    try testing.expectEqual(types.Runtime.lnako, lock.profiles[0].runtime);
    try testing.expectEqualStrings("web", lock.profiles[1].name);
    try testing.expectEqual(types.Runtime.wnako, lock.profiles[1].runtime);

    const duplicate = [_]lock_mod.GraphInput{
        .{ .profile = "default", .runtime = .lnako, .nodes = &.{}, .root = &.{}, .edges = &.{} },
        .{ .profile = "default", .runtime = .cnako, .nodes = &.{}, .root = &.{}, .edges = &.{} },
    };
    try testing.expectError(error.InvalidLock, lock_mod.fromGraphs(testing.allocator, &duplicate));
}

test "#8 lock の edge 範囲は node-semver 7.7.4 の wildcard を受理する" {
    const json_199 = lock_mod.NodeRef{ .id = "@acme/json", .version = "1.9.9" };
    const json_200 = lock_mod.NodeRef{ .id = "@acme/json", .version = "2.0.0" };
    const nodes = [_]lock_mod.GraphNode{
        node("@acme/json", "1.9.9", hash_a, false),
        node("@acme/json", "2.0.0", hash_b, false),
    };
    const root = [_]lock_mod.GraphEdge{
        edge(null, json_199, "@acme/json", "1.x.5", null),
        edge(null, json_200, "@acme/json", "*.1", null),
        edge(null, json_200, "@acme/json", "*.*.*-alpha", null),
    };
    var lock = try lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &nodes,
        .root = &root,
        .edges = &.{},
    });
    defer lock.deinit();

    const artifacts_a = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_a }};
    const artifacts_b = [_]lock_mod.IndexArtifact{.{ .kind = .universal, .sha256 = hash_b }};
    const index = [_]lock_mod.IndexRelease{
        release("@acme/json", "1.9.9", &artifacts_a),
        release("@acme/json", "2.0.0", &artifacts_b),
    };
    const actual = [_]lock_mod.ActualHash{
        .{ .key = "@acme/json@1.9.9", .sha256 = hash_a },
        .{ .key = "@acme/json@2.0.0", .sha256 = hash_b },
    };
    const report = try lock_mod.verify(testing.allocator, &lock, &index, .{
        .actual_hashes = &actual,
        .require_actual = true,
    });
    defer testing.allocator.free(report.warnings);
    try testing.expect(report.failure == null);

    const bytes = try lock_mod.toBytes(&lock, testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try lock_mod.parse(testing.allocator, bytes);
    defer parsed.deinit();
    const profile = parsed.findProfile("default").?;
    try testing.expectEqual(@as(usize, 3), profile.root.len);

    const bad_root = [_]lock_mod.GraphEdge{
        edge(null, json_199, "@acme/json", "1.x.5.6", null),
    };
    try testing.expectError(error.InvalidLock, lock_mod.fromGraph(testing.allocator, .{
        .profile = "default",
        .runtime = .lnako,
        .target_triple = "aarch64-macos-none",
        .nodes = &nodes,
        .root = &bad_root,
        .edges = &.{},
    }));
}
