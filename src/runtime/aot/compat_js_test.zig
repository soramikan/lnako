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
const lnako_qjs_call = compat.lnako_qjs_call;
const lnako_qjs_host_function = compat.lnako_qjs_host_function;
const lnako_qjs_run_gc = compat.lnako_qjs_run_gc;
const lnako_qjs_take_error = compat.lnako_qjs_take_error;
const lnako_qjs_free_string = compat.lnako_qjs_free_string;

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
    var out: Value = .{};
    var arguments = [_]Value{try state.active_runtime.?.createString(units)};
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

test "compat AOT runtimeはJS関数実行の実引数をfull変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots: [8]Value = @splat(.{});
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var arguments = [_]Value{ .{}, .{} };
    var arguments_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&arguments_frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&arguments_frame);
    var out: Value = .{};
    // ネストした配列・辞書は同じfull変換でJSへ渡る。
    arguments[0] = try testString(&state.active_runtime.?, "(a, b, c) => a[0][0] + b.x + c.y.z");
    var numbers = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&roots[0], &numbers, numbers.len);
    var numbers_container = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[1], &numbers_container, numbers_container.len);
    const x_key = try testString(&state.active_runtime.?, "x");
    var x_pair = [_]Value{ x_key, state.numberValue(5) };
    state.lnako_aot_dictionary_new(&roots[2], &x_pair, x_pair.len);
    const y_key = try testString(&state.active_runtime.?, "y");
    const z_key = try testString(&state.active_runtime.?, "z");
    var z_pair = [_]Value{ z_key, state.numberValue(10) };
    state.lnako_aot_dictionary_new(&roots[3], &z_pair, z_pair.len);
    var y_pair = [_]Value{ y_key, roots[3] };
    state.lnako_aot_dictionary_new(&roots[4], &y_pair, y_pair.len);
    var container = [_]Value{ roots[1], roots[2], roots[4] };
    state.lnako_aot_array_new(&roots[5], &container, container.len);
    arguments[1] = roots[5];
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 16), @as(f64, @bitCast(out.payload)));

    // BigIntは10進文字列経由で往復する。
    arguments[0] = try testString(&state.active_runtime.?, "(v)=>v+1n");
    arguments[1] = try state.active_runtime.?.createBigInt("9007199254740993");
    lnako_aot_compat_js_call(&out, &arguments, 2);

    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(out, "9007199254740994");

    // ByteBufferは0..255の数値配列としてJSへ渡る。
    arguments[0] = try testString(&state.active_runtime.?, "(a)=>a[0]+a[2]");
    arguments[1] = try state.active_runtime.?.createByteBuffer(&.{ 1, 2, 255 }, .uint8_array);
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 256), @as(f64, @bitCast(out.payload)));

    // Nako関数値はcallbackとしてJSへ渡る。
    arguments[0] = try testString(&state.active_runtime.?, "(f)=>typeof f");
    arguments[1] = try state.active_runtime.?.createFunction(noopFunction, 0, &.{});
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const units = try state.valueUtf16Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(units);
        try std.testing.expectEqualSlices(u16, &[_]u16{ 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n' }, units);
    }

    // JS関数値は同じJS参照のまま実引数へ渡り、JSから直接呼べる。
    roots[6] = try evalCompatJs(&state.active_runtime.?, "x=>x+1");
    arguments[0] = try testString(&state.active_runtime.?, "(f)=>f(41)");
    arguments[1] = roots[6];
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(out.payload)));

    // Nako側の自己参照配列は同じJS参照の循環として渡る。
    state.lnako_aot_array_new(&roots[7], &[_]Value{.{}}, 1);
    roots[7].object().?.payload.array.items[0] = roots[7];
    arguments[0] = try testString(&state.active_runtime.?, "a => a === a[0]");
    arguments[1] = roots[7];
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.boolean)), out.tag);
    try std.testing.expect(out.payload != 0);

    // 疎配列の穴はJSでも穴のまま渡る。
    var sparse_items = [_]Value{ state.numberValue(1), .{}, state.numberValue(3) };
    state.lnako_aot_array_new(&roots[7], &sparse_items, sparse_items.len);
    roots[7].object().?.array_presence.items[1] = false;
    // 第2引数が配列だと要素がspreadされるため、単一の配列引数は外側で包む。
    var sparse_container = [_]Value{roots[7]};
    state.lnako_aot_array_new(&roots[3], &sparse_container, sparse_container.len);
    arguments[0] = try testString(&state.active_runtime.?, "a => (1 in a) ? 0 : (a.length === 3 ? 1 : 2)");
    arguments[1] = roots[3];
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.payload)));

    // WTF-8の孤立サロゲートは文字列・辞書キーの両方で保持される。
    const surrogate_units = [_]u16{0xD800};
    arguments[0] = try testString(&state.active_runtime.?, "(s,o)=>s.charCodeAt(0) + o['\\uD800']");
    roots[1] = try state.active_runtime.?.createString(&surrogate_units);
    roots[2] = try state.active_runtime.?.createString(&surrogate_units);
    var surrogate_pair = [_]Value{ roots[2], state.numberValue(1) };
    state.lnako_aot_dictionary_new(&roots[0], &surrogate_pair, surrogate_pair.len);
    var surrogate_values = [_]Value{ roots[1], roots[0] };
    state.lnako_aot_array_new(&roots[3], &surrogate_values, surrogate_values.len);
    var surrogate_arguments = [_]Value{ arguments[0], roots[3] };
    lnako_aot_compat_js_call(&out, &surrogate_arguments, surrogate_arguments.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 55297), @as(f64, @bitCast(out.payload)));
}

test "compat AOT runtimeはJS関数実行のNako Promise引数を明示エラーにする" {
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
    arguments[0] = try testString(&state.active_runtime.?, "x => x");
    arguments[1] = try @import("async.zig").createAotPromise(&state.active_runtime.?);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "does not support promises or unsupported argument types");
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

test "compat AOT runtimeはJS関数実行の戻り値をJS実行と同じfull変換にする" {
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

    const array_value = try callCompatJs(&state.active_runtime.?, "()=>[1,2]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), array_value.tag);
    const array_items = array_value.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), array_items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(array_items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(array_items[1].payload)));
    // full変換でもJS参照（external binding）は保持する。
    try std.testing.expect(array_value.object().?.external != null);

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

    // ネストした配列・辞書は再帰変換する。
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>({a:[1,{b:2}]})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const nested_entries = roots[0].object().?.payload.dictionary.entries.items;
    try std.testing.expectEqual(@as(usize, 1), nested_entries.len);
    const nested_array = nested_entries[0].value.object().?;
    try std.testing.expectEqual(@as(usize, 2), nested_array.payload.array.items.len);
    const nested_dictionary = nested_array.payload.array.items[1].object().?;
    try std.testing.expectEqual(@as(usize, 1), nested_dictionary.payload.dictionary.entries.items.len);
    try std.testing.expectEqual(
        @as(f64, 2),
        @as(f64, @bitCast(nested_dictionary.payload.dictionary.entries.items[0].value.payload)),
    );

    // BigInt・bytes（TypedArray/ArrayBuffer）もfull変換で保持する。
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>1n");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(roots[0], "1");
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>new Uint8Array([1,2])");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), roots[0].tag);

    // 関数値はAOTのexternal関数値として保持する。
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>(x)=>x+1");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), roots[0].tag);
    try std.testing.expect(roots[0].object().?.external != null);

    // 自己参照・疎配列も同じfull変換で保持する。
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>{const a=[1];a.push(a);return a;}");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const cyclic = roots[0].object().?;
    try std.testing.expect(cyclic.payload.array.items[1].object().? == cyclic);
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>[1,,3]");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const sparse = roots[0].object().?;
    try std.testing.expectEqual(@as(usize, 3), sparse.array_presence.items.len);
    try std.testing.expect(!sparse.array_presence.items[1]);

    // 孤立サロゲートは配列要素・辞書キーの両方で保持する。
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>['\\uD800']");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const surrogate_units = try state.valueUtf16Alloc(&state.active_runtime.?, roots[0].object().?.payload.array.items[0]);
        defer std.testing.allocator.free(surrogate_units);
        try std.testing.expectEqualSlices(u16, &[_]u16{0xD800}, surrogate_units);
    }
    roots[0] = try callCompatJs(&state.active_runtime.?, "()=>({'\\uD800':1})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const entry = roots[0].object().?.payload.dictionary.entries.items[0];
        const key_units = try state.valueUtf16Alloc(&state.active_runtime.?, entry.key);
        defer std.testing.allocator.free(key_units);
        try std.testing.expectEqualSlices(u16, &[_]u16{0xD800}, key_units);
    }
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

    // 0引数形だけが「値とプロパティ名」のエラーになる。1引数形（公式の
    // グローバル名解決）はAOTでも解決できる（Unit 2）。
    lnako_aot_compat_js_object_get(&out, values[0..0], 0);
    try expectPendingFailureContains(&state.active_runtime.?, "requires a value and a property name");
    // 3引数以上は従来どおりプロパティ名のみのエラーになる。
    var too_many = [_]Value{ values[0], values[1], values[1] };
    lnako_aot_compat_js_object_get(&out, &too_many, too_many.len);
    try expectPendingFailureContains(&state.active_runtime.?, "accepts a value and a property name only");
}

// Issue #55 Unit 2: 1引数 `JSオブジェクト取得` の名前解決fixture。
// 1引数形はQuickJS engineを必要としないため、通常buildのテストでも実行する。
fn doubleFunction(out: *Value, _: *anyopaque, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    if (count == 0) return;
    const number: f64 = @bitCast(arguments.?[0].payload);
    out.* = state.numberValue(number * 2);
}

fn expectObjectGetResolved(runtime: *state.Runtime, argument: Value, expected_tag: u8, expected_payload: u64) !void {
    var out: Value = .{};
    var values = [_]Value{argument};
    lnako_aot_compat_js_object_get(&out, &values, 1);
    try std.testing.expect(!runtime.has_pending_exception);
    try std.testing.expectEqual(expected_tag, out.tag);
    try std.testing.expectEqual(expected_payload, out.payload);
}

fn expectObjectGetNull(runtime: *state.Runtime, argument: Value) !void {
    try expectObjectGetResolved(runtime, argument, @backingInt(Tag.null_value), 0);
}

test "compat AOT runtimeはJSオブジェクト取得の1引数形で関数値をそのまま返す" {
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
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

    // 関数値は名前解決せず、そのまま返す（interpreterの `requested == .function`）。
    roots[0] = try state.active_runtime.?.createFunction(noopFunction, 0, &.{});
    var out: Value = .{};
    var values = [_]Value{roots[0]};
    lnako_aot_compat_js_object_get(&out, &values, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(roots[0].tag, out.tag);
    try std.testing.expectEqual(roots[0].payload, out.payload);
}

test "compat AOT runtimeはJSオブジェクト取得の1引数形で変数フレームと名前付き関数を解決する" {
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var storage = [_]Value{
        state.numberValue(1), // outer 共有
        state.numberValue(2), // inner 共有
        Value.unboundValue(), // inner 未束縛
        state.numberValue(7), // outer 未束縛
        .{}, // inner セル
        .{}, // named function F
    };
    var roots = [_]Value{ .{}, .{}, .{} };
    var storage_frame: state.RootFrame = .{};
    var roots_frame: state.RootFrame = .{};
    active.pushRoots(&storage_frame, &storage, storage.len);
    active.pushRoots(&roots_frame, &roots, roots.len);
    defer active.popRoots(&roots_frame);
    defer active.popRoots(&storage_frame);
    storage[4] = try active.createBindingCell(state.numberValue(42));
    storage[5] = try active.createNamedFunction(doubleFunction, 1, "F", &.{});
    var outer_entries = [_]state.AotVarEntry{
        .{ .name_ptr = "共有".ptr, .name_len = "共有".len },
        .{ .name_ptr = "未束縛".ptr, .name_len = "未束縛".len },
    };
    var outer_slots = [_]*const Value{ &storage[0], &storage[3] };
    var inner_entries = [_]state.AotVarEntry{
        .{ .name_ptr = "共有".ptr, .name_len = "共有".len },
        .{ .name_ptr = "未束縛".ptr, .name_len = "未束縛".len },
        .{ .name_ptr = "セル".ptr, .name_len = "セル".len },
    };
    var inner_slots = [_]*const Value{ &storage[1], &storage[2], &storage[4] };

    var outer_frame: state.AotVarFrame = .{};
    active.pushVarFrame(&outer_frame, &outer_entries, outer_entries.len, &outer_slots);
    defer active.popVarFrame(&outer_frame);
    // フレームが無い/外側だけの状態から解決する。
    try expectObjectGetResolved(active, try testString(active, "共有"), @backingInt(Tag.number), @bitCast(@as(f64, 1)));
    try expectObjectGetResolved(active, try testString(active, "未束縛"), @backingInt(Tag.number), @bitCast(@as(f64, 7)));

    var inner_frame: state.AotVarFrame = .{};
    active.pushVarFrame(&inner_frame, &inner_entries, inner_entries.len, &inner_slots);
    // 内側の束縛が外側をシャドーイングする。
    try expectObjectGetResolved(active, try testString(active, "共有"), @backingInt(Tag.number), @bitCast(@as(f64, 2)));
    // 未束縛の内側ローカルは外側の束縛済み値へフォールバックする。
    try expectObjectGetResolved(active, try testString(active, "未束縛"), @backingInt(Tag.number), @bitCast(@as(f64, 7)));
    // クロージャcaptureのBindingCellは値をアンラップして返す。
    try expectObjectGetResolved(active, try testString(active, "セル"), @backingInt(Tag.number), @bitCast(@as(f64, 42)));

    // 名前付き関数は同じClosureオブジェクトを繰り返し返し、JS関数実行で呼べる。
    var first: Value = .{};
    var first_values = [_]Value{try testString(active, "F")};
    lnako_aot_compat_js_object_get(&first, &first_values, 1);
    try std.testing.expect(!active.has_pending_exception);
    var second: Value = .{};
    var second_values = [_]Value{try testString(active, "F")};
    lnako_aot_compat_js_object_get(&second, &second_values, 1);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), first.tag);
    try std.testing.expectEqual(first.tag, second.tag);
    try std.testing.expectEqual(first.payload, second.payload);

    var call_values = [_]Value{ first, .{} };
    var call_roots = [_]Value{ first, .{} };
    var call_frame: state.RootFrame = .{};
    active.pushRoots(&call_frame, &call_roots, call_roots.len);
    defer active.popRoots(&call_frame);
    var call_argument = [_]Value{state.numberValue(4)};
    state.lnako_aot_array_new(&call_values[1], &call_argument, call_argument.len);
    call_roots[1] = call_values[1];
    var call_out: Value = .{};
    lnako_aot_compat_js_call(&call_out, &call_values, call_values.len);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(call_out.payload)));

    // 例外巻戻し相当のpopの後は、内側の名前が外側／グローバルへ落ちる。
    // 重複popはLIFOを壊さず、外側フレームの値とそれ以外を保つ。
    active.popVarFrame(&inner_frame);
    active.popVarFrame(&inner_frame);
    try expectObjectGetResolved(active, try testString(active, "共有"), @backingInt(Tag.number), @bitCast(@as(f64, 1)));
    try expectObjectGetNull(active, try testString(active, "セル"));
    active.popVarFrame(&outer_frame);
    try expectObjectGetNull(active, try testString(active, "共有"));
    // pop後の名前付き関数はグローバルとして引き続き解決できる。
    try expectObjectGetResolved(active, try testString(active, "F"), first.tag, first.payload);
}

