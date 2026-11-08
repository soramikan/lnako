//! プロジェクト CLI（init/add/remove/lock/update/tree/why/check/cache と
//! run/test/build 自動準備）の in-process 統合テスト。実プロセス終了系の
//! 異常路（fail/exit）は対象外で、成功路の状態遷移と入出力分離を検証する。

const std = @import("std");
const builtin = @import("builtin");
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

/// 任意の命令を 1 つ公開する path 依存パッケージを書く。
/// 標準命令と衝突しない名前を呼出し側が渡す。
fn writePathPackage(a: std.mem.Allocator, dir: std.Io.Dir, root: []const u8, name: []const u8, command: []const u8) !void {
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
    const body = try std.fmt.allocPrint(a, "●{s}とは\nここまで\n", .{command});
    try dir.writeFile(io, .{ .sub_path = index_path, .data = body });
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

test "check は選択 feature の専用依存と推移依存を JSON と本文に出す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib-common/src");
    try writePathPackage(a, temporary.dir, "app/lib-common", "lib-common", "共通専用");
    try temporary.dir.createDirPath(io, "app/lib-extra/src");
    try writePathPackage(a, temporary.dir, "app/lib-extra", "lib-extra", "追加専用");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\common = { path = "lib-common" }
        \\extra = { path = "lib-extra" }
        \\
        \\[features]
        \\default = ["common"]
        \\with-extra = ["extra"]
        \\
    );

    var cli = Cli.init(a);
    // `sync` は cli.zig 側の verb なので、ここでは run 準備経路で
    // feature 選択込みの環境を作る。
    const main_path = try std.fs.path.join(a, &.{ app_root, "main.nako3" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = "「ok」を表示\n" });
    var flags = project_cmd.PrepFlags{};
    try flags.features.append(a, "with-extra");
    try project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);

    try cli.run(a, "check", &.{ "--json", "--features", "with-extra" }, app_root);
    const json = cli.out.written();
    // default が有効化する common は共通、with-extra 専用の extra は専用。
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"features\":{\"selected\":[\"default\",\"with-extra\"],\"common\":[\"common\"],\"dedicated\":[{\"feature\":\"with-extra\",\"roots\":[\"extra\"],\"packages\":[]}]}",
    ) != null);

    try cli.run(a, "check", &.{ "--features", "with-extra" }, app_root);
    const text = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, text, "feature 影響: 選択=[default, with-extra]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "共通依存: common") != null);
    try testing.expect(std.mem.indexOf(u8, text, "専用依存: with-extra → extra") != null);

    // 環境は with-extra 選択で作られているため、別の選択で check すると
    // lock は stale（再 sync が必要）になる。前回選択の graph を現行選択の
    // 結果として見せないよう、feature 影響は出さない。
    var stale_cli = Cli.init(a);
    try stale_cli.run(a, "check", &.{ "--json", "--no-default-features" }, app_root);
    const stale_json = stale_cli.out.written();
    try testing.expect(std.mem.indexOf(u8, stale_json, "\"lock\":\"stale\"") != null);
    try testing.expect(std.mem.indexOf(u8, stale_json, "\"features\":") == null);
}

test "check は package 宣言命令の OS 条件と名前空間 alias 件数を本文と JSON へ出す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib-native/src");
    try temporary.dir.createDirPath(io, "app/lib-native/lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/lib-native/nako.toml",
        .data =
        \\[package]
        \\name = "lib-native"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "lib-native"
        \\path = "src/index.nako3"
        \\native = { path = "lib/any.dll", when = "os == 'macos' or os == 'linux' or os == 'windows'" }
        \\
        ,
    });
    // 標準命令と衝突しない公開名にする（`表示` は builtin）。
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lib-native/src/index.nako3", .data = "●あいさつとは\nここまで\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lib-native/lib/any.dll", .data = "not-a-real-library" });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    try appManifest(a, app_root,
        \\[dependencies.path]
        \\lib-native = { path = "lib-native" }
        \\
    );
    const main_path = try std.fs.path.join(a, &.{ app_root, "main.nako3" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = "「ok」を表示\n" });

    var cli = Cli.init(a);
    var flags = project_cmd.PrepFlags{};
    try project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);

    const expected_condition = "全 OS | os == 'macos' or os == 'linux' or os == 'windows'";
    try cli.run(a, "check", &.{"--json"}, app_root);
    const json = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"conditions\":[{\"package\":\"pkg:") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"condition\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, expected_condition) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"availability\":\"available\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"namespaces\":{\"aliases\":1,\"scan\":\"complete\",\"issues\":[]}") != null);

    try cli.run(a, "check", &.{}, app_root);
    const text = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, text, "命令 OS 条件: 対象 OS=") != null);
    try testing.expect(std.mem.indexOf(u8, text, expected_condition) != null);
    try testing.expect(std.mem.indexOf(u8, text, "利用可能") != null);
    try testing.expect(std.mem.indexOf(u8, text, "名前空間: alias 1 件（問題 0 件）") != null);
}

test "check --json は名前空間aliasのerrorでもJSONを出して失敗する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writePathPackage(a, temporary.dir, "app/lib", "lib", "あいさつ");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
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

    // root scope に正規化後空になる alias を足す（env の形状は保ったまま）。
    const env_path = try std.fs.path.join(a, &.{ app_root, ".nako/environment.json" });
    const env_bytes = try std.Io.Dir.cwd().readFileAlloc(io, env_path, a, .limited(4 * 1024 * 1024));
    defer a.free(env_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, env_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const package_key = parsed.value.object.get("dependencies").?.array.items[0].object.get("package").?.string;
    // 既存 dependencies の先頭へ空 alias を差し込む（env shape は有効なまま）。
    const needle = "\"dependencies\":[{";
    const position = std.mem.indexOf(u8, env_bytes, needle) orelse return error.TestUnexpectedResult;
    const replacement = try std.fmt.allocPrint(
        a,
        "\"dependencies\":[{{\"alias\":\"@\",\"package\":\"{s}\"}}, {{",
        .{package_key},
    );
    defer a.free(replacement);
    // 先頭の root dependencies だけを置換する（package scope の dependencies
    // を巻き込まない）。
    const replaced = try std.fmt.allocPrint(
        a,
        "{s}{s}{s}",
        .{ env_bytes[0..position], replacement, env_bytes[position + needle.len ..] },
    );
    defer a.free(replaced);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = env_path, .data = replaced });

    try testing.expectError(error.Failed, cli.run(a, "check", &.{"--json"}, app_root));
    const out = cli.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"namespaces\":{\"aliases\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"scope\":\"root\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"empty\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"severity\":\"error\"") != null);
    const err = cli.err.written();
    try testing.expect(std.mem.indexOf(u8, err, "E029") != null);
    try testing.expect(std.mem.indexOf(u8, err, "namespace alias") != null);
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

