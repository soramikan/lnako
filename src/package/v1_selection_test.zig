const std = @import("std");
const testing = std.testing;

const types = @import("v1_types.zig");
const selection = @import("v1_selection.zig");

const triple = "x86_64-linux-gnu";
const source_sha = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const changed_source_sha = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const package_id = "@acme/json";

const universal = types.Artifact{
    .kind = .universal,
    .runtimes = &.{ .lnako, .cnako, .wnako },
};

const prebuilt = types.Artifact{
    .kind = .@"native-prebuilt",
    .runtimes = &.{.lnako},
    .target_triple = triple,
    .abi_version = 1,
    .glibc_min = "2.31",
    .sha256 = source_sha,
};

const source = types.Artifact{
    .kind = .@"native-source",
    .runtimes = &.{.lnako},
    .abi_version = 1,
    .sha256 = source_sha,
};

const changed_source = types.Artifact{
    .kind = .@"native-source",
    .runtimes = &.{.lnako},
    .abi_version = 1,
    .sha256 = changed_source_sha,
};

const esm_cnako = types.Artifact{
    .kind = .esm,
    .runtimes = &.{.cnako},
};

const esm_wnako = types.Artifact{
    .kind = .esm,
    .runtimes = &.{.wnako},
};

fn lnakoTarget(glibc: ?[]const u8) selection.Target {
    return .forLnako(triple, .{ .min = 1, .max = 1 }, glibc);
}

fn expectFailure(evaluation: selection.Evaluation) !selection.Failure {
    return switch (evaluation) {
        .selected => return error.TestUnexpectedResult,
        .failed => |failure| failure,
    };
}

test "T-01 lnako は配列末尾の native-prebuilt を universal より優先する" {
    const artifacts = [_]types.Artifact{ universal, source, prebuilt };
    const no_permissions = [_]selection.SourcePermission{};
    try testing.expectEqual(
        @as(usize, 2),
        try selection.select(package_id, &artifacts, lnakoTarget("2.31"), &no_permissions),
    );
}

test "T-02 glibc 不足の native-prebuilt を除外し、許可済み native-source を選ぶ" {
    const artifacts = [_]types.Artifact{ universal, source, prebuilt };
    const permissions = [_]selection.SourcePermission{
        .{ .id = package_id, .sha256 = source_sha },
    };
    try testing.expectEqual(
        @as(usize, 1),
        try selection.select(package_id, &artifacts, lnakoTarget("2.30"), &permissions),
    );
}

test "T-03 glibc 不足で native-source がない場合は universal を選ぶ" {
    const artifacts = [_]types.Artifact{ universal, prebuilt };
    const no_permissions = [_]selection.SourcePermission{};
    try testing.expectEqual(
        @as(usize, 0),
        try selection.select(package_id, &artifacts, lnakoTarget("2.30"), &no_permissions),
    );
}

test "T-04 wnako は native-source と native-prebuilt を受け付けない" {
    const artifacts = [_]types.Artifact{ source, prebuilt };
    const no_permissions = [_]selection.SourcePermission{};
    try testing.expectError(
        error.NoCompatibleArtifact,
        selection.select(package_id, &artifacts, selection.Target.forRuntime(.wnako), &no_permissions),
    );
}

test "T-05 cnako と wnako は runtimes を含む esm を universal より優先する" {
    const no_permissions = [_]selection.SourcePermission{};
    const cnako_artifacts = [_]types.Artifact{ universal, esm_cnako };
    try testing.expectEqual(
        @as(usize, 1),
        try selection.select(package_id, &cnako_artifacts, selection.Target.forRuntime(.cnako), &no_permissions),
    );

    const wnako_artifacts = [_]types.Artifact{ universal, esm_cnako, esm_wnako };
    try testing.expectEqual(
        @as(usize, 2),
        try selection.select(package_id, &wnako_artifacts, selection.Target.forRuntime(.wnako), &no_permissions),
    );

    const reversed_artifacts = [_]types.Artifact{ esm_cnako, universal };
    try testing.expectEqual(
        @as(usize, 1),
        try selection.select(package_id, &reversed_artifacts, selection.Target.forRuntime(.wnako), &no_permissions),
    );
}

