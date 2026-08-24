const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    for (process_args[1..]) |source| {
        var stream = try lnako.frontend.lexer.tokenize(allocator, source);
        defer stream.deinit();
        try lnako.frontend.syntax_transform.apply(&stream);
        try std.json.Stringify.value(stream.tokens, .{}, stdout);
        try stdout.writeByte('\n');
    }
}
