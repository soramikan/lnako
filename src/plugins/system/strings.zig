const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const string_mod = @import("../../runtime/string.zig");
const common = @import("common.zig");
const operators = @import("../../runtime/operators.zig");
const unicode_case = @import("unicode_case");

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

    // The ASCII-only commands explicitly coerce their receiver with
    // String(s), while the kana commands in the official implementation
    // access the raw receiver (length/substring or split).  Keep this split
    // before the common eager String conversions below.
    if (eql(name, "英数全角変換")) return try asciiFullWidth(runtime, a_root, false);
    if (eql(name, "英数半角変換")) return try fullWidthAscii(runtime, a_root, false);
    if (eql(name, "英数記号全角変換")) return try asciiFullWidth(runtime, a_root, true);
    if (eql(name, "英数記号半角変換")) return try fullWidthAscii(runtime, a_root, true);
    if (eql(name, "カタカナ全角変換")) return try katakanaFullWidth(runtime, a_root);
    if (eql(name, "カタカナ半角変換")) return try katakanaHalfWidth(runtime, a_root);
    if (eql(name, "全角変換")) {
        var kana = try katakanaFullWidth(runtime, a_root);
        try text_roots.protect(&kana);
        return try asciiFullWidth(runtime, kana, true);
    }
    if (eql(name, "半角変換")) {
        var kana = try katakanaHalfWidth(runtime, a_root);
        try text_roots.protect(&kana);
        return try fullWidthAscii(runtime, kana, true);
    }

    if (eql(name, "何文字目")) {
        if (a_root == .string and b_root == .string) {
            const index = findStringArrayWindow(a_root.string.units, b_root.string.units) orelse 0;
            return .{ .number = @floatFromInt(index) };
        }
        return .{ .number = @floatFromInt(try findRawArrayIndex(runtime, a_root, b_root)) };
    }

    var a_text = try runtime.valueToString(a);
    try text_roots.protect(&a_text);
    var b_text = try runtime.valueToString(b);
    try text_roots.protect(&b_text);
    var c_text = try runtime.valueToString(c);
    try text_roots.protect(&c_text);
    if (eql(name, "文字数")) return .{ .number = @floatFromInt(codePointCount(a_text.string.units)) };
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
    if (eql(name, "通貨形式")) return try currency(runtime, a_text);
    if (eql(name, "ゼロ埋")) return try pad(runtime, a_text, b, '0');
    if (eql(name, "空白埋")) return try pad(runtime, a_text, b, ' ');
    if (eql(name, "かなか判定")) return .{ .boolean = firstUnit(a_text.string) >= 0x3041 and firstUnit(a_text.string) <= 0x309f };
    if (eql(name, "カタカナ判定")) return .{ .boolean = firstUnit(a_text.string) >= 0x30a1 and firstUnit(a_text.string) <= 0x30fa };
    if (eql(name, "数字判定")) return .{ .boolean = isDigit(firstUnit(a_text.string)) };
    if (eql(name, "数列判定")) {
        // 公式はString化より前に元引数との厳密比較を行うため、空文字列だけfalse。
        // 空配列など、String化すると空になる別型は正規表現へ進みtrueになる。
        if (a == .string and a.string.units.len == 0) return .{ .boolean = false };
        return .{ .boolean = numberSequence(a_text.string.units) };
    }
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
    const found = indexOfUnits(source_units, delimiter_units, 0);
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
    const first_index = indexOfUnits(source_units, first_units, 0) orelse return makeCutResult(runtime, &.{}, source_units);
    const middle_start = try cutEndIndex(runtime, first_index, first_root, source_units.len);
    // The official implementation does not even String-coerce or inspect the
    // second delimiter until the first delimiter has matched.
    var last_text = try runtime.valueToString(last_root);
    try roots.protect(&last_text);
    const last_units = last_text.string.units;
    const prefix = source_units[0..first_index];
    const last_relative = indexOfUnits(source_units[middle_start..], last_units, 0);
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
fn cutEndIndex(runtime: *Runtime, match_index: usize, delimiter: Value, source_length: usize) !usize {
    const length = try cutLengthProperty(runtime, delimiter);
    const sum = try operators.binary(runtime, .add, .{ .number = @floatFromInt(match_index) }, length);
    const number = try runtime.valueToNumber(sum);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(source_length))) return source_length;
    return @intFromFloat(@trunc(number));
}

