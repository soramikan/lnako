const std = @import("std");
const ir = @import("nako_ir.zig");

const max_precise_values: usize = 512;
const max_precise_cells: usize = 262_144;

/// Storage liveness includes runtime ABI operands as well as SSA uses. In
/// particular an output pointer may never alias an input pointer, even when
/// that input dies at the instruction. Exceptional control flow is included.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    slots: []usize,
    managed: []bool,
    root_count: usize,
    scratch_count: usize,
    blocks: []Block,
    /// Whether `blocks[].before` contains precise per-instruction liveness.
    /// Large functions use dedicated slots and skip safepoint clearing so the
    /// plan stays linear in the number of values.
    precise: bool,
    /// Scratch array reused by every precise safepoint in this function.
    active: []bool,

    pub const Block = struct {
        /// Live values immediately before each instruction and the terminator.
        before: [][]bool,
    };

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn mayCollect(instruction: ir.Instruction) bool {
    return switch (instruction.opcode) {
        .const_number,
        .const_boolean,
        .const_null,
        .const_undefined,
        .phi,
        .load_local,
        .store_local,
        .try_begin,
        .try_end,
        .exception_pending,
        => false,
        // Global trace, conversions, helpers, callbacks and dynamic execution
        // are conservatively safepoints, including unknown future opcodes.
        else => true,
    };
}

pub fn analyze(allocator: std.mem.Allocator, function: ir.Function) !Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var count: usize = 0;
    var instruction_count: usize = 0;
    for (function.parameters) |p| count = @max(count, @as(usize, p.value) + 1);
    for (function.blocks) |b| for (b.instructions) |i| {
        instruction_count +|= 1;
        if (i.result) |v| count = @max(count, @as(usize, v) + 1);
    };
    const managed = try a.alloc(bool, count);
    @memset(managed, true);
    // Generic entry parameters must remain rooted even when inferred numeric:
    // a callback can enter through the generic ABI with a different type.
    for (function.blocks) |b| for (b.instructions) |i| {
        if (i.result) |v| managed[v] = switch (i.opcode) {
            .const_number,
            .const_boolean,
            .const_null,
            .const_undefined,
            .iterator_has_next,
            .exception_pending,
            => false,
            // Inferred types describe known call sites, not every generic ABI
            // entry. A local load/phi/call can still carry a managed value when
            // reached dynamically, so only intrinsically primitive opcodes
            // are excluded from the root set here.
            else => true,
        };
    };
    if (needsFallback(count, instruction_count)) {
        // Coloring and the per-instruction matrix are deliberately omitted
        // for large functions. Every value gets a private slot within its
        // storage class, which preserves ABI non-aliasing without quadratic
        // memory or time growth. The emitter skips safepoint clears for this
        // conservative plan, so a value is never cleared while it may still
        // be reachable through an unmodelled edge.
        const slots = try a.alloc(usize, count);
        var roots: usize = 0;
        var scratch: usize = 0;
        for (managed, 0..) |is_managed, value| {
            if (is_managed) {
                slots[value] = roots;
                roots += 1;
            } else {
                slots[value] = scratch;
                scratch += 1;
            }
        }
        const blocks = try a.alloc(Plan.Block, function.blocks.len);
        for (blocks) |*block| block.before = &.{};
        const active = try a.alloc(bool, roots);
        @memset(active, false);
        return .{
            .arena = arena,
            .slots = slots,
            .managed = managed,
            .root_count = roots,
            .scratch_count = scratch,
            .blocks = blocks,
            .precise = false,
            .active = active,
        };
    }
    const live_in = try matrix(a, function.blocks.len, count);
    const live_out = try matrix(a, function.blocks.len, count);
    const live = try a.alloc(bool, count);
    var changed = true;
    while (changed) {
        changed = false;
        var bi = function.blocks.len;
        while (bi > 0) {
            bi -= 1;
            const block = function.blocks[bi];
            @memset(live, false);
            switch (block.terminator) {
                .branch => |target| addSuccessor(function, block.id, target, live_in, live),
                .conditional_branch => |branch| {
                    addSuccessor(function, block.id, branch.then_block, live_in, live);
                    addSuccessor(function, block.id, branch.else_block, live_in, live);
                },
                .throw_value => |t| if (t.target) |target| {
                    addSuccessor(function, block.id, target, live_in, live);
                },
                else => {},
            }
            for (block.instructions) |i| if (i.exception_target) |target| {
                addSuccessor(function, block.id, target, live_in, live);
            };
            @memcpy(live_out[bi], live);
            addTerminator(block.terminator, live);
            var ii = block.instructions.len;
            while (ii > 0) {
                ii -= 1;
                const i = block.instructions[ii];
                if (i.result) |v| live[v] = false;
                for (i.operands) |v| live[v] = true;
                // Phi operands belong to predecessor edges, not this block.
            }
            if (!std.mem.eql(bool, live, live_in[bi])) {
                @memcpy(live_in[bi], live);
                changed = true;
            }
        }
    }
    const interference = try matrix(a, count, count);
    const blocks = try a.alloc(Plan.Block, function.blocks.len);
    for (function.blocks, 0..) |block, bi| {
        blocks[bi].before = try matrix(a, block.instructions.len + 1, count);
        @memcpy(live, live_out[bi]);
        addTerminator(block.terminator, live);
        @memcpy(blocks[bi].before[block.instructions.len], live);
        clique(interference, live);
        var ii = block.instructions.len;
        while (ii > 0) {
            ii -= 1;
            const i = block.instructions[ii];
            // Keep result and operands disjoint for the pointer-based ABI.
            for (i.operands) |v| live[v] = true;
            if (i.result) |v| live[v] = true;
            clique(interference, live);
            if (i.result) |v| live[v] = false;
            @memcpy(blocks[bi].before[ii], live);
        }
        // Phi results are stored as a batch after all LLVM phi instructions.
        for (block.instructions) |i| {
            if (i.opcode != .phi) break;
            if (i.result) |v| live[v] = true;
        }
        clique(interference, live);
    }
    // All parameters are copied to slots before local initialization.
    @memset(live, false);
    for (function.parameters) |p| live[p.value] = true;
    clique(interference, live);
    const slots = try a.alloc(usize, count);
    @memset(slots, std.math.maxInt(usize));
    var roots: usize = 0;
    var scratch: usize = 0;
    for (0..count) |v| {
        var slot: usize = 0;
        while (true) : (slot += 1) {
            var conflict = false;
            for (0..v) |other| {
                if (managed[v] == managed[other] and interference[v][other] and slots[other] == slot) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) break;
        }
        slots[v] = slot;
        if (managed[v]) roots = @max(roots, slot + 1) else scratch = @max(scratch, slot + 1);
    }
    const active = try a.alloc(bool, roots);
    @memset(active, false);
    return .{
        .arena = arena,
        .slots = slots,
        .managed = managed,
        .root_count = roots,
        .scratch_count = scratch,
        .blocks = blocks,
        .precise = true,
        .active = active,
    };
}