test "compat AOT runtimeはJSオブジェクト取得の1引数形で動的グローバルと真偽値規則を解決する" {
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // 完全一致と `{module}__{name}` サフィックス。
    try state.upsertDynamicGlobal(active, "完全一致", state.numberValue(3));
    try state.upsertDynamicGlobal(active, "modA__接尾辞", state.numberValue(4));
    try expectObjectGetResolved(active, try testString(active, "完全一致"), @backingInt(Tag.number), @bitCast(@as(f64, 3)));
    try expectObjectGetResolved(active, try testString(active, "接尾辞"), @backingInt(Tag.number), @bitCast(@as(f64, 4)));

    // 異なるモジュールの同名サフィックスは曖昧性エラーとして伝播する。
    try state.upsertDynamicGlobal(active, "modB__接尾辞", state.numberValue(5));
    var ambiguous: Value = .{};
    var ambiguous_values = [_]Value{try testString(active, "接尾辞")};
    lnako_aot_compat_js_object_get(&ambiguous, &ambiguous_values, 1);
    try expectPendingFailureContains(active, "AmbiguousGlobal");

    // falsyな値・null・undefined・未解決の名前はNakoのnullになる。
    try state.upsertDynamicGlobal(active, "ゼロ", state.numberValue(0));
    try state.upsertDynamicGlobal(active, "偽", .{ .tag = @backingInt(Tag.boolean), .payload = 0 });
    try state.upsertDynamicGlobal(active, "空文字", try testString(active, ""));
    try state.upsertDynamicGlobal(active, "ヌル", .{ .tag = @backingInt(Tag.null_value) });
    try state.upsertDynamicGlobal(active, "未定義値", .{});
    try expectObjectGetNull(active, try testString(active, "ゼロ"));
    try expectObjectGetNull(active, try testString(active, "偽"));
    try expectObjectGetNull(active, try testString(active, "空文字"));
    try expectObjectGetNull(active, try testString(active, "ヌル"));
    try expectObjectGetNull(active, try testString(active, "未定義値"));
    try expectObjectGetNull(active, try testString(active, "存在しない"));
    // QuickJSのglobalThisへはフォールバックしない。
    try expectObjectGetNull(active, try testString(active, "Math"));

    // 非文字列キーはpropertyNameZで文字列化してから解決する。
    try state.upsertDynamicGlobal(active, "123", state.numberValue(77));
    try expectObjectGetResolved(active, state.numberValue(123), @backingInt(Tag.number), @bitCast(@as(f64, 77)));
    try expectObjectGetNull(active, try testString(active, "undefined"));

    // システム定数（真値はそのまま、falsyはnull）。
    try expectObjectGetResolved(active, try testString(active, "PI"), @backingInt(Tag.number), @bitCast(@as(f64, std.math.pi)));
    const version = try testString(active, "ナデシコバージョン");
    var version_out: Value = .{};
    var version_values = [_]Value{version};
    lnako_aot_compat_js_object_get(&version_out, &version_values, 1);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), version_out.tag);
    try std.testing.expectEqualSlices(u16, &.{ '3', '.', '7', '.', '2', '4' }, version_out.object().?.payload.utf16_string);
    try expectObjectGetNull(active, try testString(active, "AJAX:ONERROR"));
    try expectObjectGetNull(active, try testString(active, "未定義"));
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

test "compat AOT runtimeはJSオブジェクト取得とJSメソッド実行で非externalコンテナをfull変換する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots: [8]Value = @splat(.{});
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    defer state.active_runtime.?.popRoots(&frame);
    var out: Value = .{};

    // JSオブジェクト取得([[1]], "0") は非externalのネスト配列をJSへコピーし、
    // 取得した配列にexternal bindingを付与する。
    var inner_numbers = [_]Value{state.numberValue(1)};
    state.lnako_aot_array_new(&roots[0], &inner_numbers, inner_numbers.len);
    var inner_array = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[1], &inner_array, inner_array.len);
    var object_get_args = [_]Value{ roots[1], try testString(&state.active_runtime.?, "0") };
    lnako_aot_compat_js_object_get(&out, &object_get_args, object_get_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), out.tag);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.object().?.payload.array.items[0].payload)));
    try std.testing.expect(out.object().?.external != null);

    // ネストした辞書も同じ規則で取得できる。
    const a_key = try testString(&state.active_runtime.?, "a");
    const b_key = try testString(&state.active_runtime.?, "b");
    var b_pair = [_]Value{ b_key, state.numberValue(5) };
    state.lnako_aot_dictionary_new(&roots[2], &b_pair, b_pair.len);
    var a_pair = [_]Value{ a_key, roots[2] };
    state.lnako_aot_dictionary_new(&roots[3], &a_pair, a_pair.len);
    var nested_get_args = [_]Value{ roots[3], a_key };
    lnako_aot_compat_js_object_get(&out, &nested_get_args, nested_get_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.dictionary)), out.tag);

    // コンテナ内のBigIntも、制限付き結果変換（`convertResult`）では
    // interpreterの`interop_result`と同じく拒否する。呼出し後のrefreshは
    // `convertFull`を使うため、refresh時のBigInt保持は変わらない。
    roots[4] = try evalCompatJs(&state.active_runtime.?, "[1n]");
    var bigint_get_args = [_]Value{ roots[4], try testString(&state.active_runtime.?, "0") };
    lnako_aot_compat_js_object_get(&out, &bigint_get_args, bigint_get_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support promises, functions, bigint, or bytes yet");

    // JSメソッド実行: 非externalのネスト配列・辞書・Nako callback・BigInt・
    // 循環配列を同じfull変換で渡す。
    roots[5] = try state.active_runtime.?.createFunction(noopFunction, 0, &.{});
    var callback_container = [_]Value{roots[5]};
    state.lnako_aot_array_new(&roots[6], &callback_container, callback_container.len);
    var x_pair = [_]Value{ try testString(&state.active_runtime.?, "x"), state.numberValue(5) };
    state.lnako_aot_dictionary_new(&roots[0], &x_pair, x_pair.len);
    var dict_container = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[0], &dict_container, dict_container.len);
    var n_pair = [_]Value{ try testString(&state.active_runtime.?, "n"), try state.active_runtime.?.createBigInt("42") };
    state.lnako_aot_dictionary_new(&roots[1], &n_pair, n_pair.len);
    state.lnako_aot_array_new(&roots[2], &[_]Value{.{}}, 1);
    roots[2].object().?.payload.array.items[0] = roots[2];
    var method_values = [_]Value{ roots[0], roots[6], roots[1], roots[2] };
    state.lnako_aot_array_new(&roots[3], &method_values, method_values.len);
    var method_arg_roots: [2]Value = @splat(.{});
    var method_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&method_frame, &method_arg_roots, method_arg_roots.len);
    defer state.active_runtime.?.popRoots(&method_frame);
    method_arg_roots[0] = try testString(&state.active_runtime.?, "({m(...a){return String(a[0][0].x) + typeof a[1][0] + typeof a[2].n + (a[3] === a[3][0])}})");
    method_arg_roots[1] = try testString(&state.active_runtime.?, "m");
    var method_args = [_]Value{ method_arg_roots[0], method_arg_roots[1], roots[3] };
    lnako_aot_compat_js_method_call(&out, &method_args, method_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("5functionbiginttrue", actual);
    }

    // コンテナ内のbytesはAOTでも従来どおり明示エラーにする。
    const bytes = try state.active_runtime.?.createByteBuffer(&.{1}, .uint8_array);
    var bytes_container = [_]Value{bytes};
    state.lnako_aot_array_new(&roots[0], &bytes_container, bytes_container.len);
    var bytes_get_args = [_]Value{ roots[0], try testString(&state.active_runtime.?, "0") };
    lnako_aot_compat_js_object_get(&out, &bytes_get_args, bytes_get_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support");
    var bytes_method_values = [_]Value{bytes};
    state.lnako_aot_array_new(&roots[1], &bytes_method_values, bytes_method_values.len);
    var bytes_method_arg_roots: [2]Value = @splat(.{});
    var bytes_method_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&bytes_method_frame, &bytes_method_arg_roots, bytes_method_arg_roots.len);
    defer state.active_runtime.?.popRoots(&bytes_method_frame);
    bytes_method_arg_roots[0] = try testString(&state.active_runtime.?, "({m(a){return a.length}})");
    bytes_method_arg_roots[1] = try testString(&state.active_runtime.?, "m");
    var bytes_method_args = [_]Value{ bytes_method_arg_roots[0], bytes_method_arg_roots[1], roots[1] };
    lnako_aot_compat_js_method_call(&out, &bytes_method_args, bytes_method_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "JSメソッド実行 does not support");

    // トップレベルの関数・BigInt・bytes・Promiseは引き続き拒否する。
    var rejected_receivers: [4]Value = @splat(.{});
    var rejected_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&rejected_frame, &rejected_receivers, rejected_receivers.len);
    defer state.active_runtime.?.popRoots(&rejected_frame);
    rejected_receivers[0] = roots[5];
    rejected_receivers[1] = try state.active_runtime.?.createBigInt("1");
    rejected_receivers[2] = bytes;
    rejected_receivers[3] = try @import("async.zig").createAotPromise(&state.active_runtime.?);
    for (rejected_receivers) |receiver| {
        var rejected_args = [_]Value{ receiver, try testString(&state.active_runtime.?, "x") };
        lnako_aot_compat_js_object_get(&out, &rejected_args, rejected_args.len);
        try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support");
    }
    // JSメソッド実行のトップレベル関数実引数も拒否する。
    var top_level_fn_arg_roots: [2]Value = @splat(.{});
    var top_level_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&top_level_frame, &top_level_fn_arg_roots, top_level_fn_arg_roots.len);
    defer state.active_runtime.?.popRoots(&top_level_frame);
    top_level_fn_arg_roots[0] = try testString(&state.active_runtime.?, "[1,2]");
    top_level_fn_arg_roots[1] = try testString(&state.active_runtime.?, "join");
    var top_level_fn_args = [_]Value{ top_level_fn_arg_roots[0], top_level_fn_arg_roots[1], roots[5] };
    lnako_aot_compat_js_method_call(&out, &top_level_fn_args, top_level_fn_args.len);
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
    // 要素値はroot frame経由で保持される（`resultFromRaw` はrawを消費する）。
    const dictionary = try compat_result.resultFromRaw(&state.active_runtime.?, raw);
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

    // `JS関数実行` の戻り値も #280 以降は full 変換（convertFullObject）を通るが、
    // ownKeys 例外の文言は同じく保持される。
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
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support promises, functions, bigint, or bytes yet");

    // 入れ子の辞書直下でも同じ文言で拒否する。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({nested:{n:1n}})");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    roots[1] = try testString(&state.active_runtime.?, "nested");
    lnako_aot_compat_js_object_get(&out, roots[0..2].ptr, 2);
    try expectPendingFailureContains(&state.active_runtime.?, "JSオブジェクト取得 does not support promises, functions, bigint, or bytes yet");

    // `JSメソッド実行` が返したBigIntも同じ文言で拒否する。
    roots[0] = try testString(&state.active_runtime.?, "({get(){return 1n}})");
    roots[1] = try testString(&state.active_runtime.?, "get");
    state.lnako_aot_array_new(&roots[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &roots, 3);
    try expectPendingFailureContains(&state.active_runtime.?, "JSメソッド実行 does not support promises, functions, bigint, or bytes yet");

    // 呼出し後のrefreshは`convertFull`を使うため、結果変換が拒否するBigIntでも
    // Nako側の辞書値としては保持される。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "({n:1,set(){this.n=1n;return 'ok';}})");
    roots[1] = try testString(&state.active_runtime.?, "set");
    state.lnako_aot_array_new(&roots[2], null, 0);
    lnako_aot_compat_js_method_call(&out, &roots, 3);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText((try dictionaryValueByKey(&state.active_runtime.?, roots[0], "n")).?, "1");
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

    // 解決値もfull変換する（BigInt・ネスト配列）。
    const bigint_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve(1n)");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try expectBigIntText(bigint_value, "1");
    const nested_value = try callCompatJs(&state.active_runtime.?, "()=>Promise.resolve([1,[2]])");
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), nested_value.tag);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), nested_value.object().?.payload.array.items[1].tag);

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

test "compat AOT runtimeはESM plugin呼出し前後でAOT変数を同期しplugin固有値を保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    // plugin は `sys.__getSysVar` / `sys.__setSysVar` でAOT変数を読み書きする。
    // `P` は plugin が `.function` を書き込むケース、`Q` は `初期化` が
    // `.function` を書き込むケースの確認に使う。
    const manifest =
        \\[{"path":"/lnako-compat-test/sync-plugin.mjs","source":"export default { 初期化: function(sys) { sys.__setSysVar('Q', () => 9); }, 取得: { type: 'func', fn: (sys) => sys.__getSysVar('X', -1) }, 設定: { type: 'func', fn: (sys) => { sys.__setSysVar('S', 7); return 0; } }, 読S: { type: 'func', fn: (sys) => sys.__getSysVar('S', -1) }, 設定P: { type: 'func', fn: (sys) => { sys.__setSysVar('P', () => 7); return 0; } }, P呼出: { type: 'func', fn: (sys) => sys.__getSysVar('P', null)() }, P種別: { type: 'func', fn: (sys) => typeof sys.__getSysVar('P', null) }, Q呼出: { type: 'func', fn: (sys) => sys.__getSysVar('Q', null)() }, Q種別: { type: 'func', fn: (sys) => typeof sys.__getSysVar('Q', null) } };","is_plugin":true,"namespaces":[],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);

    // 1) runDynamicSource なしでも AOT の X=42 が plugin から見える。
    //    `初期化` がAOT変数 Q を `.function` で上書きした状態も同時に作る。
    try state.upsertDynamicGlobal(active, "X", state.numberValue(42));
    try state.upsertDynamicGlobal(active, "Q", state.numberValue(1));
    const visible = try state.esmPluginBuiltin(active, "取得", &.{});
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), visible.tag);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(visible.payload)));
    const initialized = try state.esmPluginBuiltin(active, "Q呼出", &.{});
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), initialized.tag);
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(initialized.payload)));

    // 2) plugin の `sys.__setSysVar` が AOT dynamic_globals へ書き戻る。
    _ = try state.esmPluginBuiltin(active, "設定", &.{});
    const written = state.dynamicGlobal(active, "S") orelse return error.TestUnexpectedResult;
    const written_raw = if (written.slot) |slot| slot.* else written.value;
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), written_raw.tag);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(written_raw.payload)));
    const reread = try state.esmPluginBuiltin(active, "読S", &.{});
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(reread.payload)));
    // AOT 側の `JS実行` からも同じ値が見える。
    const via_aot = try evalCompatJs(active, "sys.__getSysVar('S','miss')");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(via_aot.payload)));

    // 3) 次のAOT変更 X=99 は次のplugin呼出しへ伝播する。
    try state.upsertDynamicGlobal(active, "X", state.numberValue(99));
    const updated = try state.esmPluginBuiltin(active, "取得", &.{});
    try std.testing.expectEqual(@as(f64, 99), @as(f64, @bitCast(updated.payload)));

    // 4) plugin が P を `.function` で上書きしても、AOT側が未変更なら
    //    次の呼出しで潰さない。AOT側を変更したら上書きされる。
    try state.upsertDynamicGlobal(active, "P", state.numberValue(1));
    _ = try state.esmPluginBuiltin(active, "設定P", &.{});
    const preserved = try state.esmPluginBuiltin(active, "P呼出", &.{});
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), preserved.tag);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(preserved.payload)));
    try state.upsertDynamicGlobal(active, "P", state.numberValue(5));
    const replaced = try state.esmPluginBuiltin(active, "P種別", &.{});
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), replaced.tag);
    const expected_kind = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "number");
    defer std.testing.allocator.free(expected_kind);
    try std.testing.expectEqualSlices(u16, expected_kind, replaced.object().?.payload.utf16_string);

    // `初期化` が書いた Q も、AOT側を変更すれば上書きされる。
    try state.upsertDynamicGlobal(active, "Q", state.numberValue(5));
    const q_replaced = try state.esmPluginBuiltin(active, "Q種別", &.{});
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), q_replaced.tag);
    try std.testing.expectEqualSlices(u16, expected_kind, q_replaced.object().?.payload.utf16_string);

    // 5) 同期fingerprintは保持され、DynamicInterpreterState.deinit で
    //    std.testing.allocator のリーク検査に引っかからない。
    const dynamic_state = active.dynamic_state orelse return error.TestUnexpectedResult;
    try std.testing.expect(dynamic_state.synced_aot_hashes.count() >= 3);
}

