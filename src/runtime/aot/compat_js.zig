//! 明示的な `--compat-js` AOT runtime のQuickJS境界。
//!
//! 通常AOTの `liblnako_runtime.a` はQuickJS stubだけをリンクし、このmoduleを
//! 含まない。`--compat-js` のAOT成果物だけが `liblnako_runtime_compat.a` を
//! リンクし、生成物へ収録したESM manifestの登録と、`JS実行` / `JS関数実行` の
//! 最小dispatchを提供する。値・Promise・callback・GCの完全接続はfollow-up
//! （Issue #55）。
const std = @import("std");
const state = @import("state.zig");

const Value = state.Value;
const Tag = state.Tag;

const Engine = opaque {};
const RawValue = opaque {};

const Kind = enum(c_int) {
    undefined,
    null_value,
    boolean,
    number,
    bigint,
    string,
    array,
    function,
    promise,
    object,
};

const HostGetFn = *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) ?*RawValue;
const HostSetFn = *const fn (*anyopaque, [*:0]const u8, *const RawValue) callconv(.c) c_int;
const HostInvokeFn = *const fn (*anyopaque, usize, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
const HostExecFn = *const fn (*anyopaque, [*:0]const u8, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;

extern fn lnako_qjs_new() ?*Engine;
extern fn lnako_qjs_set_host(engine: *Engine, context: *anyopaque, get: HostGetFn, set: HostSetFn, invoke: HostInvokeFn, exec: HostExecFn) void;
extern fn lnako_qjs_set_host_strict(engine: *Engine, strict: c_int) void;
extern fn lnako_qjs_add_module_source(engine: *Engine, name: [*:0]const u8, source: [*]const u8, length: usize, package_root: ?[*:0]const u8) c_int;
extern fn lnako_qjs_add_module_alias(engine: *Engine, alias: [*:0]const u8, target: [*:0]const u8) c_int;
extern fn lnako_qjs_release(engine: *Engine) void;
extern fn lnako_qjs_take_error(engine: *Engine) ?[*:0]u8;
extern fn lnako_qjs_free_string(text: [*:0]u8) void;
extern fn lnako_qjs_eval(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_call(engine: *Engine, function: *const RawValue, arguments: [*c]const *const RawValue, count: usize) ?*RawValue;
extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
extern fn lnako_qjs_undefined(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_null(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_boolean(engine: *Engine, value: c_int) ?*RawValue;
extern fn lnako_qjs_number(engine: *Engine, value: f64) ?*RawValue;
extern fn lnako_qjs_string(engine: *Engine, value: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_kind(value: *const RawValue) Kind;
extern fn lnako_qjs_to_boolean(value: *const RawValue) c_int;
extern fn lnako_qjs_to_number(value: *const RawValue, result: *f64) c_int;
extern fn lnako_qjs_to_string(value: *const RawValue, length: *usize) ?[*:0]u8;
extern fn lnako_qjs_value_free(value: *RawValue) void;

/// AOT runtimeにはinterpreterのhost値bridgeが無い。ESM moduleの評価中に
/// `sys.__getSysVar` 等が呼ばれても未定義動作にしないため、明示的な
/// 未対応応答を返すstubを渡す。
var host_context: u8 = 0;

fn hostGet(_: *anyopaque, _: [*:0]const u8, _: c_int) callconv(.c) ?*RawValue {
    return null;
}

fn hostSet(_: *anyopaque, _: [*:0]const u8, _: *const RawValue) callconv(.c) c_int {
    return -1;
}

fn hostInvoke(_: *anyopaque, _: usize, _: [*c]const *const RawValue, _: usize) callconv(.c) ?*RawValue {
    return null;
}

fn hostExec(_: *anyopaque, _: [*:0]const u8, _: [*c]const *const RawValue, _: usize) callconv(.c) ?*RawValue {
    return null;
}

var engine: ?*Engine = null;
var engine_failed = false;

fn ensureEngine() !*Engine {
    if (engine) |value| return value;
    if (engine_failed) return error.QuickJsInitializationFailed;
    const created = lnako_qjs_new() orelse {
        engine_failed = true;
        return error.QuickJsInitializationFailed;
    };
    lnako_qjs_set_host(created, @ptrCast(&host_context), hostGet, hostSet, hostInvoke, hostExec);
    // AOTにはinterpreterの変数bridgeが無い。`sys.__getSysVar` の直接読み取りは
    // 未定義値を返さずJS例外にし、plugin初期化の取りこぼしを表面化させる。
    lnako_qjs_set_host_strict(created, 1);
    engine = created;
    return created;
}

fn fail(runtime: *state.Runtime, engine_value: *Engine) void {
    if (lnako_qjs_take_error(engine_value)) |text| {
        defer lnako_qjs_free_string(text);
        runtime.setFailureText(std.mem.span(text));
    } else {
        runtime.setFailureText("QuickJS error");
    }
}

fn fromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer lnako_qjs_value_free(raw);
    return switch (lnako_qjs_kind(raw)) {
        .undefined => .{},
        .null_value => .{ .tag = @backingInt(Tag.null_value) },
        .boolean => .{ .tag = @backingInt(Tag.boolean), .payload = @intFromBool(lnako_qjs_to_boolean(raw) != 0) },
        .number => blk: {
            var number: f64 = 0;
            if (lnako_qjs_to_number(raw, &number) < 0) return error.QuickJsValueConversionFailed;
            break :blk state.numberValue(number);
        },
        .string => blk: {
            var length: usize = 0;
            const text = lnako_qjs_to_string(raw, &length) orelse return error.QuickJsValueConversionFailed;
            defer lnako_qjs_free_string(text);
            // QuickJSは孤立サロゲートをWTF-8で返し得る。UTF-8 strict変換だと
            // 保存済みJS文字列が変換不能になるため、可逆なWTF-8→WTF-16を使う。
            const units = try std.unicode.wtf8ToWtf16LeAlloc(runtime.allocator, text[0..length]);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        else => error.QuickJsUnsupportedValue,
    };
}

fn sourceUtf8Alloc(runtime: *state.Runtime, value: Value) ![]u8 {
    const units = try state.valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return std.unicode.utf16LeToUtf8Alloc(runtime.allocator, units);
}

/// `JS実行` の最小dispatch。AOTからQuickJSのevalを1回呼び、Promiseなら
/// jobをdrainしてawaitする。数値・文字列・真偽値・null・undefinedだけを
/// Nako値へ戻し、それ以外は未対応として失敗にする（follow-upで拡張）。
pub export fn lnako_aot_compat_js_eval(out: *Value, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (count == 0 or arguments == null) {
        runtime.setFailureText("JS実行 requires a source argument");
        return;
    }
    const source = sourceUtf8Alloc(runtime, arguments.?[0]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(source);
    const engine_value = ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    var raw = lnako_qjs_eval(engine_value, source.ptr, source.len, "<JS実行>") orelse {
        fail(runtime, engine_value);
        return;
    };
    // evalが即値でもqueueされたjobはinterpreter経路と同じくdrainする。
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(raw);
        fail(runtime, engine_value);
        return;
    }
    if (lnako_qjs_kind(raw) == .promise) {
        const awaited = lnako_qjs_await(engine_value, raw);
        lnako_qjs_value_free(raw);
        raw = awaited orelse {
            fail(runtime, engine_value);
            return;
        };
    }
    out.* = fromRaw(runtime, raw) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

fn isStringValue(value: Value) bool {
    return switch (@as(Tag, @fromBackingInt(value.tag))) {
        .utf16_string, .static_utf8_string => true,
        else => false,
    };
}

fn arrayItems(value: Value) ?[]Value {
    if (@as(Tag, @fromBackingInt(value.tag)) != .array) return null;
    const object = value.object() orelse return null;
    return object.payload.array.items;
}

/// `JS関数実行` の引数をQuickJS値へ変換する。最小スライスでは数値・文字列・
/// 真偽値・null/undefinedだけを許可し、オブジェクト/配列/関数などは呼び出し
/// 前に明示的な未対応エラーにする（Nako側の文字列化へ逃がさない）。
fn primitiveRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    return switch (@as(Tag, @fromBackingInt(value.tag))) {
        .undefined => lnako_qjs_undefined(engine_value) orelse error.OutOfMemory,
        .null_value => lnako_qjs_null(engine_value) orelse error.OutOfMemory,
        .boolean => lnako_qjs_boolean(engine_value, @intFromBool(value.payload != 0)) orelse error.OutOfMemory,
        .number => lnako_qjs_number(engine_value, @bitCast(value.payload)) orelse error.OutOfMemory,
        .utf16_string, .static_utf8_string => blk: {
            // interpreterのtoRawと同じ方針。utf16_stringは孤立サロゲートを
            // 置換し、static_utf8_stringはソース由来のUTF-8をそのまま渡す。
            const text = try state.stringUtf8Alloc(runtime, value);
            defer runtime.allocator.free(text);
            break :blk lnako_qjs_string(engine_value, text.ptr, text.len) orelse error.OutOfMemory;
        },
        else => error.QuickJsUnsupportedArgument,
    };
}

/// `JS関数実行` の最小dispatch。interpreter/officialと同じく、第1引数の文字列を
/// global evalで関数へ解決し、第2引数が配列ならその要素を、そうでなければ
/// 第2引数1個を実引数として呼び出す。`JS実行` のeval/drain/例外経路を共有し、
/// 戻り値は `fromRaw` のプリミティブ変換だけを通す。
pub export fn lnako_aot_compat_js_call(out: *Value, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    if (count == 0 or arguments == null) {
        runtime.setFailureText("JS関数実行 requires a function argument");
        return;
    }
    // 生成AOTコードの呼出し側は全Value slotをroot frameへ載せているが、
    // このABIは引数スライスだけを受け取る。変換中の割当てに備えてここでも
    // 引数全体をrootし、第2引数が配列のときの要素スライスの寿命を確保する。
    const rooted = runtime.allocator.alloc(Value, count) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    @memcpy(rooted, arguments.?[0..count]);
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, rooted.ptr, rooted.len);
    defer runtime.popRoots(&frame);
    if (!isStringValue(rooted[0])) {
        runtime.setFailureText("JS関数実行 requires a function name string in AOT compat mode");
        return;
    }
    // interpreterと同じく、utf16_stringの関数名はlossy変換してevalする。
    const source = state.stringUtf8Alloc(runtime, rooted[0]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(source);
    const engine_value = ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    const callable = lnako_qjs_eval(engine_value, source.ptr, source.len, "<JS関数実行>") orelse {
        fail(runtime, engine_value);
        return;
    };
    defer lnako_qjs_value_free(callable);
    if (lnako_qjs_kind(callable) != .function) {
        runtime.setFailureText("JS関数実行 did not evaluate to a function");
        return;
    }
    const values: []const Value = blk: {
        if (count >= 2) {
            if (arrayItems(rooted[1])) |items| break :blk items;
        }
        // official/interpreterと同じく、配列以外の第2引数は単一の実引数として
        // 扱う（第3引数以降はsemantic層が拒否する。第2引数なしのcount==1は
        // interpreterと同じ0引数呼出し）。
        break :blk rooted[1..@min(count, 2)];
    };
    // bridgeが返すRawValueはQuickJSの参照カウントで保持され、他のJS値割当てを
    // またいでも有効。lnako_qjs_value_freeまで明示的に解放しない。
    const raw_arguments = runtime.allocator.alloc(*const RawValue, values.len) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    var initialized: usize = 0;
    defer {
        for (raw_arguments[0..initialized]) |raw| lnako_qjs_value_free(@constCast(raw));
        runtime.allocator.free(raw_arguments);
    }
    for (values, 0..) |value, index| {
        raw_arguments[index] = primitiveRaw(runtime, engine_value, value) catch |failure| {
            if (failure == error.QuickJsUnsupportedArgument) {
                runtime.setFailureText("JS関数実行 does not support object, array, function, bigint, or bytes arguments yet");
            } else {
                runtime.setFailure(failure);
            }
            return;
        };
        initialized += 1;
    }
    // 空配列はゼロ長allocのptrをC ABIへ渡さずnullにする（count=0で参照されない）。
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    const raw = lnako_qjs_call(engine_value, callable, raw_pointer, raw_arguments.len) orelse {
        fail(runtime, engine_value);
        return;
    };
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(raw);
        fail(runtime, engine_value);
        return;
    }
    if (lnako_qjs_kind(raw) == .promise) {
        lnako_qjs_value_free(raw);
        runtime.setFailureText("JS関数実行 does not support Promise results yet");
        return;
    }
    // fromRawは成功・失敗にかかわらずrawを消費して解放する。
    out.* = fromRaw(runtime, raw) catch |failure| {
        if (failure == error.QuickJsUnsupportedValue) {
            runtime.setFailureText("JS関数実行 only supports primitive number, string, boolean, null, and undefined results yet");
        } else {
            runtime.setFailure(failure);
        }
        return;
    };
}

/// QuickJSのmodule名は `/` 区切りで比較される。interpreter側の
/// `moduleFilename` と同じくWindowsの `\` を `/` へ正規化して登録する。
fn dupeModuleName(runtime: *state.Runtime, text: []const u8) ![:0]u8 {
    const copy = try runtime.allocator.dupeSentinel(u8, text, 0);
    for (copy) |*character| if (character.* == '\\') {
        character.* = '/';
    };
    return copy;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return switch (item) {
        .string => |text| text,
        else => null,
    };
}

/// 生成物へ収録したESM manifest（path/source/identity）をQuickJSへ登録する。
/// manifestはJSON配列で、各要素は `path`・`source`・`is_plugin`・
/// `namespaces`・`package_root`・`bare_aliases` を持つ。
pub export fn lnako_aot_compat_esm_register(manifest: ?[*]const u8, length: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const bytes = if (manifest) |pointer| pointer[0..length] else return;
    if (bytes.len == 0) return;
    const engine_value = ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, bytes, .{}) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer parsed.deinit();
    const modules = switch (parsed.value) {
        .array => |array| array.items,
        else => {
            runtime.setFailureText("compat ESM manifest is not an array");
            return;
        },
    };
    for (modules) |module| {
        const object = switch (module) {
            .object => |value| value,
            else => continue,
        };
        const path = jsonString(object.get("path")) orelse continue;
        const source = jsonString(object.get("source")) orelse continue;
        const path_z = dupeModuleName(runtime, path) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        defer runtime.allocator.free(path_z);
        const package_root = jsonString(object.get("package_root"));
        const root_z = if (package_root) |root| dupeModuleName(runtime, root) catch |failure| {
            runtime.setFailure(failure);
            return;
        } else null;
        defer if (root_z) |root| runtime.allocator.free(root);
        if (lnako_qjs_add_module_source(engine_value, path_z.ptr, source.ptr, source.len, if (root_z) |root| root.ptr else null) < 0) {
            fail(runtime, engine_value);
            return;
        }
        const aliases = switch (object.get("bare_aliases") orelse continue) {
            .array => |array| array.items,
            else => continue,
        };
        for (aliases) |alias| {
            const alias_text = jsonString(alias) orelse continue;
            const alias_z = runtime.allocator.dupeSentinel(u8, alias_text, 0) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(alias_z);
            if (lnako_qjs_add_module_alias(engine_value, alias_z.ptr, path_z.ptr) < 0) {
                fail(runtime, engine_value);
                return;
            }
        }
    }
}

/// プロセス終了時にQuickJS engineを解放する。生成物のmainがruntime deinitの
/// 直前に呼ぶ。
pub export fn lnako_aot_compat_deinit() callconv(.c) void {
    if (engine) |value| {
        lnako_qjs_release(value);
        engine = null;
    }
}

test "compat AOT runtimeはQuickJS engineを遅延生成する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    _ = try ensureEngine();
    try std.testing.expect(engine != null);
    lnako_aot_compat_deinit();
    try std.testing.expect(engine == null);
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

test "compat AOT runtimeはJS関数実行の未対応引数を明示エラーにする" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "x => x");
    defer std.testing.allocator.free(source_units);
    // [0]=callable, [1]=実引数配列, [2]=その要素である未対応の配列。
    var arguments = [_]Value{ .{}, .{}, .{} };
    var frame: state.RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &arguments, arguments.len);
    defer state.active_runtime.?.popRoots(&frame);
    arguments[0] = try state.active_runtime.?.createString(source_units);
    var nested = [_]Value{ state.numberValue(1), state.numberValue(2) };
    state.lnako_aot_array_new(&arguments[2], &nested, nested.len);
    var container = [_]Value{arguments[2]};
    state.lnako_aot_array_new(&arguments[1], &container, container.len);
    var out: Value = .{};
    lnako_aot_compat_js_call(&out, &arguments, 2);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const units = try state.valueUtf16Alloc(&state.active_runtime.?, state.active_runtime.?.pending_exception);
    defer std.testing.allocator.free(units);
    try std.testing.expect(std.mem.indexOf(u16, units, &[_]u16{ 'd', 'o', 'e', 's', ' ', 'n', 'o', 't', ' ', 's', 'u', 'p', 'p', 'o', 'r', 't' }) != null);
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

test "compat AOT runtimeはJS関数実行の非関数・Promise・非プリミティブ戻り値を明示エラーにする" {
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
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "1+2", .expected = "did not evaluate to a function" },
        .{ .source = "()=>Promise.resolve(1)", .expected = "does not support Promise results" },
        .{ .source = "()=>({a:1})", .expected = "only supports primitive" },
    };
    for (cases) |case| {
        const source_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(source_units);
        arguments[0] = try state.active_runtime.?.createString(source_units);
        var out: Value = .{};
        lnako_aot_compat_js_call(&out, &arguments, arguments.len);
        try std.testing.expect(state.active_runtime.?.has_pending_exception);
        const message = state.active_runtime.?.takeException();
        const message_units = try state.valueUtf16Alloc(&state.active_runtime.?, message);
        defer std.testing.allocator.free(message_units);
        const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.expected);
        defer std.testing.allocator.free(expected_units);
        try std.testing.expect(std.mem.indexOf(u16, message_units, expected_units) != null);
    }
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
