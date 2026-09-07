const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../../../ir/nako_ir.zig");
const local_storage = @import("../../../../ir/local_storage.zig");
const typed_abi = @import("typed_abi.zig");
const root_liveness = @import("../../../../ir/root_liveness.zig");
const roots_mod = @import("roots.zig");
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

pub fn writeFunction(emitter: *Emitter, function: ir.Function) !void {
    const scope = 4 + function.id;
    try emitter.output.writer.print("define internal %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print(", %lnako.Value %arg.{d}", .{index});
    }
    try emitter.output.writer.print(") !dbg !{d} {{\n", .{scope});
    const locals = try emitter.localNames(function);
    defer emitter.allocator.free(locals);
    var root_plan = if (emitter.optimized) try root_liveness.analyze(emitter.allocator, function) else null;
    defer if (root_plan) |*plan| plan.deinit();
    const value_root_count = context.functionValueCount(function);
    const root_count = value_root_count + locals.len;
    const root_storage_count = @max(@as(usize, 1), root_count);
    const aggregate_count = @max(context.maxAggregateOperandCount(function), context.maxClosureCaptureCount(emitter.program, function));
    for (function.blocks, 0..) |block, block_index| {
        try emitter.output.writer.print("bb{d}:\n", .{block.id});
        if (block.id == function.entry) {
            if (root_plan) |plan| {
                try roots_mod.writeStorage(emitter, plan, locals.len);
            } else {
                try emitter.output.writer.print("  %root.values = alloca [{d} x %lnako.Value]\n", .{root_storage_count});
                try emitter.output.writer.writeAll("  %root.frame = alloca %lnako.RootFrame\n");
                for (0..root_count) |index| {
                    try emitter.output.writer.print("  %root.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %root.values, i64 0, i64 {d}\n", .{ index, root_storage_count, index });
                    try emitter.output.writer.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %root.slot.{d}\n", .{index});
                }
                if (root_count > 0) {
                    try emitter.output.writer.print("  call void @lnako_aot_push_roots(ptr %root.frame, ptr %root.slot.0, i64 {d})\n", .{root_count});
                } else try emitter.output.writer.writeAll("  call void @lnako_aot_push_roots(ptr %root.frame, ptr null, i64 0)\n");
            }
            try emitter.output.writer.writeAll("  %runtime.scratch = alloca %lnako.Value\n");
            try emitter.output.writer.writeAll("  store %lnako.Value { i8 0, i64 0 }, ptr %runtime.scratch\n");
            if (aggregate_count > 0) try emitter.output.writer.print("  %aggregate.values = alloca [{d} x %lnako.Value]\n", .{aggregate_count});
            for (function.parameters, 0..) |parameter, index| {
                try emitter.output.writer.print("  store %lnako.Value %arg.{d}, ptr %root.slot.{d}\n", .{ index, parameter.value });
            }
            for (locals, 0..) |name, index| {
                const cell_root = value_root_count + index;
                switch (local_storage.storageClass(emitter.program, function, name)) {
                    .cell => {
                        if (context.nameIndex(function.captures, name)) |capture_index| {
                            try emitter.output.writer.print("  call void @lnako_aot_function_capture(ptr %root.slot.{d}, ptr %context, i64 {d})\n", .{ cell_root, capture_index });
                        } else {
                            try emitter.output.writer.print("  call void @lnako_aot_binding_cell_new(ptr %root.slot.{d}, ptr ", .{cell_root});
                            if (context.parameterIndex(function, name)) |parameter_index| {
                                try emitter.output.writer.print("%root.slot.{d}", .{function.parameters[parameter_index].value});
                            } else try emitter.output.writer.writeAll("null");
                            try emitter.output.writer.writeAll(")\n");
                        }
                        try emitter.output.writer.print("  %local.{d} = call ptr @lnako_aot_binding_cell_value(ptr %root.slot.{d})\n", .{ index, cell_root });
                    },
                    .value => {
                        // The local root slot is already part of the active
                        // root frame.  Point operations directly at that
                        // Value instead of allocating a GC BindingCell.
                        if (context.parameterIndex(function, name)) |parameter_index| {
                            try emitter.output.writer.print("  store %lnako.Value %arg.{d}, ptr %root.slot.{d}\n", .{ parameter_index, cell_root });
                        }
                        try emitter.output.writer.print("  %local.{d} = getelementptr %lnako.Value, ptr %root.slot.{d}, i64 0\n", .{ index, cell_root });
                    },
                }
            }
        }
        var phi_count: usize = 0;
        while (phi_count < block.instructions.len and block.instructions[phi_count].opcode == .phi) : (phi_count += 1) {
            try instruction_router_mod.writeInstruction(emitter, function, locals, block.instructions[phi_count], scope, aggregate_count);
        }
        for (block.instructions[0..phi_count]) |instruction| try collections_mod.writeRootStore(emitter, instruction);
        for (block.instructions[phi_count..], phi_count..) |instruction, instruction_index| {
            if (root_plan) |plan| if (plan.precise and root_liveness.mayCollect(instruction)) {
                try roots_mod.writeSafepoint(emitter, plan, plan.blocks[block_index].before[instruction_index]);
            };
            try instruction_router_mod.writeInstruction(emitter, function, locals, instruction, scope, aggregate_count);
            try collections_mod.writeRootStore(emitter, instruction);
        }
        if (root_plan) |plan| if (plan.precise and block.terminator == .throw_value) {
            try roots_mod.writeSafepoint(emitter, plan, plan.blocks[block_index].before[block.instructions.len]);
        };
        const terminator_span = if (block.instructions.len > 0) block.instructions[block.instructions.len - 1].span else ast.emptySpan();
        try terminators_mod.writeTerminator(emitter, function, block.terminator, terminator_span, scope);
    }
    try emitter.output.writer.writeAll("}\n\n");
    if (emitter.optimized) {
        const typed_analysis = try emitter.typedAnalysis();
        if (typed_analysis.scalar(function.id)) |scalar| try writeTypedFunction(emitter, function, scalar, typed_analysis);
    }
}

