pub const std = @import("std");
pub const value_mod = @import("../../runtime/value.zig");
pub const string_mod = @import("../../runtime/string.zig");
pub const common = @import("common.zig");
pub const operators = @import("../../runtime/operators.zig");
pub const unicode_case = @import("unicode_case");
pub const arrays_plugin = @import("arrays.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const CutResult = struct { result: Value, remainder: Value };

pub const Context = struct {
    context: *anyopaque,
    callFn: ?*const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value = null,

    pub fn invoke(self: ?Context, callable: Value, arguments: []const Value) !Value {
        const actual = self orelse return error.CallbackExecutionUnavailable;
        const function = actual.callFn orelse return error.CallbackExecutionUnavailable;
        return function(actual.context, callable, arguments);
    }
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    return callWithContext(runtime, name, arguments, null);
}

pub fn callWithContext(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    // 後段プラグインがBufferなど非文字列値を受け取る場合があるため、
    // このモジュールが担当しない命令の引数は先に文字列化しない。
    if (!handles(name)) return null;
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    const c = common.argument(arguments, 2);
    if (units_mod.eql(name, "文字始") or units_mod.eql(name, "文字終")) try requireStringReceiver(a, units_mod.eql(name, "文字始"));
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
    if (units_mod.eql(name, "英数全角変換")) return try trim_case_mod.asciiFullWidth(runtime, a_root, false);
    if (units_mod.eql(name, "英数半角変換")) return try trim_case_mod.fullWidthAscii(runtime, a_root, false);
    if (units_mod.eql(name, "英数記号全角変換")) return try trim_case_mod.asciiFullWidth(runtime, a_root, true);
    if (units_mod.eql(name, "英数記号半角変換")) return try trim_case_mod.fullWidthAscii(runtime, a_root, true);
    if (units_mod.eql(name, "カタカナ全角変換")) return try trim_case_mod.katakanaFullWidth(runtime, a_root, context);
    if (units_mod.eql(name, "カタカナ半角変換")) return try trim_case_mod.katakanaHalfWidth(runtime, a_root, context);
    if (units_mod.eql(name, "全角変換")) {
        var kana = try trim_case_mod.katakanaFullWidth(runtime, a_root, context);
        try text_roots.protect(&kana);
        return try trim_case_mod.asciiFullWidth(runtime, kana, true);
    }
    if (units_mod.eql(name, "半角変換")) {
        var kana = try trim_case_mod.katakanaHalfWidth(runtime, a_root, context);
        try text_roots.protect(&kana);
        return try trim_case_mod.fullWidthAscii(runtime, kana, true);
    }

    if (units_mod.eql(name, "何文字目")) {
        if (a_root == .string and b_root == .string) {
            const index = units_mod.findStringArrayWindow(a_root.string.units, b_root.string.units) orelse 0;
            return .{ .number = @floatFromInt(index) };
        }
        return .{ .number = @floatFromInt(try units_mod.findRawArrayIndex(runtime, a_root, b_root)) };
    }

    var a_text = try runtime.valueToString(a);
    try text_roots.protect(&a_text);
    var b_text = try runtime.valueToString(b);
    try text_roots.protect(&b_text);
    var c_text = try runtime.valueToString(c);
    try text_roots.protect(&c_text);
    if (units_mod.eql(name, "文字数")) return .{ .number = @floatFromInt(units_mod.codePointCount(a_text.string.units)) };
    if (units_mod.eql(name, "CHR")) return try core_mod.chr(runtime, a);
    if (units_mod.eql(name, "ASC")) return try core_mod.asc(runtime, a);
    if (units_mod.eql(name, "文字挿入")) return try core_mod.insert(runtime, a_text, b, c_text);
    if (units_mod.eql(name, "文字検索")) {
        return .{ .number = units_mod.searchCodePoints(a_text.string.units, try runtime.valueToNumber(b), c_text.string.units) };
    }
    if (units_mod.eql(name, "追加") or units_mod.eql(name, "一行追加")) return try core_mod.append(runtime, a, b, a_text, b_text, units_mod.eql(name, "一行追加"));
    if (units_mod.eql(name, "連結") or units_mod.eql(name, "文字列連結")) return try core_mod.joinArguments(runtime, arguments);
    if (units_mod.eql(name, "文字列分解")) return try core_mod.explode(runtime, a_text);
    if (units_mod.eql(name, "リフレイン")) return try core_mod.repeat(runtime, a_text, b);
    if (units_mod.eql(name, "出現回数")) return .{ .number = @floatFromInt(units_mod.countOccurrences(a_text.string.units, b_text.string.units)) };
    if (units_mod.eql(name, "MID") or units_mod.eql(name, "文字抜出")) return try core_mod.mid(runtime, a_text, b, c);
    if (units_mod.eql(name, "LEFT") or units_mod.eql(name, "文字左部分")) return try core_mod.left(runtime, a_text, b);
    if (units_mod.eql(name, "RIGHT") or units_mod.eql(name, "文字右部分")) return try core_mod.right(runtime, a_text, b);
    if (units_mod.eql(name, "区切")) return try core_mod.splitAll(runtime, a_text, b_text);
    if (units_mod.eql(name, "文字列分割")) return try core_mod.splitFirst(runtime, a_text, b_text);
    if (units_mod.eql(name, "文字削除")) return try core_mod.remove(runtime, a_text, b, c);
    if (units_mod.eql(name, "文字始")) return .{ .boolean = units_mod.startsWith(a_text.string.units, b_text.string.units) };
    if (units_mod.eql(name, "文字終")) return .{ .boolean = units_mod.endsWith(a_text.string.units, b_text.string.units) };
    if (units_mod.eql(name, "出現")) return .{ .boolean = if (a == .array) try search_replace_mod.includes(runtime, a, b) else units_mod.indexOfUnits(a_text.string.units, b_text.string.units, 0) != null };
    if (units_mod.eql(name, "置換")) return try search_replace_mod.replace(runtime, a, b, c, true);
    if (units_mod.eql(name, "単置換")) return try search_replace_mod.replace(runtime, a, b, c, false);
    if (units_mod.eql(name, "トリム") or units_mod.eql(name, "空白除去")) return try trim_case_mod.trim(runtime, a_text, true, true);
    if (units_mod.eql(name, "右トリム") or units_mod.eql(name, "末尾空白除去")) return try trim_case_mod.trim(runtime, a_text, false, true);
    if (units_mod.eql(name, "左トリム")) return try trim_case_mod.trim(runtime, a_text, true, false);
    if (units_mod.eql(name, "大文字変換")) return try trim_case_mod.unicodeCase(runtime, a_text, true);
    if (units_mod.eql(name, "小文字変換")) return try trim_case_mod.unicodeCase(runtime, a_text, false);
    if (units_mod.eql(name, "平仮名変換")) return try trim_case_mod.offsetRange(runtime, a_text, 0x30a1, 0x30f6, -0x60);
    if (units_mod.eql(name, "カタカナ変換")) return try trim_case_mod.offsetRange(runtime, a_text, 0x3041, 0x3096, 0x60);
    if (units_mod.eql(name, "通貨形式")) return try format_mod.currency(runtime, a_text);
    if (units_mod.eql(name, "ゼロ埋")) return try format_mod.pad(runtime, a_text, b, '0');
    if (units_mod.eql(name, "空白埋")) return try format_mod.pad(runtime, a_text, b, ' ');
    if (units_mod.eql(name, "かなか判定")) return .{ .boolean = units_mod.firstUnit(a_text.string) >= 0x3041 and units_mod.firstUnit(a_text.string) <= 0x309f };
    if (units_mod.eql(name, "カタカナ判定")) return .{ .boolean = units_mod.firstUnit(a_text.string) >= 0x30a1 and units_mod.firstUnit(a_text.string) <= 0x30fa };
    if (units_mod.eql(name, "数字判定")) return .{ .boolean = units_mod.isDigit(units_mod.firstUnit(a_text.string)) };
    if (units_mod.eql(name, "数列判定")) {
        // 公式はString化より前に元引数との厳密比較を行うため、空文字列だけfalse。
        // 空配列など、String化すると空になる別型は正規表現へ進みtrueになる。
        if (a == .string and a.string.units.len == 0) return .{ .boolean = false };
        return .{ .boolean = units_mod.numberSequence(a_text.string.units) };
    }
    return null;
}

pub fn requireStringReceiver(value: Value, starts: bool) !void {
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

pub fn handles(name: []const u8) bool {
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
    for (commands) |command| if (units_mod.eql(name, command)) return true;
    return false;
}

const cutting_mod = @import("strings/cutting.zig");
const core_mod = @import("strings/core.zig");
const search_replace_mod = @import("strings/search_replace.zig");
const trim_case_mod = @import("strings/trim_case.zig");
const kana_mod = @import("strings/kana.zig");
const format_mod = @import("strings/format.zig");
const units_mod = @import("strings/units.zig");

pub const cut = cutting_mod.cut;
pub const cutRange = cutting_mod.cutRange;

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

pub fn rawArrayNoop(_: *Runtime, _: []const Value) !Value {
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

    var array_buffer_like_length = try runtime.stringUtf8("length");
    var array_buffer_like_zero = try runtime.stringUtf8("0");
    var array_buffer_like_one = try runtime.stringUtf8("1");
    var array_buffer_like_x = try runtime.stringUtf8("x");
    var array_buffer_like_y = try runtime.stringUtf8("y");
    try roots.protect(&array_buffer_like_length);
    try roots.protect(&array_buffer_like_zero);
    try roots.protect(&array_buffer_like_one);
    try roots.protect(&array_buffer_like_x);
    try roots.protect(&array_buffer_like_y);
    try array_buffer.bytes.properties.append(runtime.allocator(), .{ .key = array_buffer_like_length.string, .value = .{ .number = 2 } });
    try array_buffer.bytes.properties.append(runtime.allocator(), .{ .key = array_buffer_like_zero.string, .value = array_buffer_like_x });
    try array_buffer.bytes.properties.append(runtime.allocator(), .{ .key = array_buffer_like_one.string, .value = array_buffer_like_y });
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ array_buffer, try runtime.stringUtf8("xy") })).?.number);
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ array_buffer, try runtime.stringUtf8("x") })).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "何文字目", &.{ array_buffer, try runtime.stringUtf8("xz") })).?.number);

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

    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = @floatFromInt(units_mod.raw_array_element_limit) });
    try std.testing.expectEqual(@as(f64, 1), (try call(&runtime, "何文字目", &.{ object, object_needle })).?.number);
    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = @floatFromInt(units_mod.raw_array_element_limit + 1) });
    try std.testing.expectError(error.ArraySizeLimitExceeded, call(&runtime, "何文字目", &.{ object, object_needle }));
    try common.dictionarySetUtf8(&runtime, object.dictionary, "length", .{ .number = std.math.inf(f64) });
    try std.testing.expectError(error.ArraySizeLimitExceeded, call(&runtime, "何文字目", &.{ object, object_needle }));

    try std.testing.expectError(error.RawArrayNullNotIterable, call(&runtime, "何文字目", &.{ .null_value, source }));
    try std.testing.expectError(error.RawArrayUndefinedNotIterable, call(&runtime, "何文字目", &.{ .undefined, source }));
    try std.testing.expectError(error.RawArrayNullNotIterable, call(&runtime, "何文字目", &.{ source, .null_value }));
    try std.testing.expectError(error.RawArrayUndefinedNotIterable, call(&runtime, "何文字目", &.{ source, .undefined }));
}

