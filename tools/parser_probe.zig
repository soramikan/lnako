const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    for (process_args[1..]) |source| {
        var result = lnako.frontend.parser.parse(allocator, source, "main.nako3") catch |err| {
            try stdout.writeAll("{\"diagnostics\":[{\"severity\":\"error\",\"code\":");
            try std.json.Stringify.value(@errorName(err), .{}, stdout);
            try stdout.writeAll(",\"message\":\"フロントエンドエラー\"}]}\n");
            continue;
        };
        defer result.deinit();
        if (result.root) |root| {
            try writeNode(stdout, root);
        } else {
            try stdout.writeAll("{\"diagnostics\":");
            try std.json.Stringify.value(result.diagnostics, .{}, stdout);
            try stdout.writeByte('}');
        }
        try stdout.writeByte('\n');
    }
}

fn writeNode(writer: *std.Io.Writer, node: *const lnako.frontend.ast.Node) !void {
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(lnako.frontend.ast.kindName(node.kind), .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(node.name, .{}, writer);
    try writer.writeAll(",\"value\":");
    try std.json.Stringify.value(node.value, .{}, writer);
    try writer.writeAll(",\"operator\":");
    try std.json.Stringify.value(node.operator, .{}, writer);
    try writer.writeAll(",\"josi\":");
    try std.json.Stringify.value(node.josi, .{}, writer);
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{node.span.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{node.span.column});
    try writer.writeAll(",\"arguments\":[");
    for (node.arguments, 0..) |argument, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(argument.name, .{}, writer);
        try writer.writeAll(",\"josi\":");
        try std.json.Stringify.value(argument.josi, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"children\":[");
    for (node.children, 0..) |child, index| {
        if (index > 0) try writer.writeByte(',');
        try writeNode(writer, child);
    }
    try writer.writeAll("]}");
}
