const std = @import("std");
const builtin = @import("builtin");
const state = @import("../state.zig");
const shared = @import("shared.zig");
const foundation = @import("../../low_level_foundation.zig");
const low_level_locale = @import("../../low_level_locale.zig");

const Runtime = shared.Runtime;
const Value = shared.Value;
const Tag = shared.Tag;
const RootFrame = shared.RootFrame;
const numberValue = shared.numberValue;
const valueUtf8LossyAlloc = shared.valueUtf8LossyAlloc;
const runtimeUtf8String = shared.runtimeUtf8String;
const isString = shared.isString;
const dictionaryOwnProperty = shared.dictionaryOwnProperty;
const throwStructured = shared.throwStructured;
const expectPendingCode = shared.expectPendingCode;

const lowLevelLocaleBuiltin = if (builtin.is_test) @import("../low_level.zig").lowLevelLocaleBuiltin else void;
const aot_builtin = shared.aot_builtin;

/// `Context.locale.collateFn`（pluginContext）の実装。非Cロケールの照合を
/// `low_level_locale` のOS実装へ委譲する。InterpreterのCliHostと同じ
/// callback契約で、WASI等では内部でLocaleCollateUnsupportedになる。
pub fn pluginCollate(context: *anyopaque, allocator: std.mem.Allocator, locale: []const u8, a: []const u8, b: []const u8) anyerror!i8 {
    _ = context;
    return low_level_locale.collate(allocator, locale, a, b);
}

/// `ロケール文字列比較(A, B, OPTIONS)`。OPTIONS省略・Cロケール系名は
/// bytewise比較（3OS・経路一致）、非CロケールはOS照合機能へ委譲する。
/// Interpreter側 `plugins/lowlevel/locale.zig` と同じ契約。
pub fn localeCompareBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.locale_operations.collate;
    if (arguments.len < 2 or !isString(arguments[0]) or !isString(arguments[1])) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "AとBは文字列である必要があります");
    }
    const a = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(a);
    const b = try valueUtf8LossyAlloc(runtime, arguments[1]);
    defer runtime.allocator.free(b);

    var locale_name: []const u8 = "";
    var locale_owned: ?[]u8 = null;
    defer if (locale_owned) |name| runtime.allocator.free(name);
    if (arguments.len >= 3) {
        const options = arguments[2];
        switch (options.tag) {
            @intFromEnum(Tag.undefined), @intFromEnum(Tag.null_value) => {},
            @intFromEnum(Tag.dictionary) => {
                if (dictionaryOwnProperty(options, &.{ 'l', 'o', 'c', 'a', 'l', 'e' })) |locale_value| {
                    switch (locale_value.tag) {
                        @intFromEnum(Tag.undefined), @intFromEnum(Tag.null_value) => {},
                        @intFromEnum(Tag.static_utf8_string), @intFromEnum(Tag.utf16_string) => {
                            locale_owned = try valueUtf8LossyAlloc(runtime, locale_value);
                            locale_name = locale_owned.?;
                        },
                        else => return throwStructured(runtime, .EINVAL, operation, null, null, "localeは文字列である必要があります"),
                    }
                }
            },
            else => return throwStructured(runtime, .EINVAL, operation, null, null, "OPTIONSは辞書である必要があります"),
        }
    }
    const order = low_level_locale.collate(runtime.allocator, locale_name, a, b) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        if (failure == error.InvalidLocale) {
            return throwStructured(runtime, .EINVAL, operation, null, null, "locale名が不正です");
        }
        return throwStructured(runtime, .ENOTSUP, operation, null, foundation.Capability.locale_collate.id(), "このロケールの照合は利用できません");
    };
    return numberValue(@floatFromInt(order));
}

/// `文字表示幅取得(TEXT)`。`low_level_locale.displayWidth` の純粋計算で、
/// Interpreterと同一規則の端末表示セル幅を返す。
pub fn displayWidthBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    const operation = foundation.locale_operations.width;
    if (arguments.len < 1 or !isString(arguments[0])) {
        return throwStructured(runtime, .EINVAL, operation, null, null, "TEXTは文字列である必要があります");
    }
    const text = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(text);
    return numberValue(@floatFromInt(low_level_locale.displayWidth(text)));
}

