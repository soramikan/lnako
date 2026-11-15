const std = @import("std");
const state = @import("state.zig");
const compat = @import("compat_js.zig");
const compat_result = @import("compat_js_result.zig");

// `compat_js.zig` の ABI 面（`lnako_aot_compat_*`）と、そこから使う FFI・
// 変換ヘルパーをテストからも直接参照する。
const ensureEngine = compat.ensureEngine;
const lnako_aot_compat_deinit = compat.lnako_aot_compat_deinit;
const lnako_aot_compat_esm_register = compat.lnako_aot_compat_esm_register;
const lnako_aot_compat_js_call = compat.lnako_aot_compat_js_call;
const lnako_aot_compat_js_eval = compat.lnako_aot_compat_js_eval;
const lnako_aot_compat_js_method_call = compat.lnako_aot_compat_js_method_call;
const lnako_aot_compat_js_object_get = compat.lnako_aot_compat_js_object_get;
const lnako_qjs_eval = compat.lnako_qjs_eval;
const lnako_qjs_value_free = compat.lnako_qjs_value_free;
const shallowDictionaryFromRaw = compat_result.shallowDictionaryFromRaw;

const Value = state.Value;
const Tag = state.Tag;

test "compat AOT runtimeはQuickJS engineを遅延生成する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    _ = try ensureEngine();
    try std.testing.expect(compat.activeEngine() != null);
    lnako_aot_compat_deinit();
    try std.testing.expect(compat.activeEngine() == null);
}

test "compat AOT runtimeはJS実行をQuickJSへdispatchする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "1+2");
    defer std.testing.allocator.free(units);
    var arguments = [_]Value{try state.active_runtime.?.createString(units)};
    var out: Value = .{};
    lnako_aot_compat_js_eval(&out, &arguments, arguments.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行を配列引数でdispatchする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(a,b)=>a+b");
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    var numbers = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&arguments[1], &numbers, numbers.len);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行で文字列・真偽値・null・undefinedを往復する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(
        std.testing.allocator,
        "(s, b, n, u) => s + ':' + b + ':' + (n === null) + ':' + (u === undefined)",
    );
    defer std.testing.allocator.free(source_units);
    const text_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x");
    defer std.testing.allocator.free(text_units);
    var call_arguments = [_]Value{ .{}, .{}, .{}, .{} };
    var call_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&call_frame, &call_arguments, call_arguments.len);
    defer state.active_runtime.?.popRoots(&call_frame);
    call_arguments[0] = try state.active_runtime.?.createString(text_units);
    call_arguments[1] = .{ .tag = @backingInt(Tag.boolean), .payload = 1 };
    call_arguments[2] = .{ .tag = @backingInt(Tag.null_value) };
    call_arguments[3] = .{};
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    state.lnako_aot_array_new(&arguments[1], &call_arguments, call_arguments.len);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, out);
    defer std.testing.allocator.free(units);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 'x', ':', 't', 'r', 'u', 'e', ':', 't', 'r', 'u', 'e', ':', 't', 'r', 'u', 'e' }, units);
    lnako_aot_compat_deinit();
}

fn expectPendingFailureContains(runtime: *state.Runtime, expected: []const u8) !void {
    try std.testing.expect(runtime.has_pending_exception);
    const message = runtime.takeException();
    const units = try state.valueUtf16Alloc(runtime, message);
    defer std.testing.allocator.free(units);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(expected_units);
    try std.testing.expect(std.mem.indexOf(u16, units, expected_units) != null);
}

fn noopFunction(_: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {}

test "compat AOT runtimeはJS関数実行の配列実引数をJS配列へ変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(a)=>a[0]+a[1]");
    defer std.testing.allocator.free(source_units);
    // [0]=callable, [1]=実引数コンテナ。GC中も値を保持するためscratchをrootする。
    var arguments = [_]Value{ .{}, .{} };
    var scratch = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    var scratch_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    state.active_runtime.?.pushRoots(&scratch_frame, &scratch, scratch.len);
    defer {
        state.active_runtime.?.popRoots(&scratch_frame);
        state.active_runtime.?.popRoots(&arguments_frame);
    }
    arguments[0] = try state.active_runtime.?.createString(source_units);
    var inner = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&scratch[0], &inner, inner.len);
    var container = [_]Value{scratch[0]};
    state.lnako_aot_array_new(&arguments[1], &container, container.len);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の辞書実引数をJSオブジェクトへ変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(o)=>o.x+o.y");
    defer std.testing.allocator.free(source_units);
    const x_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x");
    defer std.testing.allocator.free(x_units);
    const y_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "y");
    defer std.testing.allocator.free(y_units);
    var arguments = [_]Value{ .{}, .{} };
    var scratch = [_]Value{ .{}, .{}, .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    var scratch_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    state.active_runtime.?.pushRoots(&scratch_frame, &scratch, scratch.len);
    defer {
        state.active_runtime.?.popRoots(&scratch_frame);
        state.active_runtime.?.popRoots(&arguments_frame);
    }
    arguments[0] = try state.active_runtime.?.createString(source_units);
    // 辞書は「非配列の第2オペランド」なので単一実引数として渡る。
    scratch[0] = try state.active_runtime.?.createString(x_units);
    scratch[1] = state.numberValue(10);
    scratch[2] = try state.active_runtime.?.createString(y_units);
    scratch[3] = state.numberValue(20);
    state.lnako_aot_dictionary_new(&arguments[1], &scratch, scratch.len);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 30), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の空配列・空辞書を渡す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var arguments = [_]Value{ .{}, .{} };
    var scratch = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    var scratch_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    state.active_runtime.?.pushRoots(&scratch_frame, &scratch, scratch.len);
    defer {
        state.active_runtime.?.popRoots(&scratch_frame);
        state.active_runtime.?.popRoots(&arguments_frame);
    }
    var out: Value = .{};

    // 空配列: コンテナの要素が空配列1個。
    const length_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(a)=>a.length");
    defer std.testing.allocator.free(length_units);
    arguments[0] = try state.active_runtime.?.createString(length_units);
    state.lnako_aot_array_new(&scratch[0], null, 0);
    var array_container = [_]Value{scratch[0]};
    state.lnako_aot_array_new(&arguments[1], &array_container, array_container.len);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(out.payload)));

    // 空辞書: 非配列の第2オペランドなので単一実引数。
    const keys_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(o)=>Object.keys(o).length");
    defer std.testing.allocator.free(keys_units);
    arguments[0] = try state.active_runtime.?.createString(keys_units);
    state.lnako_aot_dictionary_new(&arguments[1], null, 0);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の未対応引数を明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x => 1");
    defer std.testing.allocator.free(source_units);
    const x_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x");
    defer std.testing.allocator.free(x_units);
    var arguments = [_]Value{ .{}, .{} };
    var scratch = [_]Value{ .{}, .{}, .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    var scratch_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    state.active_runtime.?.pushRoots(&scratch_frame, &scratch, scratch.len);
    defer {
        state.active_runtime.?.popRoots(&scratch_frame);
        state.active_runtime.?.popRoots(&arguments_frame);
    }
    arguments[0] = try state.active_runtime.?.createString(source_units);
    scratch[3] = try state.active_runtime.?.createString(x_units);
    var out: Value = .{};

    // ネストした配列: コンテナの要素が配列で、その要素も配列。
    var nested_inner = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&scratch[0], &nested_inner, nested_inner.len);
    var nested_middle = [_]Value{scratch[0]};
    state.lnako_aot_array_new(&scratch[1], &nested_middle, nested_middle.len);
    var nested_container = [_]Value{scratch[1]};
    state.lnako_aot_array_new(&arguments[1], &nested_container, nested_container.len);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");

    // 辞書の値が配列（ネスト）。
    var nested_value_array = [_]Value{state.numberValue(1)};
    state.lnako_aot_array_new(&scratch[0], &nested_value_array, nested_value_array.len);
    var value_pairs = [_]Value{ scratch[3], scratch[0] };
    state.lnako_aot_dictionary_new(&arguments[1], &value_pairs, value_pairs.len);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");

    // 辞書の値が辞書（ネスト）。
    var inner_pairs = [_]Value{ scratch[3], state.numberValue(1) };
    state.lnako_aot_dictionary_new(&scratch[0], &inner_pairs, inner_pairs.len);
    var outer_pairs = [_]Value{ scratch[3], scratch[0] };
    state.lnako_aot_dictionary_new(&arguments[1], &outer_pairs, outer_pairs.len);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");

    // 関数値。
    arguments[1] = try state.active_runtime.?.createFunction(noopFunction, 0, &.{});
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");

    // BigInt。
    arguments[1] = try state.active_runtime.?.createBigInt("1");
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");

    // bytes（Uint8Array互換のbyte_buffer）。
    arguments[1] = try state.active_runtime.?.createByteBuffer("ab", .array_buffer);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support nested arrays or dictionaries");
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の非配列引数を単一実引数として渡す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "(a,b)=>typeof b === 'undefined' ? a : -1");
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{ .{}, state.numberValue(7), state.numberValue(8) };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out.payload)));
    // 第3引数以降はofficial/interpreterと同じく実引数にしない。
    var out_with_extra: Value = .{};
    lnako_aot_compat_js_call(&out_with_extra, &arguments, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out_with_extra.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行を空配列引数でdispatchする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "()=>42");
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    state.lnako_aot_array_new(&arguments[1], null, 0);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の非関数戻り値を明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    state.lnako_aot_array_new(&arguments[1], null, 0);
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "1+2");
    defer std.testing.allocator.free(source_units);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try expectPendingFailureContains(&state.active_runtime.?, "did not evaluate to a function");
    lnako_aot_compat_deinit();
}