fn cutLengthProperty(runtime: *Runtime, value: Value) !Value {
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
        for (source.array.items.items) |item| if (Value.sameValueZero(item, needle)) return true;
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
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source_root = source;
    try roots.protect(&source_root);

    const source_units: []const u16 = blk: {
        if (source_root == .string) break :blk source_root.string.units;
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
            if (indexOfUnits(half_voiced, source_units[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator(), full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
        }
        const unit = source_units[index];
        if (to_full) {
            if (unitIndex(half, unit)) |position| {
                if (position < full.len) try output.append(runtime.allocator(), full[position]);
            } else try output.append(runtime.allocator(), unit);
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
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    var index: usize = 0;
    while (index < units.len) {
        if (!isAsciiDigit(units[index])) {
            try output.append(runtime.allocator(), units[index]);
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and isAsciiDigit(units[index])) : (index += 1) {}
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

fn pad(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = (try text(runtime, value)).units;
    const original_number = switch (width_value) {
        .bigint => |bigint| bigint.toF64(),
        else => try runtime.valueToNumber(width_value),
    };
    const width_number = try common.parseIntValue(runtime, width_value, null);
    const fill_count = if (std.math.isNan(original_number) or original_number <= 0) @as(usize, 1) else blk: {
        if (!std.math.isFinite(original_number) or original_number >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.OutOfMemory;
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
        break :blk safeUsize(@trunc(width_number));
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

fn numberSequence(units: []const u16) bool {
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

fn isAsciiDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
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

/// Compare the same windows that `Array.from(source).slice(i, i +
/// needle.length).join('')` produces.  The window's width is measured in
/// Unicode scalar elements, while equality is still UTF-16 code-unit based;
/// this distinction prevents a lone surrogate from matching half of a pair.
/// Both offsets advance monotonically, avoiding an extra full prefix scan for
/// each candidate; equality retains the usual window-comparison cost.
fn findStringArrayWindow(haystack: []const u16, needle: []const u16) ?usize {
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
// while temporary join strings are created under GC stress.
const raw_array_element_limit: usize = 1_000_000;

fn findRawArrayIndex(runtime: *Runtime, source: Value, needle: Value) !usize {
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

fn rawArrayLength(runtime: *Runtime, value: Value) !usize {
    const length = switch (value) {
        .undefined => return error.RawArrayUndefinedNotIterable,
        .null_value => return error.RawArrayNullNotIterable,
        .string => |string| codePointCount(string.units),
        .array => |array| array.items.items.len,
        .bytes => |buffer| if (buffer.kind == .array_buffer) 0 else buffer.bytes.len,
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

fn rawArraySliceJoin(runtime: *Runtime, source: Value, start: usize, requested_count: usize, length: usize) ![]u16 {
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

fn appendRawArrayElement(runtime: *Runtime, source: Value, index: usize, output: *std.ArrayList(u16)) !void {
    const element: Value = switch (source) {
        .array => |array| array.get(index),
        .bytes => |buffer| buffer.get(index),
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

fn rawArrayNoop(_: *Runtime, _: []const Value) !Value {
    return .undefined;
}

test "何文字目は公式のArray.fromとslice.joinを型別に再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("A😀B");
    var needle = try runtime.stringUtf8("😀B");
    try roots.protect(&source);
    try roots.protect(&needle);
    try std.testing.expectEqual(@as(f64, 2), (try call(&runtime, "何文字目", &.{ source, needle })).?.number);

    var long_units: [2048]u16 = undefined;
    @memset(long_units[0..2046], 'a');
    long_units[2046] = 0xd83d;
    long_units[2047] = 0xde00;
    var long_source = try runtime.stringCodeUnits(&long_units);
    var long_needle = try runtime.stringUtf8("😀");
    try roots.protect(&long_source);
    try roots.protect(&long_needle);
    try std.testing.expectEqual(@as(f64, 2047), (try call(&runtime, "何文字目", &.{ long_source, long_needle })).?.number);

    var pair_source = (try call(&runtime, "CHR", &.{.{ .number = 128512 }})).?;
    var pair_needle = (try call(&runtime, "CHR", &.{.{ .number = 128512 }})).?;
    var high_needle = (try call(&runtime, "CHR", &.{.{ .number = 55357 }})).?;
    var low_needle = (try call(&runtime, "CHR", &.{.{ .number = 56832 }})).?;
    try roots.protect(&pair_source);
    try roots.protect(&pair_needle);
    try roots.protect(&high_needle);
    try roots.protect(&low_needle);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ pair_source, pair_needle })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ pair_source, high_needle })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ pair_source, low_needle })).?.number);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ high_needle, high_needle })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ high_needle, pair_needle })).?.number);

    var one = try runtime.createArray();
    var one_with_null = try runtime.createArray();
    var mixed = try runtime.createArray();
    try roots.protect(&one);
    try roots.protect(&one_with_null);
    try roots.protect(&mixed);
    _ = try one.array.push(try runtime.stringUtf8("a"));
    _ = try one_with_null.array.push(try runtime.stringUtf8("a"));
    _ = try one_with_null.array.push(.null_value);
    _ = try mixed.array.push(try runtime.stringUtf8("a"));
    _ = try mixed.array.push(.{ .number = 12 });
    _ = try mixed.array.push(.{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ one, one_with_null })).?.number);
    try std.testing.expectEqual(@as(f64, 2), (try call(&runtime, "何文字目", &.{ mixed, try runtime.stringUtf8("123") })).?.number);

    var nested_item = try runtime.createArray();
    var nested_source = try runtime.createArray();
    var nested_needle = try runtime.createArray();
    try roots.protect(&nested_item);
    try roots.protect(&nested_source);
    try roots.protect(&nested_needle);
    _ = try nested_item.array.push(try runtime.stringUtf8("a"));
    _ = try nested_item.array.push(try runtime.stringUtf8("b"));
    _ = try nested_source.array.push(nested_item);
    _ = try nested_source.array.push(try runtime.stringUtf8("c"));
    _ = try nested_needle.array.push(nested_item);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ nested_source, try runtime.stringUtf8("a,b") })).?.number);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ nested_source, nested_needle })).?.number);

    const number = Value{ .number = 12 };
    const boolean = Value{ .boolean = true };
    var bigint = try runtime.bigIntLiteral("1n");
    var function_name = try runtime.stringUtf8("noop");
    var function = try runtime.createNativeFunction(function_name.string, 0, rawArrayNoop, &.{});
    try roots.protect(&bigint);
    try roots.protect(&function_name);
    try roots.protect(&function);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ number, source })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ boolean, source })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ bigint, source })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ function, source })).?.number);

    var bytes = try runtime.createBytes(&.{ 1, 2, 3 });
    var uint8 = try runtime.createUint8Array(&.{ 1, 2, 3 });
    var array_buffer = try runtime.createArrayBuffer(&.{ 1, 2, 3 });
    try roots.protect(&bytes);
    try roots.protect(&uint8);
    try roots.protect(&array_buffer);
    var numeric_text = try runtime.stringUtf8("123");
    try roots.protect(&numeric_text);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ bytes, numeric_text })).?.number);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ uint8, numeric_text })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ array_buffer, numeric_text })).?.number);

    var object = try runtime.createDictionary();
    try roots.protect(&object);
    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", try runtime.stringUtf8("1.9"));
    try common.dictionarySetUtf8(&runtime, object.dictionary, "0", try runtime.stringUtf8("a"));
    var object_needle = try runtime.stringUtf8("a");
    try roots.protect(&object_needle);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ object, object_needle })).?.number);

    var inherited_prototype = try runtime.createDictionary();
    var inherited_object = try runtime.createDictionary();
    try roots.protect(&inherited_prototype);
    try roots.protect(&inherited_object);
    try common.dictionarySetUtf8(&runtime, inherited_prototype.dictionary, "length", .{ .number = 2 });
    try common.dictionarySetUtf8(&runtime, inherited_prototype.dictionary, "0", try runtime.stringUtf8("a"));
    try common.dictionarySetUtf8(&runtime, inherited_prototype.dictionary, "1", try runtime.stringUtf8("b"));
    inherited_object.dictionary.prototype = inherited_prototype;
    runtime.setGcStress(true);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ inherited_object, try runtime.stringUtf8("ab") })).?.number);
    runtime.setGcStress(false);

    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = @floatFromInt(raw_array_element_limit) });
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ object, object_needle })).?.number);
    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = @floatFromInt(raw_array_element_limit + 1) });
    try std.testing.expectError(error.ArraySizeLimitExceeded, call(&runtime, "何文字目", &.{ object, object_needle }));
    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = std.math.inf(f64) });
    try std.testing.expectError(error.ArraySizeLimitExceeded, call(&runtime, "何文字目", &.{ object, object_needle }));

    try std.testing.expectError(error.RawArrayNullNotIterable, call(&runtime, "何文字目", &.{ .null_value, source }));
    try std.testing.expectError(error.RawArrayUndefinedNotIterable, call(&runtime, "何文字目", &.{ .undefined, source }));
    try std.testing.expectError(error.RawArrayNullNotIterable, call(&runtime, "何文字目", &.{ source, .null_value }));
    try std.testing.expectError(error.RawArrayUndefinedNotIterable, call(&runtime, "何文字目", &.{ source, .undefined }));
}

