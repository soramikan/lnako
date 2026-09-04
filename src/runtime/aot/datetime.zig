const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const BigInt = state.BigInt;
const numberValue = state.numberValue;
const numberString = state.numberString;
const valueToNumber = state.valueToNumber;
const valueToNumberRuntime = state.valueToNumberRuntime;
const valueUtf16Alloc = state.valueUtf16Alloc;
const runtimeUtf8String = state.runtimeUtf8String;
const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
const arrayAppendBuiltin = state.arrayAppendBuiltin;
const staticStringValue = state.staticStringValue;
const toml_temporal = state.toml_temporal;
const string_mod = shared.string_mod;
const time = state.time;

pub fn eraDataBuiltin(runtime: *Runtime) !Value {
    if (runtime.era_data.tag != @intFromEnum(Tag.undefined)) return runtime.era_data;

    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (era_data) |era| {
        roots[1] = try runtime.createDictionary(&.{});
        roots[2] = try runtimeUtf8String(runtime, "元号");
        roots[3] = try runtimeUtf8String(runtime, era.name);
        try runtime.setDictionary(&roots[1].object().?.payload.dictionary, roots[2], roots[3]);
        roots[2] = try runtimeUtf8String(runtime, "改元日");
        roots[4] = try runtimeUtf8String(runtime, era.date);
        try runtime.setDictionary(&roots[1].object().?.payload.dictionary, roots[2], roots[4]);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    runtime.era_data = roots[0];
    return roots[0];
}
const AotEra = struct { name: []const u8, date: []const u8 };

const era_data = [_]AotEra{
    .{ .name = "令和", .date = "2019/05/01" },
    .{ .name = "平成", .date = "1989/01/08" },
    .{ .name = "昭和", .date = "1926/12/25" },
    .{ .name = "大正", .date = "1912/07/30" },
    .{ .name = "明治", .date = "1868/10/23" },
};
const datetime_milliseconds_per_second: i64 = 1000;
const datetime_milliseconds_per_minute: i64 = 60 * datetime_milliseconds_per_second;
const datetime_milliseconds_per_hour: i64 = 60 * datetime_milliseconds_per_minute;
const datetime_milliseconds_per_day: i64 = 24 * datetime_milliseconds_per_hour;
const datetime_tokyo_offset_milliseconds: i64 = 9 * datetime_milliseconds_per_hour;

const AotDateFields = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millisecond: i64,
    weekday: u8,
};

const AotDateDifferenceUnit = enum { year, month, day, hour, minute, second };

pub fn datetimeBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const now = currentTimeMilliseconds(runtime);
    return switch (command) {
        .datetime_now => datetimeTimeString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_system_time => numberValue(@floor(@as(f64, @floatFromInt(now)) / datetime_milliseconds_per_second)),
        .datetime_system_time_milliseconds => numberValue(@as(f64, @floatFromInt(now))),
        .datetime_today => datetimeDateString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_tomorrow => datetimeDateString(runtime, datetimeFieldsFromEpoch(now + datetime_milliseconds_per_day)),
        .datetime_yesterday => datetimeDateString(runtime, datetimeFieldsFromEpoch(now - datetime_milliseconds_per_day)),
        .datetime_current_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year))),
        .datetime_next_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year + 1))),
        .datetime_last_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year - 1))),
        .datetime_current_month => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).month))),
        .datetime_next_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month, 12) + 1))),
        .datetime_previous_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month + 10, 12) + 1))),
        .datetime_weekday => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeWeekdayName(runtime, try datetimeParseDate(runtime, arguments[0], now)),
        .datetime_weekday_number => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeWeekdayNumber(runtime, arguments[0]),
        .datetime_unix_time => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            numberValue(try datetimeParseDate(runtime, arguments[0], now) / datetime_milliseconds_per_second),
        .datetime_date_time => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeDateTimeString(runtime, try valueToNumberRuntime(runtime, arguments[0]) * datetime_milliseconds_per_second),
        .datetime_format => if (arguments.len < 2)
            error.InvalidArgumentCount
        else
            datetimeFormatCustom(runtime, try datetimeParseDate(runtime, arguments[0], now), arguments[1]),
        .datetime_era => if (arguments.len < 1)
            error.InvalidArgumentCount
        else
            datetimeJapaneseEra(runtime, try datetimeParseDate(runtime, arguments[0], now)),
        .datetime_year_difference => datetimeDifferenceBuiltin(runtime, .year, arguments, now),
        .datetime_month_difference => datetimeDifferenceBuiltin(runtime, .month, arguments, now),
        .datetime_day_difference => datetimeDifferenceBuiltin(runtime, .day, arguments, now),
        .datetime_hour_difference => datetimeDifferenceBuiltin(runtime, .hour, arguments, now),
        .datetime_minute_difference => datetimeDifferenceBuiltin(runtime, .minute, arguments, now),
        .datetime_second_difference => datetimeDifferenceBuiltin(runtime, .second, arguments, now),
        .datetime_difference => if (arguments.len < 3)
            error.InvalidArgumentCount
        else
            datetimeDifferenceWithUnitBuiltin(runtime, arguments, now),
        .datetime_add_time => datetimeAddTimeBuiltin(runtime, arguments, now),
        .datetime_add_date => datetimeAddDateBuiltin(runtime, arguments, now),
        .datetime_add_datetime => datetimeAddDateTimeBuiltin(runtime, arguments, now),
        .datetime_monotonic_milliseconds => numberValue(monotonicTimeMilliseconds(runtime)),
        else => error.UnknownCommand,
    };
}

