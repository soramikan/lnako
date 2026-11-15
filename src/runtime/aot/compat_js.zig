//! 明示的な `--compat-js` AOT runtime のQuickJS境界。
//!
//! 通常AOTの `liblnako_runtime.a` はQuickJS stubだけをリンクし、このmoduleを
//! 含まない。`--compat-js` のAOT成果物だけが `liblnako_runtime_compat.a` を
//! リンクし、生成物へ収録したESM manifestの登録と、`JS実行` / `JS関数実行` /
//! `JSオブジェクト取得` / `JSメソッド実行` のdispatchを提供する。
//!
//! JS→Nakoの値変換（`JS実行` のfull変換・JS関数値のcallback・再帰の
//! 結果変換・呼出し後の再同期）とNako→JSの同期変換（`SyncState` /
//! `syncValueRaw` / `syncExternalRaw`）は `compat_js_result.zig` に分離し、
//! このmoduleにはABI面（`pub export fn lnako_aot_compat_*`）と実引数の形状
//! 変換だけを残す。回帰テストは `compat_js_test.zig`（Issue #55）。
const std = @import("std");
const state = @import("state.zig");
const esm_manifest = @import("esm_manifest.zig");
const functions = @import("functions.zig");
const compat_js_result = @import("compat_js_result.zig");

const SyncState = compat_js_result.SyncState;

const Value = state.Value;
const Tag = state.Tag;
const HostFunctionTable = @import("../../compat/host_functions.zig").Table(Value);

pub const Engine = opaque {};
pub const RawValue = opaque {};
pub const Keys = opaque {};

