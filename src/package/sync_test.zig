const std = @import("std");
const cache = @import("cache.zig");
const diag = @import("diagnostics.zig");
const sync = @import("sync.zig");

const app_manifest =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\license = "MIT"
    \\
;

const lib_manifest =
    \\[package]
    \\name = "lib"
    \\version = "1.0.0"
    \\license = "MIT"
    \\
    \\[[exports]]
    \\name = "lib"
    \\path = "src/index.nako3"
    \\
;

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

test "sync は読み取り不能な commands.json を生成fallbackへ黙って落とさない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDirPath(io, "deps/lib/src");
    try temporary.dir.createDirPath(io, "deps/lib/NAKO-PKG/commands.json");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "●テストとは\n  戻る\nここまで\n",
    });

    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const lib_abs = try std.fs.path.join(allocator, &.{ root, "deps/lib" });
    defer allocator.free(lib_abs);
    const tree_digest = try cache.digestTree(io, allocator, lib_abs, &cache.source_pin_exclude);
    const mutable_sha = try std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(tree_digest, .lower)});
    defer allocator.free(mutable_sha);
    const manifest_sha = try sha256Hex(allocator, app_manifest);
    defer allocator.free(manifest_sha);

    const lock_bytes = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}, "mutablePaths": [{{ "path": "deps/lib", "sha256": "{s}" }}] }},
        \\  "packages": {{ "pkg:11111111111111111111111111111111": {{
        \\    "id": "pkg:11111111111111111111111111111111", "name": "lib", "version": "1.0.0",
        \\    "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\    "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\    "dependencies": [], "features": [], "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\  }} }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ manifest_sha, mutable_sha });
    defer allocator.free(lock_bytes);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });

    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidMetadata, sync.run(allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &diagnostics));
}
