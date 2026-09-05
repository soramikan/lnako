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

pub fn cut(runtime: *Runtime, source: Value, delimiter: Value) !CutResult {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_root = source;
    var delimiter_root = delimiter;
    try roots.protect(&source_root);
    try roots.protect(&delimiter_root);
    var source_text = try runtime.valueToString(source_root);
    try roots.protect(&source_text);
    var delimiter_text = try runtime.valueToString(delimiter_root);
    try roots.protect(&delimiter_text);
    const source_units = source_text.string.units;
    const delimiter_units = delimiter_text.string.units;
    const found = units_mod.indexOfUnits(source_units, delimiter_units, 0);
    if (found == null) return makeCutResult(runtime, source_units, &.{});
    const index = found.?;
    const end = try cutEndIndex(runtime, index, delimiter_root, source_units.len);
    const result_units = source_units[0..index];
    const remainder_units = source_units[end..];
    return makeCutResult(runtime, result_units, remainder_units);
}

pub fn cutRange(runtime: *Runtime, source: Value, first: Value, last: Value) !CutResult {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_root = source;
    var first_root = first;
    var last_root = last;
    try roots.protect(&source_root);
    try roots.protect(&first_root);
    try roots.protect(&last_root);
    var source_text = try runtime.valueToString(source_root);
    try roots.protect(&source_text);
    var first_text = try runtime.valueToString(first_root);
    try roots.protect(&first_text);
    const source_units = source_text.string.units;
    const first_units = first_text.string.units;
    const first_index = units_mod.indexOfUnits(source_units, first_units, 0) orelse return makeCutResult(runtime, &.{}, source_units);
    const middle_start = try cutEndIndex(runtime, first_index, first_root, source_units.len);
    // The official implementation does not even String-coerce or inspect the
    // second delimiter until the first delimiter has matched.
    var last_text = try runtime.valueToString(last_root);
    try roots.protect(&last_text);
    const last_units = last_text.string.units;
    const prefix = source_units[0..first_index];
    const last_relative = units_mod.indexOfUnits(source_units[middle_start..], last_units, 0);
    if (last_relative == null) return makeCutResult(runtime, source_units[middle_start..], prefix);
    const last_index = middle_start + last_relative.?;
    const last_end = middle_start + try cutEndIndex(runtime, last_relative.?, last_root, source_units.len - middle_start);
    const remainder_length = std.math.add(usize, prefix.len, source_units.len - last_end) catch return error.StringTooLarge;
    var remainder_units = try runtime.allocator().alloc(u16, remainder_length);
    defer runtime.allocator().free(remainder_units);
    @memcpy(remainder_units[0..prefix.len], prefix);
    @memcpy(remainder_units[prefix.len..], source_units[last_end..]);
    return makeCutResult(runtime, source_units[middle_start..last_index], remainder_units);
}

/// `切取` and `範囲切取` search with a String-coerced delimiter, but advance
/// with the original value's `.length`.  This intentionally keeps the two
/// operations separate: accessing `.length` on null/undefined throws only
/// after a match, while primitives such as numbers simply expose undefined.
pub fn cutEndIndex(runtime: *Runtime, match_index: usize, delimiter: Value, source_length: usize) !usize {
    const length = try cutLengthProperty(runtime, delimiter);
    const sum = try operators.binary(runtime, .add, .{ .number = @floatFromInt(match_index) }, length);
    const number = try runtime.valueToNumber(sum);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(source_length))) return source_length;
    return @intFromFloat(@trunc(number));
}

pub fn cutLengthProperty(runtime: *Runtime, value: Value) !Value {
    return switch (value) {
        .undefined => error.CutUndefinedDelimiterLength,
        .null_value => error.CutNullDelimiterLength,
        .string => |string| .{ .number = @floatFromInt(string.units.len) },
        .bytes => |buffer| if (buffer.kind == .array_buffer) .undefined else .{ .number = @floatFromInt(buffer.bytes.len) },
        .array => |array| .{ .number = @floatFromInt(array.items.items.len) },
        .function => |function| .{ .number = @floatFromInt(function.arity) },
        .dictionary => |dictionary| blk: {
            const key = try runtime.stringUtf8("length");
            break :blk dictionary.get(key.string) orelse .undefined;
        },
        else => .undefined,
    };
}

pub fn makeCutResult(runtime: *Runtime, result_units: []const u16, remainder_units: []const u16) !CutResult {
    var result = try runtime.stringCodeUnits(result_units);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const remainder = try runtime.stringCodeUnits(remainder_units);
    return .{ .result = result, .remainder = remainder };
}