pub const Kind = enum(c_int) {
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
const HostInvokeFn = *const fn (*anyopaque, usize, u64, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
const HostReleaseFn = *const fn (*anyopaque, usize, u64) callconv(.c) void;
const HostExecFn = *const fn (*anyopaque, [*:0]const u8, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;

pub extern fn lnako_qjs_new() ?*Engine;
pub extern fn lnako_qjs_set_host(engine: *Engine, context: *anyopaque, get: HostGetFn, set: HostSetFn, invoke: HostInvokeFn, exec: HostExecFn) void;
pub extern fn lnako_qjs_set_host_release(engine: *Engine, release: ?HostReleaseFn) void;
pub extern fn lnako_qjs_set_host_strict(engine: *Engine, strict: c_int) void;
pub extern fn lnako_qjs_add_module_source(engine: *Engine, name: [*:0]const u8, source: [*]const u8, length: usize, package_root: ?[*:0]const u8) c_int;
pub extern fn lnako_qjs_add_module_alias(engine: *Engine, alias: [*:0]const u8, target: [*:0]const u8) c_int;
pub extern fn lnako_qjs_release(engine: *Engine) void;
pub extern fn lnako_qjs_take_error(engine: *Engine) ?[*:0]u8;
pub extern fn lnako_qjs_free_string(text: [*:0]u8) void;
pub extern fn lnako_qjs_eval(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_call(engine: *Engine, function: *const RawValue, arguments: [*c]const *const RawValue, count: usize) ?*RawValue;
pub extern fn lnako_qjs_call_method(engine: *Engine, object: *const RawValue, name: [*:0]const u8, arguments: [*c]const *const RawValue, count: usize) ?*RawValue;
pub extern fn lnako_qjs_dup(value: *const RawValue) ?*RawValue;
pub extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
pub extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
pub extern fn lnako_qjs_undefined(engine: *Engine) ?*RawValue;
pub extern fn lnako_qjs_null(engine: *Engine) ?*RawValue;
pub extern fn lnako_qjs_boolean(engine: *Engine, value: c_int) ?*RawValue;
pub extern fn lnako_qjs_number(engine: *Engine, value: f64) ?*RawValue;
pub extern fn lnako_qjs_string(engine: *Engine, value: [*]const u8, length: usize) ?*RawValue;
pub extern fn lnako_qjs_bigint(engine: *Engine, decimal: [*]const u8, length: usize) ?*RawValue;
pub extern fn lnako_qjs_host_function(engine: *Engine, function_id: usize, generation: u64, name: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_run_gc(engine: *Engine) void;
pub extern fn lnako_qjs_set_memory_limit(engine: *Engine, limit: usize) void;
pub extern fn lnako_qjs_array(engine: *Engine) ?*RawValue;
pub extern fn lnako_qjs_object(engine: *Engine) ?*RawValue;
pub extern fn lnako_qjs_set_index(value: *RawValue, index: u32, item: *const RawValue) c_int;
pub extern fn lnako_qjs_set_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
pub extern fn lnako_qjs_array_length(value: *const RawValue) u32;
pub extern fn lnako_qjs_get_index(value: *const RawValue, index: u32) ?*RawValue;
pub extern fn lnako_qjs_get_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_get_own_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_has_own_property(value: *const RawValue, name: [*:0]const u8) c_int;
pub extern fn lnako_qjs_set_array_length(value: *RawValue, length: u32) c_int;
pub extern fn lnako_qjs_clear_properties(value: *RawValue) c_int;
pub extern fn lnako_qjs_define_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
pub extern fn lnako_qjs_delete_property(value: *RawValue, name: [*:0]const u8) c_int;
pub extern fn lnako_qjs_has_index(value: *const RawValue, index: u32) c_int;
pub extern fn lnako_qjs_delete_index(value: *RawValue, index: u32) c_int;
pub extern fn lnako_qjs_strict_equal(left: *const RawValue, right: *const RawValue) c_int;
pub extern fn lnako_qjs_value_engine(value: *const RawValue) ?*Engine;
pub extern fn lnako_qjs_identity(value: *const RawValue) usize;
pub extern fn lnako_qjs_keys(value: *const RawValue) ?*Keys;
pub extern fn lnako_qjs_keys_length(keys: *const Keys) usize;
pub extern fn lnako_qjs_key(keys: *const Keys, index: usize, length: *usize) ?[*]const u8;
pub extern fn lnako_qjs_keys_free(keys: *Keys) void;
pub extern fn lnako_qjs_is_bytes(value: *const RawValue) c_int;
pub extern fn lnako_qjs_kind(value: *const RawValue) Kind;
pub extern fn lnako_qjs_to_boolean(value: *const RawValue) c_int;
pub extern fn lnako_qjs_to_number(value: *const RawValue, result: *f64) c_int;
pub extern fn lnako_qjs_to_string(value: *const RawValue, length: *usize) ?[*:0]u8;
pub extern fn lnako_qjs_value_free(value: *RawValue) void;

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

fn hostInvoke(_: *anyopaque, function_id: usize, generation: u64, raw_arguments: [*c]const *const RawValue, count: usize) callconv(.c) ?*RawValue {
    const runtime = if (state.active_runtime) |*active| active else return null;
    if (host_runtime != runtime) return null;
    const callable = host_functions.lookup(function_id, generation) orelse return null;
    const engine_value = engine orelse return null;
    if (count != 0 and raw_arguments == null) return null;
    const had_pending = runtime.has_pending_exception;
    var result_roots = [_]Value{ callable, .{} };
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, &result_roots, result_roots.len);
    defer runtime.popRoots(&result_frame);
    const arguments = runtime.allocator.alloc(Value, count) catch {
        clearNewPendingException(runtime, had_pending);
        return null;
    };
    defer runtime.allocator.free(arguments);
    @memset(arguments, .{});
    var arguments_frame: state.RootFrame = .{};
    runtime.pushRoots(&arguments_frame, if (arguments.len == 0) null else arguments.ptr, arguments.len);
    defer runtime.popRoots(&arguments_frame);
    // 実引数は1つの `seen` を共有して変換する。JSが `cb(o, o)` と同じ
    // オブジェクトを複数回渡した場合に同じNako値へ写し、片方への変更が
    // 他方の書戻しで失われないようにする。
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    for (0..count) |index| {
        const owned = lnako_qjs_dup(raw_arguments[index]) orelse {
            clearNewPendingException(runtime, had_pending);
            return null;
        };
        arguments[index] = compat_js_result.jsEvalResultWithSeen(runtime, owned, &seen) catch {
            clearNewPendingException(runtime, had_pending);
            return null;
        };
    }
    functions.lnako_aot_function_call(&result_roots[1], &result_roots[0], if (arguments.len == 0) null else arguments.ptr, arguments.len);
    if (!had_pending and runtime.has_pending_exception) {
        // Nako callback が失敗した。null を返すと QuickJS が InternalError へ
        // 変換するため、JS 側の try/catch で捕捉できる。Nako の未捕捉例外は
        // ここで解消し、JS が捕捉しなかった場合だけ呼出し元の `fail` が報告する。
        runtime.has_pending_exception = false;
        runtime.pending_exception = .{};
        return null;
    }
    // callback 内で変更された配列・辞書を JS へ書き戻す（interpreter の
    // hostCall と同じく、実引数を同期してから戻り値を変換する）。
    // full_values で BigInt・bytes・Nako 関数も往復させる。
    var sync = compat_js_result.SyncState{ .full_values = true };
    defer sync.deinit(runtime.allocator);
    for (arguments) |argument| {
        const raw = compat_js_result.syncValueRaw(runtime, engine_value, argument, &sync, 0) catch {
            clearNewPendingException(runtime, had_pending);
            return null;
        };
        lnako_qjs_value_free(raw);
    }
    return compat_js_result.syncValueRaw(runtime, engine_value, result_roots[1], &sync, 0) catch {
        clearNewPendingException(runtime, had_pending);
        return null;
    };
}

// Nako→JS callback の host 関数テーブル。`hostFunction` が JS へ渡した Nako
// 関数を世代付き ID で保持し、QuickJS の call class から `hostInvoke` で呼び
// 戻す。capture を含む Value は runtime の GC root ではないため `compatTrace`
// で mark する。
//
// 解放は QuickJS の finalizer が `hostRelease` へ1インスタンス1回通知し、
// 最後のインスタンスが消えたスロットだけを無効化する。`hostRelease` から
// QuickJS や Nako GC を再入させないため、この通知は参照カウント減算と
// free list への連結だけを行う。
var host_functions: HostFunctionTable = .{};
var host_runtime: ?*state.Runtime = null;
var host_allocator: ?std.mem.Allocator = null;

fn deinitHostFunctions() void {
    // stale な finalizer が破棄済みテーブルへ触れないよう、通知を先に解除する。
    if (engine) |value| lnako_qjs_set_host_release(value, null);
    // `host_runtime` が差し替わった場合に、古い runtime の GC hook が
    // 破棄済みテーブルを参照しないよう先に外す（`compatDeinit` との二重クリアは
    // 無害）。
    if (host_runtime) |rt| {
        rt.compat_trace = null;
        rt.compat_deinit = null;
    }
    host_functions.deinit(host_allocator orelse std.heap.page_allocator);
    host_runtime = null;
    host_allocator = null;
}

fn compatTrace(rt: *state.Runtime) void {
    if (host_runtime != rt) return;
    host_functions.trace(rt, struct {
        fn mark(runtime: *state.Runtime, value: Value) anyerror!void {
            runtime.markValue(value);
        }
    }.mark) catch {};
}

fn compatDeinit(rt: *state.Runtime) void {
    if (host_runtime == rt) {
        deinitHostFunctions();
        rt.compat_trace = null;
        rt.compat_deinit = null;
    }
}

fn hostRelease(_: *anyopaque, function_id: usize, generation: u64) callconv(.c) void {
    host_functions.release(function_id, generation);
}

fn sameHostFunction(left: Value, right: Value) bool {
    if (@as(Tag, @fromBackingInt(left.tag)) != .function) return false;
    if (@as(Tag, @fromBackingInt(right.tag)) != .function) return false;
    return left.object() == right.object();
}

/// 登録済み host 関数スロット数（テスト・診断用）。tombstone は含まない。
pub fn registeredHostFunctionCount() usize {
    return host_functions.occupiedCount();
}

/// 登録済み JS 関数インスタンス数（テスト・診断用）。
pub fn hostFunctionInstanceCount(value: Value) usize {
    const handle = host_functions.handleForValue(value, sameHostFunction) orelse return 0;
    return host_functions.instanceCount(handle);
}

/// 値に対応する host 関数スロットの (index, generation)（テスト・診断用）。
pub fn hostFunctionHandle(value: Value) ?HostFunctionTable.Handle {
    return host_functions.handleForValue(value, sameHostFunction);
}

/// Nako 関数・クロージャを QuickJS の JS 関数値へ変換する。同じ
/// `*state.Object` は同じスロットを再利用し、別 Object（クロージャ）は別
/// スロットとして登録する。1回の呼出しは JS 関数インスタンス1個に対応し、
/// その finalizer が来るまでスロットと capture を保持する。
pub fn hostFunction(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    if (@as(Tag, @fromBackingInt(value.tag)) != .function) return error.QuickJsUnsupportedArgument;
    // 単一 engine 所有モデル。解放通知は生成先 engine に設定する必要があるため、
    // モジュール変数 `engine` と一致しない engine は拒否する。
    const active_engine = engine orelse return error.QuickJsHostUnavailable;
    if (active_engine != engine_value) return error.QuickJsHostUnavailable;
    const object = value.object() orelse return error.QuickJsUnsupportedArgument;
    // 別 runtime の残留エントリは前の runtime の Object を指すため、登録前に破棄する。
    if (host_runtime != null and host_runtime != runtime) deinitHostFunctions();
    host_runtime = runtime;
    host_allocator = runtime.allocator;
    runtime.compat_trace = compatTrace;
    runtime.compat_deinit = compatDeinit;
    lnako_qjs_set_host_release(active_engine, hostRelease);
    var handle: HostFunctionTable.Handle = undefined;
    if (host_functions.handleForValue(value, sameHostFunction)) |existing| {
        handle = existing;
    } else {
        handle = try host_functions.insert(runtime.allocator, value);
    }
    // C 側の関数生成中に QuickJS の GC やプロパティ操作で既存インスタンスの
    // finalizer が走ってもスロットが解放されないよう、生成前に参照カウントを
    // 予約する。失敗時は予約分だけを戻す（新規なら 1 -> 0 で即解放、既存なら
    // N+1 -> N で既存インスタンスを保護する）。
    host_functions.acquire(handle);
    errdefer host_functions.release(handle.index, handle.generation);
    // QuickJS の C 関数名は NUL 終端。NUL を含む名前はそこで切って安全に渡す。
    const source_name = object.payload.function.name;
    const name = if (std.mem.indexOfScalar(u8, source_name, 0)) |end| source_name[0..end] else source_name;
    const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
    defer runtime.allocator.free(name_z);
    const raw = lnako_qjs_host_function(engine_value, handle.index, handle.generation, name_z.ptr) orelse return error.OutOfMemory;
    return raw;
}

fn clearNewPendingException(runtime: *state.Runtime, had_pending: bool) void {
    if (!had_pending and runtime.has_pending_exception) {
        runtime.has_pending_exception = false;
        runtime.pending_exception = .{};
    }
}

fn hostExec(_: *anyopaque, _: [*:0]const u8, _: [*c]const *const RawValue, _: usize) callconv(.c) ?*RawValue {
    return null;
}

var engine: ?*Engine = null;
var engine_failed = false;

/// 現在のQuickJS engineを返す（テスト・診断用。未生成ならnull）。
pub fn activeEngine() ?*Engine {
    return engine;
}

pub fn ensureEngine() !*Engine {
    if (engine) |value| return value;
    if (engine_failed) return error.QuickJsInitializationFailed;
    const created = lnako_qjs_new() orelse {
        engine_failed = true;
        return error.QuickJsInitializationFailed;
    };
    lnako_qjs_set_host(created, @ptrCast(&host_context), hostGet, hostSet, hostInvoke, hostExec);
    // ESM plugin の登録 shim は interpreter と同じ JS 環境を要する。
    if (!esm_manifest.installBootstrap(created, lnako_qjs_eval, lnako_qjs_value_free)) {
        engine_failed = true;
        return error.QuickJsInitializationFailed;
    }
    // AOTにはinterpreterの変数bridgeが無い。`sys.__getSysVar` の直接読み取りは
    // 未定義値を返さずJS例外にし、plugin初期化の取りこぼしを表面化させる。
    lnako_qjs_set_host_strict(created, 1);
    // `hostFunction` を経由せずに engine を生成した場合も、finalizer の解放
    // 通知先をこのモジュールへ揃えておく（テーブルが空なら no-op）。
    lnako_qjs_set_host_release(created, hostRelease);
    engine = created;
    return created;
}

pub fn fail(runtime: *state.Runtime, engine_value: *Engine) void {
    if (lnako_qjs_take_error(engine_value)) |text| {
        defer lnako_qjs_free_string(text);
        runtime.setFailureText(std.mem.span(text));
    } else {
        runtime.setFailureText("QuickJS error");
    }
}

/// プリミティブだけをNako値へ変換する。rawは呼出し側が所有権を保持し、ここでは
/// 解放しない（`jsEvalResult` が呼出し後に消費する）。
pub fn primitiveFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
    return switch (lnako_qjs_kind(raw)) {
        .undefined => .{},
        .null_value => .{ .tag = @backingInt(Tag.null_value) },
        .boolean => .{ .tag = @backingInt(Tag.boolean), .payload = @intFromBool(lnako_qjs_to_boolean(raw) != 0) },
        .number => blk: {
            var number: f64 = 0;
            if (lnako_qjs_to_number(raw, &number) < 0) return error.QuickJsConversionFailed;
            break :blk state.numberValue(number);
        },
        .string => blk: {
            var length: usize = 0;
            const text = lnako_qjs_to_string(raw, &length) orelse return error.QuickJsConversionFailed;
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

/// 配列/辞書/関数のObjectへQuickJS参照（external binding）を結び付ける。GCで
/// Objectが回収されるときに`releaseExternal`が1回だけRawValueを解放する。
/// 参照カウントをdupするだけでNako側の割当ては増えない。
pub fn attachExternal(value: Value, raw: *const RawValue) !void {
    const object = value.object() orelse return error.QuickJsUnsupportedValue;
    const duplicate = lnako_qjs_dup(raw) orelse return error.OutOfMemory;
    object.external = .{ .handle = @ptrCast(duplicate), .release = releaseExternal };
}

/// Objectのexternal bindingをGC sweepから解放する。
fn releaseExternal(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    if (handle) |pointer| lnako_qjs_value_free(@ptrCast(@alignCast(pointer)));
}

/// external bindingを持つNako配列/辞書/関数からJS参照をdupする。externalが
/// 無ければnullを返し、呼出し側の通常変換へ委ねる。
pub fn externalRaw(value: Value) !?*RawValue {
    switch (@as(Tag, @fromBackingInt(value.tag))) {
        .array, .dictionary, .function => {},
        else => return null,
    }
    const object = value.object() orelse return null;
    const external = object.external orelse {
        return null;
    };
    const handle = external.handle orelse return null;
    return lnako_qjs_dup(@ptrCast(@alignCast(handle))) orelse error.OutOfMemory;
}

/// refreshの失敗を、呼出し元コマンドと同じ文言でruntimeへ記録する。
pub fn reportRefreshFailure(runtime: *state.Runtime, failure: anyerror, message: []const u8) void {
    if (failure == error.QuickJsUnsupportedResult or failure == error.QuickJsUnsupportedArgument) {
        runtime.setFailureText(message);
    } else {
        setFailureUnlessReported(runtime, failure);
    }
}

fn sourceUtf8Alloc(runtime: *state.Runtime, value: Value) ![]u8 {
    const units = try state.valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return std.unicode.utf16LeToUtf8Alloc(runtime.allocator, units);
}

/// `JS実行` のdispatch。AOTからQuickJSのevalを1回呼び、Promiseならjobをdrain
/// してawaitしたうえで、interpreter と同じfull変換（プリミティブ・BigInt・
/// 関数値・配列・辞書）でNako値へ戻す。
pub export fn lnako_aot_compat_js_eval(out: *Value, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const failure_epoch_at_entry = runtime.failure_epoch;
    const trace_call_id = runtime.dispatch_trace.begin("JS実行", compat_js_eval_opcode, "JS実行", 0);
    var trace_success = false;
    defer runtime.dispatch_trace.result(trace_call_id, "JS実行", compat_js_eval_opcode, "JS実行", 0, trace_success);
    if (count == 0 or arguments == null) {
        runtime.setFailureText("JS実行 requires a source argument");
        return;
    }
    const source = sourceUtf8Alloc(runtime, arguments.?[0]) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(source);
    const engine_value = ensureEngine() catch |failure| {
        setFailureUnlessReported(runtime, failure);
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
    // interpreter の `JS実行` と同じ全変換。プリミティブと配列・辞書に加えて
    // BigInt・関数値も保持する（プリミティブ限定の変換では `[1,2,3]` や
    // 関数プロパティを持つ辞書が `QuickJsUnsupportedValue` になっていた。
    // Issue #55）。
    out.* = compat_js_result.jsEvalResult(runtime, raw) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    trace_success = runtime.failure_epoch == failure_epoch_at_entry;
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

/// `JS関数実行` の実引数として同期できない値の文言。`JS実行` の full 変換と
/// 同じく配列・辞書（ネスト・循環・疎配列）・関数値・BigInt・bytesを受け付け、
/// Promiseなど同期変換できない型だけを明示エラーにする。文言はinterpreter
/// （compat/quickjs.zig）と共通。
pub const unsupported_argument_message = "JS関数実行 does not support promises or unsupported argument types";

/// bridge由来のエラー文言を既にruntimeへ記録したことを表す内部エラー。
/// 呼出し側で再度setFailureするとQuickJSの文言が失われるため区別する。
pub const reported_engine_failure = error.QuickJsConversionReported;

pub fn primitiveRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    return switch (@as(Tag, @fromBackingInt(value.tag))) {
        .undefined => lnako_qjs_undefined(engine_value) orelse error.OutOfMemory,
        .null_value => lnako_qjs_null(engine_value) orelse error.OutOfMemory,
        .boolean => lnako_qjs_boolean(engine_value, @intFromBool(value.payload != 0)) orelse error.OutOfMemory,
        .number => lnako_qjs_number(engine_value, @bitCast(value.payload)) orelse error.OutOfMemory,
        .utf16_string, .static_utf8_string => blk: {
            // interpreterのtoRawと同じく、孤立サロゲートを置換せずWTF-8で渡す
            // （QuickJSのUTF-8デコーダはサロゲート符号点を16bit単位として受理する）。
            const units = try state.valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            const text = try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator, units);
            defer runtime.allocator.free(text);
            break :blk lnako_qjs_string(engine_value, text.ptr, text.len) orelse error.OutOfMemory;
        },
        else => error.QuickJsUnsupportedArgument,
    };
}

/// `JSオブジェクト取得` / `JSメソッド実行` のレシーバ・実引数をQuickJS値へ
/// 変換する。配列・辞書はexternal bindingの有無にかかわらず同期変換
/// （`syncValueRaw`）へ渡す。`sync.full_values` は偽のままなので、ネストした
/// 配列・辞書・関数値・Nako callbackは変換し、bytesとPromiseは従来どおり
/// 明示エラーになる。トップレベルの関数・BigInt・bytes・Promiseも
/// 引き続き許可しない（AOT/interpreter共通の意図的な制限）。
fn callArgumentRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, sync: *SyncState) !*RawValue {
    const tag = @as(Tag, @fromBackingInt(value.tag));
    return switch (tag) {
        .undefined, .null_value, .boolean, .number, .utf16_string, .static_utf8_string => primitiveRaw(runtime, engine_value, value),
        .array, .dictionary => compat_js_result.syncValueRaw(runtime, engine_value, value, sync, 0),
        else => error.QuickJsUnsupportedArgument,
    };
}

/// compat JS 呼出しの dispatch trace route 名。interpreter 経路の
/// `JS関数実行` と同じ表記にして両経路を突き合わせられるようにする。
const compat_js_route = "JS関数実行";
/// `JS関数実行` の opcode。AOT の builtin opcode 表には載らない compat 専用
/// 経路なので、dispatch trace の列を区別できる固定値を割り当てる
/// （`aot_builtin.Command` の値域外）。
const compat_js_opcode: u16 = 0xffff;
/// 4 命令を trace 上で区別するための opcode。いずれも builtin 表の外にある
/// compat 専用経路なので、`aot_builtin.Command` の値域外の固定値を割り当てる。
const compat_js_eval_opcode: u16 = 0xfffe;
const compat_js_object_get_opcode: u16 = 0xfffd;
const compat_js_method_call_opcode: u16 = 0xfffc;

/// `JS関数実行` のdispatch。interpreter/officialと同じく、第1引数が文字列なら
/// global evalで関数へ解決し、第1引数が関数値ならそれを直接呼び出す
/// （external binding付きのJS関数、またはNako関数）。第2引数が配列ならその要素を、
/// そうでなければ第2引数1個を実引数として呼び出す。`JS実行` の
/// eval/drain/await/例外経路を共有し、戻り値がPromiseなら解決値を待ってから
/// `JS実行` と同じfull変換を通す。rejectとpendingはbridgeの文言で明示エラーに
/// する。
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
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    @memcpy(rooted, arguments.?[0..count]);
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, rooted.ptr, rooted.len);
    defer runtime.popRoots(&frame);
    // 第1引数は関数名の文字列、または `JS実行` が返した JS 関数値・Nako 関数値を
    // 受理する（interpreter と同じく関数値呼出しにも対応する）。
    const first_tag = @as(Tag, @fromBackingInt(rooted[0].tag));
    if (first_tag != .function and !isStringValue(rooted[0])) {
        runtime.setFailureText("JS関数実行 requires a function name string in AOT compat mode");
        return;
    }
    // AOT dispatch trace へ compat JS 呼出しも記録する（`LNAKO_DISPATCH_TRACE`）。
    // interpreter 経路の `JS関数実行` と同じ route 名を使い、両経路の
    // dispatch 列を突き合わせられるようにする。site_id は IR の site を
    // 持たない ABI なので 0（生成コード側の site とは対応しない）。
    //
    // `command` には評価式（`source`）を入れない。ユーザーのスクリプト片が
    // trace へ漏れるうえ、trace 行は JSON をエスケープせずに組み立てるため
    // 引用符を含む式で JSON が壊れる。命令名（canonical 名）だけを記録する。
    const trace_call_id = runtime.dispatch_trace.begin(compat_js_route, compat_js_opcode, compat_js_route, 0);
    const failure_epoch_at_entry = runtime.failure_epoch;
    var trace_success = false;
    defer runtime.dispatch_trace.result(trace_call_id, compat_js_route, compat_js_opcode, compat_js_route, 0, trace_success);
    if (first_tag == .function) {
        const js_callable = externalRaw(rooted[0]) catch |failure| {
            setFailureUnlessReported(runtime, failure);
            return;
        };
        if (js_callable) |callable| {
            // `JS実行` / `JSメソッド実行` が返した JS 関数値は、文字列evalを
            // 挟まず同じ関数をそのまま呼ぶ（interpreterのcallExternalCallResult）。
            defer lnako_qjs_value_free(callable);
            const engine_value = ensureEngine() catch |failure| {
                setFailureUnlessReported(runtime, failure);
                return;
            };
            if (!invokeJsCallable(runtime, engine_value, callable, rooted, count, out)) return;
            trace_success = runtime.failure_epoch == failure_epoch_at_entry;
            return;
        }
        // external bindingの無い関数値は Nako 関数。interpreterの
        // `effects.invoke` と同じく Nako 値のまま呼び出す。
        const values = copyValues(runtime, argumentSlice(rooted, count)) catch |failure| {
            setFailureUnlessReported(runtime, failure);
            return;
        };
        defer runtime.allocator.free(values);
        var values_frame: state.RootFrame = .{};
        runtime.pushRoots(&values_frame, if (values.len == 0) null else values.ptr, values.len);
        defer runtime.popRoots(&values_frame);
        functions.lnako_aot_function_call(out, &rooted[0], if (values.len == 0) null else values.ptr, values.len);
        trace_success = runtime.failure_epoch == failure_epoch_at_entry;
        return;
    }
    // interpreterと同じく、utf16_stringの関数名はlossy変換してevalする。
    const source = state.stringUtf8Alloc(runtime, rooted[0]) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(source);
    const engine_value = ensureEngine() catch |failure| {
        setFailureUnlessReported(runtime, failure);
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
    if (!invokeJsCallable(runtime, engine_value, callable, rooted, count, out)) return;
    trace_success = runtime.failure_epoch == failure_epoch_at_entry;
}

/// `JS関数実行` の実引数スライス。第2引数が配列ならその要素、そうでなければ
/// 第2引数1個（official/interpreterと同じ。第3引数以降はsemantic層が拒否し、
/// 第2引数なしの`count == 1`は0引数呼出し）。
fn argumentSlice(values: []const Value, count: usize) []const Value {
    if (count >= 2) {
        if (arrayItems(values[1])) |items| return items;
    }
    return values[1..@min(count, 2)];
}

/// JS関数を実引数付きで呼び出し、`JS関数実行` の戻り値規則（Promiseのawaitと
/// `JS実行` と同じfull変換）で`out`へ格納する。実引数もfull変換（BigInt・
/// 関数値・ネスト/循環/疎配列・bytes）でJSへ渡す。失敗時はruntimeへ文言を
/// 記録してfalseを返す（呼出し側はtraceの成否だけを確定すればよい）。
fn invokeJsCallable(
    runtime: *state.Runtime,
    engine_value: *Engine,
    callable: *const RawValue,
    rooted: []const Value,
    count: usize,
    out: *Value,
) bool {
    // 呼出し後のrefreshは実引数コンテナ自身のpayloadを差し替え得るため、
    // values（コンテナのArrayListバッファを指す）をrootedなローカルへ複製する。
    const values = copyValues(runtime, argumentSlice(rooted, count)) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return false;
    };
    defer runtime.allocator.free(values);
    var values_frame: state.RootFrame = .{};
    runtime.pushRoots(&values_frame, if (values.len == 0) null else values.ptr, values.len);
    defer runtime.popRoots(&values_frame);
    // bridgeが返すRawValueはQuickJSの参照カウントで保持され、他のJS値割当てを
    // またいでも有効。lnako_qjs_value_freeまで明示的に解放しない。
    var sync = SyncState{ .full_values = true };
    defer sync.deinit(runtime.allocator);
    const raw_arguments = runtime.allocator.alloc(*const RawValue, values.len) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return false;
    };
    var initialized: usize = 0;
    defer {
        for (raw_arguments[0..initialized]) |raw| lnako_qjs_value_free(@constCast(raw));
        runtime.allocator.free(raw_arguments);
    }
    for (values, 0..) |value, index| {
        raw_arguments[index] = compat_js_result.syncValueRaw(runtime, engine_value, value, &sync, 0) catch |failure| {
            // 未対応型は共通文言、ネスト過深・巨大配列はエラー名を保持する
            // （externalCall / hostInvokeと同じ規則）。
            reportUnsupported(runtime, failure, unsupported_argument_message);
            return false;
        };
        initialized += 1;
    }
    // 空配列はゼロ長allocのptrをC ABIへ渡さずnullにする（count=0で参照されない）。
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    var raw = lnako_qjs_call(engine_value, callable, raw_pointer, raw_arguments.len) orelse {
        const saved_error = lnako_qjs_take_error(engine_value);
        for (values, raw_arguments[0..initialized]) |value, argument_raw| {
            compat_js_result.refreshFromRaw(runtime, value, @constCast(argument_raw)) catch {};
        }
        if (saved_error) |text| {
            defer lnako_qjs_free_string(text);
            runtime.setFailureText(std.mem.span(text));
        } else fail(runtime, engine_value);
        return false;
    };
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(raw);
        fail(runtime, engine_value);
        return false;
    }
    // `JS実行` と同じく、戻り値がPromiseなら解決値を待つ。rejectはbridgeが
    // reject理由を、pendingは "QuickJS promise is still pending" をlast_errorへ
    // 記録するため、`fail` で明示エラーになる（無限待機しない）。
    if (lnako_qjs_kind(raw) == .promise) {
        const awaited = lnako_qjs_await(engine_value, raw);
        lnako_qjs_value_free(raw);
        raw = awaited orelse {
            fail(runtime, engine_value);
            return false;
        };
    }
    // interpreterと同じく、呼出し後にJS側の内容で実引数を再同期する。
    for (values, raw_arguments[0..initialized]) |value, argument_raw| {
        compat_js_result.refreshFromRaw(runtime, value, @constCast(argument_raw)) catch |failure| {
            lnako_qjs_value_free(raw);
            reportRefreshFailure(runtime, failure, unsupported_argument_message);
            return false;
        };
    }
    // `JS実行` と同じfull変換。rawは成功・失敗にかかわらず消費して解放する。
    out.* = compat_js_result.jsEvalResult(runtime, raw) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return false;
    };
    return true;
}

