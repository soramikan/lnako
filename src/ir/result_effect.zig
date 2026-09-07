const std = @import("std");
const ir = @import("nako_ir.zig");

/// Effects relevant to the interpreter's implicit `それ` write after a known
/// IR call.  A function that can read the incoming value prevents its caller
/// from dropping the caller's previous `それ` before the call.  Unknown calls
/// are deliberately treated as readers; this includes callback values and
/// dynamic execution.
pub const Summary = struct {
    reads_result: bool = false,
    may_throw: bool = false,
};

pub const Analysis = struct {
    summaries: []Summary,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.summaries);
        self.* = undefined;
    }
};

/// Per-function proof used by Prepared Interpreter.  Each flag corresponds to
/// one instruction in the matching basic block.  A true flag is only emitted
/// for a direct IR call whose implicit result store is overwritten on every
/// path before `それ` can be returned or observed.
pub const Plan = struct {
    omit_result_store: [][]bool,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.omit_result_store) |flags| allocator.free(flags);
        allocator.free(self.omit_result_store);
        self.* = undefined;
    }
};

fn directCallee(program: ir.Program, instruction: ir.Instruction) ?ir.FunctionId {
    if (instruction.direct_callee) |callee| {
        return if (callee < program.functions.len) callee else null;
    }
    for (program.functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, instruction.name)) return @intCast(index);
    }
    return null;
}

fn isResultName(name: []const u8) bool {
    return std.mem.eql(u8, name, "それ");
}

fn readsIncomingResult(program: ir.Program, instruction: ir.Instruction, summaries: []const Summary) bool {
    return switch (instruction.opcode) {
        .load_global => isResultName(instruction.name),
        // Increment performs numeric coercion.  A value with a custom
        // primitive hook can call user code before the assignment, and that
        // code can inspect the incoming `それ` value even when the increment
        // target has another name.
        .increment => true,
        .call => if (directCallee(program, instruction)) |callee|
            summaries[callee].reads_result
        else
            true,
        // A callback can inspect globals before it returns.  Dynamic source
        // has the same unknown visibility, even when its current text is
        // available only at runtime.
        .call_value,
        .dynamic_execute,
        // These operations can invoke user supplied coercion, getter, setter,
        // iterator, or destructuring hooks.  Keep the summary conservative so
        // a direct caller cannot erase an incoming result around them.
        .binary,
        .unary,
        .array_get,
        .property_get,
        .array_set,
        .property_set,
        .destructure_store,
        .iterator_begin,
        .iterator_next,
        .iterator_has_next,
        => true,
        else => false,
    };
}

fn instructionMayThrow(program: ir.Program, instruction: ir.Instruction, summaries: []const Summary) bool {
    return switch (instruction.opcode) {
        .call => if (directCallee(program, instruction)) |callee| summaries[callee].may_throw else true,
        .call_value,
        .dynamic_execute,
        .const_bigint,
        .const_string,
        .binary,
        .unary,
        .array_get,
        .property_get,
        .array_set,
        .property_set,
        .destructure_store,
        .increment,
        .iterator_begin,
        .iterator_next,
        .iterator_has_next,
        => true,
        else => false,
    };
}

fn overwritesResult(instruction: ir.Instruction) bool {
    return switch (instruction.opcode) {
        .store_global => isResultName(instruction.name),
        // Destructuring uses the same instruction for local and global
        // bindings.  Without binding metadata, treating a name as a global
        // overwrite could hide the previous system result, so keep this
        // conservative and let the ordinary load/return rules decide.
        .destructure_store => false,
        else => false,
    };
}

const Flow = struct {
    needed: bool,
    reaches_overwrite: bool,
};

