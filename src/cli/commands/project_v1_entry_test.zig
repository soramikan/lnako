//! 通常 CLI 入口の v1 閉鎖を確認する。
//!
//! `init` は v1 のローカル manifest を生成し、旧 manifest / 旧 lock 専用の
//! `add`/`remove`/`lock`/`update`/`tree`/`why`/`check` は v1 プロジェクトを
//! 旧 loader へ渡さない。旧 `nako.lock` / `.nako/environment.json` の再利用・
//! 書換えが起きないことを、実データのバイト列で確認する。

const std = @import("std");
const testing = std.testing;
const lnako = @import("lnako");
const project_cmd = @import("project.zig");

const io = std.testing.io;

const old_manifest = "[package]\nname = \"legacy\"\nversion = \"1.0.0\"\nlicense = \"MIT\"\n";
const old_lock = "{\"schemaVersion\":2,\"packages\":{}}";
const old_environment = "{\"schemaVersion\":1,\"profile\":\"default\"}";

fn readFile(a: std.mem.Allocator, root: []const u8, sub: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, sub });
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

fn writeOldData(dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.lock", .data = old_lock });
    try dir.createDirPath(io, ".nako");
    try dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = old_environment });
}

fn writeV1Project(dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.toml", .data = "schema_version = 1\n[package]\n" });
    try writeOldData(dir);
}

fn writeLegacyProject(dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.toml", .data = old_manifest });
    try dir.writeFile(io, .{ .sub_path = "nako.lock", .data = old_lock });
}

fn expectFileMissing(dir: std.Io.Dir, sub: []const u8) !void {
    dir.access(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

fn runVerb(a: std.mem.Allocator, verb: []const u8, args: []const []const u8, root: []const u8) !struct {
    err: std.Io.Writer.Allocating,
} {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    // runIn はエラー時に書きかけの writer を保持する。out はテスト中に
    // 参照しないため、ここで解放しない（arena が回収する）。
    try testing.expectError(error.Failed, project_cmd.runIn(a, io, verb, args, root, null, &out.writer, &err.writer));
    return .{ .err = err };
}

test "init は v1 ローカル manifest を生成し旧 name/version を書かない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj");
    const root = try tmp.dir.realPathFileAlloc(io, "proj", a);

    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try project_cmd.runIn(a, io, "init", &.{ "--name", "sample" }, root, null, &out.writer, &err.writer);

    const text = try readFile(a, root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, text, "schema_version = 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[package]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "name =") == null);
    try testing.expect(std.mem.indexOf(u8, text, "[[exports]]") == null);

    // 生成物は v1 のローカル manifest としてそのまま読める。
    var manifest = try lnako.package.v1_manifest.parse(a, text, .local);
    defer manifest.deinit();
    try testing.expectEqual(@as(usize, 0), manifest.exports.len);
    // 旧 lock / 旧環境を init が作らない。
    try expectFileMissing(tmp.dir, "proj/nako.lock");
    try expectFileMissing(tmp.dir, "proj/.nako");

    // --lib は v1 の exports 形式だけを生成する。
    try tmp.dir.createDirPath(io, "lib");
    const lib_root = try tmp.dir.realPathFileAlloc(io, "lib", a);
    var lib_out: std.Io.Writer.Allocating = .init(a);
    var lib_err: std.Io.Writer.Allocating = .init(a);
    try project_cmd.runIn(a, io, "init", &.{ "--lib", "--name", "samplelib" }, lib_root, null, &lib_out.writer, &lib_err.writer);
    const lib_text = try readFile(a, lib_root, "nako.toml");
    var lib_manifest = try lnako.package.v1_manifest.parse(a, lib_text, .local);
    defer lib_manifest.deinit();
    const dot = lib_manifest.findExport(".") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("src/lib.nako3", dot.entry);
    try testing.expect(dot.binding == .scoped);
}

test "v1 では add/remove/lock/update/tree/why/check が旧 manifest/lock を読み書きしない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const cases = [_]struct { verb: []const u8, args: []const []const u8 }{
        .{ .verb = "add", .args = &.{ "lib", "--path", "lib" } },
        .{ .verb = "remove", .args = &.{"lib"} },
        .{ .verb = "lock", .args = &.{} },
        .{ .verb = "update", .args = &.{} },
        .{ .verb = "tree", .args = &.{} },
        .{ .verb = "why", .args = &.{"lib"} },
        .{ .verb = "check", .args = &.{} },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeV1Project(tmp.dir);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);

        var result = try runVerb(a, case.verb, case.args, root);
        // 旧 loader のエラーではなく、v1 の代替を示して拒否する。
        try testing.expect(std.mem.indexOf(u8, result.err.written(), "v1 プロジェクト") != null);
        try testing.expect(std.mem.indexOf(u8, result.err.written(), "--v1-fixture") != null);

        const manifest_after = try readFile(a, root, "nako.toml");
        try testing.expectEqualStrings("schema_version = 1\n[package]\n", manifest_after);
        // 旧 lock / 旧環境は再利用も書換えもしない。
        try testing.expectEqualStrings(old_lock, try readFile(a, root, "nako.lock"));
        try testing.expectEqualStrings(old_environment, try readFile(a, root, ".nako/environment.json"));
        // 新しい v1 環境も計画（edit.lock）も作らない（拒否しただけ）。
        try expectFileMissing(tmp.dir, ".nako/v1");
        try expectFileMissing(tmp.dir, ".nako/edit.lock");
    }
}

test "旧 manifest/lock の公開 CLI は旧 loader へ渡さずバイト列と計画を変えない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const cases = [_]struct { verb: []const u8, args: []const []const u8 }{
        .{ .verb = "add", .args = &.{ "lib", "--path", "lib" } },
        .{ .verb = "remove", .args = &.{"lib"} },
        .{ .verb = "lock", .args = &.{} },
        .{ .verb = "update", .args = &.{} },
        .{ .verb = "tree", .args = &.{} },
        .{ .verb = "why", .args = &.{"lib"} },
        .{ .verb = "check", .args = &.{} },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeLegacyProject(tmp.dir);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);

        var result = try runVerb(a, case.verb, case.args, root);
        // 旧 loader の成功・失敗ではなく、v1 への再作成を案内して拒否する。
        try testing.expect(std.mem.indexOf(u8, result.err.written(), "旧形式") != null);
        try testing.expect(std.mem.indexOf(u8, result.err.written(), "再作成") != null);

        // 旧 manifest と旧 lock は元のバイト列のまま。旧 loader による
        // 再解決・計画（.nako/edit.lock 等）の書込みもしない。
        try testing.expectEqualStrings(old_manifest, try readFile(a, root, "nako.toml"));
        try testing.expectEqualStrings(old_lock, try readFile(a, root, "nako.lock"));
        try expectFileMissing(tmp.dir, ".nako");
    }
}

test "旧 manifest に lock が無くても公開 CLI は lock を計画しない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = old_manifest });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    var result = try runVerb(a, "lock", &.{}, root);
    try testing.expect(std.mem.indexOf(u8, result.err.written(), "旧形式") != null);
    try testing.expectEqualStrings(old_manifest, try readFile(a, root, "nako.toml"));
    // 旧形式を解決せず、nako.lock も .nako 配下の計画も作らない。
    try expectFileMissing(tmp.dir, "nako.lock");
    try expectFileMissing(tmp.dir, ".nako");
}
