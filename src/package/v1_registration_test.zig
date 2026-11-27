//! P10 命令登録の適合性テスト（§6.1・§3.5 の登録情報）。
//! R-04 の scoped 隔離、R-08 の未許可 global、R-12 の両側許可と alias 非継承を
//! 解決済みグラフと COMMANDS 相当の入力から確認する。

const std = @import("std");
const testing = std.testing;
const types = @import("v1_types.zig");
const resolver = @import("v1_resolver.zig");
const registration = @import("v1_registration.zig");

fn dep(id: []const u8, req: []const u8) types.Dependency {
    return .{ .id = id, .req = req };
}

fn graphFrom(outcome: resolver.Outcome) !*resolver.Graph {
    return switch (outcome) {
        .resolved => |graph| blk: {
            const copy = try testing.allocator.create(resolver.Graph);
            copy.* = graph;
            break :blk copy;
        },
        .failed => |failure| {
            std.debug.print("unexpected resolve failure: {any} id={s}\n", .{ failure.kind, failure.id });
            return error.ExpectedResolved;
        },
    };
}

fn expectPlanFailure(outcome: registration.Outcome, kind: registration.FailureKind) !registration.Failure {
    return switch (outcome) {
        .planned => |plan_value| blk: {
            var copy = plan_value;
            copy.deinit();
            break :blk error.ExpectedPlanFailure;
        },
        .failed => |failure| {
            try testing.expectEqual(kind, failure.kind);
            return failure;
        },
    };
}

fn namespace(plan: *const registration.Plan, path: []const u8) !*const registration.Namespace {
    return plan.findNamespace(path) orelse {
        std.debug.print("missing namespace {s}; got:", .{path});
        for (plan.namespaces) |item| std.debug.print(" {s}", .{item.path});
        std.debug.print("\n", .{});
        return error.MissingNamespace;
    };
}

fn expectCommand(space: registration.Namespace, name: []const u8) !void {
    for (space.commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return;
    }
    return error.MissingCommand;
}

test "R-04 scoped 命令は宣言元の名前空間だけに登録する" {
    const left_cmds = [_]registration.Command{.{ .name = "左命令" }};
    const right_cmds = [_]registration.Command{.{ .name = "右命令" }};
    const json1_cmds = [_]registration.Command{.{ .name = "JSON1" }};
    const json2_cmds = [_]registration.Command{.{ .name = "JSON2" }};
    const constants = [_][]const u8{"定数1"};
    const left_exports = [_]registration.Export{.{ .subpath = ".", .binding = .scoped, .commands = &left_cmds }};
    const right_exports = [_]registration.Export{.{ .subpath = ".", .binding = .scoped, .commands = &right_cmds }};
    const json1_exports = [_]registration.Export{.{ .subpath = ".", .binding = .scoped, .commands = &json1_cmds, .constants = &constants }};
    const json2_exports = [_]registration.Export{.{ .subpath = ".", .binding = .scoped, .commands = &json2_cmds }};
    const commands = [_]registration.PackageCommands{
        .{ .id = "@acme/left", .version = "1.0.0", .exports = &left_exports },
        .{ .id = "@acme/right", .version = "1.0.0", .exports = &right_exports },
        .{ .id = "@acme/json", .version = "1.1.0", .exports = &json1_exports },
        .{ .id = "@acme/json", .version = "2.1.0", .exports = &json2_exports },
    };

    const left_deps = [_]types.Dependency{dep("@acme/json", "^1.0.0")};
    const right_deps = [_]types.Dependency{dep("@acme/json", "^2.0.0")};
    const json_versions = [_]resolver.Release{ .{ .version = "1.1.0" }, .{ .version = "2.1.0" } };
    const index = [_]resolver.Package{
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
        .{ .id = "@acme/right", .versions = &.{.{ .version = "1.0.0", .dependencies = &right_deps }} },
        .{ .id = "@acme/json", .versions = &json_versions },
    };
    const root = [_]types.Dependency{ dep("@acme/left", "^1.0.0"), dep("@acme/right", "^1.0.0") };
    const graph = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    const outcome = try registration.plan(testing.allocator, graph, &commands);
    switch (outcome) {
        .planned => |plan_value| {
            var plan_copy = plan_value;
            defer plan_copy.deinit();
            try testing.expectEqual(@as(usize, 0), plan_copy.globals.len);
            const left_space = try namespace(&plan_copy, "left");
            try expectCommand(left_space.*, "左命令");
            const right_space = try namespace(&plan_copy, "right");
            try expectCommand(right_space.*, "右命令");
            const left_json = try namespace(&plan_copy, "left.json");
            try expectCommand(left_json.*, "JSON1");
            try testing.expectEqualStrings("定数1", left_json.constants[0]);
            const right_json = try namespace(&plan_copy, "right.json");
            try expectCommand(right_json.*, "JSON2");
            // scoped の命令名が global 集合へ漏れていない。
            try testing.expect(plan_copy.findNamespace("JSON1") == null);
        },
        .failed => |failure| {
            std.debug.print("R-04 plan failure: {any} id={s}\n", .{ failure.kind, failure.id });
            return error.UnexpectedPlanFailure;
        },
    }
}

