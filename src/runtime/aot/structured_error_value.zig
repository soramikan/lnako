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

    if (error_value.operation) |operation| {
        roots[5] = try runtimeUtf8String(runtime, operation);
    }
    if (error_value.path) |path| {
        roots[7] = try runtimeUtf8String(runtime, path);
    }
    if (error_value.path2) |path2| {
        roots[9] = try runtimeUtf8String(runtime, path2);
    }

    const message = try structured_error.formatMessage(
        runtime.allocator,
        error_value.code,
        error_value.operation,
        error_value.path,
        error_value.path2,
    );
    defer runtime.allocator.free(message);
    roots[11] = try runtimeUtf8String(runtime, message);

    if (error_value.capability) |capability| {
        roots[13] = try runtimeUtf8String(runtime, capability.id());
    }

    return runtime.createDictionary(&roots);
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
}

fn expectDictionaryText(runtime: *Runtime, dictionary: Value, key: []const u16, expected: []const u8) !void {
    const property = aot_state.dictionaryProperty(dictionary, key);
    const units = try aot_state.valueUtf16Alloc(runtime, property);
    defer runtime.allocator.free(units);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, units);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}
