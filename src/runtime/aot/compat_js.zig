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
const Keys = opaque {};

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
extern fn lnako_qjs_call_method(engine: *Engine, object: *const RawValue, name: [*:0]const u8, arguments: [*c]const *const RawValue, count: usize) ?*RawValue;
extern fn lnako_qjs_dup(value: *const RawValue) ?*RawValue;
extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
extern fn lnako_qjs_undefined(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_null(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_boolean(engine: *Engine, value: c_int) ?*RawValue;
extern fn lnako_qjs_number(engine: *Engine, value: f64) ?*RawValue;
extern fn lnako_qjs_string(engine: *Engine, value: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_array(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_object(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_set_index(value: *RawValue, index: u32, item: *const RawValue) c_int;
extern fn lnako_qjs_set_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
extern fn lnako_qjs_array_length(value: *const RawValue) u32;
extern fn lnako_qjs_get_index(value: *const RawValue, index: u32) ?*RawValue;
extern fn lnako_qjs_get_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_set_array_length(value: *RawValue, length: u32) c_int;
extern fn lnako_qjs_clear_properties(value: *RawValue) c_int;
extern fn lnako_qjs_identity(value: *const RawValue) usize;
extern fn lnako_qjs_keys(value: *const RawValue) ?*Keys;
extern fn lnako_qjs_keys_length(keys: *const Keys) usize;
extern fn lnako_qjs_key(keys: *const Keys, index: usize, length: *usize) ?[*]const u8;
extern fn lnako_qjs_keys_free(keys: *Keys) void;
extern fn lnako_qjs_is_bytes(value: *const RawValue) c_int;
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

/// プリミティブだけをNako値へ変換する。rawは呼出し側が所有権を保持し、ここでは
/// 解放しない（`fromRaw` と `callResultFromRaw` で解放方針が異なるため）。
fn primitiveFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
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

/// `JS実行` の戻り値変換。プリミティブだけを許可し、rawを消費して解放する。
fn fromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer lnako_qjs_value_free(raw);
    return primitiveFromRaw(runtime, raw);
}

/// `JS関数実行` の戻り値をNako値へ変換する。プリミティブに加えて、JS配列→
/// Nako配列・JSオブジェクト→Nako辞書の浅いコピーだけを許可する。要素/値は
/// プリミティブに限り、ネストした配列/辞書・関数・BigInt・bytesは
/// interpreter（compat/quickjs.zig）と同じ文言の明示的な未対応エラーにする。
/// Promiseは呼出し側（`lnako_aot_compat_js_call`）がawaitしてから渡す。
/// 配列/辞書にはQuickJS参照のexternal bindingを結び付け、`JSオブジェクト取得`
/// と`JSメソッド実行`が同じJSオブジェクトを参照できるようにする。
/// rawは成功・失敗にかかわらず消費して解放する。
fn callResultFromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer lnako_qjs_value_free(raw);
    return switch (lnako_qjs_kind(raw)) {
        .undefined, .null_value, .boolean, .number, .string => primitiveFromRaw(runtime, raw),
        .array => blk: {
            const value = try shallowArrayFromRaw(runtime, raw);
            try attachExternal(value, raw);
            break :blk value;
        },
        .object => blk: {
            if (lnako_qjs_is_bytes(raw) != 0) return error.QuickJsUnsupportedResult;
            const value = try shallowDictionaryFromRaw(runtime, raw);
            try attachExternal(value, raw);
            break :blk value;
        },
        else => error.QuickJsUnsupportedResult,
    };
}

/// 配列/辞書のObjectへQuickJS参照（external binding）を結び付ける。GCで
/// Objectが回収されるときに`releaseExternal`が1回だけRawValueを解放する。
/// 参照カウントをdupするだけでNako側の割当ては増えない。
fn attachExternal(value: Value, raw: *const RawValue) !void {
    const object = value.object() orelse return error.QuickJsUnsupportedValue;
    const duplicate = lnako_qjs_dup(raw) orelse return error.OutOfMemory;
    object.external = .{ .handle = @ptrCast(duplicate), .release = releaseExternal };
}

/// Objectのexternal bindingをGC sweepから解放する。
fn releaseExternal(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    if (handle) |pointer| lnako_qjs_value_free(@ptrCast(@alignCast(pointer)));
}

/// external bindingを持つNako配列/辞書からJS参照をdupする。externalが無ければ
/// nullを返し、呼出し側の通常変換へ委ねる。
fn externalRaw(value: Value) !?*RawValue {
    switch (@as(Tag, @fromBackingInt(value.tag))) {
        .array, .dictionary => {},
        else => return null,
    }
    const object = value.object() orelse return null;
    const external = object.external orelse return null;
    const handle = external.handle orelse return null;
    return lnako_qjs_dup(@ptrCast(@alignCast(handle))) orelse error.OutOfMemory;
}

/// external値のNako側の内容をJSオブジェクトへ書き戻す（interpreterの
/// `syncExternal`と同じ意味）。外部参照の子要素は同じJS参照をdupし、externalを
/// 持たない入れ子の配列・辞書は再帰的にJSコピーを作る。Nako側の循環参照は
/// `in_progress`（Nako Object pointer → 生成中のJS参照）で止める。
/// 関数・BigInt・bytesは書き戻せないため`error.QuickJsUnsupportedArgument`にする。
const SyncState = struct {
    in_progress: std.AutoHashMapUnmanaged(usize, *RawValue) = .empty,
};

fn syncExternalRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, raw: *RawValue) anyerror!void {
    var sync = SyncState{};
    defer sync.in_progress.deinit(runtime.allocator);
    const object = value.object() orelse return;
    try sync.in_progress.put(runtime.allocator, @intFromPtr(object), raw);
    defer _ = sync.in_progress.remove(@intFromPtr(object));
    try syncContents(runtime, engine_value, value, raw, &sync);
}

fn syncContents(runtime: *state.Runtime, engine_value: *Engine, value: Value, raw: *RawValue, sync: *SyncState) anyerror!void {
    switch (@as(Tag, @fromBackingInt(value.tag))) {
        .array => {
            const object = value.object() orelse return;
            const items = object.payload.array.items;
            if (items.len > std.math.maxInt(u32)) return error.QuickJsCollectionTooLarge;
            if (lnako_qjs_set_array_length(raw, @intCast(items.len)) < 0) {
                fail(runtime, engine_value);
                return reported_engine_failure;
            }
            for (items, 0..) |item, index| {
                const item_raw = try syncValueRaw(runtime, engine_value, item, sync);
                defer lnako_qjs_value_free(item_raw);
                if (lnako_qjs_set_index(raw, @intCast(index), item_raw) < 0) {
                    fail(runtime, engine_value);
                    return reported_engine_failure;
                }
            }
        },
        .dictionary => {
            const object = value.object() orelse return;
            if (lnako_qjs_clear_properties(raw) < 0) {
                fail(runtime, engine_value);
                return reported_engine_failure;
            }
            for (object.payload.dictionary.entries.items) |entry| {
                const name = try dictionaryKeyNameZ(runtime, entry.key);
                defer runtime.allocator.free(name);
                const item_raw = try syncValueRaw(runtime, engine_value, entry.value, sync);
                defer lnako_qjs_value_free(item_raw);
                if (lnako_qjs_set_property(raw, name.ptr, item_raw) < 0) {
                    fail(runtime, engine_value);
                    return reported_engine_failure;
                }
            }
        },
        else => {},
    }
}

/// 同期用のJS値変換。external参照はdupし、externalを持たない配列・辞書は
/// 新しいJS配列/オブジェクトへ再帰変換する（interpreterのtoRaw相当）。
/// 変換できない値（関数・BigInt・bytes・Promise）は明示エラーにする。
fn syncValueRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, sync: *SyncState) anyerror!*RawValue {
    const tag = @as(Tag, @fromBackingInt(value.tag));
    if (tag != .array and tag != .dictionary) return primitiveRaw(runtime, engine_value, value);
    const object = value.object() orelse return error.QuickJsUnsupportedArgument;
    const identity = @intFromPtr(object);
    if (sync.in_progress.get(identity)) |existing| return lnako_qjs_dup(existing) orelse error.OutOfMemory;
    const raw = if (try externalRaw(value)) |external|
        external
    else switch (tag) {
        .array => lnako_qjs_array(engine_value) orelse return error.OutOfMemory,
        .dictionary => lnako_qjs_object(engine_value) orelse return error.OutOfMemory,
        else => unreachable,
    };
    errdefer lnako_qjs_value_free(raw);
    try sync.in_progress.put(runtime.allocator, identity, raw);
    defer _ = sync.in_progress.remove(identity);
    try syncContents(runtime, engine_value, value, raw, sync);
    return raw;
}

/// JS値でNako側コピーを再構築する（interpreterの`refreshExternal`相当）。
/// JS側でメソッドが実引数/レシーバの配列・辞書を変更した場合に、次の呼出しで
/// 古いNako内容を書き戻してしまうのを防ぐ。external bindingの有無にかかわらず、
/// 呼出し時に作ったJS値（externalなら同じJS参照のdup、plainならJSコピー）から
/// 再構築する。途中で変換に失敗しても元の内容を失わないよう、まず一時的な
/// 配列/辞書へ構築し、成功後に中身だけ差し替える（Nako Objectの同一性は保つ）。
fn refreshFromRaw(runtime: *state.Runtime, value: Value, raw: *RawValue) anyerror!void {
    const tag = @as(Tag, @fromBackingInt(value.tag));
    if (tag != .array and tag != .dictionary) return;
    const object = value.object() orelse return;
    if (lnako_qjs_identity(raw) == 0) return;
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    try seen.put(runtime.allocator, lnako_qjs_identity(raw), value);
    switch (tag) {
        .array => {
            const length = lnako_qjs_array_length(raw);
            if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
            var fresh = try runtime.createArray(&.{});
            var fresh_frame: state.RootFrame = .{};
            runtime.pushRoots(&fresh_frame, @ptrCast(&fresh), 1);
            defer runtime.popRoots(&fresh_frame);
            const fresh_object = fresh.object() orelse return error.QuickJsConversionFailed;
            for (0..length) |index| {
                const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
                try appendRefreshedItem(runtime, fresh_object, item, &seen);
            }
            std.mem.swap(std.ArrayList(Value), &object.payload.array, &fresh_object.payload.array);
            std.mem.swap(std.ArrayList(bool), &object.array_presence, &fresh_object.array_presence);
        },
        .dictionary => {
            const keys = lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
            defer lnako_qjs_keys_free(keys);
            const count = lnako_qjs_keys_length(keys);
            if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
            var fresh = try runtime.createDictionary(&.{});
            var fresh_frame: state.RootFrame = .{};
            runtime.pushRoots(&fresh_frame, @ptrCast(&fresh), 1);
            defer runtime.popRoots(&fresh_frame);
            const fresh_object = fresh.object() orelse return error.QuickJsConversionFailed;
            for (0..count) |index| {
                var name_length: usize = 0;
                const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
                const name = name_pointer[0..name_length];
                const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
                defer runtime.allocator.free(name_z);
                const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
                try setRefreshedEntry(runtime, fresh_object, name, item, &seen);
            }
            std.mem.swap(state.AotDictionary, &object.payload.dictionary, &fresh_object.payload.dictionary);
        },
        else => {},
    }
}

fn appendRefreshedItem(runtime: *state.Runtime, object: *state.Object, item: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) !void {
    var roots = [_]Value{try convertResult(runtime, item, seen)};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try runtime.aotArrayAppend(object, roots[0]);
}

fn setRefreshedEntry(runtime: *state.Runtime, object: *state.Object, name: []const u8, item: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) !void {
    var roots = [_]Value{ try wtf8Value(runtime, name), .{} };
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try convertResult(runtime, item, seen);
    try runtime.setDictionary(&object.payload.dictionary, roots[0], roots[1]);
}

/// refreshの失敗を、呼出し元コマンドと同じ文言でruntimeへ記録する。
fn reportRefreshFailure(runtime: *state.Runtime, failure: anyerror, message: []const u8) void {
    if (failure == error.QuickJsUnsupportedResult or failure == error.QuickJsUnsupportedArgument) {
        runtime.setFailureText(message);
    } else if (failure != reported_engine_failure) {
        runtime.setFailure(failure);
    }
}

/// `JSオブジェクト取得` / `JSメソッド実行` の戻り値変換。`JS関数実行` の浅い
/// 規則（`callResultFromRaw`）と違い、配列/辞書は再帰的に変換し、各配列/辞書へ
/// external bindingを付与する。関数・BigInt・bytesはAOTに値の生成経路が無いため
/// 明示的な未対応エラーにする（interpreterは関数/BigIntを変換できるが、最小
/// dispatchの範囲外としてfollow-up）。rawは消費して解放する。
fn resultFromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    return convertResult(runtime, raw, &seen);
}

