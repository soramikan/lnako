//! プロジェクト CLI（init/add/remove/lock/update/tree/why/check/cache と
//! run/test/build 自動準備）の in-process 統合テスト。実プロセス終了系の
//! 異常路（fail/exit）は対象外で、成功路の状態遷移と入出力分離を検証する。

const std = @import("std");
const testing = std.testing;
const project_cmd = @import("project.zig");

const io = std.testing.io;

fn writeLibPackage(a: std.mem.Allocator, dir: std.Io.Dir, root: []const u8, name: []const u8) !void {
    const manifest_path = try std.fs.path.join(a, &.{ root, "nako.toml" });
    const source = try std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "{s}"
        \\path = "src/index.nako3"
        \\
    , .{ name, name });
    try dir.writeFile(io, .{ .sub_path = manifest_path, .data = source });
    const index_path = try std.fs.path.join(a, &.{ root, "src", "index.nako3" });
    try dir.writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\nここまで\n" });
}

/// `app/lib` の path 依存パッケージと `app/nako.toml` を持つ fixture。
/// 戻り値は `app` の絶対パス。
fn newAppFixture(a: std.mem.Allocator, temporary: *std.testing.TmpDir) ![]const u8 {
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(a, temporary.dir, "app/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        ,
    });
    return temporary.dir.realPathFileAlloc(io, "app", a);
}

fn appManifest(a: std.mem.Allocator, app_root: []const u8, deps: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ app_root, "nako.toml" });
    const source = try std.fmt.allocPrint(a,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\{s}
        \\
    , .{deps});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source });
}

fn dirFileExists(a: std.mem.Allocator, root: []const u8, sub: []const u8) !bool {
    const path = try std.fs.path.join(a, &.{ root, sub });
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readFile(a: std.mem.Allocator, root: []const u8, sub: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, sub });
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
}

const Cli = struct {
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    env: std.process.Environ.Map,

    fn init(a: std.mem.Allocator) Cli {
        return .{
            .out = .init(a),
            .err = .init(a),
            .env = std.process.Environ.Map.init(a),
        };
    }

    fn run(self: *Cli, a: std.mem.Allocator, verb: []const u8, args: []const []const u8, start_dir: []const u8) !void {
        try project_cmd.runIn(a, io, verb, args, start_dir, &self.env, &self.out.writer, &self.err.writer);
    }
};

test "init は nako.toml を生成し --lib は exports とソース雛形を作る" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "proj");
    const proj_root = try temporary.dir.realPathFileAlloc(io, "proj", a);

    var cli = Cli.init(a);
    try cli.run(a, "init", &.{ "--name", "myapp" }, proj_root);
    const manifest = try readFile(a, proj_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "[package]") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "name = \"myapp\"") != null);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "init:") != null);

    // --lib は exports・src/lib.nako3・examples・tests を生成する。
    try temporary.dir.createDirPath(io, "mylib");
    const lib_root = try temporary.dir.realPathFileAlloc(io, "mylib", a);
    var cli2 = Cli.init(a);
    try cli2.run(a, "init", &.{ "--lib", "--name", "mylib" }, lib_root);
    const lib_manifest = try readFile(a, lib_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, lib_manifest, "[[exports]]") != null);
    try testing.expect(try dirFileExists(a, lib_root, "src/lib.nako3"));
    try testing.expect(try dirFileExists(a, lib_root, "examples/main.nako3"));
    try testing.expect(try dirFileExists(a, lib_root, "tests/lib_test.nako3"));
}

test "add は manifest に依存を追記し lock まで更新する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try cli.run(a, "add", &.{ "lib", "--path", "lib" }, app_root);

    const manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "[dependencies.path]") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "lib = { path = \"lib\" }") != null);
    // lock まで進む（add の副作用契約）。
    try testing.expect(try dirFileExists(a, app_root, "nako.lock"));

    // remove は宣言を消して lock を再生成する。
    try cli.run(a, "remove", &.{"lib"}, app_root);
    const removed_manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, removed_manifest, "lib = { path") == null);
}

