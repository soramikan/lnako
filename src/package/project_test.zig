const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
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

test "path pin用manifest snapshot検査は変更後の内容を拒否する" {
    const original =
        \\[package]
        \\name = "old"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
    ;
    const changed =
        \\[package]
        \\name = "new"
        \\version = "2.0.0"
        \\license = "MIT"
        \\
    ;
    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, original, &diagnostics);
    defer manifest.deinit();
    try testing.expect(project.manifestSnapshotMatches(&manifest, original));
    try testing.expect(!project.manifestSnapshotMatches(&manifest, changed));
}

test "tree pin対象外dir配下のexportは検出する" {
    const source =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "hidden"
        \\path = "src/.git/hidden.nako3"
        \\
    ;
    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
    defer manifest.deinit();
    try testing.expect(project.hasExcludedExport(&manifest));
}

test "path dependency export target must stay inside the pinned package tree" {
    const cases = [_][]const u8{ "../shared.nako3", "/tmp/shared.nako3", "src/../shared.nako3", "src/.nako/private.nako3" };
    for (cases) |path| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\[package]
            \\name = "lib"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
            \\[[exports]]
            \\name = "entry"
            \\path = "{s}"
            \\
        , .{path});
        defer testing.allocator.free(source);
        var diagnostics = newDiagnostics();
        defer diagnostics.deinit();
        var manifest = try manifest_mod.parse(testing.allocator, source, &diagnostics);
        defer manifest.deinit();
        try testing.expect(project.hasExcludedExport(&manifest));
    }

    const safe_source =
        \\[package]
        \\name = "lib"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "entry"
        \\path = "src/index.nako3"
        \\
    ;
    var safe_diagnostics = newDiagnostics();
    defer safe_diagnostics.deinit();
    var safe_manifest = try manifest_mod.parse(testing.allocator, safe_source, &safe_diagnostics);
    defer safe_manifest.deinit();
    try testing.expect(!project.hasExcludedExport(&safe_manifest));
}

test "tree pinはhost separatorだけをslash canonical formへ揃える" {
    const forward = try project.canonicalTreePath(testing.allocator, "nested/deep/file.nako3");
    defer testing.allocator.free(forward);
    const backslash = try project.canonicalTreePath(testing.allocator, "nested\\deep\\file.nako3");
    defer testing.allocator.free(backslash);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(forward, backslash);
    } else {
        try testing.expectEqualStrings("nested\\deep\\file.nako3", backslash);
        try testing.expect(!std.mem.eql(u8, forward, backslash));
    }
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

test "findRootはmanifest候補が通常fileでない場合に拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/sub/nako.toml");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = "[package]\\n" });
    const nested = try temporary.dir.realPathFileAlloc(io, "app/sub", testing.allocator);
    defer testing.allocator.free(nested);
    // 欠落候補だけ親へ進み、存在する非fileは不正候補として拒否する。
    try testing.expectError(error.InvalidManifest, project.findRoot(testing.allocator, io, nested));
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
        if (entry.source != null and entry.source.?.kind == .path) {
            path_entries += 1;
            // 推移的 path 依存の project 相対 `source.path` は Windows で
            // も `\` を含まない（`/` 区切りへ揃えて環境間共有可能にする）。
            try testing.expect(std.mem.indexOfScalar(u8, entry.source.?.path.?, '\\') == null);
        }
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
    // mutable path digest が lock input に記録されている。
    try testing.expect(outcome.lock.input.mutable_paths.len == 1);
    // 内容変更は mutablePaths digest 不一致で lock が stale になり
    // 再解決される（manifest 同一でも dir の変更を検出する契約）。
    const index_path = try std.fs.path.join(testing.allocator, &.{ app_root, "lib", "src", "index.nako3" });
    defer testing.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "●表示とは\n  「x」を表示。\nここまで\n" });
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expect(second.report != null);
    // 無変更なら fresh のまま再解決しない。
    var third = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer third.deinit();
    try testing.expect(third.report == null);
    try testing.expect(!third.wrote);
}

test "path依存の./前置表記はlock内で正規化される" {
    // `./lib` と `lib` は同じ dir を指す宣言。lock の source.path・
    // mutablePaths・解決 id は正規形 `lib` に揃える（表記違いで別
    // package 扱い・別 digest 名にならないようにする）。
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
        \\lib = { path = "./lib", mutable = true }
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

    var found = false;
    for (outcome.lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (source.kind == .path) {
            found = true;
            try testing.expectEqualStrings("lib", source.path.?);
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), outcome.lock.input.mutable_paths.len);
    try testing.expectEqualStrings("lib", outcome.lock.input.mutable_paths[0].path);
}