fn rawArrayAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.createArray();
    try roots.protect(&source);
    var first = try runtime.stringUtf8("a");
    try roots.protect(&first);
    var second = try runtime.stringUtf8("b");
    try roots.protect(&second);
    var third = try runtime.stringUtf8("c");
    try roots.protect(&third);
    _ = try source.array.push(first);
    _ = try source.array.push(second);
    _ = try source.array.push(third);
    var needle = try runtime.stringUtf8("bc");
    try roots.protect(&needle);
    const result = call(&runtime, "何文字目", &.{ source, needle }) catch |failure| {
        if (failure == error.WriteFailed) return error.OutOfMemory;
        return failure;
    };
    try std.testing.expectEqual(@as(f64, 2), result.?.number);
}

test "何文字目はGCストレスと全割当失敗でもraw入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rawArrayAllocationTest, .{});
}

test "何文字目はGCストレス中もraw入力を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.createArray();
    try roots.protect(&source);
    var nested = try runtime.createArray();
    try roots.protect(&nested);
    var first = try runtime.stringUtf8("a");
    try roots.protect(&first);
    var second = try runtime.stringUtf8("b");
    try roots.protect(&second);
    _ = try nested.array.push(first);
    _ = try nested.array.push(second);
    _ = try source.array.push(nested);
    var tail = try runtime.stringUtf8("c");
    try roots.protect(&tail);
    _ = try source.array.push(tail);
    var needle = try runtime.stringUtf8("a,b");
    try roots.protect(&needle);
    const result = try call(&runtime, "何文字目", &.{ source, needle });
    try std.testing.expectEqual(@as(f64, 0), result.?.number);
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