pub fn currentTimeMilliseconds(runtime: *Runtime) i64 {
    if (runtime.clock_milliseconds) |value| return value;
    if (std.c.getenv("LNAKO_TEST_NOW_MS")) |environment| {
        return std.fmt.parseInt(i64, std.mem.span(environment), 10) catch hostWallClockMilliseconds();
    }
    return hostWallClockMilliseconds();
}

pub fn datetimePluginRouteEnabled() bool {
    const route = std.c.getenv("LNAKO_PLUGIN_ROUTE") orelse return false;
    return std.mem.eql(u8, std.mem.span(route), "plugin_datetime");
}

pub fn hostWallClockMilliseconds() i64 {
    const seconds = time(null);
    return std.math.mul(i64, seconds, datetime_milliseconds_per_second) catch if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub fn datetimeFieldsFromEpoch(milliseconds: i64) AotDateFields {
    const local = milliseconds + datetime_tokyo_offset_milliseconds;
    const days = @divFloor(local, datetime_milliseconds_per_day);
    const within_day = @mod(local, datetime_milliseconds_per_day);
    const civil = datetimeCivilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @divTrunc(within_day, datetime_milliseconds_per_hour),
        .minute = @divTrunc(@mod(within_day, datetime_milliseconds_per_hour), datetime_milliseconds_per_minute),
        .second = @divTrunc(@mod(within_day, datetime_milliseconds_per_minute), datetime_milliseconds_per_second),
        .millisecond = @mod(within_day, datetime_milliseconds_per_second),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

pub fn datetimeValueUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn datetimeParseDate(runtime: *Runtime, source: Value, now: i64) !f64 {
    const utf8 = try datetimeValueUtf8Alloc(runtime, source);
    defer runtime.allocator.free(utf8);
    const text = std.mem.trim(u8, utf8, " \t\r\n");
    if (datetimeIsUnsignedDecimal(text)) return std.math.trunc((std.fmt.parseFloat(f64, text) catch return std.math.nan(f64)) * 1000);
    if (datetimeIsTimeText(text)) {
        const parts = try datetimeParseDelimited(text, ':');
        const today = datetimeFieldsFromEpoch(now);
        return @floatFromInt(datetimeConstructLocal(today.year, today.month - 1, today.day, parts[0], parts[1], parts[2], 0, true));
    }
    const normalized = try runtime.allocator.dupe(u8, text);
    defer runtime.allocator.free(normalized);
    for (normalized) |*byte| if (byte.* == ' ' or byte.* == ':' or byte.* == '-' or byte.* == 'T') {
        byte.* = '/';
    };
    var parts = [_]i64{ 0, 0, 0, 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, normalized, '/');
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= parts.len) break;
        parts[index] = datetimeParseIntPrefix(part) orelse return std.math.nan(f64);
        index += 1;
    }
    if (index < 3) return std.math.nan(f64);
    return @floatFromInt(datetimeConstructLocal(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5], 0, true));
}

