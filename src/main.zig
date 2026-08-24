const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    const args = if (process_args.len > 1) process_args[1..] else process_args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const command = lnako.parseCommand(args) catch |err| {
        try stdout.print("コマンドラインエラー: {s}\n\n", .{@errorName(err)});
        try lnako.usage(stdout);
        return;
    };

    switch (command) {
        .help => try lnako.usage(stdout),
        .version => try stdout.print("lnako {s}\n", .{lnako.version}),
        .check => {
            if (args.len < 2) {
                try stderr.writeAll("check: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            var ir_program = (try compileInput(allocator, init.io, args[1], false, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            try stdout.print("{s}: 構文・意味・中間表現に問題はありません\n", .{args[1]});
        },
        .run => {
            if (args.len < 2) {
                try stderr.writeAll("run: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const compat_js = hasArgument(args[2..], "--compat-js");
            var ir_program = (try compileInput(allocator, init.io, args[1], compat_js, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            var runtime = lnako.runtime.value.Runtime.init(allocator);
            defer runtime.deinit();
            var cli_host = CliHost{ .writer = stdout };
            var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.host());
            defer interpreter.deinit();
            _ = interpreter.run() catch |err| {
                try stderr.print("実行時エラー: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .test_command => {
            if (args.len < 2) {
                try stderr.writeAll("test: 入力ファイルまたはディレクトリを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const succeeded = try runTestTarget(allocator, init.io, args[1], stdout, stderr);
            if (!succeeded) {
                try stdout.flush();
                try stderr.flush();
                std.process.exit(1);
            }
        },
        else => try stdout.print("{s}: 実装準備中です\n", .{@tagName(command)}),
    }
}

const CliHost = struct {
    writer: *std.Io.Writer,

    fn host(self: *CliHost) lnako.runtime.interpreter.Host {
        return .{ .context = self, .writeFn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
    }
};

fn compileInput(allocator: std.mem.Allocator, io: std.Io, path: []const u8, compat_js: bool, stderr: *std.Io.Writer) !?lnako.ir.nako_ir.Program {
    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    var graph = lnako.semantic.module_graph.load(allocator, path, file_provider.sourceProvider(), .{ .compat_js = compat_js }) catch |err| {
        try stderr.print("{s}: 読み込みまたは字句解析に失敗しました: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer graph.deinit();
    if (!graph.succeeded()) {
        for (graph.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        for (graph.modules) |module| if (module.parsed) |parsed| {
            for (parsed.diagnostics) |item| try item.render(module.source, stderr);
        };
        return null;
    }
    var program = try graph.analyze(allocator);
    defer program.deinit();
    if (!program.succeeded()) {
        for (program.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        return null;
    }
    var roots: std.ArrayList(*lnako.frontend.ast.Node) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        try roots.append(allocator, module.parsed.?.root.?);
        try names.append(allocator, module.name);
        try paths.append(allocator, module.path);
    }
    var hir_program = try lnako.ir.hir.lower(allocator, roots.items, names.items, paths.items, program);
    defer hir_program.deinit();
    var ir_program = try lnako.ir.lower_ssa.lower(allocator, hir_program);
    errdefer ir_program.deinit();
    var verification = try lnako.ir.verifier.verify(allocator, ir_program);
    defer verification.deinit();
    if (!verification.succeeded()) {
        for (verification.issues) |issue| try stderr.print("IR検証エラー[{s}] {s}: {s}\n", .{ @tagName(issue.code), issue.function_name, issue.message });
        ir_program.deinit();
        return null;
    }
    return ir_program;
}

fn runTestTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try stderr.print("{s}: テスト対象を確認できません: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    if (stat.kind != .directory) return runTestFile(allocator, io, path, stdout, stderr);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.path), ".nako3")) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ path, entry.path }));
    }
    std.mem.sort([]const u8, files.items, {}, lessThanString);
    var succeeded = true;
    for (files.items) |file| if (!try runTestFile(allocator, io, file, stdout, stderr)) {
        succeeded = false;
    };
    return succeeded;
}

fn runTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var ir_program = (try compileInput(allocator, io, path, false, stderr)) orelse return false;
    defer ir_program.deinit();
    var runtime = lnako.runtime.value.Runtime.init(allocator);
    defer runtime.deinit();
    var cli_host = CliHost{ .writer = stdout };
    var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.host());
    defer interpreter.deinit();
    _ = interpreter.run() catch |err| {
        try stderr.print("{s}: テスト初期化エラー: {s}\n", .{ path, @errorName(err) });
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

fn hasArgument(arguments: []const []const u8, expected: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, expected)) return true;
    return false;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn sourceForDiagnostic(graph: lnako.semantic.module_graph.ModuleGraph, file: []const u8) []const u8 {
    for (graph.modules) |module| if (std.mem.eql(u8, module.path, file)) return module.source;
    return "";
}

test "CLIモジュールを読み込める" {
    try std.testing.expect(lnako.version.len > 0);
}
