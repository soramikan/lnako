const std = @import("std");
const ir = @import("../../../../ir/nako_ir.zig");
const aot_builtin = @import("../../../../runtime/aot_builtin.zig");

/// Primitive types which have a stable internal LLVM representation.
///
/// The public Nako ABI remains `%lnako.Value`; these types are only used for
/// compiler generated calls between functions whose IR proves the complete
/// signature.  Keeping this enum here prevents the call-site and function
/// emitters from having subtly different eligibility rules.
pub const Scalar = enum {
    number,
    boolean,

    pub fn llvmType(self: Scalar) []const u8 {
        return switch (self) {
            .number => "double",
            .boolean => "i1",
        };
    }

    pub fn suffix(self: Scalar) []const u8 {
        return switch (self) {
            .number => "number",
            .boolean => "boolean",
        };
    }

    pub fn valueTag(self: Scalar) u8 {
        return switch (self) {
            .number => 3,
            .boolean => 2,
        };
    }
};

const Evidence = union(enum) {
    none,
    known: Scalar,
    conflict,

    fn add(self: *Evidence, value_type: ir.Type) void {
        const candidate = scalarType(value_type) orelse return;
        switch (self.*) {
            .none => self.* = .{ .known = candidate },
            .known => |existing| {
                if (existing != candidate) self.* = .conflict;
            },
            .conflict => {},
        }
    }
};

pub fn scalarType(value_type: ir.Type) ?Scalar {
    return switch (value_type) {
        .number => .number,
        .boolean => .boolean,
        else => null,
    };
}

/// Builtins which have a complete numeric one-argument ABI.  The generic
/// Value dispatcher remains the fallback for dynamic operands; this helper is
/// only used after a typed body has already proven the operand is a number.
pub fn scalarBuiltinCommand(instruction: ir.Instruction) ?aot_builtin.Command {
    if (instruction.opcode != .call or !instruction.is_builtin_call or instruction.direct_callee != null or instruction.operands.len != 1) return null;
    const command = aot_builtin.lookup(instruction.name) orelse return null;
    return switch (command) {
        .to_int,
        .to_float,
        .math_sin,
        .math_cos,
        .math_tan,
        .math_arcsin,
        .math_arccos,
        .math_arctan,
        .math_rad2deg,
        .math_deg2rad,
        .math_sign,
        .math_abs,
        .math_exp,
        .math_log,
        .math_frac,
        .math_integer,
        .math_sqrt,
        .math_round,
        .math_ceil,
        .math_floor,
        => command,
        else => null,
    };
}

pub fn valueType(function: ir.Function, value: ir.ValueId) ir.Type {
    for (function.parameters) |parameter| if (parameter.value == value) return parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction.type;
    };
    return .dynamic;
}

fn maxValueCount(function: ir.Function) usize {
    var count: usize = 0;
    for (function.parameters) |parameter| count = @max(count, @as(usize, parameter.value) + 1);
    for (function.blocks) |block| for (block.instructions) |instruction| if (instruction.result) |result| {
        count = @max(count, @as(usize, result) + 1);
    };
    return count;
}

fn typeAt(types: []const ir.Type, value: ir.ValueId) ir.Type {
    return if (value < types.len) types[value] else .dynamic;
}

pub fn localScalar(function: ir.Function, name: []const u8) ?Scalar {
    for (function.parameters) |parameter| if (std.mem.eql(u8, parameter.name, name)) {
        if (scalarType(parameter.type)) |scalar| return scalar;
    };
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (!std.mem.eql(u8, instruction.name, name)) continue;
        switch (instruction.opcode) {
            .load_local => if (scalarType(instruction.type)) |scalar| return scalar,
            .store_local => if (instruction.operands.len > 0) if (scalarType(valueType(function, instruction.operands[0]))) |scalar| return scalar,
            else => {},
        }
    };
    return null;
}

fn localTypesAgree(function: ir.Function) bool {
    for (function.parameters) |parameter| {
        const parameter_scalar = scalarType(parameter.type) orelse continue;
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (!std.mem.eql(u8, instruction.name, parameter.name)) continue;
            const observed: ?Scalar = switch (instruction.opcode) {
                .load_local => scalarType(instruction.type),
                .store_local => if (instruction.operands.len > 0) scalarType(valueType(function, instruction.operands[0])) else null,
                else => null,
            };
            if (observed) |scalar| if (scalar != parameter_scalar) return false;
        };
    }

    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .store_local or instruction.operands.len == 0) continue;
        const observed = scalarType(valueType(function, instruction.operands[0])) orelse return false;
        if (localScalar(function, instruction.name)) |existing| if (existing != observed) return false;
    };
    return true;
}

