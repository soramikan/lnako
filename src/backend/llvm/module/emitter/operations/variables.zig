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

/// 変数束縛のポインタをemitする。local_targetは意味解析の束縛結果を
/// そのまま使い、ローカル解決ならローカルスロット、グローバル解決なら
/// グローバルスロットのみを対象にする（スロットの有無で推測しない）。
pub fn writeAssignmentContainerPointer(emitter: *Emitter, locals: []const []const u8, name: []const u8, local_target: bool) !void {
    if (local_target) {
        if (context.nameIndex(locals, name)) |index| return emitter.output.writer.print("%local.{d}", .{index});
        return error.UnknownAssignmentContainer;
    }
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

/// 増減文の分解命令（公式convIncの `typeof v === 'undefined'` 相当）。
/// 純粋なタグ比較なのでpendingチェックはemitしない。
pub fn writeIsUndefined(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidIncrement;
    try emitter.output.writer.print("  %isundef.i32.{d} = call i32 @lnako_aot_is_undefined(ptr %root.slot.{d})", .{ result, instruction.operands[0] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %isundef.i1.{d} = icmp ne i32 %isundef.i32.{d}, 0", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %isundef.bits.{d} = zext i1 %isundef.i1.{d} to i64", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %isundef.bits.{d}, 1", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

/// 増減文の分解命令（公式convIncの `v0 = 0` 相当）。
/// undefinedなら0、それ以外はそのまま返す。
pub fn writeCoalesceOrZero(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidIncrement;
    try emitter.output.writer.print("  call void @lnako_aot_coalesce_or_zero(ptr %root.slot.{d}, ptr %root.slot.{d})", .{ result, instruction.operands[0] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

/// 増減文の分解命令（公式convIncの `Number(v0) + Number(incValue)` 相当）。
/// 呼び出し側で読み出し・undefined初期化・量の評価を済ませてからemitする。
pub fn writeIncrementValues(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 2) return error.InvalidIncrement;
    try emitter.output.writer.print("  call void @lnako_aot_increment_values(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d})", .{ result, instruction.operands[0], instruction.operands[1] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}
