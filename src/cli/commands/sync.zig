//! `lnako sync` — v1 manifest から `nako.lock` と `.nako/v1` 環境を構築する。
//!
//! v1 の同期はローカルの固定 fixture（`--v1-fixture <dir>`）を唯一の取得元に
//! する。旧 manifest・旧 `nako.lock`・旧 `.nako/environment.json` を読み替え
//! る経路は持たない（仕様 §2、Q12）。旧 manifest は再作成を案内して拒否し、
//! 旧 lock は `v1_client` が `LegacyLock` として拒否する。
//!
//! `--json` は `environment.json` と同じバイト列を標準出力へ書く。

const std = @import("std");
const lnako = @import("lnako");

const project = lnako.package.project;
const v1_client = lnako.package.v1_client;
const v1_types = lnako.package.v1_types;
const v1_entry = @import("v1_entry.zig");
const v1_sync = @import("v1_sync.zig");

const CliError = error{ Failed, Usage };

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Failed;
    std.process.exit(1);
}

fn failUsage(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) CliError {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    if (@import("builtin").is_test) return error.Usage;
    std.process.exit(2);
}

/// 値を取るフラグの次の引数を値として取り出す。末尾に値が無い場合や、
/// 次の引数が別のオプション（`-` 始まり）なら用法エラーとする。
fn flagValue(args: []const []const u8, index: *usize, flag: []const u8, stderr: *std.Io.Writer) CliError![]const u8 {
    if (index.* + 1 >= args.len or std.mem.startsWith(u8, args[index.* + 1], "-")) {
        return failUsage(stderr, "sync: {s} には値が必要です\n", .{flag});
    }
    index.* += 1;
    return args[index.*];
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, environ_map: ?*const std.process.Environ.Map, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var profile: ?[]const u8 = null;
    var runtime: ?v1_client.Runtime = null;
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(allocator);
    var no_default_features = false;
    var registry_url: ?[]const u8 = null;
    var v1_fixture: ?[]const u8 = null;
    var v1_permissions: std.ArrayList(v1_client.SourcePermission) = .empty;
    defer v1_permissions.deinit(allocator);
    var locked = false;
    var json = false;
    var root: []const u8 = ".";
    var root_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--profile")) {
            profile = try flagValue(args, &index, "--profile", stderr);
        } else if (std.mem.eql(u8, argument, "--runtime")) {
            const name = try flagValue(args, &index, "--runtime", stderr);
            if (std.mem.eql(u8, name, "lnako")) {
                runtime = .lnako;
            } else if (std.mem.eql(u8, name, "cnako")) {
                runtime = .cnako;
            } else if (std.mem.eql(u8, name, "wnako")) {
                runtime = .wnako;
            } else {
                return failUsage(stderr, "sync: 不明な runtime です: {s}（lnako|cnako|wnako）\n", .{name});
            }
        } else if (std.mem.eql(u8, argument, "--offline")) {
            // v1 の取得はローカル fixture だけで完結する。
        } else if (std.mem.eql(u8, argument, "--v1")) {
            // v1 は manifest から自動判定する。旧経路を選ぶフラグは持たない。
        } else if (std.mem.eql(u8, argument, "--locked")) {
            locked = true;
        } else if (std.mem.eql(u8, argument, "--features")) {
            const spec = try flagValue(args, &index, "--features", stderr);
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) try features.append(allocator, trimmed);
            }
        } else if (std.mem.eql(u8, argument, "--no-default-features")) {
            no_default_features = true;
        } else if (std.mem.eql(u8, argument, "--registry")) {
            registry_url = try flagValue(args, &index, "--registry", stderr);
        } else if (std.mem.eql(u8, argument, "--v1-fixture")) {
            v1_fixture = try flagValue(args, &index, "--v1-fixture", stderr);
        } else if (std.mem.eql(u8, argument, "--allow-native-source")) {
            const spec = try flagValue(args, &index, "--allow-native-source", stderr);
            const equals = std.mem.indexOfScalar(u8, spec, '=') orelse
                return failUsage(stderr, "sync: --allow-native-source は <id>=<sha256> 形式です\n", .{});
            const id = spec[0..equals];
            const hash = spec[equals + 1 ..];
            if (!v1_types.validId(id) or !v1_types.validHash(hash)) {
                return failUsage(stderr, "sync: --allow-native-source の ID または SHA-256 が不正です\n", .{});
            }
            try v1_permissions.append(allocator, .{ .id = id, .sha256 = hash });
        } else if (std.mem.eql(u8, argument, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, argument, "--package-cache-dir")) {
            _ = try flagValue(args, &index, "--package-cache-dir", stderr);
            return failUsage(stderr, "sync: v1 では --package-cache-dir を使いません（取得元は --v1-fixture です）\n", .{});
        } else if (std.mem.eql(u8, argument, "--package-cache-clean")) {
            return failUsage(stderr, "sync: v1 では --package-cache-clean を使いません（取得元は --v1-fixture です）\n", .{});
        } else if (std.mem.eql(u8, argument, "--allow-plaintext-http")) {
            return failUsage(stderr, "sync: v1 の取得元検査は HTTPS のみです（--allow-plaintext-http は使いません）\n", .{});
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return failUsage(stderr, "sync: 不明なオプションです: {s}\n", .{argument});
        } else if (!root_set) {
            root = argument;
            root_set = true;
        } else {
            return failUsage(stderr, "sync: 不明な引数です: {s}\n", .{argument});
        }
    }

    // プロジェクト検出から lock 公開まで編集 lock を保持し、並行する
    // 旧コマンドや自動準備と直列化する。v1 クライアント自身は lock を
    // 取らないため、ここで pin 済み root handle を渡す。
    const project_root = project.findRoot(allocator, io, root) catch |err| {
        return fail(stderr, "sync: プロジェクトルートを探索できません: {s}\n", .{@errorName(err)});
    } orelse return fail(stderr, "sync: nako.toml が見つかりません（v1 プロジェクトのルートで実行してください）: {s}\n", .{root});
    defer allocator.free(project_root);

    var project_dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch |err| {
        return fail(stderr, "sync: プロジェクトルートを開けません: {s}\n", .{@errorName(err)});
    };
    var dir_owned = true;
    defer if (dir_owned) project_dir.close(io);
    var edit_guard = project.acquireEditLockDir(io, project_dir) catch |err| {
        return fail(stderr, "sync: 編集ロックを取得できません: {s}\n", .{@errorName(err)});
    };
    defer edit_guard.unlock();

    var probe = v1_entry.probeDir(allocator, io, &project_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fail(stderr, "sync: nako.toml を読めません: {s}\n", .{@errorName(err)}),
    };
    defer probe.deinit(allocator);
    switch (probe) {
        .missing => return fail(stderr, "sync: nako.toml が見つかりません: {s}\n", .{project_root}),
        .legacy => return fail(stderr, "sync: {s}: {s}\n", .{ v1_entry.legacy_manifest_message, project_root }),
        .invalid => |err| return fail(stderr, "sync: nako.toml が v1 形式として不正です（{s}）: {s}\n", .{ v1_entry.manifestDiagnostic(err), project_root }),
        .v1 => {},
    }

    const fixture_root = v1_fixture orelse
        return failUsage(stderr, "sync: v1 では --v1-fixture <dir> が必要です\n", .{});
    const registry = registry_url orelse
        (if (environ_map) |map| map.get("LNAKO_REGISTRY") else null) orelse
        "https://registry.nako.example";

    dir_owned = false; // 所有権は v1_sync -> client.run へ移る。
    v1_sync.execute(allocator, io, .{
        .project_root = project_root,
        .project_dir = project_dir,
        .fixture_root = fixture_root,
        .registry_url = registry,
        .profile = profile,
        .runtime = runtime,
        .features = features.items,
        .no_default_features = no_default_features,
        .locked = locked,
        .source_permissions = v1_permissions.items,
        .environ_map = environ_map,
        .json = json,
    }, stdout, stderr) catch |err| {
        return switch (err) {
            error.LegacyManifest => fail(stderr, "sync: {s}: {s}\n", .{ v1_entry.legacy_manifest_message, project_root }),
            error.LegacyLock => fail(stderr, "sync: {s}\n", .{v1_client.legacyLockMessage()}),
            error.LockedNotSatisfied => fail(stderr, "sync: nako.lock が現在の nako.toml / index と一致しないため --locked を満たせません\n", .{}),
            error.FixtureSourceRequired => failUsage(stderr, "sync: v1 では --v1-fixture <dir> が必要です\n", .{}),
            error.ProjectNotFound => fail(stderr, "sync: プロジェクトが見つかりません\n", .{}),
            error.InvalidManifest => fail(stderr, "sync: v1 の nako.toml を解釈できません（詳細は上の診断）\n", .{}),
            error.UnknownProfile => fail(stderr, "sync: profile を解決できません（--profile を指定してください）\n", .{}),
            error.UnknownFeature => fail(stderr, "sync: 未知の feature が指定されました\n", .{}),
            error.ResolveFailed => fail(stderr, "sync: 依存解決に失敗しました（詳細は上の診断）\n", .{}),
            error.LockIndexMismatch => fail(stderr, "sync: nako.lock と index が一致しません\n", .{}),
            error.GlobalCommandsMismatch => fail(stderr, "sync: index と検証済み ZIP の global 情報が一致しません（lock と環境は公開していません）\n", .{}),
            error.SourceNotPermitted => fail(stderr, "sync: native-source のビルドには --allow-native-source <id>=<sha256> が必要です\n", .{}),
            error.MissingBuildFile, error.InvalidBuildFile => fail(stderr, "sync: native-source に明示の build.zig がありません（ビルドを開始しません）\n", .{}),
            error.BuildDirectoryConflict => fail(stderr, "sync: native-source のビルド出力ディレクトリがアーカイブに含まれています\n", .{}),
            error.BuildUnavailable => fail(stderr, "sync: native-source のビルドに zig を起動できません\n", .{}),
            error.BuildFailed => fail(stderr, "sync: native-source のビルドが失敗しました（lock と環境は変更していません）\n", .{}),
            error.BuildTimedOut => fail(stderr, "sync: native-source のビルドが時間内に終了しませんでした\n", .{}),
            error.BuildOutputTooLarge => fail(stderr, "sync: native-source のビルド出力が上限を超えました\n", .{}),
            error.BuildOutputMissing, error.BuildOutputAmbiguous, error.UnsafeBuildOutput => fail(stderr, "sync: native-source のビルド出力を確認できません（共有ライブラリはちょうど 1 個必要です）\n", .{}),
            error.UnsupportedNativeSourceExports => fail(stderr, "sync: native-source の export は \".\" 1 個だけを扱います\n", .{}),
            error.UnsupportedHost => fail(stderr, "sync: このホストでは native-source をビルドできません\n", .{}),
            error.HashMismatch, error.LockHashMismatch => fail(stderr, "sync: 取得した .npkg の SHA-256 が一致しません（展開しません）\n", .{}),
            else => fail(stderr, "sync: v1 の同期に失敗しました: {s}\n", .{@errorName(err)}),
        };
    };
}

