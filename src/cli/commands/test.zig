const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const host = @import("../../host.zig");
const compiler_pipeline = @import("../../compiler_pipeline.zig");
const arguments = @import("../arguments.zig");

/// dir 名が管理/VCS dir（`.nako`・`.git`）か。依存 package の
/// materialize 先と VCS 内部はテスト収集対象から外す。
fn isManagedDirName(name: []const u8) bool {
    if (builtin.os.tag == .windows) {
        // Windows では `.NAKO`/`.GIT` も同じ dir を指すため大小文字
        // 非依存で比較する。
        return std.ascii.eqlIgnoreCase(name, ".nako") or std.ascii.eqlIgnoreCase(name, ".git");
    }
    return std.mem.eql(u8, name, ".nako") or std.mem.eql(u8, name, ".git");
}

/// 走査 path が管理/VCS dir（`.nako`・`.git`）配下か。
/// `walkSelectively` で管理 dir には降りないため file 側では到達
/// しないが、entry.path ベースでも除外しておく。
fn isManagedPath(path: []const u8) bool {
    const separators = if (builtin.os.tag == .windows) "/\\" else "/";
    var components = std.mem.splitAny(u8, path, separators);
    while (components.next()) |component| {
        if (isManagedDirName(component)) return true;
    }
    return false;
}

/// walker entry の kind を file/directory/other へ解決する。NFS/FUSE 等
/// `DT_UNKNOWN` を返す fs では `.unknown` のまま報告されるため、
/// no-follow stat で実体を判定する。symlink は follow せず `.sym_link`
/// のまま返る（走査・収集の双方から除外される）。
fn resolveWalkKind(io: std.Io, dir: std.Io.Dir, basename: []const u8, reported: std.Io.File.Kind) !std.Io.File.Kind {
    if (reported != .unknown) return reported;
    const stat = try dir.statFile(io, basename, .{ .follow_symlinks = false });
    return stat.kind;
}

pub fn runTestTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8, forced_mode: lnako.frontend.token.Mode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try stderr.print("{s}: テスト対象を確認できません: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    if (stat.kind != .directory) return runTestFile(allocator, io, path, forced_mode, stdout, stderr);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walkSelectively(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    while (try walker.next(io)) |entry| {
        // `.nako/env/<gen>/deps` 配下の依存 package や残存世代・`.git`
        // 内部はテスト対象にしない。file 単位で除外すると管理 dir の
        // 中身まで走査してしまい、大量の file 走査コストや読み取り不可
        // dir での走査失敗を招くため、dir entry 段階で降りない。
        // NFS/FUSE 等 `DT_UNKNOWN` を返す fs では no-follow stat で実
        // kind を解決する。symlink・特殊 file は対象外のまま。
        const kind = try resolveWalkKind(io, entry.dir, entry.basename, entry.kind);
        if (kind == .directory) {
            if (!isManagedDirName(entry.basename)) {
                var dir_entry = entry;
                dir_entry.kind = .directory;
                try walker.enter(io, dir_entry);
            }
            continue;
        }
        if (kind != .file) continue;
        if (isManagedPath(entry.path)) continue;
        const extension = std.fs.path.extension(entry.path);
        if (!std.ascii.eqlIgnoreCase(extension, ".nako3") and !std.ascii.eqlIgnoreCase(extension, ".dncl") and !std.ascii.eqlIgnoreCase(extension, ".dncl2")) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ path, entry.path }));
    }
    std.mem.sort([]const u8, files.items, {}, arguments.lessThanString);
    var succeeded = true;
    for (files.items) |file| if (!try runTestFile(allocator, io, file, forced_mode, stdout, stderr)) {
        succeeded = false;
    };
    return succeeded;
}

pub fn runTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, forced_mode: lnako.frontend.token.Mode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var ir_program = (try compiler_pipeline.compileInput(allocator, io, path, .{ .forced_mode = forced_mode }, stderr)) orelse return false;
    defer ir_program.deinit();
    var runtime = lnako.runtime.value.Runtime.init(allocator);
    defer runtime.deinit();
    var cli_host = host.CliHost{
        .writer = stdout,
        .error_writer = stderr,
        .io = io,
        .http_server_enabled = ir_program.http_server_plugin_imported,
        .async_task_map = std.AutoHashMap(u64, *host.AsyncOperationTask).init(std.heap.page_allocator),
    };
    defer cli_host.deinit();
    var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.interpreterHost());
    defer interpreter.deinit();
    _ = interpreter.run() catch |err| {
        try stderr.print("{s}: テスト初期化エラー: {s}\n", .{ path, runtime.failureMessage() orelse @errorName(err) });
        return false;
    };
    const results = try interpreter.runTests();
    var succeeded = true;
    for (results) |result| {
        if (result.passed) {
            try stdout.print("ok - {s}: {s}\n", .{ path, result.name });
        } else {
            succeeded = false;
            try stdout.print("not ok - {s}: {s} ({s})\n", .{ path, result.name, result.message });
        }
    }
    if (results.len == 0) try stdout.print("{s}: テスト定義はありません\n", .{path});
    return succeeded;
}

test "isManagedPath は .nako/.git 配下を除外する" {
    // `.nako/env/<gen>/deps` に materialize された依存の source は
    // project のテスト対象ではない（lnako test . で拾わない）。
    try std.testing.expect(isManagedPath(".nako/env/1/deps/lib/main.nako3"));
    try std.testing.expect(isManagedPath("src/.nako/hidden.nako3"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isManagedPath(".nako\\env\\1\\deps\\lib.nako3"));
        // Windows では `.NAKO`/`.GIT` も同じ dir を指す。
        try std.testing.expect(isManagedPath(".NAKO/env/1/deps/lib.nako3"));
        try std.testing.expect(isManagedPath("src/.GIT/objects/ab/cd"));
    } else {
        // POSIX では backslash はファイル名文字（1 component で `.nako` ではない）。
        try std.testing.expect(!isManagedPath(".nako\\env\\1\\deps\\lib.nako3"));
        // POSIX では `.NAKO` は別名の dir（管理 dir ではない）。
        try std.testing.expect(!isManagedPath(".NAKO/env/1/deps/lib.nako3"));
    }
    try std.testing.expect(isManagedPath(".git/objects/ab/cd"));
    try std.testing.expect(!isManagedPath("src/ok.nako3"));
    try std.testing.expect(!isManagedPath("vendor/nako-tools/x.nako3"));
    try std.testing.expect(!isManagedPath("main.nako3"));
}

test "resolveWalkKind は DT_UNKNOWN 相当の entry を stat で判定する" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "a.nako3", .data = "" });
    try temporary.dir.createDir(io, "sub", .default_dir);
    // readdir が kind を返せない fs でも stat 由来の実体で分類される。
    try std.testing.expectEqual(std.Io.File.Kind.file, try resolveWalkKind(io, temporary.dir, "a.nako3", .unknown));
    try std.testing.expectEqual(std.Io.File.Kind.directory, try resolveWalkKind(io, temporary.dir, "sub", .unknown));
    // 報告済み kind はそのまま通す。
    try std.testing.expectEqual(std.Io.File.Kind.file, try resolveWalkKind(io, temporary.dir, "a.nako3", .file));
    if (builtin.os.tag != .windows) {
        try temporary.dir.symLink(io, "a.nako3", "link.nako3", .{});
        // unknown 報告された symlink も no-follow stat が .sym_link を返し
        // 走査・収集対象から外れる。
        try std.testing.expectEqual(std.Io.File.Kind.sym_link, try resolveWalkKind(io, temporary.dir, "link.nako3", .unknown));
    }
}
