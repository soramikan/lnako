//! プロジェクト CLI（init/add/remove/lock/update/tree/why/check/cache と
//! run/test/build 自動準備）の in-process 統合テスト。実プロセス終了系の
//! 異常路（fail/exit）は対象外で、成功路の状態遷移と入出力分離を検証する。

const std = @import("std");
const testing = std.testing;
const project_cmd = @import("project.zig");
const compiler_pipeline = @import("../../compiler_pipeline.zig");
const test_command = @import("test.zig");

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

    // check は静的で副作用を持たない（環境を構築しない。`.nako` 自体は
    // lock verb が作る `edit.lock` のために既に存在し得る）。
    try cli.run(a, "check", &.{}, app_root);
    const report = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, report, "nako.lock") != null);
    try testing.expect(std.mem.indexOf(u8, report, "fresh") != null);
    try testing.expect(!try dirFileExists(a, app_root, ".nako/environment.json"));
    try testing.expect(!try dirFileExists(a, app_root, ".nako/env"));
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
    try project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);

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
    try project_cmd.prepareForExecution(a, io, outside, &flags, &cli.env, "run", &cli.err.writer);
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
    var sink = std.Io.Writer.Allocating.init(a);
    const rest = try project_cmd.extractPrepFlags(a, &.{
        "--locked",   "--offline",   "--no-sync",   "--profile",  "release",
        "--features", "a,b",         "--dncl",      "main.nako3", "--compat-js",
        "--registry", "https://reg", "--unknown-x",
    }, &flags, "test", &sink.writer);
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

// ---------------------------------------------------------------------------
// レビュー指摘のリグレッションテスト（異常路は CliError で検証する）
// ---------------------------------------------------------------------------

fn expectFail(expected: anyerror, a: std.mem.Allocator, cli: *Cli, verb: []const u8, args: []const []const u8, start_dir: []const u8) !void {
    const result = cli.run(a, verb, args, start_dir);
    try testing.expectError(expected, result);
}

test "init --name の不正なパッケージ名は用法エラーで拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const proj_root = try temporary.dir.realPathFileAlloc(io, ".", a);

    var cli = Cli.init(a);
    try expectFail(error.Usage, a, &cli, "init", &.{ "--name", "evil\"inj" }, proj_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "規則に合いません") != null);
    // 拒否したので manifest は書かれない。
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "nako.toml", .{}));
}

test "init --lib は既存の雛形ファイルを上書きしない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "proj/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "proj/src/lib.nako3", .data = "「既存コード」と表示する。\n" });
    const proj_root = try temporary.dir.realPathFileAlloc(io, "proj", a);

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "init", &.{ "--lib", "--name", "mylib" }, proj_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "既に存在します") != null);
    // ユーザーのファイルは保持される。
    const kept = try readFile(a, proj_root, "src/lib.nako3");
    try testing.expectEqualStrings("「既存コード」と表示する。\n", kept);
    // 事前検査で失敗したため manifest も書かれない。
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "proj/nako.toml", .{}));
}

test "init --lib の雛形はコンパイルできテストも通る" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "proj");
    const proj_root = try temporary.dir.realPathFileAlloc(io, "proj", a);

    var cli = Cli.init(a);
    try cli.run(a, "init", &.{ "--lib", "--name", "samplelib" }, proj_root);

    // <name> が実名で置き換えられていること。
    const lib_src = try readFile(a, proj_root, "src/lib.nako3");
    try testing.expect(std.mem.indexOf(u8, lib_src, "<name>") == null);
    try testing.expect(std.mem.indexOf(u8, lib_src, "samplelib") != null);

    // examples/main.nako3 がそのままコンパイルできること。
    const example = try std.fs.path.join(a, &.{ proj_root, "examples", "main.nako3" });
    var compile_err: std.Io.Writer.Allocating = .init(a);
    const program = try compiler_pipeline.compileInput(a, io, example, .{}, &compile_err.writer);
    try testing.expect(program != null);

    // tests/lib_test.nako3 がそのまま実行・成功すること。
    const test_file = try std.fs.path.join(a, &.{ proj_root, "tests", "lib_test.nako3" });
    var test_out: std.Io.Writer.Allocating = .init(a);
    var test_err: std.Io.Writer.Allocating = .init(a);
    const ok = try test_command.runTestTarget(a, io, test_file, .{}, &test_out.writer, &test_err.writer);
    try testing.expect(ok);
}

