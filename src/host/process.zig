const std = @import("std");
const builtin = @import("builtin");
const node = @import("lnako").plugins.node;

pub fn runShellCommand(allocator: std.mem.Allocator, io: std.Io, command: []const u8, cwd: ?[]const u8) !node.CommandResult {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

pub fn emptyCommandResult(allocator: std.mem.Allocator) !node.CommandResult {
    const stdout_bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout_bytes);
    return .{ .stdout = stdout_bytes, .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
}