fn writeTypedFunction(emitter: *Emitter, function: ir.Function, scalar: typed_abi.Scalar, typed_analysis: *typed_abi.ProgramAnalysis) !void {
    // Generic and scalar variants have distinct DISubprogram metadata. LLVM
    // rejects attaching one DISubprogram to both definitions.
    const scope = 5 + emitter.program.functions.len + function.id;
    const locals = try emitter.localNames(function);
    defer emitter.allocator.free(locals);
    try emitter.output.writer.print("define internal {s} ", .{scalar.llvmType()});
    try typed_abi.writeName(&emitter.output.writer, scalar, function.id);
    try emitter.output.writer.print("(ptr %context", .{});
    for (function.parameters, 0..) |_, index| {
        const parameter_scalar = typed_abi.scalarType(typed_analysis.parameterType(function.id, index)) orelse return error.InvalidTypedCall;
        try emitter.output.writer.print(", {s} %typed.arg.{d}", .{ parameter_scalar.llvmType(), index });
    }
    try emitter.output.writer.print(") !dbg !{d} {{\n", .{scope});

    for (function.blocks) |block| {
        try emitter.output.writer.print("typed.bb.{d}.{d}:\n", .{ function.id, block.id });
        if (block.id == function.entry) {
            for (locals, 0..) |name, index| {
                const local_scalar = typed_analysis.localScalar(function, name) orelse return error.InvalidTypedLocal;
                try emitter.output.writer.print("  %typed.local.{d} = alloca {s}\n", .{ index, local_scalar.llvmType() });
            }
            for (function.parameters, 0..) |parameter, parameter_index| {
                const local_index = context.nameIndex(locals, parameter.name) orelse return error.InvalidTypedLocal;
                const parameter_scalar = typed_abi.scalarType(typed_analysis.parameterType(function.id, parameter_index)) orelse return error.InvalidTypedCall;
                try emitter.output.writer.print("  store {s} %typed.arg.{d}, ptr %typed.local.{d}\n", .{ parameter_scalar.llvmType(), parameter_index, local_index });
            }
        }
        for (block.instructions) |instruction| try writeTypedInstruction(emitter, function, locals, instruction, scope, typed_analysis);
        try terminators_mod.writeTypedTerminator(emitter, function, block.terminator, scalar, block.id, ast.emptySpan(), scope, typed_analysis);
    }
    try emitter.output.writer.writeAll("}\n\n");
}