pub fn rawArrayAllocationTest(allocator: std.mem.Allocator) !void {
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

pub fn widthConversionAllocationTest(allocator: std.mem.Allocator) !void {
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
    try std.testing.expectError(
        error.StringPadWidthUnbounded,
        call(&runtime, "ゼロ埋", &.{ try runtime.stringUtf8("x"), .{ .number = std.math.inf(f64) } }),
    );
    const negative_infinity_pad = (try call(&runtime, "空白埋", &.{ try runtime.stringUtf8("x"), .{ .number = -std.math.inf(f64) } })).?;
    try std.testing.expectEqualSlices(u16, &.{ ' ', 'x' }, negative_infinity_pad.string.units);
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
    const cut_result = try cutting_mod.cut(&runtime, try runtime.stringUtf8("A😀B"), try runtime.stringUtf8("😀"));
    try std.testing.expectEqualSlices(u16, &.{'A'}, cut_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{'B'}, cut_result.remainder.string.units);

    const range_result = try cutting_mod.cutRange(&runtime, try runtime.stringUtf8("a[b]c[d]e"), try runtime.stringUtf8("["), try runtime.stringUtf8("]"));
    try std.testing.expectEqualSlices(u16, &.{'b'}, range_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'c', '[', 'd', ']', 'e' }, range_result.remainder.string.units);

    const number_result = try cutting_mod.cut(&runtime, try runtime.stringUtf8("123X"), .{ .number = 123 });
    try std.testing.expectEqualSlices(u16, &.{}, number_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '3', 'X' }, number_result.remainder.string.units);

    const dictionary = try runtime.createDictionary();
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "length", .{ .number = 2 });
    const dictionary_result = try cutting_mod.cut(&runtime, try runtime.stringUtf8("[object Object]X"), dictionary);
    try std.testing.expectEqualSlices(u16, &.{}, dictionary_result.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' }, dictionary_result.remainder.string.units);

    const absent = try cutting_mod.cutRange(&runtime, try runtime.stringUtf8("abc"), try runtime.stringUtf8("x"), .null_value);
    try std.testing.expectEqualSlices(u16, &.{}, absent.result.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, absent.remainder.string.units);
    try std.testing.expectError(error.CutNullDelimiterLength, cutting_mod.cut(&runtime, try runtime.stringUtf8("null"), .null_value));
}

test "GCストレス中に非文字列引数を安全に文字列命令へ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    const replaced = (try call(&runtime, "置換", &.{ .{ .number = 12121 }, .{ .number = 1 }, .{ .number = 9 } })).?;
    const utf8 = try replaced.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("92929", utf8);
    const cut_result = try cutting_mod.cutRange(&runtime, .{ .number = 12345 }, .{ .number = 2 }, .{ .number = 4 });
    const middle = try cut_result.result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(middle);
    // The official implementation searches with String(number), then reads
    // number.length (undefined), so each substring endpoint becomes NaN/0.
    try std.testing.expectEqualStrings("123", middle);
}
