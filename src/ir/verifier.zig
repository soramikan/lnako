const std = @import("std");
const ir = @import("nako_ir.zig");

pub const IssueCode = enum {
    invalid_entry_block,
    invalid_block_id,
    missing_terminator,
    invalid_branch_target,
    duplicate_value,
    undefined_value,
    value_does_not_dominate_use,
    invalid_result_type,
    invalid_phi_position,
    invalid_phi_predecessor,
    invalid_phi_input_count,
    duplicate_phi_predecessor,
    invalid_exception_target,
    invalid_direct_callee,
};

pub const Issue = struct {
    code: IssueCode,
    function_name: []const u8,
    block: ?ir.BlockId,
    instruction_index: ?usize,
    message: []const u8,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    issues: []Issue,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: Report) bool {
        return self.issues.len == 0;
    }
};

const Definition = struct { block: ?ir.BlockId, instruction_index: ?usize };

pub fn verify(backing_allocator: std.mem.Allocator, program: ir.Program) !Report {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var checker = Checker{ .allocator = arena.allocator(), .function_count = program.functions.len };
    for (program.functions) |function| try checker.verifyFunction(function);
    return .{ .arena = arena, .issues = try checker.issues.toOwnedSlice(checker.allocator) };
}

const Checker = struct {
    allocator: std.mem.Allocator,
    function_count: usize,
    issues: std.ArrayList(Issue) = .empty,

    fn verifyFunction(self: *Checker, function: ir.Function) !void {
        const count = function.blocks.len;
        if (count == 0 or function.entry >= count) {
            try self.add(.invalid_entry_block, function, null, null, "エントリ基本ブロックが存在しません");
            return;
        }
        var definitions: std.AutoHashMapUnmanaged(ir.ValueId, Definition) = .empty;
        for (function.parameters) |parameter| {
            if (definitions.contains(parameter.value)) {
                try self.add(.duplicate_value, function, function.entry, null, "引数のSSA値が重複しています");
            } else try definitions.put(self.allocator, parameter.value, .{ .block = null, .instruction_index = null });
        }

        const predecessors = try self.allocator.alloc(bool, count * count);
        @memset(predecessors, false);
        for (function.blocks, 0..) |block, block_index| {
            const effective_block: ir.BlockId = @intCast(block_index);
            if (block.id != block_index) try self.add(.invalid_block_id, function, block.id, null, "基本ブロックIDと配列位置が一致しません");
            var saw_non_phi = false;
            for (block.instructions, 0..) |instruction, instruction_index| {
                if (instruction.opcode == .phi) {
                    if (saw_non_phi) try self.add(.invalid_phi_position, function, block.id, instruction_index, "phi命令は基本ブロックの先頭へ置く必要があります");
                } else saw_non_phi = true;
                if (instruction.result) |value| {
                    if (instruction.type == .void or !producesValue(instruction.opcode)) try self.add(.invalid_result_type, function, block.id, instruction_index, "値を返さない命令がSSA値を定義しています");
                    if (definitions.contains(value)) {
                        try self.add(.duplicate_value, function, block.id, instruction_index, "SSA値が複数回定義されています");
                    } else try definitions.put(self.allocator, value, .{ .block = effective_block, .instruction_index = instruction_index });
                } else if (producesValue(instruction.opcode) or instruction.type != .void) {
                    try self.add(.invalid_result_type, function, block.id, instruction_index, "命令の結果SSA値と型が一致しません");
                }
                if (instruction.opcode != .phi and instruction.phi_incoming.len > 0) try self.add(.invalid_phi_position, function, block.id, instruction_index, "phi以外の命令にphi入力があります");
                if (instruction.direct_callee) |callee| {
                    if (instruction.opcode != .call or callee >= self.function_count) try self.add(.invalid_direct_callee, function, block.id, instruction_index, "直接呼び出し先が存在しないかcall命令ではありません");
                }
                if (instruction.opcode == .try_begin) {
                    if (instruction.exception_target) |target| {
                        try self.recordEdge(function, predecessors, effective_block, target);
                    } else try self.add(.invalid_exception_target, function, block.id, instruction_index, "try_begin命令に例外分岐先がありません");
                } else if (instruction.exception_target != null) {
                    try self.add(.invalid_exception_target, function, block.id, instruction_index, "try_begin以外の命令に例外分岐先があります");
                }
            }
            switch (block.terminator) {
                .none => try self.add(.missing_terminator, function, block.id, null, "基本ブロックに終端命令がありません"),
                .branch => |target| try self.recordEdge(function, predecessors, effective_block, target),
                .conditional_branch => |branch| {
                    try self.recordEdge(function, predecessors, effective_block, branch.then_block);
                    try self.recordEdge(function, predecessors, effective_block, branch.else_block);
                },
                .throw_value => |throw_value| if (throw_value.target) |target| try self.recordEdge(function, predecessors, effective_block, target),
                else => {},
            }
        }

        const dominators = try computeDominators(self.allocator, predecessors, count, function.entry);
        for (function.blocks, 0..) |block, block_index| {
            const effective_block: ir.BlockId = @intCast(block_index);
            const predecessor_count = countPredecessors(predecessors, count, effective_block);
            for (block.instructions, 0..) |instruction, instruction_index| {
                if (instruction.opcode == .phi) {
                    if (instruction.phi_incoming.len != predecessor_count) try self.add(.invalid_phi_input_count, function, block.id, instruction_index, "phi入力数が先行ブロック数と一致しません");
                    const seen = try self.allocator.alloc(bool, count);
                    @memset(seen, false);
                    for (instruction.phi_incoming) |incoming| {
                        if (incoming.predecessor >= count or !predecessors[effective_block * count + incoming.predecessor]) {
                            try self.add(.invalid_phi_predecessor, function, block.id, instruction_index, "phi入力元が先行ブロックではありません");
                            continue;
                        }
                        if (seen[incoming.predecessor]) {
                            try self.add(.duplicate_phi_predecessor, function, block.id, instruction_index, "同じ先行ブロックから複数のphi入力があります");
                            continue;
                        }
                        seen[incoming.predecessor] = true;
                        try self.verifyUse(function, definitions, dominators, incoming.predecessor, function.blocks[incoming.predecessor].instructions.len, incoming.value, block.id, instruction_index);
                    }
                } else {
                    for (instruction.operands) |operand| {
                        try self.verifyUse(function, definitions, dominators, effective_block, instruction_index, operand, block.id, instruction_index);
                    }
                }
            }
            switch (block.terminator) {
                .conditional_branch => |branch| try self.verifyUse(function, definitions, dominators, effective_block, block.instructions.len, branch.condition, block.id, null),
                .return_value => |value| if (value) |operand| try self.verifyUse(function, definitions, dominators, effective_block, block.instructions.len, operand, block.id, null),
                .throw_value => |throw_value| {
                    try self.verifyUse(function, definitions, dominators, effective_block, block.instructions.len, throw_value.value, block.id, null);
                    if (throw_value.target) |target| if (target >= function.blocks.len) {
                        try self.add(.invalid_exception_target, function, block.id, null, "throw命令の例外分岐先が範囲外です");
                    };
                },
                else => {},
            }
        }
    }

    fn recordEdge(self: *Checker, function: ir.Function, predecessors: []bool, source: ir.BlockId, target: ir.BlockId) !void {
        if (target >= function.blocks.len) {
            try self.add(.invalid_branch_target, function, source, null, "分岐先の基本ブロックが存在しません");
            return;
        }
        predecessors[target * function.blocks.len + source] = true;
    }

    fn verifyUse(
        self: *Checker,
        function: ir.Function,
        definitions: std.AutoHashMapUnmanaged(ir.ValueId, Definition),
        dominators: []const bool,
        use_block: ir.BlockId,
        use_index: usize,
        value: ir.ValueId,
        report_block: ir.BlockId,
        report_index: ?usize,
    ) !void {
        const definition = definitions.get(value) orelse {
            try self.add(.undefined_value, function, report_block, report_index, "未定義のSSA値を使用しています");
            return;
        };
        const definition_block = definition.block orelse return;
        if (definition_block == use_block) {
            if (definition.instruction_index.? >= use_index) try self.add(.value_does_not_dominate_use, function, report_block, report_index, "SSA値が定義より前に使用されています");
            return;
        }
        const count = function.blocks.len;
        if (!dominators[use_block * count + definition_block]) {
            try self.add(.value_does_not_dominate_use, function, report_block, report_index, "SSA値の定義が使用箇所を支配していません");
        }
    }

    fn add(self: *Checker, code: IssueCode, function: ir.Function, block: ?ir.BlockId, instruction_index: ?usize, message: []const u8) !void {
        try self.issues.append(self.allocator, .{
            .code = code,
            .function_name = try self.allocator.dupe(u8, function.name),
            .block = block,
            .instruction_index = instruction_index,
            .message = message,
        });
    }
};