test "path依存の繰り返し separator・. 成分は lock 記録前に正規形へ畳む" {
    // `deps//lib`・`deps/./lib` のような非規範宣言を lock の
    // source.path へそのまま記録すると、sync の isCanonicalDepPath が
    // 拒否して lock 成功・実行失敗の不整合になる。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/deps/lib/src");
    try writeLibPackage(temporary.dir, io, "app/deps/lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "deps//./lib" }
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

    var found = false;
    for (outcome.lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (source.kind == .path) {
            found = true;
            try testing.expectEqualStrings("deps/lib", source.path.?);
        }
    }
    try testing.expect(found);
}

test "POSIX path依存のbackslashは通常のファイル名文字としてlockへ保持する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/deps\\lib/src");
    try writeLibPackage(temporary.dir, io, "app/deps\\lib", "lib");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "deps\\lib" }
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

    var found = false;
    for (outcome.lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path) continue;
        found = true;
        try testing.expectEqualStrings("deps\\lib", source.path.?);
    }
    try testing.expect(found);
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
        fn run(a: std.mem.Allocator, dir: std.Io.Dir, url: []const u8, commit: []const u8, full_commit: []const u8) !void {
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
                \\gdep_full = {{ url = "{s}", commit = "{s}" }}
                \\
            , .{ url, commit, url, full_commit });
            defer a.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = source });
        }
    }.run;
    try writeApp(testing.allocator, temporary.dir, repo.url, repo.commit[0..7], repo.commit);
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
    var git_package_count: usize = 0;
    var first_git_id: ?[]u8 = null;
    defer if (first_git_id) |id| testing.allocator.free(id);
    for (first.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .git) {
            found_git = true;
            git_package_count += 1;
            try testing.expectEqualStrings(repo.commit, entry.source.?.commit.?);
            first_git_id = try testing.allocator.dupe(u8, entry.id);
        }
    }
    try testing.expect(found_git);
    try testing.expectEqual(@as(usize, 1), git_package_count);

    // manifest を変更せず再 lock しても、lock entry は public id
    // （source identity 由来の `pkg:<hex>`）で引かれ、locked の完全 SHA
    // が宣言 prefix と整合するため解決は成功する。
    loaded.deinit();
    loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    var relocked = try project.ensureLock(testing.allocator, io, &loaded, &options, &diagnostics);
    defer relocked.deinit();

    // 同じ pin の abbreviated/full SHA は同じ canonical source public id。
    loaded.deinit();
    try writeApp(testing.allocator, temporary.dir, repo.url, repo.commit, repo.commit);
    loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    var full_pinned = try project.ensureLock(testing.allocator, io, &loaded, &options, &diagnostics);
    defer full_pinned.deinit();
    var full_id: ?[]const u8 = null;
    for (full_pinned.lock.packages) |entry| {
        if (entry.source != null and entry.source.?.kind == .git) full_id = entry.id;
    }
    try testing.expect(full_id != null);
    try testing.expectEqualStrings(first_git_id.?, full_id.?);

    // repo に別 commit を進め、manifest の commit-ish をそちらへ書き換える。
    // source identity が変わるため別 package として解決され、旧 entry は
    // lock から取り除かれる（dep key が同じでも source が異なれば別物）。
    try temporary.dir.writeFile(io, .{ .sub_path = "repo/second.txt", .data = "second\n" });
    const second_commit = try gitCommitAll(io, repo.path, "second");
    defer testing.allocator.free(second_commit);
    loaded.deinit();
    try writeApp(testing.allocator, temporary.dir, repo.url, second_commit[0..7], second_commit);
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

test "ensureLockは解決中のmanifest変更を検出してlockを公開しない" {
    // `project.load` が読んだ bytes/hash と解決完了時の manifest が
    // 異なる場合、古い manifest に対応する lock を新 manifest へ原子
    // 公開すると即座に陳腐化する。公開前に hash を再照合して失敗する。
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

    // 読込と解決の間に manifest が書き換わった状態を再現する（load 後に
    // 別内容へ上書き。bytes が変われば hash 照合で検出される）。
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.2.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = { path = "lib" }
        \\
        ,
    });

    try testing.expectError(error.StaleLock, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));
    const item = diagnostics.find(diag.E029_INVALID_VALUE) orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, item.message, "manifest changed") != null);
    // 古い manifest に対応する lock は公開されない。
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