test "AOT低レイヤーのロケール比較はInterpreterと同じ契約で返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var rooted = [_]Value{ .{}, .{}, .{}, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);

    rooted[0] = try runtimeUtf8String(&runtime, "abc");
    rooted[1] = try runtimeUtf8String(&runtime, "abd");
    const aot_builtin_command: aot_builtin.Command = .low_level_locale_compare;
    var result = try lowLevelLocaleBuiltin(&runtime, aot_builtin_command, rooted[0..2]);
    try std.testing.expect(result.tag == @intFromEnum(Tag.number) and shared.valueToNumber(result) == -1);

    const reversed = [_]Value{ rooted[1], rooted[0] };
    result = try lowLevelLocaleBuiltin(&runtime, aot_builtin_command, &reversed);
    try std.testing.expect(result.tag == @intFromEnum(Tag.number) and shared.valueToNumber(result) == 1);

    // locale=C.UTF-8指定もbytewise。
    rooted[2] = try runtime.createDictionary(&.{});
    rooted[3] = try runtimeUtf8String(&runtime, "locale");
    try runtime.setDictionary(&rooted[2].object().?.payload.dictionary, rooted[3], try runtimeUtf8String(&runtime, "C.UTF-8"));
    const args = [_]Value{ rooted[0], rooted[1], rooted[2] };
    result = try lowLevelLocaleBuiltin(&runtime, aot_builtin_command, &args);
    try std.testing.expect(result.tag == @intFromEnum(Tag.number) and shared.valueToNumber(result) == -1);

    // 未インストールの可能性が高いロケールは、照合できれば結果、
    // 未対応なら構造化ENOTSUP（capability付き）になる。
    rooted[3] = try runtimeUtf8String(&runtime, "locale");
    try runtime.setDictionary(&rooted[2].object().?.payload.dictionary, rooted[3], try runtimeUtf8String(&runtime, "zz_ZZ"));
    const maybe = lowLevelLocaleBuiltin(&runtime, aot_builtin_command, &args) catch |failure| blk: {
        try std.testing.expect(failure == error.NakoException);
        try expectPendingCode(&runtime, "ENOTSUP");
        _ = runtime.takeException();
        break :blk null;
    };
    if (maybe) |value| {
        try std.testing.expect(value.tag == @intFromEnum(Tag.number));
    }

    // 非文字列引数はEINVAL。
    const bad_args = [_]Value{ rooted[0], numberValue(1) };
    try std.testing.expectError(error.NakoException, lowLevelLocaleBuiltin(&runtime, aot_builtin_command, &bad_args));
    try expectPendingCode(&runtime, "EINVAL");
    _ = runtime.takeException();
}

test "AOT低レイヤーの表示幅はInterpreterと同じ規則を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var rooted = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    const command: aot_builtin.Command = .low_level_display_width;

    rooted[0] = try runtimeUtf8String(&runtime, "hello");
    var result = try displayWidthBuiltin(&runtime, rooted[0..1]);
    try std.testing.expect(result.tag == @intFromEnum(Tag.number) and shared.valueToNumber(result) == 5);

    rooted[1] = try runtimeUtf8String(&runtime, "こんにちは");
    result = try displayWidthBuiltin(&runtime, rooted[1..2]);
    try std.testing.expect(shared.valueToNumber(result) == 10);

    rooted[2] = try runtimeUtf8String(&runtime, "e\u{301}");
    result = try displayWidthBuiltin(&runtime, rooted[2..3]);
    try std.testing.expect(shared.valueToNumber(result) == 1);

    rooted[3] = try runtimeUtf8String(&runtime, "👨‍👩‍👧‍👦");
    result = try displayWidthBuiltin(&runtime, rooted[3..4]);
    try std.testing.expect(shared.valueToNumber(result) == 2);

    rooted[4] = try runtimeUtf8String(&runtime, "🇯🇵");
    result = try displayWidthBuiltin(&runtime, rooted[4..5]);
    try std.testing.expect(shared.valueToNumber(result) == 2);

    const bad = [_]Value{numberValue(1)};
    try std.testing.expectError(error.NakoException, displayWidthBuiltin(&runtime, &bad));
    try expectPendingCode(&runtime, "EINVAL");
    _ = runtime.takeException();
    _ = command;
}