/// `JSオブジェクト取得` / `JSメソッド実行` で、変換できない値に使う文言。
/// interpreter（compat/quickjs.zig）と同じ文言にしてAOT/インタプリタを一致させる。
const unsupported_object_get_message = "JSオブジェクト取得 does not support promises, functions, bigint, or bytes yet";
const unsupported_method_message = "JSメソッド実行 does not support promises, functions, bigint, or bytes yet";

/// 実引数スライスをruntime.allocatorへ複製する。呼出し後のrefreshがコンテナの
/// payloadをswapしても、イテレーション中の値がGCで回収されるのを防ぐ。
fn copyValues(runtime: *state.Runtime, source: []const Value) ![]Value {
    const values = try runtime.allocator.alloc(Value, source.len);
    @memcpy(values, source);
    return values;
}

/// レシーバ値からJS値を得る。external binding付きの配列/辞書は同じJS参照を
/// dupし、無い値は共有変換規則（プリミティブ＋再帰変換する配列/辞書）でJSコピーを作る。
/// `eval_string` が真（`JSメソッド実行`）のときだけ、文字列をJSソースとして評価する
/// （interpreter/officialの既存経路）。`JSオブジェクト取得` は文字列をJSの
/// プリミティブとして扱う（"abc"の"0"は"a"）。
fn receiverRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, eval_string: bool, sync: *SyncState) !*RawValue {
    if (eval_string and isStringValue(value)) {
        const source = state.stringUtf8Alloc(runtime, value) catch |failure| return failure;
        defer runtime.allocator.free(source);
        return lnako_qjs_eval(engine_value, source.ptr, source.len, "<JSメソッド実行>") orelse {
            fail(runtime, engine_value);
            return reported_engine_failure;
        };
    }
    return callArgumentRaw(runtime, engine_value, value, sync);
}