fn terminatorFlow(
    blocks: []const ir.BasicBlock,
    needed_states: []const bool,
    safe_states: []const bool,
    terminator: ir.Terminator,
    exception_pending_false: bool,
) Flow {
    return switch (terminator) {
        .branch => |target| .{
            .needed = blockEntry(blocks, needed_states, target),
            .reaches_overwrite = blockEntry(blocks, safe_states, target),
        },
        .conditional_branch => |branch| .{
            .needed = if (exception_pending_false)
                blockEntry(blocks, needed_states, branch.else_block)
            else
                blockEntry(blocks, needed_states, branch.then_block) or
                    blockEntry(blocks, needed_states, branch.else_block),
            // A dead store is removable only when every successor reaches the
            // overwrite without an observable or throwing operation.
            .reaches_overwrite = if (exception_pending_false)
                blockEntry(blocks, safe_states, branch.else_block)
            else
                blockEntry(blocks, safe_states, branch.then_block) and
                    blockEntry(blocks, safe_states, branch.else_block),
        },
        .throw_value => |throw_value| if (throw_value.target) |target| .{
            // An explicit throw edge enters the handler just like a normal
            // CFG edge.  The handler may read `それ` before overwriting it.
            .needed = blockEntry(blocks, needed_states, target),
            .reaches_overwrite = blockEntry(blocks, safe_states, target),
        } else .{
            // An uncaught exception can be caught by the caller, where the
            // global result remains observable.
            .needed = true,
            .reaches_overwrite = false,
        },
        // The interpreter leaves globals observable after a function returns.
        // Keep the last implicit result store on every function exit.
        .return_value, .none => .{ .needed = true, .reaches_overwrite = false },
        // A propagated exception is observable by an outer handler.  Keeping
        // this edge live is required even though the current call does not
        // complete its own implicit store.
        .propagate_exception, .unreachable_terminator => .{ .needed = true, .reaches_overwrite = false },
    };
}

fn blockEntry(blocks: []const ir.BasicBlock, states: []const bool, id: ir.BlockId) bool {
    if (id >= blocks.len) return true;
    return states[id];
}

const Transfer = struct {
    needed_before: bool,
    reaches_overwrite_before: bool,
    omit_store: bool = false,
};

fn canPassWithoutObservation(instruction: ir.Instruction) bool {
    return switch (instruction.opcode) {
        // These operations only move already computed SSA/local values.  They
        // do not coerce objects, invoke user code, or expose a pending result.
        .const_number, .const_boolean, .const_null, .const_undefined, .load_local, .store_local, .phi, .exception_pending => true,
        .load_global => !isResultName(instruction.name),
        // A plain global slot write is the overwrite itself when the name is
        // `それ`; other global writes have no user callback hook in the
        // interpreter.  Trace/callback modes are still checked at runtime.
        .store_global => true,
        else => false,
    };
}

fn transferInstruction(
    program: ir.Program,
    instruction: ir.Instruction,
    needed_after: bool,
    reaches_overwrite_after: bool,
    summaries: []const Summary,
) Transfer {
    if (overwritesResult(instruction)) return .{
        .needed_before = false,
        .reaches_overwrite_before = true,
    };
    if (instruction.opcode != .call) return .{
        .needed_before = if (readsIncomingResult(program, instruction, summaries)) true else needed_after,
        .reaches_overwrite_before = canPassWithoutObservation(instruction) and reaches_overwrite_after,
    };

    const callee = directCallee(program, instruction) orelse return .{
        .needed_before = true,
        .reaches_overwrite_before = false,
    };
    const callee_reads = summaries[callee].reads_result;
    const callee_may_throw = summaries[callee].may_throw;
    return .{
        .needed_before = callee_reads,
        .reaches_overwrite_before = false,
        .omit_store = !callee_reads and !callee_may_throw and !needed_after and reaches_overwrite_after,
    };
}

fn hasExceptionHandler(function: ir.Function) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .try_begin) return true;
    };
    return false;
}

/// Compute interprocedural incoming-result read summaries.  The monotone loop
/// is a small SCC fixed point: a single function in a recursive closure/call
/// cycle that reads `それ` makes all callers conservative.
pub fn analyze(allocator: std.mem.Allocator, program: ir.Program) !Analysis {
    const summaries = try allocator.alloc(Summary, program.functions.len);
    @memset(summaries, .{});
    var changed = true;
    while (changed) {
        changed = false;
        for (program.functions, 0..) |function, index| {
            var reads = false;
            var may_throw = false;
            for (function.blocks) |block| for (block.instructions) |instruction| {
                if (readsIncomingResult(program, instruction, summaries)) {
                    reads = true;
                }
                if (instructionMayThrow(program, instruction, summaries)) may_throw = true;
            };
            for (function.blocks) |block| switch (block.terminator) {
                .throw_value, .propagate_exception, .unreachable_terminator => may_throw = true,
                else => {},
            };
            if (reads and !summaries[index].reads_result) {
                summaries[index].reads_result = true;
                changed = true;
            }
            if (may_throw and !summaries[index].may_throw) {
                summaries[index].may_throw = true;
                changed = true;
            }
        }
    }
    return .{ .summaries = summaries };
}