fn convertResult(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) anyerror!Value {
    defer lnako_qjs_value_free(raw);
    return switch (lnako_qjs_kind(raw)) {
        .undefined, .null_value, .boolean, .number, .string => primitiveFromRaw(runtime, raw),
        .array => convertResultArray(runtime, raw, seen),
        .object => blk: {
            if (lnako_qjs_is_bytes(raw) != 0) return error.QuickJsUnsupportedResult;
            break :blk convertResultDictionary(runtime, raw, seen);
        },
        else => error.QuickJsUnsupportedResult,
    };
}

fn convertResultArray(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) anyerror!Value {
    const identity = lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const length = lnako_qjs_array_length(raw);
    if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    // 空配列を先に作り、埋める前にseenへ登録する。自己参照配列は同じObjectを
    // 指すため、interpreterのconvertArrayと同じ循環表現になる。
    var result = try runtime.createArray(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    const object = result.object() orelse return error.QuickJsConversionFailed;
    for (0..length) |index| {
        const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
        var roots = [_]Value{.{}};
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[0] = try convertResult(runtime, item, seen);
        try runtime.aotArrayAppend(object, roots[0]);
    }
    try attachExternal(result, raw);
    return result;
}

fn convertResultDictionary(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) anyerror!Value {
    const identity = lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const keys = lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
    defer lnako_qjs_keys_free(keys);
    const count = lnako_qjs_keys_length(keys);
    if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    var result = try runtime.createDictionary(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    for (0..count) |index| {
        var name_length: usize = 0;
        const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
        defer runtime.allocator.free(name_z);
        const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
        // キー文字列を先に作ってrootし、値の変換でGCが走っても回収されないようにする。
        var roots = [_]Value{ try wtf8Value(runtime, name), .{} };
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[1] = try convertResult(runtime, item, seen);
        try runtime.setDictionary(&result.object().?.payload.dictionary, roots[0], roots[1]);
    }
    try attachExternal(result, raw);
    return result;
}

/// 浅いコピーの要素/値。プリミティブ以外は明示的な未対応エラーにする。
fn shallowResultElement(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer lnako_qjs_value_free(raw);
    return primitiveFromRaw(runtime, raw) catch |failure| switch (failure) {
        error.QuickJsUnsupportedValue => error.QuickJsUnsupportedResult,
        else => failure,
    };
}

fn wtf8Value(runtime: *state.Runtime, text: []const u8) !Value {
    const units = try std.unicode.wtf8ToWtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

fn shallowArrayFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
    const length = lnako_qjs_array_length(raw);
    // `length = 0xFFFFFFFF` のような疎配列で数十GBを一括確保しないよう、
    // AOTの配列上限と同じ制限を浅いコピーにも適用する。
    if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    const items = try runtime.allocator.alloc(Value, length);
    defer runtime.allocator.free(items);
    @memset(items, .{});
    // 変換中の要素をGC rootへ載せる。空配列はalloc(0)のptrをrootへ渡さない。
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, if (length == 0) null else items.ptr, length);
    defer runtime.popRoots(&frame);
    for (0..length) |index| {
        const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
        items[index] = try shallowResultElement(runtime, item);
    }
    return runtime.createArray(items);
}

fn shallowDictionaryFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
    const keys = lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
    defer lnako_qjs_keys_free(keys);
    const count = lnako_qjs_keys_length(keys);
    if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    const pair_length = std.math.mul(usize, count, 2) catch return error.QuickJsCollectionTooLarge;
    const pairs = try runtime.allocator.alloc(Value, pair_length);
    defer runtime.allocator.free(pairs);
    @memset(pairs, .{});
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, if (pair_length == 0) null else pairs.ptr, pair_length);
    defer runtime.popRoots(&frame);
    var initialized: usize = 0;
    for (0..count) |index| {
        var name_length: usize = 0;
        const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
        defer runtime.allocator.free(name_z);
        const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
        // 要素値を先に作ってpairs（root frame）へ載せ、その後キー文字列を作る。
        // 逆順だとキー生成中のGCで要素値が未rootのまま回収され得る。
        pairs[initialized + 1] = try shallowResultElement(runtime, item);
        pairs[initialized] = try wtf8Value(runtime, name);
        initialized += 2;
    }
    return runtime.createDictionary(pairs[0..initialized]);
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

