const std = @import("std");
const diag = @import("diagnostics.zig");
const env_state = @import("env_state.zig");
const environment = @import("environment.zig");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const path_digest = @import("path_digest.zig");
const sync = @import("sync.zig");

const ImportConstraint = sync.ImportConstraint;
const appendScopedAlias = sync.appendScopedAlias;
const collectImportDependencies = sync.collectImportDependencies;
const collectImportDependenciesForProfile = sync.collectImportDependenciesForProfile;
const collectRootDependencyIds = sync.collectRootDependencyIds;

const testing = std.testing;

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

/// path 依存 fixture のlockを生成する。
fn fixtureLock(allocator: std.mem.Allocator, manifest_sha: []const u8, mutable_sha: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }},
        \\    "mutablePaths": [{{ "path": "deps/lib", "sha256": "{s}" }}]
        \\  }},
        \\  "packages": {{
        \\    "pkg:11111111111111111111111111111111": {{
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{ manifest_sha, mutable_sha });
}

/// `dir`（project root の handle）相対で path 依存 fixture を書く。
/// mutable path 依存の内容 digest は opened dir handle から計算するため
/// path 文字列の再解決を挟まない。
fn writeFixtureProjectDir(dir: std.Io.Dir, manifest_sha: []const u8) !void {
    const io = testing.io;
    try dir.createDirPath(io, "deps/lib/src");
    try dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    try dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "●テストとは\n  戻る\nここまで\n",
    });
    var lib_dir = try dir.openDir(io, "deps/lib", .{ .iterate = true, .follow_symlinks = true });
    defer lib_dir.close(io);
    const digest = try path_digest.digestDir(io, testing.allocator, lib_dir);
    const mutable_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer testing.allocator.free(mutable_sha);
    const lock = try fixtureLock(testing.allocator, manifest_sha, mutable_sha);
    defer testing.allocator.free(lock);
    try dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
}

fn writeFixtureProject(temporary: *std.testing.TmpDir, manifest_sha: []const u8) !void {
    try writeFixtureProjectDir(temporary.dir, manifest_sha);
}

/// deps/lib の現在内容から mutable path 用 lock を書く共通補助。
/// lock digest は作成済みの実 dir から計算するため、使用側は先に
/// fixture file をすべて配置してから呼ぶ。
fn writeMutableLibLock(temporary: *std.testing.TmpDir) !void {
    const io = testing.io;
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const lib_abs = try std.fs.path.join(testing.allocator, &.{ root, "deps/lib" });
    defer testing.allocator.free(lib_abs);
    const digest = try path_digest.digest(io, testing.allocator, lib_abs);
    const mutable_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer testing.allocator.free(mutable_sha);
    const lock = try fixtureLock(testing.allocator, manifest_sha, mutable_sha);
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
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
    const tree_digest = try path_digest.digest(io, allocator, lib_abs);
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

test "mutable source の digest 未記録 lock は sync が stale として拒否する" {
    // `mutablePaths` 導入前の旧 lock は `mutable = true` の source を
    // 持ちながら内容 digest を記録しない。dir 変更を検出できないため、
    // sync はそのまま使わず StaleLock として再解決を要求する。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try temporary.dir.createDirPath(io, "deps/lib/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "●テストとは\n  戻る\nここまで\n",
    });
    // mutablePaths を記録しない旧形式 lock を書く。
    const legacy = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}
        \\  }},
        \\  "packages": {{
        \\    "pkg:11111111111111111111111111111111": {{
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{manifest_sha});
    defer testing.allocator.free(legacy);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = legacy });

    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.StaleLock, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
}

test "sync は path 依存を参照して schema v1 の環境を構築する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);

    // environment.json を parse して契約フィールドを確認する。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const document = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), document.get("schemaVersion").?.integer);
    try testing.expectEqualStrings("default", document.get("profile").?.string);
    try testing.expectEqualStrings("lnako", document.get("runtime").?.string);
    const lib = document.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    // path 依存は宣言 dir をそのまま参照する。
    try testing.expectEqualStrings("deps/lib", lib.get("path").?.string);
    // export の source を静的走査して公開命令を記録する（path 依存でも
    // 宣言 dir を絶対化して commands 生成へ渡す）。
    const commands = lib.get("commands").?.array;
    try testing.expectEqual(@as(usize, 1), commands.items.len);
    try testing.expectEqualStrings("テスト", commands.items[0].object.get("name").?.string);

    // lockSha256 は nako.lock 実バイトの SHA-256 と一致する。
    const lock_bytes = try temporary.dir.readFileAlloc(io, "nako.lock", testing.allocator, .unlimited);
    defer testing.allocator.free(lock_bytes);
    const lock_hex = try sha256Hex(testing.allocator, lock_bytes);
    defer testing.allocator.free(lock_hex);
    const expected = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{lock_hex});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, document.get("lockSha256").?.string);

    // `.nako/environment.json` が書かれ、`current` が世代を指す。
    const written = try temporary.dir.readFileAlloc(io, ".nako/environment.json", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(report.environment_json, written);
}