fn gcTriggerCallback(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = &(state.active_runtime orelse return);
    // 元グローバルの参照を外してから GC を実行し、plugin 呼出し中に
    // `containers[].aot` が回収されないことを検証する。
    state.upsertDynamicGlobal(runtime, "GcTarget", state.numberValue(0)) catch return;
    _ = runtime.collect();
    out.* = state.numberValue(123);
}

test "compat AOT runtimeはESM pluginの循環・共有参照・大配列・辞書削除・失敗原子性・例外時書き戻しを保つ" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // 未束縛の静的グローバルスロットを登録し、`初期化` の値が反映されるか確認する。
    var static_init_slot = [_]Value{Value.unboundValue()};
    var static_init_frame = state.RootFrame{};
    pushTestRoots(active, &static_init_frame, &static_init_slot);
    defer active.popRoots(&static_init_frame);
    state.lnako_aot_dynamic_global_register("StaticInit".ptr, "StaticInit".len, &static_init_slot[0]);

    const manifest =
        \\[{"path":"/lnako-compat-test/edge-sync-plugin.mjs","source":"export default { 初期化: function(sys) { sys.__setSysVar('InitNum', 42); sys.__setSysVar('StaticInit', 99); }, 無操作: { type: 'func', fn: () => 0 }, 要素変更: { type: 'func', fn: (a) => { a[0] = 9; return 1; } }, 入れ子変更返却: { type: 'func', fn: (p) => { p[0][0] = 55; return p[0]; } }, 関数返却: { type: 'func', fn: (f) => f }, 関数保存: { type: 'func', fn: (f) => { globalThis.__saved_fn = f; return 0; } }, 保存関数返却: { type: 'func', fn: () => ({ fn: globalThis.__saved_fn }) }, 保存関数グローバル書込: { type: 'func', fn: (sys) => { sys.__setSysVar('SavedFn', globalThis.__saved_fn); return 0; } }, A確認: { type: 'func', fn: (sys) => sys.__getSysVar('A', null)[0] }, 末尾確認: { type: 'func', fn: (sys) => sys.__getSysVar('Big', [])[299] }, Big上書: { type: 'func', fn: (sys) => { sys.__setSysVar('Big', () => 7); return 0; } }, Big種別: { type: 'func', fn: (sys) => typeof sys.__getSysVar('Big', null) }, 要素関数書込: { type: 'func', fn: (a) => { a[0] = () => 7; return 0; } }, キー削除: { type: 'func', fn: (d) => { delete d.x; return 0; } }, 変更後例外: { type: 'func', fn: (a) => { a[0] = 77; throw new Error('boom'); } }, 非同期例外: { type: 'func', fn: async (a) => { a[0] = 88; throw new Error('async-boom'); } }, 関数経由GC: { type: 'func', fn: (arr, cb) => { const r = cb(); arr[0] = r; return arr; } } };","is_plugin":true,"namespaces":[],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);

    var frame = state.RootFrame{};
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);

    // 1) 自己参照グローバルがあっても無関係な plugin 呼出しで落ちず、
    //    `初期化` が書いた変換可能な通常グローバル・未束縛静的slotも AOT へ反映される。
    roots[0] = try active.createArray(&.{});
    try roots[0].object().?.payload.array.append(active.allocator, roots[0]);
    try state.upsertDynamicGlobal(active, "Cyc", roots[0]);
    _ = try state.esmPluginBuiltin(active, "無操作", &.{});
    const init_num_entry = state.dynamicGlobal(active, "InitNum") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(init_num_entry.value.payload)));
    try std.testing.expectEqual(@as(f64, 99), @as(f64, @bitCast(static_init_slot[0].payload)));

    // 2) A と B=A、さらに入れ子要素 Parent=[A] との共有参照・戻り値同一性を維持し、
    //    引数への変更もグローバル同期で取り消されない。
    roots[1] = try active.createArray(&.{state.numberValue(1)});
    roots[5] = try active.createArray(&.{roots[1]});
    try state.upsertDynamicGlobal(active, "A", roots[1]);
    try state.upsertDynamicGlobal(active, "B", roots[1]);
    _ = try state.esmPluginBuiltin(active, "無操作", &.{});
    const b_after_noop = state.dynamicGlobal(active, "B") orelse return error.TestUnexpectedResult;
    const b_raw_noop = if (b_after_noop.slot) |slot| slot.* else b_after_noop.value;
    try std.testing.expectEqual(roots[1].payload, b_raw_noop.payload);

    const changed_ret = try state.esmPluginBuiltin(active, "要素変更", &.{roots[1]});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(changed_ret.payload)));
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(roots[1].object().?.payload.array.items[0].payload)));
    const a_entry = state.dynamicGlobal(active, "A") orelse return error.TestUnexpectedResult;
    const b_entry = state.dynamicGlobal(active, "B") orelse return error.TestUnexpectedResult;
    const a_raw = if (a_entry.slot) |slot| slot.* else a_entry.value;
    const b_raw = if (b_entry.slot) |slot| slot.* else b_entry.value;
    try std.testing.expectEqual(roots[1].payload, a_raw.payload);
    try std.testing.expectEqual(roots[1].payload, b_raw.payload);
    const a_read = try state.esmPluginBuiltin(active, "A確認", &.{});
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(a_read.payload)));

    // 親配列経由で入れ子要素を書き換えてそのまま返す場合も、元の Child と同一オブジェクトになる。
    const nested_ret = try state.esmPluginBuiltin(active, "入れ子変更返却", &.{roots[5]});
    try std.testing.expectEqual(roots[1].payload, nested_ret.payload);
    try std.testing.expectEqual(@as(f64, 55), @as(f64, @bitCast(roots[1].object().?.payload.array.items[0].payload)));

    // 3) 300要素配列の256要素以降の変更も完全構造 fingerprint で検出する。
    //    plugin が Big を JS 関数へ上書きした状態で Big[299] 未変更なら関数を保持し、
    //    Big[299] を変更すると fingerprint 差分で AOT の Big が再同期される。
    roots[2] = try active.createArray(&.{});
    for (0..300) |i| {
        try roots[2].object().?.payload.array.append(active.allocator, state.numberValue(@floatFromInt(i)));
    }
    try state.upsertDynamicGlobal(active, "Big", roots[2]);
    _ = try state.esmPluginBuiltin(active, "Big上書", &.{});
    const big_fn_kind = try state.esmPluginBuiltin(active, "Big種別", &.{});
    const expected_fn_kind = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "function");
    defer std.testing.allocator.free(expected_fn_kind);
    try std.testing.expectEqualSlices(u16, expected_fn_kind, big_fn_kind.object().?.payload.utf16_string);
    roots[2].object().?.payload.array.items[299] = state.numberValue(999);
    const tail_after = try state.esmPluginBuiltin(active, "末尾確認", &.{});
    try std.testing.expectEqual(@as(f64, 999), @as(f64, @bitCast(tail_after.payload)));

    // 4) 変換不能値の書き戻し失敗は伝播し、元の配列を破壊（空配列化）しない。
    roots[3] = try active.createArray(&.{ state.numberValue(1), state.numberValue(2) });
    try std.testing.expectError(
        error.DynamicValueUnsupported,
        state.esmPluginBuiltin(active, "要素関数書込", &.{roots[3]}),
    );
    try std.testing.expectEqual(@as(usize, 2), roots[3].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[3].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[3].object().?.payload.array.items[1].payload)));

    // 5) 辞書引数の delete は AOT 側の辞書エントリからも削除される。
    roots[4] = try active.createDictionary(&.{});
    const k_x = try testString(active, "x");
    const k_y = try testString(active, "y");
    var key_frame = state.RootFrame{};
    var key_roots = [_]Value{ k_x, k_y };
    pushTestRoots(active, &key_frame, &key_roots);
    defer active.popRoots(&key_frame);
    try active.setDictionary(&roots[4].object().?.payload.dictionary, key_roots[0], state.numberValue(1));
    try active.setDictionary(&roots[4].object().?.payload.dictionary, key_roots[1], state.numberValue(2));
    _ = try state.esmPluginBuiltin(active, "キー削除", &.{roots[4]});
    try std.testing.expectEqual(@as(usize, 1), roots[4].object().?.payload.dictionary.entries.items.len);
    try std.testing.expect(roots[4].object().?.payload.dictionary.findByKey(key_roots[0]) == null);
    try std.testing.expect(roots[4].object().?.payload.dictionary.findByKey(key_roots[1]) != null);

    // 6) 同期 throw と async Promise reject の両方で送出前の配列引数変更と失敗文言を保つ。
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        state.esmPluginBuiltin(active, "変更後例外", &.{roots[3]}),
    );
    try std.testing.expectEqual(@as(f64, 77), @as(f64, @bitCast(roots[3].object().?.payload.array.items[0].payload)));
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        state.esmPluginBuiltin(active, "非同期例外", &.{roots[3]}),
    );
    try std.testing.expectEqual(@as(f64, 88), @as(f64, @bitCast(roots[3].object().?.payload.array.items[0].payload)));
    const async_failure = active.dynamic_state.?.value_runtime.failureMessage() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, async_failure, "async-boom") != null);

    // 7) plugin から呼ばれる AOT callback が元グローバルを外して GC を起こしても、
    //    `containers[].aot` が GC 保護され UAF を起こさずに書き戻し・返却できる。
    try state.upsertDynamicGlobal(active, "GcTarget", try active.createArray(&.{state.numberValue(10)}));
    const gc_target = state.dynamicGlobal(active, "GcTarget") orelse return error.TestUnexpectedResult;
    roots[6] = try active.createNamedFunction(gcTriggerCallback, 0, "GcTrigger", &.{});
    const gc_ret = try state.esmPluginBuiltin(active, "関数経由GC", &.{ gc_target.value, roots[6] });
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.array)), gc_ret.tag);
    try std.testing.expectEqual(@as(f64, 123), @as(f64, @bitCast(gc_ret.object().?.payload.array.items[0].payload)));

    // 8) AOT 関数を含む配列を無操作 plugin に渡しても `DynamicValueUnsupported` にならず、
    //    AOT 関数の直接返却・呼出しを跨いで保存したラッパの返却・`sys.__setSysVar` 経由でも元の関数と同一オブジェクトが返る。
    roots[7] = try active.createArray(&.{roots[6]});
    _ = try state.esmPluginBuiltin(active, "無操作", &.{roots[7]});
    try std.testing.expectEqual(roots[6].payload, roots[7].object().?.payload.array.items[0].payload);
    const fn_ret = try state.esmPluginBuiltin(active, "関数返却", &.{roots[6]});
    try std.testing.expectEqual(roots[6].payload, fn_ret.payload);
    _ = try state.esmPluginBuiltin(active, "関数保存", &.{roots[6]});
    const saved_ret = try state.esmPluginBuiltin(active, "保存関数返却", &.{});
    const fn_key = try testString(active, "fn");
    var fn_key_frame = state.RootFrame{};
    var fn_key_roots = [_]Value{ fn_key, saved_ret };
    pushTestRoots(active, &fn_key_frame, &fn_key_roots);
    defer active.popRoots(&fn_key_frame);
    const saved_ret_dict = &fn_key_roots[1].object().?.payload.dictionary;
    const saved_ret_index = saved_ret_dict.findByKey(fn_key_roots[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(roots[6].payload, saved_ret_dict.entries.items[saved_ret_index].value.payload);
    _ = try state.esmPluginBuiltin(active, "保存関数グローバル書込", &.{});
    const saved_global = state.dynamicGlobal(active, "SavedFn") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(roots[6].payload, saved_global.value.payload);
}

fn cbMutateAotContainers(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = &(state.active_runtime orelse return);
    const arr_entry = state.dynamicGlobal(runtime, "CbGlobal") orelse return;
    const arr_val = if (arr_entry.slot) |slot| slot.* else arr_entry.value;
    const arr_obj = arr_val.object() orelse return;
    arr_obj.payload.array.items[0] = state.numberValue(2);
    arr_obj.payload.array.append(runtime.allocator, state.numberValue(3)) catch return;

    const dict_entry = state.dynamicGlobal(runtime, "CbDict") orelse return;
    const dict_val = if (dict_entry.slot) |slot| slot.* else dict_entry.value;
    const dict_obj = dict_val.object() orelse return;
    var key = testString(runtime, "k") catch return;
    var key_frame = state.RootFrame{};
    pushTestRoots(runtime, &key_frame, @ptrCast(&key));
    defer runtime.popRoots(&key_frame);
    runtime.setDictionary(&dict_obj.payload.dictionary, key, state.numberValue(9)) catch return;
    out.* = state.numberValue(1);
}

fn cbSetPTo5(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = &(state.active_runtime orelse return);
    state.upsertDynamicGlobal(runtime, "P", state.numberValue(5)) catch return;
    out.* = state.numberValue(5);
}

fn cbSetPTo20(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = &(state.active_runtime orelse return);
    state.upsertDynamicGlobal(runtime, "P", state.numberValue(20)) catch return;
    out.* = state.numberValue(20);
}

fn cbDetachChildAndCollect(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = &(state.active_runtime orelse return);
    const dynamic_state = runtime.dynamic_state orelse return;
    const dyn_outer = dynamic_state.interpreter.getGlobal("DetachedOuter") orelse return;
    if (dyn_outer == .array and dyn_outer.array.items.items.len > 0) {
        _ = dyn_outer.array.items.pop();
    }
    _ = dynamic_state.value_runtime.collect() catch return;
    _ = runtime.collect();
    out.* = state.numberValue(1);
}

test "compat AOT runtimeはESM plugin内のAOT callback変更とunsupported更新と子コンテナGCを保つ" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    const manifest =
        \\[{"path":"/lnako-compat-test/callback-sync-plugin.mjs","source":"export default { 初期化: function(sys) {}, コールバック実行: { type: 'func', fn: (cb) => cb() }, Cb確認: { type: 'func', fn: (sys) => [sys.__getSysVar('CbGlobal', []).length, sys.__getSysVar('CbGlobal', [])[0], sys.__getSysVar('CbGlobal', [])[1], sys.__getSysVar('CbDict', {}).k] }, P上書: { type: 'func', fn: (sys) => { sys.__setSysVar('P', () => 7); return 0; } }, P上書とCb実行: { type: 'func', fn: (cb, sys) => { sys.__setSysVar('P', () => 7); return cb(); } }, P種別: { type: 'func', fn: (sys) => typeof sys.__getSysVar('P', null) }, P値: { type: 'func', fn: (sys) => sys.__getSysVar('P', null) }, 子コンテナ書換: { type: 'func', fn: (outer, cb) => { const child = outer[0]; cb(); child[0] = 99; return child; } } };","is_plugin":true,"namespaces":[],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);

    var frame = state.RootFrame{};
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);

    // 1) plugin がグローバルコンテナへ触れないまま AOT callback が CbGlobal / CbDict を
    //    更新しても、書き戻しが callback の変更を上書きせず保持する。
    roots[0] = try active.createArray(&.{state.numberValue(1)});
    try state.upsertDynamicGlobal(active, "CbGlobal", roots[0]);
    roots[1] = try active.createDictionary(&.{});
    const k_key = try testString(active, "k");
    var k_frame = state.RootFrame{};
    var k_roots = [_]Value{k_key};
    pushTestRoots(active, &k_frame, &k_roots);
    defer active.popRoots(&k_frame);
    try active.setDictionary(&roots[1].object().?.payload.dictionary, k_roots[0], state.numberValue(1));
    try state.upsertDynamicGlobal(active, "CbDict", roots[1]);

    roots[2] = try active.createNamedFunction(cbMutateAotContainers, 0, "CbMutate", &.{});
    const cb_ret = try state.esmPluginBuiltin(active, "コールバック実行", &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(cb_ret.payload)));
    try std.testing.expectEqual(@as(usize, 2), roots[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(roots[0].object().?.payload.array.items[1].payload)));
    const dict_idx = roots[1].object().?.payload.dictionary.findByKey(k_roots[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(roots[1].object().?.payload.dictionary.entries.items[dict_idx].value.payload)));

    const cb_seen = try state.esmPluginBuiltin(active, "Cb確認", &.{});
    const cb_seen_items = cb_seen.object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 4), cb_seen_items.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(cb_seen_items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(cb_seen_items[1].payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(cb_seen_items[2].payload)));
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(cb_seen_items[3].payload)));

    // 2) plugin が P を AOT 変換不能値 `() => 7` へ書き換えつつ同呼出し内で AOT callback が
    //    P=5 へ更新しても、未同期のまま synced_aot_hashes["P"] を進めないため、次の呼出しで
    //    AOT の最新値 P=5 が plugin へ再同期される。別呼出しでの callback 更新 P=20 も同様。
    const expected_number_kind = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "number");
    defer std.testing.allocator.free(expected_number_kind);
    const expected_fn_kind = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "function");
    defer std.testing.allocator.free(expected_fn_kind);

    try state.upsertDynamicGlobal(active, "P", state.numberValue(1));
    roots[3] = try active.createNamedFunction(cbSetPTo5, 0, "CbSetP5", &.{});
    _ = try state.esmPluginBuiltin(active, "P上書とCb実行", &.{roots[3]});
    const p_kind_after_5 = try state.esmPluginBuiltin(active, "P種別", &.{});
    try std.testing.expectEqualSlices(u16, expected_number_kind, p_kind_after_5.object().?.payload.utf16_string);
    const p_val_after_5 = try state.esmPluginBuiltin(active, "P値", &.{});
    try std.testing.expectEqual(@as(f64, 5), @as(f64, @bitCast(p_val_after_5.payload)));

    try state.upsertDynamicGlobal(active, "P", state.numberValue(10));
    _ = try state.esmPluginBuiltin(active, "P上書", &.{});
    const p_kind_fn = try state.esmPluginBuiltin(active, "P種別", &.{});
    try std.testing.expectEqualSlices(u16, expected_fn_kind, p_kind_fn.object().?.payload.utf16_string);
    roots[4] = try active.createNamedFunction(cbSetPTo20, 0, "CbSetP20", &.{});
    _ = try state.esmPluginBuiltin(active, "コールバック実行", &.{roots[4]});
    const p_kind_after_20 = try state.esmPluginBuiltin(active, "P種別", &.{});
    try std.testing.expectEqualSlices(u16, expected_number_kind, p_kind_after_20.object().?.payload.utf16_string);
    const p_val_after_20 = try state.esmPluginBuiltin(active, "P値", &.{});
    try std.testing.expectEqual(@as(f64, 20), @as(f64, @bitCast(p_val_after_20.payload)));

    // 3) QuickJS callPlugin 実行中の callback が親配列から子配列を切り離して
    //    dynamic value_runtime の GC を実行しても、reverse_pairs が call 前に
    //    root 保護されているため子配列が解放されず安全に書き戻せる。
    const dynamic_state = active.dynamic_state orelse return error.TestUnexpectedResult;
    const dyn_shared = @import("shared.zig").dynamic_value;
    const aot_dynamic = @import("dynamic.zig");
    var dyn_roots = dynamic_state.value_runtime.rootFrame();
    defer dyn_roots.deinit();
    var dyn_outer = try dynamic_state.value_runtime.createArray();
    try dyn_roots.protect(&dyn_outer);
    {
        var dyn_child = try dynamic_state.value_runtime.createArray();
        var tmp_child_root = dynamic_state.value_runtime.rootFrame();
        defer tmp_child_root.deinit();
        try tmp_child_root.protect(&dyn_child);
        _ = try dyn_child.array.push(.{ .number = 10 });
        _ = try dyn_outer.array.push(dyn_child);
    }
    try dynamic_state.interpreter.setGlobalValue("DetachedOuter", dyn_outer);
    roots[5] = try active.createNamedFunction(cbDetachChildAndCollect, 0, "CbDetachChildGC", &.{});
    var dyn_cb = try aot_dynamic.aotToDynamicValue(dynamic_state, roots[5]);
    try dyn_roots.protect(&dyn_cb);
    var call_args = [_]dyn_shared.Value{ dyn_outer, dyn_cb };
    var returned_child = try dynamic_state.interpreter.callExternalCommand("子コンテナ書換", &call_args);
    try dyn_roots.protect(&returned_child);
    try std.testing.expectEqual(dyn_shared.Value.array, std.meta.activeTag(returned_child));
    try std.testing.expectEqual(@as(f64, 99), returned_child.array.items.items[0].number);
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

