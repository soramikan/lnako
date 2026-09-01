const std = @import("std");

/// The temporal categories exposed by smol-toml's TomlDate wrapper.
pub const Kind = enum {
    date,
    time,
    local_datetime,
    offset_datetime,
};

/// A normalized temporal token.  The parser owns this allocation until it
/// transfers the text into the runtime value object.
pub const Normalized = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    text: []u8,

    pub fn deinit(self: *Normalized) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

/// Keep the parser's existing permissive fallback for date/time-looking
/// tokens that are not part of the standard temporal subset implemented here.
/// This is important for the documented time-only offset quirk: it remains a
/// string instead of being misparsed as a number or an unrelated error.
pub fn looksLikeTemporal(token: []const u8) bool {
    if (token.len < 5 or !std.ascii.isDigit(token[0])) return false;
    return std.mem.indexOfScalar(u8, token, ':') != null or (token.len >= 10 and token[4] == '-' and token[7] == '-');
}

pub fn hasDatePrefix(token: []const u8) bool {
    return token.len >= 10 and isDateShape(token[0..10]);
}

/// Recognize the ordinary temporal forms accepted by smol-toml and format
/// them the same way as TomlDate.toISOString().  Time-only values carrying an
/// offset are deliberately excluded: smol-toml accepts that non-standard
/// input but produces the known malformed `31T22:32:00.` result.
pub fn normalize(allocator: std.mem.Allocator, token: []const u8) !?Normalized {
    const has_date = token.len >= 10 and isDateShape(token[0..10]);
    if (has_date and token.len == 10) {
        const date = try normalizedDate(allocator, token[0..10]);
        if (date) |normalized| return .{ .allocator = allocator, .kind = .date, .text = normalized };
        return null;
    }

    var time_start: usize = 0;
    if (has_date) {
        if (token.len <= 10 or (token[10] != 'T' and token[10] != ' ')) return null;
        time_start = 11;
    }
    if (time_start >= token.len) return null;

    const parsed_time = parseTime(token[time_start..]) orelse return null;
    if (!has_date and parsed_time.suffix.len > 0) return null;

    if (has_date) {
        const date = try normalizedDate(allocator, token[0..10]) orelse return null;
        defer allocator.free(date);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, date);
        try output.append(allocator, 'T');
        try appendNormalizedTime(&output, allocator, parsed_time);
        try output.appendSlice(allocator, parsed_time.suffix);
        return .{
            .allocator = allocator,
            .kind = if (parsed_time.suffix.len == 0) .local_datetime else .offset_datetime,
            .text = try output.toOwnedSlice(allocator),
        };
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendNormalizedTime(&output, allocator, parsed_time);
    return .{ .allocator = allocator, .kind = .time, .text = try output.toOwnedSlice(allocator) };
}

const ParsedTime = struct {
    source: []const u8,
    suffix: []const u8,
    has_seconds: bool,
    fraction_start: ?usize,
};

fn parseTime(source: []const u8) ?ParsedTime {
    if (source.len < 5 or !isTwoDigits(source, 0) or source[2] != ':' or !isTwoDigits(source, 3)) return null;
    if (twoDigits(source, 0) > 23 or twoDigits(source, 3) > 59) return null;

    var index: usize = 5;
    var has_seconds = false;
    if (index < source.len and source[index] == ':') {
        if (index + 3 > source.len or !isTwoDigits(source, index + 1)) return null;
        if (twoDigits(source, index + 1) > 59) return null;
        index += 3;
        has_seconds = true;
    }

    var fraction_start: ?usize = null;
    if (index < source.len and source[index] == '.') {
        if (!has_seconds or index + 1 >= source.len) return null;
        fraction_start = index + 1;
        index += 1;
        while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
        if (index == fraction_start.?) return null;
    }

    const suffix = source[index..];
    if (suffix.len > 0 and !isOffset(suffix)) return null;
    return .{ .source = source[0..index], .suffix = suffix, .has_seconds = has_seconds, .fraction_start = fraction_start };
}

fn appendNormalizedTime(output: *std.ArrayList(u8), allocator: std.mem.Allocator, parsed: ParsedTime) !void {
    try output.appendSlice(allocator, parsed.source[0..5]);
    if (parsed.has_seconds) {
        try output.appendSlice(allocator, parsed.source[5..8]);
    } else {
        try output.appendSlice(allocator, ":00");
    }
    try output.append(allocator, '.');
    if (parsed.fraction_start) |start| {
        const fraction = parsed.source[start..];
        const length = @min(fraction.len, 3);
        try output.appendSlice(allocator, fraction[0..length]);
        for (length..3) |_| try output.append(allocator, '0');
    } else {
        try output.appendSlice(allocator, "000");
    }
}