test "add --npm は未対応として拒否し manifest を変更しない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "add", &.{ "escape", "--npm" }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "npm") != null);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "escape") != null);
    const manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "escape") == null);
}

test "manifest の npm 依存宣言は lock 時に診断付きで拒否される" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "lock", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "escape") != null);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "npm") != null);
    // 不完全な lock は残さない。
    try testing.expect(!try dirFileExists(a, app_root, "nako.lock"));
}

test "add --locked と remove --locked と update --locked は用法エラー" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try expectFail(error.Usage, a, &cli, "add", &.{ "lib", "--path", "lib", "--locked" }, app_root);
    try expectFail(error.Usage, a, &cli, "remove", &.{ "lib", "--locked" }, app_root);
    try expectFail(error.Usage, a, &cli, "update", &.{"--locked"}, app_root);
}

test "add --git は --commit 必須、add --http は --hash 必須" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try expectFail(error.Usage, a, &cli, "add", &.{ "lib", "--git", "https://example.com/x.git" }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "--commit") != null);
    var cli2 = Cli.init(a);
    try expectFail(error.Usage, a, &cli2, "add", &.{ "lib", "--http", "https://example.com/x.tgz" }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli2.err.written(), "--hash") != null);
}

test "add は依存名を検証し重複を報告する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try expectFail(error.Usage, a, &cli, "add", &.{ "Bad_Name", "--path", "lib" }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "規則に合いません") != null);

    var cli2 = Cli.init(a);
    try cli2.run(a, "add", &.{ "lib", "--path", "lib" }, app_root);
    var cli3 = Cli.init(a);
    try expectFail(error.Failed, a, &cli3, "add", &.{ "lib", "--path", "lib" }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli3.err.written(), "既に") != null);
}

test "add の bare 名は table 形式の候補を生成し解決段階まで進む" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    // registry が無いので解決は失敗するが、「生成した manifest が不正」
    // ではなく registry 必須エラーであること（候補 manifest が有効だった証左）。
    try expectFail(error.Failed, a, &cli, "add", &.{"somepkg"}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "生成した manifest が不正") == null);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "registry") != null);
    // 失敗時は manifest が復元される。
    const manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "somepkg") == null);
}

test "update は dep key を解決済み id へ写像して再解決する" {
    // source 依存の lock entry id は `pkg:<32hex>` で dep key と別名
    // 空間。dep key 指定を解決済み id へ正規化しないと、対象固有の
    // 更新（宣言変更許容・pin 解除）が効かない。
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
    // dep key 指定の update が受理される（id 写像済み）。
    try cli.run(a, "update", &.{"lib"}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "update:") != null);
}

test "update は未宣言の依存名を拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "update", &.{"no-such-dep"}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "依存にありません") != null);
}

test "extractPrepFlags は値取りこぼしを用法エラーにする" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var flags = project_cmd.PrepFlags{};
    var sink: std.Io.Writer.Allocating = .init(a);
    // `--profile` の値として `--dncl` を消費しない。
    try testing.expectError(error.Usage, project_cmd.extractPrepFlags(a, &.{ "--profile", "--dncl", "main.nako3" }, &flags, "run", &sink.writer));
    // 末尾で値が切れても用法エラー。
    try testing.expectError(error.Usage, project_cmd.extractPrepFlags(a, &.{ "main.nako3", "--features" }, &flags, "run", &sink.writer));
}