/// `JS関数実行` の戻り値fixtureをQuickJSへ渡し、戻り値のNako値を返す。
fn callCompatJs(runtime: *state.Runtime, source: []const u8) !Value {
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &arguments, arguments.len);
    defer runtime.popRoots(&frame);
    arguments[0] = try runtime.createString(source_units);
    state.lnako_aot_array_new(&arguments[1], null, 0);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    return out;
}

test "compat AOT runtimeはJS関数実行の配列・辞書戻り値をNako値へ浅く変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    const array_value = try callCompatJs(&state.active_runtime.?, "()=>[1,2]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), array_value.tag);
    const array_items = array_value.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), array_items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(array_items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(array_items[1].payload)));

    const empty_array_value = try callCompatJs(&state.active_runtime.?, "()=>[]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), empty_array_value.tag);
    try std.testing.expectEqual(@as(usize, 0), empty_array_value.object().?.payload.array.items.len);

    const dictionary_value = try callCompatJs(&state.active_runtime.?, "()=>({x:10,y:20})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), dictionary_value.tag);
    const entries = dictionary_value.object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(entries[0].value.payload)));
    try std.testing.expectEqual(@as(f64, 20), @as(f64, @bitCast(entries[1].value.payload)));

    // JSのkey順（挿入順）を保持する。
    const ordered_value = try callCompatJs(&state.active_runtime.?, "()=>({b:2,a:1})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const ordered = ordered_value.object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(ordered[0].value.payload)));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(ordered[1].value.payload)));

    const empty_dictionary_value = try callCompatJs(&state.active_runtime.?, "()=>({})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), empty_dictionary_value.tag);
    try std.testing.expectEqual(@as(usize, 0), empty_dictionary_value.object().?.payload.dictionary.entries.items.len);

    // 要素/値は文字列・真偽値・null/undefined・数値の混在も変換できる。
    const mixed_value = try callCompatJs(&state.active_runtime.?, "()=>['a',true,null,undefined,3.5]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const mixed = mixed_value.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 5), mixed.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), mixed[0].tag);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.boolean)), mixed[1].tag);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.null_value)), mixed[2].tag);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), mixed[3].tag);
    try std.testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast(mixed[4].payload)));

    // 孤立サロゲートはinterpreterと同じくWTF-8可逆で保持する。
    const surrogate_value = try callCompatJs(&state.active_runtime.?, "()=>['\\uD800']");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const surrogate_items = surrogate_value.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 1), surrogate_items.len);
    const surrogate_units = surrogate_items[0].object().?.payload.utf16_string;
    try std.testing.expectEqualSlices(u16, &[_]u16{0xD800}, surrogate_units);

    lnako_aot_compat_deinit();
}

var test_external_releases: usize = 0;

fn testExternalRelease(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    test_external_releases += 1;
}

test "compat AOT runtimeはObjectのexternal bindingをGCで1回だけ解放する" {
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    var sentinel: u8 = 0;
    const value = try runtime.createArray(&.{});
    value.object().?.external = .{ .handle = @ptrCast(&sentinel), .release = testExternalRelease };
    test_external_releases = 0;
    _ = runtime.collect();
    try std.testing.expectEqual(@as(usize, 1), test_external_releases);
    // 2個目はrootして残し、runtime.deinitでも解放されることを確認する。
    const second = try runtime.createArray(&.{});
    second.object().?.external = .{ .handle = @ptrCast(&sentinel), .release = testExternalRelease };
    var roots = [_]Value{second};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    _ = runtime.collect();
    try std.testing.expectEqual(@as(usize, 1), test_external_releases);
    runtime.popRoots(&frame);
    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 2), test_external_releases);
}

fn testString(runtime: *state.Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, text);
    defer std.testing.allocator.free(units);
    return runtime.createString(units);
}

test "compat AOT runtimeはJSオブジェクト取得をexternal binding経由でdispatchする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &values, values.len);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};

    // JS関数実行の戻り値（external binding付き辞書）からプロパティを取得する。
    values[0] = try callCompatJs(&state.active_runtime.?, "()=>({x:10})");
    try std.testing.expect(values[0].object().?.external != null);
    values[1] = try testString(&state.active_runtime.?, "x");
    lnako_aot_compat_js_object_get(&out, &values, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(out.payload)));

    // external binding付き配列は文字列キー "0" で要素を取得できる。
    values[0] = try callCompatJs(&state.active_runtime.?, "()=>[1,2]");
    values[1] = try testString(&state.active_runtime.?, "0");
    lnako_aot_compat_js_object_get(&out, &values, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.payload)));

    // external bindingを持たないNako辞書は安全なフォールバック（JSコピー）で
    // プロパティを取得する。
    var dictionary_values = [_]Value{ try testString(&state.active_runtime.?, "x"), state.numberValue(5) };
    state.lnako_aot_dictionary_new(&values[0], &dictionary_values, dictionary_values.len);
    values[1] = try testString(&state.active_runtime.?, "x");
    lnako_aot_compat_js_object_get(&out, &values, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 5), @as(f64, @bitCast(out.payload)));

    // メソッド戻り値のネストした辞書は再帰変換され、取得結果へexternal bindingを
    // 付与する。JS関数実行の戻り値は浅い規則のため、ネスト値はメソッド戻り値で作る。
    values[0] = try testString(&state.active_runtime.?, "({get(){return {a:{b:1}}}})");
    values[1] = try testString(&state.active_runtime.?, "get");
    var method_values = [_]Value{ values[0], values[1], .{} };
    var method_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&method_frame, &method_values, method_values.len);
    defer state.active_runtime.?.popRoots(&method_frame);
    state.lnako_aot_array_new(&method_values[2], null, 0);
    var nested_value: Value = .{};
    lnako_aot_compat_js_method_call(&nested_value, &method_values, method_values.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), nested_value.tag);
    try std.testing.expect(nested_value.object().?.external != null);
    var nested = [_]Value{ nested_value, .{} };
    var nested_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&nested_frame, &nested, nested.len);
    defer state.active_runtime.?.popRoots(&nested_frame);
    nested[1] = try testString(&state.active_runtime.?, "a");
    var nested_child: Value = .{};
    lnako_aot_compat_js_object_get(&nested_child, &nested, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), nested_child.tag);
    var nested_child_roots = [_]Value{ nested_child, .{} };
    var nested_child_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&nested_child_frame, &nested_child_roots, nested_child_roots.len);
    defer state.active_runtime.?.popRoots(&nested_child_frame);
    nested_child_roots[1] = try testString(&state.active_runtime.?, "b");
    lnako_aot_compat_js_object_get(&out, &nested_child_roots, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.payload)));

    // 1引数形（公式のグローバル名解決）はAOTに変数bridgeが無いため明示エラー。
    lnako_aot_compat_js_object_get(&out, values[0..1], 1);
    try expectPendingFailureContains(&state.active_runtime.?, "requires a value and a property name");
}

test "compat AOT runtimeはJSメソッド実行をexternal binding経由でdispatchする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &values, values.len);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};

    // 文字列レシーバはJSソースとして評価し、this 付きのメソッドを呼ぶ
    // （公式/interpreterと同じ。JS関数実行の浅い戻り値は関数値を保持しないため、
    // メソッドを持つオブジェクトは文字列eval経由で作る）。
    values[0] = try testString(&state.active_runtime.?, "({x:2,add(n){return this.x+n}})");
    values[1] = try testString(&state.active_runtime.?, "add");
    var argument = [_]Value{state.numberValue(5)};
    state.lnako_aot_array_new(&values[2], &argument, argument.len);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out.payload)));

    // external binding付き配列のメソッドは同じJS配列を参照して実行する。
    values[0] = try callCompatJs(&state.active_runtime.?, "()=>[1,2,3]");
    values[1] = try testString(&state.active_runtime.?, "join");
    var separator = [_]Value{try testString(&state.active_runtime.?, "-")};
    state.lnako_aot_array_new(&values[2], &separator, separator.len);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, out);
    defer std.testing.allocator.free(units);
    try std.testing.expectEqualSlices(u16, &[_]u16{ '1', '-', '2', '-', '3' }, units);

    // 戻り値の配列/辞書も再帰変換し、external bindingを付与する。
    values[0] = try testString(&state.active_runtime.?, "({get(){return {n:3}}})");
    values[1] = try testString(&state.active_runtime.?, "get");
    state.lnako_aot_array_new(&values[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), out.tag);
    try std.testing.expect(out.object().?.external != null);

    // 変換できない値（関数）はinterpreterと同じ文言で明示エラーにする。
    var unsupported = [_]Value{try state.active_runtime.?.createFunction(noopFunction, 0, &.{})};
    var unsupported_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&unsupported_frame, &unsupported, unsupported.len);
    defer state.active_runtime.?.popRoots(&unsupported_frame);
    var unsupported_arguments = [_]Value{ unsupported[0], .{}, .{} };
    var unsupported_arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&unsupported_arguments_frame, &unsupported_arguments, unsupported_arguments.len);
    defer state.active_runtime.?.popRoots(&unsupported_arguments_frame);
    unsupported_arguments[1] = try testString(&state.active_runtime.?, "x");
    state.lnako_aot_array_new(&unsupported_arguments[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &unsupported_arguments, 3);
    try expectPendingFailureContains(&state.active_runtime.?, "JSメソッド実行 does not support");
}