/// `JS関数実行` の実引数をQuickJS値へ変換する。最小スライスでは数値・文字列・
/// 真偽値・null/undefinedに加えて、Nako配列→JS配列・辞書→JSオブジェクトの
/// 浅いコピーだけを許可する。ネストした配列/辞書・関数・BigInt・bytes・
/// Promiseは呼び出し前に明示的な未対応エラーにする（Nako側の文字列化へ
/// 逃がさない）。文言はinterpreter（compat/quickjs.zig）と共通。
const unsupported_argument_message = "JS関数実行 does not support nested arrays or dictionaries, functions, bigint, or bytes arguments yet";

/// `JS関数実行` の戻り値が浅い配列/辞書へ変換できないときの文言。
/// interpreter（compat/quickjs.zig）と同じ文言で失敗させる。
const unsupported_result_message = "JS関数実行 does not support nested arrays or dictionaries, functions, bigint, or bytes results yet";

/// bridge由来のエラー文言を既にruntimeへ記録したことを表す内部エラー。
/// 呼出し側で再度setFailureするとQuickJSの文言が失われるため区別する。
const reported_engine_failure = error.QuickJsConversionReported;

fn isPrimitiveTag(tag: Tag) bool {
    return switch (tag) {
        .undefined, .null_value, .boolean, .number, .utf16_string, .static_utf8_string => true,
        else => false,
    };
}

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

