const std = @import("std");
const lnako = @import("lnako");

pub const app = @import("cli/app.zig");
pub const arguments = @import("cli/arguments.zig");
pub const test_command = @import("cli/commands/test.zig");

test "CLIモジュールを読み込める" {
    try std.testing.expect(lnako.version.len > 0);
}
