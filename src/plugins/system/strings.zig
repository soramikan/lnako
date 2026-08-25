const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const string_mod = @import("../../runtime/string.zig");
const common = @import("common.zig");
const unicode_case = @import("../../generated/unicode_case.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const CutResult = struct { result: Value, remainder: Value };

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    // 後段プラグインがBufferなど非文字列値を受け取る場合があるため、
    // このモジュールが担当しない命令の引数は先に文字列化しない。
    if (!handles(name)) return null;
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    const c = common.argument(arguments, 2);
    if (eql(name, "文字始") or eql(name, "文字終")) try requireStringReceiver(a, eql(name, "文字始"));
    var text_roots = runtime.rootFrame();
    defer text_roots.deinit();
    var a_root = a;
    var b_root = b;
    var c_root = c;
    try text_roots.protect(&a_root);
    try text_roots.protect(&b_root);
    try text_roots.protect(&c_root);
    var a_text = try runtime.valueToString(a);
    try text_roots.protect(&a_text);
    var b_text = try runtime.valueToString(b);
    try text_roots.protect(&b_text);
    var c_text = try runtime.valueToString(c);
    try text_roots.protect(&c_text);
    if (eql(name, "文字数")) return .{ .number = @floatFromInt(codePointCount(a_text.string.units)) };
    if (eql(name, "何文字目")) return .{ .number = @floatFromInt(findCodePoints(a_text.string.units, b_text.string.units, 0) orelse return Value{ .number = 0 }) };
    if (eql(name, "CHR")) return try chr(runtime, a);
    if (eql(name, "ASC")) return try asc(runtime, a);
    if (eql(name, "文字挿入")) return try insert(runtime, a_text, b, c_text);
    if (eql(name, "文字検索")) {
        return .{ .number = searchCodePoints(a_text.string.units, try runtime.valueToNumber(b), c_text.string.units) };
    }
    if (eql(name, "追加") or eql(name, "一行追加")) return try append(runtime, a, b, a_text, b_text, eql(name, "一行追加"));
    if (eql(name, "連結") or eql(name, "文字列連結")) return try joinArguments(runtime, arguments);
    if (eql(name, "文字列分解")) return try explode(runtime, a_text);
    if (eql(name, "リフレイン")) return try repeat(runtime, a_text, b);
    if (eql(name, "出現回数")) return .{ .number = @floatFromInt(countOccurrences(a_text.string.units, b_text.string.units)) };
    if (eql(name, "MID") or eql(name, "文字抜出")) return try mid(runtime, a_text, b, c);
    if (eql(name, "LEFT") or eql(name, "文字左部分")) return try left(runtime, a_text, b);
    if (eql(name, "RIGHT") or eql(name, "文字右部分")) return try right(runtime, a_text, b);
    if (eql(name, "区切")) return try splitAll(runtime, a_text, b_text);
    if (eql(name, "文字列分割")) return try splitFirst(runtime, a_text, b_text);
    if (eql(name, "文字削除")) return try remove(runtime, a_text, b, c);
    if (eql(name, "文字始")) return .{ .boolean = startsWith(a_text.string.units, b_text.string.units) };
    if (eql(name, "文字終")) return .{ .boolean = endsWith(a_text.string.units, b_text.string.units) };
    if (eql(name, "出現")) return .{ .boolean = if (a == .array) try includes(runtime, a, b) else indexOfUnits(a_text.string.units, b_text.string.units, 0) != null };
    if (eql(name, "置換")) return try replace(runtime, a, b, c, true);
    if (eql(name, "単置換")) return try replace(runtime, a, b, c, false);
    if (eql(name, "トリム") or eql(name, "空白除去")) return try trim(runtime, a_text, true, true);
    if (eql(name, "右トリム") or eql(name, "末尾空白除去")) return try trim(runtime, a_text, false, true);
    if (eql(name, "左トリム")) return try trim(runtime, a_text, true, false);
    if (eql(name, "大文字変換")) return try unicodeCase(runtime, a_text, true);
    if (eql(name, "小文字変換")) return try unicodeCase(runtime, a_text, false);
    if (eql(name, "平仮名変換")) return try offsetRange(runtime, a_text, 0x30a1, 0x30f6, -0x60);
    if (eql(name, "カタカナ変換")) return try offsetRange(runtime, a_text, 0x3041, 0x3096, 0x60);
    if (eql(name, "英数全角変換")) return try asciiFullWidth(runtime, a_text, false);
    if (eql(name, "英数半角変換")) return try fullWidthAscii(runtime, a_text, false);
    if (eql(name, "英数記号全角変換")) return try asciiFullWidth(runtime, a_text, true);
    if (eql(name, "英数記号半角変換")) return try fullWidthAscii(runtime, a_text, true);
    if (eql(name, "カタカナ全角変換")) return try katakanaFullWidth(runtime, a_text);
    if (eql(name, "カタカナ半角変換")) return try katakanaHalfWidth(runtime, a_text);
    if (eql(name, "全角変換")) {
        var kana = try katakanaFullWidth(runtime, a_text);
        try text_roots.protect(&kana);
        return try asciiFullWidth(runtime, kana, true);
    }
    if (eql(name, "半角変換")) {
        var kana = try katakanaHalfWidth(runtime, a_text);
        try text_roots.protect(&kana);
        return try fullWidthAscii(runtime, kana, true);
    }
    if (eql(name, "通貨形式")) return try currency(runtime, a_text);
    if (eql(name, "ゼロ埋")) return try pad(runtime, a_text, b, '0');
    if (eql(name, "空白埋")) return try pad(runtime, a_text, b, ' ');
    if (eql(name, "かなか判定")) return .{ .boolean = firstUnit(a_text.string) >= 0x3041 and firstUnit(a_text.string) <= 0x309f };
    if (eql(name, "カタカナ判定")) return .{ .boolean = firstUnit(a_text.string) >= 0x30a1 and firstUnit(a_text.string) <= 0x30fa };
    if (eql(name, "数字判定")) return .{ .boolean = isDigit(firstUnit(a_text.string)) };
    if (eql(name, "数列判定")) return .{ .boolean = numberSequence(a_text.string.units) };
    return null;
}