test "prepareForExecution は compat_js を lock input target へ記録する" {
    // `run`/`build --compat-js` は ESM 実装を許容するため、解決結果が
    // 非 compat 実行と異なり得る。lock input の `target.compatJs` に
    // 記録して compat 切替を鮮度で検出する。
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

    const lockCompat = struct {
        fn run(aa: std.mem.Allocator, root: []const u8) !?bool {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(aa, &.{ root, "nako.lock" }), aa, .limited(4 * 1024 * 1024));
            var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
            defer parsed.deinit();
            const input = parsed.value.object.get("input") orelse return null;
            const target = input.object.get("target") orelse return null;
            const compat = target.object.get("compatJs") orelse return false;
            return compat == .bool and compat.bool;
        }
    }.run;

    var cli = Cli.init(a);
    var flags = project_cmd.PrepFlags{ .compat_js = true };
    try project_cmd.prepareForExecution(a, io, main_path, &flags, &cli.env, "run", &cli.err.writer);
    try testing.expectEqual(@as(?bool, true), try lockCompat(a, app_root));

    // 非 compat 実行では stale_target として再解決し compatJs を外す。
    var cli2 = Cli.init(a);
    var plain = project_cmd.PrepFlags{};
    try project_cmd.prepareForExecution(a, io, main_path, &plain, &cli2.env, "run", &cli2.err.writer);
    try testing.expectEqual(@as(?bool, false), try lockCompat(a, app_root));
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

test "init --lib は明示された symlink root を拒否しリンク先へ書かない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.symLink(io, "outside", "link", .{});
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const outside_path = try std.fs.path.join(a, &.{ root, "outside" });

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "init", &.{ "link", "--lib", "--name", "safe" }, root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "symlink") != null);
    try testing.expect(!try dirFileExists(a, outside_path, "nako.toml"));
    try testing.expect(!try dirFileExists(a, outside_path, "src/lib.nako3"));
    // The explicit destination remains the original link.
    const stat = try temporary.dir.statFile(io, "link", .{ .follow_symlinks = false });
    try testing.expect(stat.kind == .sym_link);
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
    const ok = try test_command.runTestTarget(a, io, test_file, .{}, .warn, &test_out.writer, &test_err.writer);
    try testing.expect(ok);
}

test "runTestTarget は .nako/.git に降りず管理 dir の中身を走査しない" {
    // 管理 dir は file 単位の除外ではなく dir entry 段階で prune する
    // 回帰テスト。`.nako` 内に実行不能な .nako3 と（POSIX のみ）読み
    // 取り不可 dir を置いても走査全体が失敗しないことを確認する。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 収集されたら構文エラーで失敗する fixture。
    try temporary.dir.createDirPath(io, "tests/.nako/env/gen-1/deps/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = "tests/.nako/env/gen-1/deps/lib/bad.nako3", .data = "●（" });
    try temporary.dir.createDirPath(io, "tests/.git/objects/ab");
    try temporary.dir.writeFile(io, .{ .sub_path = "tests/.git/objects/ab/cd.nako3", .data = "●（" });
    try temporary.dir.writeFile(io, .{ .sub_path = "tests/ok_test.nako3", .data = "1を表示\n" });
    if (builtin.os.tag != .windows) {
        // `.nako` 内に権限なし dir を置く。walk が降りると open が
        // AccessDenied で走査全体を失敗させるが、prune 後は `.nako` を
        // 開かないため無害。
        try temporary.dir.createDirPath(io, "tests/.nako/blocked");
        try temporary.dir.setFilePermissions(io, "tests/.nako/blocked", std.Io.File.Permissions.fromMode(0o000), .{});
        defer temporary.dir.setFilePermissions(io, "tests/.nako/blocked", .default_dir, .{}) catch {};
    }
    const tests_root = try temporary.dir.realPathFileAlloc(io, "tests", a);
    var stdout: std.Io.Writer.Allocating = .init(a);
    var stderr: std.Io.Writer.Allocating = .init(a);
    const ok = try test_command.runTestTarget(a, io, tests_root, .{}, .warn, &stdout.writer, &stderr.writer);
    try testing.expect(ok);
    try testing.expect(std.mem.indexOf(u8, stdout.written(), "ok_test.nako3") != null);
    try testing.expect(std.mem.indexOf(u8, stdout.written(), "bad.nako3") == null);
    try testing.expect(std.mem.indexOf(u8, stdout.written(), "cd.nako3") == null);
}

test "編集 lock は pin 済み root handle から manifest を読み root 置換に追従しない" {
    // acquireProjectEditLock 後に root path が別 dir へ置き換わっても、
    // pin した handle の project が読まれることを確認する（lock 対象と
    // 読込み先の dir ずれの回帰テスト）。
    // Windows では open handle を持つ dir の rename が拒否されるため、
    // lock 中の root 置換は OS が防ぎこの再現自体が成立しない。
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data =
        \\[package]
        \\name = "original"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    var stderr: std.Io.Writer.Allocating = .init(a);
    var locked = (try project_cmd.acquireProjectEditLock(a, io, app_root, "test", &stderr.writer)).?;
    defer locked.deinit(a, io);
    // root を rename し、同じ path に別 project を置き換える。
    try temporary.dir.rename("app", temporary.dir, "app_moved", io);
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data =
        \\[package]
        \\name = "swapped"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    });
    var loaded = try project_cmd.loadPinnedProjectOrFail(a, io, &locked, &stderr.writer);
    defer loaded.deinit();
    // pin した元 dir（app_moved 側）の manifest が読まれる。
    try testing.expectEqualStrings("original", loaded.manifest.package.name);
    // lock file も pin した元 dir 側にできている。
    const lock_stat = try temporary.dir.statFile(io, "app_moved/.nako/edit.lock", .{ .follow_symlinks = false });
    try testing.expect(lock_stat.kind == .file);
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "app/.nako", .{ .follow_symlinks = false }));
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