/// プロパティ名/メソッド名をNUL終端のlossy UTF-8へ変換する。interpreterの
/// `common.toUtf8Alloc`（toUtf8Lossy）と同じく、孤立サロゲートは置換して
/// AOT/interpreterで同じlookupにする。
fn propertyNameZ(runtime: *state.Runtime, value: Value) ![:0]u8 {
    const units = try state.valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const wtf8 = try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator, units);
    defer runtime.allocator.free(wtf8);
    return std.unicode.wtf8ToUtf8LossyAllocZ(runtime.allocator, wtf8);
}

fn rootedArguments(runtime: *state.Runtime, arguments: ?[*]const Value, count: usize, frame: *state.RootFrame) ![]Value {
    const rooted = try runtime.allocator.alloc(Value, count);
    errdefer runtime.allocator.free(rooted);
    @memcpy(rooted, arguments.?[0..count]);
    runtime.pushRoots(frame, rooted.ptr, rooted.len);
    return rooted;
}

/// QuickJS の例外文言を既に runtime へ記録した `reported_engine_failure` を
/// 再記録しない。ここで `setFailure` すると内部エラー名
/// （`QuickJsConversionReported`）で元のJS例外が上書きされる。
pub fn setFailureUnlessReported(runtime: *state.Runtime, failure: anyerror) void {
    if (failure != reported_engine_failure) runtime.setFailure(failure);
}