test "malformed environment.json is stale and automatic preparation repairs it" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app");
    try temporary.dir.createDirPath(io, "cache");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);
    const cache_root = try temporary.dir.realPathFileAlloc(io, "cache", testing.allocator);
    defer testing.allocator.free(cache_root);

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var loaded = try project.load(a, io, app_root, &diagnostics);
    defer loaded.deinit();
    const opts = project.PrepareOptions{ .cache_root = cache_root };

    const initial = try project.ensureEnvironment(a, io, &loaded, &opts, &diagnostics);
    try testing.expect(initial.synced);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = "{\"schemaVersion\":1" });

    const info = try project.inspectForCheck(a, io, &loaded, &opts, &diagnostics);
    try testing.expect(!info.environment_current);
    const repaired = try project.ensureEnvironment(a, io, &loaded, &opts, &diagnostics);
    try testing.expect(repaired.synced);
    try testing.expect(repaired.was_stale);
    const environment = (try project.readEnvironmentInfo(a, io, app_root)).?;
    try testing.expectEqual(@as(i64, 1), environment.schema_version);
}

test "environmentPackagesUsableはpackages記録と実体を検証する" {
    // ヘッダ（lockSha256 等）だけ一致していて packages map が破損した
    // 環境を「最新」と誤認しないための内容検査。`../`・絶対 path の
    // 宣言 path 依存は正式な宣言形で、記録が lock の source.path と
    // 一致すれば project 外でも許容される。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try writeLibPackage(temporary.dir, io, "app/lib", "lib");
    try temporary.dir.createDirPath(io, "shared/outside/src");
    try writeLibPackage(temporary.dir, io, "shared/outside", "outside");
    try temporary.dir.createDirPath(io, "shared/abslib/src");
    try writeLibPackage(temporary.dir, io, "shared/abslib", "abslib");
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);
    const abslib_path = try temporary.dir.realPathFileAlloc(io, "shared/abslib", testing.allocator);
    defer testing.allocator.free(abslib_path);
    const manifest_src = try std.fmt.allocPrint(testing.allocator,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[dependencies.path]
        \\lib = {{ path = "lib" }}
        \\outside = {{ path = "../shared/outside" }}
        \\abslib = {{ path = '{s}' }}
        \\
    , .{abslib_path});
    defer testing.allocator.free(manifest_src);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/nako.toml", .data = manifest_src });

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer outcome.deinit();

    const writeEnv = struct {
        fn run(dir: std.Io.Dir, packages_json: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","profile":"default","runtime":"lnako","packages":{s}}}
                \\
            , .{packages_json});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = source });
        }
    }.run;

    // `.nako` は sync 以外では作られないため、記録の器だけ先に用意する。
    try temporary.dir.createDirPath(io, "app/.nako/env/gen-1");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-1\n" });
    // 全 path 依存の宣言 path をそのまま記録した環境は有効
    // （`../`・絶対 path の外部参照を含む）。
    var json_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json_buf.deinit();
    const writer = &json_buf.writer;
    try writer.writeAll("{");
    var lib_id: ?[]const u8 = null;
    var first = true;
    for (outcome.lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        if (std.mem.eql(u8, entry.name, "lib")) lib_id = entry.id;
        const quoted = try std.json.Stringify.valueAlloc(testing.allocator, source.path.?, .{});
        defer testing.allocator.free(quoted);
        try writer.print("\"{s}\":{{\"name\":\"{s}\",\"version\":\"{s}\",\"id\":\"{s}\",\"path\":{s}}}", .{ entry.id, entry.name, entry.version, entry.id, quoted });
    }
    try writer.writeAll("}");
    try testing.expect(lib_id != null);
    try writeEnv(temporary.dir, json_buf.written());
    try testing.expect(try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // Public ID付きrecordをname keyへ置いてもlegacy fallbackでは受理しない。
    var wrong_key_json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer wrong_key_json.deinit();
    try wrong_key_json.writer.writeAll("{");
    var wrong_key_first = true;
    for (outcome.lock.packages) |entry| {
        const source = entry.source orelse continue;
        if (source.kind != .path) continue;
        if (!wrong_key_first) try wrong_key_json.writer.writeAll(",");
        wrong_key_first = false;
        const key = if (std.mem.eql(u8, entry.name, "lib")) entry.name else entry.id;
        const quoted_key = try std.json.Stringify.valueAlloc(testing.allocator, key, .{});
        defer testing.allocator.free(quoted_key);
        const quoted_path = try std.json.Stringify.valueAlloc(testing.allocator, source.path.?, .{});
        defer testing.allocator.free(quoted_path);
        try wrong_key_json.writer.print("{s}:{{\"name\":\"{s}\",\"version\":\"{s}\",\"id\":\"{s}\",\"path\":{s}}}", .{ quoted_key, entry.name, entry.version, entry.id, quoted_path });
    }
    try wrong_key_json.writer.writeAll("}");
    try writeEnv(temporary.dir, wrong_key_json.written());
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // 記録 key の欠落は無効。
    try writeEnv(temporary.dir, "{}");
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // 宣言と一致しない無関係な外部 path を指す記録は無効。
    const escaped = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":{{\"name\":\"lib\",\"version\":\"1.0.0\",\"id\":\"{s}\",\"path\":\"../unrelated\"}}}}", .{ lib_id.?, lib_id.? });
    defer testing.allocator.free(escaped);
    try writeEnv(temporary.dir, escaped);
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));

    // 宣言と一致しない project 内 path（展開物風）の記録も無効。
    const materialized = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":{{\"name\":\"lib\",\"version\":\"1.0.0\",\"id\":\"{s}\",\"path\":\".nako/env/gen-1/deps/lib\"}}}}", .{ lib_id.?, lib_id.? });
    defer testing.allocator.free(materialized);
    try writeEnv(temporary.dir, materialized);
    try testing.expect(!try project.environmentPackagesUsable(testing.allocator, io, app_root, &outcome.lock, "default"));
}