fn requireStringReceiver(value: Value, starts: bool) !void {
    if (value == .string) return;
    if (starts) return switch (value) {
        .null_value => error.StartsWithNullReceiver,
        .undefined => error.StartsWithUndefinedReceiver,
        else => error.StartsWithReceiverExpected,
    };
    return switch (value) {
        .null_value => error.EndsWithNullReceiver,
        .undefined => error.EndsWithUndefinedReceiver,
        else => error.EndsWithReceiverExpected,
    };
}

fn handles(name: []const u8) bool {
    const commands = [_][]const u8{
        "文字数",
        "何文字目",
        "CHR",
        "ASC",
        "文字挿入",
        "文字検索",
        "追加",
        "一行追加",
        "連結",
        "文字列連結",
        "文字列分解",
        "リフレイン",
        "出現回数",
        "MID",
        "文字抜出",
        "LEFT",
        "文字左部分",
        "RIGHT",
        "文字右部分",
        "区切",
        "文字列分割",
        "文字削除",
        "文字始",
        "文字終",
        "出現",
        "置換",
        "単置換",
        "トリム",
        "空白除去",
        "右トリム",
        "末尾空白除去",
        "左トリム",
        "大文字変換",
        "小文字変換",
        "平仮名変換",
        "カタカナ変換",
        "英数全角変換",
        "英数半角変換",
        "英数記号全角変換",
        "英数記号半角変換",
        "カタカナ全角変換",
        "カタカナ半角変換",
        "全角変換",
        "半角変換",
        "通貨形式",
        "ゼロ埋",
        "空白埋",
        "かなか判定",
        "カタカナ判定",
        "数字判定",
        "数列判定",
    };
    for (commands) |command| if (eql(name, command)) return true;
    return false;
}