pub fn reportUnsupported(runtime: *state.Runtime, failure: anyerror, message: []const u8) void {
    if (failure == error.QuickJsUnsupportedArgument or failure == error.QuickJsUnsupportedResult) {
        runtime.setFailureText(message);
    } else {
        setFailureUnlessReported(runtime, failure);
    }
}

/// `--compat-js` AOTの `JSオブジェクト取得(obj, key)`。lnako拡張の2引数形で、
/// external bindingのJS参照（または共有変換規則で作ったJSコピー）のプロパティを
/// 取得する。戻り値はプリミティブに加えて配列/辞書を再帰変換し、各配列/辞書へ
/// external bindingを付与する（Promise・関数・BigInt・bytesは明示エラー）。
/// 1引数形（公式のグローバル名解決）はAOTに変数bridgeが無いため明示エラーにする。
pub export fn lnako_aot_compat_js_object_get(out: *Value, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const failure_epoch_at_entry = runtime.failure_epoch;
    const trace_call_id = runtime.dispatch_trace.begin("JSオブジェクト取得", compat_js_object_get_opcode, "JSオブジェクト取得", 0);
    var trace_success = false;
    defer runtime.dispatch_trace.result(trace_call_id, "JSオブジェクト取得", compat_js_object_get_opcode, "JSオブジェクト取得", 0, trace_success);
    if (count < 2 or arguments == null) {
        runtime.setFailureText("JSオブジェクト取得 requires a value and a property name");
        return;
    }
    if (count > 2) {
        runtime.setFailureText("JSオブジェクト取得 accepts a value and a property name only");
        return;
    }
    var frame: state.RootFrame = .{};
    const rooted = rootedArguments(runtime, arguments, count, &frame) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    defer runtime.popRoots(&frame);
    const engine_value = ensureEngine() catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    var sync = SyncState{};
    defer sync.deinit(runtime.allocator);
    const raw_object = receiverRaw(runtime, engine_value, rooted[0], false, &sync) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_object_get_message);
        return;
    };
    defer lnako_qjs_value_free(raw_object);
    const name = propertyNameZ(runtime, rooted[1]) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(name);
    const result = lnako_qjs_get_property(raw_object, name.ptr) orelse {
        fail(runtime, engine_value);
        return;
    };
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(result);
        fail(runtime, engine_value);
        return;
    }
    // getter/jobがレシーバを変更した場合に備え、取得後もNakoコピーを再同期する。
    compat_js_result.refreshFromRaw(runtime, rooted[0], raw_object) catch |failure| {
        lnako_qjs_value_free(result);
        reportRefreshFailure(runtime, failure, unsupported_object_get_message);
        return;
    };
    out.* = compat_js_result.resultFromRaw(runtime, result) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_object_get_message);
        return;
    };
    trace_success = runtime.failure_epoch == failure_epoch_at_entry;
}

