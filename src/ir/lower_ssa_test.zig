const std = @import("std");
const hir = @import("hir.zig");
const ir = @import("nako_ir.zig");
const lower_ssa = @import("lower_ssa.zig");

test "ユーザー関数は『それ』を呼び出しごとのスコープで扱う" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "●Fとは\n1に2を足す\nここまで\nF\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var user_function: ?ir.Function = null;
    for (program.functions) |function| {
        if (!std.mem.endsWith(u8, function.name, "$entry")) user_function = function;
    }
    const function = user_function.?;
    // ユーザー関数はsore_scope=true。呼出しごとの『それ』スコープは実行側が
    // 入口で退避・初期化し全終端で復元するため、IRの命令列にはスコープ管理を
    // 混ぜない（typed ABIやresult_store解析の対象命令を増やさない）。
    try std.testing.expect(function.sore_scope);
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            try std.testing.expect(!std.mem.eql(u8, instruction.name, "$それ"));
        }
    }
    // 末尾が命令呼出しの場合、暗黙戻り値は`null`（=実行側が現在の『それ』を返す）。
    const last_block = function.blocks[function.blocks.len - 1];
    try std.testing.expect(last_block.terminator == .return_value);
    try std.testing.expect(last_block.terminator.return_value == null);
    // モジュールエントリは呼び出し側と同じスコープで動くため対象外。
    const entry = program.findFunction("main__$entry").?;
    try std.testing.expect(!entry.sore_scope);
}

test "HIRから分岐とループを含むSSA IRを生成する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=0\nA<3の間\nもしA=1ならば\nA=A+1\n違えば\nA=A+2\nここまで\nここまで\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("main__$entry").?;
    try std.testing.expect(entry.blocks.len >= 7);
    try std.testing.expect(entry.blocks[0].terminator == .branch);
}

test "論理演算の右辺を短絡分岐とPHIへ変換する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=0かつ表示(\"NG\")\nB=1または表示(\"NG\")\n", "logical.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "logical.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "logical", "logical.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("logical__$entry").?;
    var phi_count: usize = 0;
    var logical_binary_count: usize = 0;
    var display_blocks: usize = 0;
    for (entry.blocks) |block| {
        var has_display = false;
        for (block.instructions) |instruction| {
            if (instruction.opcode == .phi) phi_count += 1;
            const operator = instruction.operator;
            const is_logical = std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or
                std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
            if (instruction.opcode == .binary and is_logical) logical_binary_count += 1;
            if (instruction.opcode == .call and std.mem.eql(u8, instruction.name, "表示")) has_display = true;
        }
        if (has_display) display_blocks += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), phi_count);
    try std.testing.expectEqual(@as(usize, 0), logical_binary_count);
    try std.testing.expectEqual(@as(usize, 2), display_blocks);
}

test "条件分岐と例外監視を明示的な制御フローへ変換する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "A=1\nAで条件分岐\n1ならば\nB=1\nここまで\n違えば\nB=2\nここまで\nここまで\nエラー監視\nA=2\nエラーならば\nB=3\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("main__$entry").?;
    var saw_equality = false;
    var saw_exception_edge = false;
    for (entry.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .binary and std.mem.eql(u8, instruction.operator, "==")) saw_equality = true;
        if (instruction.opcode == .try_begin and instruction.exception_target != null) saw_exception_edge = true;
    };
    try std.testing.expect(saw_equality);
    try std.testing.expect(saw_exception_edge);
}

test "エラー発生を最内側の例外分岐先付きthrowへ変換する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "エラー監視\nエラー監視\n『内』のエラー発生\nエラーならば\nここまで\nエラーならば\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "exception.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "exception.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "exception", "exception.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("exception__$entry").?;
    var throw_count: usize = 0;
    for (entry.blocks) |block| switch (block.terminator) {
        .throw_value => |throw_value| {
            throw_count += 1;
            try std.testing.expect(throw_value.target != null);
            try std.testing.expect(throw_value.target.? < entry.blocks.len);
            try std.testing.expect(throw_value.site_id != null);
            try std.testing.expect((throw_value.site_id.? & 0x8000_0000) != 0);
            try std.testing.expect(throw_value.coerce_to_error_message);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), throw_count);
}

