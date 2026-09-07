const std = @import("std");
const ir = @import("../../ir/nako_ir.zig");
const local_storage = @import("../../ir/local_storage.zig");
const result_effect = @import("../../ir/result_effect.zig");
const builtin_catalog = @import("../../semantic/builtin_catalog.zig");

/// A local slot is stable for the lifetime of one prepared function.  The
/// sentinel is used for names in a destructuring assignment that are global
/// (module qualified names contain `__`).
pub const LocalSlot = u32;
pub const no_local_slot: LocalSlot = std.math.maxInt(LocalSlot);

/// A global slot is stable for the lifetime of one Interpreter.  Prepared
/// programs only carry the slot number; the owner Interpreter binds names to
/// slots when the program enters its cache.  Appending a new global therefore
/// never invalidates slots already embedded in prepared instructions.
pub const GlobalSlot = u32;
pub const no_global_slot: GlobalSlot = std.math.maxInt(GlobalSlot);

pub const BinaryOperator = enum(u8) {
    add,
    subtract,
    multiply,
    divide,
    integer_divide,
    remainder,
    power,
    concat,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    shift_right_unsigned,
    logical_and,
    logical_or,
    abstract_equal,
    strict_equal,
    abstract_not_equal,
    strict_not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

const binary_operators = std.StaticStringMap(BinaryOperator).initComptime(.{
    .{ "+", .add },
    .{ "-", .subtract },
    .{ "*", .multiply },
    .{ "/", .divide },
    .{ "÷", .divide },
    .{ "÷÷", .integer_divide },
    .{ "%", .remainder },
    .{ "**", .power },
    .{ "&", .concat },
    .{ "|", .bit_or },
    .{ "^", .bit_xor },
    .{ "shift_l", .shift_left },
    .{ "shift_r", .shift_right },
    .{ "shift_r0", .shift_right_unsigned },
    .{ "&&", .logical_and },
    .{ "and", .logical_and },
    .{ "||", .logical_or },
    .{ "or", .logical_or },
    .{ "==", .abstract_equal },
    .{ "=", .abstract_equal },
    .{ "eq", .abstract_equal },
    .{ "===", .strict_equal },
    .{ "!=", .abstract_not_equal },
    .{ "≠", .abstract_not_equal },
    .{ "noteq", .abstract_not_equal },
    .{ "!==", .strict_not_equal },
    .{ "<", .less },
    .{ "lt", .less },
    .{ "<=", .less_equal },
    .{ "lteq", .less_equal },
    .{ ">", .greater },
    .{ "gt", .greater },
    .{ ">=", .greater_equal },
    .{ "gteq", .greater_equal },
});

pub fn resolveBinaryOperator(name: []const u8) ?BinaryOperator {
    return binary_operators.get(name);
}

pub const UnaryOperator = enum(u8) { logical_not, minus, plus, bit_not };

const unary_operators = std.StaticStringMap(UnaryOperator).initComptime(.{
    .{ "!", .logical_not },
    .{ "not", .logical_not },
    .{ "-", .minus },
    .{ "+", .plus },
    .{ "~", .bit_not },
});

pub fn resolveUnaryOperator(name: []const u8) ?UnaryOperator {
    return unary_operators.get(name);
}

/// The builtin catalog is generated from the compatibility baseline.  The
/// numeric id is metadata for the prepared representation.  The hot dispatch
/// uses it directly, while the original spelling remains available for trace
/// output and the compatibility fallback.
pub const BuiltinId = u16;

pub const StorageClass = local_storage.StorageClass;

pub fn resolveBuiltin(name: []const u8) ?BuiltinId {
    for (builtin_catalog.names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) {
            return std.math.cast(BuiltinId, index);
        }
    }
    return null;
}

pub const BuiltinTarget = struct {
    id: ?BuiltinId = null,
    /// A builtin call may be shadowed by a runtime global.  The slot is
    /// checked before dispatching `id`, preserving the dynamic shadowing
    /// semantics while avoiding a hash lookup on the hot path.
    global_slot: GlobalSlot = no_global_slot,
};

