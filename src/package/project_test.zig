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
