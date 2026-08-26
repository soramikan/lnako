const std = @import("std");
const build_options = @import("build_options");

pub const json: []const u8 = build_options.compat_summary_json;

pub fn write(writer: *std.Io.Writer) !void {
    try writer.writeAll(json);
    if (json.len == 0 or json[json.len - 1] != '\n') try writer.writeByte('\n');
}

test "埋め込み互換レポートが標準527命令の現在状態を表す" {
    try std.testing.expect(std.mem.indexOf(u8, json, "\"standardCnakoCommands\": 527") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"native\": 520") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"compat-js\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocked\": 3") != null);
}