pub fn cut(runtime: *Runtime, source: Value, delimiter: Value) !CutResult {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_text = try runtime.valueToString(source);
    try roots.protect(&source_text);
    var delimiter_text = try runtime.valueToString(delimiter);
    try roots.protect(&delimiter_text);
    const source_units = source_text.string.units;
    const delimiter_units = delimiter_text.string.units;
    const found = indexOfUnits(source_units, delimiter_units, 0);
    const result_units = if (found) |index| source_units[0..index] else source_units;
    const remainder_units = if (found) |index| source_units[index + delimiter_units.len ..] else &.{};
    return makeCutResult(runtime, result_units, remainder_units);
}

pub fn cutRange(runtime: *Runtime, source: Value, first: Value, last: Value) !CutResult {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_text = try runtime.valueToString(source);
    try roots.protect(&source_text);
    var first_text = try runtime.valueToString(first);
    try roots.protect(&first_text);
    var last_text = try runtime.valueToString(last);
    try roots.protect(&last_text);
    const source_units = source_text.string.units;
    const first_units = first_text.string.units;
    const last_units = last_text.string.units;
    const first_index = indexOfUnits(source_units, first_units, 0) orelse return makeCutResult(runtime, &.{}, source_units);
    const prefix = source_units[0..first_index];
    const middle_start = first_index + first_units.len;
    const last_relative = indexOfUnits(source_units[middle_start..], last_units, 0);
    if (last_relative == null) return makeCutResult(runtime, source_units[middle_start..], prefix);
    const last_index = middle_start + last_relative.?;
    var remainder_units = try runtime.allocator().alloc(u16, prefix.len + source_units.len - last_index - last_units.len);
    defer runtime.allocator().free(remainder_units);
    @memcpy(remainder_units[0..prefix.len], prefix);
    @memcpy(remainder_units[prefix.len..], source_units[last_index + last_units.len ..]);
    return makeCutResult(runtime, source_units[middle_start..last_index], remainder_units);
}

fn makeCutResult(runtime: *Runtime, result_units: []const u16, remainder_units: []const u16) !CutResult {
    var result = try runtime.stringCodeUnits(result_units);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    const remainder = try runtime.stringCodeUnits(remainder_units);
    return .{ .result = result, .remainder = remainder };
}

fn text(runtime: *Runtime, value: Value) !*string_mod.String {
    return (try runtime.valueToString(value)).string;
}

fn chr(runtime: *Runtime, value: Value) !Value {
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

fn codePointString(runtime: *Runtime, number: f64) !Value {
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

fn asc(runtime: *Runtime, value: Value) !Value {
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

fn insert(runtime: *Runtime, source: Value, position: Value, addition: Value) !Value {
    const source_units = (try text(runtime, source)).units;
    const addition_units = (try text(runtime, addition)).units;
    var number = try runtime.valueToNumber(position);
    if (number <= 0) number = 1;
    const codepoint_index = collectionIndex(number - 1, codePointCount(source_units));
    const offset = codePointOffset(source_units, codepoint_index);
    var output = try runtime.allocator().alloc(u16, source_units.len + addition_units.len);
    defer runtime.allocator().free(output);
    @memcpy(output[0..offset], source_units[0..offset]);
    @memcpy(output[offset .. offset + addition_units.len], addition_units);
    @memcpy(output[offset + addition_units.len ..], source_units[offset..]);
    return runtime.stringCodeUnits(output);
}

fn append(runtime: *Runtime, source: Value, addition: Value, source_text: Value, addition_text: Value, newline: bool) !Value {
    if (source == .array) {
        _ = try source.array.push(addition);
        return source;
    }
    var values = [_]Value{ source_text, addition_text, .undefined };
    if (!newline) return join(runtime, values[0..2]);
    values[2] = try runtime.stringUtf8("\n");
    return join(runtime, &values);
}

fn join(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator());
    for (values) |value| try units.appendSlice(runtime.allocator(), (try text(runtime, value)).units);
    return runtime.stringCodeUnits(units.items);
}

fn joinArguments(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator());
    for (values) |value| switch (value) {
        .undefined, .null_value => {},
        else => try units.appendSlice(runtime.allocator(), (try text(runtime, value)).units),
    };
    return runtime.stringCodeUnits(units.items);
}

fn explode(runtime: *Runtime, value: Value) !Value {
    const units = (try text(runtime, value)).units;
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        const item = try runtime.stringCodeUnits(units[index .. index + length]);
        _ = try result.array.push(item);
        index += length;
    }
    return result;
}