fn writeTypedInstruction(emitter: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, typed_analysis: *typed_abi.ProgramAnalysis) !void {
    const result = instruction.result;
    switch (instruction.opcode) {
        .const_number => {
            const id = result orelse return error.MissingInstructionResult;
            try emitter.output.writer.print("  %typed.number.bits.{d} = bitcast double 0x{X:0>16} to i64", .{ id, @as(u64, @bitCast(instruction.number_value orelse 0)) });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %typed.v{d} = bitcast i64 %typed.number.bits.{d} to double", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .const_boolean => {
            const id = result orelse return error.MissingInstructionResult;
            try emitter.output.writer.print("  %typed.v{d} = select i1 true, i1 {s}, i1 false", .{ id, if (instruction.boolean_value) "true" else "false" });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .load_local => {
            const id = result orelse return error.MissingInstructionResult;
            const local_index = context.nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
            const local_scalar = typed_abi.scalarType(typed_analysis.valueType(function.id, id)) orelse return error.InvalidTypedLocal;
            try emitter.output.writer.print("  %typed.v{d} = load {s}, ptr %typed.local.{d}", .{ id, local_scalar.llvmType(), local_index });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .store_local => {
            if (instruction.operands.len != 1) return error.InvalidTypedInstruction;
            const local_index = context.nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
            const local_scalar = typed_analysis.localScalar(function, instruction.name) orelse return error.InvalidTypedLocal;
            try emitter.output.writer.writeAll("  store ");
            try emitter.output.writer.writeAll(local_scalar.llvmType());
            try emitter.output.writer.writeByte(' ');
            try context.writeTypedValueRef(&emitter.output.writer, function, instruction.operands[0]);
            try emitter.output.writer.print(", ptr %typed.local.{d}", .{local_index});
            try emitter.debugSuffix(instruction.span, scope);
        },
        .binary => try writeTypedBinary(emitter, function, instruction, scope, typed_analysis),
        .unary => try writeTypedUnary(emitter, function, instruction, scope, typed_analysis),
        .call => {
            if (instruction.is_builtin_call) {
                try writeTypedBuiltinCall(emitter, function, instruction, scope, typed_analysis);
            } else {
                const callee_id = instruction.direct_callee orelse return error.UnsupportedTypedInstruction;
                if (callee_id >= emitter.program.functions.len) return error.InvalidTypedCall;
                const callee = emitter.program.functions[callee_id];
                const scalar = typed_analysis.scalar(callee_id) orelse return error.InvalidTypedCall;
                try calls_mod.writeTypedBodyCall(emitter, function, callee, scalar, instruction, scope);
            }
        },
        .exception_pending => {
            const id = result orelse return error.MissingInstructionResult;
            try emitter.output.writer.print("  %typed.pending.i32.{d} = call i32 @lnako_aot_exception_pending()", .{id});
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %typed.v{d} = icmp ne i32 %typed.pending.i32.{d}, 0", .{ id, id });
            try emitter.debugSuffix(instruction.span, scope);
        },
        .phi => {
            const id = result orelse return error.MissingInstructionResult;
            const result_scalar = typed_abi.scalarType(typed_analysis.valueType(function.id, id)) orelse return error.InvalidTypedInstruction;
            try emitter.output.writer.print("  %typed.v{d} = phi {s} ", .{ id, result_scalar.llvmType() });
            for (instruction.phi_incoming, 0..) |incoming, index| {
                if (index > 0) try emitter.output.writer.writeAll(", ");
                try emitter.output.writer.writeAll("[ ");
                try context.writeTypedValueRef(&emitter.output.writer, function, incoming.value);
                try emitter.output.writer.print(", %typed.bb.{d}.{d} ]", .{ function.id, incoming.predecessor });
            }
            try emitter.debugSuffix(instruction.span, scope);
        },
        .try_begin, .try_end => {},
        else => return error.UnsupportedTypedInstruction,
    }
}

fn writeTypedBuiltinCall(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, typed_analysis: *typed_abi.ProgramAnalysis) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const command = typed_abi.scalarBuiltinCommand(instruction) orelse return error.UnsupportedTypedInstruction;
    if (typed_abi.scalarType(typed_analysis.valueType(function.id, instruction.operands[0])) != .number or
        typed_abi.scalarType(typed_analysis.valueType(function.id, result)) != .number) return error.InvalidTypedInstruction;
    const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
    const operand = try typedValueText(emitter, function, instruction.operands[0]);
    defer emitter.allocator.free(operand);
    try emitter.output.writer.print("  %typed.builtin.out.{d} = alloca %lnako.Value", .{result});
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  call void @lnako_aot_math_unary_f64_call_site(ptr %typed.builtin.out.{d}, double {s}, i16 {d}, i64 {d})", .{ result, operand, @intFromEnum(command), site_id });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.builtin.value.{d} = load %lnako.Value, ptr %typed.builtin.out.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    // Keep the ordinary call contract for `それ`: a failed builtin leaves the
    // previous value visible while the following exception_pending instruction
    // decides whether the typed body propagates the failure.
    const global_index = emitter.globalIndex("それ") orelse return error.MissingResultGlobal;
    try emitter.output.writer.print("  %typed.builtin.pending.{d} = call i32 @lnako_aot_exception_pending()", .{result});
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.builtin.is-pending.{d} = icmp ne i32 %typed.builtin.pending.{d}, 0", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.builtin.previous.{d} = load %lnako.Value, ptr @lnako.global.{d}", .{ result, global_index });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.builtin.selected.{d} = select i1 %typed.builtin.is-pending.{d}, %lnako.Value %typed.builtin.previous.{d}, %lnako.Value %typed.builtin.value.{d}", .{ result, result, result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  store %lnako.Value %typed.builtin.selected.{d}, ptr @lnako.global.{d}", .{ result, global_index });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.builtin.bits.{d} = extractvalue %lnako.Value %typed.builtin.value.{d}, 1", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %typed.v{d} = bitcast i64 %typed.builtin.bits.{d} to double", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