pub const CallTarget = union(enum) {
    direct_ir: ir.FunctionId,
    local_slot: LocalSlot,
    global_or_builtin: BuiltinTarget,
};

pub const PreparedInstruction = struct {
    /// The original IR remains the source of truth for operands, spans,
    /// tracing ids, and all uncommon metadata.  Prepared fields below are
    /// immutable execution-time decisions that avoid repeating name parsing.
    ir_instruction: *const ir.Instruction = undefined,
    local_slot: LocalSlot = no_local_slot,
    global_slot: GlobalSlot = no_global_slot,
    binary_operator: ?BinaryOperator = null,
    unary_operator: ?UnaryOperator = null,
    call_target: ?CallTarget = null,
    closure_target: ?ir.FunctionId = null,
    destructure_local_slots: []const LocalSlot = &.{},
    destructure_global_slots: []GlobalSlot = &.{},
    /// The static proof is used only when no global trace is active at runtime.
    omit_result_store: bool = false,
    interrupt_safepoint: bool = false,
};

pub const PreparedBlock = struct {
    instructions: []PreparedInstruction = &.{},
};

pub const PreparedFunction = struct {
    ir_function: *const ir.Function,
    value_count: usize,
    local_slots: std.StringHashMapUnmanaged(LocalSlot) = .empty,
    storage_classes: []StorageClass = &.{},
    local_count: usize = 0,
    blocks: []PreparedBlock = &.{},

    pub fn localSlot(self: *const PreparedFunction, name: []const u8) ?LocalSlot {
        return self.local_slots.get(name);
    }

    pub fn storageClass(self: *const PreparedFunction, slot: LocalSlot) ?StorageClass {
        if (slot == no_local_slot or slot >= self.storage_classes.len) return null;
        return self.storage_classes[slot];
    }

    pub fn requiresCell(self: *const PreparedFunction, slot: LocalSlot) bool {
        return if (self.storageClass(slot)) |storage| storage == .cell else true;
    }

    pub fn deinit(self: *PreparedFunction, allocator: std.mem.Allocator) void {
        self.local_slots.deinit(allocator);
        if (self.storage_classes.len > 0) allocator.free(self.storage_classes);
        for (self.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.destructure_local_slots.len > 0) allocator.free(instruction.destructure_local_slots);
                if (instruction.destructure_global_slots.len > 0) allocator.free(instruction.destructure_global_slots);
            }
            if (block.instructions.len > 0) allocator.free(block.instructions);
        }
        if (self.blocks.len > 0) allocator.free(self.blocks);
        self.* = undefined;
    }
};