fn repeat(runtime: *Runtime, value: Value, count_value: Value) !Value {
    const count_number = try runtime.valueToNumber(count_value);
    if (std.math.isNan(count_number) or count_number <= 0) return runtime.stringUtf8("");
    if (!std.math.isFinite(count_number)) return error.RepetitionTooLarge;
    const count = safeUsize(@ceil(count_number));
    const units = (try text(runtime, value)).units;
    const length = std.math.mul(usize, units.len, count) catch return error.RepetitionTooLarge;
    var output = try runtime.allocator().alloc(u16, length);
    defer runtime.allocator().free(output);
    for (0..count) |index| @memcpy(output[index * units.len ..][0..units.len], units);
    return runtime.stringCodeUnits(output);
}

fn mid(runtime: *Runtime, source: Value, start_value: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const count_number = try substringNumber(runtime, count_value);
    if (count_number <= 0) return runtime.stringUtf8("");
    var start_number = try substringNumber(runtime, start_value);
    const length = codePointCount(units);
    if (start_number < 0) {
        start_number = @as(f64, @floatFromInt(length)) + start_number + 1;
        if (start_number < 0) start_number = 1;
    }
    const start = sliceIndex(start_number - 1, length);
    const end = sliceIndex(start_number + count_number - 1, length);
    if (end <= start) return runtime.stringUtf8("");
    return runtime.stringCodeUnits(units[codePointOffset(units, start)..codePointOffset(units, end)]);
}

fn left(runtime: *Runtime, source: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const count = sliceIndex(try runtime.valueToNumber(count_value), codePointCount(units));
    return runtime.stringCodeUnits(units[0..codePointOffset(units, count)]);
}

fn right(runtime: *Runtime, source: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const length = codePointCount(units);
    var index_number = @as(f64, @floatFromInt(length)) - try runtime.valueToNumber(count_value);
    if (index_number < 0) index_number = 0;
    const index = sliceIndex(index_number, length);
    return runtime.stringCodeUnits(units[codePointOffset(units, index)..]);
}

fn splitAll(runtime: *Runtime, source: Value, separator: Value) !Value {
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
    while (indexOfUnits(units, delimiter, start)) |found| {
        _ = try result.array.push(try runtime.stringCodeUnits(units[start..found]));
        start = found + delimiter.len;
    }
    _ = try result.array.push(try runtime.stringCodeUnits(units[start..]));
    return result;
}

fn splitFirst(runtime: *Runtime, source: Value, separator: Value) !Value {
    const units = (try text(runtime, source)).units;
    const delimiter = (try text(runtime, separator)).units;
    const found = indexOfUnits(units, delimiter, 0);
    if (found) |index| return common.arrayFromValues(runtime, &.{ try runtime.stringCodeUnits(units[0..index]), try runtime.stringCodeUnits(units[index + delimiter.len ..]) });
    return common.arrayFromValues(runtime, &.{try runtime.stringCodeUnits(units)});
}

fn remove(runtime: *Runtime, source: Value, start_value: Value, count_value: Value) !Value {
    const units = (try text(runtime, source)).units;
    const length = codePointCount(units);
    const start = sliceIndex(try runtime.valueToNumber(start_value) - 1, length);
    const count = spliceDeleteCount(try runtime.valueToNumber(count_value), length - start);
    const first = codePointOffset(units, start);
    const last = codePointOffset(units, start + count);
    var output = try runtime.allocator().alloc(u16, units.len - (last - first));
    defer runtime.allocator().free(output);
    @memcpy(output[0..first], units[0..first]);
    @memcpy(output[first..], units[last..]);
    return runtime.stringCodeUnits(output);
}

fn includes(runtime: *Runtime, source: Value, needle: Value) !bool {
    if (source == .array) {
        for (source.array.items.items) |item| if (Value.strictEqual(item, needle)) return true;
        return false;
    }
    return indexOfUnits((try text(runtime, source)).units, (try text(runtime, needle)).units, 0) != null;
}

