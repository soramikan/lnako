const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_locale = @import("../../runtime/low_level_locale.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
const node_shared = @import("../node/shared.zig");
const shared = @import("shared.zig");
// ドメインテストはディスパッチャ経由で契約を検査する。本番ビルドでは
// call.zigを解析しないよう、テスト時にだけ読み込んで閉路を避ける。
const call = if (builtin.is_test) @import("call.zig").call else void;

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;
const emptyContext = low_level_context.emptyContext;

const throwStructured = shared.throwStructured;
const captureThrow = shared.captureThrow;
const expectThrownCode = shared.expectThrownCode;
const expectThrownField = shared.expectThrownField;

/// `ロケール文字列比較(A, B, OPTIONS)`。OPTIONS省略・`{locale: "C"}` 等の
/// Cロケール系名はcallback非依存のbytewise比較（3OS一致）。非Cロケールは
/// hostのcollate callbackへ委譲し、未提供・未対応は `locale_collate`
/// capabilityを付けた構造化ENOTSUPになる。
pub fn localeCompare(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    const operation = foundation.locale_operations.collate;
    const a_value = common.argument(arguments, 0);
    const b_value = common.argument(arguments, 1);
    if (a_value != .string or b_value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "AとBは文字列である必要があります");
    }
    const a = try node_shared.valueUtf8(runtime, a_value);
    defer runtime.allocator().free(a);
    const b = try node_shared.valueUtf8(runtime, b_value);
    defer runtime.allocator().free(b);

    var locale_name: []const u8 = "";
    var locale_owned: ?[]u8 = null;
    defer if (locale_owned) |name| runtime.allocator().free(name);
    const options = common.argument(arguments, 2);
    if (options != .undefined and options != .null_value) {
        if (options != .dictionary) {
            return throwStructured(runtime, effects, .EINVAL, operation, null, null, "OPTIONSは辞書である必要があります");
        }
        if (node_shared.dictionaryGetAscii(options.dictionary, foundation.collate_option_keys.locale)) |locale_value| {
            if (locale_value != .undefined and locale_value != .null_value) {
                if (locale_value != .string) {
                    return throwStructured(runtime, effects, .EINVAL, operation, null, null, "localeは文字列である必要があります");
                }
                locale_owned = try node_shared.valueUtf8(runtime, locale_value);
                locale_name = locale_owned.?;
            }
        }
    }
    return compareResult(runtime, context, effects, operation, locale_name, a, b);
}

fn compareResult(runtime: *Runtime, context: Context, effects: Effects, operation: []const u8, locale_name: []const u8, a: []const u8, b: []const u8) !Value {
    // Cロケール系名はhost callbackを使わないportable経路（OS一致保証）。
    const order = if (low_level_locale.isCLocaleName(locale_name))
        low_level_locale.compareBytewise(a, b)
    else
        context.collateLocale(runtime.allocator(), locale_name, a, b) catch |failure| {
            if (failure == error.OutOfMemory) return failure;
            if (failure == error.InvalidLocale) {
                return throwStructured(runtime, effects, .EINVAL, operation, null, null, "locale名が不正です");
            }
            return throwStructured(runtime, effects, .ENOTSUP, operation, null, foundation.Capability.locale_collate.id(), "このロケールの照合は利用できません");
        };
    return .{ .number = @floatFromInt(order) };
}

/// `文字表示幅取得(TEXT)`。端末表示セル幅を返す純粋計算で、host callbackは
/// 使わない。East Asian Width・結合文字・絵文字・ZWJ列・制御文字・
/// 不正UTF-8は `low_level_locale.displayWidth` の規則に従う。
pub fn displayWidth(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    _ = state;
    _ = context;
    const operation = foundation.locale_operations.width;
    const text_value = common.argument(arguments, 0);
    if (text_value != .string) {
        return throwStructured(runtime, effects, .EINVAL, operation, null, null, "TEXTは文字列である必要があります");
    }
    const text = try node_shared.valueUtf8(runtime, text_value);
    defer runtime.allocator().free(text);
    return .{ .number = @floatFromInt(low_level_locale.displayWidth(text)) };
}

test "Interpreter低レイヤーのロケール比較はCロケールをbytewiseで返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var a = try runtime.stringUtf8("abc");
    try roots.protect(&a);
    var b = try runtime.stringUtf8("abd");
    try roots.protect(&b);
    // OPTIONS省略はCロケールbytewise。host callbackが無くても動作する。
    var result = (try call(&runtime, &state, emptyContext(), effects, "ロケール文字列比較", &.{ a, b })).?;
    try std.testing.expect(result == .number and result.number == -1);

    var locale = try runtime.stringUtf8("C.UTF-8");
    try roots.protect(&locale);
    var options = try runtime.createDictionary();
    try roots.protect(&options);
    try node_shared.setDictionary(&runtime, options.dictionary, "locale", locale);
    result = (try call(&runtime, &state, emptyContext(), effects, "ロケール文字列比較", &.{ b, a, options })).?;
    try std.testing.expect(result == .number and result.number == 1);

    // 等値と空文字の規則。
    result = (try call(&runtime, &state, emptyContext(), effects, "ロケール文字列比較", &.{ a, a })).?;
    try std.testing.expect(result == .number and result.number == 0);
    var empty = try runtime.stringUtf8("");
    try roots.protect(&empty);
    result = (try call(&runtime, &state, emptyContext(), effects, "ロケール文字列比較", &.{ empty, a })).?;
    try std.testing.expect(result == .number and result.number == -1);
}