test "失敗し得る二項演算の直後に例外分岐を生成する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "エラー監視\nA=1n+1\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "arithmetic-exception.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "arithmetic-exception.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "arithmetic_exception", "arithmetic-exception.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("arithmetic_exception__$entry").?;
    var saw_checked_binary = false;
    for (entry.blocks) |block| for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .binary) continue;
        try std.testing.expect(index + 1 < block.instructions.len);
        try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
        try std.testing.expect(block.terminator == .conditional_branch);
        saw_checked_binary = true;
    };
    try std.testing.expect(saw_checked_binary);
}

test "失敗し得る添字代入の直後に例外分岐を生成する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "エラー監視\nNULL[0]=2\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "assignment-exception.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "assignment-exception.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "assignment_exception", "assignment-exception.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("assignment_exception__$entry").?;
    var saw_checked_assignment = false;
    for (entry.blocks) |block| for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .element_set) continue;
        try std.testing.expect(index + 1 < block.instructions.len);
        try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
        try std.testing.expect(block.terminator == .conditional_branch);
        saw_checked_assignment = true;
    };
    try std.testing.expect(saw_checked_assignment);
}

test "単項演算の変換失敗を直後の例外分岐で捕捉する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    // The frontend rejects unary plus and lowers minus to multiplication.
    // Substitute arithmetic unary HIR to exercise its exception boundary.
    const source = "A=1n\nエラー監視\nB=!(A)\n「到達してはいけない」を表示\nエラーならば\nエラーメッセージを表示\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "unary-exception.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "unary-exception.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "unary_exception", "unary-exception.nako3", analyzed);
    defer hir_program.deinit();
    for (hir_program.nodes) |*node| {
        if (node.kind == .unary) {
            node.operator = "+";
            node.type_hint = .dynamic;
        }
    }
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("unary_exception__$entry").?;
    var checked: usize = 0;
    for (entry.blocks) |block| for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .unary) continue;
        try std.testing.expect(index + 1 < block.instructions.len);
        try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
        try std.testing.expect(block.terminator == .conditional_branch);
        const handler = entry.blocks[block.terminator.conditional_branch.then_block];
        try std.testing.expect(handler.instructions.len > 0);
        try std.testing.expectEqual(ir.Opcode.exception_take, handler.instructions[0].opcode);
        checked += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), checked);
}

test "速度優先領域の本体と境界をIRへ保持する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "「全て」で実行速度優先\nA=1\nここまで\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("main__$entry").?;
    var begin_index: ?usize = null;
    var store_index: ?usize = null;
    var end_index: ?usize = null;
    for (entry.blocks[0].instructions, 0..) |instruction, index| {
        if (instruction.opcode == .speed_mode_begin) begin_index = index;
        if (instruction.opcode == .store_global) store_index = index;
        if (instruction.opcode == .speed_mode_end) end_index = index;
    }
    try std.testing.expect(begin_index != null and store_index != null and end_index != null);
    try std.testing.expect(begin_index.? < store_index.? and store_index.? < end_index.?);
}