test "prepareForExecution は --locked --no-sync でも lock 検証する" {
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
    var flags = project_cmd.PrepFlags{ .locked = true, .no_sync = true };
    // nako.lock が無い状態で --locked --no-sync: no_sync より先に
    // verifyLocked が走り LockedNotSatisfied で失敗する。
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer));
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "nako.lock") != null);
}

test "prepareForExecution --no-sync は消えた生成環境を検出する" {
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
    try project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);

    // generation ディレクトリを消しても environment.json と current は残る。
    const current_text = try readFile(a, app_root, ".nako/current");
    const generation = std.mem.trim(u8, current_text, " \r\n\t");
    const env_path = try std.fs.path.join(a, &.{ ".nako", "env", generation });
    var app_dir = try std.Io.Dir.cwd().openDir(io, app_root, .{});
    defer app_dir.close(io);
    try app_dir.deleteTree(io, env_path);

    // メタデータだけを信じず、実在しない generation を検出して失敗する。
    var cli2 = Cli.init(a);
    flags = .{ .no_sync = true };
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, &cli2.env, "run", &cli2.err.writer));
    try testing.expect(std.mem.indexOf(u8, cli2.err.written(), ".nako 環境") != null);
}

test "tree と why は lock を書き換えず不足時は案内して失敗する" {
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

    // lock が無い状態で tree/why は失敗し、nako.lock を生成しない。
    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "tree", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "lnako lock") != null);
    var cli2 = Cli.init(a);
    try expectFail(error.Failed, a, &cli2, "why", &.{"lib"}, app_root);
    try testing.expect(!try dirFileExists(a, app_root, "nako.lock"));

    // lock 生成後は tree/why が読み取り専用で表示する。
    var cli3 = Cli.init(a);
    try cli3.run(a, "lock", &.{}, app_root);
    const lock_bytes = try readFile(a, app_root, "nako.lock");
    var cli4 = Cli.init(a);
    try cli4.run(a, "tree", &.{}, app_root);
    const lock_after = try readFile(a, app_root, "nako.lock");
    try testing.expectEqualStrings(lock_bytes, lock_after);

    // manifest を変更して lock を陳腐化させると tree は stale で失敗する。
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib", mutable = true }
        \\
    );
    var cli5 = Cli.init(a);
    try expectFail(error.Failed, a, &cli5, "tree", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, cli5.err.written(), "lnako lock") != null);
}

test "path 依存の循環は lock 生成時点で cycle として診断される" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // A↔B の path 依存循環は lock 生成時点で E004 で失敗する。
    try temporary.dir.createDirPath(io, "app/a/src");
    try writeLibPackage(a, temporary.dir, "app/a", "a");
    try temporary.dir.createDirPath(io, "app/b/src");
    try writeLibPackage(a, temporary.dir, "app/b", "b");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/a/nako.toml", .data =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\b = { path = "../b" }
        \\
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/b/nako.toml", .data =
        \\[package]
        \\name = "b"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\a = { path = "../a" }
        \\
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\a = { path = "a" }
        \\
    );

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "lock", &.{}, app_root);
    const err_text = cli.err.written();
    try testing.expect(std.mem.indexOf(u8, err_text, "E004") != null or
        std.mem.indexOf(u8, err_text, "cycle") != null or
        std.mem.indexOf(u8, err_text, "循環") != null);
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

