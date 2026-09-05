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

pub fn text(runtime: *Runtime, value: Value) !*string_mod.String {
    return (try runtime.valueToString(value)).string;
}

pub fn chr(runtime: *Runtime, value: Value) !Value {
    if (value == .array) {
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (value.array.items.items) |item| {
            const character = try codePointString(runtime, try runtime.valueToNumber(item));
            _ = try result.array.push(character);
        }
        return result;
    }
    return codePointString(runtime, try runtime.valueToNumber(value));
}

pub fn codePointString(runtime: *Runtime, number: f64) !Value {
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > 0x10ffff) {
        const number_text = try value_mod.numberToStringAlloc(runtime.allocator(), number);
        defer runtime.allocator().free(number_text);
        const message = try std.fmt.allocPrint(runtime.allocator(), "Invalid code point {s}", .{number_text});
        defer runtime.allocator().free(message);
        try runtime.setFailureMessage(message);
        return error.InvalidCodePoint;
    }
    const codepoint: u21 = @intFromFloat(number);
    if (codepoint <= 0xffff) return runtime.stringCodeUnits(&.{@intCast(codepoint)});
    const offset: u32 = codepoint - 0x10000;
    return runtime.stringCodeUnits(&.{ @intCast(0xd800 + (offset >> 10)), @intCast(0xdc00 + (offset & 0x3ff)) });
}

pub fn asc(runtime: *Runtime, value: Value) !Value {
    if (value == .array) {
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (value.array.items.items) |item| _ = try result.array.push(.{ .number = @floatFromInt((try text(runtime, item)).codePointAt(0) orelse 0) });
        return result;
    }
    return .{ .number = @floatFromInt((try text(runtime, value)).codePointAt(0) orelse 0) };
}

pub fn insert(runtime: *Runtime, source: Value, position: Value, addition: Value) !Value {
    const source_units = (try text(runtime, source)).units;
    const addition_units = (try text(runtime, addition)).units;
    var number = try runtime.valueToNumber(position);
    if (number <= 0) number = 1;
    const codepoint_index = units_mod.collectionIndex(number - 1, units_mod.codePointCount(source_units));
    const offset = units_mod.codePointOffset(source_units, codepoint_index);
    var output = try runtime.allocator().alloc(u16, source_units.len + addition_units.len);
    defer runtime.allocator().free(output);
    @memcpy(output[0..offset], source_units[0..offset]);
    @memcpy(output[offset .. offset + addition_units.len], addition_units);
    @memcpy(output[offset + addition_units.len ..], source_units[offset..]);
    return runtime.stringCodeUnits(output);
}

pub fn append(runtime: *Runtime, source: Value, addition: Value, source_text: Value, addition_text: Value, newline: bool) !Value {
    if (source == .array) {
        _ = try source.array.push(addition);
        return source;
    }
    var values = [_]Value{ source_text, addition_text, .undefined };
    if (!newline) return join(runtime, values[0..2]);
    values[2] = try runtime.stringUtf8("\n");
    return join(runtime, &values);
}

pub fn join(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator());
    for (values) |value| try units.appendSlice(runtime.allocator(), (try text(runtime, value)).units);
    return runtime.stringCodeUnits(units.items);
}

pub fn joinArguments(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator());
    for (values) |value| switch (value) {
        .undefined, .null_value => {},
        else => try units.appendSlice(runtime.allocator(), (try text(runtime, value)).units),
    };
    return runtime.stringCodeUnits(units.items);
}

pub fn explode(runtime: *Runtime, value: Value) !Value {
    const units = (try text(runtime, value)).units;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    var index: usize = 0;
    while (index < units.len) {
        const length = units_mod.codePointLength(units, index);
        const item = try runtime.stringCodeUnits(units[index .. index + length]);
        _ = try result.array.push(item);
        index += length;
    }
    return result;
}

