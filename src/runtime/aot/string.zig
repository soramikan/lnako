const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const system_constant = shared.system_constant;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const isString = aot_state.isString;
const dictionaryProperty = aot_state.dictionaryProperty;
const invokeAotCallback = aot_state.invokeAotCallback;
const staticStringValue = aot_state.staticStringValue;
const parseIntBuiltin = aot_state.parseIntBuiltin;
const compareValues = aot_state.compareValues;
const explicitRangeNumber = aot_state.explicitRangeNumber;
const safe_array_element_limit = aot_state.safe_array_element_limit;

pub fn kanaOffsetBuiltin(runtime: *Runtime, value: Value, to_katakana: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    errdefer runtime.allocator.free(output);
    const first: u16 = if (to_katakana) 0x3041 else 0x30a1;
    const last: u16 = if (to_katakana) 0x3096 else 0x30f6;
    const offset: i32 = if (to_katakana) 0x60 else -0x60;
    for (output) |*unit| {
        if (unit.* >= first and unit.* <= last) unit.* = @intCast(@as(i32, unit.*) + offset);
    }
    return runtime.ownString(output);
}

pub fn asciiWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool, symbols: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    for (output) |*unit| {
        if (to_full) {
            if (symbols and unit.* == 0x20) {
                unit.* = 0x3000;
            } else if ((symbols and unit.* >= 0x21 and unit.* <= 0x7e) or
                (!symbols and ((unit.* >= 'A' and unit.* <= 'Z') or
                    (unit.* >= 'a' and unit.* <= 'z') or
                    (unit.* >= '0' and unit.* <= '9'))))
            {
                unit.* += 0xfee0;
            }
        } else if (symbols and unit.* == 0x3000) {
            unit.* = 0x20;
        } else if ((symbols and unit.* >= 0xff00 and unit.* <= 0xff5f) or
            (!symbols and ((unit.* >= 0xff21 and unit.* <= 0xff3a) or
                (unit.* >= 0xff41 and unit.* <= 0xff5a) or
                (unit.* >= 0xff10 and unit.* <= 0xff19))))
        {
            unit.* -= 0xfee0;
        }
    }
    return runtime.ownString(output);
}

pub fn kanaWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    return kanaMapBuiltin(runtime, value, to_full);
}

pub fn widthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    // 公式実装と同じく、全角化はカナ→英数記号、半角化もカナ→英数記号の順に行う。
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try kanaMapBuiltin(runtime, value, to_full);
    return asciiWidthBuiltin(runtime, roots[0], to_full, true);
}