fn replace(runtime: *Runtime, source: Value, search: Value, replacement: Value, all: bool) !Value {
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
        const found = indexOfUnits(units, needle, 0) orelse return runtime.stringCodeUnits(units);
        return replaceFirst(runtime, units, found, found + needle.len, replacement_units);
    }
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var start: usize = 0;
    while (indexOfUnits(units, needle, start)) |found| {
        try output.appendSlice(runtime.allocator(), units[start..found]);
        try output.appendSlice(runtime.allocator(), replacement_units);
        start = found + needle.len;
    }
    try output.appendSlice(runtime.allocator(), units[start..]);
    return runtime.stringCodeUnits(output.items);
}

fn replaceFirst(runtime: *Runtime, source: []const u16, match_start: usize, match_end: usize, replacement: []const u16) !Value {
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

fn insertUnits(runtime: *Runtime, source: []const u16, index: usize, addition: []const u16) !Value {
    var output = try runtime.allocator().alloc(u16, source.len + addition.len);
    defer runtime.allocator().free(output);
    @memcpy(output[0..index], source[0..index]);
    @memcpy(output[index .. index + addition.len], addition);
    @memcpy(output[index + addition.len ..], source[index..]);
    return runtime.stringCodeUnits(output);
}

fn trim(runtime: *Runtime, source: Value, left_side: bool, right_side: bool) !Value {
    const units = (try text(runtime, source)).units;
    var first: usize = 0;
    var last = units.len;
    if (left_side) {
        while (first < last and string_mod.isEcmaWhitespace(units[first])) : (first += 1) {}
    }
    if (right_side) {
        while (last > first and string_mod.isEcmaWhitespace(units[last - 1])) : (last -= 1) {}
    }
    return runtime.stringCodeUnits(units[first..last]);
}

fn unicodeCase(runtime: *Runtime, source: Value, uppercase: bool) !Value {
    const source_string = try text(runtime, source);
    const units = source_string.units;
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(runtime.allocator());
    var unit_index: usize = 0;
    while (unit_index < units.len) {
        const codepoint = source_string.codePointAt(unit_index).?;
        try codepoints.append(runtime.allocator(), codepoint);
        unit_index += if (codepoint > 0xffff) 2 else 1;
    }
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    for (codepoints.items, 0..) |codepoint, index| {
        if (!uppercase and codepoint == 0x03a3 and isFinalSigma(codepoints.items, index)) {
            try appendCodePoint(runtime.allocator(), &output, 0x03c2);
            continue;
        }
        const mapped = if (uppercase) unicode_case.upper(codepoint) else unicode_case.lower(codepoint);
        if (mapped) |values| {
            for (values) |value| try appendCodePoint(runtime.allocator(), &output, value);
        } else try appendCodePoint(runtime.allocator(), &output, codepoint);
    }
    return runtime.stringCodeUnits(output.items);
}

fn isFinalSigma(codepoints: []const u21, index: usize) bool {
    var before = index;
    var has_cased_before = false;
    while (before > 0) {
        before -= 1;
        if (unicode_case.isCaseIgnorable(codepoints[before])) continue;
        has_cased_before = unicode_case.isCased(codepoints[before]);
        break;
    }
    if (!has_cased_before) return false;
    var after = index + 1;
    while (after < codepoints.len) : (after += 1) {
        if (unicode_case.isCaseIgnorable(codepoints[after])) continue;
        return !unicode_case.isCased(codepoints[after]);
    }
    return true;
}

fn appendCodePoint(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const offset: u32 = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (offset >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (offset & 0x3ff)));
}

fn offsetRange(runtime: *Runtime, source: Value, first: u16, last: u16, offset: i32) !Value {
    const units = (try text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (unit.* >= first and unit.* <= last) unit.* = @intCast(@as(i32, unit.*) + offset);
    }
    return runtime.stringCodeUnits(output);
}

