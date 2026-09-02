const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const constants = @import("constants.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const milliseconds_per_second: i64 = 1000;
const milliseconds_per_minute: i64 = 60 * milliseconds_per_second;
const milliseconds_per_hour: i64 = 60 * milliseconds_per_minute;
const milliseconds_per_day: i64 = 24 * milliseconds_per_hour;
const tokyo_offset_milliseconds: i64 = 9 * milliseconds_per_hour;

pub const Context = struct {
    now_milliseconds: i64,
    monotonic_milliseconds: f64,
};

const Fields = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millisecond: i64,
    weekday: u8,
};

const Era = struct { name: []const u8, year: i64, month: i64, day: i64 };
const eras = [_]Era{
    .{ .name = "令和", .year = 2019, .month = 5, .day = 1 },
    .{ .name = "平成", .year = 1989, .month = 1, .day = 8 },
    .{ .name = "昭和", .year = 1926, .month = 12, .day = 25 },
    .{ .name = "大正", .year = 1912, .month = 7, .day = 30 },
    .{ .name = "明治", .year = 1868, .month = 10, .day = 23 },
};

pub fn install(runtime: *Runtime, installer: constants.Installer) !void {
    var data = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&data);
    for (eras) |era| {
        var item = try runtime.createDictionary();
        try roots.protect(&item);
        try common.dictionarySetUtf8(runtime, item.dictionary, "元号", try runtime.stringUtf8(era.name));
        const date = try std.fmt.allocPrint(runtime.allocator(), "{:04}/{:02}/{:02}", .{ @as(u64, @intCast(era.year)), @as(u64, @intCast(era.month)), @as(u64, @intCast(era.day)) });
        defer runtime.allocator().free(date);
        try common.dictionarySetUtf8(runtime, item.dictionary, "改元日", try runtime.stringUtf8(date));
        _ = try data.array.push(item);
    }
    try installer.set("元号データ", data);
}

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    const now = if (context) |actual| actual.now_milliseconds else 0;
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    if (eql(name, "今")) return try formatTime(runtime, fieldsFromEpoch(now));
    if (eql(name, "システム時間")) return .{ .number = @floor(@as(f64, @floatFromInt(now)) / 1000) };
    if (eql(name, "システム時間ミリ秒")) return .{ .number = @floatFromInt(now) };
    if (eql(name, "今日")) return try formatDate(runtime, fieldsFromEpoch(now));
    if (eql(name, "明日")) return try formatDate(runtime, fieldsFromEpoch(now + milliseconds_per_day));
    if (eql(name, "昨日")) return try formatDate(runtime, fieldsFromEpoch(now - milliseconds_per_day));
    if (isAny(name, &.{ "今年", "来年", "去年" })) {
        const year = fieldsFromEpoch(now).year + if (eql(name, "来年")) @as(i64, 1) else if (eql(name, "去年")) @as(i64, -1) else @as(i64, 0);
        return .{ .number = @floatFromInt(year) };
    }
    if (isAny(name, &.{ "今月", "来月", "先月" })) {
        const month = fieldsFromEpoch(now).month;
        const result = if (eql(name, "来月")) @mod(month, 12) + 1 else if (eql(name, "先月")) @mod(month + 10, 12) + 1 else month;
        return .{ .number = @floatFromInt(result) };
    }
    if (eql(name, "曜日")) return try weekdayName(runtime, try parseDate(runtime, a, now));
    if (eql(name, "曜日番号取得")) return try weekdayNumber(runtime, a);
    if (isAny(name, &.{ "UNIXTIME変換", "UNIX時間変換" })) return .{ .number = (try parseDate(runtime, a, now)) / 1000 };
    if (eql(name, "日時変換")) return try formatDateTimeFor(runtime, fieldsFromEpoch(floatToEpoch(try runtime.valueToNumber(a) * 1000)), .date_time);
    if (eql(name, "日時書式変換")) return try formatCustom(runtime, try parseDate(runtime, a, now), b);
    if (eql(name, "和暦変換")) return try japaneseEra(runtime, try parseDate(runtime, a, now));
    if (isAny(name, &.{ "年数差", "月数差", "日数差", "時間差", "分差", "秒差" })) return try dateDifference(runtime, name, a, b, now);
    if (eql(name, "日時差")) return try dateDifference(runtime, try unitCommand(runtime, common.argument(arguments, 2)), a, b, now);
    if (eql(name, "時間加算")) return try addTime(runtime, a, b, now);
    if (eql(name, "日付加算")) return try addDate(runtime, a, b, now);
    if (eql(name, "日時加算")) return try addDateTime(runtime, a, b, now);
    if (eql(name, "時間ミリ秒取得")) return .{ .number = if (context) |actual| actual.monotonic_milliseconds else 0 };
    return null;
}