fn needsFallback(value_count: usize, instruction_count: usize) bool {
    if (value_count > max_precise_values) return true;
    if (value_count == 0) return false;
    return instruction_count > max_precise_cells / value_count;
}

fn matrix(a: std.mem.Allocator, rows: usize, columns: usize) ![][]bool {
    const result = try a.alloc([]bool, rows);
    for (result) |*row| {
        row.* = try a.alloc(bool, columns);
        @memset(row.*, false);
    }
    return result;
}

fn addSuccessor(function: ir.Function, predecessor: ir.BlockId, target: ir.BlockId, live_in: [][]bool, live: []bool) void {
    for (function.blocks, 0..) |block, bi| {
        if (block.id != target) continue;
        for (live_in[bi], 0..) |used, v| live[v] = live[v] or used;
        for (block.instructions) |i| {
            if (i.opcode != .phi) break;
            for (i.phi_incoming) |incoming| if (incoming.predecessor == predecessor) {
                live[incoming.value] = true;
            };
        }
        return;
    }
}

fn addTerminator(t: ir.Terminator, live: []bool) void {
    switch (t) {
        .conditional_branch => |b| live[b.condition] = true,
        .return_value => |v| if (v) |id| {
            live[id] = true;
        },
        .throw_value => |v| live[v.value] = true,
        else => {},
    }
}

fn clique(edges: [][]bool, live: []const bool) void {
    for (live, 0..) |used, v| {
        if (!used) continue;
        for (live[0..v], 0..) |other_used, other| if (other_used) {
            edges[v][other] = true;
            edges[other][v] = true;
        };
    }
}

