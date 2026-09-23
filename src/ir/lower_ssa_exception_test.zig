const std = @import("std");
const hir = @import("hir.zig");
const ir = @import("nako_ir.zig");
const lower = @import("lower_ssa.zig").lower;

fn lowerSourceForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    parsed: @import("../frontend/parser.zig").ParseResult,
    analyzed: @import("../semantic/analyzer.zig").Program,
    hir_program: hir.Program,
    program: ir.Program,
} {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const parsed = try parser.parse(allocator, source, "lower-test.nako3");
    const analyzed = try semantic.analyze(allocator, parsed.root.?, "lower-test.nako3");
    const hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "lower-test.nako3", analyzed);
    const program = try lower(allocator, hir_program);
    return .{ .parsed = parsed, .analyzed = analyzed, .hir_program = hir_program, .program = program };
}

/// ループ条件ブロック（iterator_has_nextを持つ）から繰り返しの出口を特定する。
fn findIteratorLoopExit(function: ir.Function) ?ir.BlockId {
    for (function.blocks) |block| {
        if (block.terminator != .conditional_branch) continue;
        for (block.instructions) |instruction| {
            if (instruction.opcode == .iterator_has_next) return block.terminator.conditional_branch.else_block;
        }
    }
    return null;
}

test "監視領域を抜けるループ脱出は抜ける側のtry_endをemitする" {
    // ループ内の監視領域を抜ける経路では、抜ける側のtry_begin分のtry_endを
    // emitしてからループ出口へ分岐する。try_endを欠くとInterpreterの
    // frame.handlersへ終了済みハンドラが残り、後続例外を死んだ監視
    // ブロックへ誤配送する。ループを囲む外側の監視は脱出先でも有効なため
    // 畳まない。
    var fixture = try lowerSourceForTest(std.testing.allocator, "エラー監視\n" ++
        "3回\n" ++
        "エラー監視\n" ++
        "エラー監視\n" ++
        "抜ける\n" ++
        "エラーならば\nここまで\n" ++
        "エラーならば\nここまで\n" ++
        "ここまで\n" ++
        "エラーならば\nここまで\n");
    defer fixture.program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();

    const entry = fixture.program.findFunction("main__$entry").?;
    const loop_exit = findIteratorLoopExit(entry).?;
    var try_begin_count: usize = 0;
    var try_end_count: usize = 0;
    var break_block: ?ir.BasicBlock = null;
    for (entry.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.opcode == .try_begin) try_begin_count += 1;
            if (instruction.opcode == .try_end) try_end_count += 1;
        }
        switch (block.terminator) {
            .branch => |target| {
                if (target == loop_exit) break_block = block;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), try_begin_count);
    // 抜ける経路の2つ（内側・中間の監視）+ 中間・外側の監視の正常終了経路
    // それぞれ1つずつ。
    try std.testing.expectEqual(@as(usize, 4), try_end_count);
    const edge = break_block.?;
    try std.testing.expect(edge.instructions.len >= 2);
    try std.testing.expectEqual(ir.Opcode.try_end, edge.instructions[edge.instructions.len - 1].opcode);
    try std.testing.expectEqual(ir.Opcode.try_end, edge.instructions[edge.instructions.len - 2].opcode);
}

test "監視領域を続ける経路は抜ける側のtry_endをemitする" {
    // 続けるもループ脱出と同じく監視領域を横切るため、抜ける側のtry_endを
    // emitしてからループ条件ブロックへ分岐する。
    var fixture = try lowerSourceForTest(std.testing.allocator, "3回\n" ++
        "エラー監視\n" ++
        "もし回数=2ならば\n" ++
        "続ける\n" ++
        "ここまで\n" ++
        "回数を表示\n" ++
        "エラーならば\nここまで\n" ++
        "ここまで\n");
    defer fixture.program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();

    const entry = fixture.program.findFunction("main__$entry").?;
    var condition_block: ?ir.BlockId = null;
    var try_begin_count: usize = 0;
    var try_end_count: usize = 0;
    var continue_has_try_end = false;
    for (entry.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.opcode == .try_begin) try_begin_count += 1;
            if (instruction.opcode == .try_end) try_end_count += 1;
            if (instruction.opcode == .iterator_has_next) condition_block = block.id;
        }
    }
    try std.testing.expect(condition_block != null);
    for (entry.blocks) |block| switch (block.terminator) {
        .branch => |target| {
            if (target == condition_block.? and
                block.instructions.len > 0 and
                block.instructions[block.instructions.len - 1].opcode == .try_end)
            {
                continue_has_try_end = true;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), try_begin_count);
    // 続ける経路と監視本体の正常終了経路の2箇所へtry_endをemitする。
    try std.testing.expectEqual(@as(usize, 2), try_end_count);
    try std.testing.expect(continue_has_try_end);
}