test "compat AOT runtimeは深いJS結果の変換を深度上限で明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &values, values.len);
    defer state.active_runtime.?.popRoots(&frame);
    values[0] = try testString(&state.active_runtime.?, "({deep(){let o={};for(let i=0;i<70;i++)o={a:o};return o}})");
    values[1] = try testString(&state.active_runtime.?, "deep");
    state.lnako_aot_array_new(&values[2], null, 0);
    var out: Value = .{};
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJsNestingTooDeep");
}

test "compat AOT runtimeはメソッド実行後にexternal値をJS側の内容で再同期する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &values, values.len);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};
    // JS側で push した内容がNako側コピーへ再同期され、次のjoinが"1-2-3"になる。
    values[0] = try callCompatJs(&state.active_runtime.?, "()=>[1,2]");
    values[1] = try testString(&state.active_runtime.?, "push");
    var pushed = [_]Value{state.numberValue(3)};
    state.lnako_aot_array_new(&values[2], &pushed, pushed.len);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(out.payload)));
    values[1] = try testString(&state.active_runtime.?, "join");
    var separator = [_]Value{try testString(&state.active_runtime.?, "-")};
    state.lnako_aot_array_new(&values[2], &separator, separator.len);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, out);
    defer std.testing.allocator.free(units);
    try std.testing.expectEqualSlices(u16, &[_]u16{ '1', '-', '2', '-', '3' }, units);
    // Nako側の変更は次の呼出し前にJSへ書き戻す（interpreterのsyncExternal相当）。
    values[0].object().?.payload.array.items[0] = state.numberValue(9);
    values[1] = try testString(&state.active_runtime.?, "join");
    state.lnako_aot_array_new(&values[2], &separator, separator.len);
    lnako_aot_compat_js_method_call(&out, &values, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const rewritten = try state.valueUtf16Alloc(&state.active_runtime.?, out);
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualSlices(u16, &[_]u16{ '9', '-', '2', '-', '3' }, rewritten);
}

test "compat AOT runtimeは辞書戻り値の変換中GCで要素値を失わない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const engine_value = try ensureEngine();
    const source = "({k:'v'})";
    const raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<GC辞書戻り値>") orelse {
        lnako_aot_compat_deinit();
        return error.TestUnexpectedResult;
    };
    // 次の割当てでcollectが発火する直前まで、rootした文字列で埋める。
    const roots = try std.testing.allocator.alloc(Value, 256);
    defer std.testing.allocator.free(roots);
    @memset(roots, .{});
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, roots.ptr, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x");
    defer std.testing.allocator.free(units);
    var index: usize = 0;
    while (index < roots.len and state.active_runtime.?.object_count + 1 < state.active_runtime.?.next_collection) : (index += 1) {
        roots[index] = try state.active_runtime.?.createString(units);
    }
    try std.testing.expect(index > 0);
    // 要素値の文字列生成→キー文字列生成の間にcollectが入っても、
    // 要素値はpairs（root frame）経由で保持される。
    const dictionary = try shallowDictionaryFromRaw(&state.active_runtime.?, raw);
    lnako_qjs_value_free(raw);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const entries = dictionary.object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualSlices(u16, &.{'v'}, entries[0].value.object().?.payload.utf16_string);
    lnako_aot_compat_deinit();
}

fn collectDuringDictionaryKeyCallback(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    // 辞書キーがrootされる前にGCを走らせ、未rootなら回収される状態を作る。
    _ = runtime.collect();
    // 回収されたキーと同じ大きさの文字列で領域を再利用し、未rootなら壊す。
    const units = [_]u16{'X'};
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        _ = runtime.createString(&units) catch return;
    }
}

test "compat AOT runtimeはgetter経由のGCから辞書キーを保護する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var call_arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    // Nako callback を JS の globalThis へ渡し、getter から呼び戻す。
    roots[0] = try state.active_runtime.?.createFunction(collectDuringDictionaryKeyCallback, 0, &.{});
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{globalThis.__lnako_gc_key_cb=cb;return 0;}");
    call_arguments[0] = roots[1];
    call_arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &call_arguments[0], call_arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);

    // 辞書変換ではキー `k` を root してから getter を呼ぶ。getter が Nako
    // callback 経由で collect を走らせても、キーは回収されない。
    roots[2] = try evalCompatJs(
        &state.active_runtime.?,
        "({get k(){globalThis.__lnako_gc_key_cb();return 'v';}})",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), roots[2].tag);
    const entries = roots[2].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    {
        const key_units = try state.valueUtf16Alloc(&state.active_runtime.?, entries[0].key);
        defer std.testing.allocator.free(key_units);
        try std.testing.expectEqualSlices(u16, &.{'k'}, key_units);
    }
    {
        const value_units = try state.valueUtf16Alloc(&state.active_runtime.?, entries[0].value);
        defer std.testing.allocator.free(value_units);
        try std.testing.expectEqualSlices(u16, &.{'v'}, value_units);
    }
}

test "compat AOT runtimeは変換中のJS例外文言を内部エラー名で上書きしない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);

    // JS実行 の full 変換中に getter が投げた例外は、内部エラー名ではなく
    // 元のJS例外文言として runtime に残る。
    _ = try evalCompatJs(&state.active_runtime.?, "({get k(){throw new Error('conversion-boom');}})");
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    {
        const message = state.active_runtime.?.takeException();
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, message);
        defer std.testing.allocator.free(actual);
        try std.testing.expect(std.mem.indexOf(u8, actual, "conversion-boom") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, "QuickJsConversionReported") == null);
    }

    // JS関数値の戻り値変換でも同じ文言を保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "()=>({get k(){throw new Error('callback-boom');}})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    var out: Value = .{};
    state.lnako_aot_function_call(&out, &roots[0], null, 0);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    {
        const message = state.active_runtime.?.takeException();
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, message);
        defer std.testing.allocator.free(actual);
        try std.testing.expect(std.mem.indexOf(u8, actual, "callback-boom") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, "QuickJsConversionReported") == null);
    }
}