fn localTypesAgreeWithTypes(function: ir.Function, types: []const ir.Type, parameter_types: []const ir.Type) bool {
    for (function.parameters, 0..) |parameter, parameter_index| {
        const parameter_scalar = scalarType(parameterTypeAt(function, parameter_types, parameter_index)) orelse continue;
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (!std.mem.eql(u8, instruction.name, parameter.name)) continue;
            const observed: ?Scalar = switch (instruction.opcode) {
                .load_local => if (instruction.result) |result| scalarType(typeAt(types, result)) else null,
                .store_local => if (instruction.operands.len > 0) scalarType(typeAt(types, instruction.operands[0])) else null,
                else => null,
            };
            if (observed) |scalar| if (scalar != parameter_scalar) return false;
        };
    }

    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .store_local or instruction.operands.len == 0) continue;
        const observed = scalarType(typeAt(types, instruction.operands[0])) orelse return false;
        if (localScalarWithTypes(function, types, parameter_types, instruction.name)) |existing| if (existing != observed) return false;
    };
    return true;
}

fn parameterTypeAt(function: ir.Function, parameter_types: []const ir.Type, index: usize) ir.Type {
    return if (index < parameter_types.len) parameter_types[index] else function.parameters[index].type;
}

fn localScalarWithTypes(function: ir.Function, types: []const ir.Type, parameter_types: []const ir.Type, name: []const u8) ?Scalar {
    for (function.parameters, 0..) |parameter, index| if (std.mem.eql(u8, parameter.name, name)) {
        if (scalarType(parameterTypeAt(function, parameter_types, index))) |scalar| return scalar;
    };
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (!std.mem.eql(u8, instruction.name, name)) continue;
        switch (instruction.opcode) {
            .load_local => if (instruction.result) |result| if (scalarType(typeAt(types, result))) |scalar| return scalar,
            .store_local => if (instruction.operands.len > 0) if (scalarType(typeAt(types, instruction.operands[0]))) |scalar| return scalar,
            else => {},
        }
    };
    return null;
}

fn inferLocalTypes(function: ir.Function, types: []ir.Type, parameter_types: []const ir.Type) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.opcode != .load_local) continue;
            const result = instruction.result orelse continue;
            if (typeAt(types, result) != .dynamic) continue;
            const scalar = localScalarWithTypes(function, types, parameter_types, instruction.name) orelse continue;
            types[result] = switch (scalar) {
                .number => .number,
                .boolean => .boolean,
            };
            changed = true;
        };
    }
}