fn parseDate(runtime: *Runtime, source: Value, now: i64) !f64 {
    const text_value = try runtime.valueToString(source);
    const utf8 = try text_value.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    const text = std.mem.trim(u8, utf8, " \t\r\n");
    if (isUnsignedDecimal(text)) return std.math.trunc((std.fmt.parseFloat(f64, text) catch return std.math.nan(f64)) * 1000);
    if (isTimeText(text)) {
        const parts = try parseDelimited(text, ':');
        const today = fieldsFromEpoch(now);
        return @floatFromInt(constructLocal(today.year, today.month - 1, today.day, parts[0], parts[1], parts[2], 0, true));
    }
    const normalized = try runtime.allocator().dupe(u8, text);
    defer runtime.allocator().free(normalized);
    for (normalized) |*byte| if (byte.* == ' ' or byte.* == ':' or byte.* == '-' or byte.* == 'T') {
        byte.* = '/';
    };
    var parts = [_]i64{ 0, 0, 0, 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, normalized, '/');
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= parts.len) break;
        parts[index] = parseIntPrefix(part) orelse return std.math.nan(f64);
        index += 1;
    }
    if (index < 3) return std.math.nan(f64);
    return @floatFromInt(constructLocal(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5], 0, true));
}

fn constructLocal(year_input: i64, month_zero_input: i64, day: i64, hour: i64, minute: i64, second: i64, millisecond: i64, constructor_year_rule: bool) i64 {
    var year = year_input;
    if (constructor_year_rule and year >= 0 and year <= 99) year += 1900;
    year += @divFloor(month_zero_input, 12);
    const month_zero = @mod(month_zero_input, 12);
    const days = daysFromCivil(year, month_zero + 1, 1) + day - 1;
    return days * milliseconds_per_day + hour * milliseconds_per_hour + minute * milliseconds_per_minute + second * milliseconds_per_second + millisecond - tokyo_offset_milliseconds;
}

