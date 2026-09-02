const std = @import("std");
const builtin = @import("builtin");

/// Compare a process environment value without importing the C `getenv`
/// symbol. The compiler and Interpreter are intentionally libc-free on
/// Windows, while the same lookup must work for the AOT runtime as well.
pub fn valueEquals(comptime key: []const u8, comptime expected: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        const key_w = std.unicode.wtf8ToWtf16LeStringLiteral(key);
        const expected_w = std.unicode.wtf8ToWtf16LeStringLiteral(expected);
        const value = environ.getWindows(key_w) orelse return false;
        return std.mem.eql(u16, value, expected_w[0..]);
    }
    const value = std.c.getenv(@ptrCast(key.ptr)) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), expected);
}
