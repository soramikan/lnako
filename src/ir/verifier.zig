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

// CFGは疎なので、ブロック数の二乗の行列ではなく辺リストからCSR形式の
// 先行・後続リストを構築する。recordEdgeは分岐先検証と重複除去だけを行い、
// 実体のリストは検証走査の完了後に一度だけ作る。
const Edge = struct { source: usize, target: usize };

const EdgeSet = struct {
    edges: std.ArrayList(Edge) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn add(self: *EdgeSet, allocator: std.mem.Allocator, source: usize, target: usize) !bool {
        const key = (@as(u64, target) << 32) | @as(u64, source);
        if (self.seen.contains(key)) return false;
        try self.seen.put(allocator, key, {});
        try self.edges.append(allocator, .{ .source = source, .target = target });
        return true;
    }
};

// CSR形式の辺リスト。offsets[b]..offsets[b+1]がitems上の区切りになる。
const Csr = struct {
    offsets: []usize,
    items: []usize,

    fn list(self: Csr, block: usize) []const usize {
        return self.items[self.offsets[block]..self.offsets[block + 1]];
    }

    fn contains(self: Csr, block: usize, candidate: usize) bool {
        for (self.list(block)) |item| if (item == candidate) return true;
        return false;
    }
};

const ControlFlow = struct {
    predecessors: Csr,
    successors: Csr,

    fn build(allocator: std.mem.Allocator, edges: []const Edge, count: usize) !ControlFlow {
        const pred = try buildCsr(allocator, edges, count, true);
        const succ = try buildCsr(allocator, edges, count, false);
        return .{ .predecessors = pred, .successors = succ };
    }

    fn buildCsr(allocator: std.mem.Allocator, edges: []const Edge, count: usize, by_target: bool) !Csr {
        const offsets = try allocator.alloc(usize, count + 1);
        @memset(offsets, 0);
        for (edges) |edge| offsets[if (by_target) edge.target else edge.source] += 1;
        var total: usize = 0;
        for (offsets[0..count]) |*offset| {
            const length = offset.*;
            offset.* = total;
            total += length;
        }
        offsets[count] = total;
        const items = try allocator.alloc(usize, total);
        const cursor = try allocator.alloc(usize, count);
        @memcpy(cursor, offsets[0..count]);
        for (edges) |edge| {
            const bucket = if (by_target) edge.target else edge.source;
            const member = if (by_target) edge.source else edge.target;
            items[cursor[bucket]] = member;
            cursor[bucket] += 1;
        }
        return .{ .offsets = offsets, .items = items };
    }
};