pub fn datetimeWeekdayName(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return runtimeUtf8String(runtime, "日");
    const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
    return runtimeUtf8String(runtime, names[datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds)).weekday]);
}

pub fn datetimeWeekdayNumber(runtime: *Runtime, source: Value) !Value {
    const text = try datetimeValueUtf8Alloc(runtime, source);
    defer runtime.allocator.free(text);
    var iterator = std.mem.splitScalar(u8, text, '/');
    const year = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    const month = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    const day = datetimeParseIntPrefix(iterator.next() orelse return numberValue(std.math.nan(f64))) orelse return numberValue(std.math.nan(f64));
    return numberValue(@floatFromInt(datetimeFieldsFromEpoch(datetimeConstructLocal(year, month - 1, day, 0, 0, 0, 0, true)).weekday));
}

pub fn datetimeConstructLocal(year_input: i64, month_zero_input: i64, day: i64, hour: i64, minute: i64, second: i64, millisecond: i64, constructor_year_rule: bool) i64 {
    var year = year_input;
    if (constructor_year_rule and year >= 0 and year <= 99) year += 1900;
    year += @divFloor(month_zero_input, 12);
    const month_zero = @mod(month_zero_input, 12);
    const days = datetimeDaysFromCivil(year, month_zero + 1, 1) + day - 1;
    return days * datetime_milliseconds_per_day + hour * datetime_milliseconds_per_hour + minute * datetime_milliseconds_per_minute + second * datetime_milliseconds_per_second + millisecond - datetime_tokyo_offset_milliseconds;
}

pub fn datetimeDaysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn datetimeParseDelimited(text: []const u8, delimiter: u8) ![3]i64 {
    var result = [_]i64{ 0, 0, 0 };
    var iterator = std.mem.splitScalar(u8, text, delimiter);
    var index: usize = 0;
    while (iterator.next()) |part| {
        if (index >= result.len) break;
        result[index] = datetimeParseIntPrefix(part) orelse 0;
        index += 1;
    }
    if (index == 0) return error.InvalidDatePart;
    return result;
}

pub fn datetimeParseIntPrefix(text: []const u8) ?i64 {
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

pub fn datetimeIsUnsignedDecimal(text: []const u8) bool {
    if (text.len == 0) return false;
    var dot = false;
    for (text) |byte| {
        if (byte == '.' and !dot) {
            dot = true;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return text[0] != '.' and text[text.len - 1] != '.';
}

pub fn datetimeIsTimeText(text: []const u8) bool {
    var separators: usize = 0;
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte == ':') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 1 or separators == 2;
}

pub fn datetimeFloatToEpoch(value: f64) i64 {
    if (!std.math.isFinite(value)) return 0;
    const clipped = std.math.clamp(std.math.trunc(value), @as(f64, @floatFromInt(std.math.minInt(i64) + 1)), @as(f64, @floatFromInt(std.math.maxInt(i64))));
    return @intFromFloat(clipped);
}

pub fn datetimeDateString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

pub fn datetimeTimeString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{:02}:{:02}:{:02}", .{ @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

pub fn datetimeDateTimeString(runtime: *Runtime, milliseconds: f64) !Value {
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02} {:02}:{:02}:{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)), @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

const AotDateOutputShape = enum { date_time, date, time };

pub fn datetimeFormatDateTimeFor(runtime: *Runtime, fields: AotDateFields, shape: AotDateOutputShape) !Value {
    return switch (shape) {
        .date => datetimeDateString(runtime, fields),
        .time => datetimeTimeString(runtime, fields),
        .date_time => blk: {
            const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02} {:02}:{:02}:{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)), @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
            defer runtime.allocator.free(text);
            break :blk runtimeUtf8String(runtime, text);
        },
    };
}

pub fn datetimeOutputShape(runtime: *Runtime, original: Value) !AotDateOutputShape {
    const text = try datetimeValueUtf8Alloc(runtime, original);
    defer runtime.allocator.free(text);
    if (datetimeLooksDateTime(text)) return .date_time;
    if (datetimeLooksDate(text)) return .date;
    if (datetimeIsTimeText(text)) return .time;
    return .date_time;
}