test "edit.lockのleaf symlinkは外部fileを変更せずリンクのみ置き換える" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/.nako");
    try temporary.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "keep" });
    const victim_abs = try temporary.dir.realPathFileAlloc(io, "victim.txt", testing.allocator);
    defer testing.allocator.free(victim_abs);
    temporary.dir.symLink(io, victim_abs, "app/.nako/edit.lock", .{}) catch |err| switch (err) {
        // Windows等でlink作成権限がない環境では検証を省略する。
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    // leaf symlink は追従せず、リンク本体のみ置き換えて lock を取得する。
    var edit_lock = try project.acquireEditLock(testing.allocator, io, app_root);
    edit_lock.unlock();

    // 外部 file は無傷で、edit.lock は実 file として作り直されている。
    const bytes = try temporary.dir.readFileAlloc(io, "victim.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("keep", bytes);
    const stat = try temporary.dir.statFile(io, "app/.nako/edit.lock", .{ .follow_symlinks = false });
    try testing.expect(stat.kind == .file);
}

test "環境metadataのprofile/runtime欠落・型違いは不一致とする" {
    // schema v1 の environment.json は profile/runtime を必須とする。
    // 欠落・型違いで読めなかった項目は選択 profile/runtime を証明できず、
    // 照合を「不明＝一致」と緩めない。
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
    var digest: [32]u8 = undefined;
    try testing.expect(try project.lockDigest(testing.allocator, io, app_root, &digest));
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    // 世代 dir と packages 記録を整えた環境を用意する。
    try temporary.dir.createDirPath(io, "app/.nako/env/gen-1");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-1\n" });
    const writeEnv = struct {
        fn run(dir: std.Io.Dir, extra_fields: []const u8, lock_hex_: []const u8, lib_id_: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:{s}",{s}"packages":{{"{s}":{{"name":"lib","version":"1.0.0","id":"{s}","path":"lib"}}}}}}
                \\
            , .{ lock_hex_, extra_fields, lib_id_, lib_id_ });
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = source });
        }
    }.run;
    const check = struct {
        fn run(loaded_: *const project.Project, diagnostics_: *diag.List) !bool {
            // `readEnvironmentInfo` の複製は呼出し側 allocator 所有のため
            // arena でまとめて解放する。
            var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_impl.deinit();
            const info = try project.inspectForCheck(arena_impl.allocator(), io, loaded_, &.{}, diagnostics_);
            return info.environment_current;
        }
    }.run;

    // 正規の profile/runtime は一致。
    try writeEnv(temporary.dir, "\"profile\":\"default\",\"runtime\":\"lnako\",", &lock_hex, lib_id);
    try testing.expect(try check(&loaded, &diagnostics));
    // profile 欠落は不一致。
    try writeEnv(temporary.dir, "\"runtime\":\"lnako\",", &lock_hex, lib_id);
    try testing.expect(!try check(&loaded, &diagnostics));
    // runtime 欠落は不一致。
    try writeEnv(temporary.dir, "\"profile\":\"default\",", &lock_hex, lib_id);
    try testing.expect(!try check(&loaded, &diagnostics));
    // 型違い（数値）も不一致。
    try writeEnv(temporary.dir, "\"profile\":1,\"runtime\":\"lnako\",", &lock_hex, lib_id);
    try testing.expect(!try check(&loaded, &diagnostics));
    try writeEnv(temporary.dir, "\"profile\":\"default\",\"runtime\":0,", &lock_hex, lib_id);
    try testing.expect(!try check(&loaded, &diagnostics));
}