pub fn repeat(runtime: *Runtime, value: Value, count_value: Value) !Value {
    const count_number = try runtime.valueToNumber(count_value);
    if (std.math.isNan(count_number) or count_number <= 0) return runtime.stringUtf8("");
    if (!std.math.isFinite(count_number)) return error.RepetitionTooLarge;
    const count = units_mod.safeUsize(@ceil(count_number));
    const units = (try text(runtime, value)).units;
    const length = std.math.mul(usize, units.len, count) catch return error.RepetitionTooLarge;
    var output = try runtime.allocator().alloc(u16, length);
    defer runtime.allocator().free(output);
    for (0..count) |index| @memcpy(output[index * units.len ..][0..units.len], units);
    return runtime.stringCodeUnits(output);
}

pub fn mid(runtime: *Runtime, source: Value, start_value: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const count_number = try units_mod.substringNumber(runtime, count_value);
    if (count_number <= 0) return runtime.stringUtf8("");
    var start_number = try units_mod.substringNumber(runtime, start_value);
    const length = units_mod.codePointCount(units);
    if (start_number < 0) {
        start_number = @as(f64, @floatFromInt(length)) + start_number + 1;
        if (start_number < 0) start_number = 1;
    }
    const start = units_mod.sliceIndex(start_number - 1, length);
    const end = units_mod.sliceIndex(start_number + count_number - 1, length);
    if (end <= start) return runtime.stringUtf8("");
    return runtime.stringCodeUnits(units[units_mod.codePointOffset(units, start)..units_mod.codePointOffset(units, end)]);
}

pub fn left(runtime: *Runtime, source: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const count = units_mod.sliceIndex(try runtime.valueToNumber(count_value), units_mod.codePointCount(units));
    return runtime.stringCodeUnits(units[0..units_mod.codePointOffset(units, count)]);
}

pub fn right(runtime: *Runtime, source: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const length = units_mod.codePointCount(units);
    var index_number = @as(f64, @floatFromInt(length)) - try runtime.valueToNumber(count_value);
    if (index_number < 0) index_number = 0;
    const index = units_mod.sliceIndex(index_number, length);
    return runtime.stringCodeUnits(units[units_mod.codePointOffset(units, index)..]);
}

pub fn splitAll(runtime: *Runtime, source: Value, separator: Value) !Value {
    const units = (try text(runtime, source)).units;
    const delimiter = (try text(runtime, separator)).units;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    if (delimiter.len == 0) {
        for (units) |unit| _ = try result.array.push(try runtime.stringCodeUnits(&.{unit}));
        return result;
    }
    var start: usize = 0;
    while (units_mod.indexOfUnits(units, delimiter, start)) |found| {
        _ = try result.array.push(try runtime.stringCodeUnits(units[start..found]));
        start = found + delimiter.len;
    }
    _ = try result.array.push(try runtime.stringCodeUnits(units[start..]));
    return result;
}

pub fn splitFirst(runtime: *Runtime, source: Value, separator: Value) !Value {
    const units = (try text(runtime, source)).units;
    const delimiter = (try text(runtime, separator)).units;
    const found = units_mod.indexOfUnits(units, delimiter, 0);
    if (found) |index| return common.arrayFromValues(runtime, &.{ try runtime.stringCodeUnits(units[0..index]), try runtime.stringCodeUnits(units[index + delimiter.len ..]) });
    return common.arrayFromValues(runtime, &.{try runtime.stringCodeUnits(units)});
}

pub fn remove(runtime: *Runtime, source: Value, start_value: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const length = units_mod.codePointCount(units);
    const start = units_mod.sliceIndex(try runtime.valueToNumber(start_value) - 1, length);
    const count = units_mod.spliceDeleteCount(try runtime.valueToNumber(count_value), length - start);
    const first = units_mod.codePointOffset(units, start);
    const last = units_mod.codePointOffset(units, start + count);
    var output = try runtime.allocator().alloc(u16, units.len - (last - first));
    defer runtime.allocator().free(output);
    @memcpy(output[0..first], units[0..first]);
    @memcpy(output[first..], units[last..]);
    return runtime.stringCodeUnits(output);
}