pub fn datetimeFormatCustom(runtime: *Runtime, milliseconds: f64, format_value: Value) !Value {
    if (!std.math.isFinite(milliseconds)) return runtimeUtf8String(runtime, "Invalid Date");
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const format = try datetimeValueUtf8Alloc(runtime, format_value);
    defer runtime.allocator.free(format);
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var index: usize = 0;
    while (index < format.len) {
        if (datetimeMatchToken(format, index, "YYYY")) {
            try output.writer.print("{d}", .{fields.year});
            index += 4;
        } else if (datetimeMatchToken(format, index, "ccc")) {
            try output.writer.print("{:03}", .{@as(u64, @intCast(fields.millisecond))});
            index += 3;
        } else if (datetimeMatchToken(format, index, "WWW")) {
            const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            try output.writer.writeAll(names[fields.weekday]);
            index += 3;
        } else if (datetimeMatchToken(format, index, "MMM")) {
            const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            try output.writer.writeAll(names[@intCast(fields.month - 1)]);
            index += 3;
        } else if (index + 2 <= format.len and datetimeIsTwoToken(format[index .. index + 2])) {
            const token = format[index .. index + 2];
            if (std.mem.eql(u8, token, "YY"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(@mod(fields.year, 100)))})
            else if (std.mem.eql(u8, token, "MM"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.month))})
            else if (std.mem.eql(u8, token, "DD"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.day))})
            else if (std.mem.eql(u8, token, "HH"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.hour))})
            else if (std.mem.eql(u8, token, "mm"))
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.minute))})
            else
                try output.writer.print("{:02}", .{@as(u64, @intCast(fields.second))});
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
    return runtimeUtf8String(runtime, output.written());
}

pub fn datetimeJapaneseEra(runtime: *Runtime, milliseconds: f64) !Value {
    if (!std.math.isFinite(milliseconds)) return error.InvalidDate;
    const fields = datetimeFieldsFromEpoch(datetimeFloatToEpoch(milliseconds));
    const day_number = datetimeDaysFromCivil(fields.year, fields.month, fields.day);
    for (era_data) |era| {
        const era_date = datetimeEraDateFields(era.date);
        if (day_number < datetimeDaysFromCivil(era_date.year, era_date.month, era_date.day)) continue;
        const era_year = fields.year - era_date.year + 1;
        const text = if (era_year == 1)
            try std.fmt.allocPrint(runtime.allocator, "{s}元年{:02}月{:02}日", .{ era.name, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) })
        else
            try std.fmt.allocPrint(runtime.allocator, "{s}{d}年{:02}月{:02}日", .{ era.name, era_year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
        defer runtime.allocator.free(text);
        return runtimeUtf8String(runtime, text);
    }
    return error.DateBeforeMeiji;
}

pub fn datetimeEraDateFields(date: []const u8) struct { year: i64, month: i64, day: i64 } {
    var iterator = std.mem.splitScalar(u8, date, '/');
    return .{
        .year = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
        .month = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
        .day = datetimeParseIntPrefix(iterator.next() orelse "0") orelse 0,
    };
}

pub fn datetimeDifferenceBuiltin(runtime: *Runtime, unit: AotDateDifferenceUnit, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const first = try datetimeParseDate(runtime, arguments[0], now);
    const second = try datetimeParseDate(runtime, arguments[1], now);
    if (unit == .year or unit == .month) {
        if (!std.math.isFinite(first) or !std.math.isFinite(second)) return numberValue(std.math.nan(f64));
        const left = datetimeFieldsFromEpoch(datetimeFloatToEpoch(first));
        const right = datetimeFieldsFromEpoch(datetimeFloatToEpoch(second));
        const difference = if (unit == .year)
            right.year - left.year
        else
            right.year * 12 + right.month - 1 - (left.year * 12 + left.month - 1);
        return numberValue(@floatFromInt(difference));
    }
    const first_seconds = @ceil(first / datetime_milliseconds_per_second);
    const second_seconds = @ceil(second / datetime_milliseconds_per_second);
    const divisor: f64 = switch (unit) {
        .day => 86400,
        .hour => 3600,
        .minute => 60,
        .second => 1,
        else => unreachable,
    };
    return numberValue(@ceil((second_seconds - first_seconds) / divisor));
}

pub fn datetimeDifferenceWithUnitBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    const unit = try datetimeDifferenceUnit(runtime, arguments[2]);
    return datetimeDifferenceBuiltin(runtime, unit, arguments[0..2], now);
}