test "T-06 適合候補なしの lnako 診断は runtimes と target_triple を列挙する" {
    const artifacts = [_]types.Artifact{prebuilt};
    const no_permissions = [_]selection.SourcePermission{};
    const evaluation = selection.evaluate(package_id, &artifacts, lnakoTarget("2.30"), &no_permissions);
    const failure = try expectFailure(evaluation);
    try testing.expect(failure.kind == .no_compatible_artifact);

    const text = try selection.formatFailure(testing.allocator, failure);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "lnako") != null);
    try testing.expect(std.mem.indexOf(u8, text, triple) != null);
    try testing.expect(std.mem.indexOf(u8, text, "runtimes=[lnako]") != null);
    try testing.expectError(
        error.NoCompatibleArtifact,
        selection.select(package_id, &artifacts, lnakoTarget("2.30"), &no_permissions),
    );
}

test "T-07 対応 ABI が 2 だけなら ABI 1 の native を除外して universal を選ぶ" {
    const artifacts = [_]types.Artifact{ prebuilt, source, universal };
    const permissions = [_]selection.SourcePermission{
        .{ .id = package_id, .sha256 = source_sha },
    };
    const target = selection.Target.forLnako(triple, .{ .min = 2, .max = 2 }, "2.31");
    try testing.expectEqual(
        @as(usize, 2),
        try selection.select(package_id, &artifacts, target, &permissions),
    );
}

test "T-08 未許可またはハッシュ不一致の native-source を飛ばして universal を選ぶ" {
    const no_permissions = [_]selection.SourcePermission{};
    const without_permission = [_]types.Artifact{ universal, source, prebuilt };
    try testing.expectEqual(
        @as(usize, 0),
        try selection.select(package_id, &without_permission, lnakoTarget("2.30"), &no_permissions),
    );

    const permissions = [_]selection.SourcePermission{
        .{ .id = package_id, .sha256 = source_sha },
    };
    const changed = [_]types.Artifact{ universal, changed_source, prebuilt };
    try testing.expectEqual(
        @as(usize, 0),
        try selection.select(package_id, &changed, lnakoTarget("2.30"), &permissions),
    );
}

test "T-09 universal なしで native-source が未許可なら明示許可を診断して失敗する" {
    const artifacts = [_]types.Artifact{source};
    const no_permissions = [_]selection.SourcePermission{};
    const evaluation = selection.evaluate(package_id, &artifacts, lnakoTarget("2.30"), &no_permissions);
    const failure = try expectFailure(evaluation);
    try testing.expect(failure.kind == .source_permission_required);

    const text = try selection.formatFailure(testing.allocator, failure);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "permission") != null);
    try testing.expect(std.mem.indexOf(u8, text, source_sha) != null);
    try testing.expectError(
        error.SourcePermissionRequired,
        selection.select(package_id, &artifacts, lnakoTarget("2.30"), &no_permissions),
    );
}

test "§6.3 非 GNU triple の native-prebuilt は glibc なしで一致する" {
    const macos_prebuilt = types.Artifact{
        .kind = .@"native-prebuilt",
        .runtimes = &.{.lnako},
        .target_triple = "aarch64-macos-none",
        .abi_version = 1,
    };
    const artifacts = [_]types.Artifact{macos_prebuilt};
    const no_permissions = [_]selection.SourcePermission{};
    const target = selection.Target.forLnako("aarch64-macos-none", .{ .min = 1, .max = 1 }, null);
    try testing.expectEqual(
        @as(usize, 0),
        try selection.select(package_id, &artifacts, target, &no_permissions),
    );
}

test "§6.3 ABI 範囲の上限まで受理し、逆転した範囲は invalid_target にする" {
    const abi2_source = types.Artifact{
        .kind = .@"native-source",
        .runtimes = &.{.lnako},
        .abi_version = 2,
        .sha256 = source_sha,
    };
    const artifacts = [_]types.Artifact{abi2_source};
    const permissions = [_]selection.SourcePermission{
        .{ .id = package_id, .sha256 = source_sha },
    };
    const target = selection.Target.forLnako(triple, .{ .min = 1, .max = 2 }, "2.31");
    try testing.expectEqual(
        @as(usize, 0),
        try selection.select(package_id, &artifacts, target, &permissions),
    );

    const invalid = selection.Target.forLnako(triple, .{ .min = 2, .max = 1 }, "2.31");
    const evaluation = selection.evaluate(package_id, &artifacts, invalid, &permissions);
    try testing.expect((try expectFailure(evaluation)).kind == .invalid_target);
    try testing.expectError(error.InvalidTarget, selection.select(package_id, &artifacts, invalid, &permissions));
}