fn writeTypedBinary(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, typed_analysis: *typed_abi.ProgramAnalysis) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len < 2) return error.InvalidTypedInstruction;
    const left_type = typed_abi.scalarType(typed_analysis.valueType(function.id, instruction.operands[0])) orelse return error.InvalidTypedInstruction;
    const right_type = typed_abi.scalarType(typed_analysis.valueType(function.id, instruction.operands[1])) orelse return error.InvalidTypedInstruction;
    const result_type = typed_abi.scalarType(typed_analysis.valueType(function.id, result)) orelse return error.InvalidTypedInstruction;
    if (isNumberArithmetic(instruction.operator)) {
        if (left_type != .number or right_type != .number or result_type != .number) return error.InvalidTypedInstruction;
        const left = try typedValueText(emitter, function, instruction.operands[0]);
        defer emitter.allocator.free(left);
        const right = try typedValueText(emitter, function, instruction.operands[1]);
        defer emitter.allocator.free(right);
        const opcode = arithmeticOpcode(instruction.operator) orelse return error.UnsupportedBinaryOperator;
        if (std.mem.eql(u8, opcode, "pow")) {
            try emitter.output.writer.print("  %typed.v{d} = call double @llvm.pow.f64(double {s}, double {s})", .{ result, left, right });
        } else if (std.mem.eql(u8, opcode, "divfloor")) {
            try emitter.output.writer.print("  %typed.divfloor.{d} = fdiv double {s}, {s}", .{ result, left, right });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.print("  %typed.v{d} = call double @llvm.floor.f64(double %typed.divfloor.{d})", .{ result, result });
        } else try emitter.output.writer.print("  %typed.v{d} = {s} double {s}, {s}", .{ result, opcode, left, right });
        if (!std.mem.eql(u8, opcode, "divfloor")) try emitter.debugSuffix(instruction.span, scope);
        if (std.mem.eql(u8, opcode, "divfloor")) try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (isComparison(instruction.operator)) {
        if (left_type != right_type or result_type != .boolean) return error.InvalidTypedInstruction;
        const left = try typedValueText(emitter, function, instruction.operands[0]);
        defer emitter.allocator.free(left);
        const right = try typedValueText(emitter, function, instruction.operands[1]);
        defer emitter.allocator.free(right);
        const predicate = if (left_type == .number) numberPredicate(instruction.operator) else booleanPredicate(instruction.operator);
        try emitter.output.writer.print("  %typed.v{d} = {s} {s} {s} {s}, {s}", .{ result, if (left_type == .number) "fcmp" else "icmp", predicate orelse return error.UnsupportedComparisonOperator, if (left_type == .number) "double" else "i1", left, right });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (isLogical(instruction.operator)) {
        if (left_type != .boolean or right_type != .boolean or result_type != .boolean) return error.InvalidTypedInstruction;
        const left = try typedValueText(emitter, function, instruction.operands[0]);
        defer emitter.allocator.free(left);
        const right = try typedValueText(emitter, function, instruction.operands[1]);
        defer emitter.allocator.free(right);
        try emitter.output.writer.print("  %typed.v{d} = {s} i1 {s}, {s}", .{ result, if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and")) "and" else "or", left, right });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    return error.UnsupportedBinaryOperator;
}

fn writeTypedUnary(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, typed_analysis: *typed_abi.ProgramAnalysis) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    if (instruction.operands.len != 1) return error.InvalidTypedInstruction;
    const operand_type = typed_abi.scalarType(typed_analysis.valueType(function.id, instruction.operands[0])) orelse return error.InvalidTypedInstruction;
    const result_type = typed_abi.scalarType(typed_analysis.valueType(function.id, result)) orelse return error.InvalidTypedInstruction;
    const operand = try typedValueText(emitter, function, instruction.operands[0]);
    defer emitter.allocator.free(operand);
    if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) {
        if (result_type != .boolean) return error.InvalidTypedInstruction;
        try emitter.output.writer.print("  %typed.truthy.{d} = ", .{result});
        if (operand_type == .number) try emitter.output.writer.print("fcmp one double {s}, 0.000000e+00", .{operand}) else try emitter.output.writer.print("select i1 true, i1 {s}, i1 false", .{operand});
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %typed.v{d} = xor i1 %typed.truthy.{d}, true", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (operand_type != .number) return error.InvalidTypedInstruction;
    if (result_type != .number) return error.InvalidTypedInstruction;
    if (std.mem.eql(u8, instruction.operator, "-")) {
        try emitter.output.writer.print("  %typed.v{d} = fneg double {s}", .{ result, operand });
    } else if (std.mem.eql(u8, instruction.operator, "+")) {
        // A select identity preserves NaN payloads and negative zero.
        try emitter.output.writer.print("  %typed.v{d} = select i1 true, double {s}, double 0.000000e+00", .{ result, operand });
    } else return error.UnsupportedUnaryOperator;
    try emitter.debugSuffix(instruction.span, scope);
}

fn typedValueText(emitter: *Emitter, function: ir.Function, value: ir.ValueId) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(emitter.allocator);
    defer output.deinit();
    try context.writeTypedValueRef(&output.writer, function, value);
    return output.toOwnedSlice();
}

fn isNumberArithmetic(operator: []const u8) bool {
    for ([_][]const u8{ "+", "-", "*", "/", "÷", "÷÷", "%", "**" }) |candidate| if (std.mem.eql(u8, operator, candidate)) return true;
    return false;
}

fn isComparison(operator: []const u8) bool {
    for ([_][]const u8{ "==", "=", "eq", "===", "!=", "≠", "noteq", "!==", "<", "lt", "<=", "lteq", ">", "gt", ">=", "gteq" }) |candidate| if (std.mem.eql(u8, operator, candidate)) return true;
    return false;
}

fn isLogical(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
}

fn numberPredicate(operator: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "=") or std.mem.eql(u8, operator, "eq") or std.mem.eql(u8, operator, "===")) return "oeq";
    if (std.mem.eql(u8, operator, "!=") or std.mem.eql(u8, operator, "≠") or std.mem.eql(u8, operator, "noteq") or std.mem.eql(u8, operator, "!==")) return "une";
    if (std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, "lt")) return "olt";
    if (std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, "lteq")) return "ole";
    if (std.mem.eql(u8, operator, ">") or std.mem.eql(u8, operator, "gt")) return "ogt";
    if (std.mem.eql(u8, operator, ">=") or std.mem.eql(u8, operator, "gteq")) return "oge";
    return null;
}