test "npm 依存は packument 取得失敗時に lock を書き換えない" {
    // 閉域環境（registry 到達不能）と同じ経路をローカル fixture の 404 で
    // 再現する。外部ネットワークへは出ず、lock も環境も公開しない。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const routes = [_]RegistryRoute{.{ .path = "/escape", .status = 404 }};
    try server.serve(&routes);

    var cli = Cli.init(a);
    try cli.env.put("LNAKO_NPM_REGISTRY", server.base_url.?);
    try expectFail(error.Failed, a, &cli, "lock", &.{ "--package-cache-dir", cache_root }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "escape") != null);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "E013") != null);
    // 不完全な lock は残さない。
    try testing.expect(!try dirFileExists(a, app_root, "nako.lock"));
    try testing.expectEqual(@as(usize, 1), server.requests.load(.acquire));
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
        // version range は pkg 依存専用で、source 依存には適用できない。
        &.{ "lib@^1.2.3", "--path", "lib" },
        &.{ "lib@^1.2.3", "--git", "https://example.com/x.git", "--commit", "abcdef0" },
        &.{ "lib@^1.2.3", "--http", "https://example.com/x.tgz", "--hash", "sha256:00" },
        &.{ "lib@^1.2.3", "--npm" },
        &.{ "lib@", "--path", "lib" },
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

test "manifestDeclaresはpublic-id宣言を解決idで照合し同名推移的entryを直接宣言としない" {
    // 直接宣言が public-id = pkg:222 を指し、推移的に同名 entry
    // pkg:111 も解決された場合、`why pkg:111` は dep key の名前一致で
    // 直接宣言と誤報してはいけない。public-id 宣言は解決 id 一致を
    // 必須とする。
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
        \\
    , &diagnostics);
    defer manifest.deinit();
    const packages = [_]lock_model.PackageEntry{
        .{ .id = "pkg:11111111111111111111111111111111", .name = "dup", .version = "1.0.0" },
        .{ .id = "pkg:22222222222222222222222222222222", .name = "dup", .version = "2.0.0" },
    };
    var gated = std.StringHashMap(void).init(a);
    defer gated.deinit();
    var activated = std.StringHashMap(void).init(a);
    defer activated.deinit();

    // 同名の推移的 entry（pkg:111）→ public-id が一致しないため
    // 直接宣言と報告しない。
    var transitive = packages[0];
    const none = try project_cmd.manifestDeclares(a, &manifest, "/nonexistent", &packages, &transitive, "dup", "default", &gated, &activated);
    try testing.expect(none == null);

    // public-id が指す entry（pkg:222）→ 直接宣言と報告する。
    var direct = packages[1];
    const found = try project_cmd.manifestDeclares(a, &manifest, "/nonexistent", &packages, &direct, "dup", "default", &gated, &activated);
    defer a.free(found.?);
    try testing.expectEqualStrings("dependencies.pkg", found.?);
}

test "init --lib は親dirがsymlinkの場合に追随せず失敗する" {
    // `src` が symlink の dir で init --lib を実行しても、リンク先へ
    // scaffold file を書き込まない（親 dir を no-follow で開く）。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // 外部 dir（リンク先）と project dir を用意する。
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/marker.txt", .data = "keep" });
    try temporary.dir.createDirPath(io, "proj");
    try temporary.dir.symLink(io, "../outside", "proj/src", .{ .is_directory = true });
    const proj_root = try temporary.dir.realPathFileAlloc(io, "proj", a);
    const outside_root = try temporary.dir.realPathFileAlloc(io, "outside", a);

    var cli = Cli.init(a);
    try expectFail(error.Failed, a, &cli, "init", &.{ "--lib", "--name", "mylib" }, proj_root);
    // リンク先へ書き込まれていないこと（symlink 経由の外部書込み防止）。
    try testing.expect(!try dirFileExists(a, outside_root, "lib.nako3"));
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "symlink") != null);
}

test "依存テーブルヘッダの行末コメントを許容する" {
    // `[dependencies.path] # comment` は TOML 上有効なヘッダ。
    // add が同じテーブルへ追記し、remove が宣言を除去できる。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    try appManifest(a, app_root,
        \\[dependencies.path] # local packages
        \\lib = { path = "lib" }
        \\
    );

    var cli = Cli.init(a);
    try cli.run(a, "add", &.{ "other", "--path", "lib" }, app_root);
    const manifest = try readFile(a, app_root, "nako.toml");
    // コメント付きヘッダを再利用し、2つ目の [dependencies.path] を
    // 追加しない。
    try testing.expect(std.mem.indexOf(u8, manifest, "other = { path = \"lib\" }") != null);
    var header_count: usize = 0;
    var scan = manifest;
    while (std.mem.indexOf(u8, scan, "[dependencies.path]")) |at| {
        header_count += 1;
        scan = scan[at + 1 ..];
    }
    try testing.expectEqual(@as(usize, 1), header_count);

    try cli.run(a, "remove", &.{"other"}, app_root);
    const removed = try readFile(a, app_root, "nako.toml");
    try testing.expect(std.mem.indexOf(u8, removed, "other = { path") == null);
}

test "toOptions は sync と同一の version tuple と compat_js を供給する" {
    // lock/run 系と `lnako sync` で lock input の version tuple が違うと、
    // 片方が書いた lock をもう片方が stale 判定して書き戻す往復になる。
    // 全入口で同一の組（nako/cnako/lnako version）を供給する。
    const project = @import("lnako").package.project;
    var flags = project_cmd.PrepFlags{};
    defer flags.deinit(testing.allocator);
    const options = flags.toOptions(null);
    const nako = options.nako_version orelse return error.TestExpectedEqual;
    const cnako = options.cnako_version orelse return error.TestExpectedEqual;
    const lnako_v = options.lnako_version orelse return error.TestExpectedEqual;
    const expected = try std.fmt.allocPrint(testing.allocator, "{f}", .{nako});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(project.compat_nako_version, expected);
    const cnako_text = try std.fmt.allocPrint(testing.allocator, "{f}", .{cnako});
    defer testing.allocator.free(cnako_text);
    try testing.expectEqualStrings(project.compat_nako_version, cnako_text);
    try testing.expect(lnako_v.major >= 0);
    // compat_js フラグは options へそのまま写る。
    try testing.expect(!options.compat_js);
    var compat_flags = project_cmd.PrepFlags{ .compat_js = true };
    defer compat_flags.deinit(testing.allocator);
    try testing.expect(compat_flags.toOptions(null).compat_js);
}

