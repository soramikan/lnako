const std = @import("std");
const ir = @import("nako_ir.zig");

/// Per-function effect summary used for safe local/global SSA promotion,
/// root shrinking, and typed ABI decisions.
///
/// `mutated_captures` is the set of names from the function's *captures*
/// list (i.e. names inherited from an outer scope) that may be written by
/// this function or by any nested closure it creates.
pub const Summary = struct {
    may_allocate: bool = false,
    may_throw: bool = false,
    may_reenter: bool = false,
    reads_globals: bool = false,
    writes_globals: bool = false,
    escapes: bool = false,
    written_names: std.StringArrayHashMapUnmanaged(void) = .empty,
    mutated_captures: std.StringArrayHashMapUnmanaged(void) = .empty,
    closure_children: std.ArrayListUnmanaged(ir.FunctionId) = .empty,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        self.written_names.deinit(allocator);
        self.mutated_captures.deinit(allocator);
        self.closure_children.deinit(allocator);
        self.* = .{};
    }
};

fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn markInstruction(summary: *Summary, instruction: ir.Instruction) void {
    switch (instruction.opcode) {
        .load_global => summary.reads_globals = true,
        .store_global => summary.writes_globals = true,
        .call, .call_value, .dynamic_execute => {
            summary.may_allocate = true;
            summary.may_throw = true;
            summary.may_reenter = true;
            summary.reads_globals = true;
            summary.writes_globals = true;
        },
        .make_array, .make_object, .make_closure, .iterator_begin => summary.may_allocate = true,
        .binary, .unary => {
            summary.may_throw = true;
            summary.may_reenter = true;
        },
        .array_get, .property_get, .array_set, .property_set => {
            summary.may_throw = true;
            summary.may_reenter = true;
        },
        .const_string, .const_bigint => summary.may_allocate = true,
        .exception_pending, .exception_take => summary.may_throw = true,
        else => {},
    }
}

fn recordWrites(summary: *Summary, allocator: std.mem.Allocator, function: ir.Function) !void {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        switch (instruction.opcode) {
            .store_local => try summary.written_names.put(allocator, instruction.name, {}),
            .destructure_store => for (instruction.names) |name| try summary.written_names.put(allocator, name, {}),
            .increment => try summary.written_names.put(allocator, instruction.name, {}),
            else => {},
        }
    };
}

/// Analyze the whole program and return one `Summary` per function.
/// The returned slice must be freed with `deinitAll`.
pub fn analyze(allocator: std.mem.Allocator, program: ir.Program) ![]Summary {
    var summaries = try allocator.alloc(Summary, program.functions.len);
    errdefer {
        for (0..program.functions.len) |i| summaries[i].deinit(allocator);
        allocator.free(summaries);
    }
    @memset(summaries, .{});

    var name_to_id: std.StringArrayHashMapUnmanaged(ir.FunctionId) = .empty;
    defer name_to_id.deinit(allocator);
    for (program.functions, 0..) |function, id| {
        try name_to_id.put(allocator, function.name, @intCast(id));
    }

    // Direct writes, direct effect flags and closure children.
    for (program.functions, 0..) |function, id| {
        const summary = &summaries[id];
        try recordWrites(summary, allocator, function);
        for (function.captures) |capture| {
            if (summary.written_names.contains(capture)) try summary.mutated_captures.put(allocator, capture, {});
        }
        for (function.blocks) |block| for (block.instructions) |instruction| {
            markInstruction(summary, instruction);
            if (instruction.opcode == .make_closure) {
                if (name_to_id.get(instruction.name)) |child_id| {
                    try summary.closure_children.append(allocator, child_id);
                    summary.escapes = true;
                }
            }
        };
    }

    // Propagate mutated captures through the closure-creation graph.
    var changed = true;
    while (changed) {
        changed = false;
        for (program.functions, 0..) |function, id| {
            const summary = &summaries[id];
            for (summary.closure_children.items) |child_id| {
                const child_summary = &summaries[child_id];
                for (program.functions[child_id].captures) |capture| {
                    if (!nameInList(function.captures, capture)) continue;
                    if (summary.mutated_captures.contains(capture)) continue;
                    if (child_summary.mutated_captures.contains(capture)) {
                        try summary.mutated_captures.put(allocator, capture, {});
                        changed = true;
                    }
                }
            }
        }
    }

    return summaries;
}