fn inferPrimitiveTypes(function: ir.Function, types: []ir.Type, parameter_types: []const ir.Type) void {
    var changed = true;
    while (changed) {
        changed = false;
        inferLocalTypes(function, types, parameter_types);
        for (function.blocks) |block| for (block.instructions) |instruction| {
            const result = instruction.result orelse continue;
            if (typeAt(types, result) != .dynamic) continue;
            const inferred: ?ir.Type = switch (instruction.opcode) {
                .binary => if (instruction.operands.len >= 2) blk: {
                    const left = typeAt(types, instruction.operands[0]);
                    const right = typeAt(types, instruction.operands[1]);
                    if (isNumberArithmetic(instruction.operator) and left == .number and right == .number) break :blk .number;
                    if (isComparison(instruction.operator) and left == right and scalarType(left) != null) break :blk .boolean;
                    if (isLogical(instruction.operator) and left == .boolean and right == .boolean) break :blk .boolean;
                    break :blk null;
                } else null,
                .unary => if (instruction.operands.len == 1) blk: {
                    const operand = typeAt(types, instruction.operands[0]);
                    if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) break :blk .boolean;
                    if ((std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-")) and operand == .number) break :blk .number;
                    break :blk null;
                } else null,
                .phi => if (instruction.phi_incoming.len > 0) blk: {
                    const first = typeAt(types, instruction.phi_incoming[0].value);
                    if (scalarType(first) == null) break :blk null;
                    for (instruction.phi_incoming[1..]) |incoming| if (typeAt(types, incoming.value) != first) break :blk null;
                    break :blk first;
                } else null,
                .call => if (scalarBuiltinCommand(instruction) != null and instruction.operands.len == 1 and typeAt(types, instruction.operands[0]) == .number) .number else null,
                else => null,
            };
            if (inferred) |value_type| {
                types[result] = value_type;
                changed = true;
            }
        };
    }
}

pub fn resultScalar(function: ir.Function) ?Scalar {
    return scalarType(function.return_type);
}

fn isNumberArithmetic(operator: []const u8) bool {
    for ([_][]const u8{ "+", "-", "*", "/", "÷", "÷÷", "%", "**" }) |candidate| {
        if (std.mem.eql(u8, operator, candidate)) return true;
    }
    return false;
}

fn isComparison(operator: []const u8) bool {
    for ([_][]const u8{ "==", "=", "eq", "===", "!=", "≠", "noteq", "!==", "<", "lt", "<=", "lteq", ">", "gt", ">=", "gteq" }) |candidate| {
        if (std.mem.eql(u8, operator, candidate)) return true;
    }
    return false;
}

fn isLogical(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or
        std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
}

fn instructionSupported(function: ir.Function, instruction: ir.Instruction) bool {
    const result_scalar = if (instruction.result) |result| scalarType(valueType(function, result)) else null;
    switch (instruction.opcode) {
        .const_number => return result_scalar == .number,
        .const_boolean => return result_scalar == .boolean,
        .load_local => return result_scalar != null and localScalar(function, instruction.name) != null,
        .store_local => {
            if (instruction.operands.len != 1) return false;
            const operand_scalar = scalarType(valueType(function, instruction.operands[0])) orelse return false;
            return localScalar(function, instruction.name) == operand_scalar;
        },
        .binary => {
            if (instruction.operands.len < 2) return false;
            const left = scalarType(valueType(function, instruction.operands[0])) orelse return false;
            const right = scalarType(valueType(function, instruction.operands[1])) orelse return false;
            if (isNumberArithmetic(instruction.operator)) return left == .number and right == .number and result_scalar == .number;
            if (isComparison(instruction.operator)) return left == right and result_scalar == .boolean;
            if (isLogical(instruction.operator)) return left == .boolean and right == .boolean and result_scalar == .boolean;
            return false;
        },
        .unary => {
            if (instruction.operands.len != 1) return false;
            const operand = scalarType(valueType(function, instruction.operands[0])) orelse return false;
            if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) return result_scalar == .boolean;
            if (std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-")) return operand == .number and result_scalar == .number;
            return false;
        },
        .exception_pending => return result_scalar == .boolean,
        .phi => {
            if (result_scalar == null or instruction.phi_incoming.len == 0) return false;
            for (instruction.phi_incoming) |incoming| {
                if (scalarType(valueType(function, incoming.value)) != result_scalar) return false;
            }
            return true;
        },
        // These instructions carry no value and preserve the CFG's exception
        // edges.  The typed emitter handles their control-flow counterparts.
        .try_begin, .try_end => return instruction.result == null,
        else => return false,
    }
}

fn instructionSupportedWithTypes(function: ir.Function, types: []const ir.Type, parameter_types: []const ir.Type, instruction: ir.Instruction) bool {
    const result_scalar = if (instruction.result) |result| scalarType(typeAt(types, result)) else null;
    switch (instruction.opcode) {
        .const_number => return result_scalar == .number,
        .const_boolean => return result_scalar == .boolean,
        .load_local => return result_scalar != null and localScalarWithTypes(function, types, parameter_types, instruction.name) != null,
        .store_local => {
            if (instruction.operands.len != 1) return false;
            const operand_scalar = scalarType(typeAt(types, instruction.operands[0])) orelse return false;
            return localScalarWithTypes(function, types, parameter_types, instruction.name) == operand_scalar;
        },
        .binary => {
            if (instruction.operands.len < 2) return false;
            const left = scalarType(typeAt(types, instruction.operands[0])) orelse return false;
            const right = scalarType(typeAt(types, instruction.operands[1])) orelse return false;
            if (isNumberArithmetic(instruction.operator)) return left == .number and right == .number and result_scalar == .number;
            if (isComparison(instruction.operator)) return left == right and result_scalar == .boolean;
            if (isLogical(instruction.operator)) return left == .boolean and right == .boolean and result_scalar == .boolean;
            return false;
        },
        .unary => {
            if (instruction.operands.len != 1) return false;
            const operand = scalarType(typeAt(types, instruction.operands[0])) orelse return false;
            if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) return result_scalar == .boolean;
            if (std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-")) return operand == .number and result_scalar == .number;
            return false;
        },
        .exception_pending => return result_scalar == .boolean,
        .phi => {
            if (result_scalar == null or instruction.phi_incoming.len == 0) return false;
            for (instruction.phi_incoming) |incoming| if (scalarType(typeAt(types, incoming.value)) != result_scalar) return false;
            return true;
        },
        .call => return instruction.direct_callee != null or (scalarBuiltinCommand(instruction) != null and instruction.result != null and typeAt(types, instruction.operands[0]) == .number and result_scalar == .number),
        .try_begin, .try_end => return instruction.result == null,
        else => return false,
    }
}

fn terminatorSupported(function: ir.Function, terminator: ir.Terminator) bool {
    return switch (terminator) {
        .branch, .unreachable_terminator, .propagate_exception => true,
        .conditional_branch => |branch| scalarType(valueType(function, branch.condition)) != null,
        .return_value => |value| value != null and scalarType(valueType(function, value.?)) == resultScalar(function),
        else => false,
    };
}

fn terminatorSupportedWithTypes(types: []const ir.Type, terminator: ir.Terminator) bool {
    return switch (terminator) {
        .branch, .unreachable_terminator, .propagate_exception => true,
        .conditional_branch => |branch| scalarType(typeAt(types, branch.condition)) != null,
        // Return type consistency is solved together with direct-call edges;
        // a dynamic return value may be a recursive call whose scalar type is
        // established by the fixed point below.
        .return_value => |value| value != null,
        else => false,
    };
}

fn staticEligibility(function: ir.Function, types: []const ir.Type, parameter_types: []const ir.Type) bool {
    if (function.parameters.len == 0 and function.blocks.len == 0) return false;
    if (function.captures.len != 0 or function.is_async or function.is_test) return false;
    for (function.parameters, 0..) |_, index| if (scalarType(parameterTypeAt(function, parameter_types, index)) == null) return false;
    if (!localTypesAgreeWithTypes(function, types, parameter_types)) return false;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| if (!instructionSupportedWithTypes(function, types, parameter_types, instruction)) return false;
        if (!terminatorSupportedWithTypes(types, block.terminator)) return false;
    }
    return true;
}