test "compat AOT runtimeはキー列挙中のJS例外文言を保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};
    const engine = try ensureEngine();
    const proxy_source = "new Proxy({}, {ownKeys(){throw new Error('keys-boom');}})";

    // `JS実行` の full 変換（convertFullObject）はownKeys例外の文言を残す。
    _ = try evalCompatJs(&state.active_runtime.?, proxy_source);
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");

    // `JS関数実行` の浅い辞書変換（shallowDictionaryFromRaw）も同じ文言を残す。
    _ = try callCompatJs(
        &state.active_runtime.?,
        "()=>new Proxy({}, {ownKeys(){throw new Error('keys-boom');}})",
    );
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");

    // JS側にProxyを置き、external配列のプロパティとして`JSオブジェクト取得`の
    // 戻り値変換（convertResultDictionary）へ渡す。配列の同期はインデックスだけを
    // 扱うため、追加したプロパティは削除されない。
    _ = try evalCompatJs(
        &state.active_runtime.?,
        "globalThis.__lnako_keys_proxy = new Proxy({}, {ownKeys(){throw new Error('keys-boom');}}), 0",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    roots[0] = try callCompatJs(
        &state.active_runtime.?,
        "()=>{const a=[];a.p=globalThis.__lnako_keys_proxy;return a;}",
    );
    roots[1] = try testString(&state.active_runtime.?, "p");
    lnako_aot_compat_js_object_get(&out, roots[0..2].ptr, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");

    // `JSメソッド実行` の戻り値変換（同じ convertResultDictionary）。
    roots[0] = try testString(&state.active_runtime.?, "({get(){return globalThis.__lnako_keys_proxy}})");
    roots[1] = try testString(&state.active_runtime.?, "get");
    state.lnako_aot_array_new(&roots[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &roots, 3);
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");

    // `JS関数実行` の実引数同期（syncContents）でexternal辞書のownKeysが投げる。
    const sync_raw = lnako_qjs_eval(engine, proxy_source.ptr, proxy_source.len, "<keys-boom>") orelse
        return error.QuickJsConversionFailed;
    defer lnako_qjs_value_free(sync_raw);
    state.lnako_aot_dictionary_new(&roots[2], null, 0);
    try compat.attachExternal(roots[2], sync_raw);
    var call_arguments = [_]Value{ .{}, .{} };
    var call_frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &call_frame, &call_arguments);
    defer state.active_runtime.?.popRoots(&call_frame);
    call_arguments[0] = try testString(&state.active_runtime.?, "(o)=>1");
    state.lnako_aot_array_new(&call_arguments[1], roots[2..3].ptr, 1);
    lnako_aot_compat_js_call(&out, &call_arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");

    // `refreshFromRaw` の辞書ブランチ（呼出し後の再同期）も同じ文言を残す。
    state.lnako_aot_dictionary_new(&roots[2], null, 0);
    const refresh_raw = lnako_qjs_eval(engine, proxy_source.ptr, proxy_source.len, "<keys-boom>") orelse
        return error.QuickJsConversionFailed;
    defer lnako_qjs_value_free(refresh_raw);
    try std.testing.expectError(
        compat.reported_engine_failure,
        compat_result.refreshFromRaw(&state.active_runtime.?, roots[2], refresh_raw),
    );
    try expectPendingFailureContains(&state.active_runtime.?, "keys-boom");
}

test "compat AOT runtimeはJSオブジェクト取得とJSメソッド実行でBigIntを拒否する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};

    // `JSオブジェクト取得` は辞書直下のBigIntをinterpreterと同じ文言で拒否する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({n:1n})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    roots[1] = try testString(&state.active_runtime.?, "n");
    lnako_aot_compat_js_object_get(&out, roots[0..2].ptr, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support promises, functions, bigint, bytes, or nested arrays or dictionaries yet");

    // 入れ子の辞書直下でも同じ文言で拒否する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({nested:{n:1n}})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    roots[1] = try testString(&state.active_runtime.?, "nested");
    lnako_aot_compat_js_object_get(&out, roots[0..2].ptr, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support promises, functions, bigint, bytes, or nested arrays or dictionaries yet");

    // `JSメソッド実行` が返したBigIntも同じ文言で拒否する。
    roots[0] = try testString(&state.active_runtime.?, "({get(){return 1n}})");
    roots[1] = try testString(&state.active_runtime.?, "get");
    state.lnako_aot_array_new(&roots[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &roots, 3);
    try expectPendingFailureContains(&state.active_runtime.?, "JSメソッド実行 does not support promises, functions, bigint, bytes, or nested arrays or dictionaries yet");

    // 呼出し後のrefreshは`convertFull`を使うため、結果変換が拒否するBigIntでも
    // Nako側の辞書値としては保持される。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({n:1,set(){this.n=1n;return 'ok';}})");
    roots[1] = try testString(&state.active_runtime.?, "set");
    state.lnako_aot_array_new(&roots[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &roots, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText((try dictionaryValueByKey(&state.active_runtime.?, roots[0], "n")).?, "1");
}

test "compat AOT runtimeはJS関数実行の未対応戻り値を同じ文言で明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const cases = [_][]const u8{
        "()=>[1,[2]]",
        "()=>({x:{y:1}})",
        "()=>()=>1",
        "()=>1n",
        "()=>new Uint8Array([1,2])",
        "()=>new ArrayBuffer(4)",
        "()=>new DataView(new ArrayBuffer(4))",
        "()=>new SharedArrayBuffer(4)",
        "()=>[new Uint8Array([1])]",
        "()=>({x:new Uint8Array([1])})",
    };
    for (cases) |source| {
        _ = try callCompatJs(&state.active_runtime.?, source);
        try expectPendingFailureContains(&state.active_runtime.?, "does not support nested arrays or dictionaries, functions, bigint, or bytes results yet");
    }
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行のPromise戻り値をawaitして変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    const number_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve(3)");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), number_value.tag);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(number_value.payload)));

    const string_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve('s')");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), string_value.tag);
    try std.testing.expectEqualSlices(u16, &.{'s'}, string_value.object().?.payload.utf16_string);

    const boolean_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve(true)");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.boolean)), boolean_value.tag);
    try std.testing.expect(boolean_value.payload != 0);

    const null_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve(null)");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.null_value)), null_value.tag);

    const undefined_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve()");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), undefined_value.tag);

    const array_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve([1,2])");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), array_value.tag);
    const array_items = array_value.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), array_items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(array_items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(array_items[1].payload)));

    const dictionary_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve({x:10})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), dictionary_value.tag);
    const entries = dictionary_value.object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(entries[0].value.payload)));

    // 解決値が未対応型なら、await後の変換で既存の未対応エラーになる。
    _ = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve(1n)");
    try expectPendingFailureContains(&state.active_runtime.?, "does not support nested arrays or dictionaries, functions, bigint, or bytes results yet");
    _ = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve([1,[2]])");
    try expectPendingFailureContains(&state.active_runtime.?, "does not support nested arrays or dictionaries, functions, bigint, or bytes results yet");

    // rejectはreject理由を、pendingはbridgeの文言を明示エラーにする。
    _ = try callCompatJs(&state.active_runtime.?, "()=>Promise.reject(new Error('x'))");
    try expectPendingFailureContains(&state.active_runtime.?, "Error: x");
    _ = try callCompatJs(&state.active_runtime.?, "()=>new Promise(()=>{})");
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJS promise is still pending");

    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の戻り値配列の巨大lengthを拒否する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    // 疎配列の巨大lengthで数十GBを一括確保しない。
    _ = try callCompatJs(&state.active_runtime.?, "()=>{const a=new Array();a.length=1000001;return a;}");
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJsCollectionTooLarge");
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS関数実行の防御境界を明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, null, 0);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const missing_argument = state.active_runtime.?.takeException();
    const missing_units = try state.valueUtf16Alloc(&state.active_runtime.?, missing_argument);
    defer std.testing.allocator.free(missing_units);
    const expected_argument = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "requires a function argument");
    defer std.testing.allocator.free(expected_argument);
    try std.testing.expect(std.mem.indexOf(u16, missing_units, expected_argument) != null);

    var arguments = [_]Value{state.numberValue(1)};
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const missing_string = state.active_runtime.?.takeException();
    const missing_string_units = try state.valueUtf16Alloc(&state.active_runtime.?, missing_string);
    defer std.testing.allocator.free(missing_string_units);
    const expected_string = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "requires a function name string");
    defer std.testing.allocator.free(expected_string);
    try std.testing.expect(std.mem.indexOf(u16, missing_string_units, expected_string) != null);
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはESM manifestを登録してimportできる" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const manifest =
        \\[{"path":"/lnako-compat-test/mod.mjs","source":"export function add(a, b) { return a + b; }","is_plugin":false,"namespaces":[],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "import('/lnako-compat-test/mod.mjs').then(m => m.add(2,3))");
    defer std.testing.allocator.free(units);
    var arguments = [_]Value{try state.active_runtime.?.createString(units)};
    var out: Value = .{};
    lnako_aot_compat_js_eval(&out, &arguments, arguments.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 5), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはschema 2 manifestのmodulesとpackagesを受理する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    // `--compat-js --backend aot` の生成物は schema 2（object）で、同梱
    // package の metadata を併せて持つ。packages は実行時登録に影響せず、
    // modules の登録だけが QuickJS へ渡ることを固定する。
    const manifest =
        \\{"schema":2,"modules":[{"path":"/lnako-compat-test/schema2.mjs","source":"export function add(a, b) { return a + b; }","is_plugin":false,"namespaces":[],"package_root":null,"bare_aliases":[]}],"packages":[{"name":"left-pad","version":"1.0.0","license":"MIT","root":"/tmp/npm_left-pad","kind":"npm","entries":["index.js"]}]}
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "import('/lnako-compat-test/schema2.mjs').then(m => m.add(2,3))");
    defer std.testing.allocator.free(units);
    var arguments = [_]Value{try state.active_runtime.?.createString(units)};
    var out: Value = .{};
    lnako_aot_compat_js_eval(&out, &arguments, arguments.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 5), @as(f64, @bitCast(out.payload)));
    lnako_aot_compat_deinit();
}

test "compat AOT runtimeはJS文字列の孤立サロゲートを保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    // JS source `"\uD800"`（孤立サロゲート1個の文字列）。
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "\"\\uD800\"");
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{try state.active_runtime.?.createString(source_units)};
    var out: Value = .{};
    lnako_aot_compat_js_eval(&out, &arguments, arguments.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), out.tag);
    try std.testing.expectEqualSlices(u16, &.{0xD800}, out.object().?.payload.utf16_string);
    lnako_aot_compat_deinit();
}

/// `JS実行` の戻り値fixtureをQuickJSへ渡し、戻り値のNako値を返す。
/// 引数の文字列はroot frameに載せ、eval中のGCで回収されないようにする。
fn evalCompatJs(runtime: *state.Runtime, source: []const u8) !Value {
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(source_units);
    var arguments = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &arguments, arguments.len);
    defer runtime.popRoots(&frame);
    arguments[0] = try runtime.createString(source_units);
    var out: Value = .{};
    lnako_aot_compat_js_eval(&out, &arguments, arguments.len);
    return out;
}

