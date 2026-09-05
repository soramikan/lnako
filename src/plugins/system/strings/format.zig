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

pub fn currency(runtime: *Runtime, value: Value) !Value {
    const units = (try core_mod.text(runtime, value)).units;
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var index: usize = 0;
    while (index < units.len) {
        if (!units_mod.isAsciiDigit(units[index])) {
            try output.append(runtime.allocator(), units[index]);
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and units_mod.isAsciiDigit(units[index])) : (index += 1) {}
        const end = index;
        if (start > 0 and units[start - 1] == '.') {
            try output.appendSlice(runtime.allocator(), units[start..end]);
            continue;
        }
        var group = (end - start) % 3;
        if (group == 0) group = 3;
        var cursor = start;
        while (cursor < end) {
            const next = std.math.add(usize, cursor, @min(end - cursor, group)) catch return error.StringTooLarge;
            try output.appendSlice(runtime.allocator(), units[cursor..next]);
            cursor = next;
            if (cursor < end) try output.append(runtime.allocator(), ',');
            group = 3;
        }
    }
    return runtime.stringCodeUnits(output.items);
}

pub fn pad(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = (try core_mod.text(runtime, value)).units;
    const original_number = switch (width_value) {
        .bigint => |bigint| bigint.toF64(),
        else => try runtime.valueToNumber(width_value),
    };
    const width_number = try common.parseIntValue(runtime, width_value, null);
    const fill_count = if (std.math.isNan(original_number) or original_number <= 0) @as(usize, 1) else blk: {
        // A positive Infinity makes the official pre-parse loop non-terminating.
        // Keep that safety boundary distinct from an actual allocation failure.
        if (!std.math.isFinite(original_number)) return error.StringPadWidthUnbounded;
        if (original_number >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.OutOfMemory;
        break :blk @as(usize, @intFromFloat(@ceil(original_number))) + 1;
    };
    if (std.math.isNan(width_number)) {
        const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
        var output = try runtime.allocator().alloc(u16, source_len);
        @memset(output[0..fill_count], fill);
        @memcpy(output[fill_count..], units);
        defer runtime.allocator().free(output);
        return runtime.stringCodeUnits(output);
    }
    const requested = if (width_number <= 0) 0 else blk: {
        if (!std.math.isFinite(width_number) or width_number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.OutOfMemory;
        break :blk units_mod.safeUsize(@trunc(width_number));
    };
    const width = @max(units.len, requested);
    const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
    const result_len = @min(width, source_len);
    const output = try runtime.allocator().alloc(u16, result_len);
    defer runtime.allocator().free(output);
    const result_fill_count = result_len - units.len;
    @memset(output[0..result_fill_count], fill);
    @memcpy(output[result_fill_count..], units);
    return runtime.stringCodeUnits(output);
}
