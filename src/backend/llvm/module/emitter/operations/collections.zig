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

pub fn writeRootStore(emitter: *Emitter, instruction: ir.Instruction) !void {
    const result = instruction.result orelse return;
    try emitter.output.writer.print("  store %lnako.Value %v{d}, ptr %root.slot.{d}\n", .{ result, result });
}

pub fn writeDestructure(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 1) return error.InvalidDestructure;
    for (instruction.names, 0..) |name, index| {
        try emitter.output.writer.writeAll("  call void @lnako_aot_destructure_get(ptr ");
        // ターゲットのローカル・グローバルは束縛結果（names_local）で決める
        try variables_mod.writeAssignmentContainerPointer(emitter, locals, name, ir.destructureTargetIsLocal(instruction, index));
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

/// 解決済みコンテナへの要素代入。operands=[container, key, value]で、
/// ルート変数の束縛と中間レベルの走査はlowering側でload/array_getとして
/// 先行emitされる（公式convLet/convLetArrayの最終代入部相当）。
/// 例外は呼び出し側のexception_pendingで拾う。
pub fn writeElementSet(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 3) return error.InvalidIndexAssignment;
    try emitter.output.writer.print("  call i32 @lnako_aot_index_set(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d})", .{ instruction.operands[0], instruction.operands[1], instruction.operands[2] });
    try emitter.debugSuffix(instruction.span, scope);
}

/// DNCL自動初期化: 変数スロットが配列でなければ30要素の0配列を代入する
/// （公式convLetArrayのcheckInit相当）。システム定数名は公式同様リテラル
/// 相当に留めるためemit自体を省略するが、ローカル束縛へ解決される同名は
/// 公式同様に初期化対象とする。
pub fn writeEnsureArrayVar(emitter: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
    if (!instruction.local_target and system_constant.isConstant(instruction.name)) return;
    try emitter.output.writer.writeAll("  call void @lnako_aot_ensure_array_var(ptr ");
    try variables_mod.writeAssignmentContainerPointer(emitter, locals, instruction.name, instruction.local_target);
    try emitter.output.writer.writeAll(")");
    try emitter.debugSuffix(instruction.span, scope);
}

/// DNCL自動初期化のcheck式で使う instanceof Array 相当の判定。
/// 例外を発生させない純粋なタグ比較なのでpendingチェックはemitしない。
pub fn writeIsArray(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidIndexReference;
    try emitter.output.writer.print("  %isarray.i32.{d} = call i32 @lnako_aot_is_array(ptr %root.slot.{d})", .{ result, instruction.operands[0] });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %isarray.i1.{d} = icmp ne i32 %isarray.i32.{d}, 0", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %isarray.bits.{d} = zext i1 %isarray.i1.{d} to i64", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %isarray.bits.{d}, 1", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

/// DNCL自動初期化のwrite-back式。container[key]へ無条件に30要素の0配列を
/// 書き込む（公式の `tmp[..] = arrayDefCode` 相当）。
/// 例外は呼び出し側のexception_pendingで拾う。
pub fn writeInitArrayIndex(emitter: *Emitter, instruction: ir.Instruction, scope: usize) !void {
    if (instruction.operands.len != 2) return error.InvalidIndexAssignment;
    try emitter.output.writer.print("  call void @lnako_aot_init_array_index(ptr %root.slot.{d}, ptr %root.slot.{d})", .{ instruction.operands[0], instruction.operands[1] });
    try emitter.debugSuffix(instruction.span, scope);
}