test "inputDir は file symlink の実体側 dir を返す" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // project 内の file へ project 外から symlink を張る。表記側の dir
    // （`outside`）ではなく実体側（`app`）を返す必要がある。
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/main.nako3", .data = "ok\n" });
    const target_abs = try temporary.dir.realPathFileAlloc(io, "app/main.nako3", a);
    temporary.dir.symLink(io, target_abs, "outside/link.nako3", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const outside_abs = try temporary.dir.realPathFileAlloc(io, "outside", a);
    const link_abs = try std.fs.path.join(a, &.{ outside_abs, "link.nako3" });
    const app_abs = try temporary.dir.realPathFileAlloc(io, "app", a);

    const dir = try project_cmd.inputDir(a, io, link_abs);
    try testing.expectEqualStrings(app_abs, dir);
}

test "inputDir は directory symlink の実体側 dir を返す" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // project 内 dir への symlink を project 外から渡した場合、表記側の
    // 親 dir（`outside`）ではなくリンク先 dir 自身（`app`）を起点に
    // する必要がある。file symlink と同じく実体へ解決する。
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n" });
    const target_abs = try temporary.dir.realPathFileAlloc(io, "app", a);
    temporary.dir.symLink(io, target_abs, "outside/linkdir", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const outside_abs = try temporary.dir.realPathFileAlloc(io, "outside", a);
    const link_abs = try std.fs.path.join(a, &.{ outside_abs, "linkdir" });

    const dir = try project_cmd.inputDir(a, io, link_abs);
    try testing.expectEqualStrings(target_abs, dir);
}

/// テスト用に path の mode を変更する（POSIX のみ）。
fn chmodMode(a: std.mem.Allocator, path: []const u8, mode: u32) !void {
    const mode_text = try std.fmt.allocPrint(a, "{o}", .{mode});
    defer a.free(mode_text);
    const result = try std.process.run(a, io, .{ .argv = &.{ "/bin/chmod", mode_text, path } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }
}

test "check は共有 writable を --strict-project-trust で拒否し既定は警告して続行する" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const app_root = try newAppFixture(a, &temporary);
    // group/other 書込み可の共有 writable なプロジェクトにする。
    try chmodMode(a, app_root, 0o777);
    defer chmodMode(a, app_root, 0o755) catch {};

    // 既定（warn）は警告を stderr へ出して検査を続行する。
    var warn_cli = Cli.init(a);
    try warn_cli.run(a, "check", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, warn_cli.err.written(), "警告") != null);
    try testing.expect(std.mem.indexOf(u8, warn_cli.out.written(), "nako.toml: OK") != null);

    // --no-project-trust-warning は警告を出さず続行する。
    var ignore_cli = Cli.init(a);
    try ignore_cli.run(a, "check", &.{"--no-project-trust-warning"}, app_root);
    try testing.expect(std.mem.indexOf(u8, ignore_cli.err.written(), "警告") == null);
    try testing.expect(std.mem.indexOf(u8, ignore_cli.out.written(), "nako.toml: OK") != null);

    // --strict-project-trust は共有 writable を拒否する。
    var strict_cli = Cli.init(a);
    try expectFail(error.Failed, a, &strict_cli, "check", &.{"--strict-project-trust"}, app_root);
    try testing.expect(std.mem.indexOf(u8, strict_cli.err.written(), "書き込み権限") != null);

    // 環境変数でも同じ扱いになる（enforce は拒否、ignore は無警告）。
    var env_strict = Cli.init(a);
    try env_strict.env.put("LNAKO_PROJECT_TRUST", "enforce");
    try expectFail(error.Failed, a, &env_strict, "check", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, env_strict.err.written(), "書き込み権限") != null);

    var env_ignore = Cli.init(a);
    try env_ignore.env.put("LNAKO_PROJECT_TRUST", "ignore");
    try env_ignore.run(a, "check", &.{}, app_root);
    try testing.expect(std.mem.indexOf(u8, env_ignore.err.written(), "警告") == null);
    try testing.expect(std.mem.indexOf(u8, env_ignore.out.written(), "nako.toml: OK") != null);

    // `.nako` が無い fresh clone でも既存 nako.lock の共有 writable を検査する
    //（check は環境の有無に関係なく lock を読む）。
    try chmodMode(a, app_root, 0o755);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.lock", .data = "{\"schemaVersion\":1}" });
    const lock_abs = try std.fs.path.join(a, &.{ app_root, "nako.lock" });
    try chmodMode(a, lock_abs, 0o666);
    var lock_cli = Cli.init(a);
    try expectFail(error.Failed, a, &lock_cli, "check", &.{"--strict-project-trust"}, app_root);
    try testing.expect(std.mem.indexOf(u8, lock_cli.err.written(), "書き込み権限") != null);
    // `.nako` ケースを lock 経路から分離するため、lock を安全な mode へ戻す。
    try chmodMode(a, lock_abs, 0o644);

    // `.nako` 配下の共有 writable も検査する（check は .nako を読む）。
    try temporary.dir.createDirPath(io, "app/.nako");
    const nako_dir = try std.fs.path.join(a, &.{ app_root, ".nako" });
    try chmodMode(a, nako_dir, 0o777);
    var nako_cli = Cli.init(a);
    try expectFail(error.Failed, a, &nako_cli, "check", &.{"--strict-project-trust"}, app_root);
    try testing.expect(std.mem.indexOf(u8, nako_cli.err.written(), "書き込み権限") != null);

    // 同時指定は用法エラー。
    var both_cli = Cli.init(a);
    try expectFail(error.Usage, a, &both_cli, "check", &.{ "--strict-project-trust", "--no-project-trust-warning" }, app_root);
}

// ---------------------------------------------------------------------------
// npm registry E2E（ローカル HTTP fixture）
// ---------------------------------------------------------------------------
//
// Issue #53 の残ゲート。registry の packument と tarball をテスト内の HTTP
// サーバから配信し、CLI の lock/sync を実際に走らせて
//
//   packument 取得 → tarball 取得 → integrity 検証 → cache 格納
//   → nako.lock の npmInstances → sync の deps materialize
//
// を end-to-end に観測する。外部ネットワーク・npm CLI・Node lifecycle
// script は起動せず、取得先は LNAKO_NPM_REGISTRY で fixture へ向ける。

const pkg = @import("lnako").package;
const sync_cmd = @import("sync.zig");

const RegistryRoute = struct {
    path: []const u8,
    body: []const u8 = "",
    status: u16 = 200,
};