pub fn deinitAll(allocator: std.mem.Allocator, summaries: []Summary) void {
    for (summaries) |*summary| summary.deinit(allocator);
    allocator.free(summaries);
}

fn makeTestProgram(allocator: std.mem.Allocator, child_writes: bool) !ir.Program {
    const span = @import("../frontend/ast.zig").emptySpan();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const child_load = ir.Instruction{
        .result = 1,
        .opcode = .load_local,
        .type = .dynamic,
        .name = "A",
        .span = span,
    };
    const child_store_value = ir.Instruction{
        .result = 2,
        .opcode = .const_number,
        .type = .number,
        .number_value = 2,
        .span = span,
    };
    const child_store = ir.Instruction{
        .result = null,
        .opcode = .store_local,
        .type = .void,
        .name = "A",
        .operands = try a.dupe(ir.ValueId, &.{2}),
        .span = span,
    };
    const child_instructions = if (child_writes)
        try a.dupe(ir.Instruction, &.{ child_store_value, child_store, child_load })
    else
        try a.dupe(ir.Instruction, &.{child_load});
    const child_block = try a.dupe(ir.BasicBlock, &.{.{
        .id = 0,
        .name = "entry",
        .instructions = child_instructions,
        .terminator = .{ .return_value = 1 },
    }});
    const child_captures = try a.dupe([]const u8, &.{"A"});
    const child_function = try a.dupe(ir.Function, &.{.{
        .id = 1,
        .name = "child",
        .parameters = &.{},
        .captures = child_captures,
        .blocks = child_block,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }});

    const parent_load = ir.Instruction{
        .result = 0,
        .opcode = .load_local,
        .type = .dynamic,
        .name = "A",
        .span = span,
    };
    const parent_make = ir.Instruction{
        .result = 1,
        .opcode = .make_closure,
        .type = .function,
        .name = "child",
        .span = span,
    };
    const parent_instructions = try a.dupe(ir.Instruction, &.{ parent_load, parent_make });
    const parent_block = try a.dupe(ir.BasicBlock, &.{.{
        .id = 0,
        .name = "entry",
        .instructions = parent_instructions,
        .terminator = .{ .return_value = 0 },
    }});
    const parent_parameters = try a.dupe(ir.Parameter, &.{.{ .name = "A", .value = 0, .type = .number }});
    const parent_function = try a.dupe(ir.Function, &.{.{
        .id = 0,
        .name = "parent",
        .parameters = parent_parameters,
        .captures = &.{},
        .blocks = parent_block,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }});

    return .{
        .arena = arena,
        .functions = try a.dupe(ir.Function, &.{ parent_function[0], child_function[0] }),
        .module_entries = &.{},
        .module_names = &.{},
        .module_paths = &.{},
    };
}

test "読み取り専用の捕捉セルはmutated_capturesに含まれない" {
    var program = try makeTestProgram(std.testing.allocator, false);
    defer program.deinit();
    const summaries = try analyze(std.testing.allocator, program);
    defer deinitAll(std.testing.allocator, summaries);
    try std.testing.expect(!summaries[1].mutated_captures.contains("A"));
    try std.testing.expect(summaries[0].may_allocate);
    try std.testing.expect(summaries[0].escapes);
}

test "書き込みを伴う捕捉セルはmutated_capturesに含まれる" {
    var program = try makeTestProgram(std.testing.allocator, true);
    defer program.deinit();
    const summaries = try analyze(std.testing.allocator, program);
    defer deinitAll(std.testing.allocator, summaries);
    try std.testing.expect(summaries[1].mutated_captures.contains("A"));
}