fn expectBigIntText(value: Value, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.bigint)), value.tag);
    const text = try value.object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "compat AOT runtimeはJS実行の関数値をAOT関数呼出しで複数引数付きで実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    // 外側のJSオブジェクト `outer` を閉じ込めた2つの関数値を返す。
    const bundle = try evalCompatJs(
        &state.active_runtime.?,
        "(function(){const outer={n:1};const read=(o,a)=>o.n+a;const bump=(o)=>{o.n=o.n+1;return o.n;};return {outer,read,bump};})()",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), bundle.tag);
    var roots = [_]Value{ bundle, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    const entries = roots[0].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // `outer` はexternal binding付きの入れ子辞書、`read`/`bump` はJS関数値。
    roots[1] = entries[0].value;
    roots[2] = entries[1].value;
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), roots[1].tag);
    try std.testing.expect(roots[1].object().?.external != null);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), roots[2].tag);
    try std.testing.expect(roots[2].object().?.external != null);
    // `createMethodFunction(arity = 0)` でも generated wrapper 規約なら
    // Nako側から渡した実引数がそのままJS関数へ届く。
    try std.testing.expectEqual(@as(usize, 0), roots[2].object().?.payload.function.arity);
    try std.testing.expect(roots[2].object().?.payload.function.generated_wrapper);

    // Nako側で `outer.n` を10へ変更してから関数値へ2引数で渡す。呼出し前の
    // 書き戻しでJS側の `outer.n` も10になり、`read` は 10+5 を返す。
    roots[1].object().?.payload.dictionary.entries.items[0].value = state.numberValue(10);
    var read_arguments = [_]Value{ roots[2], roots[1], state.numberValue(5) };
    var read_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&read_frame, &read_arguments, read_arguments.len);
    defer state.active_runtime.?.popRoots(&read_frame);
    var out: Value = .{};
    state.lnako_aot_function_call(&out, &read_arguments[0], read_arguments[1..].ptr, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 15), @as(f64, @bitCast(out.payload)));

    // `bump` はJS側で `outer.n` を書き換える。呼出し後の再同期でNako側の
    // 外部辞書も11になり、次に渡す値もJS側の最新値と一致する。
    roots[2] = entries[2].value;
    var bump_arguments = [_]Value{ roots[2], roots[1] };
    var bump_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&bump_frame, &bump_arguments, bump_arguments.len);
    defer state.active_runtime.?.popRoots(&bump_frame);
    state.lnako_aot_function_call(&out, &bump_arguments[0], bump_arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 11), @as(f64, @bitCast(out.payload)));
    const refreshed = roots[1].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), refreshed.len);
    try std.testing.expectEqual(@as(f64, 11), @as(f64, @bitCast(refreshed[0].value.payload)));
}

test "compat AOT runtimeはJS実行の関数値をJS関数実行の第1引数に渡せる" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const bundle = try evalCompatJs(
        &state.active_runtime.?,
        "(function(){return {add:(a,b)=>a+b,later:(v)=>Promise.resolve(v*2)};})()",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    var roots = [_]Value{ bundle, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    const entries = roots[0].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    roots[1] = entries[0].value;
    roots[2] = entries[1].value;
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), roots[1].tag);
    try std.testing.expect(roots[1].object().?.external != null);

    var arguments = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&arguments_frame);
    var out: Value = .{};

    // JS関数値を第1引数にし、第2引数の配列を実引数として呼ぶ。
    arguments[0] = roots[1];
    var numbers = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&arguments[1], &numbers, numbers.len);
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(out.payload)));

    // Promise戻り値は `JS関数実行` と同じくawaitして解決値を変換する。
    arguments[0] = roots[2];
    var single = [_]Value{state.numberValue(21)};
    state.lnako_aot_array_new(&arguments[1], &single, single.len);
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(out.payload)));
}

var test_nako_call_argument_count: usize = 0;

fn testNakoCallCallback(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    test_nako_call_argument_count = len;
    var total: f64 = 0;
    if (arguments) |values| {
        for (values[0..len]) |value| total += @as(f64, @bitCast(value.payload));
    }
    out.* = state.numberValue(total);
}

test "compat AOT runtimeはNako関数値をJS関数実行で呼び出す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var arguments = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createFunction(testNakoCallCallback, 3, &.{});
    var values = [_]Value{ state.numberValue(1), state.numberValue(2), state.numberValue(4) };
    state.lnako_aot_array_new(&arguments[1], &values, values.len);
    var out: Value = .{};
    test_nako_call_argument_count = 0;
    lnako_aot_compat_js_call(&out, &arguments, arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    // Nako関数はJS evalを挟まず、引数個数もNako値のまま渡る。
    try std.testing.expectEqual(@as(usize, 3), test_nako_call_argument_count);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out.payload)));
}

test "compat AOT runtimeはJS実行のBigInt・疎配列・入れ子・循環・関数プロパティを変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);

    // BigInt: 0n・正負・64bit超を10進文字列経由で保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "0n");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(roots[0], "0");
    roots[0] = try evalCompatJs(&state.active_runtime.?, "123n");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(roots[0], "123");
    roots[0] = try evalCompatJs(&state.active_runtime.?, "-456n");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(roots[0], "-456");
    roots[0] = try evalCompatJs(&state.active_runtime.?, "123456789012345678901234567890n");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(roots[0], "123456789012345678901234567890");

    // 疎配列の穴はpresence=falseとして保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "[1,,3]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const sparse = roots[0].object().?;
    try std.testing.expectEqual(@as(usize, 3), sparse.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), sparse.array_presence.items.len);
    try std.testing.expect(sparse.array_presence.items[0]);
    try std.testing.expect(!sparse.array_presence.items[1]);
    try std.testing.expect(sparse.array_presence.items[2]);

    // 入れ子の配列・辞書を再帰変換する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({a:[1,{b:2}]})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const nested_entries = roots[0].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), nested_entries.len);
    const nested_array = nested_entries[0].value.object().?;
    try std.testing.expectEqual(@as(usize, 2), nested_array.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(nested_array.payload.array.items[0].payload)));
    const nested_dictionary = nested_array.payload.array.items[1].object().?;
    try std.testing.expectEqual(@as(usize, 1), nested_dictionary.payload.dictionary.entries.items.len);
    try std.testing.expectEqual(
        @as(f64, 2),
        @as(f64, @bitCast(nested_dictionary.payload.dictionary.entries.items[0].value.payload)),
    );

    // 自己参照配列は同じObjectを指す循環として保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(()=>{const a=[1];a.push(a);return a;})()");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const cyclic_array = roots[0].object().?;
    try std.testing.expectEqual(@as(usize, 2), cyclic_array.payload.array.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), cyclic_array.payload.array.items[1].tag);
    try std.testing.expect(cyclic_array.payload.array.items[1].object().? == cyclic_array);

    // 自己参照辞書も同じObjectを指す循環として保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(()=>{const o={};o.self=o;return o;})()");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const cyclic_dictionary = roots[0].object().?;
    try std.testing.expectEqual(@as(usize, 1), cyclic_dictionary.payload.dictionary.entries.items.len);
    try std.testing.expect(cyclic_dictionary.payload.dictionary.entries.items[0].value.object().? == cyclic_dictionary);

    // 関数プロパティはAOTの関数値（external binding付き）として保持する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({f:(x)=>x+1,n:2})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const function_entries = roots[0].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 2), function_entries.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), function_entries[0].value.tag);
    try std.testing.expect(function_entries[0].value.object().?.external != null);
    try std.testing.expect(function_entries[0].value.object().?.payload.function.generated_wrapper);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(function_entries[1].value.payload)));
}

test "compat AOT runtimeはJS実行の深い結果を深度上限で明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    _ = try evalCompatJs(&state.active_runtime.?, "(()=>{let o={};for(let i=0;i<70;i++)o={a:o};return o})()");
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJsNestingTooDeep");
}

var test_js_function_releases: usize = 0;

fn testJsFunctionRelease(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    test_js_function_releases += 1;
    if (handle) |pointer| lnako_qjs_value_free(@ptrCast(@alignCast(pointer)));
}

test "compat AOT runtimeは未参照のJS関数値をGCで解放する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const engine_value = try ensureEngine();
    const source = "(function named(x){return x+1})";
    const raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<GC関数値>") orelse {
        return error.TestUnexpectedResult;
    };
    var function_value = try compat_result.jsFunctionValue(&state.active_runtime.?, raw);
    // 関数名と生成wrapper規約（実引数個数をそのまま渡す）を固定する。
    try std.testing.expectEqualStrings("named", function_value.object().?.payload.function.name);
    try std.testing.expect(function_value.object().?.payload.function.generated_wrapper);
    try std.testing.expect(function_value.object().?.external != null);
    // 解放を観測するためreleaseだけを差し替える（handleの解放規約は同じ）。
    function_value.object().?.external.?.release = testJsFunctionRelease;
    test_js_function_releases = 0;
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 1), test_js_function_releases);

    // rootした関数値は回収されず、root解除後のcollectで解放される。
    const second_raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<GC関数値2>") orelse {
        return error.TestUnexpectedResult;
    };
    const second = try compat_result.jsFunctionValue(&state.active_runtime.?, second_raw);
    second.object().?.external.?.release = testJsFunctionRelease;
    var roots = [_]Value{second};
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 1), test_js_function_releases);
    state.active_runtime.?.popRoots(&frame);
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 2), test_js_function_releases);
}

/// 辞書のキー（UTF-16）で値を引く。callback後のrefreshで辞書が再構築されても
/// キー順に依存せず検証するためのテスト用helper。
fn dictionaryValueByKey(runtime: *state.Runtime, dictionary: Value, key: []const u8) !?Value {
    const expected = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, key);
    defer std.testing.allocator.free(expected);
    for (dictionary.object().?.payload.dictionary.entries.items) |entry| {
        const units = try state.valueUtf16Alloc(runtime, entry.key);
        defer std.testing.allocator.free(units);
        if (std.mem.eql(u16, units, expected)) return entry.value;
    }
    return null;
}

