const std = @import("std");
const ir = @import("nako_ir.zig");

/// The storage used for a lexical binding in an execution frame.
///
/// `value` is an addressable `%lnako.Value` slot owned by the frame.  A
/// `cell` is a GC managed BindingCell whose payload is the addressable value.
/// The latter is required whenever another execution can observe the binding
/// identity rather than only a copy of its current value.
pub const StorageClass = enum {
    value,
    cell,
};

/// Reasons a local cannot be represented by a private frame Value slot.
/// Keeping these observations in the shared analysis makes it possible for
/// the Interpreter and LLVM emitter to make the same decision.
pub const Observation = packed struct {
    /// The function receives a binding cell from its enclosing closure.
    captured_in: bool = false,
    /// A nested closure receives this binding cell.
    captured_out: bool = false,
    /// The binding identity may be retained by an escaping execution.
    escaped: bool = false,
    /// Dynamic source execution can observe the current lexical environment.
    dynamic: bool = false,
    /// A callback may update the binding after the current operation returns.
    callback: bool = false,

    pub fn requiresCell(self: Observation) bool {
        return self.captured_in or self.captured_out or self.escaped or self.dynamic or self.callback;
    }

    pub fn storageClass(self: Observation) StorageClass {
        return if (self.requiresCell()) .cell else .value;
    }
};

pub const Local = struct {
    name: []const u8,
    observation: Observation = .{},

    pub fn storageClass(self: Local) StorageClass {
        return self.observation.storageClass();
    }

    pub fn requiresCell(self: Local) bool {
        return self.storageClass() == .cell;
    }
};

/// One function's storage decisions.  Names point into the IR program and
/// therefore do not need to be copied; only the Local array is owned here.
pub const FunctionAnalysis = struct {
    function_id: ir.FunctionId,
    locals: []Local = &.{},

    pub fn deinit(self: *FunctionAnalysis, allocator: std.mem.Allocator) void {
        if (self.locals.len > 0) allocator.free(self.locals);
        self.* = undefined;
    }

    pub fn local(self: FunctionAnalysis, name: []const u8) ?Local {
        for (self.locals) |candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate;
        return null;
    }

    pub fn observation(self: FunctionAnalysis, name: []const u8) Observation {
        return if (self.local(name)) |candidate| candidate.observation else .{};
    }

    pub fn storageClass(self: FunctionAnalysis, name: []const u8) StorageClass {
        return self.observation(name).storageClass();
    }

    pub fn requiresCell(self: FunctionAnalysis, name: []const u8) bool {
        return self.storageClass(name) == .cell;
    }
};

/// A whole-program analysis.  Looking at the whole program is necessary to
/// mark the creator's local when a nested function lists it in `captures`.
pub const Analysis = struct {
    functions: []FunctionAnalysis = &.{},

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        for (self.functions) |*entry| entry.deinit(allocator);
        if (self.functions.len > 0) allocator.free(self.functions);
        self.* = undefined;
    }

    pub fn function(self: Analysis, function_id: ir.FunctionId) ?FunctionAnalysis {
        if (function_id >= self.functions.len) return null;
        return self.functions[function_id];
    }

    pub fn storageClass(self: Analysis, function_id: ir.FunctionId, name: []const u8) StorageClass {
        return if (self.function(function_id)) |entry| entry.storageClass(name) else .cell;
    }

    pub fn requiresCell(self: Analysis, function_id: ir.FunctionId, name: []const u8) bool {
        return self.storageClass(function_id, name) == .cell;
    }
};

/// Collect the source-level local names consumed by both frame layouts.
/// Qualified names belong to the global namespace and must not become local
/// slots when they appear in destructuring or increment instructions.
pub fn collectLocalNames(allocator: std.mem.Allocator, function: ir.Function) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (function.captures) |name| try appendName(allocator, &names, &seen, name);
    for (function.parameters) |parameter| try appendName(allocator, &names, &seen, parameter.name);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        switch (instruction.opcode) {
            .load_local, .store_local, .array_set, .property_set => try appendName(allocator, &names, &seen, instruction.name),
            .destructure_store => for (instruction.names) |name| {
                if (!isQualifiedGlobal(name)) try appendName(allocator, &names, &seen, name);
            },
            .increment => if (!isQualifiedGlobal(instruction.name)) try appendName(allocator, &names, &seen, instruction.name),
            else => {},
        }
    };

    return allocator.dupe([]const u8, names.items);
}

fn appendName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (seen.contains(name)) return;
    try seen.put(allocator, name, {});
    try names.append(allocator, name);
}

fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

fn nameInList(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn findFunction(program: ir.Program, name: []const u8) ?ir.Function {
    for (program.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

fn dynamicObserved(function: ir.Function) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .dynamic_execute) return true;
    };
    return false;
}