test "sync は pinned project_dir handle 相対で入力を解決し root rename に追従しない" {
    // `Options.project_dir` が渡された場合、lock・manifest・`.nako`・
    // 相対 path 依存の宣言 dir は全て handle 相対で解決する。handle を
    // 開いた後に root を rename しても同じ directory を読み書きする
    // ことを確認する（path 文字列の再解決では別 dir・消失 dir へ書き
    // 得る）。
    const allocator = testing.allocator;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(allocator, app_manifest);
    defer allocator.free(manifest_sha);

    try temporary.dir.createDirPath(io, "proj");
    var project_dir = try temporary.dir.openDir(io, "proj", .{ .iterate = true, .follow_symlinks = false });
    defer project_dir.close(io);
    try writeFixtureProjectDir(project_dir, manifest_sha);

    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const stale_root = try std.fs.path.join(allocator, &.{ root, "proj" });
    defer allocator.free(stale_root);

    // pinned handle を開いた後に root を rename する。
    try std.Io.Dir.rename(temporary.dir, "proj", temporary.dir, "proj2", io);

    var list = diag.List.init(allocator);
    defer list.deinit();
    var report = try sync.run(allocator, io, .{
        .project_root = stale_root,
        .project_dir = project_dir,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);
    // 環境は rename 後の dir（pinned handle 配下）に公開され、
    // 古い path 側へは何も書かれない。
    const written = try temporary.dir.readFileAlloc(io, "proj2/.nako/environment.json", allocator, .unlimited);
    defer allocator.free(written);
    try testing.expectEqualStrings(report.environment_json, written);
    try testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "proj", .{}));
}

test "sync は実在しない export target を環境へ公開せず拒否する" {
    const io = testing.io;
    // commands.json を明示すると source export 走査を迂回する経路でも、
    // env.json が不在 file・dir を指さないよう選択 target の実 file 性を
    // 公開前に検証する。
    for ([_][]const u8{ "src/missing.nako3", "src" }) |export_path| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const lib_toml = try std.fmt.allocPrint(testing.allocator,
            \\[package]
            \\name = "lib"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
            \\[[exports]]
            \\name = "lib"
            \\path = "{s}"
            \\
        , .{export_path});
        defer testing.allocator.free(lib_toml);
        // `src` は dir として存在するが file ではない（2 例目）。
        try temporary.dir.createDirPath(io, "deps/lib/src");
        try temporary.dir.createDirPath(io, "deps/lib/NAKO-PKG");
        try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_toml });
        try temporary.dir.writeFile(io, .{
            .sub_path = "deps/lib/NAKO-PKG/commands.json",
            .data = "{\"schemaVersion\":1,\"commands\":[]}\n",
        });
        try writeMutableLibLock(&temporary);

        const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
        defer testing.allocator.free(cache_root);
        var list = diag.List.init(testing.allocator);
        defer list.deinit();
        try testing.expectError(error.InvalidMetadata, sync.run(testing.allocator, io, .{
            .project_root = root,
            .cache_root = cache_root,
        }, &list));
    }
}

test "sync は未対応の resolverVersion を LockInvalid で拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    // nako.toml を持つ正規 fixture でも、lock の resolverVersion が未対応なら
    // manifest 再解決を経由しない sync 経路の検証で拒否する。
    const lock_bytes = try temporary.dir.readFileAlloc(io, "nako.lock", testing.allocator, .unlimited);
    defer testing.allocator.free(lock_bytes);
    const replaced = try std.mem.replaceOwned(u8, testing.allocator, lock_bytes, "\"resolverVersion\": 1", "\"resolverVersion\": 999");
    defer testing.allocator.free(replaced);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = replaced });

    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.LockInvalid, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
}

test "sync は manifest との不整合な lock を StaleLock で拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeFixtureProject(&temporary, "0000000000000000000000000000000000000000000000000000000000000000");
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.StaleLock, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    // 環境は一切構築されない。
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は失敗時に直前の有効環境を保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer first.deinit();
    const first_json = try testing.allocator.dupe(u8, first.environment_json);
    defer testing.allocator.free(first_json);

    // 未知の profile を要求して失敗させる。
    try testing.expectError(error.UnknownProfile, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
        .profile = "nonexistent",
    }, &list));

    // 直前の environment.json がそのまま残る。
    const written = try temporary.dir.readFileAlloc(io, ".nako/environment.json", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(first_json, written);
}

