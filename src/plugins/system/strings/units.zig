const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const string_mod = @import("../../../runtime/string.zig");
const common = @import("../common.zig");
const operators = @import("../../../runtime/operators.zig");
const unicode_case = @import("unicode_case");
const arrays_plugin = @import("../arrays.zig");
const strings = @import("../strings.zig");
const Value = strings.Value;
const Runtime = strings.Runtime;
const Context = strings.Context;
const CutResult = strings.CutResult;

const cutting_mod = @import("cutting.zig");
const core_mod = @import("core.zig");
const search_replace_mod = @import("search_replace.zig");
const trim_case_mod = @import("trim_case.zig");
const kana_mod = @import("kana.zig");
const format_mod = @import("format.zig");
const units_mod = @import("units.zig");

pub fn numberSequence(units: []const u16) bool {
    var index: usize = 0;
    if (index < units.len and isSign(units[index])) index += 1;
    while (index < units.len and isDigit(units[index])) : (index += 1) {}
    var has_fraction = false;
    if (index < units.len and (units[index] == '.' or units[index] == 0xff0e)) {
        index += 1;
        const fraction_start = index;
        while (index < units.len and isDigit(units[index])) : (index += 1) {}
        if (index == fraction_start) return false;
        has_fraction = true;
    }
    if (index < units.len and (units[index] == 'e' or units[index] == 'E' or units[index] == 0xff45 or units[index] == 0xff25)) {
        // 指数表記は小数部がある場合だけを受理する（公式正規表現と同じ）。
        if (!has_fraction) return false;
        index += 1;
        if (index < units.len and isSign(units[index])) index += 1;
        const exponent_start = index;
        while (index < units.len and isDigit(units[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    // 空文字列だけを明示的に除外し、符号単独は公式正規表現の結果どおりtrue。
    return index == units.len;
}

pub fn isAsciiDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn codePointCount(units: []const u16) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (count += 1) index += codePointLength(units, index);
    return count;
}

pub fn codePointLength(units: []const u16, index: usize) usize {
    return if (index + 1 < units.len and units[index] >= 0xd800 and units[index] <= 0xdbff and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) 2 else 1;
}

pub fn codePointOffset(units: []const u16, target: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len and count < target) : (count += 1) index += codePointLength(units, index);
    return index;
}

/// Compare the same windows that `Array.from(source).slice(i, i +
/// needle.length).join('')` produces.  The window's width is measured in
/// Unicode scalar elements, while equality is still UTF-16 code-unit based;
/// this distinction prevents a lone surrogate from matching half of a pair.
/// Both offsets advance monotonically, avoiding an extra full prefix scan for
/// each candidate; equality retains the usual window-comparison cost.
pub fn findStringArrayWindow(haystack: []const u16, needle: []const u16) ?usize {
    if (haystack.len == 0) return null;
    const needle_count = codePointCount(needle);
    var end: usize = 0;
    var initial: usize = 0;
    while (initial < needle_count and end < haystack.len) : (initial += 1) end += codePointLength(haystack, end);

    var start: usize = 0;
    var scalar_index: usize = 0;
    while (start < haystack.len) : (scalar_index += 1) {
        if (std.mem.eql(u16, haystack[start..end], needle)) return scalar_index + 1;
        start += codePointLength(haystack, start);
        if (end < haystack.len) end += codePointLength(haystack, end);
    }
    return null;
}

// The upstream implementation deliberately applies Array.from to both
// operands, then compares String(array.slice(...)) values.  This is broader
// than the command's documentation: arrays, byte buffers, and objects with
// an own `length` property participate, while null/undefined fail as
// non-iterables.  Keep the sequence virtual so a large dictionary length does
// not allocate an intermediate array, and keep the original operands rooted
// while temporary core_mod.join strings are created under GC stress.
pub const raw_array_element_limit: usize = 1_000_000;

pub fn byteBufferOwnProperty(buffer: *value_mod.ByteBuffer, units: []const u16) ?Value {
    for (buffer.properties.items) |property| {
        if (std.mem.eql(u16, property.key.units, units)) return property.value;
    }
    return null;
}

pub fn byteBufferArrayLikeProperty(runtime: *Runtime, source: Value, units: []const u16) !Value {
    if (source == .bytes) {
        if (byteBufferOwnProperty(source.bytes, units)) |value| return value;
        if (try arrays_plugin.standardInheritedProperty(runtime, source, units)) |value| return value;
        if (std.mem.eql(u16, units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) and source.bytes.kind != .array_buffer) {
            return .{ .number = @floatFromInt(source.bytes.bytes.len) };
        }
    }
    return .undefined;
}

pub fn findRawArrayIndex(runtime: *Runtime, source: Value, needle: Value) !usize {
    const source_length = try rawArrayLength(runtime, source);
    const needle_length = try rawArrayLength(runtime, needle);
    const needle_joined = try rawArraySliceJoin(runtime, needle, 0, needle_length, needle_length);
    defer runtime.allocator().free(needle_joined);
    if (source_length == 0) return 0;

    var source_start: usize = 0;
    while (source_start < source_length) : (source_start += 1) {
        const source_joined = try rawArraySliceJoin(runtime, source, source_start, needle_length, source_length);
        defer runtime.allocator().free(source_joined);
        if (std.mem.eql(u16, source_joined, needle_joined)) return source_start + 1;
    }
    return 0;
}

pub fn rawArrayLength(runtime: *Runtime, value: Value) !usize {
    const length = switch (value) {
        .undefined => return error.RawArrayUndefinedNotIterable,
        .null_value => return error.RawArrayNullNotIterable,
        .string => |string| codePointCount(string.units),
        .array => |array| array.items.items.len,
        .bytes => |buffer| if (buffer.kind == .array_buffer) blk: {
            const length_value = try byteBufferArrayLikeProperty(runtime, value, &.{ 'l', 'e', 'n', 'g', 't', 'h' });
            const number = try runtime.valueToNumber(length_value);
            if (std.math.isNan(number) or number <= 0) break :blk 0;
            if (!std.math.isFinite(number)) return error.ArraySizeLimitExceeded;
            const floored = @floor(number);
            if (floored > @as(f64, @floatFromInt(raw_array_element_limit))) return error.ArraySizeLimitExceeded;
            break :blk @as(usize, @intFromFloat(floored));
        } else buffer.bytes.len,
        .dictionary => |dictionary| blk: {
            const length_value = value_mod.dictionaryPropertyUnits(dictionary, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) orelse .undefined;
            const number = try runtime.valueToNumber(length_value);
            if (std.math.isNan(number) or number <= 0) break :blk 0;
            if (!std.math.isFinite(number)) return error.ArraySizeLimitExceeded;
            const floored = @floor(number);
            if (floored > @as(f64, @floatFromInt(raw_array_element_limit))) return error.ArraySizeLimitExceeded;
            break :blk @as(usize, @intFromFloat(floored));
        },
        else => 0,
    };
    return length;
}

pub fn rawArraySliceJoin(runtime: *Runtime, source: Value, start: usize, requested_count: usize, length: usize) ![]u16 {
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    const end = @min(length, std.math.add(usize, start, requested_count) catch length);
    if (start >= end) return try runtime.allocator().dupe(u16, &.{});

    switch (source) {
        .string => |string| {
            const first = codePointOffset(string.units, start);
            const last = codePointOffset(string.units, end);
            try output.appendSlice(runtime.allocator(), string.units[first..last]);
        },
        else => {
            var index = start;
            while (index < end) : (index += 1) {
                try appendRawArrayElement(runtime, source, index, &output);
            }
        },
    }
    return try output.toOwnedSlice(runtime.allocator());
}

pub fn appendRawArrayElement(runtime: *Runtime, source: Value, index: usize, output: *std.ArrayList(u16)) !void {
    const element: Value = switch (source) {
        .array => |array| array.get(index),
        .bytes => |buffer| if (buffer.kind == .array_buffer) blk: {
            var key_buffer: [32]u8 = undefined;
            const key_text = std.fmt.bufPrint(&key_buffer, "{}", .{index}) catch return error.OutOfMemory;
            var key_units: [32]u16 = undefined;
            const key_len = std.unicode.utf8ToUtf16Le(&key_units, key_text) catch return error.OutOfMemory;
            break :blk try byteBufferArrayLikeProperty(runtime, source, key_units[0..key_len]);
        } else buffer.get(index),
        .dictionary => |dictionary| blk: {
            var key_buffer: [32]u8 = undefined;
            const key_text = std.fmt.bufPrint(&key_buffer, "{}", .{index}) catch return error.OutOfMemory;
            var key_units: [32]u16 = undefined;
            const key_len = std.unicode.utf8ToUtf16Le(&key_units, key_text) catch return error.OutOfMemory;
            break :blk value_mod.dictionaryPropertyUnits(dictionary, key_units[0..key_len]) orelse .undefined;
        },
        else => .undefined,
    };
    if (element == .undefined or element == .null_value) return;
    const text_value = try runtime.valueToString(element);
    try output.appendSlice(runtime.allocator(), text_value.string.units);
}

pub fn findCodePoints(haystack: []const u16, needle: []const u16, from_codepoint: usize) ?usize {
    var codepoint_index = from_codepoint;
    var unit_index = codePointOffset(haystack, from_codepoint);
    while (unit_index < haystack.len) {
        if (needle.len <= haystack.len - unit_index and std.mem.eql(u16, haystack[unit_index..][0..needle.len], needle)) return codepoint_index + 1;
        unit_index += codePointLength(haystack, unit_index);
        codepoint_index += 1;
    }
    return null;
}

pub fn searchCodePoints(haystack: []const u16, start_value: f64, needle: []const u16) f64 {
    var start = start_value;
    if (start <= 0) start = 1;
    var index = start - 1;
    const haystack_count = codePointCount(haystack);
    const needle_count = codePointCount(needle);
    while (index < @as(f64, @floatFromInt(haystack_count))) : (index += 1) {
        const scalar_index = collectionIndex(index, haystack_count);
        const unit_start = codePointOffset(haystack, scalar_index);
        const unit_end = codePointOffset(haystack, @min(haystack_count, scalar_index +| needle_count));
        if (std.mem.eql(u16, haystack[unit_start..unit_end], needle)) return index + 1;
    }
    return 0;
}

pub fn indexOfUnits(haystack: []const u16, needle: []const u16, start: usize) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.mem.eql(u16, haystack[index .. index + needle.len], needle)) return index;
    return null;
}