fn fieldsFromEpoch(milliseconds: i64) Fields {
    const local = milliseconds + tokyo_offset_milliseconds;
    const days = @divFloor(local, milliseconds_per_day);
    const within_day = @mod(local, milliseconds_per_day);
    const civil = civilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @divTrunc(within_day, milliseconds_per_hour),
        .minute = @divTrunc(@mod(within_day, milliseconds_per_hour), milliseconds_per_minute),
        .second = @divTrunc(@mod(within_day, milliseconds_per_minute), milliseconds_per_second),
        .millisecond = @mod(within_day, milliseconds_per_second),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

fn daysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn civilFromDays(days_input: i64) struct { year: i64, month: i64, day: i64 } {
    const days = days_input + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

fn formatDate(runtime: *Runtime, fields: Fields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator(), "{d}/{:02}/{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
    defer runtime.allocator().free(text);
    return runtime.stringUtf8(text);
}

fn formatTime(runtime: *Runtime, fields: Fields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator(), "{:02}:{:02}:{:02}", .{ @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator().free(text);
    return runtime.stringUtf8(text);
}

const OutputShape = enum { date_time, date, time };

fn formatDateTimeFor(runtime: *Runtime, fields: Fields, shape: OutputShape) !Value {
    return switch (shape) {
        .date => formatDate(runtime, fields),
        .time => formatTime(runtime, fields),
        .date_time => blk: {
            const text = try std.fmt.allocPrint(runtime.allocator(), "{d}/{:02}/{:02} {:02}:{:02}:{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)), @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
            defer runtime.allocator().free(text);
            break :blk runtime.stringUtf8(text);
        },
    };
}

fn outputShape(runtime: *Runtime, original: Value) !OutputShape {
    const text = try common.toUtf8Alloc(runtime, original);
    defer runtime.allocator().free(text);
    if (looksDateTime(text)) return .date_time;
    if (looksDate(text)) return .date;
    if (isTimeText(text)) return .time;
    return .date_time;
}

fn weekdayName(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return runtime.stringUtf8("日");
    const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
    return runtime.stringUtf8(names[fieldsFromEpoch(floatToEpoch(milliseconds)).weekday]);
}

fn weekdayNumber(runtime: *Runtime, source: Value) !Value {
    const text = try common.toUtf8Alloc(runtime, source);
    defer runtime.allocator().free(text);
    var iterator = std.mem.splitScalar(u8, text, '/');
    const year = parseIntPrefix(iterator.next() orelse return .{ .number = std.math.nan(f64) }) orelse return .{ .number = std.math.nan(f64) };
    const month = parseIntPrefix(iterator.next() orelse return .{ .number = std.math.nan(f64) }) orelse return .{ .number = std.math.nan(f64) };
    const day = parseIntPrefix(iterator.next() orelse return .{ .number = std.math.nan(f64) }) orelse return .{ .number = std.math.nan(f64) };
    return .{ .number = @floatFromInt(fieldsFromEpoch(constructLocal(year, month - 1, day, 0, 0, 0, 0, true)).weekday) };
}

fn formatCustom(runtime: *Runtime, milliseconds: f64, format_value: Value) !Value {
    if (!std.math.isFinite(milliseconds)) return runtime.stringUtf8("Invalid Date");
    const fields = fieldsFromEpoch(floatToEpoch(milliseconds));
    const format = try common.toUtf8Alloc(runtime, format_value);
    defer runtime.allocator().free(format);
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    var index: usize = 0;
    while (index < format.len) {
        if (matchToken(format, index, "YYYY")) {
            try output.writer.print("{d}", .{fields.year});
            index += 4;
        } else if (matchToken(format, index, "ccc")) {
            try output.writer.print("{:03}", .{@as(u64, @intCast(fields.millisecond))});
            index += 3;
        } else if (matchToken(format, index, "WWW")) {
            const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            try output.writer.writeAll(names[fields.weekday]);
            index += 3;
        } else if (matchToken(format, index, "MMM")) {
            const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            try output.writer.writeAll(names[@intCast(fields.month - 1)]);
            index += 3;
        } else if (index + 2 <= format.len and isTwoToken(format[index .. index + 2])) {
            const token = format[index .. index + 2];
            if (eql(token, "YY")) try output.writer.print("{:02}", .{@as(u64, @intCast(@mod(fields.year, 100)))}) else if (eql(token, "MM")) try output.writer.print("{:02}", .{@as(u64, @intCast(fields.month))}) else if (eql(token, "DD")) try output.writer.print("{:02}", .{@as(u64, @intCast(fields.day))}) else if (eql(token, "HH")) try output.writer.print("{:02}", .{@as(u64, @intCast(fields.hour))}) else if (eql(token, "mm")) try output.writer.print("{:02}", .{@as(u64, @intCast(fields.minute))}) else try output.writer.print("{:02}", .{@as(u64, @intCast(fields.second))});
            index += 2;
        } else switch (format[index]) {
            'M' => {
                try output.writer.print("{d}", .{fields.month});
                index += 1;
            },
            'D' => {
                try output.writer.print("{d}", .{fields.day});
                index += 1;
            },
            'H' => {
                try output.writer.print("{d}", .{fields.hour});
                index += 1;
            },
            'm' => {
                try output.writer.print("{d}", .{fields.minute});
                index += 1;
            },
            's' => {
                try output.writer.print("{d}", .{fields.second});
                index += 1;
            },
            'W' => {
                const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
                try output.writer.writeAll(names[fields.weekday]);
                index += 1;
            },
            else => {
                try output.writer.writeByte(format[index]);
                index += 1;
            },
        }
    }
    return runtime.stringUtf8(output.written());
}

fn japaneseEra(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return error.InvalidDate;
    const fields = fieldsFromEpoch(floatToEpoch(milliseconds));
    const day_number = daysFromCivil(fields.year, fields.month, fields.day);
    for (eras) |era| if (day_number >= daysFromCivil(era.year, era.month, era.day)) {
        const era_year = fields.year - era.year + 1;
        const year_text = if (era_year == 1) "元" else null;
        const text = if (year_text) |special|
            try std.fmt.allocPrint(runtime.allocator(), "{s}{s}年{:02}月{:02}日", .{ era.name, special, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) })
        else
            try std.fmt.allocPrint(runtime.allocator(), "{s}{d}年{:02}月{:02}日", .{ era.name, era_year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
        defer runtime.allocator().free(text);
        return runtime.stringUtf8(text);
    };
    return error.DateBeforeMeiji;
}

fn dateDifference(runtime: *Runtime, name: []const u8, first_value: Value, second_value: Value, now: i64) !Value {
    const first = try parseDate(runtime, first_value, now);
    const second = try parseDate(runtime, second_value, now);
    if (isAny(name, &.{ "年数差", "月数差" })) {
        if (!std.math.isFinite(first) or !std.math.isFinite(second)) return .{ .number = std.math.nan(f64) };
        const left = fieldsFromEpoch(floatToEpoch(first));
        const right = fieldsFromEpoch(floatToEpoch(second));
        const difference = if (eql(name, "年数差")) right.year - left.year else right.year * 12 + right.month - 1 - (left.year * 12 + left.month - 1);
        return .{ .number = @floatFromInt(difference) };
    }
    const first_seconds = @ceil(first / 1000);
    const second_seconds = @ceil(second / 1000);
    const divisor: f64 = if (eql(name, "日数差")) 86400 else if (eql(name, "時間差")) 3600 else if (eql(name, "分差")) 60 else 1;
    return .{ .number = @ceil((second_seconds - first_seconds) / divisor) };
}

fn unitCommand(runtime: *Runtime, value: Value) ![]const u8 {
    const text = try common.toUtf8Alloc(runtime, value);
    defer runtime.allocator().free(text);
    if (eql(text, "年")) return "年数差";
    if (eql(text, "月")) return "月数差";
    if (eql(text, "日")) return "日数差";
    if (eql(text, "時間")) return "時間差";
    if (eql(text, "分")) return "分差";
    if (eql(text, "秒")) return "秒差";
    return error.UnknownDateUnit;
}

fn addTime(runtime: *Runtime, source: Value, addition: Value, now: i64) !Value {
    const addition_text = try common.toUtf8Alloc(runtime, addition);
    defer runtime.allocator().free(addition_text);
    var text = addition_text;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try parseDelimited(text, ':');
    const seconds = sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    const original = try parseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    return formatDateTimeFor(runtime, fieldsFromEpoch(floatToEpoch(original) + seconds * 1000), try outputShape(runtime, source));
}

fn addDate(runtime: *Runtime, source: Value, addition: Value, now: i64) !Value {
    const addition_text = try common.toUtf8Alloc(runtime, addition);
    defer runtime.allocator().free(addition_text);
    var text = addition_text;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try parseDelimited(text, '/');
    const original = try parseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    const original_epoch = floatToEpoch(original);
    const epoch = if (datetimePluginRouteEnabled())
        addDatePluginEpoch(original_epoch, parts, sign)
    else
        addDateSystemEpoch(original_epoch, parts, sign);
    return formatDateTimeFor(runtime, fieldsFromEpoch(epoch), try outputShape(runtime, source));
}

fn addDateSystemEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = fieldsFromEpoch(original);
    var epoch = constructLocal(fields.year + parts[0] * sign, fields.month - 1, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = fieldsFromEpoch(epoch);
    epoch = constructLocal(fields.year, fields.month - 1 + parts[1] * sign, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = fieldsFromEpoch(epoch);
    return constructLocal(fields.year, fields.month - 1, fields.day + parts[2] * sign, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

/// The old-format `plugin_datetime` implementation delegates each component
/// to dayjs.  Calendar-unit additions therefore clamp to the last day of the
/// target month, unlike the system plugin's JavaScript Date overflow.
fn addDatePluginEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = fieldsFromEpoch(original);
    var epoch = addCalendarClamped(fields, parts[0] * sign, 0);
    fields = fieldsFromEpoch(epoch);
    epoch = addCalendarClamped(fields, 0, parts[1] * sign);
    return epoch + parts[2] * sign * milliseconds_per_day;
}

fn addCalendarClamped(fields: Fields, year_delta: i64, month_delta: i64) i64 {
    const month_zero = fields.month - 1 + month_delta;
    const year = fields.year + year_delta + @divFloor(month_zero, 12);
    const normalized_month_zero = @mod(month_zero, 12);
    const day = @min(fields.day, daysInMonth(year, normalized_month_zero + 1));
    return constructLocal(year, normalized_month_zero, day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn datetimePluginRouteEnabled() bool {
    const route = std.c.getenv("LNAKO_PLUGIN_ROUTE") orelse return false;
    return std.mem.eql(u8, std.mem.span(route), "plugin_datetime");
}

fn addDateTime(runtime: *Runtime, source: Value, addition: Value, now: i64) !Value {
    const text = try common.toUtf8Alloc(runtime, addition);
    defer runtime.allocator().free(text);
    var sign: i64 = 1;
    var cursor: usize = 0;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        cursor = 1;
    }
    const number_start = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
    if (cursor == number_start) return error.InvalidDateAddition;
    const amount = (std.fmt.parseInt(i64, text[number_start..cursor], 10) catch return error.InvalidDateAddition) * sign;
    const unit = text[cursor..];
    if (eql(unit, "年")) return addDate(runtime, source, try allocatedAffixString(runtime, amount, "/0/0"), now);
    if (eql(unit, "ヶ月")) return addDate(runtime, source, try allocatedAroundString(runtime, amount, "0/", "/0"), now);
    if (eql(unit, "週間")) return addDate(runtime, source, try allocatedAffixString(runtime, amount * 7, "0/0/"), now);
    if (eql(unit, "日")) return addDate(runtime, source, try allocatedAffixString(runtime, amount, "0/0/"), now);
    if (eql(unit, "時間")) return addTime(runtime, source, try allocatedAffixString(runtime, amount, ":0:0"), now);
    if (eql(unit, "分")) return addTime(runtime, source, try allocatedAroundString(runtime, amount, "0:", ":0"), now);
    if (eql(unit, "秒")) return addTime(runtime, source, try allocatedAffixString(runtime, amount, "0:0:"), now);
    return error.InvalidDateAddition;
}

fn allocatedAffixString(runtime: *Runtime, number: i64, prefix_or_suffix: []const u8) !Value {
    const text = if (prefix_or_suffix.len > 0 and (prefix_or_suffix[0] == '/' or prefix_or_suffix[0] == ':'))
        try std.fmt.allocPrint(runtime.allocator(), "{d}{s}", .{ number, prefix_or_suffix })
    else
        try std.fmt.allocPrint(runtime.allocator(), "{s}{d}", .{ prefix_or_suffix, number });
    defer runtime.allocator().free(text);
    return runtime.stringUtf8(text);
}

fn allocatedAroundString(runtime: *Runtime, number: i64, prefix: []const u8, suffix: []const u8) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator(), "{s}{d}{s}", .{ prefix, number, suffix });
    defer runtime.allocator().free(text);
    return runtime.stringUtf8(text);
}

fn parseDelimited(text: []const u8, delimiter: u8) ![3]i64 {
    var result = [_]i64{ 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, text, delimiter);
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= result.len) break;
        result[index] = parseIntPrefix(part) orelse 0;
        index += 1;
    }
    if (index == 0) return error.InvalidDatePart;
    return result;
}

fn parseIntPrefix(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    var negative = false;
    if (text[index] == '+' or text[index] == '-') {
        negative = text[index] == '-';
        index += 1;
    }
    const start = index;
    var value: i64 = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
        value = std.math.mul(i64, value, 10) catch return null;
        value = std.math.add(i64, value, text[index] - '0') catch return null;
    }
    if (index == start) return null;
    return if (negative) -value else value;
}

fn isUnsignedDecimal(text: []const u8) bool {
    if (text.len == 0) return false;
    var dot = false;
    for (text) |byte| {
        if (byte == '.' and !dot) {
            dot = true;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return text[0] != '.' and text[text.len - 1] != '.';
}

fn isTimeText(text: []const u8) bool {
    var separators: usize = 0;
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte == ':') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 1 or separators == 2;
}

fn looksDate(text: []const u8) bool {
    var separators: usize = 0;
    for (text) |byte| {
        if (byte == '/') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 2;
}

fn looksDateTime(text: []const u8) bool {
    const space = std.mem.indexOfAny(u8, text, " \t") orelse return false;
    return looksDate(text[0..space]) and isTimeText(std.mem.trim(u8, text[space..], " \t"));
}

fn isTwoToken(token: []const u8) bool {
    return eql(token, "YY") or eql(token, "MM") or eql(token, "DD") or eql(token, "HH") or eql(token, "mm") or eql(token, "ss");
}

fn matchToken(text: []const u8, index: usize, token: []const u8) bool {
    return index + token.len <= text.len and eql(text[index .. index + token.len], token);
}

fn floatToEpoch(value: f64) i64 {
    if (!std.math.isFinite(value)) return 0;
    const clipped = std.math.clamp(std.math.trunc(value), @as(f64, @floatFromInt(std.math.minInt(i64) + 1)), @as(f64, @floatFromInt(std.math.maxInt(i64))));
    return @intFromFloat(clipped);
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "Asia/Tokyoの日時変換・書式・加算を固定時計で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const context = Context{ .now_milliseconds = 1_735_689_845_678, .monotonic_milliseconds = 123.5 };
    const today = (try call(&runtime, "今日", &.{}, context)).?;
    const today_utf8 = try today.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(today_utf8);
    try std.testing.expectEqualStrings("2025/01/01", today_utf8);
    const formatted = (try call(&runtime, "日時書式変換", &.{ try runtime.stringUtf8("2024/02/29 03:04:05"), try runtime.stringUtf8("YYYY-MM-DD WWW HH:mm:ss") }, context)).?;
    const formatted_utf8 = try formatted.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(formatted_utf8);
    try std.testing.expectEqualStrings("2024-02-29 Thu 03:04:05", formatted_utf8);
}

test "旧形式plugin_datetimeの日付加算は月末をdayjs互換で丸める" {
    const original = constructLocal(2024, 0, 31, 0, 0, 0, 0, false);
    const parts = [_]i64{ 0, 1, 0 };
    const plugin_fields = fieldsFromEpoch(addDatePluginEpoch(original, parts, 1));
    try std.testing.expectEqual(@as(i64, 2024), plugin_fields.year);
    try std.testing.expectEqual(@as(i64, 2), plugin_fields.month);
    try std.testing.expectEqual(@as(i64, 29), plugin_fields.day);

    const system_fields = fieldsFromEpoch(addDateSystemEpoch(original, parts, 1));
    try std.testing.expectEqual(@as(i64, 2024), system_fields.year);
    try std.testing.expectEqual(@as(i64, 3), system_fields.month);
    try std.testing.expectEqual(@as(i64, 2), system_fields.day);
}