test "sync は offline で http 依存の未取得を拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    const lock = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}
        \\  }},
        \\  "packages": {{
        \\    "pkg:22222222222222222222222222222222": {{
        \\      "id": "pkg:22222222222222222222222222222222",
        \\      "name": "remote",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "http", "url": "http://127.0.0.1:1/pkg.npkg", "hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": ".npkg", "sha256": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "url": "http://127.0.0.1:1/pkg.npkg" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{manifest_sha});
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.Offline, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
        .policy = .{ .offline = true },
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は current が欠損しても公開済み世代を environment.json から保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    const first_gen = try testing.allocator.dupe(u8, first.generation);
    defer testing.allocator.free(first_gen);
    first.deinit();

    // current 更新失敗・中断と同等の状態（公開済みだが current が無い）。
    try temporary.dir.deleteFile(io, ".nako/current");

    var second = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // current が無くても environment.json の参照から前世代が保持される。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
}

test "sync は明示 commands.json 同梱でも source の .nako import を拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // `commands.json` は index であり、同梱しても source export 起点の
    // import 閉包走査を迂回しない。`.nako` は pin・digest 対象外のため、
    // index 経由で未 pin 内容への取り込みを隠せてはいけない。
    try temporary.dir.createDirPath(io, "deps/lib/src/.nako");
    try temporary.dir.createDirPath(io, "deps/lib/NAKO-PKG");
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "「.nako/helper.nako3」を取り込む\n●テストとは\n  戻る\nここまで\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/.nako/helper.nako3",
        .data = "●補助とは\n  戻る\nここまで\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/NAKO-PKG/commands.json",
        .data = "{\"schemaVersion\":1,\"commands\":[]}\n",
    });
    try writeMutableLibLock(&temporary);

    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.InvalidMetadata, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は代表実装と個別解決が異なる export を両方記録する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // lock の代表実装 `native` は artifact 選択と `prefer-native` 方針を
    // 示すだけで、個別 export の解決結果を縛らない。source-only export
    // （pure）と native 併記 export（dual）を両方 env.json へ記録する。
    const dual_manifest =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "pure"
        \\path = "src/pure.nako3"
        \\
        \\[[exports]]
        \\name = "dual"
        \\path = "src/dual.nako3"
        \\native = "native/dual.so"
        \\
    ;
    try temporary.dir.createDirPath(io, "deps/lib/src");
    try temporary.dir.createDirPath(io, "deps/lib/native");
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = dual_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/pure.nako3",
        .data = "●ピュアとは\n  戻る\nここまで\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/dual.nako3",
        .data = "●デュアルとは\n  戻る\nここまで\n",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/native/dual.so", .data = "stub-native\n" });

    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const lib_abs = try std.fs.path.join(testing.allocator, &.{ root, "deps/lib" });
    defer testing.allocator.free(lib_abs);
    const tree_digest = try path_digest.digest(io, testing.allocator, lib_abs);
    const mutable_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(tree_digest, .lower)});
    defer testing.allocator.free(mutable_sha);
    const lock_bytes = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}, "mutablePaths": [{{ "path": "deps/lib", "sha256": "{s}" }}] }},
        \\  "packages": {{ "pkg:11111111111111111111111111111111": {{
        \\    "id": "pkg:11111111111111111111111111111111", "name": "lib", "version": "1.0.0",
        \\    "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\    "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\    "dependencies": [], "features": [], "implementation": "native",
        \\    "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\  }} }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ manifest_sha, mutable_sha });
    defer testing.allocator.free(lock_bytes);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });

    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list);
    defer report.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const lib = parsed.value.object.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    const exports = lib.get("exports").?.array;
    try testing.expectEqual(@as(usize, 2), exports.items.len);
    try testing.expectEqualStrings("pure", exports.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("src/pure.nako3", exports.items[0].object.get("path").?.string);
    // `prefer-native` 方針で dual は native target へ解決される。
    try testing.expectEqualStrings("dual", exports.items[1].object.get("name").?.string);
    try testing.expectEqualStrings("native/dual.so", exports.items[1].object.get("path").?.string);
}

test "sync は読取不能な nako.toml を欠落扱いせず失敗する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    // manifest 無し（FileNotFound）のみ hash 検証を省略できる。dir 化
    // した `nako.toml` は存在するのに読めないため、検証を省略して古い
    // lock のまま環境を公開しない。
    try temporary.dir.deleteFile(io, "nako.toml");
    try temporary.dir.createDirPath(io, "nako.toml");

    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);
    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.FileSystem, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は再実行で世代を更新し直前世代を保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    const first_gen = try testing.allocator.dupe(u8, first.generation);
    defer testing.allocator.free(first_gen);
    first.deinit();

    var second = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // 直前世代 dir が残っている。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
}

test "sync は package 宣言に無い mutablePaths record を含む lock を拒否する" {
    // `mutablePaths` は lock 作者が任意に追記できる。宣言済み package の
    // mutable path source 集合と完全一致するかを digest 前に検証しない
    // と、`..`/絶対 path の余分な record で任意 dir の深い再帰読取を
    // 強要される。digest が一致する実在 dir への record であっても
    // 受理してはいけない。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // project 外に実在する dir を用意し、その正しい digest を持つ
    // `../outside` record を差し込む。
    try temporary.dir.createDirPath(io, "outside");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/payload.txt", .data = "payload" });
    const outside_abs = try temporary.dir.realPathFileAlloc(io, "outside", testing.allocator);
    defer testing.allocator.free(outside_abs);
    const outside_digest = try path_digest.digest(io, testing.allocator, outside_abs);
    const outside_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(outside_digest, .lower)});
    defer testing.allocator.free(outside_sha);
    const lib_abs = try std.fs.path.join(testing.allocator, &.{ root, "deps/lib" });
    defer testing.allocator.free(lib_abs);
    const lib_digest = try path_digest.digest(io, testing.allocator, lib_abs);
    const lib_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(lib_digest, .lower)});
    defer testing.allocator.free(lib_sha);
    const lock = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }},
        \\    "mutablePaths": [
        \\      {{ "path": "deps/lib", "sha256": "{s}" }},
        \\      {{ "path": "../outside", "sha256": "{s}" }}
        \\    ]
        \\  }},
        \\  "packages": {{
        \\    "pkg:11111111111111111111111111111111": {{
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "dependencies": [],
        \\      "features": [],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{ manifest_sha, lib_sha, outside_sha });
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.StaleLock, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は構築中に nako.toml が変更されると環境を公開しない" {
    // 開始時の manifestSha256 照合だけでは、package 取得・展開中に
    // 外部エディタが manifest を保存した変更を拾えず、旧 lock に対応
    // する環境を公開してしまう。`.lnako-work-<gen>`（公開直前の検査より
    // 前にだけ存在する workspace dir）の出現を合図に別 thread から
    // manifest を上書きし、公開直前の再照合で StaleLock に至ることと
    // 環境が公開されないことを検証する。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256Hex(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var stop = std.atomic.Value(bool).init(false);
    var written = std.atomic.Value(bool).init(false);
    const Watcher = struct {
        root_path: []const u8,
        stop_flag: *std.atomic.Value(bool),
        wrote: *std.atomic.Value(bool),
        fn run(self: *const @This()) void {
            // sync.run の testing.io と直列化しないよう実 io を使う。
            const wio = std.Io.Threaded.global_single_threaded.io();
            var dir = std.Io.Dir.cwd().openDir(wio, self.root_path, .{ .iterate = true }) catch return;
            defer dir.close(wio);
            while (!self.stop_flag.load(.acquire)) {
                var iterator = dir.iterate();
                while (iterator.next(wio) catch null) |entry| {
                    if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, ".lnako-work-")) {
                        dir.writeFile(wio, .{
                            .sub_path = "nako.toml",
                            .data = "[package]\nname = \"tampered\"\nversion = \"9.9.9\"\nlicense = \"MIT\"\n",
                        }) catch {};
                        self.wrote.store(true, .release);
                        return;
                    }
                }
            }
        }
    };
    const watcher = Watcher{ .root_path = root, .stop_flag = &stop, .wrote = &written };
    const thread = std.Thread.spawn(.{}, Watcher.run, .{&watcher}) catch null;
    defer if (thread) |t| t.join();
    defer stop.store(true, .release);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    if (thread == null) return error.SkipZigTest;
    try testing.expectError(error.StaleLock, sync.run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &list));
    // watcher が workspace 出現中に書込みに成功した（= 公開直前の
    // 再照合が実行区間内だった）ことを確認する。
    try testing.expect(written.load(.acquire));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
}

