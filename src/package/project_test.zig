const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const project = @import("project.zig");

fn writeLibPackage(dir: std.Io.Dir, io: std.Io, root: []const u8, name: []const u8) !void {
    const manifest_path = try std.fs.path.join(testing.allocator, &.{ root, "nako.toml" });
    defer testing.allocator.free(manifest_path);
    const source = try std.fmt.allocPrint(testing.allocator,
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
    defer testing.allocator.free(source);
    try dir.writeFile(io, .{ .sub_path = manifest_path, .data = source });
    const index_path = try std.fs.path.join(testing.allocator, &.{ root, "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    try dir.writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\nここまで\n" });
}

fn newDiagnostics() diag.List {
    return diag.List.init(testing.allocator);
}

test "プロジェクトを検出して読み込める" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
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
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    try testing.expectEqualStrings("app", loaded.manifest.package.name);
    try testing.expectEqualStrings("nako.toml", std.fs.path.basename(loaded.manifest_path));

    // 子dir から遡ってプロジェクトを検出できる。
    try temporary.dir.createDirPath(io, "app/sub/dir");
    const nested = try temporary.dir.realPathFileAlloc(io, "app/sub/dir", testing.allocator);
    defer testing.allocator.free(nested);
    const found = (try project.findRoot(testing.allocator, io, nested)).?;
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(app_root, found);
}

test "path依存のみのプロジェクトでensureLockがnako.lockを生成する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    try testing.expect(outcome.wrote);
    try testing.expectEqualStrings("default", outcome.profile);

    // lock に source package が `pkg:<hex>` id で記録される。
    var found_path = false;
    for (outcome.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .path) {
            found_path = true;
            try testing.expectEqualStrings("lib", entry.name);
            try testing.expectEqualStrings("lib", entry.source.?.path.?);
            try testing.expect(std.mem.startsWith(u8, entry.id, "pkg:"));
        }
    }
    try testing.expect(found_path);

    // 2回目は fresh で書き換えない。
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.wrote);

    // --locked は fresh lock を受け入れる。
    try project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics);
}

test "manifest変更で--lockedは失敗する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
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
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // lock が無い間は --locked で失敗する。
    try testing.expectError(error.LockedNotSatisfied, project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics));

    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    try testing.expect(outcome.wrote);
    try project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics);

    // manifest を変更すると lock が陳腐化して --locked が拒否する。
    loaded.deinit();
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.2.0"
        \\license = "MIT"
        \\
        ,
    });
    loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    try testing.expectError(error.LockedNotSatisfied, project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics));
}

test "npm依存はlock化できないためUnsupportedDependencyで拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // npm 依存を黙って lock から落とさず、明示的な診断付きで失敗する。
    try testing.expectError(error.UnsupportedDependency, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));
    const item = diagnostics.find(diag.E029_INVALID_VALUE) orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, item.message, "escape") != null);
    // 不完全な lock は書かれない。
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/nako.lock", .{}));
}

test "path依存の循環はDependencyCycleとして診断する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // app → pkgs/a → pkgs/b → pkgs/a の path 依存 cycle。
    try temporary.dir.createDirPath(io, "app/pkgs/a/src");
    try temporary.dir.createDirPath(io, "app/pkgs/b/src");
    const a_manifest =
        \\[package]
        \\name = "a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\b = { path = "../b" }
        \\
    ;
    const b_manifest =
        \\[package]
        \\name = "b"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\a = { path = "../a" }
        \\
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "app/pkgs/a/nako.toml", .data = a_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/pkgs/b/nako.toml", .data = b_manifest });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/pkgs/a/src/index.nako3", .data = "●表示とは\nここまで\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/pkgs/b/src/index.nako3", .data = "●表示とは\nここまで\n" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\a = { path = "pkgs/a" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // 無限に再取得せず E004_DEPENDENCY_CYCLE で失敗する。
    try testing.expectError(error.DependencyCycle, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));
    try testing.expect(diagnostics.find(diag.E004_DEPENDENCY_CYCLE) != null);
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/nako.lock", .{}));
}