test "compat AOT runtimeはexternalコンテナ内のBigIntと非externalコンテナ内のJS関数をJS関数実行へ同期する" {
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
    var call_arg_strings: [1]Value = @splat(.{});
    var call_arg_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&call_arg_frame, &call_arg_strings, call_arg_strings.len);
    defer state.active_runtime.?.popRoots(&call_arg_frame);
    call_arg_strings[0] = try testString(&state.active_runtime.?, "o => String(o.n)");
    var call_args = [_]Value{ call_arg_strings[0], roots[0] };
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("1", actual);
    }

    // Nako側でexternalコンテナのBigIntを変更しても `JS関数実行` へ同期される。
    var update_roots: [2]Value = @splat(.{});
    var update_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&update_frame, &update_roots, update_roots.len);
    defer state.active_runtime.?.popRoots(&update_frame);
    update_roots[0] = try testString(&state.active_runtime.?, "n");
    update_roots[1] = try state.active_runtime.?.createBigInt("42");
    try state.active_runtime.?.setDictionary(&roots[0].object().?.payload.dictionary, update_roots[0], update_roots[1]);
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("42", actual);
    }

    // 非externalコンテナの入れ子に置いたJS関数値も、full変換で同じJS参照のまま
    // 渡り、JSから直接呼べる。
    roots[1] = try evalCompatJs(&state.active_runtime.?, "()=>1");
    var wrapped_fn = [_]Value{roots[1]};
    state.lnako_aot_array_new(&roots[2], &wrapped_fn, wrapped_fn.len);
    var wrapped_outer = [_]Value{roots[2]};
    state.lnako_aot_array_new(&roots[2], &wrapped_outer, wrapped_outer.len);
    var nested_fn_strings: [1]Value = @splat(.{});
    var nested_fn_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&nested_fn_frame, &nested_fn_strings, nested_fn_strings.len);
    defer state.active_runtime.?.popRoots(&nested_fn_frame);
    nested_fn_strings[0] = try testString(&state.active_runtime.?, "a => a[0]()");
    var nested_fn_args = [_]Value{ nested_fn_strings[0], roots[2] };
    lnako_aot_compat_js_call(&out, &nested_fn_args, nested_fn_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(out.payload)));

    // external辞書を非external配列の要素に置いても、同じJS参照へ同期される。
    var wrapped_ext = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[2], &wrapped_ext, wrapped_ext.len);
    var nested_ext_strings: [1]Value = @splat(.{});
    var nested_ext_frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&nested_ext_frame, &nested_ext_strings, nested_ext_strings.len);
    defer state.active_runtime.?.popRoots(&nested_ext_frame);
    nested_ext_strings[0] = try testString(&state.active_runtime.?, "o => String(o.n)");
    var nested_ext_args = [_]Value{ nested_ext_strings[0], roots[2] };
    lnako_aot_compat_js_call(&out, &nested_ext_args, nested_ext_args.len);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    {
        const actual = try state.stringUtf8Alloc(&state.active_runtime.?, out);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("42", actual);
    }
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
            // 正常に返却できた登録だけがスロットを1個持つ。JS 側の最後の参照を
            // 落とすと finalizer が同期で解放通知を送る（QuickJS の zero-ref
            // 回収）ため、保持中と解放後を分けて確認する。
            try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
            lnako_qjs_value_free(raw);
            try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
            succeeded = true;
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

test "compat AOT runtimeは孤立サロゲート名・name getter例外の関数戻り値と巨大ByteBuffer上限を扱う" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);

    roots[0] = try callCompatJs(
        &state.active_runtime.?,
        "()=>{const f=()=>7;Object.defineProperty(f,'name',{value:'\\uD800'});return f;}",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.function)), roots[0].tag);

    roots[0] = try callCompatJs(
        &state.active_runtime.?,
        "()=>{const f=()=>8;Object.defineProperty(f,'name',{get(){throw new Error('boom')}});return f;}",
    );
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    var out: Value = .{};
    state.lnako_aot_function_call(&out, &roots[0], null, 0);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(out.payload)));

    const large = try std.testing.allocator.alloc(u8, 1_000_001);
    defer std.testing.allocator.free(large);
    @memset(large, 0);
    roots[1] = try state.active_runtime.?.createByteBuffer(large, .uint8_array);
    var call_args = [_]Value{ try testString(&state.active_runtime.?, "b => b.length"), roots[1] };
    var call_frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &call_frame, &call_args);
    defer state.active_runtime.?.popRoots(&call_frame);
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJsCollectionTooLarge");
}

test "compat AOT runtimeはJS関数実行の巨大配列引数をJS呼出し前に拒否する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);

    const items = try std.testing.allocator.alloc(Value, 1_000_001);
    defer std.testing.allocator.free(items);
    @memset(items, state.numberValue(1));
    state.lnako_aot_array_new(&roots[0], items.ptr, items.len);
    var wrapped = [_]Value{roots[0]};
    state.lnako_aot_array_new(&roots[1], &wrapped, wrapped.len);

    var call_args = [_]Value{
        try testString(&state.active_runtime.?, "a => { globalThis.__lnako_aot_called = 1; return a.length; }"),
        roots[1],
    };
    var call_frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &call_frame, &call_args);
    defer state.active_runtime.?.popRoots(&call_frame);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &call_args, call_args.len);
    try expectPendingFailureContains(&state.active_runtime.?, "QuickJsCollectionTooLarge");

    const called = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_aot_called || 0");
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(called.payload)));
}

/// Issue #278: host 関数インスタンスの解放・参照カウント・世代・teardown と
/// Function 意味論の回帰テスト。
fn constant42Callback(out_value: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out_value.* = state.numberValue(42);
}

fn addOneCallback(out_value: *Value, _: *anyopaque, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out_value.* = .{};
    if (count == 0 or arguments == null) return;
    const argument = arguments.?[0];
    if (@as(Tag, @fromBackingInt(argument.tag)) != .number) return;
    out_value.* = state.numberValue(@as(f64, @bitCast(argument.payload)) + 1);
}

test "compat AOT runtimeはhost関数の最後のJS参照で登録を解放しcaptureを回収する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    const engine_value = try ensureEngine();

    const captured = try testString(&state.active_runtime.?, "captured");
    var items = [_]Value{captured};
    roots[0] = try state.active_runtime.?.createArray(&items);
    roots[1] = try state.active_runtime.?.createNamedFunction(constant42Callback, 1, "callback", &.{roots[0]});
    const objects_with_capture = state.active_runtime.?.object_count;

    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[1]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[1]));
    // JS 側の最後の参照を落とすと finalizer が登録を解放する。
    lnako_qjs_value_free(raw);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 0), compat.hostFunctionInstanceCount(roots[1]));

    // host 関数テーブルが mark しなくなったので、Nako GC はクロージャと
    // capture（配列・文字列）を回収できる。
    roots[0] = .{};
    roots[1] = .{};
    _ = state.active_runtime.?.collect();
    try std.testing.expect(state.active_runtime.?.object_count < objects_with_capture);
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.object_count);
}

test "compat AOT runtimeはhost関数の複数JSインスタンスを参照カウントする" {
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
    const engine_value = try ensureEngine();
    roots[0] = try state.active_runtime.?.createNamedFunction(constant42Callback, 1, "callback", &.{});

    const first = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    const second = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 2), compat.hostFunctionInstanceCount(roots[0]));

    // 1個だけ解放してもスロットは生存し、残った JS 関数は呼べる。
    lnako_qjs_value_free(first);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[0]));
    const result = lnako_qjs_call(engine_value, second, null, 0) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(result);
    const converted = try compat.primitiveFromRaw(&state.active_runtime.?, result);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(converted.payload)));

    // すべて解放するとスロットが消える。
    lnako_qjs_value_free(second);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
}

test "compat AOT runtimeはhost関数スロットを新世代で再利用し古いIDを拒否する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    const engine_value = try ensureEngine();
    roots[0] = try state.active_runtime.?.createNamedFunction(constant42Callback, 1, "first", &.{});
    roots[1] = try state.active_runtime.?.createNamedFunction(constant42Callback, 1, "second", &.{});

    const raw_first = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    const first_handle = compat.hostFunctionHandle(roots[0]) orelse return error.TestUnexpectedResult;
    lnako_qjs_value_free(raw_first);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());

    const raw_second = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[1]);
    defer lnako_qjs_value_free(raw_second);
    const second_handle = compat.hostFunctionHandle(roots[1]) orelse return error.TestUnexpectedResult;
    // 解放された index を再利用し、世代は単調に進む。
    try std.testing.expectEqual(first_handle.index, second_handle.index);
    try std.testing.expect(second_handle.generation > first_handle.generation);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // 古い (index, generation) で作った JS 関数は新しいエントリを呼べない。
    const stale = lnako_qjs_host_function(engine_value, first_handle.index, first_handle.generation, "stale") orelse
        return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(stale);
    const stale_result = lnako_qjs_call(engine_value, stale, null, 0);
    try std.testing.expect(stale_result == null);
    const message = lnako_qjs_take_error(engine_value) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_free_string(message);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(message), "InternalError") != null);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // 新しい関数はそのまま呼べる。
    const result = lnako_qjs_call(engine_value, raw_second, null, 0) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(result);
    const converted = try compat.primitiveFromRaw(&state.active_runtime.?, result);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(converted.payload)));
}

test "compat AOT runtimeはhost関数のFunction意味論を維持する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    const engine_value = try ensureEngine();
    roots[0] = try state.active_runtime.?.createMethodFunction(addOneCallback, 1, "callback", &.{});

    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    // `JS_NewCFunctionData` 版と同じく JS の function として観測される。
    try std.testing.expectEqual(compat.Kind.function, compat.lnako_qjs_kind(raw));
    // globalThis へ載せて raw を手放しても JS 側の参照を維持する。
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_semantics_f", raw) > 0);
    lnako_qjs_value_free(raw);

    const source =
        "[" ++
        "typeof __lnako_semantics_f," ++
        " __lnako_semantics_f instanceof Function," ++
        " __lnako_semantics_f.name," ++
        " __lnako_semantics_f.length," ++
        " __lnako_semantics_f(41)," ++
        " __lnako_semantics_f.call(null, 41)," ++
        " __lnako_semantics_f.apply(null, [41])," ++
        " __lnako_semantics_f.bind(null, 41)()," ++
        " __lnako_semantics_f.constructor === Function" ++
        "].join(',')";
    roots[1] = try evalCompatJs(&state.active_runtime.?, source);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, roots[1]);
    defer std.testing.allocator.free(units);
    const expected = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "function,true,callback,0,42,42,42,42,true");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u16, expected, units);
}

test "compat AOT runtimeはhost関数を残したままdeinitを先に呼んでも安全に終了する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    state.active_runtime = runtime;
    defer {
        if (state.active_runtime != null) {
            runtime = state.active_runtime.?;
            state.active_runtime = null;
        }
    }
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    const engine_value = try ensureEngine();
    roots[0] = try state.active_runtime.?.createFunction(constant42Callback, 1, &.{});
    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // 未解放の JS 関数オブジェクトを残したまま compat deinit → runtime deinit。
    lnako_aot_compat_deinit();
    try std.testing.expect(compat.activeEngine() == null);
    state.active_runtime.?.popRoots(&frame);
    runtime = state.active_runtime.?;
    state.active_runtime = null;
    runtime.deinit();
    // engine は wrapper が保持している。finalizer は解除済みの通知を呼ばない。
    lnako_qjs_value_free(raw);
}

test "compat AOT runtimeはhost関数を残したままruntime deinitを先に呼んでも安全に終了する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    state.active_runtime = runtime;
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    const engine_value = try ensureEngine();
    roots[0] = try state.active_runtime.?.createFunction(constant42Callback, 1, &.{});
    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // runtime.deinit が先。compat_deinit が通知とテーブルを解除する。
    state.active_runtime.?.popRoots(&frame);
    runtime = state.active_runtime.?;
    state.active_runtime = null;
    runtime.deinit();
    lnako_qjs_value_free(raw);
    lnako_aot_compat_deinit();
    try std.testing.expect(compat.activeEngine() == null);
}