test "各コマンドは意味を持たないフラグを用法エラーで拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    const Case = struct { verb: []const u8, args: []const []const u8 };
    const cases = [_]Case{
        // lock は環境を構築しないため --no-sync は不活性。
        .{ .verb = "lock", .args = &.{"--no-sync"} },
        // tree/why は読み取り専用。json/no-sync/取得系フラグは不活性。
        .{ .verb = "tree", .args = &.{"--json"} },
        .{ .verb = "tree", .args = &.{"--no-sync"} },
        .{ .verb = "tree", .args = &.{"--offline"} },
        .{ .verb = "why", .args = &.{ "lib", "--json" } },
        .{ .verb = "why", .args = &.{ "lib", "--no-sync" } },
        // update に json/no-sync は無い。
        .{ .verb = "update", .args = &.{"--json"} },
        .{ .verb = "update", .args = &.{"--no-sync"} },
        // check は副作用なし。環境構築・取得系フラグは不活性。
        .{ .verb = "check", .args = &.{"--no-sync"} },
        .{ .verb = "check", .args = &.{"--offline"} },
        .{ .verb = "check", .args = &.{ "--registry", "https://example.com" } },
        // add/remove も同様。
        .{ .verb = "add", .args = &.{ "lib", "--path", "lib", "--json" } },
        .{ .verb = "add", .args = &.{ "lib", "--path", "lib", "--no-sync" } },
        .{ .verb = "remove", .args = &.{ "lib", "--json" } },
        .{ .verb = "remove", .args = &.{ "lib", "--no-sync" } },
    };
    for (cases) |case| {
        var cli = Cli.init(a);
        try expectFail(error.Usage, a, &cli, case.verb, case.args, app_root);
    }
}

test "check --locked は陳腐な lock を拒否し --locked 無しでは検査結果を返す" {
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

    var lock_cli = Cli.init(a);
    try lock_cli.run(a, "lock", &.{}, app_root);

    // manifest を変更して lock を陳腐化させる。
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib", mutable = true }
        \\
    );

    // --locked 無しの check は失敗せず stale と必要操作を報告する。
    // lock が陳腐なら環境も再構築が必要なため `lnako lock` に加えて
    // `lnako sync` も案内する。
    var plain = Cli.init(a);
    try plain.run(a, "check", &.{"--json"}, app_root);
    try testing.expect(std.mem.indexOf(u8, plain.out.written(), "stale") != null);
    try testing.expect(std.mem.indexOf(u8, plain.out.written(), "lnako lock") != null);
    try testing.expect(std.mem.indexOf(u8, plain.out.written(), "lnako sync") != null);

    // --locked 付きは verifyLocked が陳腐を拒否する。
    var locked = Cli.init(a);
    try expectFail(error.Failed, a, &locked, "check", &.{"--locked"}, app_root);
}

test "add は競合する source フラグと kind に合わないオプションを拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);

    const cases = [_][]const []const u8{
        // source kind フラグは排他。
        &.{ "lib", "--path", "lib", "--git", "https://example.com/x.git" },
        &.{ "lib", "--git", "https://example.com/x.git", "--http", "https://example.com/x.tgz" },
        &.{ "lib", "--path", "lib", "--npm" },
        &.{ "lib", "--path", "lib", "--path", "other" },
        // kind 固有オプションの混在は黙って捨てず拒否する。
        &.{ "lib", "--commit", "abcdef0" },
        &.{ "lib", "--dep-path", "sub" },
        &.{ "lib", "--hash", "sha256:00" },
        &.{ "lib", "--mutable" },
        &.{ "lib", "--path", "lib", "--commit", "abcdef0" },
        &.{ "lib", "--path", "lib", "--dep-path", "sub" },
        &.{ "lib", "--git", "https://example.com/x.git", "--commit", "abcdef0", "--hash", "sha256:00" },
    };
    for (cases) |args| {
        var cli = Cli.init(a);
        try expectFail(error.Usage, a, &cli, "add", args, app_root);
        // 用法エラーは manifest を変更しない。
        const manifest = try readFile(a, app_root, "nako.toml");
        try testing.expect(std.mem.indexOf(u8, manifest, "[dependencies") == null);
    }
}

