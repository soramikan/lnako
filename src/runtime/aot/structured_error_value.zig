const std = @import("std");
const aot_state = @import("state.zig");
const structured_error = @import("../structured_error.zig");

const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const RootFrame = aot_state.RootFrame;
const Tag = aot_state.Tag;
const numberValue = aot_state.numberValue;
const staticStringValue = aot_state.staticStringValue;
const runtimeUtf8String = aot_state.runtimeUtf8String;

const StructuredError = structured_error.StructuredError;
const keys = structured_error.error_object_keys;

const null_value: Value = .{ .tag = @intFromEnum(Tag.null_value), .payload = 0 };

/// 構造化エラーを、AOTランタイムの辞書値へ変換する。Interpreter側
/// `structured_error_value.buildValue` と同じportable `code` を公開する。
pub fn buildValue(runtime: *Runtime, error_value: StructuredError) !Value {
    var roots = [_]Value{
        staticStringValue(keys.code),        null_value,
        staticStringValue(keys.native_code), null_value,
        staticStringValue(keys.operation),   null_value,
        staticStringValue(keys.path),        null_value,
        staticStringValue(keys.path2),       null_value,
        staticStringValue(keys.message),     null_value,
        staticStringValue(keys.capability),  null_value,
    };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[1] = try runtimeUtf8String(runtime, error_value.code.name());

    if (error_value.nativeCode) |native| {
        roots[3] = numberValue(@floatFromInt(native));
    }

    const path = try displayPath(runtime, error_value.path);
    defer if (path) |owned| runtime.allocator.free(owned);
    const path2 = try displayPath(runtime, error_value.path2);
    defer if (path2) |owned| runtime.allocator.free(owned);

    if (error_value.operation) |operation| {
        roots[5] = try runtimeUtf8String(runtime, operation);
    }
    if (path) |text| {
        roots[7] = try runtimeUtf8String(runtime, text);
    }
    if (path2) |text| {
        roots[9] = try runtimeUtf8String(runtime, text);
    }

    const message = try structured_error.formatMessage(
        runtime.allocator,
        error_value.code,
        error_value.operation,
        path,
        path2,
    );
    defer runtime.allocator.free(message);
    roots[11] = try runtimeUtf8String(runtime, message);

    if (error_value.capability) |capability| {
        roots[13] = try runtimeUtf8String(runtime, capability.id());
    }

    const dictionary = try runtime.createDictionary(&roots);
    if (dictionary.object()) |object| object.structured_error = true;
    return dictionary;
}

fn displayPath(runtime: *Runtime, path: ?[]const u8) !?[]u8 {
    const raw = path orelse return null;
    return try structured_error.displayPathAlloc(runtime.allocator, raw);
}

test "AOTの構造化エラー値はInterpreterと同じcodeを公開する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const error_value = structured_error.classifyNative(.XDEV, "rename", "/src", "/dst", null).?;
    const value = try buildValue(&runtime, error_value);
    var roots = [_]Value{value};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try expectDictionaryText(&runtime, value, &.{ 'c', 'o', 'd', 'e' }, "EXDEV");
    try expectDictionaryText(&runtime, value, &.{ 'o', 'p', 'e', 'r', 'a', 't', 'i', 'o', 'n' }, "rename");
    try expectDictionaryText(&runtime, value, &.{ 'p', 'a', 't', 'h' }, "/src");
    try expectDictionaryText(&runtime, value, &.{ 'p', 'a', 't', 'h', '2' }, "/dst");
    try expectDictionaryText(
        &runtime,
        value,
        &.{ 'm', 'e', 's', 's', 'a', 'g', 'e' },
        "EXDEV: cross-device link not permitted, rename '/src' -> '/dst'",
    );

    const native_value = aot_state.dictionaryProperty(value, &.{ 'n', 'a', 't', 'i', 'v', 'e', 'C', 'o', 'd', 'e' });
    try std.testing.expectEqual(@intFromEnum(Tag.number), native_value.tag);
    try std.testing.expectEqual(@as(f64, 18), @as(f64, @bitCast(native_value.payload)));

    const capability_value = aot_state.dictionaryProperty(value, &.{ 'c', 'a', 'p', 'a', 'b', 'i', 'l', 'i', 't', 'y' });
    try std.testing.expectEqual(@intFromEnum(Tag.null_value), capability_value.tag);

    try std.testing.expect(value.object().?.structured_error);
    const rendered_units = try aot_state.valueUtf16Alloc(&runtime, value);
    defer runtime.allocator.free(rendered_units);
    const rendered = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, rendered_units);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "EXDEV: cross-device link not permitted, rename '/src' -> '/dst'",
        rendered,
    );
}

test "AOTの通常辞書はmessageキーがあっても構造化エラーにならない" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    var pairs = [_]Value{
        aot_state.staticStringValue("message"),
        try aot_state.runtimeUtf8String(&runtime, "forged"),
    };
    const forged = try runtime.createDictionary(&pairs);
    var roots = [_]Value{forged};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expect(!forged.object().?.structured_error);
    const units = try aot_state.valueUtf16Alloc(&runtime, forged);
    defer runtime.allocator.free(units);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, units);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[object Object]", text);
}

test "AOTは非UTF-8パスでも構造化エラー値を生成できる" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const raw_path = [_]u8{ 'a', 0xff, 'b' };
    const error_value = structured_error.classifyNative(.NOENT, "open", &raw_path, null, null).?;
    const value = try buildValue(&runtime, error_value);
    var roots = [_]Value{value};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try expectDictionaryText(&runtime, value, &.{ 'p', 'a', 't', 'h' }, "a\u{FFFD}b");
    const units = try aot_state.valueUtf16Alloc(&runtime, value);
    defer runtime.allocator.free(units);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, units);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0xff) == null);
}

test "AOTはmessageを非文字列にしても文字列化は止まらない" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const error_value = structured_error.classifyNative(.NOENT, "open", "/missing", null, null).?;
    var roots = [_]Value{
        try buildValue(&runtime, error_value),
        aot_state.staticStringValue("message"),
        numberValue(1),
    };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
    const units = try aot_state.valueUtf16Alloc(&runtime, roots[0]);
    defer runtime.allocator.free(units);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, units);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[object Object]", text);
}

fn expectDictionaryText(runtime: *Runtime, dictionary: Value, key: []const u16, expected: []const u8) !void {
    const property = aot_state.dictionaryProperty(dictionary, key);
    const units = try aot_state.valueUtf16Alloc(runtime, property);
    defer runtime.allocator.free(units);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, units);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}