fn cycleCallback(out_value: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const object: *state.Object = @ptrCast(@alignCast(context));
    out_value.* = .{};
    if (object.payload.function.captures.len == 0) return;
    var captured = object.payload.function.captures[0];
    state.lnako_aot_function_call(out_value, &captured, null, 0);
}

test "compat AOT runtimeはJSとNakoの循環参照をteardownまで保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    // Nako クロージャが JS 値（external binding）を capture し、JS 側がその
    // Nako callback を global で保持する循環。Nako GC は JS→Nako 辺を見ない
    // ため、host 関数テーブルが closure を root し続ける間はどちらも回収
    // しない（クロス GC の cycle collector は持たない）。JS 側の参照を落とす
    // と finalizer → 登録解除 → Nako GC の順で回収できる。
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
    const engine_value = try ensureEngine();

    roots[0] = try evalCompatJs(&state.active_runtime.?, "()=>7");
    roots[1] = try state.active_runtime.?.createFunction(cycleCallback, 0, &.{roots[0]});
    roots[2] = try evalCompatJs(&state.active_runtime.?, "(cb)=>{globalThis.__lnako_cycle_cb=cb;return 0;}");
    arguments[0] = roots[2];
    arguments[1] = roots[1];
    state.lnako_aot_function_call(&out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // Nako 側の root を落としても host テーブルが closure を mark し続ける。
    roots[0] = .{};
    roots[1] = .{};
    roots[2] = .{};
    var iteration: usize = 0;
    while (iteration < 4) : (iteration += 1) _ = state.active_runtime.?.collect();
    try std.testing.expect(compat.registeredHostFunctionCount() == 1);
    const retained = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_cycle_cb()");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(retained.payload)));

    // JS 側の参照を落とすと finalizer が登録を解除し、次の Nako GC で
    // closure・capture・external JS 値が回収される。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_cycle_cb = null; 0");
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.object_count);
}

// Issue #278 レビュー指摘: JS 自己循環内の callback は参照カウントゼロでは
// 解放されず、QuickJS GC でのみ finalizer が走る。
test "compat AOT runtimeはJS自己循環内のcallbackをQuickJS GCでのみ解放する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    const engine_value = try ensureEngine();

    const captured = try testString(&state.active_runtime.?, "self-cycle-captured");
    var items = [_]Value{captured};
    roots[0] = try state.active_runtime.?.createArray(&items);
    roots[1] = try state.active_runtime.?.createNamedFunction(constant42Callback, 1, "callback", &.{roots[0]});
    const objects_with_capture = state.active_runtime.?.object_count;

    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[1]);
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_self_cycle_cb", raw) > 0);
    lnako_qjs_value_free(raw);
    // JS 側で自己循環を作り、wrapper と global の外部参照をすべて落とす。
    const setup_source =
        "{ const box = { cb: globalThis.__lnako_self_cycle_cb };" ++
        " box.self = box;" ++
        " globalThis.__lnako_self_cycle_cb = null;" ++
        " 0 }";
    const setup = lnako_qjs_eval(engine_value, setup_source.ptr, setup_source.len, "<self-cycle>") orelse
        return error.TestUnexpectedResult;
    lnako_qjs_value_free(setup);

    // 参照カウントゼロ解放ではなく、自己循環が残っている間は生存する。
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[1]));
    roots[0] = .{};
    roots[1] = .{};
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    // QuickJS GC で自己循環が回収され、finalizer が登録を解除する。
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
    _ = state.active_runtime.?.collect();
    try std.testing.expect(state.active_runtime.?.object_count < objects_with_capture);
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.object_count);
}

// Issue #278 レビュー指摘: 2個目の生成が Zig 割当てで失敗しても、先予約
// acquire の rollback が既存インスタンスとスロットを壊さない。
test "compat AOT runtimeは新インスタンス生成失敗で既存インスタンスを保護する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
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
    const engine_value = try ensureEngine();
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    roots[0] = try state.active_runtime.?.createFunction(constant42Callback, 0, &.{});

    const first = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[0]));

    var saw_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        failing.alloc_index = 0;
        failing.fail_index = fail_index;
        const second = compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
        if (second) |raw| {
            lnako_qjs_value_free(raw);
        } else |failure| {
            saw_failure = true;
            try std.testing.expectEqual(error.OutOfMemory, failure);
        }
        // 失敗しても既存インスタンスとスロットは維持される。
        try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
        try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[0]));
    }
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(saw_failure);

    // 既存インスタンスはそのまま呼べる。
    const result = lnako_qjs_call(engine_value, first, null, 0) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(result);
    const converted = try compat.primitiveFromRaw(&state.active_runtime.?, result);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(converted.payload)));
    lnako_qjs_value_free(first);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
}

// Issue #278 レビュー指摘: 管理外 engine への登録を拒否し、既存テーブルと
// 別 engine の teardown に影響を与えない。
test "compat AOT runtimeは不一致engineのhostFunctionを拒否する" {
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
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    roots[0] = try state.active_runtime.?.createFunction(constant42Callback, 0, &.{});

    const foreign = compat.lnako_qjs_new() orelse return error.TestUnexpectedResult;
    defer compat.lnako_qjs_release(foreign);
    try std.testing.expectError(
        error.QuickJsHostUnavailable,
        compat.hostFunction(&state.active_runtime.?, foreign, roots[0]),
    );
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());

    // 既存 engine の登録は影響を受けない。
    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    lnako_qjs_value_free(raw);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
}

// Issue #278 レビュー指摘: engine 生成・破棄を繰り返してもプロセス共通の
// class ID を消費し尽くさない。
test "compat AOT runtimeは複数engineの生成破棄を繰り返してもclass IDを枯渇させない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        const created = compat.lnako_qjs_new() orelse return error.TestUnexpectedResult;
        compat.lnako_qjs_release(created);
    }

    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const engine_value = try ensureEngine();
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    roots[0] = try state.active_runtime.?.createFunction(constant42Callback, 0, &.{});
    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    lnako_qjs_value_free(raw);
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
}

// Issue #278 レビュー指摘: `globalThis.Function` を壊しても、生成した host
// 関数は intrinsic な `Function.prototype` を継承し、call/apply/bind が壊れない。
test "compat AOT runtimeはglobalThis.Function改変下でもhost関数の意味論を維持する" {
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
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);
    const engine_value = try ensureEngine();

    const break_source = "globalThis.Function = 0; 0";
    const broken = lnako_qjs_eval(engine_value, break_source.ptr, break_source.len, "<break-function>") orelse
        return error.TestUnexpectedResult;
    lnako_qjs_value_free(broken);

    roots[0] = try state.active_runtime.?.createMethodFunction(addOneCallback, 1, "callback", &.{});
    const raw = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_broken_f", raw) > 0);
    lnako_qjs_value_free(raw);

    const source =
        "[" ++
        "typeof __lnako_broken_f," ++
        " typeof __lnako_broken_f.call," ++
        " typeof __lnako_broken_f.apply," ++
        " typeof __lnako_broken_f.bind," ++
        " __lnako_broken_f.name," ++
        " __lnako_broken_f(41)," ++
        " __lnako_broken_f.call(null, 41)," ++
        " __lnako_broken_f.apply(null, [41])," ++
        " __lnako_broken_f.bind(null, 41)()" ++
        "].join(',')";
    roots[1] = try evalCompatJs(&state.active_runtime.?, source);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, roots[1]);
    defer std.testing.allocator.free(units);
    const expected = try std.unicode.utf8ToUtf16LeAlloc(
        std.testing.allocator,
        "function,function,function,function,callback,42,42,42,42",
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u16, expected, units);
}

fn cycleBoxCallback(out_value: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out_value.* = state.numberValue(7);
}

// 真のクロス GC 循環（Nako closure → capture(external box) → box.cb →
// host_functions → Nako closure）を作る。Nako 側が external binding を保持する
// 限り QuickJS は box を回収できないため、循環は teardown まで保持される。
fn setupTrueCrossGcCycle(runtime: *state.Runtime, roots: []Value, arguments: []Value, out: *Value) !*compat.Engine {
    const engine_value = try ensureEngine();
    // Nako closure が JS オブジェクト box を capture する。
    roots[0] = try evalCompatJs(runtime, "({v:7})");
    roots[1] = try runtime.createFunction(cycleBoxCallback, 0, &.{roots[0]});
    const raw = try compat.hostFunction(runtime, engine_value, roots[1]);
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_cycle_cb", raw) > 0);
    lnako_qjs_value_free(raw);
    // box を JS global に載せる。この時点の box は cb を持たないため、呼出し後の
    // refresh が Nako 側へ cb を作ることはない。
    roots[2] = try evalCompatJs(runtime, "(box)=>{globalThis.__lnako_cycle_box=box; return 0;}");
    arguments[0] = roots[2];
    arguments[1] = roots[0];
    state.lnako_aot_function_call(out, &arguments[0], arguments[1..].ptr, 1);
    try std.testing.expect(!runtime.has_pending_exception);
    // Nako 引数を渡さずに box.cb へ host 関数を格納する（refresh を避け、
    // Nako 側に cb の external binding を作らない）。
    roots[2] = try evalCompatJs(
        runtime,
        "globalThis.__lnako_cycle_box.cb = globalThis.__lnako_cycle_cb;" ++
            " globalThis.__lnako_cycle_cb = null; 0",
    );
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    return engine_value;
}

test "compat AOT runtimeは真のクロスGC循環をteardownまで保持する" {
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
    const engine_value = try setupTrueCrossGcCycle(&state.active_runtime.?, &roots, &arguments, &out);

    // Nako 側の root を落としても host テーブルが closure を mark し続ける。
    roots[0] = .{};
    roots[1] = .{};
    roots[2] = .{};
    var iteration: usize = 0;
    while (iteration < 4) : (iteration += 1) _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    // JS から到達可能な間は box.cb() を呼べる。
    const retained = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_cycle_box.cb()");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(retained.payload)));

    // JS global から落として QuickJS GC しても、Nako の external binding が
    // box を保持しているため循環は生き続ける（クロス GC cycle collector なし）。
    roots[0] = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_cycle_box = null; 0");
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    // 循環を残したまま teardown しても、defer の runtime.deinit と
    // lnako_aot_compat_deinit がリーク・クラッシュなく解放する。
}

test "compat AOT runtimeはクロスGC循環の辺を切ると実行中に回収する" {
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
    const engine_value = try setupTrueCrossGcCycle(&state.active_runtime.?, &roots, &arguments, &out);

    // JS→Nako 辺（box.cb）と JS global を落として循環を切る。
    roots[0] = try evalCompatJs(
        &state.active_runtime.?,
        "globalThis.__lnako_cycle_box.cb = null; globalThis.__lnako_cycle_box = null; 0",
    );
    lnako_qjs_run_gc(engine_value);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());
    // Nako GC で closure と capture（external box）が回収される。
    roots[0] = .{};
    roots[1] = .{};
    _ = state.active_runtime.?.collect();
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.object_count);
}

// Issue #278 再レビュー指摘: C 側の関数名文字列生成（JS_NewString）が OOM で
// 失敗した場合に、例外を name に格納した半端な wrapper を返さず失敗し、
// 先予約した参照カウントもロールバックして既存インスタンスを保護する。
test "compat AOT runtimeはhostFunctionのJS側名前割当てOOM時に失敗し既存インスタンスを保護する" {
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

    const large_name = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large_name);
    @memset(large_name, 'a');

    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(&state.active_runtime.?, &frame, &roots);
    defer state.active_runtime.?.popRoots(&frame);

    roots[0] = try state.active_runtime.?.createNamedFunction(constant42Callback, 0, large_name, &.{});
    roots[1] = try state.active_runtime.?.createNamedFunction(constant42Callback, 0, large_name, &.{});

    const existing = try compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]);
    defer lnako_qjs_value_free(existing);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[0]));

    compat.lnako_qjs_set_memory_limit(engine_value, 256 * 1024);
    defer compat.lnako_qjs_set_memory_limit(engine_value, std.math.maxInt(usize));

    try std.testing.expectError(error.OutOfMemory, compat.hostFunction(&state.active_runtime.?, engine_value, roots[0]));
    if (compat.lnako_qjs_take_error(engine_value)) |err_text| compat.lnako_qjs_free_string(err_text);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), compat.hostFunctionInstanceCount(roots[0]));

    try std.testing.expectError(error.OutOfMemory, compat.hostFunction(&state.active_runtime.?, engine_value, roots[1]));
    if (compat.lnako_qjs_take_error(engine_value)) |err_text| compat.lnako_qjs_free_string(err_text);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 0), compat.hostFunctionInstanceCount(roots[1]));

    compat.lnako_qjs_set_memory_limit(engine_value, std.math.maxInt(usize));
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_oom_existing", existing) > 0);
    roots[0] = try evalCompatJs(&state.active_runtime.?, "globalThis.__lnako_oom_existing()");
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(roots[0].payload)));
}

// ---------------------------------------------------------------------------
// Issue #55 Unit 3: QuickJS ホスト変数bridge（`sys.__getSysVar` /
// `sys.__findVar` / `sys.__setSysVar` / `sys.__getSore` / `sys.__setSore`）。
//
// C bridge の `host_get_common` は第2引数がある場合だけ既定値を返すため、
// 既定値あり／なしの両方を評価して、返却値とフォールバック規則を固定する。
// ---------------------------------------------------------------------------

/// `sys.__setSysVar` / `sys.__findVar` 等を含む式を QuickJS で評価し、
/// `JS実行` と同じ full 変換で Nako 値へ戻す（JS 側の例外文言も検査できる）。
fn evalQuickJsValue(runtime: *state.Runtime, source: []const u8) !Value {
    const engine_value = try ensureEngine();
    const raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<test>") orelse {
        if (lnako_qjs_take_error(engine_value)) |text| {
            defer lnako_qjs_free_string(text);
            std.debug.print("QuickJS eval failed: {s}\n", .{std.mem.span(text)});
        }
        return error.QuickJsEvalFailed;
    };
    return compat_result.jsEvalResult(runtime, raw);
}

fn expectQuickJsString(runtime: *state.Runtime, source: []const u8, expected: []const u8) !void {
    const value = try evalQuickJsValue(runtime, source);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), roots[0].tag);
    const units = try state.valueUtf16Alloc(runtime, roots[0]);
    defer runtime.allocator.free(units);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(runtime.allocator, units);
    defer runtime.allocator.free(utf8);
    try std.testing.expectEqualStrings(expected, utf8);
}

fn expectQuickJsNumber(runtime: *state.Runtime, source: []const u8, expected: f64) !void {
    const value = try evalQuickJsValue(runtime, source);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), roots[0].tag);
    try std.testing.expectEqual(expected, @as(f64, @bitCast(roots[0].payload)));
}

fn expectQuickJsBoolean(runtime: *state.Runtime, source: []const u8, expected: bool) !void {
    const value = try evalQuickJsValue(runtime, source);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.boolean)), roots[0].tag);
    try std.testing.expectEqual(@intFromBool(expected), roots[0].payload);
}

fn expectQuickJsNull(runtime: *state.Runtime, source: []const u8) !void {
    const value = try evalQuickJsValue(runtime, source);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.null_value)), roots[0].tag);
}

fn expectQuickJsUndefined(runtime: *state.Runtime, source: []const u8) !void {
    const value = try evalQuickJsValue(runtime, source);
    var roots = [_]Value{value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expect(!roots[0].isUnbound());
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), roots[0].tag);
    try std.testing.expectEqual(@as(u64, 0), roots[0].payload);
}