test "R-08 allow_global_commands のない global 入口を拒否する" {
    const dsl_scoped = [_]registration.Command{.{ .name = "スコープ命令" }};
    const dsl_global = [_]registration.Command{.{ .name = "HTTP取得" }};
    const dsl_exports = [_]registration.Export{
        .{ .subpath = ".", .binding = .scoped, .commands = &dsl_scoped },
        .{ .subpath = "./dsl", .binding = .global, .commands = &dsl_global },
    };
    const commands = [_]registration.PackageCommands{.{
        .id = "@acme/dsl",
        .version = "1.0.0",
        .exports = &dsl_exports,
        .exports_global_commands = true,
    }};
    const versions = [_]resolver.Release{.{
        .version = "1.0.0",
        .exports_global_commands = true,
        .global_commands = &.{"HTTP取得"},
    }};
    const index = [_]resolver.Package{.{ .id = "@acme/dsl", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/dsl", "^1.0.0")};
    const graph = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }

    const failure = try expectPlanFailure(
        try registration.plan(testing.allocator, graph, &commands),
        .global_not_allowed,
    );
    try testing.expectEqualStrings("@acme/dsl", failure.id);
}

test "R-08 scoped 入口だけを取り込むときは global 許可を要求しない" {
    const dsl_scoped = [_]registration.Command{.{ .name = "スコープ命令" }};
    const dsl_global = [_]registration.Command{.{ .name = "HTTP取得" }};
    const dsl_exports = [_]registration.Export{
        .{ .subpath = ".", .binding = .scoped, .commands = &dsl_scoped },
        .{ .subpath = "./dsl", .binding = .global, .commands = &dsl_global },
    };
    const commands = [_]registration.PackageCommands{.{
        .id = "@acme/dsl",
        .version = "1.0.0",
        .exports = &dsl_exports,
        .exports_global_commands = true,
    }};
    const versions = [_]resolver.Release{.{
        .version = "1.0.0",
        .exports_global_commands = true,
        .global_commands = &.{"HTTP取得"},
    }};
    const index = [_]resolver.Package{.{ .id = "@acme/dsl", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/dsl", "^1.0.0")};
    const graph = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    const requests = [_]registration.Request{.{ .node_key = "@acme/dsl@1.0.0", .subpath = "." }};
    const outcome = try registration.planWithRequests(testing.allocator, graph, &commands, &requests);
    switch (outcome) {
        .planned => |plan_value| {
            var plan_copy = plan_value;
            defer plan_copy.deinit();
            try testing.expectEqual(@as(usize, 0), plan_copy.globals.len);
            try testing.expect(plan_copy.findNamespace("dsl") != null);
        },
        .failed => |failure| {
            std.debug.print("R-08 scoped-only failure: {any}\n", .{failure.kind});
            return error.UnexpectedPlanFailure;
        },
    }
}

test "R-12 ルートの直接許可と宣言元の許可の両方が必要で alias は継承しない" {
    const dsl_scoped = [_]registration.Command{.{ .name = "スコープ命令" }};
    const dsl_global = [_]registration.Command{.{ .name = "HTTP取得" }};
    const dsl_constants = [_][]const u8{"共通定数"};
    const left_cmds = [_]registration.Command{.{ .name = "左命令" }};
    const dsl_exports = [_]registration.Export{
        .{ .subpath = ".", .binding = .scoped, .commands = &dsl_scoped },
        .{ .subpath = "./dsl", .binding = .global, .commands = &dsl_global, .constants = &dsl_constants },
    };
    const left_exports = [_]registration.Export{.{ .subpath = ".", .binding = .scoped, .commands = &left_cmds }};
    const commands = [_]registration.PackageCommands{
        .{ .id = "@acme/dsl", .version = "1.0.0", .exports = &dsl_exports, .exports_global_commands = true },
        .{ .id = "@acme/left", .version = "1.0.0", .exports = &left_exports },
    };
    const dsl_versions = [_]resolver.Release{.{
        .version = "1.0.0",
        .exports_global_commands = true,
        .global_commands = &.{"HTTP取得"},
    }};
    const left_deps = [_]types.Dependency{.{
        .id = "@acme/dsl",
        .req = "^1.0.0",
        .alias = "local_dsl",
        .allow_global_commands = true,
    }};
    const index = [_]resolver.Package{
        .{ .id = "@acme/dsl", .versions = &dsl_versions },
        .{ .id = "@acme/left", .versions = &.{.{ .version = "1.0.0", .dependencies = &left_deps }} },
    };

    const root_without_direct = [_]types.Dependency{dep("@acme/left", "^1.0.0")};
    const graph_without = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root_without_direct, .index = &index }));
    defer {
        graph_without.deinit();
        testing.allocator.destroy(graph_without);
    }
    const dsl_global_request = [_]registration.Request{
        .{ .node_key = "@acme/dsl@1.0.0", .subpath = "./dsl" },
        .{ .node_key = "@acme/dsl@1.0.0", .subpath = "." },
    };
    _ = try expectPlanFailure(
        try registration.planWithRequests(testing.allocator, graph_without, &commands, &dsl_global_request),
        .global_not_allowed,
    );

    const root_with_direct = [_]types.Dependency{
        .{ .id = "@acme/dsl", .req = "^1.0.0", .allow_global_commands = true },
        dep("@acme/left", "^1.0.0"),
    };
    const graph_with = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root_with_direct, .index = &index }));
    defer {
        graph_with.deinit();
        testing.allocator.destroy(graph_with);
    }
    const outcome = try registration.planWithRequests(testing.allocator, graph_with, &commands, &dsl_global_request);
    switch (outcome) {
        .planned => |plan_value| {
            var plan_copy = plan_value;
            defer plan_copy.deinit();
            try testing.expectEqual(@as(usize, 1), plan_copy.globals.len);
            try testing.expectEqualStrings("HTTP取得", plan_copy.globals[0].name);
            try testing.expectEqualStrings("@acme/dsl", plan_copy.globals[0].id);
            // 定数は global 命令名の集合に入れず、別枠で渡す（§3.5）。
            try testing.expectEqual(@as(usize, 1), plan_copy.global_constants.len);
            try testing.expectEqualStrings("共通定数", plan_copy.global_constants[0].name);
            for (plan_copy.globals) |global| try testing.expect(!std.mem.eql(u8, global.name, "共通定数"));
            // ルート直下の dsl と、left の内側の local_dsl の両方に scoped 入口がある。
            _ = try namespace(&plan_copy, "dsl");
            _ = try namespace(&plan_copy, "left.local_dsl");
            // left の alias をルートへ継承しない。
            try testing.expect(plan_copy.findNamespace("local_dsl") == null);
        },
        .failed => |failure| {
            std.debug.print("R-12 plan failure: {any} id={s} name={s}\n", .{ failure.kind, failure.id, failure.name });
            return error.UnexpectedPlanFailure;
        },
    }
}

test "COMMANDS の欠落と global 名の不一致を登録前に拒否する" {
    const versions = [_]resolver.Release{.{ .version = "1.0.0" }};
    const index = [_]resolver.Package{.{ .id = "@acme/plain", .versions = &versions }};
    const root = [_]types.Dependency{dep("@acme/plain", "^1.0.0")};
    const graph = try graphFrom(try resolver.resolve(testing.allocator, .{ .root = &root, .index = &index }));
    defer {
        graph.deinit();
        testing.allocator.destroy(graph);
    }
    const failure = try expectPlanFailure(
        try registration.plan(testing.allocator, graph, &.{}),
        .missing_commands,
    );
    try testing.expectEqualStrings("@acme/plain", failure.id);
}
