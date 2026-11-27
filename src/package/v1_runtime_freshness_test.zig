//! v1 runtime freshness（実行時の manifest / lock root 契約）の単体テスト。

const std = @import("std");
const testing = std.testing;
const v1_manifest = @import("v1_manifest.zig");
const v1_lock = @import("v1_lock.zig");
const v1_runtime_freshness = @import("v1_runtime_freshness.zig");
const types = @import("v1_types.zig");

const left_hash = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const json_hash = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const extra_hash = "sha256:3333333333333333333333333333333333333333333333333333333333333333";

const base_manifest =
    \\schema_version = 1
    \\[package]
    \\[dependencies]
    \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a", "b"], default_features = false, allow_global_commands = true }
    \\"@acme/extra" = { version = "^1.0.0", optional = true }
    \\[runtime-dependencies.lnako]
    \\"@acme/json" = { version = "~1.2.0" }
    \\[features]
    \\default = ["json"]
    \\json = ["dep:json"]
    \\extra = ["dep:extra"]
    \\
;

const RootSpec = struct {
    id: []const u8,
    version: []const u8,
    req: []const u8 = "^1.0.0",
    alias: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    optional: bool = false,
    allow_global_commands: bool = false,
    runtimes: []const types.Runtime = &.{},
};

fn makeLock(
    allocator: std.mem.Allocator,
    profile: []const u8,
    runtime: types.Runtime,
    specs: []const RootSpec,
) !v1_lock.Lock {
    var nodes = try allocator.alloc(v1_lock.GraphNode, specs.len);
    defer allocator.free(nodes);
    var roots = try allocator.alloc(v1_lock.GraphEdge, specs.len);
    defer allocator.free(roots);
    for (specs, 0..) |spec, index| {
        const hash = if (std.mem.eql(u8, spec.id, "@acme/json"))
            json_hash
        else if (std.mem.eql(u8, spec.id, "@acme/extra"))
            extra_hash
        else
            left_hash;
        nodes[index] = .{
            .id = spec.id,
            .version = spec.version,
            .sha256 = hash,
            .kind = .universal,
            .global = spec.allow_global_commands,
        };
        roots[index] = .{
            .to = .{ .id = spec.id, .version = spec.version },
            .id = spec.id,
            .req = spec.req,
            .alias = spec.alias,
            .features = spec.features,
            .default_features = spec.default_features,
            .optional = spec.optional,
            .allow_global_commands = spec.allow_global_commands,
            .runtimes = spec.runtimes,
        };
    }
    return v1_lock.fromGraph(allocator, .{
        .profile = profile,
        .runtime = runtime,
        .nodes = nodes,
        .root = roots,
        .edges = &.{},
    });
}

fn verify(
    allocator: std.mem.Allocator,
    manifest_text: []const u8,
    lock: *const v1_lock.Lock,
    inputs: v1_runtime_freshness.Inputs,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifest = try v1_manifest.parse(a, manifest_text, .local);
    return v1_runtime_freshness.verify(a, &manifest, &lock.profiles[0], inputs);
}

const base_specs = [_]RootSpec{
    .{
        .id = "@acme/left",
        .version = "1.0.0",
        .alias = "left",
        .features = &.{ "a", "b" },
        .default_features = false,
        .allow_global_commands = true,
    },
    .{ .id = "@acme/json", .version = "1.2.0", .req = "~1.2.0", .runtimes = &.{.lnako} },
};

test "freshness: 現在の manifest と lock root が一致する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    try verify(a, base_manifest, &lock, .{});
    // default feature で optional の json が有効になる。
    try verify(a, base_manifest, &lock, .{ .features = &.{"json"} });
}

test "freshness: 削除した直接依存を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a", "b"], default_features = false, allow_global_commands = true }
        \\
    , &lock, .{}));
}

test "freshness: alias の変更を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "other", features = ["a", "b"], default_features = false, allow_global_commands = true }
        \\"@acme/extra" = { version = "^1.0.0", optional = true }
        \\[runtime-dependencies.lnako]
        \\"@acme/json" = { version = "~1.2.0" }
        \\[features]
        \\default = ["json"]
        \\json = ["dep:json"]
        \\extra = ["dep:extra"]
        \\
    , &lock, .{}));
}

test "freshness: allow_global_commands の取り消しを検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a", "b"], default_features = false }
        \\"@acme/extra" = { version = "^1.0.0", optional = true }
        \\[runtime-dependencies.lnako]
        \\"@acme/json" = { version = "~1.2.0" }
        \\[features]
        \\default = ["json"]
        \\json = ["dep:json"]
        \\extra = ["dep:extra"]
        \\
    , &lock, .{}));
}

test "freshness: dependency features / default_features の変更を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a"], default_features = false, allow_global_commands = true }
        \\"@acme/extra" = { version = "^1.0.0", optional = true }
        \\[runtime-dependencies.lnako]
        \\"@acme/json" = { version = "~1.2.0" }
        \\[features]
        \\default = ["json"]
        \\json = ["dep:json"]
        \\extra = ["dep:extra"]
        \\
    , &lock, .{}));
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a", "b"], allow_global_commands = true }
        \\"@acme/extra" = { version = "^1.0.0", optional = true }
        \\[runtime-dependencies.lnako]
        \\"@acme/json" = { version = "~1.2.0" }
        \\[features]
        \\default = ["json"]
        \\json = ["dep:json"]
        \\extra = ["dep:extra"]
        \\
    , &lock, .{}));
}

test "freshness: feature 選択で有効になる optional 依存の差を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    // 既定では extra は無効なので lock と一致する。
    try verify(a, base_manifest, &lock, .{ .no_default_features = false });
    // --features extra では extra がルートへ入るため lock と一致しない。
    try testing.expectError(error.RootDeclarationMismatch, verify(a, base_manifest, &lock, .{ .features = &.{"extra"} }));
}

test "freshness: runtime-dependencies の runtime 混成を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    // lnako 用の直接依存を cnako 側へ移すと lnako の root から消える。
    try testing.expectError(error.RootDeclarationMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/extra" = { version = "^1.0.0", optional = true }
        \\[runtime-dependencies.cnako]
        \\"@acme/left" = { version = "^1.0.0", alias = "left", features = ["a", "b"], default_features = false, allow_global_commands = true }
        \\"@acme/json" = { version = "~1.2.0" }
        \\[runtime-dependencies.lnako]
        \\"@acme/json" = { version = "~1.2.0" }
        \\[features]
        \\default = ["json"]
        \\json = ["dep:json"]
        \\extra = ["dep:extra"]
        \\
    , &lock, .{}));
    // profile の runtime が lock と違えば RuntimeMismatch。
    try testing.expectError(error.RuntimeMismatch, verify(a,
        \\schema_version = 1
        \\[package]
        \\[profiles.default]
        \\runtime = "cnako"
        \\
    , &lock, .{}));
}

test "freshness: profile 名の不一致と不明 profile を検出する" {
    const a = testing.allocator;
    var lock = try makeLock(a, "default", .lnako, &base_specs);
    defer lock.deinit();
    const only_alt =
        \\schema_version = 1
        \\[package]
        \\[profiles.alt]
        \\runtime = "lnako"
        \\
    ;
    try testing.expectError(error.ProfileMismatch, verify(a, only_alt, &lock, .{}));
    try testing.expectError(error.UnknownProfile, verify(a, only_alt, &lock, .{ .profile = "missing" }));
}