fn producesValue(opcode: ir.Opcode) bool {
    return switch (opcode) {
        .store_global, .store_local, .destructure_store, .array_set, .property_set, .increment, .try_begin, .try_end, .exception_take, .speed_mode_begin, .speed_mode_end, .performance_monitor_begin, .performance_monitor_end => false,
        else => true,
    };
}

fn countPredecessors(predecessors: []const bool, count: usize, block: ir.BlockId) usize {
    var result: usize = 0;
    for (0..count) |source| if (predecessors[block * count + source]) {
        result += 1;
    };
    return result;
}

fn computeDominators(allocator: std.mem.Allocator, predecessors: []const bool, count: usize, entry: ir.BlockId) ![]bool {
    // The CFG is usually sparse. Build predecessor lists once so each
    // intersection visits actual edges instead of scanning all blocks.
    var offsets = try allocator.alloc(usize, count + 1);
    defer allocator.free(offsets);
    var incoming: std.ArrayList(usize) = .empty;
    defer incoming.deinit(allocator);
    for (0..count) |block| {
        offsets[block] = incoming.items.len;
        for (0..count) |predecessor| {
            if (predecessors[block * count + predecessor]) try incoming.append(allocator, predecessor);
        }
    }
    offsets[count] = incoming.items.len;
    const dominators = try allocator.alloc(bool, count * count);
    for (0..count) |block| for (0..count) |candidate| {
        dominators[block * count + candidate] = block != entry or candidate == entry;
    };
    for (0..count) |candidate| dominators[entry * count + candidate] = candidate == entry;

    var changed = true;
    while (changed) {
        changed = false;
        for (0..count) |block| {
            if (block == entry) continue;
            const block_predecessors = incoming.items[offsets[block]..offsets[block + 1]];
            const has_predecessor = block_predecessors.len > 0;
            for (0..count) |candidate| {
                var value = candidate == block;
                if (candidate != block and has_predecessor) {
                    value = true;
                    for (block_predecessors) |predecessor| {
                        value = value and dominators[predecessor * count + candidate];
                    }
                }
                const index = block * count + candidate;
                if (dominators[index] != value) {
                    dominators[index] = value;
                    changed = true;
                }
            }
        }
    }
    return dominators;
}