test "compat AOT runtimeはsys.__getSysVarを完全一致とシステム定数で解決する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    _ = try ensureEngine();

    // 完全一致は接尾辞より優先し、`__getSysVar` は接尾辞を解決しない
    // （interpreter の `effects.getGlobal` と同じ）。
    try state.upsertDynamicGlobal(active, "完全一致", state.numberValue(5));
    try state.upsertDynamicGlobal(active, "mod__接尾辞", state.numberValue(4));
    try expectQuickJsNumber(active, "sys.__getSysVar('完全一致','miss')", 5);
    try expectQuickJsString(active, "sys.__getSysVar('接尾辞','miss')", "miss");
    try expectQuickJsNumber(active, "sys.__getSysVar('mod__接尾辞','miss')", 4);

    // falsy も既定値へ落とさず、そのまま返す（`__findVar` との差）。
    try state.upsertDynamicGlobal(active, "ゼロ", state.numberValue(0));
    try state.upsertDynamicGlobal(active, "偽", .{ .tag = @backingInt(Tag.boolean), .payload = 0 });
    try state.upsertDynamicGlobal(active, "空文字", try testString(active, ""));
    try state.upsertDynamicGlobal(active, "ヌル", .{ .tag = @backingInt(Tag.null_value) });
    try expectQuickJsNumber(active, "sys.__getSysVar('ゼロ','miss')", 0);
    try expectQuickJsBoolean(active, "sys.__getSysVar('偽','miss')", false);
    try expectQuickJsString(active, "sys.__getSysVar('空文字','miss')", "");
    try expectQuickJsNull(active, "sys.__getSysVar('ヌル','miss')");

    // 完全一致が未束縛ならシステム定数へフォールバックする。
    try state.upsertDynamicGlobal(active, "未束縛", Value.unboundValue());
    try expectQuickJsString(active, "sys.__getSysVar('未束縛','miss')", "miss");
    try expectQuickJsString(active, "sys.__getSysVar('undefined','miss')", "miss");
    try expectQuickJsNumber(active, "sys.__getSysVar('PI','miss')", std.math.pi);
    try expectQuickJsString(active, "sys.__getSysVar('ナデシコバージョン')", "3.7.24");
    // システム定数の null は undefined ではないため既定値へ落ちない。
    try expectQuickJsNull(active, "sys.__getSysVar('AJAX:ONERROR','miss')");
    try expectQuickJsString(active, "sys.__getSysVar('存在しない','miss')", "miss");
    try expectQuickJsUndefined(active, "sys.__getSysVar('存在しない')");

    // ローカル変数は `__getSysVar` では解決しない（`__findVar` は解決する）。
    var storage = [_]Value{state.numberValue(42)};
    var storage_frame: state.RootFrame = .{};
    active.pushRoots(&storage_frame, &storage, storage.len);
    defer active.popRoots(&storage_frame);
    var entries = [_]state.AotVarEntry{.{ .name_ptr = "局所".ptr, .name_len = "局所".len }};
    var slots = [_]*const Value{&storage[0]};
    var frame: state.AotVarFrame = .{};
    active.pushVarFrame(&frame, &entries, entries.len, &slots);
    defer active.popVarFrame(&frame);
    try expectQuickJsString(active, "sys.__getSysVar('局所','miss')", "miss");
    try expectQuickJsNumber(active, "sys.__findVar('局所',0)", 42);

    // 曖昧なモジュールサフィックスは既定値へ落ち、AOT例外を残さない。
    try state.upsertDynamicGlobal(active, "modA__重複", state.numberValue(1));
    try state.upsertDynamicGlobal(active, "modB__重複", state.numberValue(2));
    try expectQuickJsString(active, "sys.__findVar('重複','fallback')", "fallback");
    try expectQuickJsString(active, "sys.__getSysVar('重複','miss')", "miss");
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__findVarをローカル・グローバル・関数・定数で解決する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    _ = try ensureEngine();

    // 動的グローバルの完全一致と `{module}__{name}` サフィックス。
    try state.upsertDynamicGlobal(active, "完全一致", state.numberValue(3));
    try state.upsertDynamicGlobal(active, "modA__接尾辞", state.numberValue(4));
    try expectQuickJsNumber(active, "sys.__findVar('完全一致',0)", 3);
    try expectQuickJsNumber(active, "sys.__findVar('接尾辞',0)", 4);

    // ローカルフレーム（内側優先・未束縛フォールバック・BindingCell）。
    var storage = [_]Value{
        state.numberValue(1), // outer 共有
        state.numberValue(2), // inner 共有
        Value.unboundValue(), // inner 未束縛
        state.numberValue(7), // outer 未束縛
        .{}, // inner セル
    };
    var storage_frame: state.RootFrame = .{};
    active.pushRoots(&storage_frame, &storage, storage.len);
    defer active.popRoots(&storage_frame);
    storage[4] = try active.createBindingCell(state.numberValue(42));
    var outer_entries = [_]state.AotVarEntry{
        .{ .name_ptr = "共有".ptr, .name_len = "共有".len },
        .{ .name_ptr = "未束縛".ptr, .name_len = "未束縛".len },
    };
    var outer_slots = [_]*const Value{ &storage[0], &storage[3] };
    var inner_entries = [_]state.AotVarEntry{
        .{ .name_ptr = "共有".ptr, .name_len = "共有".len },
        .{ .name_ptr = "未束縛".ptr, .name_len = "未束縛".len },
        .{ .name_ptr = "セル".ptr, .name_len = "セル".len },
    };
    var inner_slots = [_]*const Value{ &storage[1], &storage[2], &storage[4] };
    var outer_frame: state.AotVarFrame = .{};
    var inner_frame: state.AotVarFrame = .{};
    active.pushVarFrame(&outer_frame, &outer_entries, outer_entries.len, &outer_slots);
    defer active.popVarFrame(&outer_frame);
    active.pushVarFrame(&inner_frame, &inner_entries, inner_entries.len, &inner_slots);
    defer active.popVarFrame(&inner_frame);
    try expectQuickJsNumber(active, "sys.__findVar('共有',0)", 2);
    try expectQuickJsNumber(active, "sys.__findVar('未束縛',0)", 7);
    try expectQuickJsNumber(active, "sys.__findVar('セル',0)", 42);

    // 名前付き関数は JS 関数として取得・呼出しできる。
    var function_storage = [_]Value{try active.createNamedFunction(doubleFunction, 1, "F", &.{})};
    var function_frame: state.RootFrame = .{};
    active.pushRoots(&function_frame, &function_storage, function_storage.len);
    defer active.popRoots(&function_frame);
    try expectQuickJsString(active, "typeof sys.__findVar('F',null)", "function");
    try expectQuickJsNumber(active, "sys.__findVar('F',null)(4)", 8);

    // 真値のシステム定数はそのまま、falsy は既定値へ落ちる。
    try expectQuickJsNumber(active, "sys.__findVar('PI','miss')", std.math.pi);
    try expectQuickJsString(active, "sys.__findVar('ナデシコ種類','miss')", "cnako3");
    try expectQuickJsString(active, "sys.__findVar('AJAX:ONERROR','miss')", "miss");
    try expectQuickJsString(active, "sys.__findVar('未定義','miss')", "miss");

    // falsy な動的グローバルは既定値へ落ちる（公式の truthiness 判定）。
    try state.upsertDynamicGlobal(active, "ゼロ", state.numberValue(0));
    try state.upsertDynamicGlobal(active, "偽", .{ .tag = @backingInt(Tag.boolean), .payload = 0 });
    try state.upsertDynamicGlobal(active, "空文字", try testString(active, ""));
    try state.upsertDynamicGlobal(active, "ヌル", .{ .tag = @backingInt(Tag.null_value) });
    try state.upsertDynamicGlobal(active, "未定義値", .{});
    try state.upsertDynamicGlobal(active, "空配列", try active.createArray(&.{}));
    try expectQuickJsString(active, "sys.__findVar('ゼロ','d')", "d");
    try expectQuickJsString(active, "sys.__findVar('偽','d')", "d");
    try expectQuickJsString(active, "sys.__findVar('空文字','d')", "d");
    try expectQuickJsString(active, "sys.__findVar('ヌル','d')", "d");
    try expectQuickJsString(active, "sys.__findVar('未定義値','d')", "d");
    try expectQuickJsUndefined(active, "sys.__findVar('ゼロ')");
    // 配列は truthy なので真値として返る。
    try expectQuickJsBoolean(active, "Array.isArray(sys.__findVar('空配列',null))", true);
    try expectQuickJsString(active, "sys.__findVar('存在しない','fallback')", "fallback");
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__setSysVarで動的グローバルを更新する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    _ = try ensureEngine();

    // 新規エントリは slot を持たず、entry.value が正本になる。
    try expectQuickJsNumber(active, "sys.__setSysVar('新規', 7); sys.__getSysVar('新規')", 7);
    const created = state.dynamicGlobal(active, "新規") orelse return error.TestUnexpectedResult;
    try std.testing.expect(created.slot == null);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), created.value.tag);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(created.value.payload)));

    // `@lnako.global` 相当の slot 付きエントリは slot だけを更新し、
    // entry.value は未束縛のまま（古い値のGCルート滞留を避ける）。
    var slot = [_]Value{state.numberValue(1)};
    var slot_frame: state.RootFrame = .{};
    active.pushRoots(&slot_frame, &slot, slot.len);
    defer active.popRoots(&slot_frame);
    state.lnako_aot_dynamic_global_register("静的".ptr, "静的".len, &slot[0]);
    try std.testing.expect(!active.has_pending_exception);
    try expectQuickJsNumber(active, "sys.__setSysVar('静的', 9); sys.__getSysVar('静的')", 9);
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(slot[0].payload)));
    const static_entry = state.dynamicGlobal(active, "静的") orelse return error.TestUnexpectedResult;
    try std.testing.expect(static_entry.slot != null);
    try std.testing.expect(!static_entry.value.isUnbound());
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), static_entry.value.tag);
    try std.testing.expectEqual(@as(u64, 0), static_entry.value.payload);

    // slot から外れた旧オブジェクトは次の GC で回収される。
    slot[0] = try active.createArray(&.{});
    const before_collect = active.object_count;
    try expectQuickJsNumber(active, "sys.__setSysVar('静的', 10); sys.__getSysVar('静的')", 10);
    _ = active.collect();
    try std.testing.expect(active.object_count < before_collect);

    // JS のオブジェクト・配列・関数・BigInt を型を保って往復する。
    try expectQuickJsNumber(active, "sys.__setSysVar('オブ', {a: 41}); sys.__findVar('オブ').a + 1", 42);
    try expectQuickJsString(active, "sys.__setSysVar('配', [1,2]); sys.__findVar('配').length + ',' + sys.__getSysVar('配')[1]", "2,2");
    try expectQuickJsString(active, "sys.__setSysVar('関', (x) => x * 3); typeof sys.__getSysVar('関') + ',' + sys.__getSysVar('関')(3)", "function,9");
    try expectQuickJsString(active, "sys.__setSysVar('大', 123n); typeof sys.__getSysVar('大') + ':' + sys.__getSysVar('大').toString()", "bigint:123");

    // 変換に失敗する値は JS の InternalError になり、AOT runtime を壊さない。
    try expectQuickJsString(
        active,
        "try { sys.__setSysVar('失敗', {get a(){ throw new Error('boom'); }}); 'no-throw' } catch (error) { error.name }",
        "InternalError",
    );
    try std.testing.expect(!active.has_pending_exception);
    try expectQuickJsNumber(active, "sys.__setSysVar('回復', 1); sys.__getSysVar('回復')", 1);

    // 同期変換できない Promise/iterator を保持するグローバルは、例外を残さず
    // 既定値へ落ちる（`__getSysVar` は完全一致、`__findVar` は truthy の後で
    // 変換に失敗する）。
    var special_storage = [_]Value{
        try state.createAotPromise(active),
        try active.createIterator(&.{state.numberValue(1)}, false, 0, false),
    };
    var special_frame: state.RootFrame = .{};
    active.pushRoots(&special_frame, &special_storage, special_storage.len);
    defer active.popRoots(&special_frame);
    try state.upsertDynamicGlobal(active, "約束", special_storage[0]);
    try state.upsertDynamicGlobal(active, "反復子", special_storage[1]);
    try expectQuickJsString(active, "sys.__getSysVar('約束','miss')", "miss");
    try expectQuickJsString(active, "sys.__getSysVar('反復子','miss')", "miss");
    try expectQuickJsString(active, "sys.__findVar('約束','miss')", "miss");
    try expectQuickJsString(active, "sys.__findVar('反復子','miss')", "miss");
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__setSoreとsys.__getSoreをNakoのそれへ接続する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    _ = try ensureEngine();

    var slot = [_]Value{state.numberValue(1)};
    var slot_frame: state.RootFrame = .{};
    active.pushRoots(&slot_frame, &slot, slot.len);
    defer active.popRoots(&slot_frame);
    state.lnako_aot_dynamic_global_register("それ".ptr, "それ".len, &slot[0]);

    try expectQuickJsNumber(active, "sys.__setSore(77); sys.__getSore()", 77);
    try std.testing.expectEqual(@as(f64, 77), @as(f64, @bitCast(slot[0].payload)));
    try expectQuickJsString(active, "sys.__setSore('それ文字列'); sys.__getSore()", "それ文字列");
    try std.testing.expect(!active.has_pending_exception);
}

fn evalQuickJsOnEngine(runtime: *state.Runtime, engine_value: *compat.Engine, source: []const u8) !Value {
    const raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<test>") orelse {
        if (lnako_qjs_take_error(engine_value)) |text| {
            defer lnako_qjs_free_string(text);
            std.debug.print("QuickJS eval failed: {s}\n", .{std.mem.span(text)});
        }
        return error.QuickJsEvalFailed;
    };
    return compat_result.jsEvalResult(runtime, raw);
}

test "compat AOT runtimeはcompatDeinitでhost変数bridgeを遮断する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    const engine_value = try ensureEngine();
    try state.upsertDynamicGlobal(active, "X", state.numberValue(5));
    try expectQuickJsNumber(active, "sys.__getSysVar('X','miss')", 5);

    compat.compatDeinit(active);
    // C 側の host_get / host_set が NULL に戻り、同じ runtime の値でも
    // bridge は既定値へ落ちる（ensureEngine を呼ばず既存 engine で確認する）。
    const detached_get = try evalQuickJsOnEngine(active, engine_value, "sys.__getSysVar('X','miss')");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), detached_get.tag);
    const detached_find = try evalQuickJsOnEngine(active, engine_value, "sys.__findVar('X','miss')");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), detached_find.tag);
    const detached_set = try evalQuickJsOnEngine(active, engine_value, "sys.__setSysVar('Y', 1)");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), detached_set.tag);
    try std.testing.expect(!active.has_pending_exception);

    // engine を残したまま次の runtime / 再接続で ensureEngine() を呼ぶと、
    // 既存 engine に対しても host コールバックと GC hook が再バインドされる。
    try std.testing.expect(compat.activeEngine() != null);
    var func_roots = [_]Value{try active.createNamedFunction(doubleFunction, 1, "F_rebind", &.{})};
    var func_frame: state.RootFrame = .{};
    pushTestRoots(active, &func_frame, &func_roots);
    defer active.popRoots(&func_frame);
    _ = try ensureEngine();
    try std.testing.expect(active.compat_trace != null);
    try std.testing.expect(active.compat_deinit != null);
    try expectQuickJsNumber(active, "sys.__getSysVar('X','miss')", 5);
    try expectQuickJsNumber(active, "sys.__setSysVar('Y', 12); sys.__getSysVar('Y','miss')", 12);
    try expectQuickJsNumber(active, "sys.__findVar('F_rebind', null)(6)", 12);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはlnako_aot_compat_deinitでhost状態を解放し再初期化できる" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    const engine_value = try ensureEngine();
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);
    roots[0] = try active.createNamedFunction(doubleFunction, 1, "F", &.{});
    // hostFunction が返す *RawValue ハンドルは呼出し側が所有する。globalThis へ
    // 載せて参照を移した直後に解放し、wrapper ハンドルを漏らさない。
    const registered = try compat.hostFunction(active, engine_value, roots[0]);
    const global = lnako_qjs_eval(engine_value, "globalThis", 10, "<global>") orelse return error.TestUnexpectedResult;
    defer lnako_qjs_value_free(global);
    try std.testing.expect(compat.lnako_qjs_set_property(global, "__lnako_reinit_cb", registered) > 0);
    lnako_qjs_value_free(registered);
    try std.testing.expectEqual(@as(usize, 1), compat.registeredHostFunctionCount());

    lnako_aot_compat_deinit();
    try std.testing.expect(compat.activeEngine() == null);
    try std.testing.expectEqual(@as(usize, 0), compat.registeredHostFunctionCount());

    // 再初期化すると同じ runtime に host bridge が繋がり直す。
    _ = try ensureEngine();
    try expectQuickJsNumber(active, "sys.__setSysVar('再', 1); sys.__getSysVar('再')", 1);
    try expectQuickJsNumber(active, "sys.__findVar('F', null)(5)", 10);
    try std.testing.expect(!active.has_pending_exception);
}

