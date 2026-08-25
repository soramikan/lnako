const std = @import("std");
const ir = @import("nako_ir.zig");

/// Nako SSA IRを差分確認しやすい安定したテキスト形式で出力する。
/// この形式はデバッグ・回帰テスト用であり、永続的なバイナリABIではない。
pub fn write(program: ir.Program, writer: *std.Io.Writer) !void {
    for (program.functions, 0..) |function, function_index| {
        if (function_index > 0) try writer.writeByte('\n');
        try writer.print("func @{s}(", .{function.name});
        for (function.parameters, 0..) |parameter, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.print("%{d}:{s} {s}", .{ parameter.value, @tagName(parameter.type), parameter.name });
        }
        try writer.print(") -> {s}", .{@tagName(function.return_type)});
        if (function.is_async) try writer.writeAll(" async");
        try writer.writeAll(" {\n");
        for (function.blocks) |block| {
            try writer.print("bb{d} {s}:\n", .{ block.id, block.name });
            for (block.instructions) |instruction| try writeInstruction(instruction, writer);
            try writeTerminator(block.terminator, writer);
        }
        try writer.writeAll("}\n");
    }
}

fn writeInstruction(instruction: ir.Instruction, writer: *std.Io.Writer) !void {
    try writer.writeAll("  ");
    if (instruction.result) |result| try writer.print("%{d}:{s} = ", .{ result, @tagName(instruction.type) });
    try writer.writeAll(@tagName(instruction.opcode));
    for (instruction.operands) |operand| try writer.print(" %{d}", .{operand});
    if (instruction.phi_incoming.len > 0) {
        for (instruction.phi_incoming) |incoming| try writer.print(" [bb{d}, %{d}]", .{ incoming.predecessor, incoming.value });
    }
    if (instruction.name.len > 0) try writer.print(" name={s}", .{instruction.name});
    if (instruction.names.len > 0) {
        try writer.writeAll(" names=[");
        for (instruction.names, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll(name);
        }
        try writer.writeByte(']');
    }
    if (instruction.operator.len > 0) try writer.print(" op={s}", .{instruction.operator});
    if (instruction.text.len > 0) {
        try writer.writeAll(" text=");
        try std.json.Stringify.value(instruction.text, .{}, writer);
    }
    if (instruction.number_value) |number| try writer.print(" number={d}", .{number});
    if (instruction.direct_callee) |callee| try writer.print(" callee=@{d}", .{callee});
    if (instruction.loop_direction != .automatic) try writer.print(" direction={s}", .{@tagName(instruction.loop_direction)});
    if (instruction.exception_target) |target| try writer.print(" unwind=bb{d}", .{target});
    try writer.writeByte('\n');
}

fn writeTerminator(terminator: ir.Terminator, writer: *std.Io.Writer) !void {
    try writer.writeAll("  ");
    switch (terminator) {
        .none => try writer.writeAll("<missing terminator>"),
        .branch => |target| try writer.print("br bb{d}", .{target}),
        .conditional_branch => |branch| try writer.print("br_if %{d} bb{d} bb{d}", .{ branch.condition, branch.then_block, branch.else_block }),
        .return_value => |value| if (value) |operand| try writer.print("return %{d}", .{operand}) else try writer.writeAll("return"),
        .throw_value => |throw_value| {
            try writer.print("throw %{d}", .{throw_value.value});
            if (throw_value.target) |target| try writer.print(" catch bb{d}", .{target});
        },
        .unreachable_terminator => try writer.writeAll("unreachable"),
    }
    try writer.writeByte('\n');
}

test "SSA IRを安定したテキストへ出力する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const hir = @import("hir.zig");
    const lower_ssa = @import("lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\nAを表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(program, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "func @main__$entry() -> void") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "store_global %0 name=main__A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "call %1 name=表示") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "  return\n}\n"));
}