test "dispatch site IDはパス非依存で一意かつclone後も保持する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "1を表示\n2を表示\n";
    var first_parsed = try parser.parse(std.testing.allocator, source, "first.nako3");
    defer first_parsed.deinit();
    var first_analyzed = try semantic.analyze(std.testing.allocator, first_parsed.root.?, "first.nako3");
    defer first_analyzed.deinit();
    var first_hir = try hir.lowerSingle(std.testing.allocator, first_parsed.root.?, "main", "first.nako3", first_analyzed);
    defer first_hir.deinit();
    var first = try lower_ssa.lower(std.testing.allocator, first_hir);
    defer first.deinit();

    var second_parsed = try parser.parse(std.testing.allocator, source, "/tmp/other.nako3");
    defer second_parsed.deinit();
    var second_analyzed = try semantic.analyze(std.testing.allocator, second_parsed.root.?, "/tmp/other.nako3");
    defer second_analyzed.deinit();
    var second_hir = try hir.lowerSingle(std.testing.allocator, second_parsed.root.?, "main", "/tmp/other.nako3", second_analyzed);
    defer second_hir.deinit();
    var second = try lower_ssa.lower(std.testing.allocator, second_hir);
    defer second.deinit();

    const first_entry = first.findFunction("main__$entry").?;
    const second_entry = second.findFunction("main__$entry").?;
    var first_sites: [2]u64 = undefined;
    var second_sites: [2]u64 = undefined;
    var first_count: usize = 0;
    var second_count: usize = 0;
    for (first_entry.blocks) |block| for (block.instructions) |instruction| if (instruction.site_id) |site_id| {
        try std.testing.expect(first_count < first_sites.len);
        first_sites[first_count] = site_id;
        first_count += 1;
    };
    for (second_entry.blocks) |block| for (block.instructions) |instruction| if (instruction.site_id) |site_id| {
        try std.testing.expect(second_count < second_sites.len);
        second_sites[second_count] = site_id;
        second_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), first_count);
    try std.testing.expectEqualSlices(u64, first_sites[0..first_count], second_sites[0..second_count]);
    try std.testing.expect(first_sites[0] != first_sites[1]);

    var cloned = try first.clone(std.testing.allocator);
    defer cloned.deinit();
    const cloned_entry = cloned.findFunction("main__$entry").?;
    var clone_count: usize = 0;
    for (cloned_entry.blocks) |block| for (block.instructions) |instruction| if (instruction.site_id) |site_id| {
        try std.testing.expectEqual(first_sites[clone_count], site_id);
        clone_count += 1;
    };
    try std.testing.expectEqual(first_count, clone_count);
}

test "builtin dispatchとglobal readのsite IDを別namespaceで安定化する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "PIを表示\n永遠を表示\n", "global-sites.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "global-sites.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "global-sites.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    const entry = program.findFunction("main__$entry").?;
    var dispatch_sites: [2]u64 = undefined;
    var global_sites: [2]u64 = undefined;
    var dispatch_count: usize = 0;
    var global_count: usize = 0;
    for (entry.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.site_id) |site_id| {
            try std.testing.expectEqual(ir.Opcode.call, instruction.opcode);
            try std.testing.expect(dispatch_count < dispatch_sites.len);
            dispatch_sites[dispatch_count] = site_id;
            dispatch_count += 1;
        }
        if (instruction.global_site_id) |site_id| {
            try std.testing.expectEqual(ir.Opcode.load_global, instruction.opcode);
            try std.testing.expect(global_count < global_sites.len);
            global_sites[global_count] = site_id;
            global_count += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), dispatch_count);
    try std.testing.expectEqual(@as(usize, 2), global_count);
    try std.testing.expectEqual(@as(u64, 1), dispatch_sites[0]);
    try std.testing.expectEqual(@as(u64, 2), dispatch_sites[1]);
    try std.testing.expectEqual(@as(u64, 1), global_sites[0]);
    try std.testing.expectEqual(@as(u64, 2), global_sites[1]);
}

test "global read/writeのsite IDを同じaccess namespaceで安定化する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "ファイルコピーデフォルト動作を表示\nファイルコピーデフォルト動作=\"上書\"\nファイルコピーデフォルト動作を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "global-binding-sites.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "global-binding-sites.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "global-binding-sites.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    const entry = program.findFunction("main__$entry").?;
    const expected_opcodes = [_]ir.Opcode{ .load_global, .store_global, .load_global };
    var access_count: usize = 0;
    for (entry.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.global_site_id) |site_id| {
            try std.testing.expect(access_count < expected_opcodes.len);
            try std.testing.expectEqual(expected_opcodes[access_count], instruction.opcode);
            try std.testing.expectEqual(@as(u64, access_count + 1), site_id);
            access_count += 1;
        }
    };
    try std.testing.expectEqual(expected_opcodes.len, access_count);
}

test "catalog literalのsite IDをglobal readと別namespaceで付与する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const source = "はいを表示\nいいえを表示\n真を表示\n偽を表示\nオンを表示\nオフを表示\nNULLを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "literal-sites.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "literal-sites.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "literal-sites.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    const entry = program.findFunction("main__$entry").?;
    var literal_count: usize = 0;
    var expected_id: u64 = 1;
    for (entry.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.literal_site_id) |site_id| {
            try std.testing.expect(instruction.opcode == .const_boolean or instruction.opcode == .const_null);
            try std.testing.expectEqual(expected_id, site_id);
            try std.testing.expect(instruction.global_site_id == null);
            literal_count += 1;
            expected_id += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 7), literal_count);
}

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
    const program = try lower_ssa.lower(allocator, hir_program);
    return .{ .parsed = parsed, .analyzed = analyzed, .hir_program = hir_program, .program = program };
}

