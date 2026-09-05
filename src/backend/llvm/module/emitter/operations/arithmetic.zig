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

pub fn writeBinary(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and") or
        std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or"))
    {
        const condition_label = try std.fmt.allocPrint(emitter.allocator, "condition.{d}", .{result});
        defer emitter.allocator.free(condition_label);
        try constants_mod.writeTruthyOperand(emitter, function, instruction.operands[0], condition_label, instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = select i1 %condition.{d}, %lnako.Value ", .{ result, result });
        if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and")) {
            try constants_mod.writeValueRef(emitter, function, instruction.operands[1]);
            try emitter.output.writer.writeAll(", %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
        } else {
            try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
            try emitter.output.writer.writeAll(", %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, instruction.operands[1]);
        }
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (std.mem.eql(u8, instruction.operator, "&")) return writeConcat(emitter, instruction, scope);
    if (context.runtimeArithmeticOpcode(instruction.operator)) |opcode| {
        return writeArithmetic(emitter, function, instruction, scope, opcode);
    }
    if (shiftOpcode(instruction.operator)) |opcode| {
        return writeShift(emitter, instruction, scope, opcode);
    }
    if (context.comparisonOpcode(instruction.operator)) |opcode| {
        return writeComparison(emitter, instruction, scope, opcode);
    }
    return error.UnsupportedBinaryOperator;
}

pub fn writeArithmetic(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, opcode_value: u8) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
    const proven_number = emitter.optimized and valueType(function, instruction.operands[0]) == .number and valueType(function, instruction.operands[1]) == .number;
    if (!proven_number) {
        try emitter.output.writer.print("  call void @lnako_aot_arithmetic(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode_value });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    const left_label = try std.fmt.allocPrint(emitter.allocator, "left.number.{d}", .{result});
    defer emitter.allocator.free(left_label);
    const right_label = try std.fmt.allocPrint(emitter.allocator, "right.number.{d}", .{result});
    defer emitter.allocator.free(right_label);
    try constants_mod.writeNumberOperand(emitter, function, instruction.operands[0], left_label, instruction.span, scope);
    try constants_mod.writeNumberOperand(emitter, function, instruction.operands[1], right_label, instruction.span, scope);

    const opcode = arithmeticOpcode(instruction.operator) orelse return error.UnsupportedBinaryOperator;
    if (std.mem.eql(u8, opcode, "pow")) {
        try emitter.output.writer.print("  %binary.number.{d} = call double @llvm.pow.f64(double %left.number.{d}, double %right.number.{d})", .{ result, result, result });
    } else if (std.mem.eql(u8, opcode, "divfloor")) {
        try emitter.output.writer.print("  %binary.quotient.{d} = fdiv double %left.number.{d}, %right.number.{d}", .{ result, result, result });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %binary.number.{d} = call double @llvm.floor.f64(double %binary.quotient.{d})", .{ result, result });
    } else {
        try emitter.output.writer.print("  %binary.number.{d} = {s} double %left.number.{d}, %right.number.{d}", .{ result, opcode, result, result });
    }
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %binary.bits.{d} = bitcast double %binary.number.{d} to i64", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %binary.bits.{d}, 1", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeComparison(emitter: *Emitter, instruction: ir.Instruction, scope: usize, opcode: u8) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
    try emitter.output.writer.print("  call void @lnako_aot_compare(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeShift(emitter: *Emitter, instruction: ir.Instruction, scope: usize, opcode: u8) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
    try emitter.output.writer.print("  call void @lnako_aot_shift(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeConcat(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
    try emitter.output.writer.print("  call void @lnako_aot_concat(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d})", .{ result, instruction.operands[0], instruction.operands[1] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeIncrement(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 1) return error.InvalidIncrement;
    try emitter.output.writer.writeAll("  call void @lnako_aot_increment(ptr ");
    try variables_mod.writeRequiredNamedPointer(emitter, locals, instruction.name);
    try emitter.output.writer.print(", ptr %root.slot.{d})", .{instruction.operands[0]});
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeUnary(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 1) return error.InvalidUnaryInstruction;
    if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) {
        const truthy_label = try std.fmt.allocPrint(emitter.allocator, "truthy.{d}", .{result});
        defer emitter.allocator.free(truthy_label);
        try constants_mod.writeTruthyOperand(emitter, function, instruction.operands[0], truthy_label, instruction.span, scope);
        try emitter.output.writer.print("  %not.{d} = xor i1 %truthy.{d}, true", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %not.bits.{d} = zext i1 %not.{d} to i64", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %not.bits.{d}, 1", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    const unary_opcode: u8 = if (std.mem.eql(u8, instruction.operator, "-")) 0 else if (std.mem.eql(u8, instruction.operator, "+")) 1 else return error.UnsupportedUnaryOperator;
    const proven_number = emitter.optimized and valueType(function, instruction.operands[0]) == .number;
    if (!proven_number) {
        try emitter.output.writer.print("  call void @lnako_aot_unary(ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], unary_opcode });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    const number_label = try std.fmt.allocPrint(emitter.allocator, "unary.number.{d}", .{result});
    defer emitter.allocator.free(number_label);
    try constants_mod.writeNumberOperand(emitter, function, instruction.operands[0], number_label, instruction.span, scope);
    if (unary_opcode == 0) {
        try emitter.output.writer.print("  %unary.result.{d} = fneg double %unary.number.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %unary.bits.{d} = bitcast double %unary.result.{d} to i64", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %unary.bits.{d}, 1", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    // Unary plus is an identity operation for a proven Number. Copying the
    // aggregate preserves the exact payload, including negative zero.
    try emitter.output.writer.print("  %v{d} = select i1 true, %lnako.Value ", .{result});
    try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
    try emitter.output.writer.writeAll(", %lnako.Value ");
    try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
    try emitter.debugSuffix(instruction.span, scope);
}