/// `--compat-js` AOTの `JSメソッド実行(obj, method, args)` 最小dispatch。
/// objが文字列ならJSソースとして評価し、external bindingがあれば同じJS参照を
/// 使い、無ければ共有変換規則でJSコピーを作る。argsは第3引数が配列ならその要素、
/// そうでなければ単一実引数（`JS関数実行` と同じ規則）。戻り値はプリミティブに
/// 加えて配列/辞書を再帰変換し、各配列/辞書へexternal bindingを付与する
/// （Promise・関数・BigInt・bytesは明示エラー）。
pub export fn lnako_aot_compat_js_method_call(out: *Value, arguments: ?[*]const Value, count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const failure_epoch_at_entry = runtime.failure_epoch;
    const trace_call_id = runtime.dispatch_trace.begin("JSメソッド実行", compat_js_method_call_opcode, "JSメソッド実行", 0);
    var trace_success = false;
    defer runtime.dispatch_trace.result(trace_call_id, "JSメソッド実行", compat_js_method_call_opcode, "JSメソッド実行", 0, trace_success);
    if (count < 2 or arguments == null) {
        runtime.setFailureText("JSメソッド実行 requires an object and a method name in AOT compat mode");
        return;
    }
    var frame: state.RootFrame = .{};
    const rooted = rootedArguments(runtime, arguments, count, &frame) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    defer runtime.popRoots(&frame);
    const engine_value = ensureEngine() catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    var sync = SyncState{};
    defer sync.deinit(runtime.allocator);
    const raw_object = receiverRaw(runtime, engine_value, rooted[0], true, &sync) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_method_message);
        return;
    };
    defer lnako_qjs_value_free(raw_object);
    const method = propertyNameZ(runtime, rooted[1]) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(method);
    const values_source: []const Value = blk: {
        if (count >= 3) {
            if (arrayItems(rooted[2])) |items| break :blk items;
        }
        break :blk rooted[2..@min(count, 3)];
    };
    // refreshは実引数コンテナのpayloadを差し替え得るため、valuesを複製してrootする。
    const values = copyValues(runtime, values_source) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer runtime.allocator.free(values);
    var values_frame: state.RootFrame = .{};
    runtime.pushRoots(&values_frame, if (values.len == 0) null else values.ptr, values.len);
    defer runtime.popRoots(&values_frame);
    const raw_arguments = runtime.allocator.alloc(*const RawValue, values.len) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    var initialized: usize = 0;
    defer {
        for (raw_arguments[0..initialized]) |raw| lnako_qjs_value_free(@constCast(raw));
        runtime.allocator.free(raw_arguments);
    }
    for (values, 0..) |value, index| {
        raw_arguments[index] = callArgumentRaw(runtime, engine_value, value, &sync) catch |failure| {
            reportUnsupported(runtime, failure, unsupported_method_message);
            return;
        };
        initialized += 1;
    }
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    const call_result = lnako_qjs_call_method(engine_value, raw_object, method.ptr, raw_pointer, raw_arguments.len);
    if (call_result == null) {
        // 失敗しても呼出し途中のJS側変更をNakoへ反映する。refreshがlast_errorを
        // 上書きし得るため、元の例外文言を保存してから復元する。
        const saved_error = lnako_qjs_take_error(engine_value);
        compat_js_result.refreshFromRaw(runtime, rooted[0], raw_object) catch {};
        for (values, raw_arguments[0..initialized]) |value, argument_raw| {
            compat_js_result.refreshFromRaw(runtime, value, @constCast(argument_raw)) catch {};
        }
        if (saved_error) |text| {
            defer lnako_qjs_free_string(text);
            runtime.setFailureText(std.mem.span(text));
        } else fail(runtime, engine_value);
        return;
    }
    const result = call_result.?;
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(result);
        fail(runtime, engine_value);
        return;
    }
    // interpreterと同じく、呼出し後にJS側の内容で値（レシーバと実引数）を
    // 再同期する。JS側の変更を次の呼出しで古いNako内容が上書きしないようにする。
    compat_js_result.refreshFromRaw(runtime, rooted[0], raw_object) catch |failure| {
        lnako_qjs_value_free(result);
        reportRefreshFailure(runtime, failure, unsupported_method_message);
        return;
    };
    for (values, raw_arguments[0..initialized]) |value, argument_raw| {
        compat_js_result.refreshFromRaw(runtime, value, @constCast(argument_raw)) catch |failure| {
            lnako_qjs_value_free(result);
            reportRefreshFailure(runtime, failure, unsupported_method_message);
            return;
        };
    }
    out.* = compat_js_result.resultFromRaw(runtime, result) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_method_message);
        return;
    };
    trace_success = runtime.failure_epoch == failure_epoch_at_entry;
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

