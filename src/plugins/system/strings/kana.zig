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

pub fn mapKana(runtime: *Runtime, source: Value, to_full: bool, context: ?Context) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_root = source;
    try roots.protect(&source_root);

    const source_units: []const u16 = blk: {
        if (source_root == .string) break :blk source_root.string.units;
        if (source_root == .dictionary) {
            if (to_full) return mapKanaDictionaryFullWidth(runtime, source_root, context, &roots);
            return mapKanaDictionaryHalfWidth(runtime, source_root, context, &roots);
        }
        if (!to_full) break :blk switch (source_root) {
            .null_value => return error.KatakanaHalfWidthSplitNull,
            .undefined => return error.KatakanaHalfWidthSplitUndefined,
            else => return error.KatakanaHalfWidthSplitReceiver,
        };

        switch (source_root) {
            .null_value => return error.KatakanaFullWidthLengthNull,
            .undefined => return error.KatakanaFullWidthLengthUndefined,
            .array => |array| {
                if (array.items.items.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .dictionary => |dictionary| {
                var length_key = try runtime.stringUtf8("length");
                try roots.protect(&length_key);
                const length = dictionary.get(length_key.string) orelse .undefined;
                // `0 < s.length` is an abstract relational comparison in
                // JavaScript, rather than a strict numeric conversion.
                if (try operators.compare(runtime, .{ .number = 0 }, length)) |order| {
                    if (order == .lt) return error.KatakanaFullWidthSubstringReceiver;
                }
                break :blk &.{};
            },
            .bytes => |buffer| {
                if (buffer.kind != .array_buffer and buffer.bytes.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            // Nadesiko's generated wrapper functions have length 0.  The
            // internal callback arity is intentionally not observable here.
            .function => break :blk &.{},
            else => break :blk &.{},
        }
    };
    var full_string = try string_mod.String.fromUtf8(runtime.allocator(), full_kana);
    defer full_string.deinit();
    var half_string = try string_mod.String.fromUtf8(runtime.allocator(), half_kana);
    defer half_string.deinit();
    var full_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), full_voiced_kana);
    defer full_voiced_string.deinit();
    var half_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), half_voiced_kana);
    defer half_voiced_string.deinit();
    const full = full_string.units;
    const half = half_string.units;
    const full_voiced = full_voiced_string.units;
    const half_voiced = half_voiced_string.units;
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var index: usize = 0;
    while (index < source_units.len) {
        if (to_full) {
            const candidate_end = @min(source_units.len, index + 2);
            if (units_mod.indexOfUnits(half_voiced, source_units[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator(), full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
        }
        const unit = source_units[index];
        if (to_full) {
            if (units_mod.unitIndex(half, unit)) |position| {
                if (position < full.len) try output.append(runtime.allocator(), full[position]);
            } else try output.append(runtime.allocator(), unit);
        } else if (units_mod.unitIndex(full, unit)) |position| {
            try output.append(runtime.allocator(), half[position]);
        } else if (units_mod.unitIndex(full_voiced, unit)) |position| {
            try output.appendSlice(runtime.allocator(), half_voiced[position * 2 .. position * 2 + 2]);
        } else try output.append(runtime.allocator(), unit);
        index += 1;
    }
    return runtime.stringCodeUnits(output.items);
}

pub fn mapKanaDictionaryFullWidth(runtime: *Runtime, source: Value, context: ?Context, roots: *value_mod.RootFrame) !Value {
    const length = value_mod.dictionaryPropertyUnits(source.dictionary, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) orelse .undefined;
    var length_root = length;
    try roots.protect(&length_root);
    // The official loop is `while (i < s.length)`.  Keep the existing empty
    // receiver behavior, but once the receiver is non-empty resolve its
    // dynamic substring/charAt methods instead of treating it as a string.
    const positive = if (try operators.compare(runtime, .{ .number = 0 }, length_root)) |order| order == .lt else false;
    if (!positive) return runtime.stringCodeUnits(&.{});
    const length_number = try runtime.valueToExplicitRangeNumber(length_root);
    if (!std.math.isFinite(length_number) or length_number > @as(f64, @floatFromInt(units_mod.raw_array_element_limit))) return error.ArraySizeLimitExceeded;
    const iterations: usize = @intFromFloat(@ceil(length_number));

    var substring_method = value_mod.dictionaryPropertyUnits(source.dictionary, &.{ 's', 'u', 'b', 's', 't', 'r', 'i', 'n', 'g' }) orelse return error.KatakanaFullWidthSubstringReceiver;
    var char_at_method = value_mod.dictionaryPropertyUnits(source.dictionary, &.{ 'c', 'h', 'a', 'r', 'A', 't' }) orelse return error.KatakanaFullWidthCharAtReceiver;
    try roots.protect(&substring_method);
    try roots.protect(&char_at_method);
    if (substring_method != .function) return error.KatakanaFullWidthSubstringReceiver;
    if (char_at_method != .function) return error.KatakanaFullWidthCharAtReceiver;

    var full_string = try string_mod.String.fromUtf8(runtime.allocator(), full_kana);
    defer full_string.deinit();
    var half_string = try string_mod.String.fromUtf8(runtime.allocator(), half_kana);
    defer half_string.deinit();
    var full_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), full_voiced_kana);
    defer full_voiced_string.deinit();
    var half_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), half_voiced_kana);
    defer half_voiced_string.deinit();
    const full = full_string.units;
    const half = half_string.units;
    const full_voiced = full_voiced_string.units;
    const half_voiced = half_voiced_string.units;

    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var callback_result: Value = .undefined;
    var callback_text: Value = .undefined;
    var callback_arguments = [_]Value{ .{ .number = 0 }, .{ .number = 2 } };
    try roots.protect(&callback_result);
    try roots.protect(&callback_text);
    try roots.protect(&callback_arguments[0]);
    try roots.protect(&callback_arguments[1]);

    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        callback_arguments[0] = .{ .number = @floatFromInt(index) };
        callback_arguments[1] = .{ .number = @floatFromInt(index + 2) };
        callback_result = try Context.invoke(context, substring_method, &callback_arguments);
        callback_text = try runtime.valueToString(callback_result);
        const candidate = callback_text.string.units;
        if (units_mod.indexOfUnits(half_voiced, candidate, 0)) |position| {
            try output.append(runtime.allocator(), full_voiced[position / 2]);
            index += 1;
            continue;
        }

        callback_arguments[0] = .{ .number = @floatFromInt(index) };
        callback_result = try Context.invoke(context, char_at_method, callback_arguments[0..1]);
        callback_text = try runtime.valueToString(callback_result);
        const character = callback_text.string.units;
        if (units_mod.indexOfUnits(half, character, 0)) |position| {
            if (position < full.len) try output.append(runtime.allocator(), full[position]);
        } else try output.appendSlice(runtime.allocator(), character);
    }
    return runtime.stringCodeUnits(output.items);
}