/// 単一接続ずつ処理する最小 registry サーバ。`Connection: close` で応答する。
/// `listen` で port を確定してから `serve` で thread を起動するため、
/// tarball URL を含む packument を spawn 前に組み立てられる（追加の同期不要）。
const RegistryServer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    base_url: ?[]u8 = null,
    routes: []const RegistryRoute = &.{},
    requests: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    fn listen(self: *RegistryServer) !void {
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.listener = try loopback.listen(self.io, .{ .reuse_address = true });
        self.base_url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{self.listener.?.socket.address.getPort()});
    }

    fn serve(self: *RegistryServer, routes: []const RegistryRoute) !void {
        self.routes = routes;
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{ self, self.listener.? });
    }

    fn stop(self: *RegistryServer) void {
        if (self.listener) |*listener| {
            self.stopping.store(true, .release);
            // `accept` を解除する。Windows の listening socket shutdown は
            // INVALID_PARAMETER で panic するため自接続でも起こす。
            if (builtin.os.tag != .windows) {
                const wake: std.Io.net.Stream = .{ .socket = listener.socket };
                wake.shutdown(self.io, .both) catch {};
            }
            if (listener.socket.address.connect(self.io, .{ .mode = .stream })) |stream| {
                stream.close(self.io);
            } else |_| {}
            if (self.thread) |thread| thread.join();
            self.thread = null;
            listener.deinit(self.io);
            self.listener = null;
        }
        if (self.base_url) |base| self.allocator.free(base);
        self.base_url = null;
    }

    fn url(self: *const RegistryServer, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url.?, path });
    }

    fn serveLoop(self: *RegistryServer, server: std.Io.net.Server) void {
        var listener = server;
        while (true) {
            var stream = listener.accept(self.io) catch return;
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            self.handle(&stream);
        }
    }

    fn handle(self: *RegistryServer, stream: *std.Io.net.Stream) void {
        defer stream.close(self.io);
        _ = self.requests.fetchAdd(1, .release);
        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        // `readSliceShort` は buffer を満たすまでブロックするため、要求ヘッダの
        // 終端は 1 byte ずつ読んで CRLFCRLF を検出する。
        var request: [4096]u8 = undefined;
        var total: usize = 0;
        var window: u32 = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = reader.interface.readSliceShort(&byte) catch return;
            if (n == 0) return;
            if (total < request.len) {
                request[total] = byte[0];
                total += 1;
            }
            window = (window << 8) | byte[0];
            if (window == std.mem.readInt(u32, "\r\n\r\n", .big)) break;
        }
        const line_end = std.mem.indexOf(u8, request[0..total], "\r\n") orelse return;
        const line = request[0..line_end];
        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return;
        const rest = line[first_space + 1 ..];
        const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
        const path = rest[0..second_space];

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        for (self.routes) |route| {
            if (!std.mem.eql(u8, route.path, path)) continue;
            writer.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n", .{ route.status, statusText(route.status), route.body.len }) catch return;
            writer.interface.writeAll(route.body) catch return;
            writer.interface.flush() catch return;
            return;
        }
        writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
        writer.interface.flush() catch return;
    }

    fn statusText(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            404 => "Not Found",
            else => "Status",
        };
    }
};

/// npm registry の packument JSON。`parsePackument` が読む versions/dist の
/// 最小形だけを持たせる。
fn npmPackument(
    a: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    tarball_url: []const u8,
    integrity: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"name":"{s}","dist-tags":{{"latest":"{s}"}},"versions":{{"{s}":{{"name":"{s}","version":"{s}","dist":{{"tarball":"{s}","integrity":"{s}"}}}}}}}}
    , .{ name, version, version, name, version, tarball_url, integrity });
}

/// `package/` 前置を持つ npm tarball（tar.gz）。registry の配布形式と同じ
/// shape を作り、cache/materialize の strip 契約をそのまま通す。
fn npmTarball(
    a: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    entry_file: []const u8,
    entry_bytes: []const u8,
) ![]u8 {
    const package_json = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"{s}\",\"main\":\"{s}\"}}", .{ name, version, entry_file });
    defer a.free(package_json);

    var tar_buffer: std.Io.Writer.Allocating = .init(a);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    try tar_writer.setRoot("package");
    try tar_writer.writeFileBytes("package.json", package_json, .{});
    try tar_writer.writeFileBytes(entry_file, entry_bytes, .{});
    try tar_writer.finishPedantically();

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(tar_buffer.written());
    try compress.finish();
    return try out.toOwnedSlice();
}