test "幅変換のカナ系は公式の生レシーバ分岐と専用エラーを保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const empty_array = try runtime.createArray();
    const nonempty_array = try runtime.createArray();
    _ = try nonempty_array.array.push(.{ .number = 1 });
    const no_length = try runtime.createDictionary();
    const zero_length = try runtime.createDictionary();
    try common.dictionarySetUtf8(&runtime, zero_length.dictionary, "length", .{ .number = 0 });
    const positive_length = try runtime.createDictionary();
    try common.dictionarySetUtf8(&runtime, positive_length.dictionary, "length", try runtime.stringUtf8("1"));

    for ([_]Value{ .{ .number = 1 }, .{ .boolean = true }, try runtime.bigIntLiteral("1n"), empty_array, no_length }) |value| {
        const result = (try call(&runtime, "カタカナ全角変換", &.{value})).?;
        try std.testing.expectEqualSlices(u16, &.{}, result.string.units);
    }
    const zero_result = (try call(&runtime, "全角変換", &.{zero_length})).?;
    try std.testing.expectEqualSlices(u16, &.{}, zero_result.string.units);
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, call(&runtime, "カタカナ全角変換", &.{nonempty_array}));
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, call(&runtime, "全角変換", &.{positive_length}));
    try std.testing.expectError(error.KatakanaFullWidthLengthNull, call(&runtime, "カタカナ全角変換", &.{.null_value}));
    try std.testing.expectError(error.KatakanaFullWidthLengthUndefined, call(&runtime, "カタカナ全角変換", &.{.undefined}));
    try std.testing.expectError(error.KatakanaHalfWidthSplitNull, call(&runtime, "カタカナ半角変換", &.{.null_value}));
    try std.testing.expectError(error.KatakanaHalfWidthSplitUndefined, call(&runtime, "半角変換", &.{.undefined}));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, call(&runtime, "カタカナ半角変換", &.{.{ .number = 1 }}));
}