test "sync は immutable path 依存を世代内へ materialize する" {
    // `mutable = false` の path 依存は pin 済み snapshot を
    // `.nako/env/<gen>/deps` へ複製し environment.json がそちらを指す。
    // 宣言 dir を生参照したままだと sync 後の編集が lock を変えずに
    // `--no-sync` 消費者へ未 pin の内容を届けてしまう。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDirPath(io, "deps/lib/src");
    // digest 対象外の管理 dir は複製されないことの確認用に置く。
    try temporary.dir.createDirPath(io, "deps/lib/.git");
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/.git/HEAD", .data = "ref\n" });
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
    const tree_digest = try path_digest.digest(io, allocator, lib_abs);
    const pin_sha = try std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(tree_digest, .lower)});
    defer allocator.free(pin_sha);
    const manifest_sha = try sha256Hex(allocator, app_manifest);
    defer allocator.free(manifest_sha);

    const lock_bytes = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{ "pkg:11111111111111111111111111111111": {{
        \\    "id": "pkg:11111111111111111111111111111111", "name": "lib", "version": "1.0.0",
        \\    "source": {{ "type": "path", "path": "deps/lib", "mutable": false }},
        \\    "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": false }},
        \\    "dependencies": [], "features": [], "artifacts": {{ "source": {{ "kind": "source", "type": "raw", "sha256": "{s}" }} }}
        \\  }} }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ manifest_sha, pin_sha });
    defer allocator.free(lock_bytes);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });

    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var report = try sync.run(allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &diagnostics);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.package_count);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, report.environment_json, .{});
    defer parsed.deinit();
    const lib = parsed.value.object.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    const env_path = lib.get("path").?.string;
    // 宣言 dir `deps/lib` ではなく世代内の複製を指す。
    try std.testing.expect(!std.mem.eql(u8, env_path, "deps/lib"));
    try std.testing.expect(std.mem.indexOf(u8, env_path, ".nako") != null);
    try std.testing.expect(std.mem.indexOf(u8, env_path, "deps") != null);
    // 複製先に source があり、digest 対象外の `.git` は持ち込まれない。
    const copied_index = try std.fs.path.join(allocator, &.{ env_path, "src", "index.nako3" });
    defer allocator.free(copied_index);
    const copied = try temporary.dir.readFileAlloc(io, copied_index, allocator, .unlimited);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("●テストとは\n  戻る\nここまで\n", copied);
    const git_dir = try std.fs.path.join(allocator, &.{ env_path, ".git" });
    defer allocator.free(git_dir);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, git_dir, .{}));

    // 生成した環境は packages 検査を通過する。immutable path 依存の記録
    // path は宣言 dir ではなく現行世代の管理 dir を指す契約のため、
    // sync 直後から usable でなければならない。
    var parsed_lock = try lock_mod.parse(allocator, lock_bytes, &diagnostics);
    defer parsed_lock.deinit();
    try std.testing.expect(try env_state.environmentPackagesUsable(allocator, io, root, &parsed_lock, "default"));
}

test "sync は directory symlink 宣言の immutable path 依存を受理する" {
    // path_digest は宣言 root のみ symlink を follow するため、root が
    // directory symlink の immutable path 依存は lock 生成・鮮度検査で
    // 正当な構成として扱われる。materialize 時も root のみ follow して
    // 固定 handle 化し、内部 entry は no-follow のまま複製する。
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDirPath(io, "deps/lib/src");
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
    temporary.dir.symLink(io, lib_abs, "deps/lib-link", .{}) catch return error.SkipZigTest;

    // digest は宣言 root（symlink）を follow して実体 tree と一致する。
    const link_abs = try std.fs.path.join(allocator, &.{ root, "deps/lib-link" });
    defer allocator.free(link_abs);
    const tree_digest = try path_digest.digest(io, allocator, link_abs);
    const pin_sha = try std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(tree_digest, .lower)});
    defer allocator.free(pin_sha);
    const manifest_sha = try sha256Hex(allocator, app_manifest);
    defer allocator.free(manifest_sha);

    const lock_bytes = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1, "resolverVersion": 1,
        \\  "input": {{ "manifestSha256": "sha256:{s}", "profile": "default", "features": [], "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }} }},
        \\  "packages": {{ "pkg:11111111111111111111111111111111": {{
        \\    "id": "pkg:11111111111111111111111111111111", "name": "lib", "version": "1.0.0",
        \\    "source": {{ "type": "path", "path": "deps/lib-link", "mutable": false }},
        \\    "resolvedFrom": {{ "type": "path", "path": "deps/lib-link", "mutable": false }},
        \\    "dependencies": [], "features": [], "artifacts": {{ "source": {{ "kind": "source", "type": "raw", "sha256": "{s}" }} }}
        \\  }} }},
        \\  "profiles": {{ "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }} }}
        \\}}
    , .{ manifest_sha, pin_sha });
    defer allocator.free(lock_bytes);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });

    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();
    var report = try sync.run(allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
    }, &diagnostics);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.package_count);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, report.environment_json, .{});
    defer parsed.deinit();
    const lib = parsed.value.object.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    const env_path = lib.get("path").?.string;
    const copied_index = try std.fs.path.join(allocator, &.{ env_path, "src", "index.nako3" });
    defer allocator.free(copied_index);
    const copied = try temporary.dir.readFileAlloc(io, copied_index, allocator, .unlimited);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("●テストとは\n  戻る\nここまで\n", copied);
}