fn asciiFullWidth(runtime: *Runtime, source: Value, symbols: bool) !Value {
    const units = (try text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (symbols and unit.* == 0x20) unit.* = 0x3000 else if ((symbols and unit.* >= 0x21 and unit.* <= 0x7e) or (!symbols and ((unit.* >= 'A' and unit.* <= 'Z') or (unit.* >= 'a' and unit.* <= 'z') or (unit.* >= '0' and unit.* <= '9')))) unit.* += 0xfee0;
    }
    return runtime.stringCodeUnits(output);
}

fn fullWidthAscii(runtime: *Runtime, source: Value, symbols: bool) !Value {
    const units = (try text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (symbols and unit.* == 0x3000) unit.* = 0x20 else if ((symbols and unit.* >= 0xff00 and unit.* <= 0xff5f) or (!symbols and ((unit.* >= 0xff21 and unit.* <= 0xff3a) or (unit.* >= 0xff41 and unit.* <= 0xff5a) or (unit.* >= 0xff10 and unit.* <= 0xff19)))) unit.* -= 0xfee0;
    }
    return runtime.stringCodeUnits(output);
}

fn katakanaFullWidth(runtime: *Runtime, source: Value) !Value {
    return mapKana(runtime, source, true);
}

fn katakanaHalfWidth(runtime: *Runtime, source: Value) !Value {
    return mapKana(runtime, source, false);
}

fn mapKana(runtime: *Runtime, source: Value, to_full: bool) !Value {
    const source_units = (try text(runtime, source)).units;
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
            if (indexOfUnits(half_voiced, source_units[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator(), full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
        }
        const unit = source_units[index];
        if (to_full) {
            if (unitIndex(half, unit)) |position| try output.append(runtime.allocator(), full[position]) else try output.append(runtime.allocator(), unit);
        } else if (unitIndex(full, unit)) |position| {
            try output.append(runtime.allocator(), half[position]);
        } else if (unitIndex(full_voiced, unit)) |position| {
            try output.appendSlice(runtime.allocator(), half_voiced[position * 2 .. position * 2 + 2]);
        } else try output.append(runtime.allocator(), unit);
        index += 1;
    }
    return runtime.stringCodeUnits(output.items);
}

fn currency(runtime: *Runtime, value: Value) !Value {
    const units = (try text(runtime, value)).units;
    var decimal = units.len;
    for (units, 0..) |unit, index| if (unit == '.') {
        decimal = index;
        break;
    };
    var first_digit: usize = 0;
    while (first_digit < decimal and (units[first_digit] < '0' or units[first_digit] > '9')) first_digit += 1;
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    for (units, 0..) |unit, index| {
        if (index > first_digit and index < decimal and (decimal - index) % 3 == 0 and unit >= '0' and unit <= '9') try output.append(runtime.allocator(), ',');
        try output.append(runtime.allocator(), unit);
    }
    return runtime.stringCodeUnits(output.items);
}

fn pad(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = (try text(runtime, value)).units;
    const width_number = try common.parseIntValue(runtime, width_value, null);
    const width = if (std.math.isNan(width_number) or width_number <= 0) units.len else @max(units.len, safeUsize(@trunc(width_number)));
    var output = try runtime.allocator().alloc(u16, width);
    defer runtime.allocator().free(output);
    @memset(output[0 .. width - units.len], fill);
    @memcpy(output[width - units.len ..], units);
    return runtime.stringCodeUnits(output);
}

fn numberSequence(units: []const u16) bool {
    if (units.len == 0) return false;
    var index: usize = 0;
    if (isSign(units[index])) index += 1;
    var integer_digits: usize = 0;
    while (index < units.len and isDigit(units[index])) : (index += 1) integer_digits += 1;
    var fraction_digits: usize = 0;
    if (index < units.len and (units[index] == '.' or units[index] == 0xff0e)) {
        index += 1;
        while (index < units.len and isDigit(units[index])) : (index += 1) fraction_digits += 1;
        if (fraction_digits == 0) return false;
    }
    if (index < units.len and (units[index] == 'e' or units[index] == 'E' or units[index] == 0xff45 or units[index] == 0xff25)) {
        if (fraction_digits == 0) return false;
        index += 1;
        if (index < units.len and isSign(units[index])) index += 1;
        const exponent_start = index;
        while (index < units.len and isDigit(units[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == units.len and (integer_digits > 0 or fraction_digits > 0);
}

fn codePointCount(units: []const u16) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (count += 1) index += codePointLength(units, index);
    return count;
}

fn codePointLength(units: []const u16, index: usize) usize {
    return if (index + 1 < units.len and units[index] >= 0xd800 and units[index] <= 0xdbff and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) 2 else 1;
}

fn codePointOffset(units: []const u16, target: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len and count < target) : (count += 1) index += codePointLength(units, index);
    return index;
}

fn findCodePoints(haystack: []const u16, needle: []const u16, from_codepoint: usize) ?usize {
    var codepoint_index = from_codepoint;
    var unit_index = codePointOffset(haystack, from_codepoint);
    while (unit_index < haystack.len) {
        if (needle.len <= haystack.len - unit_index and std.mem.eql(u16, haystack[unit_index..][0..needle.len], needle)) return codepoint_index + 1;
        unit_index += codePointLength(haystack, unit_index);
        codepoint_index += 1;
    }
    return null;
}

fn searchCodePoints(haystack: []const u16, start_value: f64, needle: []const u16) f64 {
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

fn indexOfUnits(haystack: []const u16, needle: []const u16, start: usize) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.mem.eql(u16, haystack[index .. index + needle.len], needle)) return index;
    return null;
}

fn countOccurrences(haystack: []const u16, needle: []const u16) i64 {
    if (needle.len == 0) return @as(i64, @intCast(haystack.len)) - 1;
    var count: i64 = 0;
    var start: usize = 0;
    while (indexOfUnits(haystack, needle, start)) |found| {
        count += 1;
        start = found + needle.len;
    }
    return count;
}

fn startsWith(source: []const u16, prefix: []const u16) bool {
    return source.len >= prefix.len and std.mem.eql(u16, source[0..prefix.len], prefix);
}

fn endsWith(source: []const u16, suffix: []const u16) bool {
    return source.len >= suffix.len and std.mem.eql(u16, source[source.len - suffix.len ..], suffix);
}

fn oneBasedIndex(number: f64) usize {
    return if (std.math.isNan(number) or number <= 1) 0 else safeUsize(@trunc(number) - 1);
}

fn safeUsize(number: f64) usize {
    if (!std.math.isFinite(number) or number <= 0) return 0;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(number);
}

fn collectionIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(@trunc(number));
}

fn substringNumber(runtime: *Runtime, value: Value) !f64 {
    return if (value == .string) common.parseIntValue(runtime, value, null) else runtime.valueToNumber(value);
}

fn sliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    const length_number: f64 = @floatFromInt(length);
    if (number >= length_number) return length;
    if (number <= -length_number) return 0;
    if (number < 0) return length - @as(usize, @intFromFloat(-@trunc(number)));
    return @intFromFloat(@trunc(number));
}