fn addFunction(out: *Value, _: *anyopaque, arguments_slice: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    if (count < 2) return;
    const arguments = arguments_slice orelse return;
    const left: f64 = @bitCast(arguments[0].payload);
    const right: f64 = @bitCast(arguments[1].payload);
    out.* = state.numberValue(left + right);
}

test "compat AOT runtimeはsys.__execでユーザ関数とビルトインを解決する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);

    // グローバルなでしこ関数は `aotCompatResolve` で解決され、関数呼び出しへ
    // ディスパッチされる。
    roots[0] = try active.createNamedFunction(addFunction, 2, "たす", &.{});
    try expectQuickJsNumber(active, "sys.__exec('たす', [20, 22])", 42);
    try std.testing.expect(!active.has_pending_exception);

    // ローカル非関数変数が同名グローバル関数をシャドーイングしても、外側を
    // 再探索せずビルトイン命令へフォールスルーする（interpreter の
    // `quickJsExec` と同じ）。
    var shadow_storage = [_]Value{state.numberValue(999)};
    var shadow_entries = [_]state.AotVarEntry{
        .{ .name_ptr = "整数変換".ptr, .name_len = "整数変換".len },
    };
    var shadow_slots = [_]*const Value{&shadow_storage[0]};
    var shadow_frame: state.AotVarFrame = .{};
    active.pushVarFrame(&shadow_frame, &shadow_entries, shadow_entries.len, &shadow_slots);
    defer active.popVarFrame(&shadow_frame);
    try expectQuickJsNumber(active, "sys.__exec('整数変換', ['12.9'])", 12);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execの曖昧名をクリアしてビルトインへフォールスルーする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);

    // 複数モジュールの同名サフィックスは `error.AmbiguousGlobal` になる。
    // 解決エラーは新規保留例外だけをクリアし、ビルトイン探索へ進む。
    roots[0] = try active.createNamedFunction(addFunction, 2, "m1__F", &.{});
    roots[1] = try active.createNamedFunction(addFunction, 2, "m2__F", &.{});
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('F', []);return 'no';}catch(e){return 'caught:'+e.name;}})()",
        "caught:InternalError",
    );
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execで主要ビルトイン命令を実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    try expectQuickJsNumber(active, "sys.__exec('足', [20, 22])", 42);
    try expectQuickJsNumber(active, "sys.__exec('整数変換', ['12.9'])", 12);

    // `表示` は `表示ログ` を更新し、`sys.__getSysVar` からも観測できる。
    try expectQuickJsString(
        active,
        "sys.__exec('表示', ['hello']); sys.__getSysVar('表示ログ')",
        "hello\n",
    );

    // `切取` は戻り値と `対象` の双方を更新する。
    try expectQuickJsString(active, "sys.__exec('切取', ['A=B', '='])", "A");
    try expectQuickJsString(active, "sys.__getSysVar('対象')", "B");

    // `正規表現マッチ` は `抽出文字列` を更新する。区切り記号付きの
    // パターンは既定の global を解除するため、戻り値は文字列になる。
    try expectQuickJsString(active, "sys.__exec('正規表現マッチ', ['abc123', '/([0-9]+)/'])", "123");
    try expectQuickJsNumber(active, "sys.__getSysVar('抽出文字列').length", 1);
    try expectQuickJsString(active, "sys.__getSysVar('抽出文字列')[0]", "123");

    // `範囲` は汎用 call site 経由で辞書を返す。
    try expectQuickJsNumber(active, "sys.__exec('範囲', [1, 3]).先頭", 1);
    try expectQuickJsNumber(active, "sys.__exec('範囲', [1, 3]).末尾", 3);

    // `表示ログクリア` は `表示ログ` を空文字列へ戻す。
    try expectQuickJsString(
        active,
        "sys.__exec('表示ログクリア'); sys.__getSysVar('表示ログ')",
        "",
    );

    // プラグイン名・名前空間の管理命令もスロットを更新する。
    try expectQuickJsString(
        active,
        "sys.__exec('プラグイン名設定', ['p']); sys.__getSysVar('プラグイン名')",
        "p",
    );
    try expectQuickJsString(
        active,
        "sys.__exec('名前空間設定', ['ns']); sys.__getSysVar('名前空間')",
        "ns",
    );
    try expectQuickJsString(
        active,
        "sys.__exec('名前空間ポップ'); typeof sys.__getSysVar('名前空間')",
        "undefined",
    );

    // `ASSERT` / `確認` はインタプリタと同じ truthiness 契約。
    try expectQuickJsBoolean(active, "sys.__exec('ASSERT', [true])", true);
    try expectQuickJsNumber(active, "sys.__exec('確認', [7])", 7);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execで引数の参照同一性と書き戻しを保つ" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}};
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);

    roots[0] = try active.createNamedFunction(sharedArgumentCallback, 2, "共有確認", &.{});
    test_shared_argument_identity = false;
    // 同じ JS オブジェクトを2引数で渡しても同一の Nako 辞書へ変換され、
    // callback の変更が JS 側の `o.n` へ書き戻される。
    try expectQuickJsNumber(
        active,
        "(function(){const o={n:1};sys.__exec('共有確認', [o, o]);return o.n;})()",
        2,
    );
    try std.testing.expect(test_shared_argument_identity);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはManagedGlobalSlotが動的グローバル再確保後も安全に書き戻す" {
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // 未登録の名前はスタック上のルート保護スロットを使う。
    var slot = try compat.ManagedGlobalSlot.init(active, "対象", .{});
    const pointer = slot.bindAndPtr();
    // 実行中に動的グローバルを大量追加して `dynamic_globals` の再確保を誘発する。
    var index: usize = 0;
    while (index < 512) : (index += 1) {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "再確保_{d}", .{index});
        try state.upsertDynamicGlobal(active, name, state.numberValue(@floatFromInt(index)));
    }
    pointer.* = state.numberValue(42);
    slot.finish();

    const entry = state.dynamicGlobal(active, "対象") orelse return error.TestUnexpectedResult;
    const value = if (entry.slot) |static_slot| static_slot.* else entry.value;
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), value.tag);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(value.payload)));
}

test "compat AOT runtimeはsys.__execのエラーをJSのtry/catchで捕捉し保留例外を残さない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // 未知命令と `エラー発生` は JS の InternalError になり、捕捉後は AOT 側に
    // 保留例外を残さない。
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('存在しない命令', []);return 'no';}catch(e){return 'caught:'+e.name;}})()",
        "caught:InternalError",
    );
    try std.testing.expect(!active.has_pending_exception);
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('エラー発生', ['失敗']);return 'no';}catch(e){return 'caught:'+e.name;}})()",
        "caught:InternalError",
    );
    try std.testing.expect(!active.has_pending_exception);

    // 捕捉しなければ外側の JS 実行が失敗し、AOT 側に例外が残る。
    _ = try evalCompatJs(active, "sys.__exec('存在しない命令', [])");
    try std.testing.expect(active.has_pending_exception);
    _ = active.takeException();
}

fn registerTestGlobalSlot(runtime: *state.Runtime, name: []const u8, storage: *Value) void {
    _ = runtime;
    state.lnako_aot_dynamic_global_register(name.ptr, name.len, storage);
}

var test_timer_fired: usize = 0;

fn markTimerFired(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    test_timer_fired += 1;
    out.* = .{};
}

var test_promise_settled: f64 = -1;

fn recordPromiseNumber(out: *Value, _: *anyopaque, arguments_slice: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    if (count == 0 or arguments_slice == null) return;
    const argument = arguments_slice.?[0];
    if (argument.tag != @backingInt(Tag.number)) return;
    test_promise_settled = @bitCast(argument.payload);
}

fn resolvePromiseImmediately(out: *Value, _: *anyopaque, arguments_slice: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    if (count < 1 or arguments_slice == null) return;
    var resolver = arguments_slice.?[0];
    var settled = [_]Value{state.numberValue(42)};
    state.lnako_aot_function_call(out, &resolver, &settled, settled.len);
}

fn rejectPromiseImmediately(out: *Value, _: *anyopaque, arguments_slice: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    if (count < 2 or arguments_slice == null) return;
    var rejecter = arguments_slice.?[1];
    var reason = [_]Value{state.numberValue(7)};
    state.lnako_aot_function_call(out, &rejecter, &reason, reason.len);
}

test "compat AOT runtimeはsys.__execで圧縮解凍ツールパスとAJAX設定を保持する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // ツールパスは `圧縮解凍ツールパス` スロットへ書き戻る。
    try expectQuickJsString(
        active,
        "sys.__exec('圧縮解凍ツールパス変更', ['lnako-archive-helper']); sys.__getSysVar('圧縮解凍ツールパス')",
        "lnako-archive-helper",
    );
    // AJAX オプションは辞書のまま保持される。
    try expectQuickJsString(
        active,
        "(function(){sys.__exec('AJAXオプション設定', [{method:'PUT',body:'x'}]);const o=sys.__getSysVar('AJAXオプション');return o.method+':'+o.body;})()",
        "PUT:x",
    );
    // 失敗ハンドラは関数値として保持される。
    try expectQuickJsString(
        active,
        "(function(){sys.__exec('AJAX失敗時', [() => 1]);return typeof sys.__getSysVar('AJAX:ONERROR');})()",
        "function",
    );
    // いずれも既定スロットが無い単体テスト環境でも再入でクラッシュしない。
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execで内蔵ZIPの圧縮解凍を実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "日本語ABC" });
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const source = try std.fs.path.join(std.testing.allocator, &.{ base, "source.txt" });
    defer std.testing.allocator.free(source);
    const archive = try std.fs.path.join(std.testing.allocator, &.{ base, "archive.zip" });
    defer std.testing.allocator.free(archive);
    const output = try std.fs.path.join(std.testing.allocator, &.{ base, "output" });
    defer std.testing.allocator.free(output);

    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    try state.upsertDynamicGlobal(active, "P_source", try testString(active, source));
    try state.upsertDynamicGlobal(active, "P_archive", try testString(active, archive));
    try state.upsertDynamicGlobal(active, "P_output", try testString(active, output));

    // ツールパス未変更なら内蔵 ZIP が使われ、外部 7z を起動しない。
    try expectQuickJsBoolean(
        active,
        "sys.__exec('圧縮', [sys.__getSysVar('P_source'), sys.__getSysVar('P_archive')])",
        true,
    );
    try expectQuickJsBoolean(
        active,
        "sys.__exec('解凍', [sys.__getSysVar('P_archive'), sys.__getSysVar('P_output')])",
        true,
    );
    const extracted = try temporary.dir.readFileAlloc(std.testing.io, "output/source.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings("日本語ABC", extracted);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execでファイル操作の既定動作と列挙を実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one" });
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const source = try std.fs.path.join(std.testing.allocator, &.{ base, "a.txt" });
    defer std.testing.allocator.free(source);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ base, "b.txt" });
    defer std.testing.allocator.free(destination);
    const sub = try std.fs.path.join(std.testing.allocator, &.{ base, "sub" });
    defer std.testing.allocator.free(sub);

    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    try state.upsertDynamicGlobal(active, "P_base", try testString(active, base));
    try state.upsertDynamicGlobal(active, "P_source", try testString(active, source));
    try state.upsertDynamicGlobal(active, "P_destination", try testString(active, destination));
    try state.upsertDynamicGlobal(active, "P_sub", try testString(active, sub));

    try expectQuickJsNumber(active, "sys.__exec('ファイル列挙', [sys.__getSysVar('P_base')]).length", 1);
    try expectQuickJsString(active, "sys.__exec('ファイル列挙', [sys.__getSysVar('P_base')])[0]", "a.txt");
    try expectQuickJsUndefined(active, "sys.__exec('フォルダ作成', [sys.__getSysVar('P_sub')])");
    var sub_directory = try temporary.dir.openDir(std.testing.io, "sub", .{});
    sub_directory.close(std.testing.io);

    // 既定の `上書禁止` では既存コピー先への上書きを拒否する。
    try expectQuickJsUndefined(
        active,
        "sys.__exec('ファイルコピー', [sys.__getSysVar('P_source'), sys.__getSysVar('P_destination')])",
    );
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "two" });
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('ファイルコピー',[sys.__getSysVar('P_source'),sys.__getSysVar('P_destination')]);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );
    const rejected = try temporary.dir.readFileAlloc(std.testing.io, "b.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqualStrings("one", rejected);

    // `ファイルコピーデフォルト動作` を変更すると同じ命令が上書きする。
    try expectQuickJsUndefined(active, "sys.__setSysVar('ファイルコピーデフォルト動作', '上書')");
    try expectQuickJsUndefined(
        active,
        "sys.__exec('ファイルコピー', [sys.__getSysVar('P_source'), sys.__getSysVar('P_destination')])",
    );
    const overwritten = try temporary.dir.readFileAlloc(std.testing.io, "b.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(overwritten);
    try std.testing.expectEqualStrings("two", overwritten);

    try expectQuickJsUndefined(active, "sys.__exec('ファイル削除', [sys.__getSysVar('P_destination')])");
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "b.txt", .{}));
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execでタイマーを登録・停止する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);
    // `対象` に固定スロットを登録しないと、非同期コールバックがスタック上の
    // アドレスを保持し得る。登録済みスロット経由の経路を固定する。
    registerTestGlobalSlot(active, "対象", &roots[0]);
    roots[1] = try active.createNamedFunction(markTimerFired, 1, "タイマー記録", &.{});

    test_timer_fired = 0;
    try expectQuickJsString(active, "typeof sys.__exec('秒後', ['タイマー記録', 0])", "number");
    try std.testing.expectEqual(@as(usize, 1), active.timers.items.len);
    try state.drainAotTimers(active);
    try std.testing.expectEqual(@as(usize, 1), test_timer_fired);
    try std.testing.expectEqual(@as(usize, 0), active.timers.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), roots[0].tag);

    // 発火しない長い待機を登録し、`タイマー停止` と `全タイマー停止` で
    // 取り消せることを固定する。
    try expectQuickJsBoolean(
        active,
        "(function(){const id=sys.__exec('秒後',['タイマー記録',60000]);return sys.__exec('タイマー停止',[id]);})()",
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), active.timers.items.len);
    _ = try evalCompatJs(active, "sys.__exec('秒後', ['タイマー記録', 60000]); sys.__exec('全タイマー停止')");
    try std.testing.expectEqual(@as(usize, 0), active.timers.items.len);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execのPromise命令を静的スロット経由で実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);
    registerTestGlobalSlot(active, "そ", &roots[0]);
    registerTestGlobalSlot(active, "対象", &roots[1]);

    roots[2] = try active.createFunction(resolvePromiseImmediately, 1, &.{});
    var create_arguments = [_]Value{roots[2]};
    var promise: Value = .{};
    compat.execCompatBuiltin(active, "動時", &create_arguments, &promise);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.promise)), roots[0].tag);
    try std.testing.expectEqual(roots[0].payload, promise.payload);

    // `成功時` は `そ` を読み、連鎖した Promise を `そ` へ書き戻す。
    test_promise_settled = -1;
    const success_callback = try active.createFunction(recordPromiseNumber, 1, &.{});
    var success_arguments = [_]Value{ success_callback, roots[0] };
    var chained: Value = .{};
    compat.execCompatBuiltin(active, "成功時", &success_arguments, &chained);
    try std.testing.expect(!active.has_pending_exception);
    try state.drainAotPromiseTasks(active);
    try std.testing.expectEqual(@as(f64, 42), test_promise_settled);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.promise)), roots[0].tag);

    // `束` は配列要素の非 Promise 値をそのまま結果へ含める。
    // `成功時` の連鎖結果は標準 `.then` と同じくコールバックの戻り値
    // （ここでは undefined）になるため、元 Promise を束ねて 42 を観測する。
    var all_arguments = [_]Value{ promise, state.numberValue(7) };
    var bundled: Value = .{};
    compat.execCompatBuiltin(active, "束", &all_arguments, &bundled);
    try std.testing.expect(!active.has_pending_exception);
    const settled = try state.awaitAotPromise(active, bundled);
    try std.testing.expectEqual(@as(usize, 2), settled.object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(settled.object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(settled.object().?.payload.array.items[1].payload)));

    // `失敗時` は reject 理由をコールバックへ渡す。
    const rejector = try active.createFunction(rejectPromiseImmediately, 2, &.{});
    var reject_arguments = [_]Value{rejector};
    var rejected_promise: Value = .{};
    compat.execCompatBuiltin(active, "動時", &reject_arguments, &rejected_promise);
    try std.testing.expect(!active.has_pending_exception);
    test_promise_settled = -1;
    const failure_callback = try active.createFunction(recordPromiseNumber, 1, &.{});
    var failure_arguments = [_]Value{ failure_callback, rejected_promise };
    var failed_chain: Value = .{};
    compat.execCompatBuiltin(active, "失敗時", &failure_arguments, &failed_chain);
    try std.testing.expect(!active.has_pending_exception);
    try state.drainAotPromiseTasks(active);
    try std.testing.expectEqual(@as(f64, 7), test_promise_settled);
}

