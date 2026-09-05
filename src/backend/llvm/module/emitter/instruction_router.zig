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

pub fn writeInstruction(emitter: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result;
    switch (instruction.opcode) {
        .const_number => {
            const id = result orelse return error.MissingInstructionResult;
            try emitter.output.writer.print("  %number.bits.{d} = bitcast double 0x{X:0>16} to i64", .{ id, @as(u64, @bitCast(instruction.number_value orelse 0)) });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %number.bits.{d}, 1", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .const_boolean => {
            if (instruction.literal_site_id) |site_id| try emitter.output.writer.print("  call void @lnako_aot_literal_site(i64 {d})\n", .{site_id});
            try constants_mod.writeBoxConstant(emitter, result orelse return error.MissingInstructionResult, 2, @intFromBool(instruction.boolean_value), instruction.span, scope);
        },
        .const_null => {
            if (instruction.literal_site_id) |site_id| try emitter.output.writer.print("  call void @lnako_aot_literal_site(i64 {d})\n", .{site_id});
            try constants_mod.writeBoxConstant(emitter, result orelse return error.MissingInstructionResult, 1, 0, instruction.span, scope);
        },
        .const_undefined => try constants_mod.writeBoxConstant(emitter, result orelse return error.MissingInstructionResult, 0, 0, instruction.span, scope),
        .const_bigint => {
            const id = result orelse return error.MissingInstructionResult;
            const constant = emitter.bigintConstant(function.id, id) orelse return error.InvalidBigIntConstant;
            try emitter.output.writer.print("  call void @lnako_aot_bigint_new(ptr %root.slot.{d}, ptr @lnako.bigint.{d}, i64 {d})", .{ id, constant.index, constant.text.len });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .const_string => {
            const id = result orelse return error.MissingInstructionResult;
            const constant = emitter.stringConstant(function.id, id) orelse return error.InvalidStringConstant;
            try emitter.output.writer.print("  call void @lnako_aot_string_new(ptr %root.slot.{d}, ptr @lnako.string.{d}, i64 {d})", .{ id, constant.index, constant.units.len });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .load_global => {
            const index = emitter.globalIndex(instruction.name) orelse return error.UnknownGlobal;
            if (instruction.global_site_id) |site_id| {
                try emitter.output.writer.print("  call void @lnako_aot_global_read_site(i64 {d})", .{site_id});
                try emitter.debugSuffix(instruction.span, scope);
            }
            try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr @lnako.global.{d}", .{ result orelse return error.MissingInstructionResult, index });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .store_global => {
            const index = emitter.globalIndex(instruction.name) orelse return error.UnknownGlobal;
            const site_id = instruction.global_site_id orelse return error.MissingGlobalSiteId;
            try emitter.output.writer.print("  call void @lnako_aot_global_write_site(i64 {d})", .{site_id});
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  store %lnako.Value ", .{});
            try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
            try emitter.output.writer.print(", ptr @lnako.global.{d}", .{index});
            try emitter.debugSuffix(instruction.span, scope);
        },
        .load_local => {
            const index = context.nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
            try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %local.{d}", .{ result orelse return error.MissingInstructionResult, index });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .store_local => {
            const index = context.nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, instruction.operands[0]);
            try emitter.output.writer.print(", ptr %local.{d}", .{index});
            try emitter.debugSuffix(instruction.span, scope);
        },
        .destructure_store => try collections_mod.writeDestructure(emitter, locals, instruction, scope),
        .binary => try arithmetic_mod.writeBinary(emitter, function, instruction, scope),
        .unary => try arithmetic_mod.writeUnary(emitter, function, instruction, scope),
        .call => try calls_mod.writeCall(emitter, function, locals, instruction, scope, aggregate_count),
        .call_value => try calls_mod.writeCallValue(emitter, function, instruction, scope, aggregate_count),
        .make_closure => try calls_mod.writeMakeClosure(emitter, function, locals, instruction, scope, aggregate_count),
        .make_array => try collections_mod.writeAggregate(emitter, function, instruction, scope, aggregate_count, "lnako_aot_array_new"),
        .make_object => try collections_mod.writeAggregate(emitter, function, instruction, scope, aggregate_count, "lnako_aot_dictionary_new"),
        .array_get, .property_get => try collections_mod.writeIndexGet(emitter, instruction, scope),
        .array_set, .property_set => try collections_mod.writeIndexSet(emitter, locals, instruction, scope),
        .increment => try variables_mod.writeIncrement(emitter, locals, instruction, scope),
        .iterator_begin => try control_mod.writeIteratorBegin(emitter, function, instruction, scope, aggregate_count),
        .iterator_has_next => try control_mod.writeIteratorHasNext(emitter, instruction, scope),
        .iterator_next => try control_mod.writeIteratorNext(emitter, function, locals, instruction, scope),
        .try_begin, .try_end => {},
        .exception_pending => {
            const id = result orelse return error.MissingInstructionResult;
            try emitter.output.writer.print("  %exception.pending.i32.{d} = call i32 @lnako_aot_exception_pending()", .{id});
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %exception.pending.i1.{d} = icmp ne i32 %exception.pending.i32.{d}, 0", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %exception.pending.bits.{d} = zext i1 %exception.pending.i1.{d} to i64", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %exception.pending.bits.{d}, 1", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .exception_take => {
            const error_index = emitter.globalIndex("エラーメッセージ") orelse return error.MissingErrorMessageGlobal;
            try emitter.output.writer.print("  call void @lnako_aot_exception_take(ptr @lnako.global.{d})", .{error_index});
            try emitter.debugSuffix(instruction.span, scope);
        },
        .phi => {
            try emitter.output.writer.print("  %v{d} = phi %lnako.Value ", .{result orelse return error.MissingInstructionResult});
            for (instruction.phi_incoming, 0..) |incoming, index| {
                if (index > 0) try emitter.output.writer.writeAll(", ");
                try emitter.output.writer.writeAll("[ ");
                try constants_mod.writeValueRef(emitter, function, incoming.value);
                try emitter.output.writer.print(", %bb{d} ]", .{incoming.predecessor});
            }
            try emitter.debugSuffix(instruction.span, scope);
        },
        .speed_mode_begin, .speed_mode_end, .performance_monitor_begin, .performance_monitor_end => {},
        else => return error.UnsupportedInstruction,
    }
}