fn spliceDeleteCount(number: f64, remaining: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(remaining))) return remaining;
    return @intFromFloat(@trunc(number));
}

fn firstUnit(value: *string_mod.String) u16 {
    return if (value.units.len > 0) value.units[0] else 0;
}

fn isDigit(unit: u16) bool {
    return (unit >= '0' and unit <= '9') or (unit >= 0xff10 and unit <= 0xff19);
}

fn isSign(unit: u16) bool {
    return unit == '+' or unit == '-' or unit == 0xff0b or unit == 0xff0d;
}

fn unitIndex(units: []const u16, needle: u16) ?usize {
    for (units, 0..) |unit, index| if (unit == needle) return index;
    return null;
}

fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

const full_kana = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンァィゥェォャュョッ、。ー「」";
const full_voiced_kana = "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポ";
const half_kana = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝｧｨｩｪｫｬｭｮｯ､｡ｰ｢｣ﾞﾟ";
const half_voiced_kana = "ｶﾞｷﾞｸﾞｹﾞｺﾞｻﾞｼﾞｽﾞｾﾞｿﾞﾀﾞﾁﾞﾂﾞﾃﾞﾄﾞﾊﾞﾋﾞﾌﾞﾍﾞﾎﾞﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ";

test "Unicode文字列命令をコードポイント単位で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("A😀B😀");
    try std.testing.expectEqual(@as(f64, 4), (try call(&runtime, "文字数", &.{source})).?.number);
    try std.testing.expectEqual(@as(f64, 2), (try call(&runtime, "何文字目", &.{ source, try runtime.stringUtf8("😀") })).?.number);
    const middle = (try call(&runtime, "文字抜出", &.{ source, .{ .number = 2 }, .{ .number = 2 } })).?;
    const utf8 = try middle.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("😀B", utf8);
}