test "root storage keeps ABI output disjoint and reuses dead slots" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var operand = [_]ir.ValueId{0};
    var instructions = [_]ir.Instruction{
        .{ .result = 0, .opcode = .const_string, .type = .string, .span = span },
        .{ .result = 1, .opcode = .call, .type = .number, .operands = &operand, .span = span },
        .{ .result = 2, .opcode = .const_string, .type = .string, .span = span },
        .{ .result = 3, .opcode = .const_number, .type = .number, .span = span },
    };
    var blocks = [_]ir.BasicBlock{.{ .id = 0, .name = "entry", .instructions = &instructions, .terminator = .{ .return_value = 2 } }};
    const function: ir.Function = .{ .id = 0, .name = "test", .parameters = &.{}, .blocks = &blocks, .entry = 0, .return_type = .dynamic, .is_async = false, .is_test = false };
    var plan = try analyze(std.testing.allocator, function);
    defer plan.deinit();
    try std.testing.expect(plan.slots[0] != plan.slots[1]);
    try std.testing.expectEqual(plan.slots[0], plan.slots[2]);
    try std.testing.expectEqual(@as(usize, 2), plan.root_count);
    try std.testing.expect(plan.precise);
    try std.testing.expect(!plan.managed[3]);
    try std.testing.expect(plan.managed[1]); // inferred number is not a generic ABI guarantee
    try std.testing.expect(plan.blocks[0].before[1][0]);
    try std.testing.expect(!plan.blocks[0].before[2][0]);
}

test "root liveness follows loop phi edges and exception handlers" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var incoming = [_]ir.PhiIncoming{ .{ .predecessor = 0, .value = 0 }, .{ .predecessor = 1, .value = 2 } };
    var operand = [_]ir.ValueId{1};
    var entry = [_]ir.Instruction{
        .{ .result = 0, .opcode = .const_string, .type = .string, .span = span },
        .{ .result = null, .opcode = .try_begin, .type = .void, .exception_target = 2, .span = span },
    };
    var loop = [_]ir.Instruction{
        .{ .result = 1, .opcode = .phi, .type = .string, .phi_incoming = &incoming, .span = span },
        .{ .result = 2, .opcode = .call, .type = .string, .operands = &operand, .span = span },
    };
    var blocks = [_]ir.BasicBlock{
        .{ .id = 0, .name = "entry", .instructions = &entry, .terminator = .{ .branch = 1 } },
        .{ .id = 1, .name = "loop", .instructions = &loop, .terminator = .{ .conditional_branch = .{ .condition = 2, .then_block = 1, .else_block = 2 } } },
        .{ .id = 2, .name = "handler", .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    const function: ir.Function = .{ .id = 0, .name = "loop", .parameters = &.{}, .blocks = &blocks, .entry = 0, .return_type = .dynamic, .is_async = false, .is_test = false };
    var plan = try analyze(std.testing.allocator, function);
    defer plan.deinit();
    try std.testing.expect(plan.blocks[1].before[1][0]);
    try std.testing.expect(plan.blocks[1].before[1][1]);
    try std.testing.expect(plan.blocks[1].before[2][2]);
    try std.testing.expect(plan.slots[0] != plan.slots[1]);
    try std.testing.expect(plan.slots[0] != plan.slots[2]);
    try std.testing.expect(plan.slots[1] != plan.slots[2]);
}

test "root liveness precision threshold is bounded exactly" {
    try std.testing.expect(!needsFallback(max_precise_values, max_precise_cells / max_precise_values));
    try std.testing.expect(needsFallback(max_precise_values, max_precise_cells / max_precise_values + 1));
    try std.testing.expect(needsFallback(max_precise_values + 1, 1));
    try std.testing.expect(!needsFallback(0, std.math.maxInt(usize)));
}

test "large root plans use dedicated nonalias slots without before matrix" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var instructions: [513]ir.Instruction = undefined;
    for (&instructions, 0..) |*instruction, value| {
        instruction.* = .{
            .result = @intCast(value),
            .opcode = if (value == 512) .const_number else .const_string,
            .type = if (value == 512) .number else .string,
            .span = span,
        };
    }
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "large",
        .instructions = &instructions,
        .terminator = .{ .return_value = 511 },
    }};
    const function: ir.Function = .{
        .id = 0,
        .name = "large",
        .parameters = &.{},
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    };
    var plan = try analyze(std.testing.allocator, function);
    defer plan.deinit();
    try std.testing.expect(!plan.precise);
    try std.testing.expectEqual(@as(usize, 512), plan.root_count);
    try std.testing.expectEqual(@as(usize, 1), plan.scratch_count);
    try std.testing.expectEqual(@as(usize, 512), plan.active.len);
    try std.testing.expectEqual(@as(usize, 0), plan.slots[0]);
    try std.testing.expectEqual(@as(usize, 511), plan.slots[511]);
    try std.testing.expectEqual(@as(usize, 0), plan.slots[512]);
    try std.testing.expect(plan.slots[0] != plan.slots[1]);
    try std.testing.expect(plan.slots[511] != plan.slots[0]);
    try std.testing.expectEqual(@as(usize, 0), plan.blocks[0].before.len);
}
