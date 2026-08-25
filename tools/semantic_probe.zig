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
        var parsed = try lnako.frontend.parser.parse(allocator, source, "main.nako3");
        defer parsed.deinit();
        if (!parsed.succeeded()) {
            try stdout.writeAll("{\"diagnostics\":true}\n");
            continue;
        }
        var program = try lnako.semantic.analyzer.analyze(allocator, parsed.root.?, "main.nako3");
        defer program.deinit();
        try stdout.writeAll("{\"bindings\":[");
        for (program.bindings, 0..) |binding, index| {
            if (index > 0) try stdout.writeByte(',');
            try stdout.writeAll("{\"kind\":");
            const kind = if (binding.kind == .builtin)
                (if (binding.node.kind == .function_call) "call" else "reference")
            else
                @tagName(binding.kind);
            try std.json.Stringify.value(kind, .{}, stdout);
            try stdout.writeAll(",\"name\":");
            try std.json.Stringify.value(binding.name, .{}, stdout);
            try stdout.writeAll(",\"resolved\":");
            try std.json.Stringify.value(binding.resolved_name, .{}, stdout);
            try stdout.writeByte('}');
        }
        try stdout.writeAll("],\"diagnosticCount\":");
        try stdout.print("{d}", .{program.diagnostics.len});
        if (program.diagnostics.len > 0) {
            const item = program.diagnostics[0];
            try stdout.writeAll(",\"firstDiagnostic\":{\"code\":");
            try std.json.Stringify.value(@tagName(item.code), .{}, stdout);
            try stdout.writeAll(",\"line\":");
            try stdout.print("{d}", .{item.span.line});
            try stdout.writeByte('}');
        }
        try stdout.writeAll("}\n");
    }
}
