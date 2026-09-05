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

pub fn writeIteratorBegin(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len == 0 or instruction.operands.len > aggregate_count) return error.InvalidIterator;
    for (instruction.operands, 0..) |operand, index| {
        try emitter.output.writer.print("  %iterator.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, operand);
        try emitter.output.writer.print(", ptr %iterator.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    const is_range = instruction.name.len > 0 and instruction.operands.len >= 2;
    const direction: u8 = switch (instruction.loop_direction) {
        .automatic => 0,
        .up => 1,
        .down => 2,
    };
    try emitter.output.writer.print("  call void @lnako_aot_iterator_new(ptr %root.slot.{d}, ptr %iterator.{d}.slot.0, i64 {d}, i1 {s}, i8 {d})", .{ result, result, instruction.operands.len, if (is_range) "true" else "false", direction });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeIteratorHasNext(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidIterator;
    try emitter.output.writer.print("  %iterator.has.{d} = call i32 @lnako_aot_iterator_has_next(ptr %root.slot.{d})", .{ result, instruction.operands[0] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %iterator.bool.{d} = icmp ne i32 %iterator.has.{d}, 0", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %iterator.bits.{d} = zext i1 %iterator.bool.{d} to i64", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %iterator.bits.{d}, 1", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeIteratorNext(emitter: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidIterator;
    const begin = context.instructionForValue(function, instruction.operands[0]) orelse return error.InvalidIterator;
    if (begin.opcode != .iterator_begin) return error.InvalidIterator;
    try emitter.output.writer.print("  call void @lnako_aot_iterator_next(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr ", .{ result, instruction.operands[0] });
    try variables_mod.writeOptionalNamedPointer(emitter, locals, "回数");
    try emitter.output.writer.writeAll(", ptr ");
    try variables_mod.writeOptionalNamedPointer(emitter, locals, "対象");
    try emitter.output.writer.writeAll(", ptr ");
    try variables_mod.writeOptionalNamedPointer(emitter, locals, "対象キー");
    try emitter.output.writer.writeAll(", ptr ");
    try variables_mod.writeOptionalNamedPointer(emitter, locals, begin.name);
    try emitter.output.writer.writeByte(')');
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}
