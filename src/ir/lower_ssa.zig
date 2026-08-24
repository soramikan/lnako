const std = @import("std");
const hir = @import("hir.zig");
const ir = @import("nako_ir.zig");

pub fn lower(backing_allocator: std.mem.Allocator, hir_program: hir.Program) !ir.Program {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var functions: std.ArrayList(ir.Function) = .empty;
    for (hir_program.functions) |function| {
        var builder = FunctionBuilder{
            .allocator = allocator,
            .hir_program = hir_program,
            .function = function,
            .next_value = @intCast(function.parameters.len),
        };
        _ = try builder.createBlock("entry");
        for (function.parameters, 0..) |parameter, index| try builder.parameters.append(allocator, .{
            .name = try allocator.dupe(u8, parameter.name),
            .value = @intCast(index),
        });
        _ = try builder.lowerNode(function.body);
        if (!builder.isTerminated()) builder.terminate(.{ .return_value = null });
        try functions.append(allocator, try builder.finish());
    }
    return .{ .arena = arena, .functions = try functions.toOwnedSlice(allocator) };
}

const BlockBuilder = struct {
    id: ir.BlockId,
    name: []const u8,
    instructions: std.ArrayList(ir.Instruction) = .empty,
    terminator: ir.Terminator = .none,
};

const LoopTargets = struct { continue_block: ir.BlockId, break_block: ir.BlockId };