pub fn datetimeDifferenceUnit(runtime: *Runtime, value: Value) !AotDateDifferenceUnit {
    const text = try datetimeValueUtf8Alloc(runtime, value);
    defer runtime.allocator.free(text);
    if (std.mem.eql(u8, text, "年")) return .year;
    if (std.mem.eql(u8, text, "月")) return .month;
    if (std.mem.eql(u8, text, "日")) return .day;
    if (std.mem.eql(u8, text, "時間")) return .hour;
    if (std.mem.eql(u8, text, "分")) return .minute;
    if (std.mem.eql(u8, text, "秒")) return .second;
    return error.UnknownDateUnit;
}

pub fn datetimeAddTimeBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    return datetimeAddTimeText(runtime, arguments[0], addition, now);
}

pub fn datetimeAddTimeText(runtime: *Runtime, source: Value, addition: []const u8, now: i64) !Value {
    var text = addition;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try datetimeParseDelimited(text, ':');
    const seconds = sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    const original = try datetimeParseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    return datetimeFormatDateTimeFor(runtime, datetimeFieldsFromEpoch(datetimeFloatToEpoch(original) + seconds * 1000), try datetimeOutputShape(runtime, source));
}

pub fn datetimeAddDateBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    return datetimeAddDateText(runtime, arguments[0], addition, now);
}

pub fn datetimeAddDateText(runtime: *Runtime, source: Value, addition: []const u8, now: i64) !Value {
    var text = addition;
    var sign: i64 = 1;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }
    const parts = try datetimeParseDelimited(text, '/');
    const original = try datetimeParseDate(runtime, source, now);
    if (!std.math.isFinite(original)) return error.InvalidDate;
    const original_epoch = datetimeFloatToEpoch(original);
    const epoch = if (datetimePluginRouteEnabled())
        datetimeAddDatePluginEpoch(original_epoch, parts, sign)
    else
        datetimeAddDateSystemEpoch(original_epoch, parts, sign);
    return datetimeFormatDateTimeFor(runtime, datetimeFieldsFromEpoch(epoch), try datetimeOutputShape(runtime, source));
}