/// 浅いコピーの要素（配列の要素・辞書の値）はプリミティブだけを許可する。
fn shallowArgumentRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    if (!isPrimitiveTag(@as(Tag, @fromBackingInt(value.tag)))) return error.QuickJsUnsupportedArgument;
    return primitiveRaw(runtime, engine_value, value);
}

fn arrayArgumentRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    const items = arrayItems(value) orelse return error.QuickJsUnsupportedArgument;
    if (items.len > std.math.maxInt(u32)) return error.QuickJsCollectionTooLarge;
    const result = lnako_qjs_array(engine_value) orelse return error.OutOfMemory;
    errdefer lnako_qjs_value_free(result);
    for (items, 0..) |item, index| {
        const raw = try shallowArgumentRaw(runtime, engine_value, item);
        defer lnako_qjs_value_free(raw);
        if (lnako_qjs_set_index(result, @intCast(index), raw) < 0) {
            fail(runtime, engine_value);
            return reported_engine_failure;
        }
    }
    return result;
}

fn dictionaryEntries(value: Value) ?[]const state.DictionaryEntry {
    if (@as(Tag, @fromBackingInt(value.tag)) != .dictionary) return null;
    const object = value.object() orelse return null;
    return object.payload.dictionary.entries.items;
}

/// `lnako_qjs_set_property` はNUL終端の名前を取る。interpreterのtoRawと同じく
/// 辞書キーをlossy UTF-8へ変換する（辞書キーは通常は文字列）。
fn dictionaryKeyNameZ(runtime: *state.Runtime, key: Value) ![:0]u8 {
    const text = switch (@as(Tag, @fromBackingInt(key.tag))) {
        .utf16_string, .static_utf8_string => try state.stringUtf8Alloc(runtime, key),
        else => blk: {
            const units = try state.valueUtf16Alloc(runtime, key);
            defer runtime.allocator.free(units);
            break :blk try std.unicode.utf16LeToUtf8Alloc(runtime.allocator, units);
        },
    };
    defer runtime.allocator.free(text);
    return runtime.allocator.dupeSentinel(u8, text, 0);
}

