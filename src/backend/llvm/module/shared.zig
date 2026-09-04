const std = @import("std");
const ir = @import("../../../ir/nako_ir.zig");

pub const manifest_schema = "lnako.aot.builtin-manifest.v1";
pub const global_manifest_schema = "lnako.aot.global-manifest.v1";
pub const literal_manifest_schema = "lnako.aot.literal-manifest.v1";
pub const StringConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, units: []u16, index: usize };
pub const DebugPathConstant = struct { path: []const u8 };
pub const SystemStringConstant = struct { global_index: usize, units: []u16 };
pub const BigIntConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, text: []const u8, index: usize };
pub const DebugLocation = struct { id: usize, line: usize, column: usize, scope: usize };

pub fn lookupFunction(program: ir.Program, name: []const u8) ?ir.Function {
    for (program.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

pub fn isDynamicNamedCall(function: ir.Function, name: []const u8) bool {
    return isQualifiedGlobal(name) or hasLocalName(function, name);
}

pub fn isNativePluginCall(program: ir.Program, function: ir.Function, instruction: ir.Instruction) bool {
    return program.native_plugin_paths.len > 0 and
        instruction.opcode == .call and
        instruction.direct_callee == null and
        !instruction.is_builtin_call and
        instruction.name.len > 0 and
        lookupFunction(program, instruction.name) == null and
        !isDynamicNamedCall(function, instruction.name);
}

pub fn hasLocalName(function: ir.Function, name: []const u8) bool {
    for (function.captures) |capture| if (std.mem.eql(u8, capture, name)) return true;
    for (function.parameters) |parameter| if (std.mem.eql(u8, parameter.name, name)) return true;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if ((instruction.opcode == .load_local or instruction.opcode == .store_local or instruction.opcode == .increment) and
            std.mem.eql(u8, instruction.name, name)) return true;
        if (instruction.opcode == .destructure_store) for (instruction.names) |local_name| {
            if (std.mem.eql(u8, local_name, name)) return true;
        };
    };
    return false;
}

pub fn isDisplayCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する") or std.mem.eql(u8, name, "連続表示");
}

pub fn valueType(function: ir.Function, value: ir.ValueId) ir.Type {
    for (function.parameters) |parameter| if (parameter.value == value) return parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction.type;
    };
    return .dynamic;
}

pub fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

pub fn arithmeticOpcode(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, opcode: []const u8 }{
        .{ .operator = "+", .opcode = "fadd" },
        .{ .operator = "-", .opcode = "fsub" },
        .{ .operator = "*", .opcode = "fmul" },
        .{ .operator = "/", .opcode = "fdiv" },
        .{ .operator = "÷", .opcode = "fdiv" },
        .{ .operator = "÷÷", .opcode = "divfloor" },
        .{ .operator = "%", .opcode = "frem" },
        .{ .operator = "**", .opcode = "pow" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

pub fn shiftOpcode(operator: []const u8) ?u8 {
    const entries = [_]struct { operator: []const u8, opcode: u8 }{
        .{ .operator = "shift_l", .opcode = 0 },
        .{ .operator = "shift_r", .opcode = 1 },
        .{ .operator = "shift_r0", .opcode = 2 },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}