pub fn datetimeAddDateSystemEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = datetimeFieldsFromEpoch(original);
    var epoch = datetimeConstructLocal(fields.year + parts[0] * sign, fields.month - 1, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = datetimeFieldsFromEpoch(epoch);
    epoch = datetimeConstructLocal(fields.year, fields.month - 1 + parts[1] * sign, fields.day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
    fields = datetimeFieldsFromEpoch(epoch);
    return datetimeConstructLocal(fields.year, fields.month - 1, fields.day + parts[2] * sign, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

/// The old-format `plugin_datetime` implementation delegates each component
/// to dayjs.  Calendar-unit additions therefore clamp to the last day of the
/// target month, unlike the system plugin's JavaScript Date overflow.
pub fn datetimeAddDatePluginEpoch(original: i64, parts: [3]i64, sign: i64) i64 {
    var fields = datetimeFieldsFromEpoch(original);
    var epoch = datetimeAddCalendarClamped(fields, parts[0] * sign, 0);
    fields = datetimeFieldsFromEpoch(epoch);
    epoch = datetimeAddCalendarClamped(fields, 0, parts[1] * sign);
    return epoch + parts[2] * sign * datetime_milliseconds_per_day;
}

pub fn datetimeAddCalendarClamped(fields: AotDateFields, year_delta: i64, month_delta: i64) i64 {
    const month_zero = fields.month - 1 + month_delta;
    const year = fields.year + year_delta + @divFloor(month_zero, 12);
    const normalized_month_zero = @mod(month_zero, 12);
    const day = @min(fields.day, datetimeDaysInMonth(year, normalized_month_zero + 1));
    return datetimeConstructLocal(year, normalized_month_zero, day, fields.hour, fields.minute, fields.second, fields.millisecond, false);
}

pub fn datetimeDaysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (datetimeIsLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn datetimeIsLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn datetimeAddDateTimeBuiltin(runtime: *Runtime, arguments: []const Value, now: i64) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    const addition = try datetimeValueUtf8Alloc(runtime, arguments[1]);
    defer runtime.allocator.free(addition);
    var text = addition;
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
    if (std.mem.eql(u8, unit, "年")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "/0/0", false);
    if (std.mem.eql(u8, unit, "ヶ月")) return datetimeAddDateTimeAround(runtime, arguments[0], now, amount, "0/", "/0", false);
    if (std.mem.eql(u8, unit, "週間")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount * 7, "0/0/", false);
    if (std.mem.eql(u8, unit, "日")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "0/0/", false);
    if (std.mem.eql(u8, unit, "時間")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, ":0:0", true);
    if (std.mem.eql(u8, unit, "分")) return datetimeAddDateTimeAround(runtime, arguments[0], now, amount, "0:", ":0", true);
    if (std.mem.eql(u8, unit, "秒")) return datetimeAddDateTimeWithAffix(runtime, arguments[0], now, amount, "0:0:", true);
    return error.InvalidDateAddition;
}

pub fn datetimeAddDateTimeWithAffix(runtime: *Runtime, source: Value, now: i64, amount: i64, prefix_or_suffix: []const u8, is_time: bool) !Value {
    const text = if (prefix_or_suffix.len > 0 and (prefix_or_suffix[0] == '/' or prefix_or_suffix[0] == ':'))
        try std.fmt.allocPrint(runtime.allocator, "{d}{s}", .{ amount, prefix_or_suffix })
    else
        try std.fmt.allocPrint(runtime.allocator, "{s}{d}", .{ prefix_or_suffix, amount });
    defer runtime.allocator.free(text);
    return if (is_time) datetimeAddTimeText(runtime, source, text, now) else datetimeAddDateText(runtime, source, text, now);
}

pub fn datetimeAddDateTimeAround(runtime: *Runtime, source: Value, now: i64, amount: i64, prefix: []const u8, suffix: []const u8, is_time: bool) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{s}{d}{s}", .{ prefix, amount, suffix });
    defer runtime.allocator.free(text);
    return if (is_time) datetimeAddTimeText(runtime, source, text, now) else datetimeAddDateText(runtime, source, text, now);
}

pub fn monotonicTimeMilliseconds(runtime: *Runtime) f64 {
    if (runtime.monotonic_milliseconds) |value| return value;
    if (std.c.getenv("LNAKO_TEST_MONOTONIC_MS")) |environment| {
        if (std.fmt.parseFloat(f64, std.mem.span(environment))) |value| return value else |_| {}
    }
    const timestamp = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
    return @as(f64, @floatFromInt(timestamp.nanoseconds)) / 1_000_000.0;
}

pub fn datetimeLooksDate(text: []const u8) bool {
    var separators: usize = 0;
    for (text) |byte| {
        if (byte == '/') separators += 1 else if (!std.ascii.isDigit(byte)) return false;
    }
    return separators == 2;
}

pub fn datetimeLooksDateTime(text: []const u8) bool {
    const space = std.mem.indexOfAny(u8, text, " \t") orelse return false;
    return datetimeLooksDate(text[0..space]) and datetimeIsTimeText(std.mem.trim(u8, text[space..], " \t"));
}

pub fn datetimeIsTwoToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "YY") or std.mem.eql(u8, token, "MM") or std.mem.eql(u8, token, "DD") or std.mem.eql(u8, token, "HH") or std.mem.eql(u8, token, "mm") or std.mem.eql(u8, token, "ss");
}

pub fn datetimeMatchToken(text: []const u8, index: usize, token: []const u8) bool {
    return index + token.len <= text.len and std.mem.eql(u8, text[index .. index + token.len], token);
}
pub fn datetimeCivilFromDays(days_input: i64) struct { year: i64, month: i64, day: i64 } {
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
