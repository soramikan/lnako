const std = @import("std");
const parser = @import("../../frontend/parser.zig");
const semantic = @import("../../semantic/analyzer.zig");
const hir = @import("../../ir/hir.zig");
const lower_ssa = @import("../../ir/lower_ssa.zig");
const istate = @import("state.zig");
const shared = @import("shared.zig");

const Interpreter = istate.Interpreter;
const BufferHost = istate.BufferHost;
const Runtime = shared.Runtime;

fn compileForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    parsed: parser.ParseResult,
    analyzed: semantic.Program,
    hir_program: hir.Program,
    ir_program: @import("../../ir/nako_ir.zig").Program,
} {
    const parsed = try parser.parse(allocator, source, "exception-boundary.nako3");
    const analyzed = try semantic.analyze(allocator, parsed.root.?, "exception-boundary.nako3");
    const hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "exception-boundary.nako3", analyzed);
    const ir_program = try lower_ssa.lower(allocator, hir_program);
    return .{ .parsed = parsed, .analyzed = analyzed, .hir_program = hir_program, .ir_program = ir_program };
}

test "テスト実行は前のテストの保留例外を次へ漏らさない" {
    const source =
        "●テスト:失敗とは\n" ++
        "\"first\"のエラー発生\n" ++
        "ここまで\n" ++
        "●テスト:次とは\n" ++
        "エラー監視\n" ++
        "0と1がASSERT等\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();

    const results = try interpreter.runTests();
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(!results[0].passed);
    try std.testing.expect(results[1].passed);
    try std.testing.expectEqualStrings("AssertionFailed\n", host.written());
}

test "タイマーcallbackは前のcallbackの保留例外を次へ漏らさない" {
    const source =
        "0秒後には\n" ++
        "\"timer\"のエラー発生\n" ++
        "ここまで\n" ++
        "0秒後には\n" ++
        "エラー監視\n" ++
        "0と1がASSERT等\n" ++
        "エラーならば\n" ++
        "エラーメッセージを表示\n" ++
        "ここまで\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();

    _ = try interpreter.run();
    try std.testing.expectEqualStrings("AssertionFailed\n", host.written());
}