test "異なる親の同名dep keyは別sourceとして解決される" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // app → pkgs/a, pkgs/b。a と b がどちらも `common` という dep key
    // を宣言するが、指す source が異なる。dep key は親 manifest 内の
    // 名前空間なので衝突にならず、source identity の異なる2 package
    // として解決される必要がある。
    try temporary.dir.createDirPath(io, "app/pkgs/common-a/src");
    try temporary.dir.createDirPath(io, "app/pkgs/common-b/src");
    try writeLibPackage(temporary.dir, io, "app/pkgs/common-a", "common-a");
    try writeLibPackage(temporary.dir, io, "app/pkgs/common-b", "common-b");
    for ([_][]const u8{ "a", "b" }) |name| {
        const dir_path = try std.fmt.allocPrint(testing.allocator, "app/pkgs/{s}", .{name});
        defer testing.allocator.free(dir_path);
        const src_dir = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{dir_path});
        defer testing.allocator.free(src_dir);
        try temporary.dir.createDirPath(io, src_dir);
        const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/nako.toml", .{dir_path});
        defer testing.allocator.free(manifest_path);
        const manifest = try std.fmt.allocPrint(testing.allocator,
            \\[package]
            \\name = "{s}"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
            \\[[exports]]
            \\name = "{s}"
            \\path = "src/index.nako3"
            \\
            \\[dependencies.path]
            \\common = {{ path = "../common-{s}" }}
            \\
        , .{ name, name, name });
        defer testing.allocator.free(manifest);
        try temporary.dir.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
        const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/src/index.nako3", .{dir_path});
        defer testing.allocator.free(index_path);
        try temporary.dir.writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\nここまで\n" });
    }
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\a = { path = "pkgs/a" }
        \\b = { path = "pkgs/b" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    // a, b, common-a, common-b の4つの path entry が記録される。
    var path_entries: usize = 0;
    for (outcome.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .path) path_entries += 1;
    }
    try testing.expectEqual(@as(usize, 4), path_entries);
}

test "mutable=falseのpath依存はtree hashでpinし内容変更を検出する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib", mutable = false }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    // source artifact に sha256 が記録される（spec §3.4.3）。
    var recorded: ?[]const u8 = null;
    for (outcome.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .path) {
            const artifact = entry.artifact("source") orelse return error.TestExpectedEqual;
            recorded = artifact.sha256 orelse return error.TestExpectedEqual;
            try testing.expect(std.mem.startsWith(u8, recorded.?, "sha256:"));
        }
    }
    try testing.expect(recorded != null);
    try project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics);

    // 内容を変えると pin 不一致で --locked が拒否し、通常解決は再記録する。
    const index_path = try std.fs.path.join(testing.allocator, &.{ app_root, "lib", "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\n  「changed」を表示。\nここまで\n" });
    try testing.expectError(error.LockedNotSatisfied, project.verifyLocked(testing.allocator, io, &loaded, &.{}, &diagnostics));
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expect(second.wrote);
    for (second.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .path) {
            const artifact = entry.artifact("source") orelse return error.TestExpectedEqual;
            try testing.expect(!std.mem.eql(u8, artifact.sha256.?, recorded.?));
        }
    }
}

test "mutable=trueのpath依存はhashを記録しない" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib", mutable = true }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    for (outcome.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .path) {
            try testing.expectEqual(@as(?bool, true), entry.source.?.mutable);
            const artifact = entry.artifact("source") orelse return error.TestExpectedEqual;
            try testing.expect(artifact.sha256 == null);
        }
    }
    // 内容変更しても lock は fresh のまま（live reference 契約）。
    const index_path = try std.fs.path.join(testing.allocator, &.{ app_root, "lib", "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\n  「x」を表示。\nここまで\n" });
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.wrote);
}

test "存在しないpath依存の取得失敗はdep名を含む診断を出す" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\missing = { path = "missing" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // 裸のエラー名だけでなく session.failures 由来の詳細診断が出る。
    try testing.expectError(error.NotFound, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));
    try testing.expect(diagnostics.errorCount() > 0);
    var found_detail = false;
    for (diagnostics.items.items) |item| {
        if (std.mem.indexOf(u8, item.message, "missing") != null) found_detail = true;
    }
    try testing.expect(found_detail);
}

test "generationExistsは.nako/env/<gen>の実在を検査する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/.nako/env/g1");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    try testing.expect(project.generationExists(io, app_root, "g1"));
    try testing.expect(!project.generationExists(io, app_root, "gone"));
    try testing.expect(!project.generationExists(io, app_root, "../escape"));
    try testing.expect(!project.generationExists(io, app_root, ""));
}

test "check相当の環境検査は.nakoを作成しない" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
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
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    const info = try project.readEnvironmentInfo(testing.allocator, io, app_root);
    try testing.expect(info == null);
    // 副作用なし: .nako が作られていない。
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/.nako", .{}));
}