/// cache の `objects/` 直下にある完全/不完全 entry の数。integrity 不一致の
/// 試験で「公開済み entry が 1 つも無い」ことを観測するために使う。
fn countCacheObjects(a: std.mem.Allocator, cache_root: []const u8) !usize {
    const objects_path = try std.fs.path.join(a, &.{ cache_root, "objects" });
    var objects = std.Io.Dir.openDirAbsolute(io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer objects.close(io);
    var count: usize = 0;
    var it = objects.iterate();
    while (try it.next(io)) |_| count += 1;
    return count;
}

/// lock の `npmInstances` から instance key 一致の 1 件を返す（packages と
/// profile_packages の双方を走査する）。
fn findNpmInstance(lock: *const pkg.lock.Lock, key: []const u8) ?pkg.lock.NpmInstance {
    for (lock.packages) |entry| {
        for (entry.npm_instances) |instance| {
            if (std.mem.eql(u8, instance.key, key)) return instance;
        }
    }
    for (lock.profile_packages) |profile| {
        for (profile.packages) |entry| {
            for (entry.npm_instances) |instance| {
                if (std.mem.eql(u8, instance.key, key)) return instance;
            }
        }
    }
    return null;
}

test "npm registry E2E: packument 取得から cache・lock・sync materialize まで" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    const entry_bytes = "export default 42;\n";
    const tarball = try npmTarball(a, "escape", "1.2.3", "index.js", entry_bytes);
    const integrity = try pkg.npm.integritySha512(a, tarball);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const tarball_url = try server.url(a, "/escape/-/escape-1.2.3.tgz");
    const packument = try npmPackument(a, "escape", "1.2.3", tarball_url, integrity);
    const routes = [_]RegistryRoute{
        .{ .path = "/escape", .body = packument },
        .{ .path = "/escape/-/escape-1.2.3.tgz", .body = tarball },
    };
    try server.serve(&routes);

    // --- lock: packument + tarball を取り、integrity 検証して cache へ格納 ---
    var cli = Cli.init(a);
    try cli.env.put("LNAKO_NPM_REGISTRY", server.base_url.?);
    try cli.run(a, "lock", &.{ "--package-cache-dir", cache_root }, app_root);
    try testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));

    var diagnostics = pkg.diagnostics.List.init(a);
    defer diagnostics.deinit();
    const lock_bytes = try readFile(a, app_root, "nako.lock");
    var parsed = try pkg.lock.parse(a, lock_bytes, &diagnostics);
    defer parsed.deinit();
    const instance = findNpmInstance(&parsed, "escape@1.2.3") orelse return error.TestExpectedInstance;
    try testing.expectEqualStrings("escape", instance.name);
    try testing.expectEqualStrings("1.2.3", instance.version);
    try testing.expectEqualStrings(tarball_url, instance.url.?);
    const sha_hex = try pkg.fetch.sha256Hex(a, tarball);
    const expected_sha256 = try std.fmt.allocPrint(a, "sha256:{s}", .{sha_hex});
    try testing.expectEqualStrings(expected_sha256, instance.sha256.?);

    // cache には lock の sha256 + url から再導出できる内容アドレス key で
    // tarball bytes が格納されている（sync の materialize はこれだけを使う）。
    var store = try pkg.cache.Store.open(a, io, cache_root);
    defer store.deinit();
    const cache_key = (try pkg.npm_esm.cacheKeyForInstance(a, instance)).?;
    const cached = (try store.readVerifiedSourceArchive(a, cache_key, instance.sha256.?)).?;
    try testing.expectEqualSlices(u8, tarball, cached);

    // --- sync: lock と cache だけから世代 deps/ へ materialize ---
    // `--offline` で通信を禁じ、registry を止めても再構築できることを示す。
    var out: std.Io.Writer.Allocating = .init(a);
    var err_out: std.Io.Writer.Allocating = .init(a);
    try sync_cmd.run(a, io, &.{ "--offline", "--package-cache-dir", cache_root, app_root }, &cli.env, &out.writer, &err_out.writer);
    // lock は fresh・tarball は cache hit なので追加の取得は起きない。
    try testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));
    try testing.expect(try dirFileExists(a, app_root, ".nako/environment.json"));

    const generation = std.mem.trim(u8, try readFile(a, app_root, ".nako/current"), " \t\r\n");
    const dir_name = try pkg.npm_env.instanceDirName(a, instance);
    const installed_manifest_rel = try std.fmt.allocPrint(a, ".nako/env/{s}/deps/{s}/package.json", .{ generation, dir_name });
    const installed_manifest = try readFile(a, app_root, installed_manifest_rel);
    try testing.expect(std.mem.indexOf(u8, installed_manifest, "\"name\":\"escape\"") != null);
    const installed_entry_rel = try std.fmt.allocPrint(a, ".nako/env/{s}/deps/{s}/index.js", .{ generation, dir_name });
    try testing.expectEqualStrings(entry_bytes, try readFile(a, app_root, installed_entry_rel));
}

test "npm registry E2E: tarball の integrity 不一致は既存の lock と cache を汚さず失敗する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    const good = try npmTarball(a, "escape", "1.2.3", "index.js", "export default 42;\n");
    const tampered = try npmTarball(a, "escape", "1.2.3", "index.js", "export default 43;\n");
    const integrity = try pkg.npm.integritySha512(a, good);

    // 1) 正常な registry から lock と cache を作る。
    var healthy = RegistryServer{ .io = io, .allocator = a };
    try healthy.listen();
    defer healthy.stop();
    const healthy_tarball_url = try healthy.url(a, "/escape/-/escape-1.2.3.tgz");
    const healthy_packument = try npmPackument(a, "escape", "1.2.3", healthy_tarball_url, integrity);
    const healthy_routes = [_]RegistryRoute{
        .{ .path = "/escape", .body = healthy_packument },
        .{ .path = "/escape/-/escape-1.2.3.tgz", .body = good },
    };
    try healthy.serve(&healthy_routes);
    var cli = Cli.init(a);
    try cli.env.put("LNAKO_NPM_REGISTRY", healthy.base_url.?);
    try cli.run(a, "lock", &.{ "--package-cache-dir", cache_root }, app_root);
    const lock_before = try readFile(a, app_root, "nako.lock");
    const objects_before = try countCacheObjects(a, cache_root);
    try testing.expect(objects_before > 0);

    // 2) packument の integrity は正規 tarball のまま、配信 tarball だけを
    //    差し替えた registry へ切り替えて再解決（update）を強制する。
    var tampered_server = RegistryServer{ .io = io, .allocator = a };
    try tampered_server.listen();
    defer tampered_server.stop();
    const tampered_url = try tampered_server.url(a, "/escape/-/escape-1.2.3.tgz");
    const tampered_packument = try npmPackument(a, "escape", "1.2.3", tampered_url, integrity);
    const tampered_routes = [_]RegistryRoute{
        .{ .path = "/escape", .body = tampered_packument },
        .{ .path = "/escape/-/escape-1.2.3.tgz", .body = tampered },
    };
    try tampered_server.serve(&tampered_routes);

    try cli.env.put("LNAKO_NPM_REGISTRY", tampered_server.base_url.?);
    try expectFail(error.Failed, a, &cli, "update", &.{ "--package-cache-dir", cache_root }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "sha512 mismatch") != null);
    // 失敗しても既存 lock の bytes は変わらず、cache へ部分 entry も足さない。
    try testing.expectEqualStrings(lock_before, try readFile(a, app_root, "nako.lock"));
    try testing.expectEqual(objects_before, try countCacheObjects(a, cache_root));
    try testing.expectEqual(@as(usize, 2), tampered_server.requests.load(.acquire));
}

