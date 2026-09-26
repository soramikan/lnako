const std = @import("std");
const Resolver = @import("import_resolver.zig").Resolver;

test "environment entryのexports省略は空exportとして検証する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/nako.toml", .data = "[package]\nname = \"pkg\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"path\",\"path\":\".nako/env/gen-test/deps/pkg\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\"}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var resolver = try Resolver.load(allocator, io, root);
    resolver.deinit();
}

test "同名packageのmaterialized path差し替えを拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/math");
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/math-2");
    for ([_]struct { dir: []const u8, version: []const u8 }{ .{ .dir = "math", .version = "1.0.0" }, .{ .dir = "math-2", .version = "2.0.0" } }) |package| {
        const manifest_path = try std.fs.path.join(allocator, &.{ ".nako/env/gen-test/deps", package.dir, "nako.toml" });
        defer allocator.free(manifest_path);
        const manifest = try std.fmt.allocPrint(allocator, "[package]\nname = \"math\"\nversion = \"{s}\"\nlicense = \"MIT\"\n[[exports]]\nname = \"main\"\npath = \"index.nako3\"\n", .{package.version});
        defer allocator.free(manifest);
        const source_path = try std.fs.path.join(allocator, &.{ ".nako/env/gen-test/deps", package.dir, "index.nako3" });
        defer allocator.free(source_path);
        try temporary.dir.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
        try temporary.dir.writeFile(io, .{ .sub_path = source_path, .data = "" });
    }
    const lock = "{\"schemaVersion\":2,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:math-v1\":{\"id\":\"pkg:math-v1\",\"name\":\"math\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/math-v1\"},\"dependencies\":[]},\"pkg:math-v2\":{\"id\":\"pkg:math-v2\",\"name\":\"math\",\"version\":\"2.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/math-v2\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[\"pkg:math-v1\"]}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(allocator, "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[],\"packages\":{{\"pkg:math-v1\":{{\"id\":\"pkg:math-v1\",\"name\":\"math\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/math\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}]}},\"pkg:math-v2\":{{\"id\":\"pkg:math-v2\",\"name\":\"math\",\"version\":\"2.0.0\",\"path\":\".nako/env/gen-test/deps/math-2\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}]}}}}}}", .{hash});
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var resolver = try Resolver.load(allocator, io, root);
    resolver.deinit();
    const swapped = try std.mem.replaceOwned(u8, allocator, environment, "\"path\":\".nako/env/gen-test/deps/math\"", "\"path\":\".nako/env/gen-test/deps/math-2\"");
    defer allocator.free(swapped);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = swapped });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
}

test "schema-v2のroot edge省略はenvironment dependencyを拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg");
    const lock = "{\"schemaVersion\":2,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/pkg\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[]}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"pkg\",\"package\":\"pkg:test\"}}],\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\",\"exports\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
}