fn normalizedDate(allocator: std.mem.Allocator, token: []const u8) !?[]u8 {
    if (token.len != 10 or !isDateShape(token)) return null;
    const year = fourDigits(token, 0);
    var month = twoDigits(token, 5);
    var day = twoDigits(token, 8);
    if (month == 0 or month > 12 or day == 0 or day > 31) return null;

    // Date.parse, which TomlDate delegates to, accepts day overflow within a
    // month (for example 1979-04-31 becomes 1979-05-01).  Preserve that
    // observable normalization while rejecting impossible month/day ranges.
    var normalized_year = year;
    while (day > daysInMonth(normalized_year, month)) {
        day -= daysInMonth(normalized_year, month);
        month += 1;
        if (month == 13) {
            month = 1;
            normalized_year += 1;
            if (normalized_year > 9999) return null;
        }
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendFourDigits(&output, allocator, normalized_year);
    try output.append(allocator, '-');
    try appendTwoDigits(&output, allocator, month);
    try output.append(allocator, '-');
    try appendTwoDigits(&output, allocator, day);
    return try output.toOwnedSlice(allocator);
}

fn isDateShape(token: []const u8) bool {
    return token.len == 10 and isFourDigits(token, 0) and token[4] == '-' and isTwoDigits(token, 5) and token[7] == '-' and isTwoDigits(token, 8);
}

fn isOffset(token: []const u8) bool {
    if (token.len == 1) return token[0] == 'Z' or token[0] == 'z';
    if (token.len != 6 or (token[0] != '+' and token[0] != '-') or token[3] != ':' or !isTwoDigits(token, 1) or !isTwoDigits(token, 4)) return false;
    return twoDigits(token, 1) <= 23 and twoDigits(token, 4) <= 59;
}

fn isFourDigits(source: []const u8, start: usize) bool {
    return start + 4 <= source.len and std.ascii.isDigit(source[start]) and std.ascii.isDigit(source[start + 1]) and std.ascii.isDigit(source[start + 2]) and std.ascii.isDigit(source[start + 3]);
}

fn isTwoDigits(source: []const u8, start: usize) bool {
    return start + 2 <= source.len and std.ascii.isDigit(source[start]) and std.ascii.isDigit(source[start + 1]);
}

fn fourDigits(source: []const u8, start: usize) u16 {
    return @as(u16, source[start] - '0') * 1000 + @as(u16, source[start + 1] - '0') * 100 + @as(u16, source[start + 2] - '0') * 10 + @as(u16, source[start + 3] - '0');
}

fn twoDigits(source: []const u8, start: usize) u8 {
    return (source[start] - '0') * 10 + source[start + 1] - '0';
}

fn appendFourDigits(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try output.append(allocator, @intCast('0' + value / 1000));
    try output.append(allocator, @intCast('0' + (value / 100) % 10));
    try output.append(allocator, @intCast('0' + (value / 10) % 10));
    try output.append(allocator, @intCast('0' + value % 10));
}

fn appendTwoDigits(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u8) !void {
    try output.append(allocator, @intCast('0' + value / 10));
    try output.append(allocator, @intCast('0' + value % 10));
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn isLeapYear(year: u16) bool {
    return year % 400 == 0 or (year % 4 == 0 and year % 100 != 0);
}

test "TOML日時をsmol-toml互換のISO表現へ正規化する" {
    const cases = [_]struct { source: []const u8, kind: Kind, expected: []const u8 }{
        .{ .source = "1979-05-27", .kind = .date, .expected = "1979-05-27" },
        .{ .source = "07:32", .kind = .time, .expected = "07:32:00.000" },
        .{ .source = "07:32:00.123456", .kind = .time, .expected = "07:32:00.123" },
        .{ .source = "1979-05-27 07:32", .kind = .local_datetime, .expected = "1979-05-27T07:32:00.000" },
        .{ .source = "1979-05-27T07:32:00-05:30", .kind = .offset_datetime, .expected = "1979-05-27T07:32:00.000-05:30" },
        .{ .source = "1979-04-31", .kind = .date, .expected = "1979-05-01" },
    };
    for (cases) |case| {
        var normalized = (try normalize(std.testing.allocator, case.source)).?;
        defer normalized.deinit();
        try std.testing.expectEqual(case.kind, normalized.kind);
        try std.testing.expectEqualStrings(case.expected, normalized.text);
    }
}

test "TOML日時の非標準な時刻単独offsetは専用型へ昇格しない" {
    try std.testing.expect((try normalize(std.testing.allocator, "07:32:00+09:00")) == null);
}
