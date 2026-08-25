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
    direct_callee: ?FunctionId = null,
    loop_direction: LoopDirection = .automatic,
    exception_target: ?BlockId = null,
    span: ast.Span,
};

pub const ConditionalBranch = struct { condition: ValueId, then_block: BlockId, else_block: BlockId };
pub const Throw = struct { value: ValueId, target: ?BlockId = null };

pub const Terminator = union(enum) {
    none,
    branch: BlockId,
    conditional_branch: ConditionalBranch,
    return_value: ?ValueId,
    throw_value: Throw,
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
    captures: []const []const u8 = &.{},
    blocks: []BasicBlock,
    entry: BlockId,
    return_type: Type,
    is_async: bool,
    is_test: bool,
};

pub const JavaScriptModule = struct {
    path: []const u8,
    source: []const u8,
    is_plugin: bool = false,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    functions: []Function,
    module_entries: []FunctionId,
    module_names: []const []const u8 = &.{},
    module_paths: []const []const u8 = &.{},
    compat_js: bool = false,
    javascript_modules: []JavaScriptModule = &.{},
    native_plugin_paths: []const []const u8 = &.{},

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn clone(self: Program, backing_allocator: std.mem.Allocator) !Program {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const functions = try allocator.alloc(Function, self.functions.len);
        for (self.functions, functions) |source_function, *target_function| {
            const blocks = try allocator.alloc(BasicBlock, source_function.blocks.len);
            for (source_function.blocks, blocks) |source_block, *target_block| {
                const instructions = try allocator.dupe(Instruction, source_block.instructions);
                for (instructions) |*instruction| {
                    instruction.operands = try allocator.dupe(ValueId, instruction.operands);
                    instruction.phi_incoming = try allocator.dupe(PhiIncoming, instruction.phi_incoming);
                    instruction.name = try allocator.dupe(u8, instruction.name);
                    instruction.text = try allocator.dupe(u8, instruction.text);
                    instruction.operator = try allocator.dupe(u8, instruction.operator);
                    const names = try allocator.alloc([]const u8, instruction.names.len);
                    for (instruction.names, names) |source_name, *target_name| target_name.* = try allocator.dupe(u8, source_name);
                    instruction.names = names;
                }
                target_block.* = source_block;
                target_block.name = try allocator.dupe(u8, source_block.name);
                target_block.instructions = instructions;
            }
            target_function.* = source_function;
            target_function.parameters = try allocator.dupe(Parameter, source_function.parameters);
            for (target_function.parameters) |*parameter| parameter.name = try allocator.dupe(u8, parameter.name);
            target_function.captures = try cloneStrings(allocator, source_function.captures);
            target_function.name = try allocator.dupe(u8, source_function.name);
            target_function.blocks = blocks;
        }
        const javascript_modules = try allocator.dupe(JavaScriptModule, self.javascript_modules);
        for (javascript_modules) |*module| {
            module.path = try allocator.dupe(u8, module.path);
            module.source = try allocator.dupe(u8, module.source);
        }
        const native_plugin_paths = try allocator.alloc([]const u8, self.native_plugin_paths.len);
        for (self.native_plugin_paths, native_plugin_paths) |source_path, *target_path| target_path.* = try allocator.dupe(u8, source_path);
        return .{
            .arena = arena,
            .functions = functions,
            .module_entries = try allocator.dupe(FunctionId, self.module_entries),
            .module_names = try cloneStrings(allocator, self.module_names),
            .module_paths = try cloneStrings(allocator, self.module_paths),
            .compat_js = self.compat_js,
            .javascript_modules = javascript_modules,
            .native_plugin_paths = native_plugin_paths,
        };
    }

    pub fn findFunction(self: Program, name: []const u8) ?Function {
        for (self.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }
};

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    for (source, result) |value, *target| target.* = try allocator.dupe(u8, value);
    return result;
}