test "compat AOT runtimeはHTTPサーバ命令の未起動時にスロットを残留させない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    // 固定スロットが無い場合、専用 ABI が設定した `http_globals` は
    // 呼出し前の値へ戻され、スタック上の temp を指したまま残らない。
    try std.testing.expect(active.http_globals == null);
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('簡易HTTPサーバ出力', ['x']);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );
    try std.testing.expect(active.http_globals == null);
    try std.testing.expect(!active.has_pending_exception);

    // 固定スロットがある場合はそのアドレスが `http_globals` に残る。
    var slots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &slots);
    defer active.popRoots(&frame);
    registerTestGlobalSlot(active, "HTTPメソッド", &slots[0]);
    registerTestGlobalSlot(active, "GETデータ", &slots[1]);
    registerTestGlobalSlot(active, "POSTデータ", &slots[2]);
    registerTestGlobalSlot(active, "FILESデータ", &slots[3]);
    _ = try evalCompatJs(active, "try{sys.__exec('簡易HTTPサーバ出力', ['x']);}catch(e){}");
    const globals = active.http_globals orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?*Value, &slots[0]), globals.method);
    try std.testing.expectEqual(@as(?*Value, &slots[1]), globals.get_data);
    try std.testing.expectEqual(@as(?*Value, &slots[2]), globals.post_data);
    try std.testing.expectEqual(@as(?*Value, &slots[3]), globals.files_data);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execでESM plugin命令とplugin内sys.__execを実行する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    // plugin 命令は AOT codegen ではなく実行時の `sys.__exec` からのみ呼ぶ。
    // 各命令は plugin 内の `sys.__exec` でビルトイン・別 plugin 命令を呼ぶ。
    const manifest =
        \\[{"path":"/lnako-compat-test/exec-plugin.mjs","source":"export default { 加算: { type: 'func', fn: (sys) => sys.__exec('足', [20, 22]) }, 委譲: { type: 'func', fn: (sys) => sys.__exec('加算', []) }, 表示委譲: { type: 'func', fn: (sys) => { sys.__exec('表示', ['plugin']); return sys.__getSysVar('表示ログ'); } } };","is_plugin":true,"namespaces":[],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(usize, 1), active.esm_modules.items.len);

    try expectQuickJsNumber(active, "sys.__exec('加算', [])", 42);
    try expectQuickJsNumber(active, "sys.__exec('委譲', [])", 42);
    try expectQuickJsString(active, "sys.__exec('表示委譲', [])", "plugin\n");
    try std.testing.expect(!active.has_pending_exception);

    // 未知の plugin 命令は従来どおり JS の InternalError になる。
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('存在しないプラグイン命令', []);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );
    try std.testing.expect(!active.has_pending_exception);
}

fn nakoCatchAndReturn42(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    runtime.setFailure(error.InvalidArgumentCount);
    _ = runtime.takeException();
    out.* = state.numberValue(42);
}

fn nakoNestedJsCatchAndReturn7(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const source_units = std.unicode.utf8ToUtf16LeAlloc(
        std.testing.allocator,
        "(function(){try{sys.__exec('存在しない命令', []);return -1;}catch(e){return 7;}})()",
    ) catch return;
    defer std.testing.allocator.free(source_units);
    var argument = runtime.createString(source_units) catch return;
    var eval_out: Value = .{};
    lnako_aot_compat_js_eval(&eval_out, @ptrCast(&argument), 1);
    out.* = eval_out;
}

test "compat AOT runtimeは捕捉済み例外をsys.__exec・callback境界で再送出しない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var roots = [_]Value{ .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &roots);
    defer active.popRoots(&frame);
    roots[0] = try active.createFunction(nakoCatchAndReturn42, 0, &.{});
    roots[1] = try active.createFunction(nakoNestedJsCatchAndReturn7, 0, &.{});
    registerTestGlobalSlot(active, "捕捉確認", &roots[0]);
    registerTestGlobalSlot(active, "内側捕捉", &roots[1]);

    // Nako 側でエラー監視相当の捕捉を行った後も failure_epoch の増加だけで
    // InternalError を再送出しない。
    try expectQuickJsNumber(active, "sys.__exec('捕捉確認', [])", 42);
    try std.testing.expect(!active.has_pending_exception);

    // JS関数実行経由のコールバックでも同様。
    var call_args = [_]Value{ roots[0], .{} };
    var call_frame: state.RootFrame = .{};
    pushTestRoots(active, &call_frame, &call_args);
    defer active.popRoots(&call_frame);
    const cb_source = try testString(active, "(cb) => cb()");
    var inner_args = [_]Value{roots[0]};
    var packed_args: Value = .{};
    state.lnako_aot_array_new(&packed_args, &inner_args, inner_args.len);
    call_args[0] = cb_source;
    call_args[1] = packed_args;
    var call_out: Value = .{};
    lnako_aot_compat_js_call(&call_out, &call_args, call_args.len);
    try std.testing.expect(!active.has_pending_exception);
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), call_out.tag);
    try std.testing.expectEqual(@as(f64, 42), @as(f64, @bitCast(call_out.payload)));

    // 内側の JS実行 が JS try/catch で例外を処理した場合も 7 をそのまま返す。
    try expectQuickJsNumber(active, "sys.__exec('内側捕捉', [])", 7);
    try std.testing.expect(!active.has_pending_exception);
}

test "compat AOT runtimeはsys.__execでそれと省略引数をインタプリタと一致させる" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;

    var slots = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    pushTestRoots(active, &frame, &slots);
    defer active.popRoots(&frame);
    slots[2] = try testString(active, "");
    registerTestGlobalSlot(active, "それ", &slots[0]);
    registerTestGlobalSlot(active, "対象", &slots[1]);
    registerTestGlobalSlot(active, "表示ログ", &slots[2]);

    // `sys.__exec` 単体は `それ` を書き換えないが、`表示ログ` や `対象` は同期する。
    try expectQuickJsNumber(active, "sys.__setSore(99); sys.__exec('足', [1, 2]); sys.__getSore()", 99);
    try expectQuickJsNumber(active, "sys.__setSore(99); sys.__exec('表示', ['log']); sys.__getSore()", 99);
    try expectQuickJsString(active, "sys.__getSysVar('表示ログ')", "log\n");
    try expectQuickJsNumber(active, "sys.__setSore(99); sys.__exec('切取', ['A=B', '=']); sys.__getSore()", 99);
    try expectQuickJsString(active, "sys.__getSysVar('対象')", "B");

    // 省略引数はインタプリタと同様に既定値 / undefined として扱う。
    const add_empty = try evalCompatJs(active, "sys.__exec('足', [])");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), add_empty.tag);
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(add_empty.payload))));
    const max_val = try evalCompatJs(active, "sys.__exec('最大値', [])");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), max_val.tag);
    try std.testing.expectEqual(-std.math.inf(f64), @as(f64, @bitCast(max_val.payload)));
    const min_val = try evalCompatJs(active, "sys.__exec('最小値', [])");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.number)), min_val.tag);
    try std.testing.expectEqual(std.math.inf(f64), @as(f64, @bitCast(min_val.payload)));
    try expectQuickJsString(active, "sys.__exec('切取', ['abc'])", "abc");
    try expectQuickJsString(active, "sys.__exec('置換', ['aba', 'a'])", ",b,");
    try expectQuickJsString(active, "sys.__exec('正規表現置換', ['aba', 'a'])", "undefinedbundefined");

    const say_empty = try evalCompatJs(active, "sys.__exec('言', [])");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), say_empty.tag);
    const console_empty = try evalCompatJs(active, "sys.__exec('コンソール表示', [])");
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.undefined)), console_empty.tag);

    // タイマー命令は第2引数（秒数）不足時に補完せずエラーとして拒否する。
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('秒後', ['完了']);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('秒毎', ['完了']);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );
    try std.testing.expectEqual(@as(usize, 0), active.timers.items.len);

    // `ハテナ関数設定` の `JS:` 形式は compat 経路では関数化して実行できる。
    try expectQuickJsNumber(
        active,
        "globalThis.__hatenaSeen = 0; sys.__exec('ハテナ関数設定', [['JS:(x)=>{ globalThis.__hatenaSeen = x + 10; return globalThis.__hatenaSeen; }', '表示']]); sys.__exec('ハテナ関数実行', [5]); globalThis.__hatenaSeen",
        15,
    );
    try expectQuickJsString(active, "sys.__getSysVar('表示ログ')", "log\n15\n");
    try expectQuickJsString(
        active,
        "(function(){try{sys.__exec('ハテナ関数設定', [['JS:123']]);return 'no';}catch(e){return e.name;}})()",
        "InternalError",
    );

    var throw_out: Value = .{};
    compat.execCompatBuiltin(active, "エラー発生", &.{}, &throw_out);
    try expectPendingFailureContains(active, "エラー");
}

fn expectUtf16Text(value: Value, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u8, @backingInt(Tag.utf16_string)), value.tag);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, value.object().?.payload.utf16_string);
}

fn fallbackCandidates(comptime names: []const []const u8) [names.len]state.PluginCandidate {
    var candidates: [names.len]state.PluginCandidate = undefined;
    inline for (names, 0..) |name, index| candidates[index] = .{ .name = name.ptr, .len = name.len };
    return candidates;
}

fn registerFallbackPlugins(active: *state.Runtime) !void {
    // a.mjs は 外部甲 と 外部競合、b.mjs は 外部乙 と 外部競合（後発）を持つ。
    const manifest =
        \\[{"path":"/lnako-compat-test/fb-a.mjs","source":"export default { 外部甲: { type: 'func', fn: (x) => `甲:${x}` }, 外部競合: { type: 'func', fn: (x) => `競合-a:${x}` } };","is_plugin":true,"namespaces":["pkg:t:a.mjs"],"package_root":null,"bare_aliases":[]},{"path":"/lnako-compat-test/fb-b.mjs","source":"export default { 外部乙: { type: 'func', fn: (x) => `乙:${x}` }, 外部競合: { type: 'func', fn: (x) => `競合-b:${x}` } };","is_plugin":true,"namespaces":["pkg:t:b.mjs"],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);
}

fn callFallback(active: *state.Runtime, candidates: []const state.PluginCandidate, argument: f64) !Value {
    var arguments = [_]Value{state.numberValue(argument)};
    var out: Value = .{};
    state.lnako_aot_plugin_fallback_call(&out, &arguments, arguments.len, candidates.ptr, candidates.len, 0, true);
    try std.testing.expect(!active.has_pending_exception);
    return out;
}

test "AOT plugin fallback呼出しは非競合時に先発pluginの命令へ、競合時は後勝ちで配送する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    try registerFallbackPlugins(active);

    // 外部甲: 主配送先 b.mjs には無く、先発 a.mjs にある → a.mjs へフォールバック。
    const jia = fallbackCandidates(&.{ "pkg:t:b.mjs__外部甲", "pkg:t:a.mjs__外部甲" });
    try expectUtf16Text(try callFallback(active, &jia, 1), "甲:1");
    // 外部乙: 主配送先 b.mjs にある → b.mjs（先発 a.mjs には無い）。
    const yi = fallbackCandidates(&.{ "pkg:t:b.mjs__外部乙", "pkg:t:a.mjs__外部乙" });
    try expectUtf16Text(try callFallback(active, &yi, 2), "乙:2");
    // 外部競合: 両方にある → 後勝ち（主配送先 b.mjs）。
    const conflict = fallbackCandidates(&.{ "pkg:t:b.mjs__外部競合", "pkg:t:a.mjs__外部競合" });
    try expectUtf16Text(try callFallback(active, &conflict, 3), "競合-b:3");
}

test "AOT plugin fallback関数参照は登録済み候補を解決し全候補未登録ならUnknownFunctionで関数値を作らない" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    try registerFallbackPlugins(active);

    var slots = [_]Value{ .{}, .{} };
    var frame = state.RootFrame{};
    pushTestRoots(active, &frame, &slots);
    defer active.popRoots(&frame);

    // 先発 a.mjs の 外部甲 を `{関数}` 参照して呼び出せる。
    const jia = fallbackCandidates(&.{ "pkg:t:b.mjs__外部甲", "pkg:t:a.mjs__外部甲" });
    state.lnako_aot_plugin_function_new_fallback(&slots[0], &jia, jia.len, true);
    try std.testing.expect(!active.has_pending_exception);
    var arguments = [_]Value{state.numberValue(4)};
    var out: Value = .{};
    state.lnako_aot_function_call(&out, &slots[0], &arguments, arguments.len);
    try std.testing.expect(!active.has_pending_exception);
    try expectUtf16Text(out, "甲:4");

    // 全候補が未登録なら関数値を作らず失敗する（Interpreter の UnknownFunction と一致）。
    const missing = fallbackCandidates(&.{ "pkg:t:b.mjs__未登録", "pkg:t:a.mjs__未登録" });
    state.lnako_aot_plugin_function_new_fallback(&slots[1], &missing, missing.len, true);
    try std.testing.expect(active.has_pending_exception);
    try std.testing.expect(slots[1].tag != @backingInt(Tag.function));
    _ = active.takeException();
}

test "AOT plugin fallback関数参照は登録照合の失敗をプロセス終了せず実行時エラーとして記録する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer lnako_aot_compat_deinit();
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    // 主候補の `fn` getter が例外を投げる plugin。照合が失敗しても runtimeFailure
    // （exit）ではなく setFailure で戻り、関数値は作らない。
    const manifest =
        \\[{"path":"/lnako-compat-test/fb-throw.mjs","source":"export default { 例外: { type: 'func', get fn() { throw new Error('boom'); } } };","is_plugin":true,"namespaces":["pkg:t:throw.mjs"],"package_root":null,"bare_aliases":[]}]
    ;
    lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(!active.has_pending_exception);

    var slots = [_]Value{.{}};
    var frame = state.RootFrame{};
    pushTestRoots(active, &frame, &slots);
    defer active.popRoots(&frame);

    const candidates = fallbackCandidates(&.{ "pkg:t:throw.mjs__例外", "pkg:t:first.mjs__例外" });
    state.lnako_aot_plugin_function_new_fallback(&slots[0], &candidates, candidates.len, true);
    try std.testing.expect(active.has_pending_exception);
    try std.testing.expect(slots[0].tag != @backingInt(Tag.function));
    _ = active.takeException();

    // 候補表が null の場合も同様に実行時エラーとして戻る。
    state.lnako_aot_plugin_function_new_fallback(&slots[0], null, 0, true);
    try std.testing.expect(active.has_pending_exception);
    _ = active.takeException();
}