// ---------------------------------------------------------------------------
// git 依存の再 lock（locked source 再利用・衝突検出）
// ---------------------------------------------------------------------------

fn gitRunInner(io: std.Io, argv: []const []const u8) !std.process.RunResult {
    var env_map = try fetch.sanitizedGitEnvMap(testing.allocator);
    defer if (env_map) |*m| m.deinit();
    return std.process.run(testing.allocator, io, .{
        .argv = argv,
        .environ_map = if (env_map) |*m| m else null,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
}

fn gitAvailable(io: std.Io) bool {
    const result = gitRunInner(io, &.{ "git", "--version" }) catch return false;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn gitRun(io: std.Io, argv: []const []const u8) !void {
    const result = gitRunInner(io, argv) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitFailed;
}

fn gitStdout(io: std.Io, argv: []const []const u8) ![]u8 {
    const result = gitRunInner(io, argv) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(result.stdout);
    return owned;
}

fn gitCommitAll(io: std.Io, repo: []const u8, message: []const u8) ![]u8 {
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "-A" });
    try gitRun(io, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message });
    return gitStdout(io, &.{ "git", "-C", repo, "rev-parse", "HEAD" });
}

/// ローカル git repo（`repo` package）を作り、HEAD の完全 SHA を返す。
fn createGitRepo(temporary: *std.testing.TmpDir, io: std.Io) !struct { path: [:0]u8, url: []u8, commit: []u8 } {
    try temporary.dir.createDirPath(io, "repo/src");
    try writeLibPackage(temporary.dir, io, "repo", "repo-pkg");
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/.gitattributes", .data = "* -text\n" });
    const repo = try temporary.dir.realPathFileAlloc(io, "repo", testing.allocator);
    errdefer testing.allocator.free(repo);

    try gitRun(io, &.{ "git", "init", "--quiet", repo });
    const commit = try gitCommitAll(io, repo, "init");
    errdefer testing.allocator.free(commit);
    const url = if (builtin.os.tag == .windows) blk: {
        const fwd = try testing.allocator.dupe(u8, repo);
        defer testing.allocator.free(fwd);
        for (fwd) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        break :blk try std.fmt.allocPrint(testing.allocator, "file:///{s}", .{fwd});
    } else try std.fmt.allocPrint(testing.allocator, "file://{s}", .{repo});
    return .{ .path = repo, .url = url, .commit = commit };
}

test "ensureLockはlockのgit sourceを再利用しcommit変更は別packageとして解決する" {
    const io = testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo = try createGitRepo(&temporary, io);
    defer testing.allocator.free(repo.path);
    defer testing.allocator.free(repo.url);
    defer testing.allocator.free(repo.commit);

    const tmp_abs = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);
    const cache_dir = try std.fs.path.join(testing.allocator, &.{ tmp_abs, "cache" });
    defer testing.allocator.free(cache_dir);

    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    const writeApp = struct {
        fn run(a: std.mem.Allocator, dir: std.Io.Dir, url: []const u8, commit: []const u8) !void {
            const source = try std.fmt.allocPrint(a,
                \\[package]
                \\name = "app"
                \\version = "0.1.0"
                \\license = "MIT"
                \\
                \\[dependencies.path]
                \\lib = {{ path = "lib" }}
                \\
                \\[dependencies.git]
                \\gdep = {{ url = "{s}", commit = "{s}" }}
                \\
            , .{ url, commit });
            defer a.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = source });
        }
    }.run;
    try writeApp(testing.allocator, temporary.dir, repo.url, repo.commit[0..7]);
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    const options = project.PrepareOptions{ .cache_root = cache_dir };

    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    var first = try project.ensureLock(testing.allocator, io, &loaded, &options, &diagnostics);
    defer first.deinit();
    // git source は lock の完全 SHA で記録される。
    var found_git = false;
    for (first.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .git) {
            found_git = true;
            try testing.expectEqualStrings(repo.commit, entry.source.?.commit.?);
        }
    }
    try testing.expect(found_git);

    // manifest を変更せず再 lock しても、lock entry は public id
    // （source identity 由来の `pkg:<hex>`）で引かれ、locked の完全 SHA
    // が宣言 prefix と整合するため解決は成功する。
    loaded.deinit();
    loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    var relocked = try project.ensureLock(testing.allocator, io, &loaded, &options, &diagnostics);
    defer relocked.deinit();

    // repo に別 commit を進め、manifest の commit-ish をそちらへ書き換える。
    // source identity が変わるため別 package として解決され、旧 entry は
    // lock から取り除かれる（dep key が同じでも source が異なれば別物）。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/second.txt", .data = "second\n" });
    const second_commit = try gitCommitAll(io, repo.path, "second");
    defer testing.allocator.free(second_commit);
    loaded.deinit();
    try writeApp(testing.allocator, temporary.dir, repo.url, second_commit[0..7]);
    loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    var updated = try project.ensureLock(testing.allocator, io, &loaded, &options, &diagnostics);
    defer updated.deinit();
    found_git = false;
    for (updated.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .git) {
            found_git = true;
            try testing.expectEqualStrings(second_commit, entry.source.?.commit.?);
        }
    }
    try testing.expect(found_git);
}