/// 生成物へ収録したESM manifestをQuickJSへ登録し、module を AOT runtime へ
/// 引き継ぐ（埋め込み interpreter の `installModules` が plugin 命令を登録
/// するため）。schema 2 の object と旧形式の配列を受理する。`packages` は
/// 自己記述（SBOM/監査用）で実行時登録には使わない。
pub export fn lnako_aot_compat_esm_register(manifest: ?[*]const u8, length: usize) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    const bytes = if (manifest) |pointer| pointer[0..length] else return;
    if (bytes.len == 0) return;
    const engine_value = ensureEngine() catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, bytes, .{}) catch |failure| {
        setFailureUnlessReported(runtime, failure);
        return;
    };
    defer parsed.deinit();
    const modules = switch (parsed.value) {
        .array => |array| array.items,
        .object => |object| modules_of: {
            // schema 2 の object manifest。未知の schema は module 形が変わり
            // 得るため黙って解釈せず失敗させる（schema 欠落は旧手書き
            // manifest 互換のため schema 2 とみなす）。
            if (object.get("schema")) |schema| {
                if (schema != .integer or schema.integer != 2) {
                    runtime.setFailureText("unsupported compat ESM manifest schema");
                    return;
                }
            }
            const modules_value = object.get("modules") orelse {
                runtime.setFailureText("compat ESM manifest has no modules");
                return;
            };
            break :modules_of switch (modules_value) {
                .array => |array| array.items,
                else => {
                    runtime.setFailureText("compat ESM manifest modules is not an array");
                    return;
                },
            };
        },
        else => {
            runtime.setFailureText("compat ESM manifest is not an array or object");
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
            setFailureUnlessReported(runtime, failure);
            return;
        };
        defer runtime.allocator.free(path_z);
        const package_root = jsonString(object.get("package_root"));
        const root_z = if (package_root) |root| dupeModuleName(runtime, root) catch |failure| {
            setFailureUnlessReported(runtime, failure);
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
                setFailureUnlessReported(runtime, failure);
                return;
            };
            defer runtime.allocator.free(alias_z);
            if (lnako_qjs_add_module_alias(engine_value, alias_z.ptr, path_z.ptr) < 0) {
                fail(runtime, engine_value);
                return;
            }
        }
    }
    esm_manifest.collectEsmModules(runtime, modules);
}

/// プロセス終了時にQuickJS engineを解放する。生成物のmainがruntime deinitの
/// 直前に呼ぶ。
pub export fn lnako_aot_compat_deinit() callconv(.c) void {
    // runtime.deinit() が先でも後でも、GC hook と host 関数テーブルを確実に
    // 解除してから engine を解放する。
    if (host_runtime) |runtime| {
        runtime.compat_trace = null;
        runtime.compat_deinit = null;
    }
    deinitHostFunctions();
    if (engine) |value| {
        lnako_qjs_release(value);
        engine = null;
    }
}

test {
    _ = @import("compat_js_test.zig");
}