fn booleanPredicate(operator: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "=") or std.mem.eql(u8, operator, "eq") or std.mem.eql(u8, operator, "===")) return "eq";
    if (std.mem.eql(u8, operator, "!=") or std.mem.eql(u8, operator, "≠") or std.mem.eql(u8, operator, "noteq") or std.mem.eql(u8, operator, "!==")) return "ne";
    if (std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, "lt")) return "ult";
    if (std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, "lteq")) return "ule";
    if (std.mem.eql(u8, operator, ">") or std.mem.eql(u8, operator, "gt")) return "ugt";
    if (std.mem.eql(u8, operator, ">=") or std.mem.eql(u8, operator, "gteq")) return "uge";
    return null;
}

pub fn writeFunctionWrapper(emitter: *Emitter, function: ir.Function) !void {
    try emitter.output.writer.print("define internal void @lnako.wrapper.{d}(ptr %result.out, ptr %context, ptr %arguments, i64 %argument.count) {{\nentry:\n", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print("  %wrapper.argument.pointer.{d} = getelementptr %lnako.Value, ptr %arguments, i64 {d}\n", .{ index, index });
        try emitter.output.writer.print("  %wrapper.argument.{d} = load %lnako.Value, ptr %wrapper.argument.pointer.{d}\n", .{ index, index });
    }
    try emitter.output.writer.print("  %wrapper.result = call %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print(", %lnako.Value %wrapper.argument.{d}", .{index});
    }
    try emitter.output.writer.writeAll(")\n  store %lnako.Value %wrapper.result, ptr %result.out\n  ret void\n}\n\n");
}