test "mutableなpath依存のmanifest変更はfreshなlockを再利用せず再解決する" {
    // `mutable = true` の path 依存は宣言 dir の内容変更（manifest の
    // version・exports・推移的依存・ソース）を mutablePaths digest 不一致
    // として検出し、root manifest が変わらなくても再解決する契約。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/lib/src/index.nako3",
        .data = "●表示とは\nここまで\n",
    });
    const writeDepManifest = struct {
        fn run(dir: std.Io.Dir, version: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\[package]
                \\name = "lib"
                \\version = "{s}"
                \\license = "MIT"
                \\
                \\[[exports]]
                \\name = "lib"
                \\path = "src/index.nako3"
                \\
            , .{version});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/lib/nako.toml", .data = source });
        }
    }.run;
    try writeDepManifest(temporary.dir, "1.0.0");
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

    const libVersion = struct {
        fn run(lock: *const lock_model.Lock) ?[]const u8 {
            for (lock.packages) |entry| {
                if (std.mem.eql(u8, entry.name, "lib")) return entry.version;
            }
            return null;
        }
    }.run;

    var first = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer first.deinit();
    try testing.expectEqualStrings("1.0.0", libVersion(&first.lock).?);

    // dep manifest の version だけを更新。root manifest は無変更でも
    // 再解決され、lock の version が追従する。
    try writeDepManifest(temporary.dir, "2.0.0");
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expect(second.report != null);
    try testing.expectEqualStrings("2.0.0", libVersion(&second.lock).?);

    // 無変更なら lock は fresh のまま再解決しない（mutable path の
    // digest も一致するため）。
    var third = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer third.deinit();
    try testing.expect(third.report == null);
    try testing.expect(!third.wrote);
}