pub fn mapKanaDictionaryHalfWidth(runtime: *Runtime, source: Value, context: ?Context, roots: *value_mod.RootFrame) !Value {
    var split_method = value_mod.dictionaryPropertyUnits(source.dictionary, &.{ 's', 'p', 'l', 'i', 't' }) orelse return error.KatakanaHalfWidthSplitReceiver;
    try roots.protect(&split_method);
    if (split_method != .function) return error.KatakanaHalfWidthSplitReceiver;

    var empty_separator = try runtime.stringUtf8("");
    try roots.protect(&empty_separator);
    var split_result = try Context.invoke(context, split_method, &.{empty_separator});
    try roots.protect(&split_result);
    if (split_result != .array) return error.KatakanaHalfWidthMapReceiver;

    var full_string = try string_mod.String.fromUtf8(runtime.allocator(), full_kana);
    defer full_string.deinit();
    var half_string = try string_mod.String.fromUtf8(runtime.allocator(), half_kana);
    defer half_string.deinit();
    var full_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), full_voiced_kana);
    defer full_voiced_string.deinit();
    var half_voiced_string = try string_mod.String.fromUtf8(runtime.allocator(), half_voiced_kana);
    defer half_voiced_string.deinit();
    const full = full_string.units;
    const half = half_string.units;
    const full_voiced = full_voiced_string.units;
    const half_voiced = half_voiced_string.units;

    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var item: Value = .undefined;
    var item_text: Value = .undefined;
    try roots.protect(&item);
    try roots.protect(&item_text);
    for (split_result.array.items.items, 0..) |value, index| {
        if (!split_result.array.isPresent(index)) continue;
        item = value;
        item_text = try runtime.valueToString(item);
        const character = item_text.string.units;
        if (units_mod.indexOfUnits(full, character, 0)) |position| {
            if (position < half.len) try output.append(runtime.allocator(), half[position]);
        } else if (units_mod.indexOfUnits(full_voiced, character, 0)) |position| {
            const start = position * 2;
            if (start + 2 <= half_voiced.len) try output.appendSlice(runtime.allocator(), half_voiced[start .. start + 2]);
        } else if (item != .undefined and item != .null_value) {
            try output.appendSlice(runtime.allocator(), character);
        }
    }
    return runtime.stringCodeUnits(output.items);
}

pub const full_kana = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンァィゥェォャュョッ、。ー「」";
pub const full_voiced_kana = "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポ";
pub const half_kana = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝｧｨｩｪｫｬｭｮｯ､｡ｰ｢｣ﾞﾟ";
pub const half_voiced_kana = "ｶﾞｷﾞｸﾞｹﾞｺﾞｻﾞｼﾞｽﾞｾﾞｿﾞﾀﾞﾁﾞﾂﾞﾃﾞﾄﾞﾊﾞﾋﾞﾌﾞﾍﾞﾎﾞﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ";
