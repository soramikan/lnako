//! 明示的な `--compat-js` AOT runtime のQuickJS境界。
//!
//! 通常AOTの `liblnako_runtime.a` はQuickJS stubだけをリンクし、このmoduleを
//! 含まない。`--compat-js` のAOT成果物だけが `liblnako_runtime_compat.a` を
//! リンクし、生成物へ収録したESM manifestの登録と、`JS実行` の最小dispatchを
//! 提供する。値・Promise・callback・GCの完全接続はfollow-up（Issue #55）。
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
extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
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