fn callResultInstruction(function: ir.Function, value: ir.ValueId) ?ir.Instruction {
    for (function.blocks) |block| for (block.instructions) |instruction| if (instruction.result) |result| {
        if (result == value) return instruction;
    };
    return null;
}

fn baseReturnScalar(function: ir.Function, types: []const ir.Type) ?Scalar {
    var result: ?Scalar = null;
    var saw_return = false;
    for (function.blocks) |block| switch (block.terminator) {
        .return_value => |value| {
            const returned = value orelse return null;
            if (callResultInstruction(function, returned)) |instruction| if (instruction.opcode == .call) continue;
            const scalar = scalarType(typeAt(types, returned)) orelse continue;
            if (result) |existing| {
                if (existing != scalar) return null;
            } else result = scalar;
            saw_return = true;
        },
        else => {},
    };
    return if (saw_return) result else null;
}

fn directCalleeId(program: ir.Program, instruction: ir.Instruction) ?ir.FunctionId {
    const id = instruction.direct_callee orelse return null;
    if (id >= program.functions.len) return null;
    return id;
}

fn callSupported(program: ir.Program, types: [][]ir.Type, parameter_types: [][]ir.Type, candidates: []const ?Scalar, function: ir.Function, instruction: ir.Instruction) bool {
    if (instruction.is_builtin_call) {
        return scalarBuiltinCommand(instruction) != null and instruction.result != null and
            typeAt(types[function.id], instruction.operands[0]) == .number and
            scalarType(typeAt(types[function.id], instruction.result.?)) == .number;
    }
    const callee_id = directCalleeId(program, instruction) orelse return false;
    const scalar = candidates[callee_id] orelse return false;
    const result_type = if (instruction.result) |result| typeAt(types[function.id], result) else instruction.type;
    const callee_parameters = parameter_types[callee_id];
    if (scalarType(result_type) != scalar or instruction.operands.len != callee_parameters.len) return false;
    for (instruction.operands, callee_parameters) |operand, parameter_type| {
        if (typeAt(types[function.id], operand) != parameter_type) return false;
        if (scalarType(typeAt(types[function.id], operand)) == null) return false;
    }
    return true;
}

fn returnScalarFromTypes(function: ir.Function, types: []const ir.Type) ?Scalar {
    var result: ?Scalar = null;
    var saw_return = false;
    for (function.blocks) |block| switch (block.terminator) {
        .return_value => |value| {
            const returned = value orelse return null;
            const scalar = scalarType(typeAt(types, returned)) orelse return null;
            if (result) |existing| {
                if (existing != scalar) return null;
            } else result = scalar;
            saw_return = true;
        },
        else => {},
    };
    if (!saw_return) return null;
    if (scalarType(function.return_type)) |declared| if (result.? != declared) return null;
    return result;
}

fn fallbackParameterType(function: ir.Function) ir.Type {
    var saw_boolean_operation = false;
    var saw_number_operation = false;
    for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.opcode) {
        .binary => {
            if (isLogical(instruction.operator)) saw_boolean_operation = true;
            if (isNumberArithmetic(instruction.operator)) saw_number_operation = true;
        },
        .unary => {
            if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) saw_boolean_operation = true;
        },
        else => {},
    };
    if (saw_boolean_operation and !saw_number_operation) return .boolean;
    return .number;
}

fn collectParameterTypes(allocator: std.mem.Allocator, program: ir.Program, raw_types: [][]ir.Type) ![][]ir.Type {
    const evidence = try allocator.alloc([]Evidence, program.functions.len);
    var evidence_initialized: usize = 0;
    errdefer {
        for (evidence[0..evidence_initialized]) |items| allocator.free(items);
        allocator.free(evidence);
    }
    for (program.functions, evidence) |function, *items| {
        items.* = try allocator.alloc(Evidence, function.parameters.len);
        @memset(items.*, .none);
        evidence_initialized += 1;
    }
    for (program.functions) |caller| {
        const caller_types = raw_types[caller.id];
        for (caller.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.opcode != .call) continue;
            const callee_id = instruction.direct_callee orelse continue;
            if (callee_id >= program.functions.len) continue;
            for (evidence[callee_id], 0..) |*item, index| {
                if (index >= instruction.operands.len) {
                    item.* = .conflict;
                } else item.add(typeAt(caller_types, instruction.operands[index]));
            }
        };
    }

    const parameter_types = try allocator.alloc([]ir.Type, program.functions.len);
    var initialized: usize = 0;
    errdefer {
        for (parameter_types[0..initialized]) |items| allocator.free(items);
        allocator.free(parameter_types);
    }
    for (program.functions, parameter_types) |function, *items| {
        items.* = try allocator.alloc(ir.Type, function.parameters.len);
        initialized += 1;
        for (function.parameters, 0..) |parameter, index| {
            if (scalarType(parameter.type) != null) {
                items.*[index] = parameter.type;
            } else items.*[index] = switch (evidence[function.id][index]) {
                .known => |value| switch (value) {
                    .number => .number,
                    .boolean => .boolean,
                },
                .none => fallbackParameterType(function),
                .conflict => .dynamic,
            };
        }
    }
    for (evidence) |items| allocator.free(items);
    allocator.free(evidence);
    return parameter_types;
}

