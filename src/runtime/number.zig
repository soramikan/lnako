const std = @import("std");

pub fn toStringAlloc(allocator: std.mem.Allocator, value: f64) ![]u8 {
    if (std.math.isNan(value)) return allocator.dupe(u8, "NaN");
    if (value == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (value == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    if (value == 0) return allocator.dupe(u8, "0");
    var fixed_output: std.Io.Writer.Allocating = .init(allocator);
    defer fixed_output.deinit();
    try fixed_output.writer.print("{d}", .{value});
    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) return fixedToScientific(allocator, fixed_output.written());
    return allocator.dupe(u8, fixed_output.written());
}

fn fixedToScientific(allocator: std.mem.Allocator, fixed: []const u8) ![]u8 {
    const negative = fixed.len > 0 and fixed[0] == '-';
    const digits_start: usize = @intFromBool(negative);
    const dot = std.mem.indexOfScalarPos(u8, fixed, digits_start, '.') orelse fixed.len;
    var first_nonzero = digits_start;
    while (first_nonzero < fixed.len and (fixed[first_nonzero] == '0' or fixed[first_nonzero] == '.')) first_nonzero += 1;
    if (first_nonzero == fixed.len) return allocator.dupe(u8, "0");
    const exponent: i64 = if (dot < first_nonzero)
        -@as(i64, @intCast(first_nonzero - dot))
    else
        @as(i64, @intCast(dot - first_nonzero - 1));
    var significant = try allocator.alloc(u8, fixed.len - first_nonzero);
    defer allocator.free(significant);
    var length: usize = 0;
    for (fixed[first_nonzero..]) |character| if (character != '.') {
        significant[length] = character;
        length += 1;
    };
    while (length > 1 and significant[length - 1] == '0') length -= 1;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (negative) try output.writer.writeByte('-');
    try output.writer.writeByte(significant[0]);
    if (length > 1) {
        try output.writer.writeByte('.');
        try output.writer.writeAll(significant[1..length]);
    }
    try output.writer.writeByte('e');
    if (exponent >= 0) try output.writer.writeByte('+');
    try output.writer.print("{d}", .{exponent});
    return output.toOwnedSlice();
}

test "binary64をJavaScript互換の最短文字列へ変換する" {
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = -0.0, .expected = "0" },
        .{ .value = std.math.pi, .expected = "3.141592653589793" },
        .{ .value = 0.000001, .expected = "0.000001" },
        .{ .value = 0.0000001, .expected = "1e-7" },
        .{ .value = 1e20, .expected = "100000000000000000000" },
        .{ .value = 1e21, .expected = "1e+21" },
    };
    for (cases) |case| {
        const actual = try toStringAlloc(std.testing.allocator, case.value);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
