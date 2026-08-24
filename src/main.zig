const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    const args = if (process_args.len > 1) process_args[1..] else process_args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const command = lnako.parseCommand(args) catch |err| {
        try stdout.print("コマンドラインエラー: {s}\n\n", .{@errorName(err)});
        try lnako.usage(stdout);
        return;
    };

    switch (command) {
        .help => try lnako.usage(stdout),
        .version => try stdout.print("lnako {s}\n", .{lnako.version}),
        .check => {
            if (args.len < 2) {
                try stderr.writeAll("check: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(128 * 1024 * 1024)) catch |err| {
                try stderr.print("{s}: 読み込みに失敗しました: {s}\n", .{ args[1], @errorName(err) });
                try stderr.flush();
                std.process.exit(2);
            };
            var result = lnako.frontend.parser.parse(allocator, source, args[1]) catch |err| {
                try stderr.print("{s}: 字句解析に失敗しました: {s}\n", .{ args[1], @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            defer result.deinit();
            if (!result.succeeded()) {
                for (result.diagnostics) |item| try item.render(source, stderr);
                try stderr.flush();
                std.process.exit(1);
            }
            try stdout.print("{s}: 構文に問題はありません\n", .{args[1]});
        },
        else => try stdout.print("{s}: 実装準備中です\n", .{@tagName(command)}),
    }
}

test "CLIモジュールを読み込める" {
    try std.testing.expect(lnako.version.len > 0);
}
