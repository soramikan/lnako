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
const DynamicCallTarget = context.DynamicCallTarget;
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

pub fn writeCall(emitter: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.direct_callee == null and instruction.is_builtin_call and isDisplayCall(instruction.name)) {
        return plugins_mod.writeDisplayCall(emitter, function, instruction, scope, aggregate_count);
    }
    if (instruction.direct_callee == null and instruction.is_builtin_call) if (aot_builtin.lookup(instruction.name)) |command| {
        if (command == .regexp_match or command == .regexp_extract or command == .regexp_replace or command == .regexp_split) {
            try plugins_mod.writeRegexpCall(emitter, function, instruction, scope, aggregate_count, command);
            try writeCallResult(emitter, result, instruction.span, scope);
            return;
        }
        try plugins_mod.writeBuiltinCall(emitter, function, instruction, scope, aggregate_count, command);
        try writeCallResult(emitter, result, instruction.span, scope);
        return;
    };
    const callee = if (instruction.direct_callee) |callee_id|
        if (callee_id < emitter.program.functions.len) emitter.program.functions[callee_id] else return error.InvalidDirectCallee
    else
        emitter.findFunction(instruction.name);
    if (callee == null) {
        if (isNativePluginCall(emitter.program, function, instruction)) {
            try plugins_mod.writeNativePluginCall(emitter, function, instruction, scope, aggregate_count);
        } else {
            try writeDynamicCall(emitter, function, locals, instruction, .{ .name = instruction.name }, instruction.operands, scope, aggregate_count);
        }
        try writeCallResult(emitter, result, instruction.span, scope);
        return;
    }
    try emitter.output.writer.print("  %v{d} = call %lnako.Value @lnako.fn.{d}(ptr null", .{ result, callee.?.id });
    for (instruction.operands) |operand| {
        try emitter.output.writer.writeAll(", %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, operand);
    }
    try emitter.output.writer.writeByte(')');
    try emitter.debugSuffix(instruction.span, scope);
    try writeCallResult(emitter, result, instruction.span, scope);
}

pub fn writeCallValue(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    if (instruction.operands.len == 0) return error.InvalidCall;
    try writeDynamicCall(emitter, function, &.{}, instruction, .{ .value = instruction.operands[0] }, instruction.operands[1..], scope, aggregate_count);
}

pub fn writeDynamicCall(
    emitter: *Emitter,
    function: ir.Function,
    locals: []const []const u8,
    instruction: ir.Instruction,
    target: DynamicCallTarget,
    arguments: []const ir.ValueId,
    scope: usize,
    aggregate_count: usize,
) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (arguments.len > aggregate_count) return error.InvalidCallScratch;
    for (arguments, 0..) |argument, index| {
        try emitter.output.writer.print("  %call.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, argument);
        try emitter.output.writer.print(", ptr %call.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  call void @lnako_aot_function_call(ptr %root.slot.{d}, ptr ", .{result});
    switch (target) {
        .name => |name| try variables_mod.writeRequiredNamedPointer(emitter, locals, name),
        .value => |value| try emitter.output.writer.print("%root.slot.{d}", .{value}),
    }
    try emitter.output.writer.writeAll(", ptr ");
    if (arguments.len > 0) {
        try emitter.output.writer.print("%call.{d}.slot.0", .{result});
    } else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.print(", i64 {d})", .{arguments.len});
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeMakeClosure(emitter: *Emitter, caller: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const function = lookupFunction(emitter.program, instruction.name) orelse return error.UnknownClosureFunction;
    if (function.captures.len > aggregate_count) return error.InvalidAggregateScratch;
    const value_root_count = context.functionValueCount(caller);
    for (function.captures, 0..) |capture, index| {
        const local_index = context.nameIndex(locals, capture) orelse return error.MissingClosureCapture;
        const cell_root = value_root_count + local_index;
        try emitter.output.writer.print("  %closure.capture.{d}.{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, index, cell_root });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %closure.capture.slot.{d}.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  store %lnako.Value %closure.capture.{d}.{d}, ptr %closure.capture.slot.{d}.{d}", .{ result, index, result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  call void @lnako_aot_function_new_named(ptr %root.slot.{d}, ptr @lnako.wrapper.{d}, i64 {d}, ptr @lnako.function.name.{d}, i64 {d}, ptr ", .{ result, function.id, function.parameters.len, function.id, function.name.len });
    if (function.captures.len > 0) {
        try emitter.output.writer.print("%closure.capture.slot.{d}.0", .{result});
    } else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.print(", i64 {d})", .{function.captures.len});
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeCallResult(emitter: *Emitter, result: ir.ValueId, span: ast.Span, scope: usize) !void {
    const global_index = emitter.globalIndex("それ") orelse return error.MissingResultGlobal;
    try emitter.output.writer.print("  %call.result.pending.{d} = call i32 @lnako_aot_exception_pending()", .{result});
    try emitter.debugSuffix(span, scope);
    try emitter.output.writer.print("  %call.result.is-pending.{d} = icmp ne i32 %call.result.pending.{d}, 0", .{ result, result });
    try emitter.debugSuffix(span, scope);
    try emitter.output.writer.print("  %call.result.previous.{d} = load %lnako.Value, ptr @lnako.global.{d}", .{ result, global_index });
    try emitter.debugSuffix(span, scope);
    try emitter.output.writer.print("  %call.result.selected.{d} = select i1 %call.result.is-pending.{d}, %lnako.Value %call.result.previous.{d}, %lnako.Value %v{d}", .{ result, result, result, result });
    try emitter.debugSuffix(span, scope);
    try emitter.output.writer.print("  store %lnako.Value %call.result.selected.{d}, ptr @lnako.global.{d}", .{ result, global_index });
    try emitter.debugSuffix(span, scope);
}
