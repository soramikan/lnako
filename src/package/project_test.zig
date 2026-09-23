const std = @import("std");
const testing = std.testing;
const diag = @import("diagnostics.zig");
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
