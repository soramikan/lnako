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

pub fn includes(runtime: *Runtime, source: Value, needle: Value) !bool {
    if (source == .array) {
        for (source.array.items.items) |item| if (Value.sameValueZero(item, needle)) return true;
        return false;
    }
    return units_mod.indexOfUnits((try core_mod.text(runtime, source)).units, (try core_mod.text(runtime, needle)).units, 0) != null;
}

pub fn replace(runtime: *Runtime, source: Value, search: Value, replacement: Value, all: bool) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_text = try runtime.valueToString(source);
    try roots.protect(&source_text);
    const units = source_text.string.units;
    // String.prototype.split(undefined) does not split, whereas
    // String.prototype.replace(undefined, ...) searches for "undefined".
    if (all and search == .undefined) return runtime.stringCodeUnits(units);
    var search_text = try runtime.valueToString(search);
    try roots.protect(&search_text);
    const needle = search_text.string.units;
    var replacement_text: Value = .undefined;
    const replacement_units: []const u16 = if (all and replacement == .undefined)
        // Array.prototype.join(undefined) uses its default comma separator.
        &.{','}
    else blk: {
        replacement_text = try runtime.valueToString(replacement);
        try roots.protect(&replacement_text);
        break :blk replacement_text.string.units;
    };
    if (needle.len == 0) {
        if (!all) return replaceFirst(runtime, units, 0, 0, replacement_units);
        var output: std.ArrayList(u16) = .empty;
        defer output.deinit(runtime.allocator());
        for (units, 0..) |unit, index| {
            if (index > 0) try output.appendSlice(runtime.allocator(), replacement_units);
            try output.append(runtime.allocator(), unit);
        }
        return runtime.stringCodeUnits(output.items);
    }
    if (!all) {
        const found = units_mod.indexOfUnits(units, needle, 0) orelse return runtime.stringCodeUnits(units);
        return replaceFirst(runtime, units, found, found + needle.len, replacement_units);
    }
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var start: usize = 0;
    while (units_mod.indexOfUnits(units, needle, start)) |found| {
        try output.appendSlice(runtime.allocator(), units[start..found]);
        try output.appendSlice(runtime.allocator(), replacement_units);
        start = found + needle.len;
    }
    try output.appendSlice(runtime.allocator(), units[start..]);
    return runtime.stringCodeUnits(output.items);
}

pub fn replaceFirst(runtime: *Runtime, source: []const u16, match_start: usize, match_end: usize, replacement: []const u16) !Value {
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    try output.appendSlice(runtime.allocator(), source[0..match_start]);
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try output.append(runtime.allocator(), replacement[index]);
            index += 1;
            continue;
        }
        switch (replacement[index + 1]) {
            '$' => try output.append(runtime.allocator(), '$'),
            '&' => try output.appendSlice(runtime.allocator(), source[match_start..match_end]),
            '`' => try output.appendSlice(runtime.allocator(), source[0..match_start]),
            '\'' => try output.appendSlice(runtime.allocator(), source[match_end..]),
            else => {
                try output.append(runtime.allocator(), '$');
                index += 1;
                continue;
            },
        }
        index += 2;
    }
    try output.appendSlice(runtime.allocator(), source[match_end..]);
    return runtime.stringCodeUnits(output.items);
}

pub fn insertUnits(runtime: *Runtime, source: []const u16, index: usize, addition: []const u16) !Value {
    var output = try runtime.allocator().alloc(u16, source.len + addition.len);
    defer runtime.allocator().free(output);
    @memcpy(output[0..index], source[0..index]);
    @memcpy(output[index .. index + addition.len], addition);
    @memcpy(output[index + addition.len ..], source[index..]);
    return runtime.stringCodeUnits(output);
}