fn makeTestProgram(allocator: std.mem.Allocator) !struct { hir_program: @import("hir.zig").Program, ir_program: ir.Program, parsed: @import("../frontend/parser.zig").ParseResult, analyzed: @import("../semantic/analyzer.zig").Program } {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const hir = @import("hir.zig");
    const lower_ssa = @import("lower_ssa.zig");
    const parsed = try parser.parse(allocator, "A=0\nもしA=0ならば\nA=1\n違えば\nA=2\nここまで\nAを表示\n", "main.nako3");
    const analyzed = try semantic.analyze(allocator, parsed.root.?, "main.nako3");
    const hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
    const ir_program = try lower_ssa.lower(allocator, hir_program);
    return .{ .hir_program = hir_program, .ir_program = ir_program, .parsed = parsed, .analyzed = analyzed };
}

test "支配関係は分岐合流・後方辺・到達不能ブロックを保持する" {
    const count = 6;
    var predecessors = [_]bool{false} ** (count * count);
    const edges = [_][2]usize{ .{ 0, 4 }, .{ 4, 1 }, .{ 4, 2 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 4 } };
    for (edges) |edge| predecessors[edge[1] * count + edge[0]] = true;
    const dominators = try computeDominators(std.testing.allocator, &predecessors, count, 0);
    defer std.testing.allocator.free(dominators);
    const expected = [_][count]bool{
        .{ true, false, false, false, false, false },
        .{ true, true, false, false, true, false },
        .{ true, false, true, false, true, false },
        .{ true, false, false, true, true, false },
        .{ true, false, false, false, true, false },
        .{ false, false, false, false, false, true },
    };
    for (expected, 0..) |row, block| try std.testing.expectEqualSlices(bool, &row, dominators[block * count .. (block + 1) * count]);
}