test "値を取るフラグは次のオプションを値として消費せず用法エラーにする" {
    const testing = std.testing;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);

    // `sync --features --json` が "--json" を feature 名として受理しない
    // ことを含め、全値フラグで次オプションの誤消費と末尾欠落を検査する。
    const flags = [_][]const u8{ "--profile", "--runtime", "--features", "--registry", "--v1-fixture", "--allow-native-source", "--package-cache-dir" };
    for (flags) |flag| {
        err.clearRetainingCapacity();
        try testing.expectError(error.Usage, run(a, testing.io, &.{flag}, null, &out.writer, &err.writer));
        try testing.expect(std.mem.indexOf(u8, err.written(), "には値が必要です") != null);

        err.clearRetainingCapacity();
        try testing.expectError(error.Usage, run(a, testing.io, &.{ flag, "--json" }, null, &out.writer, &err.writer));
        try testing.expect(std.mem.indexOf(u8, err.written(), "には値が必要です") != null);
    }
}

test "sync: 旧 manifest は旧経路へ分岐せず再作成を案内して拒否する" {
    const testing = std.testing;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        ,
    });

    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.Failed, run(a, std.testing.io, &.{ root, "--v1-fixture", root }, null, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, err.written(), "旧形式") != null);
    try testing.expect(std.mem.indexOf(u8, err.written(), "再作成") != null);
    // 旧 lock / 旧環境を生成しない。
    std.Io.Dir.cwd().access(std.testing.io, try std.fs.path.join(a, &.{ root, "nako.lock" }), .{}) catch |access_err| {
        try testing.expectEqual(error.FileNotFound, access_err);
        return;
    };
    return error.TestUnexpectedResult;
}