fn dictionaryArgumentRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    const entries = dictionaryEntries(value) orelse return error.QuickJsUnsupportedArgument;
    const result = lnako_qjs_object(engine_value) orelse return error.OutOfMemory;
    errdefer lnako_qjs_value_free(result);
    for (entries) |entry| {
        const name = try dictionaryKeyNameZ(runtime, entry.key);
        defer runtime.allocator.free(name);
        const raw = try shallowArgumentRaw(runtime, engine_value, entry.value);
        defer lnako_qjs_value_free(raw);
        if (lnako_qjs_set_property(result, name.ptr, raw) < 0) {
            fail(runtime, engine_value);
            return reported_engine_failure;
        }
    }
    return result;
}

fn callArgumentRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) !*RawValue {
    // JS由来のexternal bindingは、要素を再構築せず同じJSオブジェクトを渡す。
    // interpreterのtoRawと同じく、Nako側の変更をJSへ書き戻してからdupする。
    if (try externalRaw(value)) |raw| {
        errdefer lnako_qjs_value_free(raw);
        try syncExternalRaw(runtime, engine_value, value, raw);
        return raw;
    }
    return switch (@as(Tag, @fromBackingInt(value.tag))) {
        .undefined, .null_value, .boolean, .number, .utf16_string, .static_utf8_string => primitiveRaw(runtime, engine_value, value),
        .array => arrayArgumentRaw(runtime, engine_value, value),
        .dictionary => dictionaryArgumentRaw(runtime, engine_value, value),
        else => error.QuickJsUnsupportedArgument,
    };
}

