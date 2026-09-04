const std = @import("std");
const builtin = @import("builtin");

pub fn homeDirectory(environment: *const std.process.Environ.Map) ?[]const u8 {
    return environment.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
}

pub fn temporaryDirectory(environment: *const std.process.Environ.Map) []const u8 {
    const value = if (builtin.os.tag == .windows)
        environment.get("TEMP") orelse environment.get("TMP") orelse "."
    else
        environment.get("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    return if (trimmed.len == 0) value else trimmed;
}

pub fn parseOptionalI64(value: ?[]const u8) ?i64 {
    return std.fmt.parseInt(i64, value orelse return null, 10) catch null;
}

pub fn parseOptionalU64(value: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, value orelse return null, 10) catch null;
}

pub fn parseOptionalF64(value: ?[]const u8) ?f64 {
    return std.fmt.parseFloat(f64, value orelse return null) catch null;
}
