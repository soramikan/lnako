//! `sync.zig` の単体テスト。同期 transaction の公開面と、依存 alias・
//! edge scope の内部契約（`pub` 宣言のみ）を検証する。

const std = @import("std");
const cache_key = @import("cache_key.zig");
const diag = @import("diagnostics.zig");
const environment = @import("environment.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const sync = @import("sync.zig");

const Allocator = std.mem.Allocator;
const ImportConstraint = sync.ImportConstraint;
const appendScopedAlias = sync.appendScopedAlias;
const collectImportDependencies = sync.collectImportDependencies;
const collectImportDependenciesForProfile = sync.collectImportDependenciesForProfile;
const collectRootDependencyIds = sync.collectRootDependencyIds;
const run = sync.run;

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sha256HexAlloc(allocator: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, &hex);
}

const app_manifest =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\license = "MIT"
    \\
    \\[dependencies.path]
    \\lib = { path = "deps/lib" }
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

/// path 依存1件を持つ最小プロジェクトを作る。戻り値は lock 本文。
fn fixtureLock(allocator: Allocator, manifest_sha: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
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
    , .{manifest_sha});
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
    const lock = try fixtureLock(testing.allocator, manifest_sha);
    defer testing.allocator.free(lock);
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
}

test "sync は path 依存を参照して schema v1 の環境を構築する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try run(testing.allocator, io, .{
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
    const root_dependencies = document.get("dependencies").?.array;
    try testing.expectEqual(@as(usize, 1), root_dependencies.items.len);
    try testing.expectEqualStrings("lib", root_dependencies.items[0].object.get("alias").?.string);
    try testing.expectEqualStrings("pkg:11111111111111111111111111111111", root_dependencies.items[0].object.get("package").?.string);
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
    const lock_hex = try sha256HexAlloc(testing.allocator, lock_bytes);
    defer testing.allocator.free(lock_hex);
    const expected = try std.fmt.allocPrint(testing.allocator, "sha256:{s}", .{lock_hex});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, document.get("lockSha256").?.string);

    // `.nako/environment.json` が書かれ、`current` が世代を指す。
    const written = try temporary.dir.readFileAlloc(io, ".nako/environment.json", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(report.environment_json, written);
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
    try testing.expectError(error.StaleLock, run(testing.allocator, io, .{
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
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer first.deinit();
    const first_json = try testing.allocator.dupe(u8, first.environment_json);
    defer testing.allocator.free(first_json);

    // 未知の profile を要求して失敗させる。
    try testing.expectError(error.UnknownProfile, run(testing.allocator, io, .{
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
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
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
    try testing.expectError(error.Offline, run(testing.allocator, io, .{
        .project_root = root,
        .cache_root = cache_root,
        .policy = .{ .offline = true },
    }, &list));
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, ".nako/environment.json", .{}));
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
    const manifest_sha = try sha256HexAlloc(testing.allocator, support_manifest);
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
    var report = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
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
    const manifest_sha = try sha256HexAlloc(testing.allocator, feature_manifest);
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
    , .{manifest_sha});
    defer testing.allocator.free(lock);
    try temporary.dir.createDirPath(io, "deps/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.toml", .data = feature_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/nako.toml", .data = feature_lib_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "deps/lib/x.mjs", .data = "export {};\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock });
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var report = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
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

test "artifactKey は宣言 hash を key 材料へ含める" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const allocator = arena_impl.allocator();
    const url = "https://example.test/pkg.tar.gz";
    // sha256 は digest 自体が key になるため表記が違っても同一 key。
    const a = try cache_key.artifactKey(allocator, "http", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", url);
    const b = try cache_key.artifactKey(allocator, "http", "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", url);
    try testing.expectEqualStrings(a, b);
    // sha256 以外の表記でも宣言 hash が key 材料へ入る。同じ URL で lock の
    // hash が更新されれば必ず別 entry になり、古い内容を復元しない。
    const c = try cache_key.artifactKey(allocator, "http", "sha512:aaaa", url);
    const d = try cache_key.artifactKey(allocator, "http", "sha512:bbbb", url);
    try testing.expect(!std.mem.eql(u8, c, d));
    try testing.expect(!std.mem.eql(u8, a, c));
    // 同じ hash 宣言でも取得元が違えば別 entry。
    const e = try cache_key.artifactKey(allocator, "http", "sha512:aaaa", "https://other.test/pkg.tar.gz");
    try testing.expect(!std.mem.eql(u8, c, e));
}

test "sync は current が欠損しても公開済み世代を environment.json から保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    const first_gen = try testing.allocator.dupe(u8, first.generation);
    defer testing.allocator.free(first_gen);
    first.deinit();

    // current 更新失敗・中断と同等の状態（公開済みだが current が無い）。
    try temporary.dir.deleteFile(io, ".nako/current");

    var second = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // current が無くても environment.json の参照から前世代が保持される。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
}

test "sync は再実行で世代を更新し直前世代を保持する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest_sha = try sha256HexAlloc(testing.allocator, app_manifest);
    defer testing.allocator.free(manifest_sha);
    try writeFixtureProject(&temporary, manifest_sha);
    const root = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const cache_root = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_root);

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    var first = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    const first_gen = try testing.allocator.dupe(u8, first.generation);
    defer testing.allocator.free(first_gen);
    first.deinit();

    var second = try run(testing.allocator, io, .{ .project_root = root, .cache_root = cache_root }, &list);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first_gen, second.generation));

    // 直前世代 dir が残っている。
    const previous = try std.fs.path.join(testing.allocator, &.{ root, ".nako", "env", first_gen });
    defer testing.allocator.free(previous);
    try std.Io.Dir.cwd().access(io, previous, .{});
}

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