test "推移的manifestのnpm宣言もlock化を拒否する" {
    // app → path:lib で、lib が npm 依存を宣言する。metaFromManifest は
    // npm 辺を黙って落とすため、orchestration 側で明示失敗させないと
    // 必要な推移的依存が lock/環境から欠落する。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/lib/nako.toml",
        .data =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "lib"
        \\path = "src/index.nako3"
        \\
        \\[dependencies.npm]
        \\escape = "^1.0.0"
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lib/src/index.nako3", .data = "x\n" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    try testing.expectError(error.UnsupportedDependency, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));
    const item = diagnostics.find(diag.E029_INVALID_VALUE) orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, item.message, "escape") != null);
    // 不完全な lock は書かれない。
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, "app/nako.lock", .{}));
}

test "feature-gatedな推移的pkg依存が非活性ならregistryを要求しない" {
    // lib は feature "extra" 経由でのみ有効になる pkg 依存 optdep を
    // 宣言する。default feature では有効化されないため、registry 未設定
    // でも lock が成功し、optdep は lock に現れない。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/lib/nako.toml",
        .data =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "lib"
        \\path = "src/index.nako3"
        \\
        \\[features]
        \\extra = ["optdep"]
        \\
        \\[dependencies.pkg]
        \\optdep = { version = "^1.0.0" }
        \\
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lib/src/index.nako3", .data = "x\n" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // registry 未設定でも非活性 pkg 依存のために失敗しない。
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();
    try testing.expect(outcome.wrote);
    var found_lib = false;
    for (outcome.lock.packages) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "optdep"));
        if (std.mem.eql(u8, entry.name, "lib")) found_lib = true;
    }
    try testing.expect(found_lib);
}

test "environmentPackagesUsableはpackages記録と実体を検証する" {
    // ヘッダ（lockSha256 等）だけ一致していて packages map が破損した
    // 環境を「最新」と誤認しないための内容検査。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();

    const lib_id = blk: {
        for (outcome.lock.packages) |entry| {
            if (entry.source != null and entry.source.?.kind == .path) break :blk entry.id;
        }
        return error.TestExpectedEqual;
    };

    const writeEnv = struct {
        fn run(dir: std.Io.Dir, packages_json: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","profile":"default","runtime":"lnako","generation":"gen-1","packages":{s}}}
                \\
            , .{packages_json});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = source });
        }
    }.run;

    // 実在する dir を指す記録は有効。
    try temporary.dir.createDirPath(io, "app/.nako/env/gen-1/deps/lib");
    const valid = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":{{\"name\":\"lib\",\"version\":\"1.0.0\",\"id\":\"{s}\",\"path\":\".nako/env/gen-1/deps/lib\"}}}}", .{ lib_id, lib_id });
    defer testing.allocator.free(valid);
    try writeEnv(temporary.dir, valid);
    try testing.expect(try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // 記録 key の欠落は無効。
    try writeEnv(temporary.dir, "{}");
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // project 外を指す記録は無効。
    const escaped = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":{{\"name\":\"lib\",\"version\":\"1.0.0\",\"id\":\"{s}\",\"path\":\"../outside\"}}}}", .{ lib_id, lib_id });
    defer testing.allocator.free(escaped);
    try writeEnv(temporary.dir, escaped);
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // dir ではなく file を指す記録は無効。
    const file_record = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":{{\"name\":\"lib\",\"version\":\"1.0.0\",\"id\":\"{s}\",\"path\":\"nako.lock\"}}}}", .{ lib_id, lib_id });
    defer testing.allocator.free(file_record);
    try writeEnv(temporary.dir, file_record);
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));
}
