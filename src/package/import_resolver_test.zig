const std = @import("std");
const Resolver = @import("import_resolver.zig").Resolver;
const resolver = @import("import_resolver.zig");

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
    var loaded = try Resolver.load(allocator, io, root);
    loaded.deinit();
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
    var loaded = try Resolver.load(allocator, io, root);
    loaded.deinit();
    const swapped = try std.mem.replaceOwned(u8, allocator, environment, "\"path\":\".nako/env/gen-test/deps/math\"", "\"path\":\".nako/env/gen-test/deps/math-2\"");
    defer allocator.free(swapped);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = swapped });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
}

test "exportsを持つpackageのmissing materialized rootを拒否しno-export support packageは許可する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps");
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"support\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/support\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const with_exports = try std.fmt.allocPrint(allocator, "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"support\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/support\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}]}}}}}}", .{lock_hex});
    defer allocator.free(with_exports);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = with_exports });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
    const without_exports = try std.mem.replaceOwned(u8, allocator, with_exports, ",\"exports\":[{\"name\":\"main\",\"path\":\"index.nako3\"}]", "");
    defer allocator.free(without_exports);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = without_exports });
    var loaded = try Resolver.load(allocator, io, root);
    loaded.deinit();
}

test "materialized package内の共有writable dirを拒否する" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/nako.toml", .data = "[package]\nname = \"pkg\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/pkg\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\",\"exports\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var loaded = try Resolver.load(allocator, io, root);
    loaded.deinit();
    // materialized tree 配下の dir が共有writableなら export 対象を
    // 差し替えられるため private な `.nako` でも採用できない。
    try temporary.dir.setFilePermissions(io, ".nako/env/gen-test/deps/pkg/lib", std.Io.File.Permissions.fromMode(0o777), .{});
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
    // dir がprivateでも配下fileが共有writableなら export 対象の中身を
    // そのまま書き換えられるため同様に拒否する。
    try temporary.dir.setFilePermissions(io, ".nako/env/gen-test/deps/pkg/lib", std.Io.File.Permissions.fromMode(0o755), .{});
    try temporary.dir.setFilePermissions(io, ".nako/env/gen-test/deps/pkg/nako.toml", std.Io.File.Permissions.fromMode(0o666), .{});
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
}

test "宣伝されたexport対象がpackage root内に実在しない環境を拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/nako.toml", .data = "[package]\nname = \"pkg\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[[exports]]\nname = \"main\"\npath = \"index.nako3\"\n" });
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/pkg\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    // export宣言はlock・manifest・environmentで一致していても、対象fileが
    // package root内に無い環境は採用できない。
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/index.nako3", .data = "" });
    var loaded = try Resolver.load(allocator, io, root);
    loaded.deinit();
}

test "対象targetで解決できないexport宣言を持つ環境を拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg");
    // pathを持たないESM専用export。lnako非compat-jsのtargetではresolveが
    // E006を記録してnullを返すため、exportを欠いたenvironmentは受理できない
    // （受理するとpackage import使用時にExportNotFoundへ遅延する）。
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/nako.toml", .data = "[package]\nname = \"pkg\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[[exports]]\nname = \"main\"\nesm = \"m.mjs\"\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/m.mjs", .data = "export {}\n" });
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/pkg\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\",\"exports\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, root));
}

test "lock候補を持たないpackage manifest依存を持つ環境を拒否する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/pkg");
    // 有効な依存宣言に対して lock 側の一致候補が一つも無いのは lock・環境・
    // manifest の不整合であり、alias欠落の環境を受理してはならない。
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/pkg/nako.toml", .data = "[package]\nname = \"pkg\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n[dependencies.pkg]\nabsent = { version = \"1.0.0\", public-id = \"pkg:absent\" }\n" });
    const lock = "{\"schemaVersion\":1,\"input\":{\"profile\":\"default\",\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:test\":{\"id\":\"pkg:test\",\"name\":\"pkg\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/pkg\"},\"dependencies\":[]}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const environment = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"packages\":{{\"pkg:test\":{{\"name\":\"pkg\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/pkg\",\"exports\":[],\"dependencies\":[{{\"alias\":\"absent\",\"package\":\"pkg:absent\"}}]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(environment);
    try temporary.dir.createDirPath(io, ".nako");
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = environment });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
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

