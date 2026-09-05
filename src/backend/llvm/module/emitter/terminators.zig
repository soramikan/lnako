const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../../../ir/nako_ir.zig");
const ast = @import("../../../../frontend/ast.zig");
const aot_abi = @import("../../../../runtime/aot_abi.zig");
const aot_builtin = @import("../../../../runtime/aot_builtin.zig");
const system_constant = @import("../../../../runtime/system_constant.zig");
const shared = @import("../shared.zig");
const context = @import("context.zig");
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
const constants_mod = @import("operations/constants.zig");
const collections_mod = @import("operations/collections.zig");
const variables_mod = @import("operations/variables.zig");
const control_mod = @import("operations/control.zig");
const arithmetic_mod = @import("operations/arithmetic.zig");
const calls_mod = @import("operations/calls.zig");
const plugins_mod = @import("operations/plugins.zig");
const instruction_router_mod = @import("instruction_router.zig");
const terminators_mod = @import("terminators.zig");
const functions_mod = @import("functions.zig");
const preamble_mod = @import("preamble.zig");
const declarations_mod = @import("declarations.zig");

pub fn writeTerminator(emitter: *Emitter, function: ir.Function, terminator: ir.Terminator, span: ast.Span, scope: usize) !void {
    switch (terminator) {
        .branch => |target| {
            try emitter.output.writer.print("  br label %bb{d}", .{target});
            try emitter.debugSuffix(span, scope);
        },
        .conditional_branch => |branch| {
            const condition_label = try std.fmt.allocPrint(emitter.allocator, "branch.condition.v{d}", .{branch.condition});
            defer emitter.allocator.free(condition_label);
            try constants_mod.writeTruthyOperand(emitter, function, branch.condition, condition_label, span, scope);
            try emitter.output.writer.print("  br i1 %branch.condition.v{d}, label %bb{d}, label %bb{d}", .{ branch.condition, branch.then_block, branch.else_block });
            try emitter.debugSuffix(span, scope);
        },
        .return_value => |value| {
            try emitter.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
            try emitter.output.writer.writeAll("  ret %lnako.Value ");
            if (value) |operand| try constants_mod.writeValueRef(emitter, function, operand) else try emitter.output.writer.writeAll("{ i8 0, i64 0 }");
            try emitter.debugSuffix(span, scope);
        },
        .throw_value => |throw_value| {
            if (throw_value.site_id) |site_id| {
                try emitter.output.writer.print("  call void @lnako_aot_throw_site(i64 {d})", .{site_id});
                try emitter.debugSuffix(throw_value.span, scope);
            }
            const exception_set = if (throw_value.coerce_to_error_message) "lnako_aot_exception_set_error_message" else "lnako_aot_exception_set";
            try emitter.output.writer.print("  call void @{s}(ptr %root.slot.{d})", .{ exception_set, throw_value.value });
            try emitter.debugSuffix(span, scope);
            if (throw_value.target) |target| {
                try emitter.output.writer.print("  br label %bb{d}", .{target});
                try emitter.debugSuffix(span, scope);
            } else {
                try emitter.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
                try emitter.output.writer.writeAll("  ret %lnako.Value { i8 0, i64 0 }");
                try emitter.debugSuffix(span, scope);
            }
        },
        .propagate_exception => {
            try emitter.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
            try emitter.output.writer.writeAll("  ret %lnako.Value { i8 0, i64 0 }");
            try emitter.debugSuffix(span, scope);
        },
        .unreachable_terminator => {
            try emitter.output.writer.writeAll("  unreachable");
            try emitter.debugSuffix(span, scope);
        },
        else => return error.UnsupportedTerminator,
    }
}