// ---------------------------------------------------------------------------
// package import 依存 alias（lock edge scope・namespace 衝突）の検証
// ---------------------------------------------------------------------------

test "Git package import constraintは短縮commitをlockのfull SHA prefixで照合する" {
    const full_commit = "abc1234def567890123456789012345678901234";
    const candidate = lock_model.PackageEntry{
        .id = "pkg:git-lib",
        .name = "lib",
        .version = "1.0.0",
        .source = .{ .kind = .git, .url = "https://example.test/lib.git", .commit = full_commit },
    };
    try testing.expect((ImportConstraint{ .git = .{ .url = "https://example.test/lib.git", .commit = "abc1234", .path = null } }).matches(candidate));
    try testing.expect(!(ImportConstraint{ .git = .{ .url = "https://example.test/lib.git", .commit = "abc1235", .path = null } }).matches(candidate));
    try testing.expect(!(ImportConstraint{ .git = .{ .url = "https://other.test/lib.git", .commit = "abc1234", .path = null } }).matches(candidate));
}

test "profile限定package import aliasは共有package IDでも選択profile外で公開しない" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\"@alice/shared" = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111" }
        \\shared = { version = "1.0.0", public-id = "pkg:11111111111111111111111111111111", profile = "windows", alias = "win-shared" }
        \\
        \\[profiles.windows]
        \\os = "windows"
        \\cpu = "x86_64"
        \\abi = "msvc"
        \\
    ;
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:11111111111111111111111111111111", .name = "shared", .version = "1.0.0", .source = .{ .kind = .registry } },
    };
    const allowed_ids = [_][]const u8{"pkg:11111111111111111111111111111111"};

    const aliases = try collectImportDependenciesForProfile(testing.allocator, &lock_entries, &allowed_ids, null, &manifest, "linux", &diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 2), aliases.len);
    try testing.expect(containsImportDependency(aliases, "@alice/shared", "pkg:11111111111111111111111111111111"));
    try testing.expect(containsImportDependency(aliases, "shared", "pkg:11111111111111111111111111111111"));
    try testing.expect(!containsImportDependency(aliases, "win-shared", "pkg:11111111111111111111111111111111"));

    var missing_edge_diagnostics = diag.List.init(testing.allocator);
    defer missing_edge_diagnostics.deinit();
    const no_root_edges: [0][]const u8 = .{};
    try testing.expectError(
        error.LockInvalid,
        collectImportDependenciesForProfile(testing.allocator, &lock_entries, &no_root_edges, null, &manifest, "linux", &missing_edge_diagnostics),
    );
    try testing.expect(missing_edge_diagnostics.hasErrors());
}

test "lock edge外のdependency診断はroot scopeとtransitive scopeを区別する" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\shared = { version = "1.0.0" }
        \\
    ;
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:11111111111111111111111111111111", .name = "shared", .version = "1.0.0", .source = .{ .kind = .registry } },
    };
    const empty_edges: [0][]const u8 = .{};

    var root_diagnostics = diag.List.init(testing.allocator);
    defer root_diagnostics.deinit();
    try testing.expectError(
        error.LockInvalid,
        collectImportDependenciesForProfile(testing.allocator, &lock_entries, &empty_edges, null, &manifest, null, &root_diagnostics),
    );
    try testing.expectEqualStrings("nako.lock.rootDependencies", root_diagnostics.items.items[0].path);
    try testing.expect(std.mem.indexOf(u8, root_diagnostics.items.items[0].message, "rootDependencies") != null);

    var transitive_diagnostics = diag.List.init(testing.allocator);
    defer transitive_diagnostics.deinit();
    try testing.expectError(
        error.LockInvalid,
        collectImportDependenciesForProfile(testing.allocator, &lock_entries, &empty_edges, "consumer", &manifest, null, &transitive_diagnostics),
    );
    try testing.expectEqualStrings("nako.lock", transitive_diagnostics.items.items[0].path);
    try testing.expect(std.mem.indexOf(u8, transitive_diagnostics.items.items[0].message, "\"consumer\"") != null);
    try testing.expect(std.mem.indexOf(u8, transitive_diagnostics.items.items[0].message, "rootDependencies") == null);
}