fn resetValueTypes(function: ir.Function, types: []ir.Type, parameter_types: []const ir.Type) void {
    @memset(types, .dynamic);
    for (function.parameters, 0..) |parameter, index| types[parameter.value] = parameterTypeAt(function, parameter_types, index);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| types[result] = instruction.type;
    };
    inferPrimitiveTypes(function, types, parameter_types);
}

/// Cached whole-program proof for primitive internal ABI bodies.  ValueId type
/// tables are built once per function, then call eligibility is solved as a
/// monotone fixed point.  Initial candidates contain only local/CFG proofs;
/// recursive direct-call SCCs remain eligible when every edge has a matching
/// primitive signature.  Any unknown, indirect, dynamic, callback, or
/// unsupported edge removes the affected candidate and its callers.
pub const ProgramAnalysis = struct {
    scalar_by_id: []?Scalar,
    value_types: [][]ir.Type,
    parameter_types: [][]ir.Type,

    pub fn deinit(self: *ProgramAnalysis, allocator: std.mem.Allocator) void {
        for (self.value_types) |types| allocator.free(types);
        for (self.parameter_types) |types| allocator.free(types);
        allocator.free(self.value_types);
        allocator.free(self.parameter_types);
        allocator.free(self.scalar_by_id);
        self.* = undefined;
    }

    pub fn scalar(self: ProgramAnalysis, function_id: ir.FunctionId) ?Scalar {
        return if (function_id < self.scalar_by_id.len) self.scalar_by_id[function_id] else null;
    }

    pub fn valueType(self: ProgramAnalysis, function_id: ir.FunctionId, value: ir.ValueId) ir.Type {
        if (function_id >= self.value_types.len) return .dynamic;
        return typeAt(self.value_types[function_id], value);
    }

    pub fn parameterType(self: ProgramAnalysis, function_id: ir.FunctionId, index: usize) ir.Type {
        if (function_id >= self.parameter_types.len or index >= self.parameter_types[function_id].len) return .dynamic;
        return self.parameter_types[function_id][index];
    }

    pub fn localScalar(self: ProgramAnalysis, function: ir.Function, name: []const u8) ?Scalar {
        for (function.parameters, 0..) |parameter, index| if (std.mem.eql(u8, parameter.name, name)) {
            if (scalarType(self.parameterType(function.id, index))) |kind| return kind;
        };
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (!std.mem.eql(u8, instruction.name, name)) continue;
            switch (instruction.opcode) {
                .load_local => if (instruction.result) |result| if (scalarType(self.valueType(function.id, result))) |kind| return kind,
                .store_local => if (instruction.operands.len > 0) if (scalarType(self.valueType(function.id, instruction.operands[0]))) |kind| return kind,
                else => {},
            }
        };
        return null;
    }

    pub fn callSpecialization(self: ProgramAnalysis, callee: ir.Function, argument_types: []const ir.Type) ?Scalar {
        const result_scalar = self.scalar(callee.id) orelse return null;
        if (argument_types.len != callee.parameters.len) return null;
        for (argument_types, 0..) |argument_type, index| {
            if (self.parameterType(callee.id, index) != argument_type or scalarType(argument_type) == null) return null;
        }
        return result_scalar;
    }
};