pub fn currencyBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < units.len) {
        if (!isAsciiDigitBuiltin(units[index])) {
            try output.append(runtime.allocator, units[index]);
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and isAsciiDigitBuiltin(units[index])) : (index += 1) {}
        const end = index;
        // 公式の可変長後読みは、ドット直後の数字run全体を除外する。
        if (start > 0 and units[start - 1] == '.') {
            try output.appendSlice(runtime.allocator, units[start..end]);
            continue;
        }
        var group = (end - start) % 3;
        if (group == 0) group = 3;
        var cursor = start;
        while (cursor < end) {
            const next = std.math.add(usize, cursor, @min(end - cursor, group)) catch return error.StringTooLarge;
            try output.appendSlice(runtime.allocator, units[cursor..next]);
            cursor = next;
            if (cursor < end) try output.append(runtime.allocator, ',');
            group = 3;
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn padBuiltin(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const original_number = switch (@as(Tag, @enumFromInt(width_value.tag))) {
        .bigint => width_value.object().?.payload.bigint.toF64(),
        else => try valueToNumberRuntime(runtime, width_value),
    };
    const parsed = try parseIntBuiltin(runtime, width_value);
    // 公式はparseInt前に `for (i = 0; i < A; i++)` で埋め文字を作る。
    // したがってAが数値化不能でも、parseInt後の幅とは別に1文字が残る。
    const fill_count = if (std.math.isNan(original_number) or original_number <= 0) @as(usize, 1) else blk: {
        // 正のInfinityでは公式のループが終了しないため、AOTでは安全に拒否する。
        // 実際の割当失敗とは別の境界として呼び出し側へ伝える。
        if (!std.math.isFinite(original_number)) return error.StringPadWidthUnbounded;
        if (original_number >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.OutOfMemory;
        const iterations: usize = @intFromFloat(@ceil(original_number));
        break :blk iterations + 1;
    };
    if (std.math.isNan(parsed)) {
        const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
        const output = try runtime.allocator.alloc(u16, source_len);
        errdefer runtime.allocator.free(output);
        @memset(output[0..fill_count], fill);
        @memcpy(output[fill_count..], units);
        return runtime.ownString(output);
    }
    const requested: usize = if (parsed <= 0) 0 else blk: {
        if (!std.math.isFinite(parsed) or parsed >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.OutOfMemory;
        break :blk @intFromFloat(@trunc(parsed));
    };
    const target = @max(units.len, requested);
    const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
    const result_len = @min(target, source_len);
    const output = try runtime.allocator.alloc(u16, result_len);
    errdefer runtime.allocator.free(output);
    const result_fill_count = result_len - units.len;
    @memset(output[0..result_fill_count], fill);
    @memcpy(output[result_fill_count..], units);
    return runtime.ownString(output);
}

pub fn stringPredicateBuiltin(runtime: *Runtime, value: Value, command: aot_builtin.Command) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const first = if (units.len == 0) 0 else units[0];
    const result = switch (command) {
        .hiragana_predicate => first >= 0x3041 and first <= 0x309f,
        .katakana_predicate => first >= 0x30a1 and first <= 0x30fa,
        .digit_predicate => isSequenceDigitBuiltin(first),
        .number_sequence_predicate => if (isString(value) and units.len == 0) false else numberSequenceBuiltin(units),
        else => unreachable,
    };
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
}

pub fn numberSequenceBuiltin(units: []const u16) bool {
    var index: usize = 0;
    if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
    while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
    if (index < units.len and (units[index] == '.' or units[index] == 0xff0e)) {
        index += 1;
        const fraction_start = index;
        while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
        if (index == fraction_start) return false;
        if (index < units.len and (units[index] == 'e' or units[index] == 'E' or units[index] == 0xff45 or units[index] == 0xff25)) {
            index += 1;
            if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
            const exponent_start = index;
            while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
            if (index == exponent_start) return false;
        }
    }
    // 公式正規表現は空文字列だけを別扱いにし、符号単独も受理する。
    return index == units.len;
}

pub fn isAsciiDigitBuiltin(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn isSequenceDigitBuiltin(unit: u16) bool {
    return isAsciiDigitBuiltin(unit) or (unit >= 0xff10 and unit <= 0xff19);
}

pub fn isSequenceSignBuiltin(unit: u16) bool {
    return unit == '+' or unit == '-' or unit == 0xff0b or unit == 0xff0d;
}

pub fn kanaMapBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    var roots = [_]Value{ value, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var allocated_source: ?[]u16 = null;
    defer if (allocated_source) |source| runtime.allocator.free(source);
    const source: []const u16 = blk: {
        if (isString(roots[0])) {
            allocated_source = try valueUtf16Alloc(runtime, roots[0]);
            break :blk allocated_source.?;
        }
        if (@as(Tag, @enumFromInt(roots[0].tag)) == .dictionary) {
            if (!to_full) return kanaMapDictionaryHalfWidthBuiltin(runtime, roots[0], &roots);
            const length = dictionaryProperty(roots[0], &.{ 'l', 'e', 'n', 'g', 't', 'h' });
            // `0 < s.length` uses JavaScript's abstract relational
            // comparison. Undefined/NaN therefore takes the empty path.
            if (try compareValues(runtime, .less, numberValue(0), length)) return kanaMapDictionaryFullWidthBuiltin(runtime, roots[0], length, &roots);
            break :blk &.{};
        }
        if (!to_full) switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaHalfWidthSplitNull,
            .undefined => return error.KatakanaHalfWidthSplitUndefined,
            else => return error.KatakanaHalfWidthSplitReceiver,
        };

        switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaFullWidthLengthNull,
            .undefined => return error.KatakanaFullWidthLengthUndefined,
            .array => {
                if (roots[0].object().?.payload.array.items.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .byte_buffer => {
                const buffer = roots[0].object().?.payload.byte_buffer;
                if (buffer.kind != .array_buffer and buffer.bytes.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .function => break :blk &.{},
            else => break :blk &.{},
        }
    };
    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (to_full) {
            const candidate_end = @min(source.len, index + 2);
            // The official implementation searches the half-width voiced table
            // with the two-unit candidate. This intentionally also maps a lone
            // dakuten/handakuten to the first matching voiced kana entry.
            if (indexOfUnitsBuiltin(half_voiced, source[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator, full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
            if (unitIndexBuiltin(half, source[index])) |half_index| {
                if (half_index < full.len) try output.append(runtime.allocator, full[half_index]);
            } else {
                try output.append(runtime.allocator, source[index]);
            }
        } else if (unitIndexBuiltin(full, source[index])) |full_index| {
            try output.append(runtime.allocator, half[full_index]);
        } else if (unitIndexBuiltin(full_voiced, source[index])) |voiced_index| {
            try output.append(runtime.allocator, half_voiced[voiced_index * 2]);
            try output.append(runtime.allocator, half_voiced[voiced_index * 2 + 1]);
        } else {
            try output.append(runtime.allocator, source[index]);
        }
        index += 1;
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn kanaMapDictionaryFullWidthBuiltin(runtime: *Runtime, source: Value, length: Value, roots: []Value) !Value {
    const length_number = try explicitRangeNumber(runtime, length);
    if (!std.math.isFinite(length_number) or length_number > @as(f64, @floatFromInt(safe_array_element_limit))) return error.ArraySizeLimitExceeded;
    const iterations: usize = @intFromFloat(@ceil(length_number));

    roots[1] = dictionaryProperty(source, &.{ 's', 'u', 'b', 's', 't', 'r', 'i', 'n', 'g' });
    roots[2] = dictionaryProperty(source, &.{ 'c', 'h', 'a', 'r', 'A', 't' });
    if (roots[1].tag != @intFromEnum(Tag.function)) return error.KatakanaFullWidthSubstringReceiver;
    if (roots[2].tag != @intFromEnum(Tag.function)) return error.KatakanaFullWidthCharAtReceiver;

    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var arguments = [_]Value{ numberValue(0), numberValue(2) };
    roots[3] = arguments[0];
    roots[4] = arguments[1];
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        arguments[0] = numberValue(@floatFromInt(index));
        arguments[1] = numberValue(@floatFromInt(index + 2));
        roots[3] = arguments[0];
        roots[4] = arguments[1];
        roots[5] = try invokeAotCallback(runtime, roots[1], &arguments, arguments.len);
        const candidate = try valueUtf16Alloc(runtime, roots[5]);
        defer runtime.allocator.free(candidate);
        if (indexOfUnitsBuiltin(half_voiced, candidate, 0)) |position| {
            try output.append(runtime.allocator, full_voiced[position / 2]);
            index += 1;
            continue;
        }

        arguments[0] = numberValue(@floatFromInt(index));
        roots[3] = arguments[0];
        roots[5] = try invokeAotCallback(runtime, roots[2], arguments[0..1].ptr, 1);
        const character = try valueUtf16Alloc(runtime, roots[5]);
        defer runtime.allocator.free(character);
        if (indexOfUnitsBuiltin(half, character, 0)) |position| {
            if (position < full.len) try output.append(runtime.allocator, full[position]);
        } else try output.appendSlice(runtime.allocator, character);
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn kanaMapDictionaryHalfWidthBuiltin(runtime: *Runtime, source: Value, roots: []Value) !Value {
    roots[1] = dictionaryProperty(source, &.{ 's', 'p', 'l', 'i', 't' });
    if (roots[1].tag != @intFromEnum(Tag.function)) return error.KatakanaHalfWidthSplitReceiver;
    roots[2] = try invokeAotCallback(runtime, roots[1], @ptrCast(&[_]Value{staticStringValue("")}), 1);
    if (roots[2].tag != @intFromEnum(Tag.array)) return error.KatakanaHalfWidthMapReceiver;

    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    const items = &roots[2].object().?.payload.array;
    for (items.items, 0..) |value, index| {
        if (!runtime.aotArrayIsPresent(roots[2].object().?, index)) continue;
        roots[3] = value;
        const character = try valueUtf16Alloc(runtime, roots[3]);
        defer runtime.allocator.free(character);
        if (indexOfUnitsBuiltin(full, character, 0)) |position| {
            if (position < half.len) try output.append(runtime.allocator, half[position]);
        } else if (indexOfUnitsBuiltin(full_voiced, character, 0)) |position| {
            const start = position * 2;
            if (start + 2 <= half_voiced.len) try output.appendSlice(runtime.allocator, half_voiced[start .. start + 2]);
        } else if (roots[3].tag != @intFromEnum(Tag.undefined) and roots[3].tag != @intFromEnum(Tag.null_value)) {
            try output.appendSlice(runtime.allocator, character);
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn unitIndexBuiltin(units: []const u16, needle: u16) ?usize {
    for (units, 0..) |unit, index| if (unit == needle) return index;
    return null;
}

pub fn indexOfUnitsBuiltin(haystack: []const u16, needle: []const u16, start: usize) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.mem.eql(u16, haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

pub fn replaceBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value, replacement_value: Value, all: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    // split(undefined) returns the source as its sole element, so join never
    // observes the replacement separator. replace(undefined, ...) still
    // searches for the literal string "undefined" and must use the path below.
    if (all and needle_value.tag == @intFromEnum(Tag.undefined)) return runtime.createString(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var allocated_replacement: ?[]u16 = null;
    const replacement: []const u16 = if (all and replacement_value.tag == @intFromEnum(Tag.undefined))
        // Array.prototype.join(undefined) uses its default comma separator.
        &.{','}
    else blk: {
        allocated_replacement = try valueUtf16Alloc(runtime, replacement_value);
        break :blk allocated_replacement.?;
    };
    defer if (allocated_replacement) |allocated| runtime.allocator.free(allocated);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (!all) {
        const found = std.mem.indexOf(u16, source, needle) orelse return runtime.createString(source);
        try output.appendSlice(runtime.allocator, source[0..found]);
        try appendFirstReplacementBuiltin(runtime, &output, source, found, found + needle.len, replacement);
        try output.appendSlice(runtime.allocator, source[found + needle.len ..]);
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    if (needle.len == 0) {
        for (source, 0..) |unit, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, replacement);
            try output.append(runtime.allocator, unit);
        }
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        try output.appendSlice(runtime.allocator, source[start..found]);
        try output.appendSlice(runtime.allocator, replacement);
        start = found + needle.len;
    }
    try output.appendSlice(runtime.allocator, source[start..]);
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn appendFirstReplacementBuiltin(runtime: *Runtime, output: *std.ArrayList(u16), source: []const u16, match_start: usize, match_end: usize, replacement: []const u16) !void {
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try output.append(runtime.allocator, replacement[index]);
            index += 1;
            continue;
        }
        switch (replacement[index + 1]) {
            '$' => try output.append(runtime.allocator, '$'),
            '&' => try output.appendSlice(runtime.allocator, source[match_start..match_end]),
            '`' => try output.appendSlice(runtime.allocator, source[0..match_start]),
            '\'' => try output.appendSlice(runtime.allocator, source[match_end..]),
            else => {
                try output.append(runtime.allocator, '$');
                index += 1;
                continue;
            },
        }
        index += 2;
    }
}