test "一致候補を持たない有効依存はroot scopeとtransitive scopeでLockInvalidになる" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\shared = { version = "1.0.0" }
        \\
    ;
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();
    // lock 内に "shared" に一致する package が一つも無い（edge list 省略の
    // schema-v1相当）。宣言された有効な依存に対して lock が候補を提供しない
    // のは不整合であり、alias を欠落させた環境を公開してはならない。
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:99999999999999999999999999999999", .name = "other", .version = "1.0.0", .source = .{ .kind = .registry } },
    };

    var root_diagnostics = diag.List.init(testing.allocator);
    defer root_diagnostics.deinit();
    try testing.expectError(
        error.LockInvalid,
        collectImportDependenciesForProfile(testing.allocator, &lock_entries, null, null, &manifest, null, &root_diagnostics),
    );
    try testing.expectEqualStrings("nako.lock.rootDependencies", root_diagnostics.items.items[0].path);
    try testing.expect(std.mem.indexOf(u8, root_diagnostics.items.items[0].message, "no matching lock package") != null);

    var transitive_diagnostics = diag.List.init(testing.allocator);
    defer transitive_diagnostics.deinit();
    try testing.expectError(
        error.LockInvalid,
        collectImportDependenciesForProfile(testing.allocator, &lock_entries, null, "consumer", &manifest, null, &transitive_diagnostics),
    );
    try testing.expectEqualStrings("nako.lock", transitive_diagnostics.items.items[0].path);
    try testing.expect(std.mem.indexOf(u8, transitive_diagnostics.items.items[0].message, "\"consumer\"") != null);
}

test "root package import候補は直接依存のversion rangeで絞る" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\lib = { version = ">=1.0.0" }
        \\
    ;
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();

    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:direct-lib", .name = "lib", .version = "1.4.0", .source = .{ .kind = .registry } },
        .{ .id = "pkg:transitive-lib", .name = "lib", .version = "1.2.0", .source = .{ .kind = .registry } },
        .{ .id = "pkg:parent", .name = "parent", .version = "1.0.0", .source = .{ .kind = .registry }, .dependencies = &.{"pkg:transitive-lib"} },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const direct_ids = try collectRootDependencyIds(testing.allocator, &lock_entries, &manifest, &sync_diagnostics);
    defer testing.allocator.free(direct_ids);
    try testing.expectEqual(@as(usize, 1), direct_ids.len);
    try testing.expectEqualStrings("pkg:direct-lib", direct_ids[0]);

    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, direct_ids, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 1), aliases.len);
    try testing.expectEqualStrings("pkg:direct-lib", aliases[0].package_key);
}

test "package import aliasはmanifest依存scopeごとにlock keyへ解決される" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\source-dep = { path = "../dep" }
        \\
    ;
    var diagnostics = diag.List.init(testing.allocator);
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();

    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:dep-id", .name = "package-manifest-name", .version = "1.0.0", .source = .{ .kind = .path, .path = "../dep" } },
        .{ .id = "pkg:other-id", .name = "other", .version = "1.0.0", .source = .{ .kind = .path, .path = "../other" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const root_aliases = try collectImportDependencies(testing.allocator, &lock_entries, null, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(root_aliases);
    try testing.expectEqual(@as(usize, 1), root_aliases.len);

    const package_dependencies = [_][]const u8{"pkg:dep-id"};
    const scoped_aliases = try collectImportDependencies(testing.allocator, &lock_entries, &package_dependencies, "owner-pkg", &manifest, &sync_diagnostics);
    defer testing.allocator.free(scoped_aliases);
    try testing.expectEqual(@as(usize, 1), scoped_aliases.len);
    try testing.expectEqualStrings("source-dep", scoped_aliases[0].alias);
    try testing.expectEqualStrings("pkg:dep-id", scoped_aliases[0].package_key);
}

fn containsSyncString(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

fn containsImportDependency(items: []const environment.ImportDependency, alias: []const u8, package_key: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.alias, alias) and std.mem.eql(u8, item.package_key, package_key)) return true;
    return false;
}

fn containsImportAlias(items: []const environment.ImportDependency, alias: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.alias, alias)) return true;
    return false;
}

test "registry owner/name keyはownerとexplicit aliasでlock entryへ対応する" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\"alice/lib" = { version = "^1.0.0", alias = "alice-lib" }
        \\"bob/lib" = { version = "^1.0.0", alias = "bob-lib" }
        \\"@alice/tool" = { version = "^2.0.0" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &parse_diagnostics);
    defer manifest.deinit();

    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:alice-lib", .name = "lib", .version = "1.4.0", .source = .{ .kind = .static, .url = "https://registry.test/alice/lib" } },
        .{ .id = "pkg:bob-lib", .name = "lib", .version = "1.2.0", .source = .{ .kind = .static, .url = "https://registry.test/bob/lib" } },
        .{ .id = "pkg:alice-tool", .name = "tool", .version = "2.1.0", .source = .{ .kind = .static, .url = "https://registry.test/alice/tool" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const roots = try collectRootDependencyIds(testing.allocator, &lock_entries, &manifest, &sync_diagnostics);
    defer testing.allocator.free(roots);
    try testing.expectEqual(@as(usize, 3), roots.len);
    try testing.expect(containsSyncString(roots, "pkg:alice-lib"));
    try testing.expect(containsSyncString(roots, "pkg:bob-lib"));
    try testing.expect(containsSyncString(roots, "pkg:alice-tool"));

    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, roots, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 6), aliases.len);
    try testing.expect(containsImportDependency(aliases, "alice-lib", "pkg:alice-lib"));
    try testing.expect(containsImportDependency(aliases, "alice/lib", "pkg:alice-lib"));
    try testing.expect(containsImportDependency(aliases, "bob-lib", "pkg:bob-lib"));
    try testing.expect(containsImportDependency(aliases, "bob/lib", "pkg:bob-lib"));
    try testing.expect(containsImportDependency(aliases, "tool", "pkg:alice-tool"));
    try testing.expect(containsImportDependency(aliases, "@alice/tool", "pkg:alice-tool"));
    try testing.expect(!containsImportAlias(aliases, "lib"));
}