/// Immutable execution metadata for one IR owner.  The owner is retained by
/// `Interpreter` for as long as this object is cached, including dynamic
/// programs, so all borrowed names and instruction pointers stay valid.
pub const PreparedProgram = struct {
    owner: *const ir.Program,
    functions: []PreparedFunction,
    exact: std.StringHashMapUnmanaged(ir.FunctionId) = .empty,
    suffix: std.StringHashMapUnmanaged(?ir.FunctionId) = .empty,

    pub fn init(allocator: std.mem.Allocator, owner: *const ir.Program) !PreparedProgram {
        var result: PreparedProgram = .{
            .owner = owner,
            .functions = try allocator.alloc(PreparedFunction, owner.functions.len),
        };
        var initialized_functions: usize = 0;
        errdefer {
            for (result.functions[0..initialized_functions]) |*function| function.deinit(allocator);
            allocator.free(result.functions);
            result.exact.deinit(allocator);
            result.suffix.deinit(allocator);
        }
        for (result.functions, owner.functions) |*prepared, *function| {
            prepared.* = .{
                .ir_function = function,
                .value_count = maxValueId(function.*) + 1,
            };
            initialized_functions += 1;
        }

        for (owner.functions, 0..) |function, index| {
            const id: ir.FunctionId = @intCast(index);
            const exact = try result.exact.getOrPut(allocator, function.name);
            if (!exact.found_existing) exact.value_ptr.* = id;
            if (std.mem.lastIndexOf(u8, function.name, "__")) |separator| {
                const suffix = function.name[separator + 2 ..];
                const slot = try result.suffix.getOrPut(allocator, suffix);
                if (!slot.found_existing) {
                    slot.value_ptr.* = id;
                } else if (slot.value_ptr.* != id) {
                    slot.value_ptr.* = null;
                }
            }
        }
        var result_effect_analysis = try result_effect.analyze(allocator, owner.*);
        defer result_effect_analysis.deinit(allocator);
        for (result.functions, 0..) |*prepared, index| try prepareFunction(allocator, prepared, &owner.functions[index], &result, result_effect_analysis);
        return result;
    }

    pub fn deinit(self: *PreparedProgram, allocator: std.mem.Allocator) void {
        for (self.functions) |*function| function.deinit(allocator);
        if (self.functions.len > 0) allocator.free(self.functions);
        self.exact.deinit(allocator);
        self.suffix.deinit(allocator);
        self.* = undefined;
    }

    pub fn functionAt(self: *const PreparedProgram, function: *const ir.Function) ?*const PreparedFunction {
        if (function.id < self.functions.len and self.functions[function.id].ir_function == function) return &self.functions[function.id];
        for (self.functions) |*prepared| if (prepared.ir_function == function) return prepared;
        return null;
    }

    pub fn functionAtId(self: *const PreparedProgram, id: ir.FunctionId) ?*const PreparedFunction {
        if (id >= self.functions.len) return null;
        return &self.functions[id];
    }

    fn findFunction(self: *const PreparedProgram, name: []const u8) ?ir.FunctionId {
        if (self.exact.get(name)) |id| return id;
        if (self.suffix.get(name)) |id| return id orelse null;
        return null;
    }
};