pub fn countOccurrences(haystack: []const u16, needle: []const u16) i64 {
    if (needle.len == 0) return @as(i64, @intCast(haystack.len)) - 1;
    var count: i64 = 0;
    var start: usize = 0;
    while (indexOfUnits(haystack, needle, start)) |found| {
        count += 1;
        start = found + needle.len;
    }
    return count;
}

pub fn startsWith(source: []const u16, prefix: []const u16) bool {
    return source.len >= prefix.len and std.mem.eql(u16, source[0..prefix.len], prefix);
}

pub fn endsWith(source: []const u16, suffix: []const u16) bool {
    return source.len >= suffix.len and std.mem.eql(u16, source[source.len - suffix.len ..], suffix);
}

pub fn oneBasedIndex(number: f64) usize {
    return if (std.math.isNan(number) or number <= 1) 0 else safeUsize(@trunc(number) - 1);
}

pub fn safeUsize(number: f64) usize {
    if (!std.math.isFinite(number) or number <= 0) return 0;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(number);
}

pub fn collectionIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(@trunc(number));
}

pub fn substringNumber(runtime: *Runtime, value: Value) !f64 {
    return if (value == .string) common.parseIntValue(runtime, value, null) else runtime.valueToNumber(value);
}

pub fn sliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    const length_number: f64 = @floatFromInt(length);
    if (number >= length_number) return length;
    if (number <= -length_number) return 0;
    if (number < 0) return length - @as(usize, @intFromFloat(-@trunc(number)));
    return @intFromFloat(@trunc(number));
}

pub fn spliceDeleteCount(number: f64, remaining: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(remaining))) return remaining;
    return @intFromFloat(@trunc(number));
}

pub fn firstUnit(value: *string_mod.String) u16 {
    return if (value.units.len > 0) value.units[0] else 0;
}

pub fn isDigit(unit: u16) bool {
    return (unit >= '0' and unit <= '9') or (unit >= 0xff10 and unit <= 0xff19);
}

pub fn isSign(unit: u16) bool {
    return unit == '+' or unit == '-' or unit == 0xff0b or unit == 0xff0d;
}

pub fn unitIndex(units: []const u16, needle: u16) ?usize {
    for (units, 0..) |unit, index| if (unit == needle) return index;
    return null;
}

pub fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}