// 即時支配木のDFS区間による支配関係。到達不能ブロックは木に入らず、
// 従来の行列と同じく自身以外を支配しない結果になる。
const Dominators = struct {
    first: []u32,
    last: []u32,
    reachable: []bool,

    fn dominates(self: Dominators, definition: usize, use: usize) bool {
        return self.reachable[definition] and self.reachable[use] and
            self.first[definition] <= self.first[use] and self.last[use] <= self.last[definition];
    }
};

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

        var edges = EdgeSet{};
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
                        try self.recordEdge(function, &edges, effective_block, target);
                    } else try self.add(.invalid_exception_target, function, block.id, instruction_index, "try_begin命令に例外分岐先がありません");
                } else if (instruction.exception_target != null) {
                    try self.add(.invalid_exception_target, function, block.id, instruction_index, "try_begin以外の命令に例外分岐先があります");
                }
            }
            switch (block.terminator) {
                .none => try self.add(.missing_terminator, function, block.id, null, "基本ブロックに終端命令がありません"),
                .branch => |target| try self.recordEdge(function, &edges, effective_block, target),
                .conditional_branch => |branch| {
                    try self.recordEdge(function, &edges, effective_block, branch.then_block);
                    try self.recordEdge(function, &edges, effective_block, branch.else_block);
                },
                .throw_value => |throw_value| if (throw_value.target) |target| try self.recordEdge(function, &edges, effective_block, target),
                else => {},
            }
        }

        const flow = try ControlFlow.build(self.allocator, edges.edges.items, count);
        const dominators = try computeDominators(self.allocator, flow, count, function.entry);
        const phi_seen = try self.allocator.alloc(u32, count);
        @memset(phi_seen, 0);
        var phi_generation: u32 = 0;
        for (function.blocks, 0..) |block, block_index| {
            const effective_block: ir.BlockId = @intCast(block_index);
            const predecessor_count = flow.predecessors.list(effective_block).len;
            for (block.instructions, 0..) |instruction, instruction_index| {
                if (instruction.opcode == .phi) {
                    if (instruction.phi_incoming.len != predecessor_count) try self.add(.invalid_phi_input_count, function, block.id, instruction_index, "phi入力数が先行ブロック数と一致しません");
                    phi_generation += 1;
                    for (instruction.phi_incoming) |incoming| {
                        if (incoming.predecessor >= count or !flow.predecessors.contains(effective_block, incoming.predecessor)) {
                            try self.add(.invalid_phi_predecessor, function, block.id, instruction_index, "phi入力元が先行ブロックではありません");
                            continue;
                        }
                        if (phi_seen[incoming.predecessor] == phi_generation) {
                            try self.add(.duplicate_phi_predecessor, function, block.id, instruction_index, "同じ先行ブロックから複数のphi入力があります");
                            continue;
                        }
                        phi_seen[incoming.predecessor] = phi_generation;
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

    fn recordEdge(self: *Checker, function: ir.Function, edges: *EdgeSet, source: ir.BlockId, target: ir.BlockId) !void {
        if (target >= function.blocks.len) {
            try self.add(.invalid_branch_target, function, source, null, "分岐先の基本ブロックが存在しません");
            return;
        }
        _ = try edges.add(self.allocator, source, target);
    }

    fn verifyUse(
        self: *Checker,
        function: ir.Function,
        definitions: std.AutoHashMapUnmanaged(ir.ValueId, Definition),
        dominators: Dominators,
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
        if (!dominators.dominates(definition_block, use_block)) {
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

// Cooper-Harvey-Kennedyの反復idom計算。RPO順に処理すると疎なCFGでは
// 数回の走査で収束し、二乗の支配行列と固定点の全要素反復を避けられる。
fn computeDominators(allocator: std.mem.Allocator, flow: ControlFlow, count: usize, entry: ir.BlockId) !Dominators {
    const invalid = std.math.maxInt(usize);
    const order_index = try allocator.alloc(usize, count);
    @memset(order_index, invalid);
    const order = try reversePostOrder(allocator, flow.successors, count, entry, order_index);

    const idom = try allocator.alloc(usize, count);
    @memset(idom, invalid);
    idom[entry] = entry;
    var changed = true;
    while (changed) {
        changed = false;
        for (order[1..]) |block| {
            var new_idom: usize = invalid;
            for (flow.predecessors.list(block)) |predecessor| {
                if (idom[predecessor] == invalid) continue;
                new_idom = if (new_idom == invalid) predecessor else intersectIdom(idom, order_index, predecessor, new_idom);
            }
            if (new_idom != invalid and idom[block] != new_idom) {
                idom[block] = new_idom;
                changed = true;
            }
        }
    }

    const child_head = try allocator.alloc(usize, count);
    @memset(child_head, invalid);
    const child_next = try allocator.alloc(usize, count);
    @memset(child_next, invalid);
    for (order[1..]) |block| {
        if (idom[block] == invalid) continue;
        child_next[block] = child_head[idom[block]];
        child_head[idom[block]] = block;
    }

    const first = try allocator.alloc(u32, count);
    const last = try allocator.alloc(u32, count);
    const reachable = try allocator.alloc(bool, count);
    @memset(reachable, false);
    var tick: u32 = 0;
    const cursor = try allocator.alloc(usize, count);
    @memcpy(cursor, child_head);
    var stack: std.ArrayList(usize) = .empty;
    try stack.append(allocator, entry);
    first[entry] = tick;
    tick += 1;
    reachable[entry] = true;
    while (stack.items.len > 0) {
        const top = stack.items[stack.items.len - 1];
        if (cursor[top] != invalid) {
            const child = cursor[top];
            cursor[top] = child_next[child];
            reachable[child] = true;
            first[child] = tick;
            tick += 1;
            try stack.append(allocator, child);
        } else {
            last[top] = tick;
            tick += 1;
            _ = stack.pop();
        }
    }
    return .{ .first = first, .last = last, .reachable = reachable };
}

fn intersectIdom(idom: []const usize, order_index: []const usize, a_start: usize, b_start: usize) usize {
    var a = a_start;
    var b = b_start;
    while (a != b) {
        while (order_index[a] > order_index[b]) a = idom[a];
        while (order_index[b] > order_index[a]) b = idom[b];
    }
    return a;
}

fn reversePostOrder(allocator: std.mem.Allocator, successors: Csr, count: usize, entry: ir.BlockId, order_index: []usize) ![]usize {
    const visited = try allocator.alloc(bool, count);
    @memset(visited, false);
    var post_order: std.ArrayList(usize) = .empty;
    var stack: std.ArrayList(struct { block: usize, next: usize }) = .empty;
    visited[entry] = true;
    try stack.append(allocator, .{ .block = entry, .next = 0 });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const succs = successors.list(top.block);
        if (top.next < succs.len) {
            const succ = succs[top.next];
            top.next += 1;
            if (!visited[succ]) {
                visited[succ] = true;
                try stack.append(allocator, .{ .block = succ, .next = 0 });
            }
        } else {
            try post_order.append(allocator, top.block);
            _ = stack.pop();
        }
    }
    const order = try allocator.alloc(usize, post_order.items.len);
    for (post_order.items, 0..) |block, index| {
        const position = post_order.items.len - 1 - index;
        order[position] = block;
        order_index[block] = position;
    }
    return order;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const count = 6;
    const edge_list = [_]Edge{ .{ .source = 0, .target = 4 }, .{ .source = 4, .target = 1 }, .{ .source = 4, .target = 2 }, .{ .source = 1, .target = 3 }, .{ .source = 2, .target = 3 }, .{ .source = 3, .target = 4 } };
    const flow = try ControlFlow.build(allocator, &edge_list, count);
    const dominators = try computeDominators(allocator, flow, count, 0);
    const expected = [_][count]bool{
        .{ true, false, false, false, false, false },
        .{ true, true, false, false, true, false },
        .{ true, false, true, false, true, false },
        .{ true, false, false, true, true, false },
        .{ true, false, false, false, true, false },
        .{ false, false, false, false, false, false },
    };
    for (expected, 0..) |row, use_block| {
        for (row, 0..) |dominates, definition_block| {
            if (use_block == definition_block and !dominators.reachable[use_block]) continue;
            try std.testing.expectEqual(dominates, dominators.dominates(definition_block, use_block));
        }
    }
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