pub fn writeMain(emitter: *Emitter) !void {
    const scope = 4 + emitter.program.functions.len;
    const entry_name = if (target_builtin.os.tag == .windows) "wmain" else "main";
    try emitter.output.writer.print("define i32 @{s}(i32 %argc, ptr %argv) !dbg !{d} {{\nentry:\n", .{ entry_name, scope });
    try emitter.output.writer.writeAll("  %runtime.status = call i32 @lnako_aot_runtime_init()\n");
    for (emitter.program.native_plugin_paths, 0..) |path, index| {
        try emitter.output.writer.print("  call void @lnako_aot_native_plugin_register(ptr @lnako.native.plugin.path.{d}, i64 {d})\n", .{ index, path.len });
    }
    for (emitter.globals.items, 0..) |_, global_index| {
        try emitter.output.writer.print("  %global.root.frame.{d} = alloca %lnako.RootFrame\n", .{global_index});
        try emitter.output.writer.print("  call void @lnako_aot_push_roots(ptr %global.root.frame.{d}, ptr @lnako.global.{d}, i64 1)\n", .{ global_index, global_index });
    }
    if (try emitter.hasDynamicBuiltin()) for (emitter.globals.items, 0..) |name, global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_dynamic_global_register(ptr @lnako.global.name.{d}, i64 {d}, ptr @lnako.global.{d})\n", .{ global_index, name.len, global_index });
    };
    for (emitter.system_strings.items, 0..) |constant, index| {
        try emitter.output.writer.print("  call void @lnako_aot_string_new(ptr @lnako.global.{d}, ptr ", .{constant.global_index});
        if (constant.units.len == 0) {
            try emitter.output.writer.writeAll("null");
        } else try emitter.output.writer.print("@lnako.system.string.{d}", .{index});
        try emitter.output.writer.print(", i64 {d})\n", .{constant.units.len});
    }
    for (emitter.system_arrays.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_array_new(ptr @lnako.global.{d}, ptr null, i64 0)\n", .{global_index});
    }
    for (emitter.system_dictionaries.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_caniuse_agents_new(ptr @lnako.global.{d})\n", .{global_index});
    }
    for (emitter.system_era_data.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_era_data_new(ptr @lnako.global.{d})\n", .{global_index});
    }
    if (emitter.globalIndex("コマンドライン") != null or emitter.globalIndex("ナデシコランタイム") != null or emitter.globalIndex("ナデシコランタイムパス") != null) {
        const constants_initializer = if (target_builtin.os.tag == .windows)
            "lnako_aot_node_constants_init_wide"
        else
            "lnako_aot_node_constants_init";
        try emitter.output.writer.print("  call void @{s}(ptr ", .{constants_initializer});
        if (emitter.globalIndex("コマンドライン")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("ナデシコランタイム")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("ナデシコランタイムパス")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", i32 %argc, ptr %argv)\n");
    }
    if (emitter.globalIndex("デスクトップ") != null or emitter.globalIndex("マイドキュメント") != null or emitter.globalIndex("テンポラリフォルダ") != null) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_node_directory_constants_init(ptr ");
        if (emitter.globalIndex("デスクトップ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("マイドキュメント")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("テンポラリフォルダ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(")\n");
    }
    if (try emitter.needsNodeMotherPath()) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_node_mother_path_init(ptr ");
        if (emitter.globalIndex("母艦パス")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.source_path.len > 0) try emitter.output.writer.writeAll("@lnako.node.source.path") else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d})\n", .{emitter.source_path.len});
    }
    for (emitter.program.functions) |function| if (emitter.globalIndex(function.name)) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_function_new_named(ptr @lnako.global.{d}, ptr @lnako.wrapper.{d}, i64 {d}, ptr @lnako.function.name.{d}, i64 {d}, ptr null, i64 0)\n", .{ global_index, function.id, function.parameters.len, function.id, function.name.len });
    };
    if (emitter.program.http_server_plugin_imported) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_http_server_init(ptr ");
        if (emitter.globalIndex("HTTPメソッド")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("GETデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("POSTデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("FILESデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(")\n");
    }
    var index = emitter.program.module_entries.len;
    var call_index: usize = 0;
    while (index > 0) {
        index -= 1;
        try emitter.output.writer.print("  %entry.result.{d} = call %lnako.Value @lnako.fn.{d}(ptr null)", .{ call_index, emitter.program.module_entries[index] });
        try emitter.debugSuffix(ast.emptySpan(), scope);
        try emitter.output.writer.print("  %entry.exception.pending.{d} = call i32 @lnako_aot_exception_pending()\n", .{call_index});
        try emitter.output.writer.print("  %entry.exception.is-pending.{d} = icmp ne i32 %entry.exception.pending.{d}, 0\n", .{ call_index, call_index });
        try emitter.output.writer.print("  br i1 %entry.exception.is-pending.{d}, label %entry.exception.abort.{d}, label %entry.continue.{d}\n", .{ call_index, call_index, call_index });
        try emitter.output.writer.print("entry.exception.abort.{d}:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.continue.{d}:\n", .{ call_index, call_index });
        call_index += 1;
    }
    if (try emitter.usesAsyncEvents()) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_runtime_drain_events()\n");
    } else {
        try emitter.output.writer.writeAll("  call void @lnako_aot_runtime_drain_events_light()\n");
    }
    try emitter.output.writer.writeAll("  %entry.timer.exception.pending = call i32 @lnako_aot_exception_pending()\n");
    try emitter.output.writer.writeAll("  %entry.timer.exception.is-pending = icmp ne i32 %entry.timer.exception.pending, 0\n");
    try emitter.output.writer.writeAll("  br i1 %entry.timer.exception.is-pending, label %entry.timer.exception.abort, label %entry.timer.continue\n");
    try emitter.output.writer.writeAll("entry.timer.exception.abort:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.timer.continue:\n");
    var global_index = emitter.globals.items.len;
    while (global_index > 0) {
        global_index -= 1;
        try emitter.output.writer.print("  call void @lnako_aot_pop_roots(ptr %global.root.frame.{d})\n", .{global_index});
    }
    try emitter.output.writer.writeAll("  call void @lnako_aot_runtime_deinit()\n  ret i32 0");
    try emitter.debugSuffix(ast.emptySpan(), scope);
    try emitter.output.writer.writeAll("}\n\n");
}