test "直接指定した依存aliasはlock入力のfeaturesに記録される" {
    // `req` は feature 定義の item に登場するため gated な依存。
    // `--features req` で直接有効化した場合、展開 feature 集合は空で
    // 有効化は dependency_aliases 側にのみ残る。lock 入力が alias を
    // 記録しないと features 無指定の lock と鮮度上区別できない。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/req/src");
    try writeLibPackage(temporary.dir, io, "app/req", "req");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/nako.toml",
        .data =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
        \\[features]
        \\opt = ["req"]
        \\
        \\[dependencies.path]
        \\req = { path = "req" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();

    // 直接 alias 指定で lock を生成すると、graph と lock 入力の両方に
    // `req` が記録される。
    var outcome = try project.ensureLock(testing.allocator, io, &loaded, &.{
        .features = &.{"req"},
    }, &diagnostics);
    defer outcome.deinit();
    var found_req = false;
    for (outcome.lock.packages) |entry| {
        if (std.mem.eql(u8, entry.name, "req")) found_req = true;
    }
    try testing.expect(found_req);
    var input_has_req = false;
    for (outcome.lock.input.features) |name| {
        if (std.mem.eql(u8, name, "req")) input_has_req = true;
    }
    try testing.expect(input_has_req);

    // features 無指定の鮮度検査は stale（記録入力が `req` 有りなのに
    // 再計算入力が無指定）となり、別グラフの lock を fresh と誤認しない。
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const info = try project.inspectForCheck(arena_impl.allocator(), io, &loaded, &.{}, &diagnostics);
    try testing.expect(info.lock_state == .stale);
    try testing.expect(info.freshness != .fresh);
}

test "環境metadataのmutablePaths記録は宣言dirのmetadata変更を検出する" {
    // `mutable = true` な path 依存は exports/commands を環境へ snapshot
    // する。dir の変更が lock バイト列を変えなくても（version・依存が
    // 同一の exports 変更）、環境側に記録した digest と現行 dir を照合
    // して陳腐化を検出する。`mutablePaths` を記録しない旧環境は
    // metadata 変更を検出できないため不一致とする。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    const writeDepManifest = struct {
        fn run(dir: std.Io.Dir, exports_path: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\[package]
                \\name = "lib"
                \\version = "1.0.0"
                \\license = "MIT"
                \\
                \\[[exports]]
                \\name = "lib"
                \\path = "{s}"
                \\
            , .{exports_path});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/lib/nako.toml", .data = source });
        }
    }.run;
    try writeDepManifest(temporary.dir, "src/index.nako3");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/lib/src/index.nako3", .data = "●表示とは\nここまで\n" });
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
    try testing.expectEqual(@as(usize, 1), outcome.lock.input.mutable_paths.len);
    const recorded = outcome.lock.input.mutable_paths[0];

    const lib_id = blk: {
        for (outcome.lock.packages) |entry| {
            if (entry.source != null and entry.source.?.kind == .path) break :blk entry.id;
        }
        return error.TestExpectedEqual;
    };
    var digest: [32]u8 = undefined;
    try testing.expect(try project.lockDigest(testing.allocator, io, app_root, &digest));
    const lock_hex = std.fmt.bytesToHex(digest, .lower);
    try temporary.dir.createDirPath(io, "app/.nako/env/gen-1");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-1\n" });
    const writeEnv = struct {
        fn run(dir: std.Io.Dir, mutable_json: []const u8, lock_hex_: []const u8, lib_id_: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:{s}","profile":"default","runtime":"lnako",{s}"packages":{{"{s}":{{"name":"lib","version":"1.0.0","id":"{s}","path":"lib"}}}}}}
                \\
            , .{ lock_hex_, mutable_json, lib_id_, lib_id_ });
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = source });
        }
    }.run;
    const envCurrent = struct {
        fn run(loaded_: *const project.Project, diagnostics_: *diag.List) !bool {
            var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_impl.deinit();
            const info = try project.inspectForCheck(arena_impl.allocator(), io, loaded_, &.{}, diagnostics_);
            return info.environment_current;
        }
    }.run;

    // `mutablePaths` を記録しない旧環境は不一致（metadata 変更を検出
    // できないため）。
    try writeEnv(temporary.dir, "", &lock_hex, lib_id);
    try testing.expect(!try envCurrent(&loaded, &diagnostics));

    // sync 時点の digest を記録した環境は一致。
    const mutable_json = try std.fmt.allocPrint(testing.allocator,
        \\"mutablePaths":[{{"path":"{s}","sha256":"{s}"}}],
        \\
    , .{ recorded.path, recorded.sha256 });
    defer testing.allocator.free(mutable_json);
    try writeEnv(temporary.dir, mutable_json, &lock_hex, lib_id);
    try testing.expect(try envCurrent(&loaded, &diagnostics));

    // 宣言 dir の metadata（exports）を変えると lock も再解決される。
    // 再解決後の lock digest で環境を作っても、記録された mutablePaths
    // が sync 時点より古い digest のままなら環境は陳腐（exports/commands
    // の snapshot が古い）と判定される。lockSha256 一致と分離して検査する。
    try writeDepManifest(temporary.dir, "src/other.nako3");
    var second = try project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.lock.input.mutable_paths.len);
    const recorded2 = second.lock.input.mutable_paths[0];
    var digest2: [32]u8 = undefined;
    try testing.expect(try project.lockDigest(testing.allocator, io, app_root, &digest2));
    const lock_hex2 = std.fmt.bytesToHex(digest2, .lower);
    // env: 新 lockSha256 + 旧 mutable digest → 不一致。
    try writeEnv(temporary.dir, mutable_json, &lock_hex2, lib_id);
    try testing.expect(!try envCurrent(&loaded, &diagnostics));
    // env: 新 lockSha256 + 新 mutable digest → 一致。
    const mutable_json2 = try std.fmt.allocPrint(testing.allocator,
        \\"mutablePaths":[{{"path":"{s}","sha256":"{s}"}}],
        \\
    , .{ recorded2.path, recorded2.sha256 });
    defer testing.allocator.free(mutable_json2);
    try writeEnv(temporary.dir, mutable_json2, &lock_hex2, lib_id);
    try testing.expect(try envCurrent(&loaded, &diagnostics));
}

test "any/common profile は依存 manifest を cnako target にも照合する" {
    // `runtime = "any"` profile の解決 target は lnako へ coerce されるが、
    // `sync --runtime cnako` でも同じ package 集合を materialize するため、
    // `runtimes = ["lnako"]` だけの source package は受理できない
    // （受理すると使えない cnako 環境を生成する）。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/lib/src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "app/lib/src/index.nako3",
        .data = "●表示とは\nここまで\n",
    });
    const writeDep = struct {
        fn run(dir: std.Io.Dir, runtimes: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\[package]
                \\name = "lib"
                \\version = "1.0.0"
                \\license = "MIT"
                \\runtimes = [{s}]
                \\
                \\[[exports]]
                \\name = "lib"
                \\path = "src/index.nako3"
                \\
            , .{runtimes});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/lib/nako.toml", .data = source });
        }
    }.run;
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
        \\[profiles]
        \\default = { runtime = "any", os = "macos", cpu = "aarch64", abi = "gnu" }
        \\
        ,
    });
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);

    // lnako 専用の source package は any/common profile で受理しない。
    try writeDep(temporary.dir, "\"lnako\"");
    var diagnostics = newDiagnostics();
    defer diagnostics.deinit();
    var loaded = try project.load(testing.allocator, io, app_root, &diagnostics);
    defer loaded.deinit();
    try testing.expectError(error.ResolveFailed, project.ensureLock(testing.allocator, io, &loaded, &.{}, &diagnostics));

    // 両 runtime 対応を宣言する package は受理する。
    try writeDep(temporary.dir, "\"lnako\", \"cnako\"");
    var diagnostics2 = newDiagnostics();
    defer diagnostics2.deinit();
    var loaded2 = try project.load(testing.allocator, io, app_root, &diagnostics2);
    defer loaded2.deinit();
    var outcome = try project.ensureLock(testing.allocator, io, &loaded2, &.{}, &diagnostics2);
    defer outcome.deinit();
}

