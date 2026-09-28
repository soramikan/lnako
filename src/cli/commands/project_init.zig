//! `lnako init` — `nako.toml`・`--lib` scaffold を生成するコマンド。
//! 生成は全て対象 dir の pinned handle 相対に行い、既存 file/dir・
//! symlink 置換された親 dir を書き換えない（詳細は各 helper の
//! doc コメント）。共通の失敗・フラグ基盤は `project.zig`（`shared`）。

const std = @import("std");
const lnako = @import("lnako");
const shared = @import("project.zig");
const toml_scan = @import("toml_scan.zig");

const project = lnako.package.project;
const manifest_mod = lnako.package.manifest;

const Allocator = std.mem.Allocator;

const fail = shared.fail;
const failUsage = shared.failUsage;
const flagValue = shared.flagValue;

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

const lib_source_template =
    \\/// <name> ライブラリのエントリポイント。
    \\/// 利用側プロジェクトは `[dependencies.path]` または registry 依存として
    \\/// このパッケージを参照する。
    \\
    \\●(値を)二倍とは
    \\  値*2で戻る
    \\ここまで
    \\
;

const lib_example_template =
    \\/// <name> の利用例。このファイルはライブラリ開発中の動作確認用で、
    \\/// 相対 path でライブラリソースを取り込む。
    \\
    \\!「../src/lib.nako3」を取り込む
    \\
    \\21を二倍して表示
    \\
;

const lib_test_template =
    \\/// <name> のテスト。
    \\
    \\!「../src/lib.nako3」を取り込む
    \\
    \\●テスト:二倍関数とは
    \\  結果は21を二倍。
    \\  結果と42がASSERT等
    \\ここまで
    \\
;

/// scaffold の親 dir（`src`/`examples`/`tests`）を no-follow で開く。
/// 既存の実 dir はそのまま使い、無ければ作成する。leaf symlink・
/// reparse point・実 file は追随せず `error.InvalidScaffoldDir` と
/// する（init は既存物を置き換えず、symlink 経由で外部へ書かない）。
fn openScaffoldDir(io: std.Io, dir: std.Io.Dir, rel: []const u8) !std.Io.Dir {
    while (true) {
        var opened = dir.openDir(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                dir.createDirPath(io, rel) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                continue;
            },
            // leaf symlink・実 file は追随せず init 失敗とする。
            error.SymLinkLoop, error.NotDir => return error.InvalidScaffoldDir,
            else => return err,
        };
        const stat = opened.stat(io) catch |err| {
            opened.close(io);
            return err;
        };
        if (stat.kind == .directory) return opened;
        opened.close(io);
        return error.InvalidScaffoldDir;
    }
}