test "sync: v1 固定 fixture で lock と .nako/v1 環境を構築する" {
    // サブ dir から親プロジェクトを発見する通常経路を、ローカル fixture
    // （index/v1/config.json）だけで通す。外部ネットワークは使わない。
    const testing = std.testing;
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const fixture_root = try std.fs.path.join(a, &.{ root, "fixture" });
    const subdir = try std.fs.path.join(a, &.{ root, "sub", "dir" });
    try temporary.dir.createDirPath(io, "sub/dir");
    try temporary.dir.createDirPath(io, "fixture/index/v1");
    try temporary.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "schema_version = 1\n[package]\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "fixture/index/v1/config.json",
        .data =
        \\{
        \\  "schema_version": 1,
        \\  "registry_id": "nako-official",
        \\  "api_base_url": "https://api.registry.example.invalid/v1",
        \\  "artifact_base_url": "https://cdn.example.invalid/artifacts",
        \\  "allowed_external_hosts": []
        \\}
        ,
    });

    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try run(a, io, &.{ subdir, "--v1-fixture", fixture_root }, null, &out.writer, &err.writer);
    // 発見した親 root 配下に v1 lock と環境が構築される。
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ root, "nako.lock" }), .{});
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ root, ".nako", "v1", "environment.json" }), .{});
    try testing.expect(std.mem.indexOf(u8, err.written(), "v1 で") != null);
}

test "sync: 空の index は config.json 到達を診断し、lock を作らない" {
    const testing = std.testing;
    const io = std.testing.io;
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const fixture_root = try std.fs.path.join(a, &.{ root, "fixture" });
    try temporary.dir.createDirPath(io, "fixture");
    try temporary.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "schema_version = 1\n[package]\n",
    });

    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.Failed, run(a, io, &.{ root, "--v1-fixture", fixture_root }, null, &out.writer, &err.writer));
    // 空 fixture でも index の入口まで到達したことを診断で示す。
    try testing.expect(std.mem.indexOf(u8, err.written(), "index/v1/config.json") != null);
    // 失敗時に lock も環境ポインタも公開しない。
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, ".nako/v1/environment.json", .{}));
}
