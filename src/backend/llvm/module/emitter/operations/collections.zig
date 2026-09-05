const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../../../../ir/nako_ir.zig");
const ast = @import("../../../../../frontend/ast.zig");
const aot_abi = @import("../../../../../runtime/aot_abi.zig");
const aot_builtin = @import("../../../../../runtime/aot_builtin.zig");
const system_constant = @import("../../../../../runtime/system_constant.zig");
const shared = @import("../../shared.zig");
const context = @import("../context.zig");
const Emitter = context.Emitter;
const StringConstant = shared.StringConstant;
const DebugPathConstant = shared.DebugPathConstant;
const SystemStringConstant = shared.SystemStringConstant;
const BigIntConstant = shared.BigIntConstant;
const DebugLocation = shared.DebugLocation;
const arithmeticOpcode = shared.arithmeticOpcode;
const isDisplayCall = shared.isDisplayCall;
const isNativePluginCall = shared.isNativePluginCall;
const isQualifiedGlobal = shared.isQualifiedGlobal;
const lookupFunction = shared.lookupFunction;
const shiftOpcode = shared.shiftOpcode;
const valueType = shared.valueType;
const constants_mod = @import("constants.zig");
const collections_mod = @import("collections.zig");
const variables_mod = @import("variables.zig");
const control_mod = @import("control.zig");
const arithmetic_mod = @import("arithmetic.zig");
const calls_mod = @import("calls.zig");
const plugins_mod = @import("plugins.zig");
const instruction_router_mod = @import("../instruction_router.zig");
const terminators_mod = @import("../terminators.zig");
const functions_mod = @import("../functions.zig");
const preamble_mod = @import("../preamble.zig");
const declarations_mod = @import("../declarations.zig");

pub fn writeRootStore(emitter: *Emitter, instruction: ir.Instruction) !void {
    const result = instruction.result orelse return;
    try emitter.output.writer.print("  store %lnako.Value %v{d}, ptr %root.slot.{d}\n", .{ result, result });
}

pub fn writeDestructure(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 1) return error.InvalidDestructure;
    for (instruction.names, 0..) |name, index| {
        try emitter.output.writer.writeAll("  call void @lnako_aot_destructure_get(ptr ");
        try variables_mod.writeRequiredNamedPointer(emitter, locals, name);
        try emitter.output.writer.print(", ptr %root.slot.{d}, i64 {d})", .{ instruction.operands[0], index });
        try emitter.debugSuffix(instruction.span, scope);
    }
}

pub fn writeAggregate(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, runtime_name: []const u8) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len > aggregate_count) return error.InvalidAggregateScratch;
    for (instruction.operands, 0..) |operand, index| {
        try emitter.output.writer.print("  %aggregate.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, operand);
        try emitter.output.writer.print(", ptr %aggregate.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  call void @{s}(ptr %root.slot.{d}, ptr ", .{ runtime_name, result });
    if (instruction.operands.len > 0) {
        try emitter.output.writer.print("%aggregate.{d}.slot.0", .{result});
    } else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.print(", i64 {d})", .{instruction.operands.len});
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeIndexGet(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidIndexReference;
    for (instruction.operands[1..], 0..) |key, index| {
        const last = index + 2 == instruction.operands.len;
        try emitter.output.writer.print("  call void @lnako_aot_index_get(ptr %root.slot.{d}, ptr ", .{result});
        if (index == 0) {
            try emitter.output.writer.print("%root.slot.{d}", .{instruction.operands[0]});
        } else try emitter.output.writer.print("%root.slot.{d}", .{result});
        try emitter.output.writer.print(", ptr %root.slot.{d})", .{key});
        try emitter.debugSuffix(instruction.span, scope);
        if (!last) continue;
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
    }
}

pub fn writeIndexSet(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len < 2) return error.InvalidIndexAssignment;
    const temporary = emitter.next_metadata;
    const literal_tag: ?u8 = if (std.mem.eql(u8, instruction.name, "NULL")) 1 else if (std.mem.eql(u8, instruction.name, "undefined")) 0 else null;
    if (literal_tag) |tag| {
        try emitter.output.writer.print("  store %lnako.Value {{ i8 {d}, i64 0 }}, ptr %runtime.scratch", .{tag});
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  %set.container.{d} = load %lnako.Value, ptr ", .{temporary});
    try variables_mod.writeAssignmentContainerPointer(emitter, locals, instruction.name, literal_tag != null);
    try emitter.debugSuffix(instruction.span, scope);
    for (instruction.operands[1 .. instruction.operands.len - 1], 0..) |key, index| {
        try emitter.output.writer.writeAll("  call void @lnako_aot_index_get(ptr %runtime.scratch, ptr ");
        if (index == 0) {
            try variables_mod.writeAssignmentContainerPointer(emitter, locals, instruction.name, literal_tag != null);
        } else try emitter.output.writer.writeAll("%runtime.scratch");
        try emitter.output.writer.print(", ptr %root.slot.{d})", .{key});
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  %set.status.{d} = call i32 @lnako_aot_index_set(ptr ", .{temporary});
    if (instruction.operands.len == 2) {
        try variables_mod.writeAssignmentContainerPointer(emitter, locals, instruction.name, literal_tag != null);
    } else try emitter.output.writer.writeAll("%runtime.scratch");
    try emitter.output.writer.print(", ptr %root.slot.{d}, ptr %root.slot.{d})", .{ instruction.operands[instruction.operands.len - 1], instruction.operands[0] });
    try emitter.debugSuffix(instruction.span, scope);
}