test "project environment lookup does not cross the nearest manifest boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "parent/.nako");
    try temporary.dir.createDirPath(io, "parent/victim/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/.nako/environment.json", .data = "{}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/victim/nako.toml", .data = "[package]\nname = \"victim\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/victim/src/main.nako3", .data = "" });
    const input = try temporary.dir.realPathFileAlloc(io, "parent/victim/src/main.nako3", allocator);
    defer allocator.free(input);
    try std.testing.expect((try resolver.findProjectRoot(allocator, io, input)) == null);

    try temporary.dir.createDirPath(io, "parent/victim/.nako");
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/victim/.nako/environment.json", .data = "{}" });
    const found_root = (try resolver.findProjectRoot(allocator, io, input)) orelse return error.ProjectRootNotFound;
    defer allocator.free(found_root);
    const expected_root = try temporary.dir.realPathFileAlloc(io, "parent/victim", allocator);
    defer allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, found_root);
}

test "project environment lookup rejects a .nako symlink outside the manifest root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "parent/.nako");
    try temporary.dir.createDirPath(io, "parent/victim");
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/.nako/environment.json", .data = "{}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/victim/nako.toml", .data = "[package]\nname = \"victim\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "parent/victim/main.nako3", .data = "" });
    temporary.dir.symLink(io, "../.nako", "parent/victim/.nako", .{ .is_directory = true }) catch return error.SkipZigTest;
    const input = try temporary.dir.realPathFileAlloc(io, "parent/victim/main.nako3", allocator);
    defer allocator.free(input);
    try std.testing.expect((try resolver.findProjectRoot(allocator, io, input)) == null);
}

test "project environment lookup rejects a group/world-writable .nako directory" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "victim/.nako");
    try temporary.dir.writeFile(io, .{ .sub_path = "victim/nako.toml", .data = "[package]\nname = \"victim\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "victim/main.nako3", .data = "" });
    // environment.json 自体は read-only でも、dir が共有writableなら
    // materialized tree の差し替えが可能なため採用できない。
    try temporary.dir.writeFile(io, .{ .sub_path = "victim/.nako/environment.json", .data = "{}" });
    try temporary.dir.setFilePermissions(io, "victim/.nako", std.Io.File.Permissions.fromMode(0o777), .{});
    const input = try temporary.dir.realPathFileAlloc(io, "victim/main.nako3", allocator);
    defer allocator.free(input);
    try std.testing.expect((try resolver.findProjectRoot(allocator, io, input)) == null);
}

const manifest_mod = @import("manifest.zig");
const npkg_files = @import("npkg_files.zig");
const semver = @import("semver.zig");

fn temporaryDirRealPathAlloc(allocator: std.mem.Allocator, io: std.Io, base: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var directory = if (std.mem.eql(u8, sub_path, ".")) base else try base.openDir(io, sub_path, .{});
    defer if (!std.mem.eql(u8, sub_path, ".")) directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    return try allocator.dupe(u8, buffer[0..length]);
}

const Value = resolver.Value;
const asArray = resolver.asArray;
const asObject = resolver.asObject;
const findManifestDependencyTarget = resolver.findManifestDependencyTarget;
const findProjectRoot = resolver.findProjectRoot;
const get = resolver.get;
const isWithin = resolver.isWithin;
const namespaceFor = resolver.namespaceFor;
const realPathDirAlloc = resolver.realPathDirAlloc;
const selectExport = resolver.selectExport;

test "manifest dependency lock edge不整合はenvironment validationで拒否する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const locked_json =
        \\{"pkg:other-profile":{"name":"conditional-lib","version":"2.0.0","source":{"type":"registry","url":"https://example.invalid/conditional-lib"},"dependencies":[]},"pkg:current-edge":{"name":"unrelated","version":"1.0.0","source":{"type":"registry","url":"https://example.invalid/unrelated"},"dependencies":[]}}
    ;
    const parsed_lock = try std.json.parseFromSlice(Value, allocator, locked_json, .{});
    defer parsed_lock.deinit();
    const locked_packages = asObject(parsed_lock.value).?;
    const edges_json = "[\"pkg:current-edge\"]";
    const parsed_edges = try std.json.parseFromSlice(Value, allocator, edges_json, .{});
    defer parsed_edges.deinit();
    const allowed_edges = asArray(parsed_edges.value).?;
    const version_range = try semver.Range.parse(allocator, "2.0.0");
    const dependency = manifest_mod.PkgDependency{
        .name = "conditional-lib",
        .version = version_range,
        .version_text = "2.0.0",
        .profile = "windows",
    };

    try std.testing.expectError(error.InvalidEnvironment, findManifestDependencyTarget(
        allocator,
        locked_packages,
        allowed_edges,
        false,
        dependency.name,
        .{ .pkg = dependency },
        null,
    ));
}

