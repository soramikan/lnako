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

test "監視領域を抜けるで抜けた後の例外は生存中のハンドラへ配送される" {
    // ループ内の監視領域を抜けると、そのtryのハンドラは畳かれなければ
    // ならない。畳まれない場合、frame.handlersへ死んだハンドラが残り、
    // 後続の例外が終了済みの監視ブロックへ誤配送されてループ本体を
    // ゾンビ再実行する（ハンドラの合流点がループ内にあるため）。
    const source =
        "エラー監視\n" ++
        "3回\n" ++
        "エラー監視\n" ++
        "「到達した」を表示\n" ++
        "抜ける\n" ++
        "エラーならば\n" ++
        "「捕捉:{エラーメッセージ}」を表示\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "「後続」を表示\n" ++
        "「最後」のエラー発生\n" ++
        "エラーならば\n" ++
        "「外捕捉:{エラーメッセージ}」を表示\n" ++
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
    try std.testing.expectEqualStrings("到達した\n後続\n外捕捉:最後\n", host.written());
}

test "監視領域を続けるで抜けた後の例外は生存中のハンドラへ配送される" {
    const source =
        "エラー監視\n" ++
        "3回\n" ++
        "エラー監視\n" ++
        "もし、回数=2ならば\n" ++
        "続ける\n" ++
        "ここまで\n" ++
        "回数を表示\n" ++
        "エラーならば\n" ++
        "「捕捉:{回数}」を表示\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "「後続」を表示\n" ++
        "「最後」のエラー発生\n" ++
        "エラーならば\n" ++
        "「外捕捉:{エラーメッセージ}」を表示\n" ++
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
    try std.testing.expectEqualStrings("1\n3\n後続\n外捕捉:最後\n", host.written());
}

test "監視領域を戻るで抜けても後続例外は正しいハンドラへ配送される" {
    const source =
        "●Fとは\n" ++
        "エラー監視\n" ++
        "「F内」で戻る\n" ++
        "エラーならば\n" ++
        "「F捕捉」を表示\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "F()を表示\n" ++
        "エラー監視\n" ++
        "「最後」のエラー発生\n" ++
        "エラーならば\n" ++
        "「外捕捉:{エラーメッセージ}」を表示\n" ++
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
    try std.testing.expectEqualStrings("F内\n外捕捉:最後\n", host.written());
}

test "ネストした監視領域を抜けるは内側から順にハンドラを畳く" {
    const source =
        "エラー監視\n" ++
        "3回\n" ++
        "エラー監視\n" ++
        "エラー監視\n" ++
        "「到達した」を表示\n" ++
        "抜ける\n" ++
        "エラーならば\n" ++
        "「内捕捉:{エラーメッセージ}」を表示\n" ++
        "ここまで\n" ++
        "エラーならば\n" ++
        "「中捕捉」を表示\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "「後続」を表示\n" ++
        "「最後」のエラー発生\n" ++
        "エラーならば\n" ++
        "「外捕捉:{エラーメッセージ}」を表示\n" ++
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
    try std.testing.expectEqualStrings("到達した\n後続\n外捕捉:最後\n", host.written());
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
