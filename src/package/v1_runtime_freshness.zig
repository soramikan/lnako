//! v1 実行時の manifest 鮮度検証。
//!
//! `nako.lock` の profile は解決済みの直接依存（`root`）を保持する。実行時に
//! 現在の `nako.toml`・選択 profile・runtime・feature 選択から同じ宣言を
//! 作り直し、lock の `root` と一致しなければ古い環境を使わない（§6.1）。
//!
//! このモジュールはファイルを書かない。`--no-sync` / `--locked` でも
//! 書き換えず、呼出し側が `StaleEnvironment` として失敗させる。
//!
//! lock の構造は変更しない。比較対象は lock が既に持つ `root` の宣言
//! （id・req・alias・features・default_features・optional・
//! allow_global_commands・runtimes）だけであり、解決済みの `to`（版）は
//! 再解決せず lock の固定をそのまま使う。

const std = @import("std");
const v1_manifest = @import("v1_manifest.zig");
const v1_lock = @import("v1_lock.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    UnknownProfile,
    UnknownFeature,
    DuplicateDependency,
    /// 現在の manifest が選ぶ profile 名が lock と違う。
    ProfileMismatch,
    /// 現在の manifest が選ぶ profile の runtime が lock と違う。
    RuntimeMismatch,
    /// 直接依存の契約（件数・id・req・alias・features・許可）が lock と違う。
    RootDeclarationMismatch,
};

pub const Inputs = struct {
    /// CLI の `--profile`。null は manifest の既定選択。
    profile: ?[]const u8 = null,
    /// CLI の `--features`。
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
};

/// 現在の manifest と lock profile のルート宣言が一致するか検証する。
/// 一致しなければ対応する `Error` を返す（書き換えは行わない）。
pub fn verify(
    allocator: Allocator,
    manifest: *const v1_manifest.Manifest,
    lock_profile: *const v1_lock.Profile,
    inputs: Inputs,
) Error!void {
    const choice = v1_manifest.selectProfile(manifest, inputs.profile) catch |err| switch (err) {
        error.UnknownProfile => return error.UnknownProfile,
    };
    if (!std.mem.eql(u8, choice.name, lock_profile.name)) return error.ProfileMismatch;
    if (choice.runtime != lock_profile.runtime) return error.RuntimeMismatch;

    const roots = v1_manifest.effectiveRootDependencies(
        manifest,
        allocator,
        lock_profile.runtime,
        inputs.features,
        inputs.no_default_features,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownProfile => return error.UnknownProfile,
        error.UnknownFeature => return error.UnknownFeature,
        error.DuplicateDependency => return error.DuplicateDependency,
    };
    defer allocator.free(roots);
    if (roots.len != lock_profile.root.len) return error.RootDeclarationMismatch;

    const used = try allocator.alloc(bool, lock_profile.root.len);
    defer allocator.free(used);
    @memset(used, false);
    for (roots) |dependency| {
        var matched = false;
        for (lock_profile.root, 0..) |edge, index| {
            if (used[index]) continue;
            if (!std.mem.eql(u8, edge.id, dependency.id)) continue;
            used[index] = true;
            matched = true;
            if (!declarationMatches(dependency, edge)) return error.RootDeclarationMismatch;
            break;
        }
        if (!matched) return error.RootDeclarationMismatch;
    }
}

fn declarationMatches(dependency: v1_manifest.Dependency, edge: v1_lock.Edge) bool {
    if (!std.mem.eql(u8, dependency.req, edge.req)) return false;
    if (!optionalStringEqual(dependency.alias, edge.alias)) return false;
    if (dependency.default_features != edge.default_features) return false;
    if (dependency.optional != edge.optional) return false;
    if (dependency.allow_global_commands != edge.allow_global_commands) return false;
    // features と runtimes は集合として比較する（§3.3 と同じ扱い）。
    if (!stringSetEqual(dependency.features, edge.features)) return false;
    if (!runtimeSetEqual(dependency.runtimes, edge.runtimes)) return false;
    return true;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn stringSetEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |item| {
        var count_a: usize = 0;
        var count_b: usize = 0;
        for (a) |candidate| {
            if (std.mem.eql(u8, candidate, item)) count_a += 1;
        }
        for (b) |candidate| {
            if (std.mem.eql(u8, candidate, item)) count_b += 1;
        }
        if (count_a != count_b) return false;
    }
    return true;
}

fn runtimeSetEqual(a: []const v1_manifest.Runtime, b: []const v1_manifest.Runtime) bool {
    if (a.len != b.len) return false;
    for (a) |item| {
        var count_a: usize = 0;
        var count_b: usize = 0;
        for (a) |candidate| {
            if (candidate == item) count_a += 1;
        }
        for (b) |candidate| {
            if (candidate == item) count_b += 1;
        }
        if (count_a != count_b) return false;
    }
    return true;
}

test {
    _ = @import("v1_runtime_freshness_test.zig");
}
