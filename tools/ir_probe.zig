const std = @import("std");
const lnako = @import("lnako");

/// 開発・差分テスト用に、引数で受け取ったなでしこソースをNako SSA IRへ変換する。
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    for (process_args[1..], 0..) |source, index| {
        if (index > 0) try stdout.writeAll("\n---\n\n");
        var parsed = try lnako.frontend.parser.parse(allocator, source, "main.nako3");
        defer parsed.deinit();
        if (!parsed.succeeded()) return error.ParseFailed;
        var analyzed = try lnako.semantic.analyzer.analyze(allocator, parsed.root.?, "main.nako3");
        defer analyzed.deinit();
        if (!analyzed.succeeded()) return error.SemanticAnalysisFailed;
        var hir_program = try lnako.ir.hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
        defer hir_program.deinit();
        var ir_program = try lnako.ir.lower_ssa.lower(allocator, hir_program);
        defer ir_program.deinit();
        var report = try lnako.ir.verifier.verify(allocator, ir_program);
        defer report.deinit();
        if (!report.succeeded()) return error.IrVerificationFailed;
        try lnako.ir.printer.write(ir_program, stdout);
    }
}