fn widthConversionAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("Ａ ｶﾞ");
    try roots.protect(&source);
    var full = (try call(&runtime, "全角変換", &.{source})).?;
    try roots.protect(&full);
    _ = try call(&runtime, "英数半角変換", &.{source});
    _ = try call(&runtime, "カタカナ半角変換", &.{try runtime.stringUtf8("ガ")});
}

test "幅変換はGCストレスと全割当失敗でも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, widthConversionAllocationTest, .{});
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

test "指定形式と文字種判定の公式境界を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const formatted = (try call(&runtime, "通貨形式", &.{try runtime.stringUtf8("abc1234567.89 xyz1234")})).?;
    const expected_formatted = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "abc1,234,567.89 xyz1,234");
    defer std.testing.allocator.free(expected_formatted);
    try std.testing.expectEqualSlices(u16, expected_formatted, formatted.string.units);
    const zero_pad = (try call(&runtime, "ゼロ埋", &.{ try runtime.stringUtf8("x"), try runtime.stringUtf8("2rest") })).?;
    try std.testing.expectEqualSlices(u16, &.{ '0', 'x' }, zero_pad.string.units);
    const bigint_pad = (try call(&runtime, "ゼロ埋", &.{ try runtime.stringUtf8("x"), try runtime.bigIntLiteral("3n") })).?;
    try std.testing.expectEqualSlices(u16, &.{ '0', '0', 'x' }, bigint_pad.string.units);
    const nan_pad = (try call(&runtime, "空白埋", &.{ try runtime.stringUtf8("x"), .{ .number = std.math.nan(f64) } })).?;
    try std.testing.expectEqualSlices(u16, &.{ ' ', 'x' }, nan_pad.string.units);
    try std.testing.expect((try call(&runtime, "かなか判定", &.{try runtime.stringUtf8("あX")})).?.boolean);
    try std.testing.expect((try call(&runtime, "カタカナ判定", &.{try runtime.stringUtf8("アX")})).?.boolean);
    try std.testing.expect((try call(&runtime, "数字判定", &.{try runtime.stringUtf8("９X")})).?.boolean);
    try std.testing.expect((try call(&runtime, "数列判定", &.{try runtime.stringUtf8("＋．５ｅ－２")})).?.boolean);
    try std.testing.expect((try call(&runtime, "数列判定", &.{try runtime.stringUtf8("+")})).?.boolean);
    try std.testing.expect(!(try call(&runtime, "数列判定", &.{try runtime.stringUtf8("")})).?.boolean);
    try std.testing.expect((try call(&runtime, "数列判定", &.{try runtime.createArray()})).?.boolean);
}

test "切取系命令はUTF-16と遅延length参照を公式どおり処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const cut_result = try cut(&runtime, try runtime.stringUtf8("A😀B"), try runtime.stringUtf8("😀"));
    try std.testing.expectEqualSlices(u16, &.{'A'}, cut_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{'B'}, cut_result.remainder.string.units);

    const range_result = try cutRange(&runtime, try runtime.stringUtf8("a[b]c[d]e"), try runtime.stringUtf8("["), try runtime.stringUtf8("]"));
    try std.testing.expectEqualSlices(u16, &.{'b'}, range_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'c', '[', 'd', ']', 'e' }, range_result.remainder.string.units);

    const number_result = try cut(&runtime, try runtime.stringUtf8("123X"), .{ .number = 123 });
    try std.testing.expectEqualSlices(u16, &.{}, number_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '3', 'X' }, number_result.remainder.string.units);

    const dictionary = try runtime.createDictionary();
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "length", .{ .number = 2 });
    const dictionary_result = try cut(&runtime, try runtime.stringUtf8("[object Object]X"), dictionary);
    try std.testing.expectEqualSlices(u16, &.{}, dictionary_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' }, dictionary_result.remainder.string.units);

    const absent = try cutRange(&runtime, try runtime.stringUtf8("abc"), try runtime.stringUtf8("x"), .null_value);
    try std.testing.expectEqualSlices(u16, &.{}, absent.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, absent.remainder.string.units);
    try std.testing.expectError(error.CutNullDelimiterLength, cut(&runtime, try runtime.stringUtf8("null"), .null_value));
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
    // The official implementation searches with String(number), then reads
    // number.length (undefined), so each substring endpoint becomes NaN/0.
    try std.testing.expectEqualStrings("123", middle);
}