test "environmentPackagesUsableは余分なrecordと形状違反と中間symlinkを拒否する" {
    // packages map は graph と key 集合が完全一致し、各 record が
    // environment schema の形状（name/version/id/path/exports/commands）
    // を満たす必要がある。中間 dir（.nako/env 等）が symlink の環境も
    // 受理しない。
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/.nako/env/gen-1/deps/lib");
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-1\n" });
    try temporary.dir.createDirPath(io, "app/src");

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const entries = [_]lock_model.PackageEntry{.{
        .id = "pkg:11111111111111111111111111111111",
        .name = "lib",
        .version = "1.0.0",
        .source = .{ .kind = .registry },
    }};
    var lock = lock_model.Lock{
        .arena = arena_impl,
        .input = .{
            .manifest_sha256 = "sha256:00",
            .profile = "default",
            .target = .{ .os = "macos", .cpu = "aarch64", .abi = "gnu" },
        },
        .packages = &entries,
    };
    const app_root = try temporary.dir.realPathFileAlloc(io, "app", testing.allocator);
    defer testing.allocator.free(app_root);
    const writeEnv = struct {
        fn run(dir: std.Io.Dir, packages_json: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","packages":{s}}}
                \\
            , .{packages_json});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = source });
        }
    }.run;
    const usable = struct {
        fn run(lock_: *lock_model.Lock, root: []const u8) !bool {
            return try project.environmentPackagesUsable(testing.allocator, io, root, lock_, "default");
        }
    }.run;

    const valid =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","path":"src/index.nako3","native":{"path":"bin/lib.dll","libc":"msvc","features":["win32"]},"esm":["index.mjs",{"path":"node.mjs","min-os":"1.0"}]}],"commands":[{"name":"テスト","args":["x"],"josi":[]}]}}
    ;
    try writeEnv(temporary.dir, valid);
    try testing.expect(try usable(&lock, app_root));
    const invalid_artifact_ref =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":[]}]}}
    ;
    try writeEnv(temporary.dir, invalid_artifact_ref);
    try testing.expect(!try usable(&lock, app_root));
    const invalid_empty_artifact =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":""}]}}
    ;
    try writeEnv(temporary.dir, invalid_empty_artifact);
    try testing.expect(!try usable(&lock, app_root));
    const invalid_empty_artifact_path =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":{"path":""}}]}}
    ;
    try writeEnv(temporary.dir, invalid_empty_artifact_path);
    try testing.expect(!try usable(&lock, app_root));
    const invalid_artifact_when =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":{"path":"lib.dll","when":"os =="}}]}}
    ;
    try writeEnv(temporary.dir, invalid_artifact_when);
    try testing.expect(!try usable(&lock, app_root));
    const invalid_array_artifact_path =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":[""]}]}}
    ;
    try writeEnv(temporary.dir, invalid_array_artifact_path);
    try testing.expect(!try usable(&lock, app_root));
    const invalid_artifact_version_overflow =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","exports":[{"name":"lib","native":{"path":"lib.dll","min-os":"999999999999999999999999999999999999"}}]}}
    ;
    try writeEnv(temporary.dir, invalid_artifact_version_overflow);
    try testing.expect(!try usable(&lock, app_root));

    const unknown_root = try std.fmt.allocPrint(testing.allocator,
        \\{{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","packages":{s},"generation":"gen-1"}}
        \\
    , .{valid});
    defer testing.allocator.free(unknown_root);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data = unknown_root });
    const unknown_info = (try project.readEnvironmentInfo(testing.allocator, io, app_root)).?;
    try testing.expectEqual(@as(i64, 0), unknown_info.schema_version);
    try testing.expect(!try usable(&lock, app_root));

    // mutablePaths は schema に合わない item が1つでもあれば文書全体を無効化。
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data =
        \\{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","mutablePaths":[{"bogus":1}],"packages":{}}
    });
    try testing.expect((try project.readEnvironmentInfo(testing.allocator, io, app_root)).?.schema_version == 0);
    try testing.expect(!try usable(&lock, app_root));
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data =
        \\{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","mutablePaths":[{"path":"pkg","sha256":"sha256:bad"}],"packages":{}}
    });
    try testing.expect((try project.readEnvironmentInfo(testing.allocator, io, app_root)).?.schema_version == 0);
    try testing.expect(!try usable(&lock, app_root));
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data =
        \\{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","mutablePaths":[{"path":"","sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}],"packages":{}}
    });
    try testing.expect((try project.readEnvironmentInfo(testing.allocator, io, app_root)).?.schema_version == 0);
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data =
        \\{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","mutablePaths":[{"path":"./pkg","sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}],"packages":{}}
    });
    try testing.expect(!try usable(&lock, app_root));
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/environment.json", .data =
        \\{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","mutablePaths":[{"path":"../outside","sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}],"packages":{}}
    });
    try testing.expect(!try usable(&lock, app_root));

    const windows_separators =
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako\\env\\gen-1\\deps\\lib","exports":[{"name":"lib","path":"src/index.nako3"}],"commands":[{"name":"テスト","args":["x"],"josi":[]}]}}
    ;
    try writeEnv(temporary.dir, windows_separators);
    try testing.expect(try usable(&lock, app_root));

    // 現行世代は environment.json ではなく `.nako/current` で識別する。
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-missing\n" });
    try testing.expect(!try usable(&lock, app_root));
    try temporary.dir.writeFile(io, .{ .sub_path = "app/.nako/current", .data = "gen-1\n" });

    // project 内に実在する unrelated dir でも managed generation 外なら拒否。
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":"src"}}
    );
    try testing.expect(!try usable(&lock, app_root));

    // 余分な record を残した環境は不一致（key 集合の完全一致）。
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib"},"pkg:22222222222222222222222222222222":{"name":"x","version":"1.0.0","path":".nako/env/gen-1/deps/x"}}
    );
    try testing.expect(!try usable(&lock, app_root));
    // name・version が entry と食い違う record は不一致。
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"other","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib"}}
    );
    try testing.expect(!try usable(&lock, app_root));
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"9.9.9","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib"}}
    );
    try testing.expect(!try usable(&lock, app_root));
    // public id entry の id 欠落・未知キー・形状違反は不一致。
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","path":".nako/env/gen-1/deps/lib"}}
    );
    try testing.expect(!try usable(&lock, app_root));
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","extra":1}}
    );
    try testing.expect(!try usable(&lock, app_root));
    try writeEnv(temporary.dir,
        \\{"pkg:11111111111111111111111111111111":{"name":"lib","version":"1.0.0","id":"pkg:11111111111111111111111111111111","path":".nako/env/gen-1/deps/lib","commands":[{"args":["x"]}]}}
    );
    try testing.expect(!try usable(&lock, app_root));

    // 中間 dir が symlink の環境は不一致。`.nako/env` を外部 dir への
    // symlink に差し替え、同じ世代 layout を持つ target を指させる。
    if (builtin.os.tag == .windows) return;
    try temporary.dir.deleteTree(io, "app/.nako/env");
    try temporary.dir.createDirPath(io, "outside/env/gen-1/deps/lib");
    // `app/.nako/env` の親 dir は `app/.nako` のため `../../outside/env`。
    try temporary.dir.symLink(io, "../../outside/env", "app/.nako/env", .{ .is_directory = true });
    try writeEnv(temporary.dir, valid);
    try testing.expect(!try usable(&lock, app_root));
    // 現行世代の実在検査も中間 symlink を追従しない。
    try testing.expect(!project.generationExists(io, app_root, "gen-1"));

    // `.nako` 自体が symlink の場合も environment.json は管理外から
    // 供給されるため不一致（外部 target は変更しない）。
    try temporary.dir.deleteTree(io, "app/.nako");
    try temporary.dir.createDirPath(io, "outside2/env/gen-1/deps/lib");
    try temporary.dir.symLink(io, "../outside2", "app/.nako", .{ .is_directory = true });
    const outside_env = struct {
        fn run(dir: std.Io.Dir, packages_json: []const u8) !void {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\{{"schemaVersion":1,"lockSha256":"sha256:00","profile":"default","runtime":"lnako","packages":{s}}}
                \\
            , .{packages_json});
            defer testing.allocator.free(source);
            try dir.writeFile(io, .{ .sub_path = "outside2/environment.json", .data = source });
        }
    }.run;
    try outside_env(temporary.dir, valid);
    try testing.expect(!try usable(&lock, app_root));
    const outside_stat = try temporary.dir.statFile(io, "app/.nako", .{ .follow_symlinks = false });
    try testing.expect(outside_stat.kind == .sym_link);
}