test "package importは公開export名とaliasだけを選択しpath traversalを拒否する" {
    const json =
        \\[ {"name":"main","path":"src/main.nako3"},{"name":"utility","alias":"math","path":"src/utility.nako3"},{"name":"vector","path":"src/vector.nako3"}]
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const exports = asArray(parsed.value).?.items;
    const main = try selectExport(exports, null);
    try std.testing.expectEqualStrings("src/main.nako3", get(asObject(main).?, "path").?.string);
    const utility = try selectExport(exports, "math");
    try std.testing.expectEqualStrings("src/utility.nako3", get(asObject(utility).?, "path").?.string);
    const vector = try selectExport(exports, "vector");
    try std.testing.expectEqualStrings("src/vector.nako3", get(asObject(vector).?, "path").?.string);
    try std.testing.expectError(error.ExportNotFound, selectExport(exports, "private"));
    try std.testing.expect(!npkg_files.isCanonicalPath("../outside.nako3"));
}

test "既定exportはmainまたはindexという公開名をファイル名より優先する" {
    const json =
        \\[ {"name":"main","path":"src/main.nako3"}, {"name":"helpers","path":"helpers/index.nako3"} ]
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const selected = try selectExport(asArray(parsed.value).?.items, null);
    try std.testing.expectEqualStrings("main", get(asObject(selected).?, "name").?.string);
}

test "package alias内の識別子不適合文字を参照可能なnamespaceへ変換する" {
    const normalized = try namespaceFor(std.testing.allocator, "my-util", null);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("my_util", normalized);

    const scoped = try namespaceFor(std.testing.allocator, "@alice/my-util", "sub-path");
    defer std.testing.allocator.free(scoped);
    try std.testing.expectEqualStrings("alice__my_util__sub_path", scoped);
}

test "package import path containmentはprefix類似directoryを通さない" {
    const allocator = std.testing.allocator;
    const root = try std.fs.path.join(allocator, &.{ "tmp", "pkg" });
    defer allocator.free(root);
    const nested = try std.fs.path.join(allocator, &.{ root, "src", "index.nako3" });
    defer allocator.free(nested);
    const sibling = try std.fs.path.join(allocator, &.{ "tmp", "pkg-evil", "index.nako3" });
    defer allocator.free(sibling);
    try std.testing.expect(isWithin(root, nested));
    try std.testing.expect(!isWithin(root, sibling));
}