test "compat AOT runtimeはネストしたexternalコンテナのNako変更をJSへ書き戻す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&arguments_frame);
    var out: Value = .{};

    // `{child:{n:1}}` は親も子もexternal bindingを持つ。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({child:{n:1}})");
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(function(o){o.child.n=o.child.n+1;return o.child.n;})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expect(roots[0].object().?.external != null);
    const child = (try dictionaryValueByKey(&state.active_runtime.?, roots[0], "child")).?;
    try std.testing.expect(child.object().?.external != null);
    // Nako側でchild.nを42へ変更してからJS関数値へ親を渡す。
    child.object().?.payload.dictionary.entries.items[0].value = state.numberValue(42);
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 43), @as(f64, @bitCast(out.payload)));
    // callback後のfull refreshでJS側の43がNako側の入れ子辞書へ戻る。
    const refreshed_child = (try dictionaryValueByKey(&state.active_runtime.?, roots[0], "child")).?;
    try std.testing.expectEqual(@as(f64, 43), @as(f64, @bitCast(refreshed_child.object().?.payload.dictionary.entries.items[0].value.payload)));

    // 自己参照のexternal辞書も循環を保ったまま書き戻す。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(()=>{const o={n:1};o.self=o;return o;})()");
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(function(o){o.n=7;return o.self===o;})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expect(roots[0].object().?.external != null);
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.boolean)), out.tag);
    try std.testing.expect(out.payload != 0);
    const cyclic = roots[0].object().?;
    try std.testing.expectEqual(@as(usize, 2), cyclic.payload.dictionary.entries.items.len);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try dictionaryValueByKey(&state.active_runtime.?, roots[0], "n")).?.payload)));
    const self_value = (try dictionaryValueByKey(&state.active_runtime.?, roots[0], "self")).?;
    try std.testing.expect(self_value.object().? == cyclic);
}

test "compat AOT runtimeはcallback後のrefreshでネストした関数・BigInt・循環を保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&arguments_frame);
    var out: Value = .{};

    roots[0] = try evalCompatJs(
        &state.active_runtime.?,
        "(function(a){a.length=0;a.push([()=>1,2n]);a.push({fn:()=>9,n:10n});a.push(a);return 0;})",
    );
    var items = [_]Value{state.numberValue(1)};
    state.lnako_aot_array_new(&roots[1], &items, items.len);
    arguments[0] = roots[0];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(out.payload)));

    const refreshed = roots[1].object().?;
    try std.testing.expectEqual(@as(usize, 3), refreshed.payload.array.items.len);
    // 配列要素に入った関数とBigIntを取り出せる。
    const nested = refreshed.payload.array.items[0].object().?;
    try std.testing.expectEqual(@as(usize, 2), nested.payload.array.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), nested.payload.array.items[0].tag);
    state.lnako_aot_function_call(&out, &nested.payload.array.items[0], null, 0);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.payload)));
    try expectBigIntText(nested.payload.array.items[1], "2");
    // 辞書値に入った関数とBigIntも同様に保持する。
    const nested_dictionary = refreshed.payload.array.items[1].object().?;
    try std.testing.expectEqual(@as(usize, 2), nested_dictionary.payload.dictionary.entries.items.len);
    const nested_function = (try dictionaryValueByKey(&state.active_runtime.?, refreshed.payload.array.items[1], "fn")).?;
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), nested_function.tag);
    state.lnako_aot_function_call(&out, &nested_function, null, 0);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(out.payload)));
    try expectBigIntText((try dictionaryValueByKey(&state.active_runtime.?, refreshed.payload.array.items[1], "n")).?, "10");
    // JS側で追加した自己参照はNako側でも同じObjectを指す。
    try std.testing.expectEqual(@as(usize, 3), refreshed.payload.array.items.len);
    try std.testing.expect(refreshed.payload.array.items[2].object().? == refreshed);
}

test "compat AOT runtimeはJS関数値callbackへBigIntとbytesを直接・入れ子で渡す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&arguments_frame);
    var out: Value = .{};

    // BigIntを直接渡す（64bit超も10進文字列経由で往復する）。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(x)=>x+1n");
    roots[1] = try state.active_runtime.?.createBigInt("9007199254740993");
    arguments[0] = roots[0];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(out, "9007199254740994");
    // `JS実行("1n")` が返したBigIntも直接渡せる。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "1n");
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(x)=>x+1n");
    arguments[0] = roots[0];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(out, "2");
    // 配列・辞書の入れ子に入れたBigIntも変換する。
    roots[1] = try state.active_runtime.?.createBigInt("9007199254740993");
    var big_values = [_]Value{roots[1]};
    state.lnako_aot_array_new(&roots[2], &big_values, big_values.len);
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(a)=>a[0]+1n");
    arguments[0] = roots[0];
    arguments[1] = roots[2];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(out, "9007199254740994");
    const big_key = try testString(&state.active_runtime.?, "v");
    var big_pair = [_]Value{ big_key, roots[1] };
    state.lnako_aot_dictionary_new(&roots[2], &big_pair, big_pair.len);
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(o)=>o.v+1n");
    arguments[0] = roots[0];
    arguments[1] = roots[2];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(out, "9007199254740994");

    // ByteBufferを直接渡す（0..255の数値配列としてJSへ渡す）。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(arr)=>arr[0]+arr[2]");
    roots[1] = try state.active_runtime.?.createByteBuffer(&.{ 1, 2, 255 }, .uint8_array);
    arguments[0] = roots[0];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 256), @as(f64, @bitCast(out.payload)));
    // 配列の入れ子に入れたByteBufferも変換する。
    var bytes_values = [_]Value{roots[1]};
    state.lnako_aot_array_new(&roots[2], &bytes_values, bytes_values.len);
    roots[0] = try evalCompatJs(&state.active_runtime.?, "(a)=>a[0][1]");
    arguments[0] = roots[0];
    arguments[1] = roots[2];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(out.payload)));

    // `JSメソッド実行` のトップレベル引数制限は従来どおり（callbackだけがfull）。
    var method_arguments = [_]Value{
        try testString(&state.active_runtime.?, "[]"),
        try testString(&state.active_runtime.?, "concat"),
        roots[1],
    };
    lnako_aot_compat_js_method_call(&out, &method_arguments, method_arguments.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JSメソッド実行 does not support");
}

test "compat AOT runtimeはexternalコンテナ内のBigIntをJS関数実行へ同期し浅いコンテナ内のJS関数は拒否する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};

    // external辞書内のBigIntは `JS関数実行` でも書き戻されて読み取れる。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({n: 1n})");
    var call_args = [_]Value{
        try testString(&state.active_runtime.?, "o => String(o.n)"),
        roots[0],
    };
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("1", actual);
    }

    // Nako側でexternalコンテナのBigIntを変更しても `JS関数実行` へ同期される。
    const n_key = try testString(&state.active_runtime.?, "n");
    const big_42 = try state.active_runtime.?.createBigInt("42");
    try state.active_runtime.?.setDictionary(&roots[0].object().?.payload.dictionary, n_key, big_42);
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("42", actual);
    }

    // 浅い引数コンテナ内に置いたJS関数値やexternal配列は型制限を迂回せず拒否する。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "()=>1");
    var wrapped_fn = [_]Value{roots[1]};
    state.lnako_aot_array_new(&roots[2], &wrapped_fn, wrapped_fn.len);
    var wrapped_outer = [_]Value{roots[2]};
    state.lnako_aot_array_new(&roots[2], &wrapped_outer, wrapped_outer.len);
    var bad_call_args = [_]Value{
        try testString(&state.active_runtime.?, "a => a[0]()"),
        roots[2],
    };
    lnako_aot_compat_js_call(&out, &bad_call_args, bad_call_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support");

    // `roots[0]` (external辞書) 自体も非external浅い配列の要素に置かれた場合は拒否する。
    var wrapped_ext = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[2], &wrapped_ext, wrapped_ext.len);
    var bad_ext_outer = [_]Value{roots[2]};
    state.lnako_aot_array_new(&roots[2], &bad_ext_outer, bad_ext_outer.len);
    var bad_ext_args = [_]Value{
        try testString(&state.active_runtime.?, "o => o.n"),
        roots[2],
    };
    lnako_aot_compat_js_call(&out, &bad_ext_args, bad_ext_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JS関数実行 does not support");
}

// --- Issue #55 Unit 2: Nako→JS callback / GC trace ---

var test_capture_invocations: usize = 0;

/// capture の数値を1つ進め、呼出し回数（と任意の数値引数）を戻す Nako callback。
/// JS から `cb()` / `cb(10)` として同期呼出しされ、`binding_cell` の更新が
/// 呼出しをまたいで残ることを検証する。
fn counterCallback(out: *Value, context: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const object: *state.Object = @ptrCast(@alignCast(context));
    if (object.payload.function.captures.len == 0) {
        runtime.setFailureText("counter callback requires a capture");
        return;
    }
    const value_ptr = &object.payload.function.captures[0].object().?.payload.binding_cell;
    const current = @as(f64, @bitCast(value_ptr.payload));
    value_ptr.* = state.numberValue(current + 1);
    test_capture_invocations += 1;
    var increment: f64 = 0;
    if (arguments) |values| {
        if (len > 0 and @as(Tag, @fromBackingInt(values[0].tag)) == .number) {
            increment = @as(f64, @bitCast(values[0].payload));
        }
    }
    out.* = state.numberValue(current + 1 + increment);
}

