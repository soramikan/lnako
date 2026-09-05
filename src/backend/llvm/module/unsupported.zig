const std = @import("std");
const ir = @import("../../../ir/nako_ir.zig");
const ast = @import("../../../frontend/ast.zig");
const aot_builtin = @import("../../../runtime/aot_builtin.zig");
const shared = @import("shared.zig");

pub const UnsupportedFeature = struct {
    function_name: []const u8,
    opcode: []const u8,
    detail: []const u8,
    span: ast.Span,
};

/// A single builtin dispatch recorded by the optional AOT compile manifest.
///
/// This is deliberately limited to names, a stable site identity, and source
/// locations. It is a pre-optimization witness of the dispatches that the
pub fn findUnsupported(program: ir.Program) ?UnsupportedFeature {
    for (program.functions) |function| for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            const supported = switch (instruction.opcode) {
                .const_number,
                .const_boolean,
                .const_null,
                .const_undefined,
                .load_global,
                .store_global,
                .load_local,
                .store_local,
                .make_array,
                .make_object,
                .array_get,
                .property_get,
                .array_set,
                .property_set,
                .iterator_next,
                .iterator_has_next,
                .increment,
                .phi,
                .speed_mode_begin,
                .speed_mode_end,
                .performance_monitor_begin,
                .performance_monitor_end,
                .try_begin,
                .try_end,
                .exception_pending,
                .exception_take,
                => true,
                .const_bigint => true,
                .destructure_store => destructureSourceSupported(function, instruction),
                .const_string => true,
                .binary => shared.arithmeticOpcode(instruction.operator) != null or comparisonPredicate(instruction.operator) != null or
                    shared.shiftOpcode(instruction.operator) != null or
                    std.mem.eql(u8, instruction.operator, "&") or
                    std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and") or
                    std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or"),
                .unary => std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not") or
                    std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-"),
                .call => shared.isDisplayCall(instruction.name) or aot_builtin.lookup(instruction.name) != null or validDirectCallee(program, instruction) or shared.lookupFunction(program, instruction.name) != null or
                    shared.isDynamicNamedCall(function, instruction.name) or shared.isNativePluginCall(program, function, instruction),
                .call_value => instruction.operands.len > 0,
                .make_closure => closureSupported(program, function, instruction.name),
                .iterator_begin => iteratorSourceSupported(function, instruction),
                else => false,
            };
            if (!supported) return .{
                .function_name = function.name,
                .opcode = @tagName(instruction.opcode),
                .detail = if (instruction.name.len > 0) instruction.name else if (instruction.operator.len > 0) instruction.operator else @tagName(instruction.opcode),
                .span = instruction.span,
            };
        }
        switch (block.terminator) {
            .branch, .conditional_branch, .return_value, .throw_value, .propagate_exception, .unreachable_terminator => {},
            else => return .{
                .function_name = function.name,
                .opcode = @tagName(block.terminator),
                .detail = "terminator",
                .span = if (block.instructions.len > 0) block.instructions[block.instructions.len - 1].span else ast.emptySpan(),
            },
        }
    };
    return null;
}

fn validDirectCallee(program: ir.Program, instruction: ir.Instruction) bool {
    return if (instruction.direct_callee) |callee| callee < program.functions.len else false;
}

fn closureSupported(program: ir.Program, caller: ir.Function, name: []const u8) bool {
    const function = shared.lookupFunction(program, name) orelse return false;
    for (function.captures) |capture| if (!shared.hasLocalName(caller, capture)) return false;
    return true;
}

fn iteratorSourceSupported(function: ir.Function, instruction: ir.Instruction) bool {
    if (instruction.operands.len == 0) return false;
    if (instruction.name.len > 0 and instruction.operands.len >= 2) return true;
    return switch (shared.valueType(function, instruction.operands[0])) {
        .void => false,
        else => true,
    };
}

fn destructureSourceSupported(_: ir.Function, instruction: ir.Instruction) bool {
    return instruction.operands.len == 1;
}

fn comparisonPredicate(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, predicate: []const u8 }{
        .{ .operator = "==", .predicate = "oeq" },    .{ .operator = "=", .predicate = "oeq" },   .{ .operator = "eq", .predicate = "oeq" },
        .{ .operator = "===", .predicate = "oeq" },   .{ .operator = "!=", .predicate = "une" },
        .{ .operator = "≠", .predicate = "une" },
        .{ .operator = "noteq", .predicate = "une" }, .{ .operator = "!==", .predicate = "une" }, .{ .operator = "<", .predicate = "olt" },
        .{ .operator = "lt", .predicate = "olt" },    .{ .operator = "<=", .predicate = "ole" },  .{ .operator = "lteq", .predicate = "ole" },
        .{ .operator = ">", .predicate = "ogt" },     .{ .operator = "gt", .predicate = "ogt" },  .{ .operator = ">=", .predicate = "oge" },
        .{ .operator = "gteq", .predicate = "oge" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.predicate;
    return null;
}