/// `JS関数実行` の最小dispatch。interpreter/officialと同じく、第1引数の文字列を
/// global evalで関数へ解決し、第2引数が配列ならその要素を、そうでなければ
/// 第2引数1個を実引数として呼び出す。`JS実行` のeval/drain/await/例外経路を共有し、
/// 戻り値がPromiseなら解決値を待ってから `callResultFromRaw` のプリミティブ＋
/// 浅い配列/辞書変換だけを通す。rejectとpendingはbridgeの文言で明示エラーにする。
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
    const values_source: []const Value = blk: {
        if (count >= 2) {
            if (arrayItems(rooted[1])) |items| break :blk items;
        }
        // official/interpreterと同じく、配列以外の第2引数は単一の実引数として
        // 扱う（第3引数以降はsemantic層が拒否する。第2引数なしのcount==1は
        // interpreterと同じ0引数呼出し）。
        break :blk rooted[1..@min(count, 2)];
    };
    // 呼出し後のrefreshは実引数コンテナ自身のpayloadを差し替え得るため、
    // values（コンテナのArrayListバッファを指す）をrootedなローカルへ複製する。
    const values = copyValues(runtime, values_source) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(values);
    var values_frame: state.RootFrame = .{};
    runtime.pushRoots(&values_frame, if (values.len == 0) null else values.ptr, values.len);
    defer runtime.popRoots(&values_frame);
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
        raw_arguments[index] = callArgumentRaw(runtime, engine_value, value) catch |failure| {
            switch (failure) {
                error.QuickJsUnsupportedArgument => runtime.setFailureText(unsupported_argument_message),
                // bridgeの文言はarrayArgumentRaw/dictionaryArgumentRawが
                // fail()で既にruntimeへ記録している。
                reported_engine_failure => {},
                else => runtime.setFailure(failure),
            }
            return;
        };
        initialized += 1;
    }
    // 空配列はゼロ長allocのptrをC ABIへ渡さずnullにする（count=0で参照されない）。
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    var raw = lnako_qjs_call(engine_value, callable, raw_pointer, raw_arguments.len) orelse {
        fail(runtime, engine_value);
        return;
    };
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(raw);
        fail(runtime, engine_value);
        return;
    }
    // `JS実行` と同じく、戻り値がPromiseなら解決値を待つ。rejectはbridgeが
    // reject理由を、pendingは "QuickJS promise is still pending" をlast_errorへ
    // 記録するため、`fail` で明示エラーになる（無限待機しない）。
    if (lnako_qjs_kind(raw) == .promise) {
        const awaited = lnako_qjs_await(engine_value, raw);
        lnako_qjs_value_free(raw);
        raw = awaited orelse {
            fail(runtime, engine_value);
            return;
        };
    }
    // interpreterと同じく、呼出し後にJS側の内容で実引数を再同期する。
    for (values, raw_arguments[0..initialized]) |value, argument_raw| {
        refreshFromRaw(runtime, value, @constCast(argument_raw)) catch |failure| {
            lnako_qjs_value_free(raw);
            reportRefreshFailure(runtime, failure, unsupported_argument_message);
            return;
        };
    }
    // callResultFromRawは成功・失敗にかかわらずrawを消費して解放する。
    out.* = callResultFromRaw(runtime, raw) catch |failure| {
        if (failure == error.QuickJsUnsupportedResult) {
            runtime.setFailureText(unsupported_result_message);
        } else {
            runtime.setFailure(failure);
        }
        return;
    };
}

