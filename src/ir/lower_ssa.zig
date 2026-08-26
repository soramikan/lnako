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
        if (!builder.isTerminated()) builder.terminate(.{ .return_value = builder.implicitResult() });
        var lowered = try builder.finish();
        try assignDispatchSiteIds(&lowered);
        try functions.append(allocator, lowered);
    }
    const module_entries = try allocator.alloc(ir.FunctionId, hir_program.modules.len);
    for (hir_program.modules, 0..) |module, index| module_entries[index] = module.entry_function;
    const module_names = try allocator.alloc([]const u8, hir_program.modules.len);
    const module_paths = try allocator.alloc([]const u8, hir_program.modules.len);
    for (hir_program.modules, 0..) |module, index| {
        module_names[index] = try allocator.dupe(u8, module.name);
        module_paths[index] = try allocator.dupe(u8, module.path);
    }
    return .{
        .arena = arena,
        .functions = try functions.toOwnedSlice(allocator),
        .module_entries = module_entries,
        .module_names = module_names,
        .module_paths = module_paths,
    };
}

/// Assigns deterministic dispatch identities before any optimizer can clone,
/// fold, or remove instructions.  Function IDs are stable within a lowered
/// program and the low word is the source/CFG traversal ordinal, so IDs do not
/// depend on absolute paths or allocator addresses.
fn assignDispatchSiteIds(function: *ir.Function) !void {
    var ordinal: u64 = 0;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.opcode != .call or instruction.direct_callee != null or !instruction.is_builtin_call) continue;
            ordinal += 1;
            if (ordinal > std.math.maxInt(u32)) return error.DispatchSiteIdOverflow;
            instruction.site_id = (@as(u64, function.id) << 32) | ordinal;
        }
    }
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
    exception_handlers: std.ArrayList(ir.BlockId) = .empty,

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
            .captures = try dupeStrings(self.allocator, self.function.captures),
            .blocks = blocks,
            .entry = 0,
            .return_type = toType(self.function.return_type),
            .is_async = self.function.is_async,
            .is_test = self.function.is_test,
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
            .binary => if (isLogicalOperator(node.operator)) try self.lowerLogical(node) else try self.lowerFallible(.binary, toType(node.type_hint), node),
            .unary => try self.lowerVariadic(.unary, toType(node.type_hint), node),
            .call => try self.lowerCall(.call, node),
            .call_value => try self.lowerCall(.call_value, node),
            .make_array => try self.lowerVariadic(.make_array, .array, node),
            .make_object => try self.lowerVariadic(.make_object, .object, node),
            .array_get => try self.lowerVariadic(.array_get, .dynamic, node),
            .property_get => try self.lowerVariadic(.property_get, .dynamic, node),
            .array_set => try self.lowerFallibleVoid(.array_set, node),
            .property_set => try self.lowerFallibleVoid(.property_set, node),
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
            .throw_statement => self.lowerThrow(node),
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

    fn lowerCall(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !ir.ValueId {
        const result = (try self.lowerVariadic(opcode, toType(node.type_hint), node)) orelse return error.InvalidCallResult;
        try self.lowerExceptionCheck(node);
        return result;
    }

    fn lowerFallible(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, node: hir.Node) !ir.ValueId {
        const result = (try self.lowerVariadic(opcode, result_type, node)) orelse return error.InvalidFallibleResult;
        try self.lowerExceptionCheck(node);
        return result;
    }

    fn lowerFallibleVoid(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        _ = try self.lowerVariadic(opcode, .void, node);
        try self.lowerExceptionCheck(node);
        return null;
    }

    fn lowerExceptionCheck(self: *FunctionBuilder, node: hir.Node) !void {
        const pending = try self.emitValue(.exception_pending, .boolean, &.{}, node);
        const exception_block = if (self.exception_handlers.items.len > 0)
            self.exception_handlers.items[self.exception_handlers.items.len - 1]
        else
            try self.createBlock("exception.propagate");
        const continue_block = try self.createBlock("exception.continue");
        self.terminate(.{ .conditional_branch = .{ .condition = pending, .then_block = exception_block, .else_block = continue_block } });
        if (self.exception_handlers.items.len == 0) {
            self.current = exception_block;
            self.terminate(.propagate_exception);
        }
        self.current = continue_block;
    }

    fn lowerLogical(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len != 2) return error.InvalidHir;
        const left = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        const left_predecessor = self.current;
        const right_block = try self.createBlock("logical.right");
        const merge_block = try self.createBlock("logical.end");
        const is_and = std.mem.eql(u8, node.operator, "&&") or std.mem.eql(u8, node.operator, "and");
        self.terminate(.{ .conditional_branch = .{
            .condition = left,
            .then_block = if (is_and) right_block else merge_block,
            .else_block = if (is_and) merge_block else right_block,
        } });

        self.current = right_block;
        const right = (try self.lowerNode(node.children[1])) orelse try self.emitUndefined(node);
        const right_predecessor = self.current;
        var incoming: std.ArrayList(ir.PhiIncoming) = .empty;
        try incoming.append(self.allocator, .{ .predecessor = left_predecessor, .value = left });
        if (!self.isTerminated()) {
            self.terminate(.{ .branch = merge_block });
            try incoming.append(self.allocator, .{ .predecessor = right_predecessor, .value = right });
        }

        self.current = merge_block;
        const result = self.next_value;
        self.next_value += 1;
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = result,
            .opcode = .phi,
            .type = toType(node.type_hint),
            .phi_incoming = try incoming.toOwnedSlice(self.allocator),
            .operator = try self.allocator.dupe(u8, node.operator),
            .span = node.span,
        });
        return result;
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
        try self.exception_handlers.append(self.allocator, handler_block);
        if (node.children.len > 0) _ = try self.lowerNode(node.children[0]);
        _ = self.exception_handlers.pop();
        if (!self.isTerminated()) {
            try self.emitVoid(.try_end, &.{}, node);
            self.terminate(.{ .branch = merge_block });
        }
        self.current = handler_block;
        try self.emitVoid(.exception_take, &.{}, node);
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerThrow(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        const value = if (node.children.len > 0)
            (try self.lowerNode(node.children[node.children.len - 1])) orelse try self.emitUndefined(node)
        else
            try self.emitUndefined(node);
        self.terminate(.{ .throw_value = .{
            .value = value,
            .target = if (self.exception_handlers.items.len > 0) self.exception_handlers.items[self.exception_handlers.items.len - 1] else null,
        } });
        return value;
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
            .is_builtin_call = node.is_builtin_call,
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
            .is_builtin_call = node.is_builtin_call,
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

    fn implicitResult(self: *FunctionBuilder) ?ir.ValueId {
        const instructions = self.currentBlock().instructions.items;
        if (instructions.len == 0) return null;
        const last = instructions[instructions.len - 1];
        if (last.opcode != .store_global or !std.mem.eql(u8, last.name, "それ") or last.operands.len != 1) return null;
        return last.operands[0];
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

fn isLogicalOperator(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or
        std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
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
    var program = try lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("logical__$entry").?;
    var phi_count: usize = 0;
    var logical_binary_count: usize = 0;
    var display_blocks: usize = 0;
    for (entry.blocks) |block| {
        var has_display = false;
        for (block.instructions) |instruction| {
            if (instruction.opcode == .phi) phi_count += 1;
            if (instruction.opcode == .binary and isLogicalOperator(instruction.operator)) logical_binary_count += 1;
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
    var program = try lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("exception__$entry").?;
    var throw_count: usize = 0;
    for (entry.blocks) |block| switch (block.terminator) {
        .throw_value => |throw_value| {
            throw_count += 1;
            try std.testing.expect(throw_value.target != null);
            try std.testing.expect(throw_value.target.? < entry.blocks.len);
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
    var program = try lower(std.testing.allocator, hir_program);
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
    var program = try lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const entry = program.findFunction("assignment_exception__$entry").?;
    var saw_checked_assignment = false;
    for (entry.blocks) |block| for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .array_set) continue;
        try std.testing.expect(index + 1 < block.instructions.len);
        try std.testing.expectEqual(ir.Opcode.exception_pending, block.instructions[index + 1].opcode);
        try std.testing.expect(block.terminator == .conditional_branch);
        saw_checked_assignment = true;
    };
    try std.testing.expect(saw_checked_assignment);
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
    var first = try lower(std.testing.allocator, first_hir);
    defer first.deinit();

    var second_parsed = try parser.parse(std.testing.allocator, source, "/tmp/other.nako3");
    defer second_parsed.deinit();
    var second_analyzed = try semantic.analyze(std.testing.allocator, second_parsed.root.?, "/tmp/other.nako3");
    defer second_analyzed.deinit();
    var second_hir = try hir.lowerSingle(std.testing.allocator, second_parsed.root.?, "main", "/tmp/other.nako3", second_analyzed);
    defer second_hir.deinit();
    var second = try lower(std.testing.allocator, second_hir);
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

test "利用者関数名のbuiltin衝突と動的plugin命令にはsite IDを付けない" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");

    var collision_parsed = try parser.parse(std.testing.allocator, "●表示とは\n99で戻る\nここまで\n表示()を表示\n", "collision.nako3");
    defer collision_parsed.deinit();
    var collision_analyzed = try semantic.analyze(std.testing.allocator, collision_parsed.root.?, "collision.nako3");
    defer collision_analyzed.deinit();
    var collision_hir = try hir.lowerSingle(std.testing.allocator, collision_parsed.root.?, "collision", "collision.nako3", collision_analyzed);
    defer collision_hir.deinit();
    var collision = try lower(std.testing.allocator, collision_hir);
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
    var dynamic_hir = try hir.lower(std.testing.allocator, &.{dynamic_parsed.root.?}, &.{"dynamic-plugin"}, &.{"dynamic-plugin.nako3"}, dynamic_analyzed);
    defer dynamic_hir.deinit();
    var dynamic = try lower(std.testing.allocator, dynamic_hir);
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