test "remove はコメント内の開き brace で文を延長せず後続宣言を保持する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    // 行末コメント内の `{` を文の開き brace と誤計上すると、除去範囲が
    // 次行の `other` 宣言まで延びて消し込む（または EOF まで延びる）。
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib" } # { はコメント内の brace
        \\other = { path = "lib" }
        \\
    );

    var cli = Cli.init(a);
    try cli.run(a, "remove", &.{"lib"}, app_root);
    const manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "lib = {") == null);
    // 無関係な `other` 宣言は残り、manifest は再 parse 可能（remove が
    // candidate を再検証して成功した証左）。
    try testing.expect(std.mem.indexOf(u8, manifest, "other = { path = \"lib\" }") != null);
}

test "remove は引用符3連を含む行で文終端を誤らない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    // 単一引用が3連すると multiline literal の開始になる。`'` 単独の
    // on/off 追跡では3個目以降が文字列内扱いになり、文が閉じず末尾まで
    // 除去範囲が延びる。dep 値として合法な形にするため git 依存の
    // alias 文字列で検証する。
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib = { path = "lib" } # ''' は literal ではなくコメント
        \\other = { path = "lib" }
        \\
    );

    var cli = Cli.init(a);
    try cli.run(a, "remove", &.{"lib"}, app_root);
    const manifest = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, manifest, "lib = {") == null);
    try testing.expect(std.mem.indexOf(u8, manifest, "other = { path = \"lib\" }") != null);
}

test "why は解決済みの public id でも直接宣言を特定する" {
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
    // lock から解決済み entry の public id（`pkg:<32hex>`）を取り出す。
    const lock_text = try readFile(a, app_root, "nako.lock");
    const needle = "\"id\": \"pkg:";
    const at = std.mem.indexOf(u8, lock_text, needle) orelse return error.TestExpectedEqual;
    const id_start = at + needle.len - 4; // "pkg:" から始める
    const id_end = std.mem.indexOfScalarPos(u8, lock_text, id_start, '"') orelse return error.TestExpectedEqual;
    const public_id = lock_text[id_start..id_end];

    // `why pkg:<id>` は宣言 source 由来の id と一致するため
    // 「解決グラフに含まれます」ではなく直接宣言として報告する。
    try cli.run(a, "why", &.{public_id}, app_root);
    const why = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, why, "直接宣言") != null);
    try testing.expect(std.mem.indexOf(u8, why, "dep key: lib") != null);
}

test "depKeyIdMapはpublic-id宣言を同名entryの先頭一致より優先する" {
    // 同名 package が複数解決された lock では name 照合の先頭一致が
    // 誤った entry を返す。`public-id` 宣言は解決済み ID で直接照合する。
    const a = testing.allocator;
    const lnako = @import("lnako");
    const diag = lnako.package.diagnostics;
    const manifest_mod = lnako.package.manifest;
    const lock_model = lnako.package.lock;
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(a,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\dup = { version = "1.0.0", public-id = "pkg:22222222222222222222222222222222" }
        \\plain = { version = "1.0.0" }
        \\
    , &diagnostics);
    defer manifest.deinit();
    const packages = [_]lock_model.PackageEntry{
        .{ .id = "pkg:11111111111111111111111111111111", .name = "dup", .version = "1.0.0" },
        .{ .id = "pkg:22222222222222222222222222222222", .name = "dup", .version = "2.0.0" },
        .{ .id = "pkg:33333333333333333333333333333333", .name = "plain", .version = "1.0.0" },
    };
    var maps = try project_cmd.depKeyIdMap(a, &manifest, "/nonexistent", &packages);
    defer maps.deinit();
    // `public-id` 宣言は同名先頭 entry（pkg:111）ではなく指定 ID へ写像。
    try testing.expectEqualStrings("pkg:22222222222222222222222222222222", maps.by_name.get("dup").?);
    try testing.expectEqualStrings("dup", maps.by_id.get("pkg:22222222222222222222222222222222").?);
    // `public-id` 未指定は従来どおり name 照合で写像する。
    try testing.expectEqualStrings("pkg:33333333333333333333333333333333", maps.by_name.get("plain").?);
}