/// `JSオブジェクト取得` / `JSメソッド実行` で、変換できない値に使う文言。
/// interpreter（compat/quickjs.zig）と同じ文言にしてAOT/インタプリタを一致させる。
const unsupported_object_get_message = "JSオブジェクト取得 does not support promises, functions, bigint, bytes, or nested arrays or dictionaries yet";
const unsupported_method_message = "JSメソッド実行 does not support promises, functions, bigint, bytes, or nested arrays or dictionaries yet";

/// 実引数スライスをruntime.allocatorへ複製する。呼出し後のrefreshがコンテナの
/// payloadをswapしても、イテレーション中の値がGCで回収されるのを防ぐ。
fn copyValues(runtime: *state.Runtime, source: []const Value) ![]Value {
    const values = try runtime.allocator.alloc(Value, source.len);
    @memcpy(values, source);
    return values;
}

/// レシーバ値からJS値を得る。external binding付きの配列/辞書は同じJS参照を
/// dupし、無い値は共有変換規則（プリミティブ＋浅い配列/辞書）でJSコピーを作る。
/// `eval_string` が真（`JSメソッド実行`）のときだけ、文字列をJSソースとして評価する
/// （interpreter/officialの既存経路）。`JSオブジェクト取得` は文字列をJSの
/// プリミティブとして扱う（"abc"の"0"は"a"）。
fn receiverRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, eval_string: bool) !*RawValue {
    if (eval_string and isStringValue(value)) {
        const source = state.stringUtf8Alloc(runtime, value) catch |failure| return failure;
        defer runtime.allocator.free(source);
        return lnako_qjs_eval(engine_value, source.ptr, source.len, "<JSメソッド実行>") orelse {
            fail(runtime, engine_value);
            return reported_engine_failure;
        };
    }
    return callArgumentRaw(runtime, engine_value, value);
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

fn reportUnsupported(runtime: *state.Runtime, failure: anyerror, message: []const u8) void {
    if (failure == error.QuickJsUnsupportedArgument or failure == error.QuickJsUnsupportedResult) {
        runtime.setFailureText(message);
    } else if (failure != reported_engine_failure) {
        runtime.setFailure(failure);
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
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    defer runtime.popRoots(&frame);
    const engine_value = ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    const raw_object = receiverRaw(runtime, engine_value, rooted[0], false) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_object_get_message);
        return;
    };
    defer lnako_qjs_value_free(raw_object);
    const name = propertyNameZ(runtime, rooted[1]) catch |failure| {
        runtime.setFailure(failure);
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
    out.* = resultFromRaw(runtime, result) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_object_get_message);
        return;
    };
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
    if (count < 2 or arguments == null) {
        runtime.setFailureText("JSメソッド実行 requires an object and a method name in AOT compat mode");
        return;
    }
    var frame: state.RootFrame = .{};
    const rooted = rootedArguments(runtime, arguments, count, &frame) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(rooted);
    defer runtime.popRoots(&frame);
    const engine_value = ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    const raw_object = receiverRaw(runtime, engine_value, rooted[0], true) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_method_message);
        return;
    };
    defer lnako_qjs_value_free(raw_object);
    const method = propertyNameZ(runtime, rooted[1]) catch |failure| {
        runtime.setFailure(failure);
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
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(values);
    var values_frame: state.RootFrame = .{};
    runtime.pushRoots(&values_frame, if (values.len == 0) null else values.ptr, values.len);
    defer runtime.popRoots(&values_frame);
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
        raw_arguments[index] = callArgumentRaw(runtime, engine_value, value) catch |failure| {
            reportUnsupported(runtime, failure, unsupported_method_message);
            return;
        };
        initialized += 1;
    }
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    const result = lnako_qjs_call_method(engine_value, raw_object, method.ptr, raw_pointer, raw_arguments.len) orelse {
        fail(runtime, engine_value);
        return;
    };
    if (lnako_qjs_drain_jobs(engine_value) < 0) {
        lnako_qjs_value_free(result);
        fail(runtime, engine_value);
        return;
    }
    // interpreterと同じく、呼出し後にJS側の内容で値（レシーバと実引数）を
    // 再同期する。JS側の変更を次の呼出しで古いNako内容が上書きしないようにする。
    refreshFromRaw(runtime, rooted[0], raw_object) catch |failure| {
        lnako_qjs_value_free(result);
        reportRefreshFailure(runtime, failure, unsupported_method_message);
        return;
    };
    for (values, raw_arguments[0..initialized]) |value, argument_raw| {
        refreshFromRaw(runtime, value, @constCast(argument_raw)) catch |failure| {
            lnako_qjs_value_free(result);
            reportRefreshFailure(runtime, failure, unsupported_method_message);
            return;
        };
    }
    out.* = resultFromRaw(runtime, result) catch |failure| {
        reportUnsupported(runtime, failure, unsupported_method_message);
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
    var value = try runtime.createArray(&.{});
    value.object().?.external = .{ .handle = @ptrCast(&sentinel), .release = testExternalRelease };
    test_external_releases = 0;
    _ = runtime.collect();
    try std.testing.expectEqual(@as(usize, 1), test_external_releases);
    // 2個目はrootして残し、runtime.deinitでも解放されることを確認する。
    var second = try runtime.createArray(&.{});
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