/// `sub_path` へ新規 file を排他作成して書き込む。既存・symlink・
/// reparse point には `PathAlreadyExists`/`SymLinkLoop` で失敗し、
/// 既存ファイルや symlink 先を上書きしない（`access` 検査と書込の
/// 間に置かれた symlink も `exclusive` で捕捉できる）。親 dir は
/// no-follow で開いたハンドル相対で作成し、親が symlink の場合も
/// リンク先へ書き込まない。
fn writeInitFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, contents: []const u8) !void {
    var target_dir = dir;
    var leaf = sub_path;
    var owned_dir: ?std.Io.Dir = null;
    defer if (owned_dir) |*owned| owned.close(io);
    if (std.fs.path.dirname(sub_path)) |parent| {
        owned_dir = try openScaffoldDir(io, dir, parent);
        target_dir = owned_dir.?;
        leaf = std.fs.path.basename(sub_path);
    }
    var file = try target_dir.createFile(io, leaf, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// `path` が存在するか。`access`（symlink 追従）ではリンク切れの
/// symlink を見逃して対象を上書きし得るため、no-follow stat で
/// symlink/reparse point そのものも「存在する」と判定する。
fn initTargetExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// `init` が今回の呼出しで作成した出力だけを取り消す。scaffold 途中の
/// 失敗で manifest や部分的な生成物が残ると再試行が「既に存在」で
/// 拒否されるため、作成済みの file/dir を登録して失敗時に除去する。
/// 既存の file/dir は登録しないため一切触れない。個々の削除失敗は
/// 無視する（ロールバックの失敗で元の error を隠さない）。
/// 削除は常に pinned handle 相対で行う。登録した path の中間成分が
/// rollback 前に symlink へ置換されても、絶対 path 再解決で project
/// 外の file を消さない。
const InitRollback = struct {
    io: std.Io,
    /// init 対象 dir の pinned handle（所有しない。caller が close する
    /// 前に `run` が呼ばれるよう errdefer の宣言順で制御する）。
    /// Windows では `std.Io.Dir.cwd()` が comptime 評価できないため
    /// 既定値は持たず必須とする。
    root_dir: std.Io.Dir,
    /// 今回作成した `nako.toml`。createFile 成功後に登録する。
    manifest_created: bool = false,
    /// 今回作成したプロジェクト dir の親 handle（所有する）と basename。
    /// dir が既存だった場合は null。
    new_dir_parent: ?std.Io.Dir = null,
    new_dir_name: []const u8 = "",
    /// 今回作成した scaffold file（root_dir 相対、作成順）。
    files: std.ArrayList([]const u8) = .empty,
    /// 今回作成した scaffold 親 dir（root_dir 相対、作成順）。
    dirs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *InitRollback, a: Allocator) void {
        self.files.deinit(a);
        self.dirs.deinit(a);
        if (self.new_dir_parent) |*parent| {
            parent.close(self.io);
            self.new_dir_parent = null;
        }
    }

    /// 登録済みの生成物を作成の逆順で削除する。file は親 dir を
    /// no-follow で開いてから leaf を消し、dir は空の場合のみ消える
    /// （`deleteDir` は leaf symlink を辿らない）。
    fn run(self: *InitRollback) void {
        for (self.files.items) |rel| {
            if (std.fs.path.dirname(rel)) |parent_rel| {
                var parent = self.root_dir.openDir(self.io, parent_rel, .{ .follow_symlinks = false }) catch continue;
                defer parent.close(self.io);
                parent.deleteFile(self.io, std.fs.path.basename(rel)) catch {};
            } else {
                self.root_dir.deleteFile(self.io, rel) catch {};
            }
        }
        var i = self.dirs.items.len;
        while (i > 0) {
            i -= 1;
            self.root_dir.deleteDir(self.io, self.dirs.items[i]) catch {};
        }
        if (self.manifest_created) self.root_dir.deleteFile(self.io, project.manifest_name) catch {};
        if (self.new_dir_parent) |*parent| {
            parent.deleteDir(self.io, self.new_dir_name) catch {};
            parent.close(self.io);
            self.new_dir_parent = null;
        }
    }
};

pub fn runInit(a: Allocator, io: std.Io, args: []const []const u8, start_dir: []const u8, stderr: *std.Io.Writer) !void {
    var lib = false;
    var name_opt: ?[]const u8 = null;
    var dir_arg: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--lib")) {
            lib = true;
        } else if (std.mem.eql(u8, argument, "--name")) {
            name_opt = try flagValue(args, &index, "init", "--name", stderr);
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "init: 不明なオプションです: {s}\n", .{argument});
        } else if (dir_arg == null) {
            dir_arg = argument;
        } else {
            return failUsage(stderr, "init: 不明な引数です: {s}\n", .{argument});
        }
    }

    // --name は副作用（dir 作成・manifest 書込）より先に検証する。
    if (name_opt) |n| {
        if (!manifest_mod.isPackageName(n)) {
            return failUsage(stderr, "init: パッケージ名が規則に合いません: {s}（[a-z][a-z0-9-]{{0,63}}）\n", .{n});
        }
    }
    const cwd = std.Io.Dir.cwd();
    // dir 作成より先に package 名を検証する（basename が規則外で失敗
    // した場合に空 dir を残さない）。
    const dir_abs = if (dir_arg) |dir|
        try project_abs(a, io, dir, start_dir)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, start_dir, a);
    const name = name_opt orelse std.fs.path.basename(dir_abs);
    // パッケージ名規則を先に検証する。dir 名が規則外の場合は --name で
    // 明示してもらう。
    if (!manifest_mod.isPackageName(name)) {
        return failUsage(stderr, "init: パッケージ名が規則に合いません: {s}（[a-z][a-z0-9-]{{0,63}}。--name で指定してください）\n", .{name});
    }
    var created_dir = false;
    if (dir_arg != null) {
        const dir_existed = try initTargetExists(io, dir_abs);
        if (!dir_existed) {
            try cwd.createDirPath(io, dir_abs);
            created_dir = true;
        }
    }
    // Hold a no-follow handle to the destination root. Besides rejecting an
    // explicit root symlink/junction, all writes below are relative to this
    // handle so replacing the path after validation cannot redirect them.
    var root_dir = cwd.openDir(io, dir_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir => return fail(stderr, "init: {s} は symlink またはディレクトリではありません\n", .{dir_abs}),
        else => return err,
    };
    defer root_dir.close(io);
    // scaffold 作成の途中失敗で `nako.toml` や部分的な生成物が残り
    // 再試行を妨げないよう、今回作成した出力だけを追跡して失敗時に
    // 除去する。既存の file/dir は対象に含めない。削除は `root_dir` の
    // pinned handle 相対で行うため、errdefer は close より後（=先に実行）
    // に登録する。
    var rollback = InitRollback{ .io = io, .root_dir = root_dir };
    defer rollback.deinit(a);
    errdefer rollback.run();
    if (created_dir) {
        // `dir_abs` 自身の削除は親 handle 相対で行う。親をここで pin
        // しておけば、rollback までに path が置換されても作成した dir
        // 以外を消さない。
        if (std.fs.path.dirname(dir_abs)) |parent_path| {
            const maybe_parent = cwd.openDir(io, parent_path, .{ .follow_symlinks = false }) catch null;
            if (maybe_parent) |parent| {
                rollback.new_dir_parent = parent;
                rollback.new_dir_name = std.fs.path.basename(dir_abs);
            }
        }
    }
    const root_stat = try root_dir.stat(io);
    if (root_stat.kind != .directory) {
        return fail(stderr, "init: {s} は symlink またはディレクトリではありません\n", .{dir_abs});
    }
    const manifest_path = try std.fs.path.join(a, &.{ dir_abs, project.manifest_name });
    if (try initTargetExists(io, manifest_path)) {
        return fail(stderr, "init: {s} は既に存在します\n", .{manifest_path});
    }

    // --lib の生成物も事前に存在検査する。ユーザの既存ファイルを
    // 黙って上書きしない。
    const scaffold_paths = [_][]const u8{
        "src" ++ std.fs.path.sep_str ++ "lib.nako3",
        "examples" ++ std.fs.path.sep_str ++ "main.nako3",
        "tests" ++ std.fs.path.sep_str ++ "lib_test.nako3",
    };
    if (lib) {
        for (scaffold_paths) |rel| {
            const target = try std.fs.path.join(a, &.{ dir_abs, rel });
            if (try initTargetExists(io, target)) {
                return fail(stderr, "init: {s} は既に存在します（既存ファイルを上書きしません）\n", .{target});
            }
        }
    }

    const name_toml = try toml_scan.tomlEscape(a, name);
    var manifest_text: std.ArrayList(u8) = .empty;
    try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    , .{name_toml}));
    if (lib) {
        try manifest_text.appendSlice(a, try std.fmt.allocPrint(a,
            \\
            \\[[exports]]
            \\name = "{s}"
            \\path = "src/lib.nako3"
            \\
        , .{name_toml}));
    }
    // 事前検査と書込の間に置かれた file/symlink も `exclusive` で拒否
    // する（symlink 先の外部 file を上書きしない）。
    var manifest_file = root_dir.createFile(io, project.manifest_name, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return fail(stderr, "init: {s} は既に存在します\n", .{manifest_path}),
        else => return err,
    };
    rollback.manifest_created = true;
    // Windows では open 中の file を削除できないため、ロールバックが
    // manifest を除去できるよう書込直後に閉じる。
    manifest_file.writeStreamingAll(io, manifest_text.items) catch |err| {
        manifest_file.close(io);
        return err;
    };
    manifest_file.close(io);

    if (lib) {
        const lib_source = try std.mem.replaceOwned(u8, a, lib_source_template, "<name>", name);
        const example = try std.mem.replaceOwned(u8, a, lib_example_template, "<name>", name);
        const test_source = try std.mem.replaceOwned(u8, a, lib_test_template, "<name>", name);
        for ([_][]const u8{ lib_source, example, test_source }, scaffold_paths) |contents, rel| {
            const target = try std.fs.path.join(a, &.{ dir_abs, rel });
            // writeInitFile が親 dir を新規作成する場合に備え、生成前に
            // 存在しなかった dir はロールバック対象へ登録する。既存の
            // dir は登録しないためロールバックで残る。登録は root_dir
            // 相対で行う（rollback 中の path 置換に追随しない）。
            if (std.fs.path.dirname(rel)) |parent_rel| {
                const parent_abs = try std.fs.path.join(a, &.{ dir_abs, parent_rel });
                if (!try initTargetExists(io, parent_abs)) try rollback.dirs.append(a, parent_rel);
            }
            writeInitFile(io, root_dir, rel, contents) catch |err| {
                // 実 CLI の fail は exit するため errdefer が走らない。
                // 明示的にロールバックしてから失敗を返す。
                rollback.run();
                return switch (err) {
                    error.InvalidScaffoldDir => fail(stderr, "init: {s} の親 dir は symlink またはファイルのため作成できません\n", .{target}),
                    error.PathAlreadyExists => fail(stderr, "init: {s} は既に存在します（既存ファイルを上書きしません）\n", .{target}),
                    else => err,
                };
            };
            try rollback.files.append(a, rel);
        }
    }
    try stderr.print("init: {s} にプロジェクトを作成しました\n", .{dir_abs});
    try stderr.flush();
}