/// JSから受け取った配列へ99を追加し、辞書の先頭値を42へ変更し、受け取った
/// BigIntをそのまま戻す Nako callback。hostInvoke の実引数書き戻しを検証する。
fn mutationCallback(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (arguments == null or len < 3) {
        runtime.setFailureText("mutation callback requires three arguments");
        return;
    }
    const values = arguments.?[0..len];
    const array_object = values[0].object() orelse {
        runtime.setFailureText("mutation callback requires an array");
        return;
    };
    runtime.aotArrayAppend(array_object, state.numberValue(99)) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    const dictionary_object = values[1].object() orelse {
        runtime.setFailureText("mutation callback requires a dictionary");
        return;
    };
    if (dictionary_object.payload.dictionary.entries.items.len == 0) {
        runtime.setFailureText("mutation callback requires a non-empty dictionary");
        return;
    }
    dictionary_object.payload.dictionary.entries.items[0].value = state.numberValue(42);
    out.* = values[2];
}

/// JSの `try/catch` で捕捉させるため、Nako側の失敗を記録する callback。
fn failingCallback(_: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.setFailureText("nako callback failed");
}

/// capture に保持したJS関数を呼び、その結果をcaptureの配列へ追加して
/// `captured:<要素数>` を返す Nako callback。GC後もクロージャ・capture・JS関数が
/// 生存することに加え、capture配列の先頭要素（heap上の文字列）が回収されず
/// 内容まで保たれていることを文字列で確認する。
fn captureRoundTripCallback(out: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const object: *state.Object = @ptrCast(@alignCast(context));
    if (object.payload.function.captures.len < 2) {
        runtime.setFailureText("capture callback requires two captures");
        return;
    }
    const array_object = object.payload.function.captures[0].object().?.payload.binding_cell.object() orelse {
        runtime.setFailureText("capture callback requires an array capture");
        return;
    };
    var function_value = object.payload.function.captures[1].object().?.payload.binding_cell;
    var result: Value = .{};
    state.lnako_aot_function_call(&result, &function_value, null, 0);
    if (runtime.has_pending_exception) return;
    const number = @as(f64, @bitCast(result.payload));
    runtime.aotArrayAppend(array_object, state.numberValue(number)) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    if (object.payload.function.captures.len >= 3) {
        // capture した external コンテナの binding が GC 後も有効か確認する。
        const external_value = object.payload.function.captures[2].object().?.payload.binding_cell;
        const external_object = external_value.object() orelse {
            runtime.setFailureText("capture callback requires an external capture");
            return;
        };
        if (external_object.external == null) {
            runtime.setFailureText("external capture lost its QuickJS binding");
            return;
        }
        if (external_object.payload.dictionary.entries.items.len == 0) {
            runtime.setFailureText("external capture requires a non-empty dictionary");
            return;
        }
        runtime.aotArrayAppend(array_object, external_object.payload.dictionary.entries.items[0].value) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
    }
    out.* = captureRoundTripText(runtime, array_object) orelse return;
}

/// capture配列の先頭要素が文字列のまま残っていることを確認し、`captured:<数>`
/// をNako文字列として返す。要素数だけの確認では、文字列本体がGCで回収されて
/// タグだけ残る退行を見逃すため、UTF-8内容まで突き合わせる。
fn captureRoundTripText(runtime: *state.Runtime, array_object: *state.Object) ?Value {
    const items = array_object.payload.array.items;
    if (items.len == 0) {
        runtime.setFailureText("capture callback requires a captured string element");
        return null;
    }
    const first_tag = @as(Tag, @fromBackingInt(items[0].tag));
    if (first_tag != .utf16_string and first_tag != .static_utf8_string) {
        runtime.setFailureText("captured string element lost its string tag");
        return null;
    }
    const text = state.stringUtf8Alloc(runtime, items[0]) catch |failure| {
        runtime.setFailure(failure);
        return null;
    };
    defer runtime.allocator.free(text);
    if (!std.mem.eql(u8, text, "captured")) {
        runtime.setFailureText("captured string element lost its content");
        return null;
    }
    const combined = std.fmt.allocPrint(runtime.allocator, "{s}:{d}", .{ text, items.len }) catch |failure| {
        runtime.setFailure(failure);
        return null;
    };
    defer runtime.allocator.free(combined);
    const units = std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, combined) catch |failure| {
        runtime.setFailure(failure);
        return null;
    };
    defer runtime.allocator.free(units);
    return runtime.createString(units) catch |failure| {
        runtime.setFailure(failure);
        return null;
    };
}

fn pushTestRoots(runtime: *state.Runtime, frame: *state.RootFrame, roots: []Value) void {
    runtime.pushRoots(frame, if (roots.len == 0) null else roots.ptr, roots.len);
}

test "compat AOT runtimeはNakoクロージャをJSへ直接・入れ子で渡して同期呼出しする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    roots[0] = try state.active_runtime.?.createBindingCell(state.numberValue(0));
    roots[1] = try state.active_runtime.?.createFunction(counterCallback, 1, &.{roots[0]});
    test_capture_invocations = 0;

    // 直接渡し: JSが同じNakoクロージャを複数回呼ぶ。
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{const a=cb();const b=cb();return [a,b];}");
    arguments[0] = roots[2];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(usize, 2), test_capture_invocations);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), out.tag);
    try std.testing.expectEqual(@as(usize, 2), out.object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(out.object().?.payload.array.items[1].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[0].object().?.payload.binding_cell.payload)));

    // 辞書 `{cb: fn}` の中の Nako クロージャ。
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(o)=>{const a=o.cb();const b=o.cb();return a+b;}");
    const callback_key = try testString(&state.active_runtime.?, "cb");
    var dictionary_pairs = [_]Value{ callback_key, roots[1] };
    state.lnako_aot_dictionary_new(&roots[3], &dictionary_pairs, dictionary_pairs.len);
    arguments[0] = roots[2];
    arguments[1] = roots[3];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out.payload)));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[0].object().?.payload.binding_cell.payload)));

    // 配列 `[fn]` の中の Nako クロージャ。
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(a)=>{const x=a[0]();const y=a[0]();return x+y;}");
    var array_items = [_]Value{roots[1]};
    state.lnako_aot_array_new(&roots[3], &array_items, array_items.len);
    arguments[0] = roots[2];
    arguments[1] = roots[3];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 11), @as(f64, @bitCast(out.payload)));
    try std.testing.expectEqual(@as(f64, 6), @as(f64, @bitCast(roots[0].object().?.payload.binding_cell.payload)));
}

test "compat AOT runtimeはNako callbackの配列・辞書変更とBigIntをJSへ書き戻す" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var call_arguments = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var out: Value = .{};

    var array_items = [_]Value{state.numberValue(1)};
    state.lnako_aot_array_new(&roots[0], &array_items, array_items.len);
    const key = try testString(&state.active_runtime.?, "n");
    var dictionary_pairs = [_]Value{ key, state.numberValue(1) };
    state.lnako_aot_dictionary_new(&roots[1], &dictionary_pairs, dictionary_pairs.len);
    roots[2] = try state.active_runtime.?.createBigInt("9007199254740993");
    roots[3] = try state.active_runtime.?.createFunction(mutationCallback, 3, &.{});
    roots[4] = try evalCompatJs(&state.active_runtime.?, "(a,o,b,cb)=>{const result=cb(a,o,b);return (typeof result) + ':' + (result === 9007199254740993n);}");

    call_arguments[0] = roots[4];
    call_arguments[1] = roots[0];
    call_arguments[2] = roots[1];
    call_arguments[3] = roots[2];
    call_arguments[4] = roots[3];
    state.lnako_aot_function_call(&out, &call_arguments[0], call_arguments[1..].ptr, 4);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        // callbackの戻り値がJSのBigIntとして書き戻り、元のBigIntと一致する。
        try std.testing.expectEqualStrings("bigint:true", actual);
    }
    // Nako callback が変更した配列・辞書が JS から戻ってきている。
    const refreshed_items = roots[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), refreshed_items.len);
    try std.testing.expectEqual(@as(f64, 99), @as(f64, @bitCast(refreshed_items[1].payload)));
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(roots[1].object().?.payload.dictionary.entries.items[0].value.payload)));
}

var test_shared_argument_identity = false;

fn sharedArgumentCallback(out: *Value, _: *anyopaque, arguments_slice: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const arguments = arguments_slice orelse return;
    if (count < 2) return;
    const first = arguments[0];
    const second = arguments[1];
    test_shared_argument_identity = first.object() != null and first.object() == second.object();
    const object = first.object() orelse return;
    if (object.payload != .dictionary) return;
    const units = std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "n") catch return;
    defer runtime.allocator.free(units);
    const key = runtime.createString(units) catch return;
    var roots = [_]Value{key};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.setDictionary(&object.payload.dictionary, roots[0], state.numberValue(2)) catch return;
    out.* = first;
}

