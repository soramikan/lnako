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

pub fn writeBoxConstant(emitter: *Emitter, id: ir.ValueId, tag: u8, payload: u64, span: ast.Span, scope: usize) !void {
    try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 {d}, i64 0 }}, i64 {d}, 1", .{ id, tag, payload });
    try emitter.debugSuffix(span, scope);
}

pub fn writeValueRef(emitter: *Emitter, function: ir.Function, value: ir.ValueId) !void {
    for (function.parameters, 0..) |parameter, index| if (parameter.value == value) {
        try emitter.output.writer.print("%arg.{d}", .{index});
        return;
    };
    try emitter.output.writer.print("%v{d}", .{value});
}

pub fn writeNumberOperand(emitter: *Emitter, function: ir.Function, value: ir.ValueId, label: []const u8, span: ast.Span, scope: usize) !void {
    if (emitter.optimized and valueType(function, value) == .number) {
        try emitter.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
        try writeValueRef(emitter, function, value);
        try emitter.output.writer.writeAll(", 1");
        try emitter.debugSuffix(span, scope);
        try emitter.output.writer.print("  %{s} = bitcast i64 %{s}.bits to double", .{ label, label });
        try emitter.debugSuffix(span, scope);
        return;
    }
    try emitter.output.writer.print("  %{s} = call double @lnako.to_number(%lnako.Value ", .{label});
    try writeValueRef(emitter, function, value);
    try emitter.output.writer.writeByte(')');
    try emitter.debugSuffix(span, scope);
}

pub fn writeTruthyOperand(emitter: *Emitter, function: ir.Function, value: ir.ValueId, label: []const u8, span: ast.Span, scope: usize) !void {
    const value_type = valueType(function, value);
    if (emitter.optimized and value_type == .boolean) {
        try emitter.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
        try writeValueRef(emitter, function, value);
        try emitter.output.writer.writeAll(", 1");
        try emitter.debugSuffix(span, scope);
        try emitter.output.writer.print("  %{s} = trunc i64 %{s}.bits to i1", .{ label, label });
        try emitter.debugSuffix(span, scope);
        return;
    }
    if (emitter.optimized and value_type == .number) {
        try emitter.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
        try writeValueRef(emitter, function, value);
        try emitter.output.writer.writeAll(", 1");
        try emitter.debugSuffix(span, scope);
        try emitter.output.writer.print("  %{s}.number = bitcast i64 %{s}.bits to double", .{ label, label });
        try emitter.debugSuffix(span, scope);
        try emitter.output.writer.print("  %{s} = fcmp one double %{s}.number, 0.000000e+00", .{ label, label });
        try emitter.debugSuffix(span, scope);
        return;
    }
    try emitter.output.writer.print("  %{s} = call i1 @lnako.truthy(%lnako.Value ", .{label});
    try writeValueRef(emitter, function, value);
    try emitter.output.writer.writeByte(')');
    try emitter.debugSuffix(span, scope);
}