fn project_abs(a: Allocator, io: std.Io, path: []const u8, base_dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(a, &.{path}) catch return error.FileSystem;
    }
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, base_dir, a);
    return std.fs.path.resolve(a, &.{ base, path }) catch return error.FileSystem;
}
test "initTargetExists は symlink も存在として検出する" {
    // `access`（symlink 追従）ではリンク切れの symlink を見逃し、init が
    // link 先を上書きし得る。no-follow stat で symlink 本体を検出する。
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.symLink(io, "missing-target", "nako.toml", .{});
    // リンク切れの symlink は realPathFileAlloc では解決できないため
    // tmpdir の実 path と連結する。
    const tmp_abs = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const link_abs = try std.fs.path.join(std.testing.allocator, &.{ tmp_abs, "nako.toml" });
    defer std.testing.allocator.free(link_abs);
    try std.testing.expect(try initTargetExists(io, link_abs));
}

test "init --lib は scaffold 失敗時に今回作成した生成物だけをロールバックする" {
    // `src` が symlink のため scaffold 作成は InvalidScaffoldDir で失敗する。
    // 途中まで作成した nako.toml が残ると再試行が「既に存在」で拒否される
    // ため、今回作成した file/dir を除去する。既存の symlink・file・dir
    // は対象に含めず残す。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);

    // `src` を symlink、`examples` を中身付きの実 dir にして、1 件目の
    // scaffold（src/lib.nako3）は親が symlink で失敗、2 件目の
    // examples/main.nako3 まで進まない構成と既存物保護を両方検証する
    // ため、別の fixture で両パターンを試す。
    try temporary.dir.symLink(io, "elsewhere", "src", .{});
    try temporary.dir.createDirPath(io, "examples");
    try temporary.dir.writeFile(io, .{ .sub_path = "examples/keep.txt", .data = "keep" });

    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.Failed, runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer));

    // 作成した nako.toml は残さない。
    const manifest_abs = try std.fs.path.join(a, &.{ root, "nako.toml" });
    try std.testing.expect(!try initTargetExists(io, manifest_abs));
    // 既存の src symlink と examples/keep.txt は無傷で残る。
    const src_stat = try temporary.dir.statFile(io, "src", .{ .follow_symlinks = false });
    try std.testing.expect(src_stat.kind == .sym_link);
    try std.testing.expect(try initTargetExists(io, try std.fs.path.join(a, &.{ root, "examples", "keep.txt" })));

    // symlink を取り除けば再試行が成功する。
    try temporary.dir.deleteFile(io, "src");
    try runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer);
    try std.testing.expect(try initTargetExists(io, manifest_abs));
    try std.testing.expect(try initTargetExists(io, try std.fs.path.join(a, &.{ root, "src", "lib.nako3" })));
}