/// iterator_has_nextの結果値で分岐する条件ブロックから繰り返しの出口を
/// 特定する。has_nextと分岐の間には例外チェックのexception_pending分岐が
/// 挟まるため、結果値を条件に持つ終端を探す。
fn findIteratorLoopExit(function: ir.Function) ?ir.BlockId {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.opcode != .iterator_has_next) continue;
            const has_next = instruction.result orelse return null;
            for (function.blocks) |branch_block| {
                if (branch_block.terminator != .conditional_branch) continue;
                if (branch_block.terminator.conditional_branch.condition == has_next)
                    return branch_block.terminator.conditional_branch.else_block;
            }
            return null;
        }
    }
    return null;
}

test "反復ガードはiterator_has_next直後にexception_pendingで監視配送する" {
    // `N回`ガードの抽象関係比較はカスタムvalueOfを反復ごとに呼び得るため、
    // 失敗時に残る保留例外をhas_nextの結果分岐より先に検査する。
    var fixture = try lowerSourceForTest(std.testing.allocator, "3回\nここまで\n");
    defer fixture.program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();

    const entry = fixture.program.findFunction("main__$entry").?;
    var found = false;
    for (entry.blocks) |block| {
        for (block.instructions, 0..) |instruction, index| {
            if (instruction.opcode != .iterator_has_next) continue;
            found = true;
            try std.testing.expect(index + 1 < block.instructions.len);
            try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
            try std.testing.expect(block.terminator == .conditional_branch);
            const pending = block.instructions[index + 1].result.?;
            try std.testing.expectEqual(pending, block.terminator.conditional_branch.condition);
        }
    }
    try std.testing.expect(found);
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

test "利用者関数名のbuiltin衝突と動的plugin命令にはsite IDを付けない" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");

    var collision_parsed = try parser.parse(std.testing.allocator, "●表示とは\n99で戻る\nここまで\n表示()を表示\n", "collision.nako3");
    defer collision_parsed.deinit();
    var collision_analyzed = try semantic.analyze(std.testing.allocator, collision_parsed.root.?, "collision.nako3");
    defer collision_analyzed.deinit();
    var collision_hir = try hir.lowerSingle(std.testing.allocator, collision_parsed.root.?, "collision", "collision.nako3", collision_analyzed);
    defer collision_hir.deinit();
    var collision = try lower_ssa.lower(std.testing.allocator, collision_hir);
    defer collision.deinit();
    var collision_calls: usize = 0;
    for (collision.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call) continue;
        collision_calls += 1;
        try std.testing.expect(!instruction.is_builtin_call);
        try std.testing.expect(instruction.site_id == null);
    };
    try std.testing.expect(collision_calls > 0);

    var dynamic_parsed = try parser.parse(std.testing.allocator, "外部追加()\n", "dynamic-plugin.nako3");
    defer dynamic_parsed.deinit();
    var dynamic_analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "dynamic-plugin",
        .path = "dynamic-plugin.nako3",
        .root = dynamic_parsed.root.?,
        .allows_dynamic_commands = true,
    }});
    defer dynamic_analyzed.deinit();
    var dynamic_hir = try hir.lower(std.testing.allocator, &.{dynamic_parsed.root.?}, &.{"dynamic-plugin"}, &.{"dynamic-plugin.nako3"}, &.{&.{}}, dynamic_analyzed);
    defer dynamic_hir.deinit();
    var dynamic = try lower_ssa.lower(std.testing.allocator, dynamic_hir);
    defer dynamic.deinit();
    var dynamic_calls: usize = 0;
    for (dynamic.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call) continue;
        dynamic_calls += 1;
        try std.testing.expect(!instruction.is_builtin_call);
        try std.testing.expect(instruction.site_id == null);
    };
    try std.testing.expectEqual(@as(usize, 1), dynamic_calls);
}