test "環境JSONのrootとpackage scopeでalias・subpathを解決しlock hashを検証する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/math/src");
    try temporary.dir.createDirPath(io, ".nako/env/gen-test/deps/dependency");
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/main.nako3", .data = "" });
    const root_manifest =
        \\[package]
        \\name = "app"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\math = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\windows-math = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111", profile = "windows", alias = "win-math" }
        \\"alice/lib" = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\alice = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222" }
        \\"@alice/tool" = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\
        \\[profiles.windows]
        \\os = "windows"
        \\cpu = "x86_64"
        \\abi = "msvc"
        \\
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = root_manifest });
    var root_manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root_manifest, &root_manifest_digest, .{});
    const root_manifest_sha256 = std.fmt.bytesToHex(root_manifest_digest, .lower);
    const lock_json_template = "{\"schemaVersion\":2,\"resolverVersion\":1,\"input\":{\"manifestSha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"profile\":\"default\",\"features\":[],\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:11111111111111111111111111111111\":{\"id\":\"pkg:11111111111111111111111111111111\",\"name\":\"math\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/math\"},\"dependencies\":[\"pkg:22222222222222222222222222222222\",\"pkg:33333333333333333333333333333333\"]},\"pkg:22222222222222222222222222222222\":{\"id\":\"pkg:22222222222222222222222222222222\",\"name\":\"dependency\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/dependency\"},\"dependencies\":[]},\"pkg:33333333333333333333333333333333\":{\"id\":\"pkg:33333333333333333333333333333333\",\"name\":\"missing\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/missing\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[\"pkg:11111111111111111111111111111111\",\"pkg:22222222222222222222222222222222\"]}}";
    const lock_json = try std.mem.replaceOwned(u8, allocator, lock_json_template, "0000000000000000000000000000000000000000000000000000000000000000", &root_manifest_sha256);
    defer allocator.free(lock_json);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_json });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/nako.toml", .data =
        \\[package]
        \\name = "math"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.pkg]
        \\dependency = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222", alias = "dep" }
        \\windows-dependency = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222", profile = "windows", alias = "win-dependency" }
        \\missing = { version = "1.0.0", public-id = "pkg:33333333333333333333333333333333" }
        \\
        \\[profiles.windows]
        \\os = "windows"
        \\cpu = "x86_64"
        \\abi = "msvc"
        \\
        \\[[exports]]
        \\name = "main"
        \\alias = "math"
        \\path = "src/main.nako3"
        \\[[exports]]
        \\name = "vector"
        \\path = "vector.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/dependency/nako.toml", .data =
        \\[package]
        \\name = "dependency"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/src/main.nako3", .data = "A=1\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/vector.nako3", .data = "B=2\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/dependency/index.nako3", .data = "C=3\n" });
    temporary.dir.symLink(io, "math", ".nako/env/gen-test/deps/math-link", .{}) catch return error.SkipZigTest;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_json, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"math\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"alice/lib\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"lib\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"alice\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"@alice/tool\",\"package\":\"pkg:11111111111111111111111111111111\"}},{{\"alias\":\"tool\",\"package\":\"pkg:11111111111111111111111111111111\"}}],\"packages\":{{\"pkg:11111111111111111111111111111111\":{{\"id\":\"pkg:11111111111111111111111111111111\",\"name\":\"math\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/math\",\"exports\":[{{\"name\":\"main\",\"alias\":\"math\",\"path\":\"src/main.nako3\"}},{{\"name\":\"vector\",\"path\":\"vector.nako3\"}}],\"dependencies\":[{{\"alias\":\"dependency\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"dep\",\"package\":\"pkg:22222222222222222222222222222222\"}},{{\"alias\":\"missing\",\"package\":\"pkg:33333333333333333333333333333333\"}}]}},\"pkg:22222222222222222222222222222222\":{{\"id\":\"pkg:22222222222222222222222222222222\",\"name\":\"dependency\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/dependency\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}]}},\"pkg:33333333333333333333333333333333\":{{\"id\":\"pkg:33333333333333333333333333333333\",\"name\":\"missing\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/missing\",\"exports\":[],\"dependencies\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(json);
    const project_root = try temporaryDirRealPathAlloc(allocator, io, temporary.dir, ".");
    defer allocator.free(project_root);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/env/gen-test/deps/math/private.nako3", .data = "PRIVATE=1\\n" });
    const tampered_root_alias_json = try std.mem.replaceOwned(u8, allocator, json, "\"alias\":\"math\",\"package\":\"pkg:11111111111111111111111111111111\"", "\"alias\":\"math\",\"package\":\"pkg:22222222222222222222222222222222\"");
    defer allocator.free(tampered_root_alias_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_root_alias_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_package_alias_json = try std.mem.replaceOwned(u8, allocator, json, "\"alias\":\"dep\",\"package\":\"pkg:22222222222222222222222222222222\"", "\"alias\":\"dep\",\"package\":\"pkg:33333333333333333333333333333333\"");
    defer allocator.free(tampered_package_alias_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_package_alias_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_export_json = try std.mem.replaceOwned(u8, allocator, json, "\"path\":\"src/main.nako3\"", "\"path\":\"private.nako3\"");
    defer allocator.free(tampered_export_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_export_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_json = try std.mem.replaceOwned(u8, allocator, json, ".nako/env/gen-test/deps/math", "../outside");
    defer allocator.free(tampered_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    const tampered_id_json = try std.mem.replaceOwned(u8, allocator, json, "pkg:11111111111111111111111111111111", "pkg:not-locked-id");
    defer allocator.free(tampered_id_json);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = tampered_id_json });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = json });
    const canonical_hash = try std.fmt.allocPrint(allocator, "sha256:{s}", .{lock_hex});
    defer allocator.free(canonical_hash);
    const base64_buffer = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
    defer allocator.free(base64_buffer);
    const base64_hash = std.base64.standard.Encoder.encode(base64_buffer, &digest);
    const sri_hash = try std.fmt.allocPrint(allocator, "sha256-{s}", .{base64_hash});
    defer allocator.free(sri_hash);
    const hash_variants = [_][]const u8{ canonical_hash, lock_hex[0..], sri_hash };
    for (hash_variants) |hash_text| {
        const variant_json = try std.mem.replaceOwned(u8, allocator, json, canonical_hash, hash_text);
        defer allocator.free(variant_json);
        try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = variant_json });
        var hash_resolver = try Resolver.load(allocator, io, project_root);
        hash_resolver.deinit();
    }
    const cnako_environment = try std.mem.replaceOwned(u8, allocator, json, "\"runtime\":\"lnako\"", "\"runtime\":\"cnako\"");
    defer allocator.free(cnako_environment);
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = cnako_environment });
    try std.testing.expectError(error.InvalidEnvironment, Resolver.load(allocator, io, project_root));
    try temporary.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = json });
    temporary.dir.symLink(io, project_root, ".project-link", .{ .is_directory = true }) catch return error.SkipZigTest;
    const project_alias = try std.fs.path.join(allocator, &.{ project_root, ".project-link" });
    defer allocator.free(project_alias);

    var package_resolver = try Resolver.load(allocator, io, project_alias);
    defer package_resolver.deinit();
    const root_entry = try std.fs.path.join(allocator, &.{ project_root, "main.nako3" });
    defer allocator.free(root_entry);
    const detected_root = (try findProjectRoot(allocator, io, root_entry)).?;
    defer allocator.free(detected_root);
    try std.testing.expectEqualStrings(project_root, detected_root);
    const cwd = try realPathDirAlloc(allocator, io, ".");
    defer allocator.free(cwd);
    try std.testing.expect(std.mem.startsWith(u8, project_root, cwd));
    try std.testing.expect(project_root.len > cwd.len and std.fs.path.isSep(project_root[cwd.len]));
    const relative_directory = project_root[cwd.len + 1 ..];
    const relative_main = try std.fs.path.join(allocator, &.{ relative_directory, "main.nako3" });
    defer allocator.free(relative_main);
    const relative_nested = try std.fs.path.join(allocator, &.{ relative_directory, "src", "main.nako3" });
    defer allocator.free(relative_nested);
    const relative_inputs = [_][]const u8{ relative_main, relative_nested };
    for (relative_inputs) |relative_input| {
        const found_root = (try findProjectRoot(allocator, io, relative_input)) orelse return error.ProjectRootNotFound;
        defer allocator.free(found_root);
        try std.testing.expectEqualStrings(project_root, found_root);
    }
    const math_import = try package_resolver.resolve(allocator, root_entry, "パッケージ:math");
    defer allocator.free(math_import.path);
    defer allocator.free(math_import.canonical_id);
    defer allocator.free(math_import.namespace);
    defer if (math_import.package_root) |package_root| allocator.free(package_root);
    const expected_math_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "math", "src", "main.nako3" });
    defer allocator.free(expected_math_path);
    try std.testing.expect(std.mem.endsWith(u8, math_import.path, expected_math_path));
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/main", math_import.canonical_id);
    try std.testing.expectEqualStrings("math", math_import.namespace);
    try std.testing.expectError(error.PackageNotFound, package_resolver.resolve(allocator, root_entry, "pkg:win-math"));
    try std.testing.expectError(error.PackageNotFound, package_resolver.resolve(allocator, math_import.path, "pkg:win-dependency"));
    const owner_name_import = try package_resolver.resolve(allocator, root_entry, "pkg:alice/lib");
    defer allocator.free(owner_name_import.path);
    defer allocator.free(owner_name_import.canonical_id);
    defer allocator.free(owner_name_import.namespace);
    defer if (owner_name_import.package_root) |package_root| allocator.free(package_root);
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/main", owner_name_import.canonical_id);
    try std.testing.expectEqualStrings("alice__lib", owner_name_import.namespace);
    const scoped_owner_import = try package_resolver.resolve(allocator, root_entry, "pkg:@alice/tool");
    defer allocator.free(scoped_owner_import.path);
    defer allocator.free(scoped_owner_import.canonical_id);
    defer allocator.free(scoped_owner_import.namespace);
    defer if (scoped_owner_import.package_root) |package_root| allocator.free(package_root);
    try std.testing.expectEqualStrings("alice__tool", scoped_owner_import.namespace);
    const scoped_subpath_import = try package_resolver.resolve(allocator, root_entry, "pkg:alice/lib/vector");
    defer allocator.free(scoped_subpath_import.path);
    defer allocator.free(scoped_subpath_import.canonical_id);
    defer allocator.free(scoped_subpath_import.namespace);
    defer if (scoped_subpath_import.package_root) |package_root| allocator.free(package_root);
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/vector", scoped_subpath_import.canonical_id);
    try std.testing.expectEqualStrings("alice__lib__vector", scoped_subpath_import.namespace);
    const vector_import = try package_resolver.resolve(allocator, root_entry, "pkg:math/vector");
    defer allocator.free(vector_import.path);
    defer allocator.free(vector_import.canonical_id);
    defer allocator.free(vector_import.namespace);
    defer if (vector_import.package_root) |package_root| allocator.free(package_root);
    const expected_vector_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "math", "vector.nako3" });
    defer allocator.free(expected_vector_path);
    try std.testing.expect(std.mem.endsWith(u8, vector_import.path, expected_vector_path));
    try std.testing.expectEqualStrings("pkg:11111111111111111111111111111111/vector", vector_import.canonical_id);
    try std.testing.expectEqualStrings("math__vector", vector_import.namespace);
    const nested_import = try package_resolver.resolve(allocator, math_import.path, "パッケージ:dep");
    defer allocator.free(nested_import.path);
    defer allocator.free(nested_import.canonical_id);
    defer allocator.free(nested_import.namespace);
    defer if (nested_import.package_root) |package_root| allocator.free(package_root);
    const expected_nested_path = try std.fs.path.join(allocator, &.{ ".nako", "env", "gen-test", "deps", "dependency", "index.nako3" });
    defer allocator.free(expected_nested_path);
    try std.testing.expect(std.mem.endsWith(u8, nested_import.path, expected_nested_path));
    try std.testing.expectEqualStrings("pkg:22222222222222222222222222222222/index", nested_import.canonical_id);
    try std.testing.expectEqualStrings("dep", nested_import.namespace);
    try std.testing.expectError(error.PackageNotFound, package_resolver.resolve(allocator, root_entry, "パッケージ:dep"));
    try std.testing.expectError(error.PackageNotFound, package_resolver.resolve(allocator, root_entry, "パッケージ:math@1.0.0"));
    try std.testing.expectError(error.PackageNotFound, package_resolver.resolve(allocator, root_entry, "パッケージ:math/../private"));
    try std.testing.expectError(error.ExportNotFound, package_resolver.resolve(allocator, root_entry, "パッケージ:math/escape"));
}

