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

pub fn writeAssignmentContainerPointer(emitter: *Emitter, locals: []const []const u8, name: []const u8, literal: bool) !void {
    if (literal) return emitter.output.writer.writeAll("%runtime.scratch");
    if (context.nameIndex(locals, name)) |index| return emitter.output.writer.print("%local.{d}", .{index});
    if (emitter.globalIndex(name)) |index| return emitter.output.writer.print("@lnako.global.{d}", .{index});
    return error.UnknownAssignmentContainer;
}

pub fn writeOptionalNamedPointer(emitter: *Emitter, locals: []const []const u8, name: []const u8) !void {
    if (name.len == 0) return emitter.output.writer.writeAll("null");
    if (context.nameIndex(locals, name)) |index| return emitter.output.writer.print("%local.{d}", .{index});
    if (emitter.globalIndex(name)) |index| return emitter.output.writer.print("@lnako.global.{d}", .{index});
    return emitter.output.writer.writeAll("null");
}

pub fn writeRequiredNamedPointer(emitter: *Emitter, locals: []const []const u8, name: []const u8) !void {
    if (context.nameIndex(locals, name)) |index| return emitter.output.writer.print("%local.{d}", .{index});
    if (emitter.globalIndex(name)) |index| return emitter.output.writer.print("@lnako.global.{d}", .{index});
    return error.UnknownAssignmentTarget;
}

pub fn writeIncrement(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 1) return error.InvalidIncrement;
    try emitter.output.writer.writeAll("  call void @lnako_aot_increment(ptr ");
    try writeRequiredNamedPointer(emitter, locals, instruction.name);
    try emitter.output.writer.print(", ptr %root.slot.{d})", .{instruction.operands[0]});
    try emitter.debugSuffix(instruction.span, scope);
}