fn prepareFunction(
    allocator: std.mem.Allocator,
    prepared: *PreparedFunction,
    function: *const ir.Function,
    program: *const PreparedProgram,
    result_effect_analysis: result_effect.Analysis,
) !void {
    var next_slot: usize = 0;
    for (function.parameters) |parameter| try addLocal(allocator, prepared, parameter.name, &next_slot);
    for (function.captures) |capture| try addLocal(allocator, prepared, capture, &next_slot);
    for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.opcode) {
        .load_local, .store_local => try addLocal(allocator, prepared, instruction.name, &next_slot),
        .increment => if (!isQualifiedGlobal(instruction.name)) try addLocal(allocator, prepared, instruction.name, &next_slot),
        .array_set, .property_set => {},
        .destructure_store => for (instruction.names) |name| if (std.mem.indexOf(u8, name, "__") == null) try addLocal(allocator, prepared, name, &next_slot),
        else => {},
    };
    prepared.local_count = next_slot;

    var analysis = try local_storage.analyzeFunction(allocator, program.owner.*, function.*);
    defer analysis.deinit(allocator);
    prepared.storage_classes = try allocator.alloc(StorageClass, next_slot);
    @memset(prepared.storage_classes, .value);
    errdefer {
        if (prepared.storage_classes.len > 0) allocator.free(prepared.storage_classes);
        prepared.storage_classes = &.{};
    }
    for (analysis.locals) |local| if (prepared.localSlot(local.name)) |slot| {
        prepared.storage_classes[slot] = local.storageClass();
    };

    var result_plan = try result_effect.plan(allocator, program.owner.*, function.*, result_effect_analysis);
    defer result_plan.deinit(allocator);

    prepared.blocks = try allocator.alloc(PreparedBlock, function.blocks.len);
    @memset(prepared.blocks, .{});
    errdefer {
        for (prepared.blocks) |block| {
            for (block.instructions) |instruction| if (instruction.destructure_local_slots.len > 0) allocator.free(instruction.destructure_local_slots);
            for (block.instructions) |instruction| if (instruction.destructure_global_slots.len > 0) allocator.free(instruction.destructure_global_slots);
            if (block.instructions.len > 0) allocator.free(block.instructions);
        }
        allocator.free(prepared.blocks);
        prepared.blocks = &.{};
    }
    for (prepared.blocks, function.blocks, 0..) |*prepared_block, block, block_index| {
        prepared_block.instructions = try allocator.alloc(PreparedInstruction, block.instructions.len);
        @memset(prepared_block.instructions, .{});
        for (prepared_block.instructions, block.instructions, 0..) |*entry, *instruction, instruction_index| {
            entry.* = .{
                .ir_instruction = instruction,
                .local_slot = prepared.localSlot(instruction.name) orelse no_local_slot,
                .binary_operator = if (instruction.opcode == .binary) resolveBinaryOperator(instruction.operator) else null,
                .unary_operator = if (instruction.opcode == .unary) resolveUnaryOperator(instruction.operator) else null,
                .call_target = if (instruction.opcode == .call) resolveCallTarget(prepared, program, instruction.*) else null,
                .closure_target = if (instruction.opcode == .make_closure) program.findFunction(instruction.name) else null,
                .omit_result_store = result_plan.omit_result_store[block_index][instruction_index],
                .interrupt_safepoint = isInterruptSafepoint(instruction.opcode),
            };
            if (instruction.opcode == .destructure_store and instruction.names.len > 0) {
                const local_slots = try allocator.alloc(LocalSlot, instruction.names.len);
                const global_slots = allocator.alloc(GlobalSlot, instruction.names.len) catch |failure| {
                    allocator.free(local_slots);
                    return failure;
                };
                for (local_slots, instruction.names) |*slot, name| slot.* = if (std.mem.indexOf(u8, name, "__") != null) no_local_slot else prepared.localSlot(name) orelse no_local_slot;
                entry.destructure_local_slots = local_slots;
                @memset(global_slots, no_global_slot);
                entry.destructure_global_slots = global_slots;
            }
        }
    }
}

fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

fn isInterruptSafepoint(opcode: ir.Opcode) bool {
    return switch (opcode) {
        .const_bigint,
        .const_string,
        .binary,
        .unary,
        .call,
        .call_value,
        .make_array,
        .make_object,
        .array_get,
        .property_get,
        .array_set,
        .property_set,
        .increment,
        .make_closure,
        .iterator_begin,
        .iterator_next,
        .dynamic_execute,
        => true,
        else => false,
    };
}

fn addLocal(allocator: std.mem.Allocator, prepared: *PreparedFunction, name: []const u8, next_slot: *usize) !void {
    if (name.len == 0 or prepared.local_slots.contains(name)) return;
    const slot = std.math.cast(LocalSlot, next_slot.*) orelse return error.LocalSlotOverflow;
    const result = try prepared.local_slots.getOrPut(allocator, name);
    if (!result.found_existing) {
        result.value_ptr.* = slot;
        next_slot.* += 1;
    }
}

fn resolveCallTarget(
    prepared: *const PreparedFunction,
    program: *const PreparedProgram,
    instruction: ir.Instruction,
) CallTarget {
    if (instruction.direct_callee) |callee| return .{ .direct_ir = callee };
    if (program.findFunction(instruction.name)) |callee| return .{ .direct_ir = callee };
    if (prepared.localSlot(instruction.name)) |slot| return .{ .local_slot = slot };
    return .{ .global_or_builtin = .{ .id = resolveBuiltin(instruction.name) } };
}

fn maxValueId(function: ir.Function) usize {
    var maximum: usize = if (function.parameters.len == 0) 0 else function.parameters.len - 1;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.result) |result| maximum = @max(maximum, result);
        }
    }
    return maximum;
}