test "文字始と文字終は非文字列レシーバを公式文言で拒否する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectError(error.StartsWithReceiverExpected, call(&runtime, "文字始", &.{ .{ .number = 123 }, .{ .number = 12 } }));
    try std.testing.expectError(error.EndsWithNullReceiver, call(&runtime, "文字終", &.{ .null_value, try runtime.stringUtf8("x") }));
}

test "置換・幅変換・かな変換を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const replaced = (try call(&runtime, "置換", &.{ try runtime.stringUtf8("a-a"), try runtime.stringUtf8("a"), try runtime.stringUtf8("x") })).?;
    const replaced_utf8 = try replaced.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(replaced_utf8);
    try std.testing.expectEqualStrings("x-x", replaced_utf8);
    const converted = (try call(&runtime, "全角変換", &.{try runtime.stringUtf8("ABC ｶﾞ")})).?;
    const converted_utf8 = try converted.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(converted_utf8);
    try std.testing.expectEqualStrings("ＡＢＣ　ガ", converted_utf8);
}

test "置換はsplitとjoinのundefined型強制を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const unchanged = (try call(&runtime, "置換", &.{ try runtime.stringUtf8("xundefinedy"), .undefined, try runtime.stringUtf8("z") })).?;
    const unchanged_utf8 = try unchanged.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(unchanged_utf8);
    try std.testing.expectEqualStrings("xundefinedy", unchanged_utf8);

    const comma_joined = (try call(&runtime, "置換", &.{ try runtime.stringUtf8("a-a"), try runtime.stringUtf8("a"), .undefined })).?;
    const comma_joined_utf8 = try comma_joined.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(comma_joined_utf8);
    try std.testing.expectEqualStrings(",-,", comma_joined_utf8);

    const replaced_once = (try call(&runtime, "単置換", &.{ try runtime.stringUtf8("xundefinedy"), .undefined, try runtime.stringUtf8("z") })).?;
    const replaced_once_utf8 = try replaced_once.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(replaced_once_utf8);
    try std.testing.expectEqualStrings("xzy", replaced_once_utf8);

    const undefined_replacement = (try call(&runtime, "単置換", &.{ try runtime.stringUtf8("x-x"), try runtime.stringUtf8("x"), .undefined })).?;
    const undefined_replacement_utf8 = try undefined_replacement.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(undefined_replacement_utf8);
    try std.testing.expectEqualStrings("undefined-x", undefined_replacement_utf8);
}

test "ECMAScriptのUnicode大小文字変換と文脈依存シグマを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const uppercase = (try call(&runtime, "大文字変換", &.{try runtime.stringUtf8("Straße ﬁ")})).?;
    const uppercase_utf8 = try uppercase.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(uppercase_utf8);
    try std.testing.expectEqualStrings("STRASSE FI", uppercase_utf8);
    const lowercase = (try call(&runtime, "小文字変換", &.{try runtime.stringUtf8("ΟΣ ΣΑ")})).?;
    const lowercase_utf8 = try lowercase.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(lowercase_utf8);
    try std.testing.expectEqualStrings("ος σα", lowercase_utf8);
}

test "GCストレス中に非文字列引数を安全に文字列命令へ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    const replaced = (try call(&runtime, "置換", &.{ .{ .number = 12121 }, .{ .number = 1 }, .{ .number = 9 } })).?;
    const utf8 = try replaced.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("92929", utf8);
    const cut_result = try cutRange(&runtime, .{ .number = 12345 }, .{ .number = 2 }, .{ .number = 4 });
    const middle = try cut_result.result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(middle);
    try std.testing.expectEqualStrings("3", middle);
}