test "owner/nameのderived aliasは通常の依存キーとの衝突順に依存しない" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\"alice/lib" = { version = "^2.0.0" }
        \\lib = { version = "^1.0.0" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &parse_diagnostics);
    defer manifest.deinit();
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:alice-lib", .name = "lib", .version = "2.4.0", .source = .{ .kind = .static, .url = "https://registry.test/alice/lib" } },
        .{ .id = "pkg:plain-lib", .name = "lib", .version = "1.2.0", .source = .{ .kind = .static, .url = "https://registry.test/lib" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, null, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 2), aliases.len);
    try testing.expect(containsImportDependency(aliases, "alice/lib", "pkg:alice-lib"));
    try testing.expect(containsImportDependency(aliases, "lib", "pkg:plain-lib"));
}

test "owner/nameのderived aliasは他依存のexplicit aliasに優先しない" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\"alice/lib" = { version = "^1.0.0" }
        \\plain-key = { version = "^1.0.0", alias = "lib" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &parse_diagnostics);
    defer manifest.deinit();
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:alice-lib", .name = "lib", .version = "1.4.0", .source = .{ .kind = .static, .url = "https://registry.test/alice/lib" } },
        .{ .id = "pkg:plain", .name = "plain-key", .version = "1.2.0", .source = .{ .kind = .static, .url = "https://registry.test/plain-key" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, null, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 3), aliases.len);
    try testing.expect(containsImportDependency(aliases, "alice/lib", "pkg:alice-lib"));
    try testing.expect(containsImportDependency(aliases, "plain-key", "pkg:plain"));
    try testing.expect(containsImportDependency(aliases, "lib", "pkg:plain"));
}

test "同じleafを持つregistry owner/nameのderived aliasだけを省く" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\"alice/lib" = { version = "^1.0.0" }
        \\"bob/lib" = { version = "^1.0.0" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &parse_diagnostics);
    defer manifest.deinit();
    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:alice-lib", .name = "lib", .version = "1.4.0", .source = .{ .kind = .static, .url = "https://registry.test/alice/lib" } },
        .{ .id = "pkg:bob-lib", .name = "lib", .version = "1.2.0", .source = .{ .kind = .static, .url = "https://registry.test/bob/lib" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, null, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    try testing.expectEqual(@as(usize, 2), aliases.len);
    try testing.expect(containsImportDependency(aliases, "alice/lib", "pkg:alice-lib"));
    try testing.expect(containsImportDependency(aliases, "bob/lib", "pkg:bob-lib"));
    try testing.expect(!containsImportAlias(aliases, "lib"));
}

test "path git http dependencyはtable keyとpackage nameが異なってもsource条件で解決する" {
    const source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\local-key = { path = "../local" }
        \\
        \\[dependencies.git]
        \\git-key = { url = "https://example.test/git.git", commit = "abc1234", alias = "git-alias" }
        \\
        \\[dependencies.http]
        \\http-key = { url = "https://example.test/archive.tar", hash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", alias = "http-alias" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &parse_diagnostics);
    defer manifest.deinit();

    const lock_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:path-id", .name = "some-other-path-name", .version = "1.0.0", .source = .{ .kind = .path, .path = "../local" } },
        .{ .id = "pkg:git-id", .name = "some-other-git-name", .version = "1.0.0", .source = .{ .kind = .git, .url = "https://example.test/git.git", .commit = "abc1234ff" } },
        .{ .id = "pkg:http-id", .name = "some-other-http-name", .version = "1.0.0", .source = .{ .kind = .http, .url = "https://example.test/archive.tar", .hash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } },
    };
    var sync_diagnostics = diag.List.init(testing.allocator);
    defer sync_diagnostics.deinit();
    const aliases = try collectImportDependencies(testing.allocator, &lock_entries, null, null, &manifest, &sync_diagnostics);
    defer testing.allocator.free(aliases);
    const expectations = [_]struct { alias: []const u8, id: []const u8 }{
        .{ .alias = "local-key", .id = "pkg:path-id" },
        .{ .alias = "git-alias", .id = "pkg:git-id" },
        .{ .alias = "http-alias", .id = "pkg:http-id" },
    };
    for (expectations) |expected| {
        var found = false;
        for (aliases) |dependency| if (std.mem.eql(u8, dependency.alias, expected.alias) and std.mem.eql(u8, dependency.package_key, expected.id)) {
            found = true;
            break;
        };
        try testing.expect(found);
    }
}

test "syncは曖昧なlock候補とalias衝突を診断する" {
    const ambiguous_source =
        \\[package]
        \\name = "consumer"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\local = { path = "../local" }
        \\
    ;
    var parse_diagnostics = diag.List.init(testing.allocator);
    defer parse_diagnostics.deinit();
    var ambiguous_manifest = try manifest_mod.parse(testing.allocator, ambiguous_source, &parse_diagnostics);
    defer ambiguous_manifest.deinit();
    const ambiguous_entries = [_]lock_model.PackageEntry{
        .{ .id = "pkg:local-one", .name = "one", .version = "1.0.0", .source = .{ .kind = .path, .path = "../local" } },
        .{ .id = "pkg:local-two", .name = "two", .version = "1.0.0", .source = .{ .kind = .path, .path = "../local" } },
    };
    const allowed = [_][]const u8{ "pkg:local-one", "pkg:local-two" };
    var ambiguous_diagnostics = diag.List.init(testing.allocator);
    defer ambiguous_diagnostics.deinit();
    try testing.expectError(error.LockInvalid, collectImportDependencies(testing.allocator, &ambiguous_entries, &allowed, null, &ambiguous_manifest, &ambiguous_diagnostics));
    try testing.expectEqual(@as(usize, 1), ambiguous_diagnostics.items.items.len);
    try testing.expect(std.mem.indexOf(u8, ambiguous_diagnostics.items.items[0].message, "local-one") != null);
    try testing.expect(std.mem.indexOf(u8, ambiguous_diagnostics.items.items[0].message, "local-two") != null);

    var collision_result: std.ArrayListUnmanaged(environment.ImportDependency) = .empty;
    defer collision_result.deinit(testing.allocator);
    var collision_diagnostics = diag.List.init(testing.allocator);
    defer collision_diagnostics.deinit();
    try appendScopedAlias(testing.allocator, &collision_result, "shared", "pkg:git-a", &collision_diagnostics);
    try testing.expectError(error.LockInvalid, appendScopedAlias(testing.allocator, &collision_result, "shared", "pkg:http-b", &collision_diagnostics));
    try testing.expectEqual(@as(usize, 1), collision_diagnostics.items.items.len);
    try testing.expect(std.mem.indexOf(u8, collision_diagnostics.items.items[0].message, "shared") != null);
    try testing.expect(std.mem.indexOf(u8, collision_diagnostics.items.items[0].message, "pkg:git-a") != null);
    try testing.expect(std.mem.indexOf(u8, collision_diagnostics.items.items[0].message, "pkg:http-b") != null);
}

test "sync は implementation=none の support package を空dirで公開しimport検証を通過する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const support_manifest =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.pkg]
        \\support = { version = "1.0.0" }
        \\
    ;
    const manifest_sha = try sha256Hex(testing.allocator, support_manifest);
    defer testing.allocator.free(manifest_sha);
    const lock = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }}
        \\  }},
        \\  "packages": {{
        \\    "pkg:22222222222222222222222222222222": {{
        \\      "id": "pkg:22222222222222222222222222222222",
        \\      "name": "support",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "static", "url": "https://registry.test/support" }},
        \\      "resolvedFrom": {{ "type": "static", "url": "https://registry.test/support" }},
        \\      "dependencies": [],
        \\      "implementation": "none",
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "tar.gz", "sha256": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "url": "https://registry.test/support/source.tar.gz" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako" }}
        \\  }}
        \\}}
    , .{manifest_sha});
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = support_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer report.deinit();

    // `none` は artifact を取得せず空の materialized dir を公開する。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const support = parsed.value.object.get("packages").?.object.get("pkg:22222222222222222222222222222222").?.object;
    const env_path = support.get("path").?.string;
    try testing.expect(std.mem.startsWith(u8, env_path, ".nako/env/"));
    try testing.expect(std.mem.endsWith(u8, env_path, "/deps/support"));
    if (support.get("exports")) |exports| {
        try testing.expectEqual(@as(usize, 0), exports.array.items.len);
    }
    try temporary.dir.access(io, env_path, .{});

    // import 解決も lock の support record と一致して受理する。
    var loaded = try @import("import_resolver.zig").Resolver.load(testing.allocator, io, root);
    defer loaded.deinit();
}