test "npm registry E2E: packument 404 は既存の lock を汚さず失敗する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    const tarball = try npmTarball(a, "escape", "1.2.3", "index.js", "export default 42;\n");
    const integrity = try pkg.npm.integritySha512(a, tarball);

    // 1) 正常な registry から lock を作る。
    var healthy = RegistryServer{ .io = io, .allocator = a };
    try healthy.listen();
    defer healthy.stop();
    const healthy_tarball_url = try healthy.url(a, "/escape/-/escape-1.2.3.tgz");
    const healthy_packument = try npmPackument(a, "escape", "1.2.3", healthy_tarball_url, integrity);
    const healthy_routes = [_]RegistryRoute{
        .{ .path = "/escape", .body = healthy_packument },
        .{ .path = "/escape/-/escape-1.2.3.tgz", .body = tarball },
    };
    try healthy.serve(&healthy_routes);
    var cli = Cli.init(a);
    try cli.env.put("LNAKO_NPM_REGISTRY", healthy.base_url.?);
    try cli.run(a, "lock", &.{ "--package-cache-dir", cache_root }, app_root);
    const lock_before = try readFile(a, app_root, "nako.lock");

    // 2) packument が 404 の registry へ切り替えて再解決を強制する。
    //    閉域環境（registry 到達不能）とは診断コードが異なるため、ここでは
    //    到達不能時の取得失敗経路（E013）を再現する。
    var missing = RegistryServer{ .io = io, .allocator = a };
    try missing.listen();
    defer missing.stop();
    const missing_routes = [_]RegistryRoute{.{ .path = "/escape", .status = 404 }};
    try missing.serve(&missing_routes);

    try cli.env.put("LNAKO_NPM_REGISTRY", missing.base_url.?);
    try expectFail(error.Failed, a, &cli, "update", &.{ "--package-cache-dir", cache_root }, app_root);
    try testing.expect(std.mem.indexOf(u8, cli.err.written(), "E013") != null);
    try testing.expectEqualStrings(lock_before, try readFile(a, app_root, "nako.lock"));
    try testing.expectEqual(@as(usize, 1), missing.requests.load(.acquire));
}

test "npm registry E2E: lock 無しの sync も fixture registry から構築する" {
    // sync は lock が無い/陳腐なら ensureLock で解決してから環境を作る。
    // sync 側の LNAKO_NPM_REGISTRY 配線（project.zig とは別経路）が
    // 効いていることを、lock を作らずに online sync を走らせて確認する。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    try appManifest(a, app_root,
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
    );

    const entry_bytes = "export default 42;\n";
    const tarball = try npmTarball(a, "escape", "1.2.3", "index.js", entry_bytes);
    const integrity = try pkg.npm.integritySha512(a, tarball);
    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const tarball_url = try server.url(a, "/escape/-/escape-1.2.3.tgz");
    const packument = try npmPackument(a, "escape", "1.2.3", tarball_url, integrity);
    const routes = [_]RegistryRoute{
        .{ .path = "/escape", .body = packument },
        .{ .path = "/escape/-/escape-1.2.3.tgz", .body = tarball },
    };
    try server.serve(&routes);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("LNAKO_NPM_REGISTRY", server.base_url.?);
    var out: std.Io.Writer.Allocating = .init(a);
    var err_out: std.Io.Writer.Allocating = .init(a);
    try sync_cmd.run(a, io, &.{ "--package-cache-dir", cache_root, app_root }, &env, &out.writer, &err_out.writer);
    try testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));

    var diagnostics = pkg.diagnostics.List.init(a);
    defer diagnostics.deinit();
    const lock_bytes = try readFile(a, app_root, "nako.lock");
    var parsed = try pkg.lock.parse(a, lock_bytes, &diagnostics);
    defer parsed.deinit();
    const instance = findNpmInstance(&parsed, "escape@1.2.3") orelse return error.TestExpectedInstance;
    try testing.expectEqualStrings(tarball_url, instance.url.?);
    const generation = std.mem.trim(u8, try readFile(a, app_root, ".nako/current"), " \t\r\n");
    const dir_name = try pkg.npm_env.instanceDirName(a, instance);
    const entry_rel = try std.fmt.allocPrint(a, ".nako/env/{s}/deps/{s}/index.js", .{ generation, dir_name });
    try testing.expectEqualStrings(entry_bytes, try readFile(a, app_root, entry_rel));
}

// ---------------------------------------------------------------------------
// 参照 plugin+npm E2E（Issue #54）
// ---------------------------------------------------------------------------
//
// `tests/fixtures/package-plugin-npm` の参照パッケージを tmp へ展開し、
//
//   lnako lock（ローカル registry から packument/tarball 取得・検証・cache）
//   → sync --offline（lock と cache だけから世代 deps を materialize）
//   → compileInput(.compat_js = true) + Interpreter 実行
//
// を end-to-end に観測する。ESM plugin 命令（`leftpad__整形`）と、その
// plugin 実装内の npm bare import（`left-pad`）が同時に動くことを stdout
// 全体で固定する。fixture は commit 済みファイルをそのまま読むため、
// テストが参照する内容と fixture の drift も検出できる。
//
// 外部ネットワーク・npm CLI・Node lifecycle script は起動せず、registry は
// 127.0.0.1 のテスト内 HTTP fixture のみを使う（#226）。

const core = @import("lnako");
const host_module = @import("../../host.zig");

/// `zig build test` の run step は build root（repo root）を cwd にする。
/// 念のため cwd から数段上も探し、fixture の source of truth は commit 済み
/// ファイルのままにする（テスト側で内容を複製しない）。
fn pluginNpmFixtureRoot(a: std.mem.Allocator) ![]const u8 {
    const prefixes = [_][]const u8{ ".", "..", "../..", "../../.." };
    for (prefixes) |prefix| {
        const path = if (std.mem.eql(u8, prefix, "."))
            try a.dupe(u8, "tests/fixtures/package-plugin-npm")
        else
            try std.fmt.allocPrint(a, "{s}/tests/fixtures/package-plugin-npm", .{prefix});
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    return error.PluginNpmFixtureNotFound;
}

fn readPluginNpmFixture(a: std.mem.Allocator, relative: []const u8) ![]u8 {
    const root = try pluginNpmFixtureRoot(a);
    const path = try std.fs.path.join(a, &.{ root, relative });
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

/// 参照 fixture を `app` 配下へ展開する（source of truth は commit 済み
/// fixture ファイル）。
fn writePluginNpmReferenceApp(a: std.mem.Allocator, temporary: *std.testing.TmpDir) !void {
    try temporary.dir.createDirPath(io, "app/packages/leftpad");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = try readPluginNpmFixture(a, "app/nako.toml") });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/main.nako3", .data = try readPluginNpmFixture(a, "app/main.nako3") });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/packages/leftpad/nako.toml", .data = try readPluginNpmFixture(a, "app/packages/leftpad/nako.toml") });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/packages/leftpad/plugin.mjs", .data = try readPluginNpmFixture(a, "app/packages/leftpad/plugin.mjs") });
}