test "compat AOT runtimeは同じJSオブジェクトの複数実引数を同一のNako値へ変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var call_arguments = [_]Value{ .{}, .{}, .{} };
    var out: Value = .{};

    roots[0] = try state.active_runtime.?.createFunction(sharedArgumentCallback, 2, &.{});
    // JS が同じオブジェクトを2回渡す。Nako callback は第1引数の n を 2 にし、
    // 戻り値として JS は o.n を返す。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(o,cb)=>{cb(o,o);return o.n;}");
    const key = try testString(&state.active_runtime.?, "n");
    var dictionary_pairs = [_]Value{ key, state.numberValue(1) };
    state.lnako_aot_dictionary_new(&roots[2], &dictionary_pairs, dictionary_pairs.len);
    test_shared_argument_identity = false;
    call_arguments[0] = roots[1];
    call_arguments[1] = roots[2];
    call_arguments[2] = roots[0];
    state.lnako_aot_function_call(&out, &call_arguments[0], call_arguments[1..].ptr, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    // Nako 側で2つの実引数が同じ辞書オブジェクトになっている。
    try std.testing.expect(test_shared_argument_identity);
    // 第1引数への変更が第2引数の書戻しで失われず、JS 側の o.n も 2 になる。
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), out.tag);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(out.payload)));
    const refreshed = roots[2].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), refreshed.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(refreshed[0].value.payload)));
}

test "compat AOT runtimeはPromise.then経由のNako callbackをmicrotaskで実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    roots[0] = try state.active_runtime.?.createBindingCell(state.numberValue(0));
    roots[1] = try state.active_runtime.?.createFunction(counterCallback, 1, &.{roots[0]});
    test_capture_invocations = 0;
    // クロージャをJSのglobalThisへ渡し、Promiseのthenハンドラにする。
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{globalThis.__lnako_promise_cb=cb;return 1;}");
    arguments[0] = roots[2];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);

    // JS実行 が job を drain/await する間に callback が microtask として呼ばれる。
    roots[2] = try evalCompatJs(&state.active_runtime.?, "Promise.resolve(10).then(globalThis.__lnako_promise_cb)");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), roots[2].tag);
    // callback は 10 を受け取り、capture を1進めて 0+1+10 を返す。
    try std.testing.expectEqual(@as(f64, 11), @as(f64, @bitCast(roots[2].payload)));
    try std.testing.expectEqual(@as(usize, 1), test_capture_invocations);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[0].object().?.payload.binding_cell.payload)));
}

test "compat AOT runtimeはNako callback例外をJSのtry/catchで捕捉し未捕捉時だけ失敗する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    roots[0] = try state.active_runtime.?.createFunction(failingCallback, 0, &.{});
    // JS が catch した場合は Nako 側の未捕捉例外を残さない。try 側と catch 側で
    // 戻り値を変え、catch した例外が QuickJS の InternalError であることも確認する
    // （bridge が NULL を返すと QuickJS が InternalError に変換する）。
    roots[1] = try evalCompatJs(
        &state.active_runtime.?,
        "(cb)=>{try{cb();return 'not-thrown';}catch(e){return 'caught:' + (e instanceof Error) + ':' + e.name;}}",
    );
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("caught:true:InternalError", actual);
    }

    // catch しなければ呼出しが失敗し、Nako 側に例外が残る。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>cb()");
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);

    // callback 後の引数書き戻し失敗（frozen JS 配列への書き込み）も JS try/catch で捕捉できる。
    state.active_runtime.?.has_pending_exception = false;
    state.active_runtime.?.pending_exception = .{};
    const mutate_fn = try state.active_runtime.?.createFunction(struct {
        fn call(out_value: *Value, _: *anyopaque, args: ?[*]const Value, count: usize) callconv(.c) void {
            out_value.* = .{};
            if (count > 0 and args != null) {
                if (args.?[0].object()) |arr_obj| {
                    if (arr_obj.payload == .array and arr_obj.payload.array.items.len > 0) {
                        arr_obj.payload.array.items[0] = state.numberValue(2);
                    }
                }
            }
        }
    }.call, 1, &.{});
    roots[0] = mutate_fn;
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{try{cb(Object.freeze([1]));}catch(e){}return 7;}");
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(out.payload)));

    // 同じ書き戻し失敗を JS が catch しなければ失敗が外側へ伝播する。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>cb(Object.freeze([1]))");
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);

    // callback 戻り値の書き戻し失敗（外部の frozen 配列を返却前に変更）でも try/catch 後に例外を残さない。
    state.active_runtime.?.has_pending_exception = false;
    state.active_runtime.?.pending_exception = .{};
    const frozen_arr = try evalCompatJs(&state.active_runtime.?, "Object.freeze([1])");
    roots[2] = try state.active_runtime.?.createBindingCell(frozen_arr);
    const return_fail_fn = try state.active_runtime.?.createFunction(struct {
        fn call(out_value: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
            const fn_obj: *state.Object = @ptrCast(@alignCast(context));
            const cell = fn_obj.payload.function.captures[0];
            const captured = cell.object().?.payload.binding_cell;
            if (captured.object()) |arr_obj| {
                if (arr_obj.payload == .array and arr_obj.payload.array.items.len > 0) {
                    arr_obj.payload.array.items[0] = state.numberValue(2);
                }
            }
            out_value.* = captured;
        }
    }.call, 0, &.{roots[2]});
    roots[0] = return_fail_fn;
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{try{cb();}catch(e){}return 9;}");
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(out.payload)));

    // catch しなければ戻り値書き戻し失敗も外側へ伝播する。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "(cb)=>cb()");
    arguments[0] = roots[1];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
}

test "compat AOT runtimeはhostFunctionの登録失敗をロールバックする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    // セットアップ中は失敗させず、hostFunction 内の Zig 割当てだけを順に
    // 失敗させて、追加済みスロットが残らないことを確認する。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var runtime = state.Runtime{ .allocator = failing.allocator() };
    defer {
        failing.fail_index = std.math.maxInt(usize);
        lnako_aot_compat_deinit();
        runtime.deinit();
    }
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const engine = try ensureEngine();
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    roots[0] = try state.active_runtime.?.createFunction(noopFunction, 0, &.{});
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());

    var saw_failure = false;
    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        failing.alloc_index = 0;
        failing.fail_index = fail_index;
        const registered = compat.hostFunction(&state.active_runtime.?, engine, roots[0]);
        if (registered) |raw| {
            lnako_qjs_value_free(raw);
            succeeded = true;
            // 正常に返却できた登録だけがスロットを1個持つ。
            try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
            break;
        } else |failure| {
            saw_failure = true;
            try std.testing.expectEqual(error.OutOfMemory, failure);
            // 名前確保・append・C 関数生成のどこで失敗しても未返却スロットを
            // 残さない（append 後の失敗で pop する）。
            try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
        }
    }
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(saw_failure);
    try std.testing.expect(succeeded);
}

test "compat AOT runtimeはJSへ渡したNakoクロージャとcaptureをGC traceで保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    // capture: heap上の文字列を含む配列、JS関数値、externalなJS辞書。
    const captured_text = try testString(&state.active_runtime.?, "captured");
    var initial_items = [_]Value{captured_text};
    const captured_array = try state.active_runtime.?.createArray(&initial_items);
    roots[0] = try state.active_runtime.?.createBindingCell(captured_array);
    roots[3] = try evalCompatJs(&state.active_runtime.?, "()=>123");
    roots[1] = try state.active_runtime.?.createBindingCell(roots[3]);
    roots[4] = try evalCompatJs(&state.active_runtime.?, "({n:7})");
    roots[5] = try state.active_runtime.?.createBindingCell(roots[4]);
    roots[2] = try state.active_runtime.?.createFunction(captureRoundTripCallback, 0, &.{ roots[0], roots[1], roots[5] });

    // JSのglobalThisへ渡し、Nako側のrootを外す。
    roots[6] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{globalThis.__lnako_gc_cb=cb;return 0;}");
    arguments[0] = roots[6];
    arguments[1] = roots[2];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    state.active_runtime.?.popRoots(&frame);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);

    // Nako側から参照が消えても、compatTraceがhost関数テーブル経由で
    // クロージャ・capture配列・capture内のJS関数値・external辞書をmarkし続ける。
    var iteration: usize = 0;
    while (iteration < 4) : (iteration += 1) _ = state.active_runtime.?.collect();
    roots[6] = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_gc_cb() + ',' + globalThis.__lnako_gc_cb()");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, roots[6]);
        defer std.testing.allocator.free(actual);
        // 呼出しごとに 123 と external辞書の n=7 を追加する。1回目は3要素、2回目は5要素。
        // capture配列の先頭要素 "captured" がGC後も内容まで残っていることも、
        // callbackの戻り文字列（`captured:<要素数>`）で確認する。
        try std.testing.expectEqualStrings("captured:3,captured:5", actual);
    }
}

test "compat AOT runtimeはcompat deinitをruntimeより先に呼んでもリークしない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var out: Value = .{};

    roots[0] = try state.active_runtime.?.createBindingCell(state.numberValue(0));
    roots[1] = try state.active_runtime.?.createFunction(counterCallback, 1, &.{roots[0]});
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{globalThis.__lnako_order_cb=cb;return 0;}");
    arguments[0] = roots[2];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);

    // engine より先に host 関数テーブルと GC hook を解除する。残った external
    // binding は runtime.deinit が解放する（engine は参照カウントで保持）。
    lnako_aot_compat_deinit();
    try std.testing.expect(compat.activeEngine() == null);
}