const FunctionBuilder = struct {
    allocator: std.mem.Allocator,
    hir_program: hir.Program,
    function: hir.Function,
    blocks: std.ArrayList(*BlockBuilder) = .empty,
    parameters: std.ArrayList(ir.Parameter) = .empty,
    current: ir.BlockId = 0,
    next_value: ir.ValueId,
    loops: std.ArrayList(LoopTargets) = .empty,

    fn finish(self: *FunctionBuilder) !ir.Function {
        var blocks = try self.allocator.alloc(ir.BasicBlock, self.blocks.items.len);
        for (self.blocks.items, 0..) |block, index| blocks[index] = .{
            .id = block.id,
            .name = block.name,
            .instructions = try block.instructions.toOwnedSlice(self.allocator),
            .terminator = block.terminator,
        };
        return .{
            .id = self.function.id,
            .name = try self.allocator.dupe(u8, self.function.name),
            .parameters = try self.parameters.toOwnedSlice(self.allocator),
            .blocks = blocks,
            .entry = 0,
            .return_type = toType(self.function.return_type),
            .is_async = self.function.is_async,
        };
    }

    fn lowerNode(self: *FunctionBuilder, node_id: hir.NodeId) anyerror!?ir.ValueId {
        const node = self.hir_program.node(node_id);
        return switch (node.kind) {
            .nop => null,
            .block => self.lowerBlock(node),
            .number => try self.emitValue(.const_number, .number, &.{}, node),
            .bigint => try self.emitValue(.const_bigint, .bigint, &.{}, node),
            .boolean => try self.emitValue(.const_boolean, .boolean, &.{}, node),
            .null_value => try self.emitValue(.const_null, .null_value, &.{}, node),
            .string, .string_template => try self.emitValue(.const_string, .string, &.{}, node),
            .load_global => try self.emitValue(.load_global, toType(node.type_hint), &.{}, node),
            .load_local => try self.emitValue(.load_local, toType(node.type_hint), &.{}, node),
            .store_global => try self.lowerStore(.store_global, node),
            .store_local => try self.lowerStore(.store_local, node),
            .destructure_store => try self.lowerVariadic(.destructure_store, .void, node),
            .binary => try self.lowerVariadic(.binary, toType(node.type_hint), node),
            .unary => try self.lowerVariadic(.unary, toType(node.type_hint), node),
            .call => try self.lowerVariadic(.call, toType(node.type_hint), node),
            .call_value => try self.lowerVariadic(.call_value, toType(node.type_hint), node),
            .make_array => try self.lowerVariadic(.make_array, .array, node),
            .make_object => try self.lowerVariadic(.make_object, .object, node),
            .array_get => try self.lowerVariadic(.array_get, .dynamic, node),
            .property_get => try self.lowerVariadic(.property_get, .dynamic, node),
            .array_set => try self.lowerVariadic(.array_set, .void, node),
            .property_set => try self.lowerVariadic(.property_set, .void, node),
            .increment => try self.lowerVariadic(.increment, .void, node),
            .if_statement => self.lowerIf(node),
            .while_statement => self.lowerWhile(node, false),
            .post_test_loop => self.lowerWhile(node, true),
            .repeat_times, .for_statement, .foreach_statement => self.lowerIteratorLoop(node),
            .return_statement => self.lowerReturn(node),
            .break_statement => self.lowerBreak(node),
            .continue_statement => self.lowerContinue(node),
            .closure => try self.emitValue(.make_closure, .function, &.{}, node),
            .try_except => self.lowerTry(node),
            .dynamic_execute => try self.lowerVariadic(.dynamic_execute, .dynamic, node),
            .switch_statement => self.lowerSwitch(node),
            .speed_mode => self.lowerScopedMode(.speed_mode_begin, .speed_mode_end, node),
            .performance_monitor => self.lowerScopedMode(.performance_monitor_begin, .performance_monitor_end, node),
        };
    }

    fn lowerBlock(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        var last: ?ir.ValueId = null;
        for (node.children) |child| {
            if (self.isTerminated()) break;
            last = try self.lowerNode(child);
        }
        return last;
    }

    fn lowerStore(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        const value = if (node.children.len > 0) (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node) else try self.emitUndefined(node);
        try self.emitVoid(opcode, &.{value}, node);
        return value;
    }

    fn lowerVariadic(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, node: hir.Node) !?ir.ValueId {
        var operands: std.ArrayList(ir.ValueId) = .empty;
        for (node.children) |child| if (try self.lowerNode(child)) |value| try operands.append(self.allocator, value);
        if (result_type == .void) {
            try self.emitVoid(opcode, operands.items, node);
            return null;
        }
        return try self.emitValue(opcode, result_type, operands.items, node);
    }

    fn lowerIf(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 3) return error.InvalidHir;
        const condition = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        const then_block = try self.createBlock("if.then");
        const else_block = try self.createBlock("if.else");
        const merge_block = try self.createBlock("if.end");
        self.terminate(.{ .conditional_branch = .{ .condition = condition, .then_block = then_block, .else_block = else_block } });

        self.current = then_block;
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = else_block;
        _ = try self.lowerNode(node.children[2]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerWhile(self: *FunctionBuilder, node: hir.Node, post_test: bool) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const condition_block = try self.createBlock("loop.cond");
        const body_block = try self.createBlock("loop.body");
        const exit_block = try self.createBlock("loop.end");
        self.terminate(.{ .branch = if (post_test) body_block else condition_block });
        try self.loops.append(self.allocator, .{ .continue_block = condition_block, .break_block = exit_block });

        self.current = body_block;
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = condition_block });
        self.current = condition_block;
        const condition = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        self.terminate(.{ .conditional_branch = .{ .condition = condition, .then_block = body_block, .else_block = exit_block } });
        _ = self.loops.pop();
        self.current = exit_block;
        return null;
    }

    fn lowerIteratorLoop(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        var inputs: std.ArrayList(ir.ValueId) = .empty;
        for (node.children[0 .. node.children.len - 1]) |child| {
            const value = (try self.lowerNode(child)) orelse try self.emitUndefined(node);
            try inputs.append(self.allocator, value);
        }
        const iterator = try self.emitValue(.iterator_begin, .dynamic, inputs.items, node);
        const condition_block = try self.createBlock("iterator.cond");
        const body_block = try self.createBlock("iterator.body");
        const exit_block = try self.createBlock("iterator.end");
        self.terminate(.{ .branch = condition_block });
        try self.loops.append(self.allocator, .{ .continue_block = condition_block, .break_block = exit_block });
        self.current = condition_block;
        const has_next = try self.emitValue(.iterator_has_next, .boolean, &.{iterator}, node);
        self.terminate(.{ .conditional_branch = .{ .condition = has_next, .then_block = body_block, .else_block = exit_block } });
        self.current = body_block;
        _ = try self.emitValue(.iterator_next, .dynamic, &.{iterator}, node);
        _ = try self.lowerNode(node.children[node.children.len - 1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = condition_block });
        _ = self.loops.pop();
        self.current = exit_block;
        return null;
    }

    fn lowerReturn(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        const value = if (node.children.len > 0) try self.lowerNode(node.children[0]) else null;
        self.terminate(.{ .return_value = value });
        return value;
    }

    fn lowerBreak(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        _ = node;
        if (self.loops.items.len == 0) {
            self.terminate(.unreachable_terminator);
        } else self.terminate(.{ .branch = self.loops.items[self.loops.items.len - 1].break_block });
        return null;
    }

    fn lowerContinue(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        _ = node;
        if (self.loops.items.len == 0) {
            self.terminate(.unreachable_terminator);
        } else self.terminate(.{ .branch = self.loops.items[self.loops.items.len - 1].continue_block });
        return null;
    }

    fn lowerTry(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const handler_block = try self.createBlock("try.handler");
        const merge_block = try self.createBlock("try.end");
        try self.emitVoid(.try_begin, &.{}, node);
        self.currentBlock().instructions.items[self.currentBlock().instructions.items.len - 1].exception_target = handler_block;
        if (node.children.len > 0) _ = try self.lowerNode(node.children[0]);
        if (!self.isTerminated()) {
            try self.emitVoid(.try_end, &.{}, node);
            self.terminate(.{ .branch = merge_block });
        }
        self.current = handler_block;
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerSwitch(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len == 0) return null;
        const discriminant = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        const merge_block = try self.createBlock("switch.end");
        var index: usize = 2;
        while (index + 1 < node.children.len) : (index += 2) {
            const case_value = (try self.lowerNode(node.children[index])) orelse try self.emitUndefined(node);
            const compare = try self.emitValue(.binary, .boolean, &.{ discriminant, case_value }, node);
            self.currentBlock().instructions.items[self.currentBlock().instructions.items.len - 1].operator = "==";
            const case_block = try self.createBlock("switch.case");
            const next_block = try self.createBlock("switch.next");
            self.terminate(.{ .conditional_branch = .{ .condition = compare, .then_block = case_block, .else_block = next_block } });
            self.current = case_block;
            _ = try self.lowerNode(node.children[index + 1]);
            if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
            self.current = next_block;
        }
        if (node.children.len > 1) _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerScopedMode(self: *FunctionBuilder, begin_opcode: ir.Opcode, end_opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        try self.emitVoid(begin_opcode, &.{}, node);
        const result = if (node.children.len > 0) try self.lowerNode(node.children[node.children.len - 1]) else null;
        if (!self.isTerminated()) try self.emitVoid(end_opcode, &.{}, node);
        return result;
    }

    fn emitUndefined(self: *FunctionBuilder, node: hir.Node) !ir.ValueId {
        return self.emitValue(.const_undefined, .dynamic, &.{}, node);
    }

    fn emitValue(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, operands: []const ir.ValueId, node: hir.Node) !ir.ValueId {
        const value = self.next_value;
        self.next_value += 1;
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = value,
            .opcode = opcode,
            .type = result_type,
            .operands = try self.allocator.dupe(ir.ValueId, operands),
            .name = try self.allocator.dupe(u8, node.name),
            .text = try self.allocator.dupe(u8, node.text),
            .operator = try self.allocator.dupe(u8, node.operator),
            .names = try dupeStrings(self.allocator, node.names),
            .number_value = node.number_value,
            .boolean_value = node.boolean_value,
            .loop_direction = toLoopDirection(node.loop_direction),
            .span = node.span,
        });
        return value;
    }

    fn emitVoid(self: *FunctionBuilder, opcode: ir.Opcode, operands: []const ir.ValueId, node: hir.Node) !void {
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = null,
            .opcode = opcode,
            .type = .void,
            .operands = try self.allocator.dupe(ir.ValueId, operands),
            .name = try self.allocator.dupe(u8, node.name),
            .text = try self.allocator.dupe(u8, node.text),
            .operator = try self.allocator.dupe(u8, node.operator),
            .names = try dupeStrings(self.allocator, node.names),
            .loop_direction = toLoopDirection(node.loop_direction),
            .span = node.span,
        });
    }

    fn createBlock(self: *FunctionBuilder, base_name: []const u8) !ir.BlockId {
        const id: ir.BlockId = @intCast(self.blocks.items.len);
        const block = try self.allocator.create(BlockBuilder);
        block.* = .{ .id = id, .name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ base_name, id }) };
        try self.blocks.append(self.allocator, block);
        return id;
    }

    fn currentBlock(self: *FunctionBuilder) *BlockBuilder {
        return self.blocks.items[self.current];
    }

    fn isTerminated(self: *FunctionBuilder) bool {
        return self.currentBlock().terminator != .none;
    }

    fn terminate(self: *FunctionBuilder, terminator: ir.Terminator) void {
        self.currentBlock().terminator = terminator;
    }
};

fn toType(value: hir.TypeHint) ir.Type {
    return switch (value) {
        .dynamic => .dynamic,
        .number => .number,
        .bigint => .bigint,
        .boolean => .boolean,
        .null_value => .null_value,
        .string => .string,
        .array => .array,
        .object => .object,
        .function => .function,
        .void => .void,
    };
}

fn toLoopDirection(value: @import("../frontend/ast.zig").LoopDirection) ir.LoopDirection {
    return switch (value) {
        .automatic => .automatic,
        .up => .up,
        .down => .down,
    };
}

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |value, index| result[index] = try allocator.dupe(u8, value);
    return result;
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
    var program = try lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("main__$entry").?;
    try std.testing.expect(entry.blocks.len >= 7);
    try std.testing.expect(entry.blocks[0].terminator == .branch);
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
    var program = try lower(std.testing.allocator, hir_program);
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

test "速度優先領域の本体と境界をIRへ保持する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    var parsed = try parser.parse(std.testing.allocator, "「全て」で実行速度優先\nA=1\nここまで\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower(std.testing.allocator, hir_program);
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