fn exceptionPendingAlwaysFalse(program: ir.Program, block: ir.BasicBlock, summaries: []const Summary) bool {
    for (block.instructions, 0..) |instruction, index| {
        if (instruction.opcode != .exception_pending) continue;
        // lowerExceptionCheck emits the fallible operation immediately before
        // this marker.  If that operation cannot throw, the handler edge is
        // unreachable in the Interpreter and must not pessimize the normal
        // overwrite proof.  Any non-canonical layout stays conservative.
        if (index == 0) return false;
        return !instructionMayThrow(program, block.instructions[index - 1], summaries);
    }
    return false;
}

/// Build a conservative dead-store plan for one function.
pub fn plan(allocator: std.mem.Allocator, program: ir.Program, function: ir.Function, analysis: Analysis) !Plan {
    const omit_result_store = try allocator.alloc([]bool, function.blocks.len);
    @memset(omit_result_store, &.{});
    errdefer {
        for (omit_result_store) |flags| if (flags.len > 0) allocator.free(flags);
        allocator.free(omit_result_store);
    }
    for (function.blocks, omit_result_store) |block, *flags| {
        flags.* = try allocator.alloc(bool, block.instructions.len);
        @memset(flags.*, false);
    }

    const entry_needed = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(entry_needed);
    @memset(entry_needed, true);
    const entry_safe = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(entry_safe);
    @memset(entry_safe, false);

    // The incoming-result state is a greatest fixed point, while the
    // overwrite reachability state starts false and grows only when every
    // successor proves a safe overwrite.  A loop without a terminating
    // overwrite therefore never becomes removable.
    var changed = true;
    while (changed) {
        changed = false;
        var block_index = function.blocks.len;
        while (block_index > 0) {
            block_index -= 1;
            const block = function.blocks[block_index];
            const exit = terminatorFlow(
                function.blocks,
                entry_needed,
                entry_safe,
                block.terminator,
                exceptionPendingAlwaysFalse(program, block, analysis.summaries),
            );
            var needed = exit.needed;
            var reaches_overwrite = exit.reaches_overwrite;
            var instruction_index = block.instructions.len;
            while (instruction_index > 0) {
                instruction_index -= 1;
                const transfer = transferInstruction(program, block.instructions[instruction_index], needed, reaches_overwrite, analysis.summaries);
                needed = transfer.needed_before;
                reaches_overwrite = transfer.reaches_overwrite_before;
            }
            if (entry_needed[block_index] != needed) {
                entry_needed[block_index] = needed;
                changed = true;
            }
            if (entry_safe[block_index] != reaches_overwrite) {
                entry_safe[block_index] = reaches_overwrite;
                changed = true;
            }
        }
    }

    const exception_handler_present = hasExceptionHandler(function);
    for (function.blocks, omit_result_store) |block, flags| {
        const exit = terminatorFlow(
            function.blocks,
            entry_needed,
            entry_safe,
            block.terminator,
            exceptionPendingAlwaysFalse(program, block, analysis.summaries),
        );
        var needed = exit.needed;
        var reaches_overwrite = exit.reaches_overwrite;
        var instruction_index = block.instructions.len;
        while (instruction_index > 0) {
            instruction_index -= 1;
            const transfer = transferInstruction(program, block.instructions[instruction_index], needed, reaches_overwrite, analysis.summaries);
            flags[instruction_index] = transfer.omit_store and !exception_handler_present;
            needed = transfer.needed_before;
            reaches_overwrite = transfer.reaches_overwrite_before;
        }
    }
    return .{ .omit_result_store = omit_result_store };
}

