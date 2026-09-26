const std = @import("std");
const path_digest = @import("path_digest.zig");
const diag = @import("diagnostics.zig");
const sync = @import("sync.zig");

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

fn writeFixtureProject(temporary: *std.testing.TmpDir, manifest_sha: []const u8) !void {
    const io = testing.io;
    try temporary.dir.createDirPath(io, "deps/lib/src");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = app_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = lib_manifest });
    try temporary.dir.writeFile(io, .{
        .sub_path = "deps/lib/src/index.nako3",
        .data = "●テストとは\n  戻る\nここまで\n",
    });
    // mutable path 依存の内容 digest を実 dir から計算して lock へ記録する。
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