/// Analyze one function against its enclosing program.  This function is
/// useful to consumers that already iterate functions, while `analyze`
/// below avoids repeating the same work for the common whole-program path.
pub fn analyzeFunction(allocator: std.mem.Allocator, program: ir.Program, function: ir.Function) !FunctionAnalysis {
    const names = try collectLocalNames(allocator, function);
    defer allocator.free(names);
    const locals = try allocator.alloc(Local, names.len);
    errdefer allocator.free(locals);
    for (names, locals) |name, *local| local.* = .{ .name = name };

    for (locals) |*local| {
        if (nameInList(function.captures, local.name)) local.observation.captured_in = true;
        if (dynamicObserved(function)) {
            local.observation.dynamic = true;
            local.observation.escaped = true;
        }

        // A closure's capture list is the proof that this frame's binding
        // identity leaves the frame.  It is deliberately conservative about
        // control-flow: a closure may be created on a later path and its
        // binding must still be valid whenever it is created.
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.opcode != .make_closure) continue;
            const child = findFunction(program, instruction.name) orelse {
                // An unresolved closure target is an unsupported/invalid
                // program for the emitter, but keeping every local boxed is
                // the safe answer for consumers that only use this analysis.
                local.observation.escaped = true;
                continue;
            };
            if (nameInList(child.captures, local.name)) {
                local.observation.captured_out = true;
                local.observation.escaped = true;
                // A captured binding is shared with a callback, even when the
                // child currently contains only reads.  Keeping this bit
                // explicit helps later prepared execution account for the
                // callback mutation boundary without changing this decision.
                local.observation.callback = true;
            }
        };
    }

    return .{ .function_id = function.id, .locals = locals };
}

pub fn analyze(allocator: std.mem.Allocator, program: ir.Program) !Analysis {
    const functions = try allocator.alloc(FunctionAnalysis, program.functions.len);
    var initialized: usize = 0;
    errdefer {
        for (functions[0..initialized]) |*function| function.deinit(allocator);
        allocator.free(functions);
    }
    for (program.functions, functions) |function, *analysis| {
        analysis.* = try analyzeFunction(allocator, program, function);
        initialized += 1;
    }
    return .{ .functions = functions };
}

/// Allocation-free query for emitters which already have a local name list.
/// Unknown bindings remain conservative, because their addressability cannot
/// be proven from the caller's local IR.
pub fn storageClass(program: ir.Program, function: ir.Function, name: []const u8) StorageClass {
    if (nameInList(function.captures, name) or dynamicObserved(function)) return .cell;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .make_closure) continue;
        const child = findFunction(program, instruction.name) orelse return .cell;
        if (nameInList(child.captures, name)) return .cell;
    };
    return .value;
}

pub fn requiresCell(program: ir.Program, function: ir.Function, name: []const u8) bool {
    return storageClass(program, function, name) == .cell;
}

test "通常localはValue slot、capture localはcellへ分類する" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var empty_parameters = [_]ir.Parameter{};
    var child_instructions = [_]ir.Instruction{};
    var child_blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &child_instructions,
        .terminator = .{ .return_value = null },
    }};
    const child = ir.Function{
        .id = 1,
        .name = "child",
        .parameters = &empty_parameters,
        .captures = &.{"A"},
        .blocks = &child_blocks,
        .entry = 0,
        .return_type = .void,
        .is_async = false,
        .is_test = false,
    };
    var a_operands = [_]ir.ValueId{0};
    var b_operands = [_]ir.ValueId{2};
    var parent_instructions = [_]ir.Instruction{
        .{ .result = 0, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
        .{ .result = null, .opcode = .store_local, .type = .void, .name = "A", .operands = &a_operands, .span = span },
        .{ .result = 2, .opcode = .const_number, .type = .number, .number_value = 2, .span = span },
        .{ .result = null, .opcode = .store_local, .type = .void, .name = "B", .operands = &b_operands, .span = span },
        .{ .result = 3, .opcode = .make_closure, .type = .function, .name = "child", .span = span },
    };
    var parent_blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &parent_instructions,
        .terminator = .{ .return_value = 3 },
    }};
    const parent = ir.Function{
        .id = 0,
        .name = "parent",
        .parameters = &empty_parameters,
        .blocks = &parent_blocks,
        .entry = 0,
        .return_type = .function,
        .is_async = false,
        .is_test = false,
    };
    var functions = [_]ir.Function{ parent, child };
    var module_entries = [_]ir.FunctionId{};
    var program = ir.Program{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .functions = &functions,
        .module_entries = &module_entries,
    };
    defer program.arena.deinit();

    var analysis = try analyze(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(StorageClass.cell, analysis.storageClass(0, "A"));
    try std.testing.expectEqual(StorageClass.value, analysis.storageClass(0, "B"));
    try std.testing.expectEqual(StorageClass.cell, analysis.storageClass(1, "A"));
}

test "dynamic executionはlocalのbinding identityを保持する" {
    const span = @import("../frontend/ast.zig").emptySpan();
    var local_operands = [_]ir.ValueId{0};
    var dynamic_operands = [_]ir.ValueId{0};
    var instructions = [_]ir.Instruction{
        .{ .result = 0, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
        .{ .result = null, .opcode = .store_local, .type = .void, .name = "A", .operands = &local_operands, .span = span },
        .{ .result = 1, .opcode = .dynamic_execute, .type = .dynamic, .operands = &dynamic_operands, .span = span },
    };
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .return_value = 1 },
    }};
    var parameters = [_]ir.Parameter{};
    const function = ir.Function{
        .id = 0,
        .name = "dynamic",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    };
    var functions = [_]ir.Function{function};
    var module_entries = [_]ir.FunctionId{};
    var program = ir.Program{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .functions = &functions,
        .module_entries = &module_entries,
    };
    defer program.arena.deinit();
    try std.testing.expect(requiresCell(program, function, "A"));
}