fn makeProgram(allocator: std.mem.Allocator, child_reads: bool) !ir.Program {
    const span = @import("../frontend/ast.zig").emptySpan();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const child_load = ir.Instruction{ .result = 0, .opcode = .load_global, .type = .dynamic, .name = "それ", .span = span };
    const child_const = ir.Instruction{ .result = 1, .opcode = .const_number, .type = .number, .number_value = 2, .span = span };
    const child_store = ir.Instruction{ .result = null, .opcode = .store_global, .type = .void, .name = "それ", .operands = try a.dupe(ir.ValueId, &.{1}), .span = span };
    const child_instructions = if (child_reads) try a.dupe(ir.Instruction, &.{ child_load, child_const, child_store }) else try a.dupe(ir.Instruction, &.{ child_const, child_store });
    const child_blocks = try a.dupe(ir.BasicBlock, &.{.{ .id = 0, .name = "child", .instructions = child_instructions, .terminator = .{ .return_value = null } }});
    const child = ir.Function{ .id = 1, .name = "child", .parameters = &.{}, .blocks = child_blocks, .entry = 0, .return_type = .void, .is_async = false, .is_test = false };

    const call = ir.Instruction{ .result = 0, .opcode = .call, .type = .dynamic, .name = "child", .direct_callee = 1, .span = span };
    const overwrite_value = ir.Instruction{ .result = 1, .opcode = .const_number, .type = .number, .number_value = 3, .span = span };
    const overwrite = ir.Instruction{ .result = null, .opcode = .store_global, .type = .void, .name = "それ", .operands = try a.dupe(ir.ValueId, &.{1}), .span = span };
    const parent_instructions = try a.dupe(ir.Instruction, &.{ call, overwrite_value, overwrite });
    const parent_blocks = try a.dupe(ir.BasicBlock, &.{.{ .id = 0, .name = "parent", .instructions = parent_instructions, .terminator = .{ .return_value = null } }});
    const parent = ir.Function{ .id = 0, .name = "parent", .parameters = &.{}, .blocks = parent_blocks, .entry = 0, .return_type = .void, .is_async = false, .is_test = false };
    return .{ .arena = arena, .functions = try a.dupe(ir.Function, &.{ parent, child }), .module_entries = &.{} };
}

test "direct call result store is removable before a proven overwrite" {
    var program = try makeProgram(std.testing.allocator, false);
    defer program.deinit();
    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    var parent_plan = try plan(std.testing.allocator, program, program.functions[0], analysis);
    defer parent_plan.deinit(std.testing.allocator);
    try std.testing.expect(parent_plan.omit_result_store[0][0]);
}

test "a callee that reads result keeps the caller store" {
    var program = try makeProgram(std.testing.allocator, true);
    defer program.deinit();
    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    var parent_plan = try plan(std.testing.allocator, program, program.functions[0], analysis);
    defer parent_plan.deinit(std.testing.allocator);
    try std.testing.expect(analysis.summaries[1].reads_result);
    try std.testing.expect(!parent_plan.omit_result_store[0][0]);
}

test "return and unknown callback stay conservative" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    const unknown = ir.Instruction{ .result = 0, .opcode = .call_value, .type = .dynamic, .span = span };
    const blocks = try a.dupe(ir.BasicBlock, &.{.{ .id = 0, .name = "entry", .instructions = try a.dupe(ir.Instruction, &.{unknown}), .terminator = .{ .return_value = null } }});
    const function = ir.Function{ .id = 0, .name = "main", .parameters = &.{}, .blocks = blocks, .entry = 0, .return_type = .void, .is_async = false, .is_test = false };
    const functions = try a.dupe(ir.Function, &.{function});
    var program = ir.Program{ .arena = arena, .functions = functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    var function_plan = try plan(std.testing.allocator, program, function, analysis);
    defer function_plan.deinit(std.testing.allocator);
    try std.testing.expect(analysis.summaries[0].reads_result);
    try std.testing.expect(!function_plan.omit_result_store[0][0]);
}