test "監視領域を戻るで抜ける経路はreturnの前にtry_endをemitする" {
    // 関数脱出でも残りの監視ハンドラを畳み、try_begin/try_endを全経路で
    // 対に保つ。
    var fixture = try lowerSourceForTest(std.testing.allocator, "●Fとは\n" ++
        "エラー監視\n" ++
        "1で戻る\n" ++
        "エラーならば\nここまで\n" ++
        "ここまで\n" ++
        "F()\n");
    defer fixture.program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();

    var user_function: ?ir.Function = null;
    for (fixture.program.functions) |function| {
        if (!std.mem.endsWith(u8, function.name, "$entry")) user_function = function;
    }
    const function = user_function.?;
    var try_begin_count: usize = 0;
    var try_end_count: usize = 0;
    var return_has_try_end = false;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.opcode == .try_begin) try_begin_count += 1;
            if (instruction.opcode == .try_end) try_end_count += 1;
        }
        if (block.terminator == .return_value and
            block.instructions.len > 0 and
            block.instructions[block.instructions.len - 1].opcode == .try_end)
        {
            return_has_try_end = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), try_begin_count);
    try std.testing.expectEqual(@as(usize, 1), try_end_count);
    try std.testing.expect(return_has_try_end);
}

test "ループを囲む監視領域はループ脱出で畳まない" {
    // 監視領域の内側にあるループから抜けても監視領域自体は続くため、
    // 脱出経路へtry_endをemitしない（emitすると有効なハンドラを剥がし、
    // 監視内の後続例外が捕捉されなくなる）。
    var fixture = try lowerSourceForTest(std.testing.allocator, "エラー監視\n" ++
        "3回\n" ++
        "抜ける\n" ++
        "ここまで\n" ++
        "エラーならば\nここまで\n");
    defer fixture.program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();

    const entry = fixture.program.findFunction("main__$entry").?;
    const loop_exit = findIteratorLoopExit(entry).?;
    var try_begin_count: usize = 0;
    var try_end_count: usize = 0;
    var break_has_try_end = false;
    for (entry.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.opcode == .try_begin) try_begin_count += 1;
            if (instruction.opcode == .try_end) try_end_count += 1;
        }
        switch (block.terminator) {
            .branch => |target| if (target == loop_exit) {
                for (block.instructions) |instruction| {
                    if (instruction.opcode == .try_end) break_has_try_end = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), try_begin_count);
    try std.testing.expectEqual(@as(usize, 1), try_end_count);
    try std.testing.expect(!break_has_try_end);
}

test "エラー監視を飛び越す抜ける・続けるはtry_endでhandlerを外す" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    // 『抜ける』『続ける』が『エラー監視』本体を非局所分岐で抜けるとき、
    // 分岐経路にtry_endをemitしてInterpreterのframe.handlersから外す。
    // 外さないと取り残されたhandlerが後続の例外を捕捉し、静的な
    // exception_targetを使うAOTと分岐する（PR #173レビュー指摘）。
    const sources = [_]struct { source: []const u8, unwinds: usize }{
        .{ .source = "3回\nエラー監視\n抜ける。\nエラーならば\n「h」を表示\nここまで\nここまで\n", .unwinds = 1 },
        .{ .source = "3回\nエラー監視\n続ける。\nエラーならば\n「h」を表示\nここまで\nここまで\n", .unwinds = 1 },
        .{ .source = "3回\nエラー監視\nエラー監視\n抜ける。\nエラーならば\nここまで\nエラーならば\nここまで\nここまで\n", .unwinds = 2 },
        // 条件分岐のcase節の『抜ける』も同じく監視を飛び越す
        .{ .source = "A=1\nAで条件分岐\n1ならば\nエラー監視\n抜ける。\nエラーならば\n「h」を表示\nここまで\nここまで\nここまで\n", .unwinds = 1 },
    };
    for (sources) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.source, "unwind.nako3");
        defer parsed.deinit();
        var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "unwind.nako3");
        defer analyzed.deinit();
        try std.testing.expect(analyzed.succeeded());
        var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "unwind", "unwind.nako3", analyzed);
        defer hir_program.deinit();
        var program = try lower(std.testing.allocator, hir_program);
        defer program.deinit();
        const entry = program.findFunction("unwind__$entry").?;
        var unwind_blocks: usize = 0;
        var unwind_total: usize = 0;
        for (entry.blocks) |block| {
            var try_ends: usize = 0;
            for (block.instructions) |instruction| {
                if (instruction.opcode == .try_end) try_ends += 1;
            }
            if (try_ends == 0 or block.terminator != .branch) continue;
            // 監視本体の正常出口もtry_end+branchなので、try.endへ向かう
            // 経路は除外し、繰り返し・条件分岐の境界へ向かう経路だけ数える。
            if (std.mem.startsWith(u8, entry.blocks[block.terminator.branch].name, "try.end")) continue;
            unwind_blocks += 1;
            unwind_total += try_ends;
        }
        try std.testing.expectEqual(@as(usize, 1), unwind_blocks);
        try std.testing.expectEqual(case.unwinds, unwind_total);
    }
}
