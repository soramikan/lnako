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
            var file_provider = lnako.semantic.module_graph.FileProvider{ .io = init.io };
            var graph = lnako.semantic.module_graph.load(allocator, args[1], file_provider.sourceProvider(), .{}) catch |err| {
                try stderr.print("{s}: 読み込みまたは字句解析に失敗しました: {s}\n", .{ args[1], @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            defer graph.deinit();
            if (!graph.succeeded()) {
                for (graph.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
                for (graph.modules) |module| if (module.parsed) |parsed| {
                    for (parsed.diagnostics) |item| try item.render(module.source, stderr);
                };
                try stderr.flush();
                std.process.exit(1);
            }
            var program = try graph.analyze(allocator);
            defer program.deinit();
            if (!program.succeeded()) {
                for (program.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
                try stderr.flush();
                std.process.exit(1);
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
            defer ir_program.deinit();
            var verification = try lnako.ir.verifier.verify(allocator, ir_program);
            defer verification.deinit();
            if (!verification.succeeded()) {
                for (verification.issues) |issue| try stderr.print("IR検証エラー[{s}] {s}: {s}\n", .{ @tagName(issue.code), issue.function_name, issue.message });
                try stderr.flush();
                std.process.exit(1);
            }
            try stdout.print("{s}: 構文・意味・中間表現に問題はありません（{d}モジュール）\n", .{ args[1], graph.modules.len });
        },
        else => try stdout.print("{s}: 実装準備中です\n", .{@tagName(command)}),
    }
}

fn sourceForDiagnostic(graph: lnako.semantic.module_graph.ModuleGraph, file: []const u8) []const u8 {
    for (graph.modules) |module| if (std.mem.eql(u8, module.path, file)) return module.source;
    return "";
}

test "CLIモジュールを読み込める" {
    try std.testing.expect(lnako.version.len > 0);
}