test "exception edges and coercion operations keep the incoming result live" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var program = try makeProgram(std.testing.allocator, false);
    defer program.deinit();
    const a = program.arena.allocator();

    const call = ir.Instruction{ .result = 0, .opcode = .call, .type = .dynamic, .name = "child", .direct_callee = 1, .span = span };
    const thrown_value = ir.Instruction{ .result = 1, .opcode = .const_number, .type = .number, .number_value = 4, .span = span };
    const handler_load = ir.Instruction{ .result = 2, .opcode = .load_global, .type = .dynamic, .name = "それ", .span = span };
    program.functions[0].blocks = try a.dupe(ir.BasicBlock, &.{
        .{ .id = 0, .name = "body", .instructions = try a.dupe(ir.Instruction, &.{ call, thrown_value }), .terminator = .{ .throw_value = .{ .value = 1, .target = 1, .span = span } } },
        .{ .id = 1, .name = "handler", .instructions = try a.dupe(ir.Instruction, &.{handler_load}), .terminator = .{ .return_value = null } },
    });
    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    var exception_plan = try plan(std.testing.allocator, program, program.functions[0], analysis);
    defer exception_plan.deinit(std.testing.allocator);
    try std.testing.expect(!exception_plan.omit_result_store[0][0]);

    const property_get = ir.Instruction{ .result = 2, .opcode = .property_get, .type = .dynamic, .operands = try a.dupe(ir.ValueId, &.{ 0, 1 }), .span = span };
    const overwrite_value = ir.Instruction{ .result = 3, .opcode = .const_number, .type = .number, .number_value = 8, .span = span };
    const overwrite = ir.Instruction{ .result = null, .opcode = .store_global, .type = .void, .name = "それ", .operands = try a.dupe(ir.ValueId, &.{3}), .span = span };
    program.functions[0].blocks = try a.dupe(ir.BasicBlock, &.{.{
        .id = 0,
        .name = "coercion",
        .instructions = try a.dupe(ir.Instruction, &.{ call, thrown_value, property_get, overwrite_value, overwrite }),
        .terminator = .{ .return_value = null },
    }});
    var coercion_analysis = try analyze(std.testing.allocator, program);
    defer coercion_analysis.deinit(std.testing.allocator);
    var coercion_plan = try plan(std.testing.allocator, program, program.functions[0], coercion_analysis);
    defer coercion_plan.deinit(std.testing.allocator);
    try std.testing.expect(!coercion_plan.omit_result_store[0][0]);
}

test "try handlers disable result-store omission across the handler edge" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var program = try makeProgram(std.testing.allocator, false);
    defer program.deinit();
    const a = program.arena.allocator();
    const try_begin = ir.Instruction{ .result = null, .opcode = .try_begin, .type = .void, .exception_target = 1, .span = span };
    const call = ir.Instruction{ .result = 0, .opcode = .call, .type = .dynamic, .name = "child", .direct_callee = 1, .span = span };
    const overwrite_value = ir.Instruction{ .result = 1, .opcode = .const_number, .type = .number, .number_value = 5, .span = span };
    const overwrite = ir.Instruction{ .result = null, .opcode = .store_global, .type = .void, .name = "それ", .operands = try a.dupe(ir.ValueId, &.{1}), .span = span };
    const try_end = ir.Instruction{ .result = null, .opcode = .try_end, .type = .void, .span = span };
    const handler_load = ir.Instruction{ .result = 2, .opcode = .load_global, .type = .dynamic, .name = "それ", .span = span };
    program.functions[0].blocks = try a.dupe(ir.BasicBlock, &.{
        .{ .id = 0, .name = "try", .instructions = try a.dupe(ir.Instruction, &.{ try_begin, call, overwrite_value, overwrite, try_end }), .terminator = .{ .branch = 2 } },
        .{ .id = 1, .name = "handler", .instructions = try a.dupe(ir.Instruction, &.{handler_load}), .terminator = .{ .branch = 2 } },
        .{ .id = 2, .name = "merge", .instructions = &.{}, .terminator = .{ .return_value = null } },
    });
    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    var handler_plan = try plan(std.testing.allocator, program, program.functions[0], analysis);
    defer handler_plan.deinit(std.testing.allocator);
    try std.testing.expect(!handler_plan.omit_result_store[0][1]);
}
