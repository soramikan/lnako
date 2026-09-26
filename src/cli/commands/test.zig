const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const host = @import("../../host.zig");
const compiler_pipeline = @import("../../compiler_pipeline.zig");
const arguments = @import("../arguments.zig");

/// 走査 path が管理/VCS dir（`.nako`・`.git`）配下か。依存 package の
/// materialize 先と VCS 内部はテスト収集対象から外す。
fn isManagedPath(path: []const u8) bool {
    const separators = if (builtin.os.tag == .windows) "/\\" else "/";
    var components = std.mem.splitAny(u8, path, separators);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".nako") or std.mem.eql(u8, component, ".git")) return true;
    }
    return false;
}

pub fn runTestTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8, forced_mode: lnako.frontend.token.Mode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try stderr.print("{s}: テスト対象を確認できません: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    if (stat.kind != .directory) return runTestFile(allocator, io, path, forced_mode, stdout, stderr);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // `.nako/env/<gen>/deps` 配下の依存 package や残存世代は対象
        // ディレクトリ走査のテスト対象にしない（依存の初期化コードや
        // 単独実行できない module まで実行されてしまう）。
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
    } else {
        // POSIX では backslash はファイル名文字（1 component で `.nako` ではない）。
        try std.testing.expect(!isManagedPath(".nako\\env\\1\\deps\\lib.nako3"));
    }
    try std.testing.expect(isManagedPath(".git/objects/ab/cd"));
    try std.testing.expect(!isManagedPath("src/ok.nako3"));
    try std.testing.expect(!isManagedPath("vendor/nako-tools/x.nako3"));
    try std.testing.expect(!isManagedPath("main.nako3"));
}
