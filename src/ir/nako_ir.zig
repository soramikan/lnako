const std = @import("std");
const ast = @import("../frontend/ast.zig");

pub const ValueId = u32;
pub const BlockId = u32;
pub const FunctionId = u32;

pub const Type = enum { dynamic, number, bigint, boolean, null_value, string, array, object, function, void };

pub const Opcode = enum {
    const_number,
    const_bigint,
    const_boolean,
    const_null,
    const_string,
    const_undefined,
    load_global,
    load_local,
    store_global,
    store_local,
    destructure_store,
    binary,
    unary,
    call,
    call_value,
    make_array,
    make_object,
    array_get,
    property_get,
    array_set,
    property_set,
    increment,
    make_closure,
    iterator_begin,
    iterator_next,
    iterator_has_next,
    try_begin,
    try_end,
    dynamic_execute,
    speed_mode_begin,
    speed_mode_end,
    performance_monitor_begin,
    performance_monitor_end,
    phi,
};

pub const PhiIncoming = struct { predecessor: BlockId, value: ValueId };
pub const LoopDirection = enum { automatic, up, down };

pub const Instruction = struct {
    result: ?ValueId,
    opcode: Opcode,
    type: Type,
    operands: []ValueId = &.{},
    phi_incoming: []PhiIncoming = &.{},
    name: []const u8 = "",
    text: []const u8 = "",
    operator: []const u8 = "",
    names: []const []const u8 = &.{},
    number_value: ?f64 = null,
    boolean_value: bool = false,
    loop_direction: LoopDirection = .automatic,
    exception_target: ?BlockId = null,
    span: ast.Span,
};

pub const ConditionalBranch = struct { condition: ValueId, then_block: BlockId, else_block: BlockId };

pub const Terminator = union(enum) {
    none,
    branch: BlockId,
    conditional_branch: ConditionalBranch,
    return_value: ?ValueId,
    throw_value: ValueId,
    unreachable_terminator,
};

pub const BasicBlock = struct {
    id: BlockId,
    name: []const u8,
    instructions: []Instruction,
    terminator: Terminator,
};

pub const Parameter = struct { name: []const u8, value: ValueId, type: Type = .dynamic };

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    parameters: []Parameter,
    blocks: []BasicBlock,
    entry: BlockId,
    return_type: Type,
    is_async: bool,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    functions: []Function,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findFunction(self: Program, name: []const u8) ?Function {
        for (self.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }
};