pub fn analyzeProgram(allocator: std.mem.Allocator, program: ir.Program) !ProgramAnalysis {
    const scalar_by_id = try allocator.alloc(?Scalar, program.functions.len);
    errdefer allocator.free(scalar_by_id);
    @memset(scalar_by_id, null);
    const value_types = try allocator.alloc([]ir.Type, program.functions.len);
    var initialized: usize = 0;
    errdefer {
        for (value_types[0..initialized]) |types| allocator.free(types);
        allocator.free(value_types);
    }
    for (program.functions, value_types) |function, *types| {
        types.* = try allocator.alloc(ir.Type, maxValueCount(function));
        initialized += 1;
    }

    const raw_types = try allocator.alloc([]ir.Type, program.functions.len);
    var raw_initialized: usize = 0;
    defer {
        for (raw_types[0..raw_initialized]) |types| allocator.free(types);
        allocator.free(raw_types);
    }
    for (program.functions, raw_types) |function, *types| {
        types.* = try allocator.alloc(ir.Type, maxValueCount(function));
        raw_initialized += 1;
        @memset(types.*, .dynamic);
        for (function.parameters) |parameter| types.*[parameter.value] = parameter.type;
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.result) |result| types.*[result] = instruction.type;
        };
    }
    const parameter_types = collectParameterTypes(allocator, program, raw_types) catch |err| {
        return err;
    };
    errdefer {
        for (parameter_types) |types| allocator.free(types);
        allocator.free(parameter_types);
    }

    var active = try allocator.alloc(bool, program.functions.len);
    defer allocator.free(active);
    @memset(active, true);
    for (program.functions, 0..) |function, index| {
        resetValueTypes(function, value_types[index], parameter_types[index]);
        // Delay the full local/CFG check until call results have propagated.
        // A recursive function's stores initially contain dynamic call results
        // even though the same SCC can prove them scalar in the next pass.
        active[index] = function.parameters.len != 0 or function.blocks.len != 0;
        active[index] = active[index] and function.captures.len == 0 and !function.is_async and !function.is_test;
        for (function.parameters, 0..) |_, parameter_index| {
            if (scalarType(parameterTypeAt(function, parameter_types[index], parameter_index)) == null) active[index] = false;
        }
    }

    var outer_iteration: usize = 0;
    var changed = true;
    while (changed and outer_iteration < program.functions.len + 2) : (outer_iteration += 1) {
        changed = false;
        @memset(scalar_by_id, null);
        for (program.functions, 0..) |function, index| resetValueTypes(function, value_types[index], parameter_types[index]);

        // First close all return types and call-result types for the currently
        // active signatures.  No function is removed while this inner pass is
        // still discovering a recursive SCC, so function order cannot break a
        // valid A -> B -> A cycle.
        var inner_changed = true;
        var inner_iteration: usize = 0;
        while (inner_changed and inner_iteration < program.functions.len + 2) : (inner_iteration += 1) {
            inner_changed = false;
            for (program.functions, 0..) |function, index| {
                if (!active[index]) continue;
                for (function.blocks) |block| for (block.instructions) |instruction| {
                    if (instruction.opcode != .call) continue;
                    const callee_id = directCalleeId(program, instruction) orelse continue;
                    if (!active[callee_id]) continue;
                    const result = instruction.result orelse continue;
                    const scalar = scalar_by_id[callee_id] orelse continue;
                    const desired: ir.Type = if (scalar == .number) .number else .boolean;
                    if (typeAt(value_types[index], result) == .dynamic) {
                        value_types[index][result] = desired;
                        inner_changed = true;
                    }
                };
                inferPrimitiveTypes(function, value_types[index], parameter_types[index]);
                if (scalar_by_id[index] == null) {
                    // A recursive function may have a scalar base return even
                    // while its self-call result is still dynamic.  Seed that
                    // result before the next pass so the whole SCC can close.
                    if (baseReturnScalar(function, value_types[index])) |scalar| {
                        scalar_by_id[index] = scalar;
                        inner_changed = true;
                    } else if (returnScalarFromTypes(function, value_types[index])) |scalar| {
                        scalar_by_id[index] = scalar;
                        inner_changed = true;
                    }
                }
            }
        }

        for (program.functions, 0..) |function, index| {
            if (!active[index]) continue;
            if (!staticEligibility(function, value_types[index], parameter_types[index]) or
                scalar_by_id[index] == null or returnScalarFromTypes(function, value_types[index]) == null)
            {
                active[index] = false;
                scalar_by_id[index] = null;
                changed = true;
                continue;
            }
            for (function.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.opcode == .call and !callSupported(program, value_types, parameter_types, scalar_by_id, function, instruction)) {
                    active[index] = false;
                    scalar_by_id[index] = null;
                    changed = true;
                    break;
                }
            };
        }
    }
    return .{ .scalar_by_id = scalar_by_id, .value_types = value_types, .parameter_types = parameter_types };
}

/// Returns the scalar result type only when the complete function can be
/// emitted as a primitive body.  Unknown values, dynamic execution, captures,
/// callbacks, and host calls all stay on the generic `%lnako.Value` ABI.
pub fn specialization(function: ir.Function) ?Scalar {
    const result = resultScalar(function) orelse return null;
    if (function.parameters.len == 0 and function.blocks.len == 0) return null;
    if (function.captures.len != 0 or function.is_async or function.is_test) return null;
    for (function.parameters) |parameter| if (scalarType(parameter.type) == null) return null;
    if (!localTypesAgree(function)) return null;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| if (!instructionSupported(function, instruction)) return null;
        if (!terminatorSupported(function, block.terminator)) return null;
    }
    return result;
}