test "init --lib は scaffold 途中の失敗で先行 file と dir もロールバックする" {
    // `examples` が symlink のため、1 件目（src/lib.nako3）は成功してから
    // 2 件目で失敗する。先行して作成した src/lib.nako3・src dir・
    // nako.toml を全て除去し、既存の symlink は残す。
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    try temporary.dir.symLink(io, "elsewhere", "examples", .{});

    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.Failed, runInit(a, io, &.{ "--lib", "--name", "testlib" }, root, &err.writer));

    try std.testing.expect(!try initTargetExists(io, try std.fs.path.join(a, &.{ root, "nako.toml" })));
    try std.testing.expect(!try initTargetExists(io, try std.fs.path.join(a, &.{ root, "src" })));
    const examples_stat = try temporary.dir.statFile(io, "examples", .{ .follow_symlinks = false });
    try std.testing.expect(examples_stat.kind == .sym_link);
}

test "InitRollback は symlink 置換された親 dir を辿らず project 外を消さない" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // init 先と project 外の victim を用意する。
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/victim.txt", .data = "keep" });
    var root = try temporary.dir.openDir(io, ".", .{ .follow_symlinks = false });
    defer root.close(io);
    // init が作成した生成物（manifest + src/lib.nako3 + src dir）を再現。
    try root.writeFile(io, .{ .sub_path = "nako.toml", .data = "[package]\n" });
    try root.createDirPath(io, "src");
    try root.writeFile(io, .{ .sub_path = "src/lib.nako3", .data = "x" });
    var rollback = InitRollback{ .io = io, .root_dir = root, .manifest_created = true };
    defer rollback.deinit(std.testing.allocator);
    try rollback.files.append(std.testing.allocator, "src/lib.nako3");
    try rollback.dirs.append(std.testing.allocator, "src");
    // rollback 前に `src` が outside への symlink へ置換された想定。
    // 絶対 path で `src/lib.nako3` を消すと outside 側まで辿って消える。
    try root.deleteTree(io, "src");
    try root.symLink(io, "../outside", "src", .{});
    rollback.run();
    try temporary.dir.access(io, "outside/victim.txt", .{});
    try std.testing.expectError(error.FileNotFound, root.access(io, "nako.toml", .{}));
    const src_stat = try root.statFile(io, "src", .{ .follow_symlinks = false });
    try std.testing.expect(src_stat.kind == .sym_link);
}