/// `lnako run --compat-js` と同じ順序で compile → Interpreter 実行を行う。
/// compile が診断を出して null を返した場合は false、診断以外のエラーは
/// 呼出し側へ伝播する。
fn runCompatJsMain(
    a: std.mem.Allocator,
    main_path: []const u8,
    cache_root: []const u8,
    work_root: []const u8,
    out: *std.Io.Writer.Allocating,
    err_out: *std.Io.Writer.Allocating,
) !bool {
    const compiled = compiler_pipeline.compileInput(a, io, main_path, .{
        .compat_js = true,
        .package_cache_root = cache_root,
    }, &err_out.writer) catch |err| {
        std.debug.print("参照 plugin+npm E2E: compile エラー: {s}\n{s}", .{ @errorName(err), err_out.written() });
        return err;
    };
    var ir_program = compiled orelse return false;
    defer ir_program.deinit();
    var runtime = core.runtime.value.Runtime.init(a);
    defer runtime.deinit();
    var cli_host = host_module.CliHost{
        .writer = &out.writer,
        .error_writer = &err_out.writer,
        .io = io,
        .program_arguments = &.{main_path},
        .runtime_path = "lnako",
        .source_path = main_path,
        .environment_names = &.{},
        .environment_values = &.{},
        .temporary_directory = work_root,
        .async_task_map = std.AutoHashMap(u64, *host_module.AsyncOperationTask).init(std.heap.page_allocator),
    };
    defer cli_host.deinit();
    var interpreter = core.runtime.interpreter.Interpreter.init(a, &runtime, ir_program, cli_host.interpreterHost());
    defer interpreter.deinit();
    _ = interpreter.run() catch |err| {
        // 既存の run/test 経路と同じく、QuickJS 側の失敗理由を残す。
        std.debug.print("参照 plugin+npm E2E: 実行時エラー: {s}\n{s}", .{ runtime.failureMessage() orelse @errorName(err), err_out.written() });
        return err;
    };
    return true;
}

test "参照 plugin+npm E2E: lock→sync --offline→run --compat-js で plugin 登録と bare import が同時に動く" {
    // 通常ビルド（QuickJS なし）では JS/ESM を実行できないため skip する。
    // `zig build -Dcompat-js=true test` でこのテストが実走する。
    if (!core.compat.quickjs.available()) return error.SkipZigTest;

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "cache");
    try writePluginNpmReferenceApp(a, &temporary);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", a);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", a);
    const work_root = try temporary.dir.realPathFileAlloc(io, ".", a);

    // --- fixture registry: `left-pad` の packument と tarball を配信する ---
    const registry_entry = try readPluginNpmFixture(a, "registry/left-pad/index.js");
    const expected_stdout = try readPluginNpmFixture(a, "expected-stdout.txt");
    const tarball = try npmTarball(a, "left-pad", "1.0.0", "index.js", registry_entry);
    const integrity = try pkg.npm.integritySha512(a, tarball);
    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const tarball_url = try server.url(a, "/left-pad/-/left-pad-1.0.0.tgz");
    const packument = try npmPackument(a, "left-pad", "1.0.0", tarball_url, integrity);
    const routes = [_]RegistryRoute{
        .{ .path = "/left-pad", .body = packument },
        .{ .path = "/left-pad/-/left-pad-1.0.0.tgz", .body = tarball },
    };
    try server.serve(&routes);

    var cli = Cli.init(a);
    try cli.env.put("LNAKO_NPM_REGISTRY", server.base_url.?);

    // --- lock: packument 取得 → tarball 取得/integrity 検証 → cache 格納 ---
    cli.run(a, "lock", &.{ "--package-cache-dir", cache_root }, app_root) catch |err| {
        std.debug.print("参照 plugin+npm E2E: lock 失敗: {s}\n{s}", .{ @errorName(err), cli.err.written() });
        return err;
    };
    try testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));

    var diagnostics = pkg.diagnostics.List.init(a);
    defer diagnostics.deinit();
    const lock_bytes = try readFile(a, app_root, "nako.lock");
    var parsed = try pkg.lock.parse(a, lock_bytes, &diagnostics);
    defer parsed.deinit();
    // path 依存（plugin package）が ESM 実装として、npm instance と同時に
    // lock に載る。
    try testing.expect(std.mem.indexOf(u8, lock_bytes, "\"implementation\": \"ESM\"") != null);
    try testing.expect(std.mem.indexOf(u8, lock_bytes, "\"leftpad\"") != null);
    const instance = findNpmInstance(&parsed, "left-pad@1.0.0") orelse return error.TestExpectedInstance;
    try testing.expectEqualStrings(tarball_url, instance.url.?);

    // --- sync --offline: lock と cache だけから世代 deps へ materialize ---
    var sync_out: std.Io.Writer.Allocating = .init(a);
    var sync_err: std.Io.Writer.Allocating = .init(a);
    sync_cmd.run(a, io, &.{ "--offline", "--package-cache-dir", cache_root, app_root }, &cli.env, &sync_out.writer, &sync_err.writer) catch |err| {
        std.debug.print("参照 plugin+npm E2E: sync --offline 失敗: {s}\n{s}", .{ @errorName(err), sync_err.written() });
        return err;
    };
    // 追加の registry 取得は起きない（offline でも cache hit だけで完結）。
    try testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));
    try testing.expect(try dirFileExists(a, app_root, ".nako/environment.json"));

    const generation = std.mem.trim(u8, try readFile(a, app_root, ".nako/current"), " \t\r\n");
    const dir_name = try pkg.npm_env.instanceDirName(a, instance);
    const installed_entry_rel = try std.fmt.allocPrint(a, ".nako/env/{s}/deps/{s}/index.js", .{ generation, dir_name });
    try testing.expectEqualStrings(registry_entry, try readFile(a, app_root, installed_entry_rel));

    // --- run --compat-js: plugin 命令と npm bare import を同時に実行する ---
    const main_path = try std.fs.path.join(a, &.{ app_root, "main.nako3" });
    var out: std.Io.Writer.Allocating = .init(a);
    var err_out: std.Io.Writer.Allocating = .init(a);
    const executed = try runCompatJsMain(a, main_path, cache_root, work_root, &out, &err_out);
    if (!executed) {
        std.debug.print("参照 plugin+npm E2E: compile 診断:\n{s}", .{err_out.written()});
        return error.TestExpectedCompileSuccess;
    }
    try testing.expectEqualStrings(expected_stdout, out.written());

    // --- 通常モード分離: --compat-js なしでは JS/ESM を取り込まない ---
    var normal_err: std.Io.Writer.Allocating = .init(a);
    const normal = try compiler_pipeline.compileInput(a, io, main_path, .{}, &normal_err.writer);
    try testing.expect(normal == null);
    try testing.expect(std.mem.indexOf(u8, normal_err.written(), "JavaScriptの取り込みには--compat-jsが必要です") != null);
}