test "realpath importerとproject entry優先でancestor package scopeを誤選択しない" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "repo/examples/.nako/env/gen-test/deps/root-util");
    try temporary.dir.createDirPath(io, "repo/parent-util");
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/main.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/parent-util/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/env/gen-test/deps/root-util/index.nako3", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/nako.toml", .data =
        \\[package]
        \\name = "ancestor"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[dependencies.path]
        \\util = { path = "../parent-util" }
        \\[[exports]]
        \\name = "main"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/parent-util/nako.toml", .data =
        \\[package]
        \\name = "parent-util"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/env/gen-test/deps/root-util/nako.toml", .data =
        \\[package]
        \\name = "root-util"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "index"
        \\path = "index.nako3"
        \\
    });
    const lock_json = "{\"schemaVersion\":2,\"resolverVersion\":1,\"input\":{\"manifestSha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"profile\":\"default\",\"features\":[],\"target\":{\"os\":\"macos\",\"cpu\":\"aarch64\",\"abi\":\"none\"}},\"packages\":{\"pkg:ancestor\":{\"id\":\"pkg:ancestor\",\"name\":\"ancestor\",\"version\":\"1.0.0\",\"source\":{\"type\":\"path\",\"path\":\"..\"},\"dependencies\":[\"pkg:parent-util\"]},\"pkg:root-util\":{\"id\":\"pkg:root-util\",\"name\":\"root-util\",\"version\":\"1.0.0\",\"source\":{\"type\":\"registry\",\"url\":\"https://example.invalid/root-util\"},\"dependencies\":[]},\"pkg:parent-util\":{\"id\":\"pkg:parent-util\",\"name\":\"parent-util\",\"version\":\"1.0.0\",\"source\":{\"type\":\"path\",\"path\":\"../parent-util\"},\"dependencies\":[]}},\"rootDependencies\":{\"default\":[\"pkg:root-util\"]}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/nako.lock", .data = lock_json });
    const parent_entry = try temporary.dir.realPathFileAlloc(io, "repo/index.nako3", allocator);
    defer allocator.free(parent_entry);
    temporary.dir.symLink(io, parent_entry, "repo/examples/parent-link.nako3", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_json, &digest, .{});
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":1,\"lockSha256\":\"sha256:{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"dependencies\":[{{\"alias\":\"util\",\"package\":\"pkg:root-util\"}}],\"packages\":{{\"pkg:ancestor\":{{\"id\":\"pkg:ancestor\",\"name\":\"ancestor\",\"version\":\"1.0.0\",\"path\":\"..\",\"exports\":[{{\"name\":\"main\",\"path\":\"index.nako3\"}}],\"dependencies\":[{{\"alias\":\"util\",\"package\":\"pkg:parent-util\"}}]}},\"pkg:root-util\":{{\"id\":\"pkg:root-util\",\"name\":\"root-util\",\"version\":\"1.0.0\",\"path\":\".nako/env/gen-test/deps/root-util\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}],\"dependencies\":[]}},\"pkg:parent-util\":{{\"id\":\"pkg:parent-util\",\"name\":\"parent-util\",\"version\":\"1.0.0\",\"path\":\"../parent-util\",\"exports\":[{{\"name\":\"index\",\"path\":\"index.nako3\"}}],\"dependencies\":[]}}}}}}",
        .{lock_hex},
    );
    defer allocator.free(json);
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/examples/.nako/environment.json", .data = json });
    const project_root = try temporaryDirRealPathAlloc(allocator, io, temporary.dir, "repo/examples");
    defer allocator.free(project_root);
    const root_entry = try temporary.dir.realPathFileAlloc(io, "repo/examples/main.nako3", allocator);
    defer allocator.free(root_entry);
    const symlink_importer = try std.fs.path.join(allocator, &.{ project_root, "parent-link.nako3" });
    defer allocator.free(symlink_importer);

    var package_resolver = try Resolver.load(allocator, io, project_root);
    defer package_resolver.deinit();
    const project_import = try package_resolver.resolve(allocator, root_entry, "pkg:util");
    defer allocator.free(project_import.path);
    defer allocator.free(project_import.canonical_id);
    defer allocator.free(project_import.namespace);
    defer if (project_import.package_root) |package_root| allocator.free(package_root);
    const expected_root_util = try std.fs.path.join(allocator, &.{ "root-util", "index.nako3" });
    defer allocator.free(expected_root_util);
    try std.testing.expect(std.mem.endsWith(u8, project_import.path, expected_root_util));

    const package_import = try package_resolver.resolve(allocator, symlink_importer, "pkg:util");
    defer allocator.free(package_import.path);
    defer allocator.free(package_import.canonical_id);
    defer allocator.free(package_import.namespace);
    defer if (package_import.package_root) |package_root| allocator.free(package_root);
    const expected_parent_util = try std.fs.path.join(allocator, &.{ "parent-util", "index.nako3" });
    defer allocator.free(expected_parent_util);
    try std.testing.expect(std.mem.endsWith(u8, package_import.path, expected_parent_util));
}