/// Returns the specialization used by a statically proven call site.  The
/// caller supplies its already inferred operand types so this helper remains
/// independent of the emitter's cache and cannot accidentally specialize an
/// indirect or unknown call.
pub fn callSpecialization(callee: ir.Function, argument_types: []const ir.Type) ?Scalar {
    const result = specialization(callee) orelse return null;
    if (argument_types.len != callee.parameters.len) return null;
    for (callee.parameters, argument_types) |parameter, argument_type| {
        if (parameter.type != argument_type or scalarType(argument_type) == null) return null;
    }
    return result;
}

pub fn writeName(writer: *std.Io.Writer, scalar: Scalar, function_id: ir.FunctionId) !void {
    try writer.print("@lnako.fn.{s}.{d}", .{ scalar.suffix(), function_id });
}

test "typed ABI only accepts closed primitive CFGs" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters = [_]ir.Parameter{.{ .name = "A", .value = 0, .type = .number }};
    var operands = [_]ir.ValueId{0};
    var instructions = [_]ir.Instruction{
        .{ .result = 1, .opcode = .load_local, .type = .number, .name = "A", .span = span },
        .{ .result = null, .opcode = .store_local, .type = .void, .name = "A", .operands = &operands, .span = span },
    };
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .return_value = 1 },
    }};
    const function = ir.Function{
        .id = 0,
        .name = "number",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .number,
        .is_async = false,
        .is_test = false,
    };
    try std.testing.expectEqual(Scalar.number, specialization(function));
}

test "typed ABI closes a proven recursive Number SCC" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters = [_]ir.Parameter{.{ .name = "N", .value = 0, .type = .number }};
    var recursive_argument = [_]ir.ValueId{0};
    var entry_instructions = [_]ir.Instruction{
        .{ .result = 1, .opcode = .const_boolean, .type = .boolean, .boolean_value = true, .span = span },
    };
    var base_instructions = [_]ir.Instruction{
        .{ .result = 2, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
    };
    var recursive_instructions = [_]ir.Instruction{
        .{ .result = 3, .opcode = .call, .type = .dynamic, .direct_callee = 0, .operands = &recursive_argument, .name = "recursive", .span = span },
    };
    var blocks = [_]ir.BasicBlock{
        .{ .id = 0, .name = "entry", .instructions = &entry_instructions, .terminator = .{ .conditional_branch = .{ .condition = 1, .then_block = 1, .else_block = 2 } } },
        .{ .id = 1, .name = "base", .instructions = &base_instructions, .terminator = .{ .return_value = 2 } },
        .{ .id = 2, .name = "recursive", .instructions = &recursive_instructions, .terminator = .{ .return_value = 3 } },
    };
    var functions = [_]ir.Function{.{
        .id = 0,
        .name = "recursive",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }};
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(Scalar.number, analysis.scalar(0));
    try std.testing.expectEqual(ir.Type.number, analysis.valueType(0, 3));
}

test "typed ABI derives a private Number signature for a dynamic public parameter" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters = [_]ir.Parameter{.{ .name = "A", .value = 0, .type = .dynamic }};
    var operands = [_]ir.ValueId{ 0, 1 };
    var instructions = [_]ir.Instruction{
        .{ .result = 1, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
        .{ .result = 2, .opcode = .binary, .type = .dynamic, .operator = "+", .operands = &operands, .span = span },
    };
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .return_value = 2 },
    }};
    var functions = [_]ir.Function{.{
        .id = 0,
        .name = "public-number",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }};
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Type.dynamic, functions[0].parameters[0].type);
    try std.testing.expectEqual(ir.Type.number, analysis.parameterType(0, 0));
    try std.testing.expectEqual(ir.Type.number, analysis.valueType(0, 2));
    try std.testing.expectEqual(Scalar.number, analysis.scalar(0));
    try std.testing.expectEqual(Scalar.number, analysis.callSpecialization(functions[0], &.{.number}));
    try std.testing.expect(analysis.callSpecialization(functions[0], &.{.boolean}) == null);
}

test "typed ABI derives a private Boolean signature for a dynamic public parameter" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters = [_]ir.Parameter{.{ .name = "A", .value = 0, .type = .dynamic }};
    var operands = [_]ir.ValueId{0};
    var instructions = [_]ir.Instruction{.{
        .result = 1,
        .opcode = .unary,
        .type = .dynamic,
        .operator = "!",
        .operands = &operands,
        .span = span,
    }};
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .return_value = 1 },
    }};
    var functions = [_]ir.Function{.{
        .id = 0,
        .name = "public-boolean",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }};
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Type.boolean, analysis.parameterType(0, 0));
    try std.testing.expectEqual(ir.Type.boolean, analysis.valueType(0, 1));
    try std.testing.expectEqual(Scalar.boolean, analysis.scalar(0));
    try std.testing.expectEqual(Scalar.boolean, analysis.callSpecialization(functions[0], &.{.boolean}));
}