test "lock は nako.lock を生成し tree/why/check が参照できる" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
    );

    var cli = Cli.init(a);
    try cli.run(a, "lock", &.{}, app_root);
    try testing.expect(try dirFileExists(a, app_root, "nako.lock"));

    // --json は stdout だけに JSON を書く（診断は stderr）。
    try cli.run(a, "lock", &.{"--json"}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.out.written(), "\"profile\":\"default\"") != null);

    try cli.run(a, "tree", &.{}, app_root);
    const tree = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, tree, "app") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "lib") != null);

    try cli.run(a, "why", &.{"lib"}, app_root);
    const why = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, why, "lib") != null);
    try testing.expect(std.mem.indexOf(u8, why, "直接宣言") != null);

    // check は静的で副作用を持たない（.nako を作らない）。
    try cli.run(a, "check", &.{}, app_root);
    const report = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, report, "nako.lock") != null);
    try testing.expect(std.mem.indexOf(u8, report, "fresh") != null);
    try testing.expect(!try dirFileExists(a, app_root, ".nako"));
}

test "check --json は機械可読な検査結果を stdout へ出す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try cli.run(a, "check", &.{"--json"}, app_root);
    const out = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"manifest\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"lock\":\"missing\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "lnako lock") != null);
    try testing.expect(!try dirFileExists(a, app_root, ".nako"));
    try testing.expect(!try dirFileExists(a, app_root, "nako.lock"));
}

test "prepareForExecution は lock と .nako 環境を自動準備する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
    );
    const main_path = try std.fs.path.join(a, &.{ app_root, "main.nako3" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = "「ok」を表示\n" });

    var cli = Cli.init(a);
    var flags = project_cmd.PrepFlags{};
    project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);

    try testing.expect(try dirFileExists(a, app_root, "nako.lock"));
    try testing.expect(try dirFileExists(a, app_root, ".nako/environment.json"));
}

test "prepareForExecution はプロジェクト外では何もしない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const outside = try std.fs.path.join(a, &.{ root, "main.nako3" });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "「ok」を表示\n" });

    var cli = Cli.init(a);
    var flags = project_cmd.PrepFlags{};
    project_cmd.prepareForExecution(a, io, outside, &flags, &cli.env, "run", &cli.err.writer);
    temporary.dir.access(io, "nako.lock", .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedEqual;
}

test "extractPrepFlags は prep フラグを分離し残りを保持する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var flags = project_cmd.PrepFlags{};
    const rest = try project_cmd.extractPrepFlags(a, &.{
        "--locked",   "--offline",   "--no-sync",   "--profile",  "release",
        "--features", "a,b",         "--dncl",      "main.nako3", "--compat-js",
        "--registry", "https://reg", "--unknown-x",
    }, &flags);
    try testing.expect(flags.locked);
    try testing.expect(flags.offline);
    try testing.expect(flags.no_sync);
    try testing.expectEqualStrings("release", flags.profile.?);
    try testing.expectEqualStrings("https://reg", flags.registry.?);
    try testing.expectEqual(@as(usize, 2), flags.features.items.len);
    // dncl・位置引数・未知オプションは残りへ保持される。
    try testing.expectEqual(@as(usize, 4), rest.len);
    try testing.expectEqualStrings("--dncl", rest[0]);
    try testing.expectEqualStrings("main.nako3", rest[1]);
    try testing.expectEqualStrings("--compat-js", rest[2]);
    try testing.expectEqualStrings("--unknown-x", rest[3]);
}

test "cache dir はキャッシュルートを出力する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var cli = Cli.init(a);
    try project_cmd.runIn(a, io, "cache", &.{"dir"}, ".", &cli.env, &cli.out.writer, &cli.err.writer);
    const out = cli.out.written();
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOf(u8, out, "\n") != null);
}
