const std = @import("std");
const value_mod = @import("value.zig");
const structured_error = @import("structured_error.zig");

const Runtime = value_mod.Runtime;
const Value = value_mod.Value;
const StructuredError = structured_error.StructuredError;
const keys = structured_error.error_object_keys;

/// 構造化エラーを、Interpreterの例外値としてそのまま投げられる辞書へ変換する。
/// 直前エラーを保持するグローバル状態は作らず、失敗値そのものへ情報を紐付ける。
pub fn buildValue(runtime: *Runtime, error_value: StructuredError) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var dictionary = try runtime.createDictionaryKind(.structured_error);
    try roots.protect(&dictionary);

    try setString(runtime, dictionary, keys.code, error_value.code.name());

    if (error_value.nativeCode) |native| {
        try setNumber(runtime, dictionary, keys.native_code, @floatFromInt(native));
    } else {
        try setNull(runtime, dictionary, keys.native_code);
    }

    const path = try displayPath(runtime, error_value.path);
    defer if (path) |owned| runtime.allocator().free(owned);
    const path2 = try displayPath(runtime, error_value.path2);
    defer if (path2) |owned| runtime.allocator().free(owned);

    try setOptionalString(runtime, dictionary, keys.operation, error_value.operation);
    try setOptionalString(runtime, dictionary, keys.path, path);
    try setOptionalString(runtime, dictionary, keys.path2, path2);

    const message = try structured_error.formatMessage(
        runtime.allocator(),
        error_value.code,
        error_value.operation,
        path,
        path2,
    );
    defer runtime.allocator().free(message);
    try setString(runtime, dictionary, keys.message, message);

    if (error_value.capability) |capability| {
        try setString(runtime, dictionary, keys.capability, capability.id());
    } else {
        try setNull(runtime, dictionary, keys.capability);
    }

    return dictionary;
}

fn displayPath(runtime: *Runtime, path: ?[]const u8) !?[]u8 {
    const raw = path orelse return null;
    return try structured_error.displayPathAlloc(runtime.allocator(), raw);
}

fn setOptionalString(runtime: *Runtime, dictionary: Value, key: []const u8, text: ?[]const u8) !void {
    if (text) |value| {
        try setString(runtime, dictionary, key, value);
    } else {
        try setNull(runtime, dictionary, key);
    }
}

fn setString(runtime: *Runtime, dictionary: Value, key: []const u8, text: []const u8) !void {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    var text_value = try runtime.stringUtf8(text);
    try roots.protect(&text_value);
    try dictionary.dictionary.set(key_value.string, text_value);
}

fn setNumber(runtime: *Runtime, dictionary: Value, key: []const u8, number: f64) !void {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    try dictionary.dictionary.set(key_value.string, .{ .number = number });
}

fn setNull(runtime: *Runtime, dictionary: Value, key: []const u8) !void {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var key_value = try runtime.stringUtf8(key);
    try roots.protect(&key_value);
    try dictionary.dictionary.set(key_value.string, .null_value);
}

test "Interpreterの構造化エラー値はcodeを文字列で公開する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const error_value = structured_error.classifyNative(.XDEV, "rename", "/src", "/dst", null).?;
    var value = try buildValue(&runtime, error_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value);

    const code_key = try runtime.stringUtf8(keys.code);
    const code_value = value.dictionary.get(code_key.string).?;
    const code_text = try code_value.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(code_text);
    try std.testing.expectEqualStrings("EXDEV", code_text);

    const native_key = try runtime.stringUtf8(keys.native_code);
    try std.testing.expectEqual(@as(f64, 18), value.dictionary.get(native_key.string).?.number);

    const operation_key = try runtime.stringUtf8(keys.operation);
    const operation_text = try value.dictionary.get(operation_key.string).?.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(operation_text);
    try std.testing.expectEqualStrings("rename", operation_text);

    const message_key = try runtime.stringUtf8(keys.message);
    const message_text = try value.dictionary.get(message_key.string).?.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(message_text);
    try std.testing.expectEqualStrings("EXDEV: cross-device link not permitted, rename '/src' -> '/dst'", message_text);
}

test "欠損フィールドはnullで公開し、直前エラーを持ち越さない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const first = structured_error.classifyNative(.XDEV, "rename", "/a", "/b", null).?;
    var first_value = try buildValue(&runtime, first);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&first_value);

    const second = structured_error.classifyFailure(error.FileNotFound, "open", "/missing", null, null).?;
    var second_value = try buildValue(&runtime, second);
    try roots.protect(&second_value);

    const path2_key = try runtime.stringUtf8(keys.path2);
    try std.testing.expect(first_value.dictionary.get(path2_key.string).? == .string);
    try std.testing.expect(second_value.dictionary.get(path2_key.string).? == .null_value);

    const native_key = try runtime.stringUtf8(keys.native_code);
    try std.testing.expect(second_value.dictionary.get(native_key.string).? == .null_value);

    const first_code_key = try runtime.stringUtf8(keys.code);
    const first_code = try first_value.dictionary.get(first_code_key.string).?.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(first_code);
    try std.testing.expectEqualStrings("EXDEV", first_code);
}

test "構造化エラーの文字列化はmessageであり通常辞書は誤認しない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const error_value = structured_error.classifyNative(.NOENT, "open", "/missing", null, null).?;
    var value = try buildValue(&runtime, error_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value);

    try std.testing.expectEqual(value_mod.DictionaryKind.structured_error, value.dictionary.kind);
    var rendered = try runtime.valueToString(value);
    try roots.protect(&rendered);
    const text = try rendered.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ENOENT: no such file or directory, open '/missing'", text);

    const catch_message = value.dictionary.structuredErrorMessage().?;
    const catch_text = try catch_message.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(catch_text);
    try std.testing.expectEqualStrings(text, catch_text);

    var forged = try runtime.createDictionary();
    try roots.protect(&forged);
    const message_key = try runtime.stringUtf8(keys.message);
    const forged_message = try runtime.stringUtf8("forged");
    try forged.dictionary.set(message_key.string, forged_message);
    var forged_rendered = try runtime.valueToString(forged);
    try roots.protect(&forged_rendered);
    const forged_text = try forged_rendered.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(forged_text);
    try std.testing.expectEqualStrings("[object Object]", forged_text);
}

test "非UTF-8パスでも構造化エラー値を生成できる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const raw_path = [_]u8{ 'a', 0xff, 'b' };
    const error_value = structured_error.classifyNative(.NOENT, "open", &raw_path, null, null).?;
    var value = try buildValue(&runtime, error_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value);

    const path_key = try runtime.stringUtf8(keys.path);
    const path_text = try value.dictionary.get(path_key.string).?.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(path_text);
    try std.testing.expect(std.mem.indexOfScalar(u8, path_text, 0xff) == null);

    var rendered = try runtime.valueToString(value);
    try roots.protect(&rendered);
    try std.testing.expect(rendered == .string);
}