test "typed ABI admits numeric unary builtin calls" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters = [_]ir.Parameter{.{ .name = "A", .value = 0, .type = .dynamic }};
    var operands = [_]ir.ValueId{0};
    var instructions = [_]ir.Instruction{.{
        .result = 1,
        .opcode = .call,
        .type = .dynamic,
        .is_builtin_call = true,
        .operands = &operands,
        .name = "SQRT",
        .span = span,
    }};
    var blocks = [_]ir.BasicBlock{.{
        .id = 0,
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .return_value = 1 },
    }};
    var functions = [_]ir.Function{.{
        .id = 0,
        .name = "public-sqrt",
        .parameters = &parameters,
        .blocks = &blocks,
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    }};
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(aot_builtin.Command.math_sqrt, scalarBuiltinCommand(instructions[0]));
    try std.testing.expectEqual(Scalar.number, analysis.scalar(0));
    try std.testing.expectEqual(ir.Type.number, analysis.valueType(0, 1));
}

test "typed ABI closes a proven mutual recursive Number SCC" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var parameters_a = [_]ir.Parameter{.{ .name = "N", .value = 0, .type = .dynamic }};
    var parameters_b = [_]ir.Parameter{.{ .name = "N", .value = 0, .type = .dynamic }};
    var recursive_argument_a = [_]ir.ValueId{0};
    var recursive_argument_b = [_]ir.ValueId{0};
    var a_entry_instructions = [_]ir.Instruction{
        .{ .result = 1, .opcode = .const_boolean, .type = .boolean, .boolean_value = true, .span = span },
    };
    var a_base_instructions = [_]ir.Instruction{
        .{ .result = 2, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
    };
    var a_recursive_instructions = [_]ir.Instruction{
        .{ .result = 3, .opcode = .call, .type = .dynamic, .direct_callee = 1, .operands = &recursive_argument_a, .name = "mutual-b", .span = span },
    };
    var b_entry_instructions = [_]ir.Instruction{
        .{ .result = 1, .opcode = .const_boolean, .type = .boolean, .boolean_value = true, .span = span },
    };
    var b_base_instructions = [_]ir.Instruction{
        .{ .result = 2, .opcode = .const_number, .type = .number, .number_value = 1, .span = span },
    };
    var b_recursive_instructions = [_]ir.Instruction{
        .{ .result = 3, .opcode = .call, .type = .dynamic, .direct_callee = 0, .operands = &recursive_argument_b, .name = "mutual-a", .span = span },
    };
    var a_blocks = [_]ir.BasicBlock{
        .{ .id = 0, .name = "entry-a", .instructions = &a_entry_instructions, .terminator = .{ .conditional_branch = .{ .condition = 1, .then_block = 1, .else_block = 2 } } },
        .{ .id = 1, .name = "base-a", .instructions = &a_base_instructions, .terminator = .{ .return_value = 2 } },
        .{ .id = 2, .name = "recursive-a", .instructions = &a_recursive_instructions, .terminator = .{ .return_value = 3 } },
    };
    var b_blocks = [_]ir.BasicBlock{
        .{ .id = 0, .name = "entry-b", .instructions = &b_entry_instructions, .terminator = .{ .conditional_branch = .{ .condition = 1, .then_block = 1, .else_block = 2 } } },
        .{ .id = 1, .name = "base-b", .instructions = &b_base_instructions, .terminator = .{ .return_value = 2 } },
        .{ .id = 2, .name = "recursive-b", .instructions = &b_recursive_instructions, .terminator = .{ .return_value = 3 } },
    };
    var functions = [_]ir.Function{
        .{ .id = 0, .name = "mutual-a", .parameters = &parameters_a, .blocks = &a_blocks, .entry = 0, .return_type = .dynamic, .is_async = false, .is_test = false },
        .{ .id = 1, .name = "mutual-b", .parameters = &parameters_b, .blocks = &b_blocks, .entry = 0, .return_type = .dynamic, .is_async = false, .is_test = false },
    };
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(Scalar.number, analysis.scalar(0));
    try std.testing.expectEqual(Scalar.number, analysis.scalar(1));
    try std.testing.expectEqual(ir.Type.number, analysis.valueType(0, 3));
    try std.testing.expectEqual(ir.Type.number, analysis.valueType(1, 3));
}

test "typed ABI rejects an indirect or unknown call" {
    const span = @import("../../../../frontend/ast.zig").emptySpan();
    var arguments = [_]ir.ValueId{};
    var instructions = [_]ir.Instruction{.{ .result = 0, .opcode = .call, .type = .dynamic, .operands = &arguments, .name = "unknown", .span = span }};
    var blocks = [_]ir.BasicBlock{.{ .id = 0, .name = "entry", .instructions = &instructions, .terminator = .{ .return_value = 0 } }};
    var functions = [_]ir.Function{.{ .id = 0, .name = "dynamic", .parameters = &.{}, .blocks = &blocks, .entry = 0, .return_type = .dynamic, .is_async = false, .is_test = false }};
    var program = ir.Program{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .functions = &functions, .module_entries = &.{} };
    defer program.deinit();
    var analysis = try analyzeProgram(std.testing.allocator, program);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expect(analysis.scalar(0) == null);
}