test "sync/import双方がlockのpackage featuresをexport解決へ反映する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const feature_manifest =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "deps/lib" }
        \\
    ;
    const feature_lib_manifest =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[features]
        \\simd = []
        \\
        \\[[exports]]
        \\name = "lib"
        \\esm = [{ path = "x.mjs", features = ["simd"] }]
        \\
    ;
    const manifest_sha = try sha256Hex(testing.allocator, feature_manifest);
    defer testing.allocator.free(manifest_sha);
    try temporary.dir.createDirPath(io, "deps/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = feature_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = feature_lib_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/x.mjs", .data = "export {};\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    // mutable path 依存は lock の `mutablePaths` digest と一致が前提。
    const lib_abs = try std.fs.path.join(testing.allocator, &.{ root, "deps/lib" });
    defer testing.allocator.free(lib_abs);
    const lib_digest = try path_digest.digest(io, testing.allocator, lib_abs);
    const mutable_sha = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{std.fmt.bytesToHex(lib_digest, .lower)});
    defer testing.allocator.free(mutable_sha);
    const lock = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "resolverVersion": 1,
        \\  "input": {{
        \\    "manifestSha256": "sha256:{s}",
        \\    "profile": "default",
        \\    "features": [],
        \\    "target": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu" }},
        \\    "mutablePaths": [{{ "path": "deps/lib", "sha256": "{s}" }}]
        \\  }},
        \\  "packages": {{
        \\    "pkg:11111111111111111111111111111111": {{
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "source": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "resolvedFrom": {{ "type": "path", "path": "deps/lib", "mutable": true }},
        \\      "dependencies": [],
        \\      "features": ["simd"],
        \\      "artifacts": {{ "source": {{ "kind": "source", "type": "raw" }} }}
        \\    }}
        \\  }},
        \\  "profiles": {{
        \\    "default": {{ "os": "macos", "cpu": "aarch64", "abi": "gnu", "runtime": "lnako", "compat-js": true }}
        \\  }}
        \\}}
    , .{ manifest_sha, mutable_sha });
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try sync.run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer report.deinit();

    // feature "simd" が lock に記録されているため、feature 必須の ESM
    // 宣言が適合して export が公開される。
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, report.environment_json, .{});
    defer parsed.deinit();
    const lib = parsed.value.object.get("packages").?.object.get("pkg:11111111111111111111111111111111").?.object;
    const exports = lib.get("exports").?.array;
    try testing.expectEqual(@as(usize, 1), exports.items.len);
    try testing.expectEqualStrings("x.mjs", exports.items[0].object.get("path").?.string);

    // import 検証も同じ feature 集合で一致しなければ拒否される。
    var loaded = try @import("import_resolver.zig").Resolver.load(testing.allocator, io, root);
    defer loaded.deinit();
}