test "生成したSSA IRを検証する" {
    var fixture = try makeTestProgram(std.testing.allocator);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var report = try verify(std.testing.allocator, fixture.ir_program);
    defer report.deinit();
    try std.testing.expect(report.succeeded());
}

test "不正な分岐先と未定義値を拒否する" {
    var fixture = try makeTestProgram(std.testing.allocator);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    fixture.ir_program.functions[0].blocks[0].terminator = .{ .branch = 9999 };
    fixture.ir_program.functions[0].blocks[0].id = 9999;
    var changed_operand = false;
    for (fixture.ir_program.functions[0].blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.operands.len > 0) {
            instruction.operands[0] = 9999;
            changed_operand = true;
            break;
        }
    };
    try std.testing.expect(changed_operand);
    var report = try verify(std.testing.allocator, fixture.ir_program);
    defer report.deinit();
    var branch_issue = false;
    var block_issue = false;
    var value_issue = false;
    for (report.issues) |issue| {
        if (issue.code == .invalid_branch_target) branch_issue = true;
        if (issue.code == .invalid_block_id) block_issue = true;
        if (issue.code == .undefined_value) value_issue = true;
    }
    try std.testing.expect(branch_issue);
    try std.testing.expect(block_issue);
    try std.testing.expect(value_issue);
}

test "不正なphi入力を拒否する" {
    var fixture = try makeTestProgram(std.testing.allocator);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    const instruction = &fixture.ir_program.functions[0].blocks[0].instructions[0];
    instruction.opcode = .phi;
    instruction.phi_incoming = try fixture.ir_program.arena.allocator().dupe(ir.PhiIncoming, &.{.{ .predecessor = 0, .value = instruction.result.? }});
    var report = try verify(std.testing.allocator, fixture.ir_program);
    defer report.deinit();
    var input_count_issue = false;
    var predecessor_issue = false;
    for (report.issues) |issue| {
        if (issue.code == .invalid_phi_input_count) input_count_issue = true;
        if (issue.code == .invalid_phi_predecessor) predecessor_issue = true;
    }
    try std.testing.expect(input_count_issue);
    try std.testing.expect(predecessor_issue);
}

test "call以外と範囲外の直接呼び出し先を拒否する" {
    var fixture = try makeTestProgram(std.testing.allocator);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    const instruction = &fixture.ir_program.functions[0].blocks[0].instructions[0];
    instruction.direct_callee = @intCast(fixture.ir_program.functions.len);
    var report = try verify(std.testing.allocator, fixture.ir_program);
    defer report.deinit();
    try std.testing.expect(!report.succeeded());
    var direct_issue = false;
    for (report.issues) |issue| if (issue.code == .invalid_direct_callee) {
        direct_issue = true;
    };
    try std.testing.expect(direct_issue);
}