test "Interpreter低レイヤーのロケール比較はcallback経由で非Cロケールを照合する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    // 逆順比較を返すダミーcollator。callbackが実際に使われることを検査する。
    const Reverse = struct {
        fn collate(_: *anyopaque, _: std.mem.Allocator, _: []const u8, a: []const u8, b: []const u8) anyerror!i8 {
            return switch (std.mem.order(u8, a, b)) {
                .lt => 1,
                .eq => 0,
                .gt => -1,
            };
        }
    };
    var host: u8 = 0;
    const context = Context{ .locale = .{
        .context = @ptrCast(&host),
        .collateFn = Reverse.collate,
    } };

    var a = try runtime.stringUtf8("a");
    try roots.protect(&a);
    var b = try runtime.stringUtf8("b");
    try roots.protect(&b);
    var locale = try runtime.stringUtf8("xx_YY");
    try roots.protect(&locale);
    var options = try runtime.createDictionary();
    try roots.protect(&options);
    try node_shared.setDictionary(&runtime, options.dictionary, "locale", locale);
    const result = (try call(&runtime, &state, context, effects, "ロケール文字列比較", &.{ a, b, options })).?;
    try std.testing.expect(result == .number and result.number == 1);

    // callbackが無いと非Cロケールは構造化ENOTSUP（capability付き）。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "ロケール文字列比較", &.{ a, b, options }));
    try expectThrownCode(&runtime, thrown, "ENOTSUP");
    try expectThrownField(&runtime, thrown, foundation.error_object_keys.capability, "locale_collate");

    // 非文字列引数と非辞書OPTIONSはEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ロケール文字列比較", &.{ a, .{ .number = 1 } }));
    try expectThrownCode(&runtime, thrown, "EINVAL");
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ロケール文字列比較", &.{ a, b, .{ .number = 1 } }));
    try expectThrownCode(&runtime, thrown, "EINVAL");

    // localeが非文字列もEINVAL。
    var bad_locale = try runtime.createDictionary();
    try roots.protect(&bad_locale);
    try node_shared.setDictionary(&runtime, bad_locale.dictionary, "locale", .{ .number = 1 });
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ロケール文字列比較", &.{ a, b, bad_locale }));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "Interpreter低レイヤーの表示幅は全角・結合文字・絵文字を数える" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var ascii = try runtime.stringUtf8("hello");
    try roots.protect(&ascii);
    var result = (try call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{ascii})).?;
    try std.testing.expect(result == .number and result.number == 5);

    var jp = try runtime.stringUtf8("こんにちは");
    try roots.protect(&jp);
    result = (try call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{jp})).?;
    try std.testing.expect(result == .number and result.number == 10);

    var combining = try runtime.stringUtf8("e\u{301}");
    try roots.protect(&combining);
    result = (try call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{combining})).?;
    try std.testing.expect(result == .number and result.number == 1);

    var emoji = try runtime.stringUtf8("👨‍👩‍👧‍👦");
    try roots.protect(&emoji);
    result = (try call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{emoji})).?;
    try std.testing.expect(result == .number and result.number == 2);

    var flag = try runtime.stringUtf8("🇯🇵");
    try roots.protect(&flag);
    result = (try call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{flag})).?;
    try std.testing.expect(result == .number and result.number == 2);

    // 非文字列はEINVAL。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, emptyContext(), effects, "文字表示幅取得", &.{.{ .number = 1 }}));
    try expectThrownCode(&runtime, thrown, "EINVAL");
}

test "Interpreter低レイヤーのlocale capabilityはcallback有無を反映する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var collate_name = try runtime.stringUtf8("locale_collate");
    try roots.protect(&collate_name);
    const unsupported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{collate_name})).?;
    try std.testing.expect(unsupported == .boolean and !unsupported.boolean);

    const Dummy = struct {
        fn collate(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!i8 {
            return 0;
        }
    };
    var host: u8 = 0;
    const context = Context{ .locale = .{
        .context = @ptrCast(&host),
        .collateFn = Dummy.collate,
    } };
    const supported = (try call(&runtime, &state, context, effects, foundation.capability_supported_command, &.{collate_name})).?;
    try std.testing.expect(supported == .boolean and supported.boolean);

    // display_widthは純粋計算のためcallbackなしでtrue。
    var width_name = try runtime.stringUtf8("display_width");
    try roots.protect(&width_name);
    const width_supported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{width_name})).?;
    try std.testing.expect(width_supported == .boolean and width_supported.boolean);
}
