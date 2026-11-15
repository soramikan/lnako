const std = @import("std");
const build_options = @import("build_options");
const value_mod = @import("../runtime/value.zig");
const common = @import("../plugins/system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const HostFunctionTable = @import("host_functions.zig").Table(Value);

pub const Engine = opaque {};
pub const RawValue = opaque {};
pub const RawKeys = opaque {};

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

pub extern fn lnako_qjs_new() ?*Engine;
const HostGetFn = *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) ?*RawValue;
const HostSetFn = *const fn (*anyopaque, [*:0]const u8, *const RawValue) callconv(.c) c_int;
const HostInvokeFn = *const fn (*anyopaque, usize, u64, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
const HostReleaseFn = *const fn (*anyopaque, usize, u64) callconv(.c) void;
const HostExecFn = *const fn (*anyopaque, [*:0]const u8, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
extern fn lnako_qjs_set_host(engine: *Engine, context: *anyopaque, get: HostGetFn, set: HostSetFn, invoke: HostInvokeFn, exec: HostExecFn) void;
pub extern fn lnako_qjs_set_host_release(engine: *Engine, release: ?HostReleaseFn) void;
extern fn lnako_qjs_add_module_source(engine: *Engine, name: [*:0]const u8, source: [*]const u8, length: usize, package_root: ?[*:0]const u8) c_int;
extern fn lnako_qjs_add_module_alias(engine: *Engine, alias: [*:0]const u8, target: [*:0]const u8) c_int;
pub extern fn lnako_qjs_release(engine: *Engine) void;
pub extern fn lnako_qjs_take_error(engine: *Engine) ?[*:0]u8;
pub extern fn lnako_qjs_free_string(text: [*:0]u8) void;
pub extern fn lnako_qjs_eval(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_eval_module(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_global(engine: *Engine, name: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_call(engine: *Engine, function: *const RawValue, arguments: [*]const *const RawValue, count: usize) ?*RawValue;
extern fn lnako_qjs_call_method(engine: *Engine, object: *const RawValue, name: [*:0]const u8, arguments: [*]const *const RawValue, count: usize) ?*RawValue;
pub extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
extern fn lnako_qjs_undefined(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_null(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_boolean(engine: *Engine, value: c_int) ?*RawValue;
extern fn lnako_qjs_number(engine: *Engine, value: f64) ?*RawValue;
extern fn lnako_qjs_string(engine: *Engine, value: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_bigint(engine: *Engine, decimal: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_array(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_object(engine: *Engine) ?*RawValue;
pub extern fn lnako_qjs_host_function(engine: *Engine, function_id: usize, generation: u64, name: [*:0]const u8) ?*RawValue;
pub extern fn lnako_qjs_run_gc(engine: *Engine) void;
pub extern fn lnako_qjs_set_memory_limit(engine: *Engine, limit: usize) void;
extern fn lnako_qjs_dup(value: *const RawValue) ?*RawValue;
extern fn lnako_qjs_value_engine(value: *const RawValue) ?*Engine;
pub extern fn lnako_qjs_value_free(value: *RawValue) void;
pub extern fn lnako_qjs_kind(value: *const RawValue) Kind;
extern fn lnako_qjs_identity(value: *const RawValue) usize;
extern fn lnako_qjs_is_bytes(value: *const RawValue) c_int;
extern fn lnako_qjs_to_boolean(value: *const RawValue) c_int;
pub extern fn lnako_qjs_to_number(value: *const RawValue, result: *f64) c_int;
extern fn lnako_qjs_to_string(value: *const RawValue, length: *usize) ?[*:0]u8;
pub extern fn lnako_qjs_array_length(value: *const RawValue) u32;
extern fn lnako_qjs_get_index(value: *const RawValue, index: u32) ?*RawValue;
extern fn lnako_qjs_set_index(value: *RawValue, index: u32, item: *const RawValue) c_int;
extern fn lnako_qjs_set_array_length(value: *RawValue, length: u32) c_int;
extern fn lnako_qjs_get_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_get_own_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_has_own_property(value: *const RawValue, name: [*:0]const u8) c_int;
extern fn lnako_qjs_set_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
extern fn lnako_qjs_clear_properties(value: *RawValue) c_int;
extern fn lnako_qjs_define_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
extern fn lnako_qjs_delete_property(value: *RawValue, name: [*:0]const u8) c_int;
extern fn lnako_qjs_has_index(value: *const RawValue, index: u32) c_int;
extern fn lnako_qjs_delete_index(value: *RawValue, index: u32) c_int;
extern fn lnako_qjs_strict_equal(left: *const RawValue, right: *const RawValue) c_int;
extern fn lnako_qjs_keys(value: *const RawValue) ?*RawKeys;
extern fn lnako_qjs_keys_length(keys: *const RawKeys) usize;
extern fn lnako_qjs_key(keys: *const RawKeys, index: usize, length: *usize) ?[*]const u8;
extern fn lnako_qjs_keys_free(keys: *RawKeys) void;

pub const Effects = struct {
    context: *anyopaque,
    invokeFn: *const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value,
    resolveFn: *const fn (context: *anyopaque, name: []const u8) anyerror!Value,
    getGlobalFn: *const fn (context: *anyopaque, name: []const u8) ?Value,
    setGlobalFn: *const fn (context: *anyopaque, name: []const u8, value: Value) anyerror!void,
    execFn: *const fn (context: *anyopaque, name: []const u8, arguments: []const Value) anyerror!Value,

    pub fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        return self.invokeFn(self.context, callable, arguments);
    }

    pub fn getGlobal(self: Effects, name: []const u8) ?Value {
        return self.getGlobalFn(self.context, name);
    }

    pub fn resolve(self: Effects, name: []const u8) !Value {
        return self.resolveFn(self.context, name);
    }

    pub fn setGlobal(self: Effects, name: []const u8, value: Value) !void {
        return self.setGlobalFn(self.context, name, value);
    }

    pub fn exec(self: Effects, name: []const u8, arguments: []const Value) !Value {
        return self.execFn(self.context, name, arguments);
    }
};

pub const State = struct {
    enabled: bool,
    engine: ?*Engine = null,
    modules_loaded: bool = false,
    runtime: ?*Runtime = null,
    effects: ?Effects = null,
    host_functions: HostFunctionTable = .{},
    package_namespaces: std.ArrayList([]const u8) = .empty,

    pub fn init(enabled: bool) State {
        return .{ .enabled = enabled };
    }

    pub fn deinit(self: *State) void {
        if (build_options.quickjs_enabled) if (self.engine) |engine| {
            // engine が external binding で生き残っても、破棄済みの table へ
            // finalizer が触れないよう、release より先に通知を解除する。
            lnako_qjs_set_host_release(engine, null);
            lnako_qjs_release(engine);
        };
        if (self.runtime) |runtime| {
            self.host_functions.deinit(runtime.allocator());
            for (self.package_namespaces.items) |namespace| runtime.allocator().free(namespace);
            self.package_namespaces.deinit(runtime.allocator());
        }
        self.* = undefined;
    }

    pub fn trace(self: *State, runtime: *Runtime) !void {
        try self.host_functions.trace(runtime, struct {
            fn mark(rt: *Runtime, value: Value) anyerror!void {
                try rt.traceExternal(value);
            }
        }.mark);
    }

    /// 登録済み host 関数スロット数（テスト・診断用）。tombstone は含まない。
    pub fn registeredHostFunctionCount(self: *State) usize {
        return self.host_functions.occupiedCount();
    }

    /// 登録済み host 関数インスタンス数（テスト・診断用）。
    pub fn hostFunctionInstanceCount(self: *State, value: Value) usize {
        const handle = self.hostFunctionHandle(value) orelse return 0;
        return self.host_functions.instanceCount(handle);
    }

    /// 値に対応する host 関数スロットの (index, generation)（テスト・診断用）。
    pub fn hostFunctionHandle(self: *State, value: Value) ?HostFunctionTable.Handle {
        return self.host_functions.handleForValue(value, sameHostValue);
    }

    pub fn hostFunction(self: *State, engine: *Engine, value: Value) !*RawValue {
        if (value != .function) return error.QuickJsUnsupportedArgument;
        // 単一 engine 所有モデル。`State.deinit` は `self.engine` の解放通知
        // しか解除しないため、別 engine へ登録すると teardown 後に finalizer が
        // 破棄済み State を参照してしまう。管理外の engine は拒否する。
        const active_engine = self.engine orelse return error.QuickJsHostUnavailable;
        if (active_engine != engine) return error.QuickJsHostUnavailable;
        // `ensure` を経由しないテスト・診断からも同じ State へ call/release が
        // 戻るよう、登録のたびに冪等に設定する。
        lnako_qjs_set_host(engine, self, hostGet, hostSet, hostInvoke, hostExec);
        lnako_qjs_set_host_release(engine, hostRelease);
        const function = value.function;
        const runtime = self.runtime orelse return error.QuickJsHostUnavailable;
        var handle: HostFunctionTable.Handle = undefined;
        if (self.host_functions.findHandle(value, sameHostValue)) |existing| {
            handle = existing;
        } else {
            handle = try self.host_functions.insert(runtime.allocator(), value);
        }
        // C 側の関数生成中に QuickJS の GC やプロパティ操作で既存インスタンスの
        // finalizer が走ってもスロットが解放されないよう、生成前に参照カウントを
        // 予約する。失敗時は予約分だけを戻す（新規なら 1 -> 0 で即解放、既存なら
        // N+1 -> N で既存インスタンスを保護する）。
        self.host_functions.acquire(handle);
        errdefer self.host_functions.release(handle.index, handle.generation);
        const name = try function.name.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(name);
        const name_z = try runtime.allocator().dupeSentinel(u8, name, 0);
        defer runtime.allocator().free(name_z);
        const raw = lnako_qjs_host_function(engine, handle.index, handle.generation, name_z.ptr) orelse return error.OutOfMemory;
        return raw;
    }

    fn ensure(self: *State, runtime: *Runtime, effects: Effects) !*Engine {
        if (!self.enabled or !build_options.quickjs_enabled) return error.QuickJsCompatibilityRequired;
        self.runtime = runtime;
        self.effects = effects;
        if (self.engine) |engine| {
            lnako_qjs_set_host(engine, self, hostGet, hostSet, hostInvoke, hostExec);
            lnako_qjs_set_host_release(engine, hostRelease);
            return engine;
        }
        const engine = lnako_qjs_new() orelse return error.QuickJsInitializationFailed;
        self.engine = engine;
        lnako_qjs_set_host(engine, self, hostGet, hostSet, hostInvoke, hostExec);
        lnako_qjs_set_host_release(engine, hostRelease);
        const bootstrap = bootstrapSource;
        const result = lnako_qjs_eval(engine, bootstrap, bootstrap.len, "<lnako-bootstrap>") orelse return quickJsError(engine);
        lnako_qjs_value_free(result);
        return engine;
    }
};

fn hostGet(context: *anyopaque, name: [*:0]const u8, find_variable: c_int) callconv(.c) ?*RawValue {
    const state: *State = @ptrCast(@alignCast(context));
    const runtime = state.runtime orelse return null;
    const effects = state.effects orelse return null;
    const name_slice = std.mem.span(name);
    const value = if (find_variable != 0)
        effects.resolve(name_slice) catch return null
    else
        effects.getGlobal(name_slice) orelse return null;
    // Nadesiko 3's __findVar checks Map values by truthiness, so zero, false,
    // an empty string and null are treated as missing and use the default.
    if (find_variable != 0 and !value.toBoolean()) return null;
    const engine = state.engine orelse return null;
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    return toRaw(state, runtime, engine, value, &cache) catch null;
}

fn hostSet(context: *anyopaque, name: [*:0]const u8, raw: *const RawValue) callconv(.c) c_int {
    const state: *State = @ptrCast(@alignCast(context));
    const runtime = state.runtime orelse return -1;
    const effects = state.effects orelse return -1;
    const owned = lnako_qjs_dup(raw) orelse return -1;
    const value = fromRaw(state, runtime, owned) catch return -1;
    effects.setGlobal(std.mem.span(name), value) catch return -1;
    return 0;
}

fn sameHostValue(left: Value, right: Value) bool {
    if (left != .function or right != .function) return false;
    return left.function == right.function;
}

/// QuickJS finalizer からの解放通知。JS の実行も Nako GC も再入させず、
/// スロットの参照カウント減算と解放だけを行う。
fn hostRelease(context: *anyopaque, function_id: usize, generation: u64) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context));
    state.host_functions.release(function_id, generation);
}

fn hostInvoke(context: *anyopaque, function_id: usize, generation: u64, raw_arguments: [*c]const *const RawValue, count: usize) callconv(.c) ?*RawValue {
    const state: *State = @ptrCast(@alignCast(context));
    const value = state.host_functions.lookup(function_id, generation) orelse return null;
    return hostCall(state, value, null, raw_arguments, count);
}

fn hostExec(context: *anyopaque, name: [*:0]const u8, raw_arguments: [*c]const *const RawValue, count: usize) callconv(.c) ?*RawValue {
    const state: *State = @ptrCast(@alignCast(context));
    return hostCall(state, null, std.mem.span(name), raw_arguments, count);
}

fn hostCall(state: *State, callable: ?Value, command: ?[]const u8, raw_arguments: [*c]const *const RawValue, count: usize) ?*RawValue {
    const runtime = state.runtime orelse return null;
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    const effects = state.effects orelse return null;
    const engine = state.engine orelse return null;
    const arguments = runtime.allocator().alloc(Value, count) catch return null;
    defer runtime.allocator().free(arguments);
    @memset(arguments, .undefined);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (0..count) |index| {
        const owned = lnako_qjs_dup(raw_arguments[index]) orelse return null;
        arguments[index] = fromRaw(state, runtime, owned) catch return null;
        roots.protect(&arguments[index]) catch return null;
    }
    var result = if (callable) |value|
        effects.invoke(value, arguments) catch return null
    else
        effects.exec(command.?, arguments) catch return null;
    roots.protect(&result) catch return null;
    for (arguments) |argument| {
        const synchronized = toRaw(state, runtime, engine, argument, &cache) catch return null;
        lnako_qjs_value_free(synchronized);
    }
    return toRaw(state, runtime, engine, result, &cache) catch null;
}

pub fn available() bool {
    return build_options.quickjs_enabled;
}

/// `JS関数実行` の実引数として同期できない値（Promiseなど）の文言。
/// AOT compat（`src/runtime/aot/compat_js.zig`）と同じ文言で失敗させる。
pub const unsupported_call_argument_message = "JS関数実行 does not support promises or unsupported argument types";

/// `JSオブジェクト取得` / `JSメソッド実行` で、AOTと共有する未対応文言。
pub const unsupported_object_get_message = "JSオブジェクト取得 does not support promises, functions, bigint, or bytes yet";
pub const unsupported_method_message = "JSメソッド実行 does not support promises, functions, bigint, or bytes yet";

/// `JSオブジェクト取得` / `JSメソッド実行` のトップレベル値がAOTと同じ規則で
/// JSへ渡せるか。プリミティブと配列・辞書だけを許可する（関数・BigInt・bytes・
/// Promiseは明示エラー）。配列・辞書の中身は`toRaw`の同期変換に委ね、bytesだけは
/// `containsBytesValue`でAOTのfull_values=falseと同じく拒否する。
pub fn isSupportedInteropValue(value: Value) bool {
    return switch (value) {
        .undefined, .null_value, .boolean, .number, .string, .array, .dictionary => true,
        else => false,
    };
}

/// externalコンテナ内にNakoのbytesが含まれるか。AOTのsyncValueRawはbytesを
/// 書き戻せないため、interpreterも同じ入力で明示エラーにする。循環は
/// Nako Object pointerの訪問済み集合で止める。
fn containsBytesValue(runtime: *Runtime, value: Value) bool {
    return containsBytesInner(runtime, value, null);
}

fn containsBytesInner(runtime: *Runtime, value: Value, visited: ?*std.AutoHashMapUnmanaged(usize, void)) bool {
    switch (value) {
        .bytes => return true,
        .array => |array| {
            var local = std.AutoHashMapUnmanaged(usize, void){};
            const map = visited orelse blk: {
                break :blk &local;
            };
            defer if (visited == null) local.deinit(runtime.allocator());
            const identity = @intFromPtr(array);
            if (map.contains(identity)) return false;
            map.put(runtime.allocator(), identity, {}) catch return true;
            for (array.items.items) |item| {
                if (containsBytesInner(runtime, item, map)) return true;
            }
            return false;
        },
        .dictionary => |dictionary| {
            var local = std.AutoHashMapUnmanaged(usize, void){};
            const map = visited orelse blk: {
                break :blk &local;
            };
            defer if (visited == null) local.deinit(runtime.allocator());
            const identity = @intFromPtr(dictionary);
            if (map.contains(identity)) return false;
            map.put(runtime.allocator(), identity, {}) catch return true;
            for (dictionary.values()) |item| {
                if (containsBytesInner(runtime, item, map)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// レシーバ/実引数をJS値へ変換する。`eval_string`が真（`JSメソッド実行`）の
/// ときだけ文字列をJSソースとして評価する（既存経路）。external bindingは
/// `toRaw`が同じJS参照をdupしてNako側の変更を書き戻す。
pub fn interopValueRaw(state: *State, runtime: *Runtime, engine: *Engine, value: Value, message: []const u8, cache: *SyncCache) !*RawValue {
    if (!isSupportedInteropValue(value) or containsBytesValue(runtime, value)) {
        try runtime.setFailureMessage(message);
        return error.QuickJsUnsupportedArgument;
    }
    // コンテナ内のPromiseはAOTのsyncValueRawと同じく同期変換できない。
    return toRaw(state, runtime, engine, value, cache) catch |failure| {
        if (failure == error.QuickJsPromiseBridgePending) {
            try runtime.setFailureMessage(message);
            return error.QuickJsUnsupportedArgument;
        }
        return failure;
    };
}

/// 2引数`JSオブジェクト取得`。external bindingのJS参照、または共有変換規則で
/// 作ったJSコピーのプロパティを取得し、`JS実行`/`JSメソッド実行`と同じfull
/// 変換（配列/辞書は再帰、external付き）でNako値へ戻す。
pub fn lookupExternalProperty(state: *State, runtime: *Runtime, engine: *Engine, object: Value, key: Value) !Value {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var rooted_object = object;
    var rooted_key = key;
    try roots.protect(&rooted_object);
    try roots.protect(&rooted_key);
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    const raw_object = try interopValueRaw(state, runtime, engine, rooted_object, unsupported_object_get_message, &cache);
    defer lnako_qjs_value_free(raw_object);
    const name = try common.toUtf8Alloc(runtime, rooted_key);
    defer runtime.allocator().free(name);
    const name_z = try runtime.allocator().dupeSentinel(u8, name, 0);
    defer runtime.allocator().free(name_z);
    const result = lnako_qjs_get_property(raw_object, name_z.ptr) orelse return quickJsError(engine);
    if (lnako_qjs_drain_jobs(engine) < 0) {
        lnako_qjs_value_free(result);
        return quickJsError(engine);
    }
    // getterが実行時にレシーバを変更した場合、次の呼出しで古いNakoコピーを
    // 書き戻さないよう、取得後にレシーバを再同期する。
    refreshExternal(state, runtime, rooted_object, raw_object) catch |failure| {
        lnako_qjs_value_free(result);
        return failure;
    };
    return interopFromRaw(state, runtime, result) catch |failure| {
        if (failure == error.QuickJsUnsupportedInteropResult) {
            try runtime.setFailureMessage(unsupported_object_get_message);
        }
        return failure;
    };
}

pub fn call(runtime: *Runtime, state: *State, effects: Effects, name: []const u8, arguments: []const Value) !?Value {
    if (!isCompatCommand(name)) {
        if (!state.enabled or !state.modules_loaded) return null;
        return callPlugin(state, runtime, name, arguments);
    }
    const engine = try state.ensure(runtime, effects);
    if (std.mem.eql(u8, name, "JS実行")) {
        const source = try common.toUtf8Alloc(runtime, common.argument(arguments, 0));
        defer runtime.allocator().free(source);
        const raw = lnako_qjs_eval(engine, source.ptr, source.len, "<JS実行>") orelse return quickJsError(engine);
        return @as(?Value, try fromRaw(state, runtime, raw));
    }
    if (std.mem.eql(u8, name, "JSオブジェクト取得")) {
        // 2引数形はlnako拡張（公式は1引数）。external bindingのJS参照、または
        // 共有変換規則で作ったJSコピーのプロパティを取得する。AOTと同じ意味。
        if (arguments.len == 0) {
            try runtime.setFailureMessage("JSオブジェクト取得 requires a value and a property name");
            return error.QuickJsUnsupportedArgument;
        }
        if (arguments.len > 2) {
            try runtime.setFailureMessage("JSオブジェクト取得 accepts a value and a property name only");
            return error.QuickJsUnsupportedArgument;
        }
        if (arguments.len == 2) {
            return @as(?Value, try lookupExternalProperty(state, runtime, engine, common.argument(arguments, 0), common.argument(arguments, 1)));
        }
        const requested = common.argument(arguments, 0);
        if (requested == .function) return @as(?Value, requested);
        const name_text = try common.toUtf8Alloc(runtime, requested);
        defer runtime.allocator().free(name_text);
        if (effects.resolve(name_text)) |value| {
            if (value.toBoolean()) return @as(?Value, value);
        } else |_| {}
        return @as(?Value, .null_value);
    }
    if (std.mem.eql(u8, name, "JS関数実行")) {
        var callable = common.argument(arguments, 0);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&callable);
        if (callable == .string) {
            const source = try callable.string.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(source);
            const raw = lnako_qjs_eval(engine, source.ptr, source.len, "<JS関数実行>") orelse return quickJsError(engine);
            callable = try fromRaw(state, runtime, raw);
        }
        const call_arguments = common.argument(arguments, 1);
        const slice = if (call_arguments == .array) call_arguments.array.items.items else arguments[1..@min(arguments.len, 2)];
        // Nako関数値の呼出しはNako値のまま渡すため制限しない。JS関数へ渡す
        // 実引数はAOTと同じfull変換（BigInt・関数値・ネスト/循環/疎配列・
        // bytes）で同期する。呼出し不能の判定は引数変換より先に行い、AOT
        // （eval→関数判定→引数変換）と同じ優先順位にする。
        if (callable == .function and callable.function.kind != .external) return @as(?Value, try effects.invoke(callable, slice));
        if (callable != .function or callable.function.kind != .external) return error.QuickJsValueNotCallable;
        return @as(?Value, try callExternalCallResult(state, runtime, callable, slice));
    }
    if (std.mem.eql(u8, name, "JSメソッド実行")) {
        var object = common.argument(arguments, 0);
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&object);
        if (object == .string) {
            const source = try object.string.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(source);
            const raw = lnako_qjs_eval(engine, source.ptr, source.len, "<JSメソッド実行>") orelse return quickJsError(engine);
            object = try fromRaw(state, runtime, raw);
        }
        // AOTと同じく、レシーバと実引数はトップレベルではプリミティブと配列・
        // 辞書に限る（関数/BigInt/bytes/Promiseは明示エラー）。配列・辞書の
        // 中身は同期変換（ネストした配列・辞書・関数値・BigInt）で扱い、bytesは
        // AOTのfull_values=falseと同じく明示エラーにする。
        if (!isSupportedInteropValue(object) or containsBytesValue(runtime, object)) {
            try runtime.setFailureMessage(unsupported_method_message);
            return error.QuickJsUnsupportedArgument;
        }
        // レシーバevalがhost callback経由で引数配列を変更し得るため、eval後に
        // 実引数コンテナとsliceを取り直す。
        const call_arguments = common.argument(arguments, 2);
        const slice = if (call_arguments == .array) call_arguments.array.items.items else arguments[2..@min(arguments.len, 3)];
        for (slice) |argument| {
            if (!isSupportedInteropValue(argument) or containsBytesValue(runtime, argument)) {
                try runtime.setFailureMessage(unsupported_method_message);
                return error.QuickJsUnsupportedArgument;
            }
        }
        const method = try common.toUtf8Alloc(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(method);
        const method_z = try runtime.allocator().dupeSentinel(u8, method, 0);
        defer runtime.allocator().free(method_z);
        return @as(?Value, try callExternalMethod(state, runtime, engine, object, method_z, slice));
    }
    unreachable;
}

pub fn installModules(runtime: *Runtime, state: *State, modules: []const @import("../ir/nako_ir.zig").JavaScriptModule, effects: Effects) !void {
    if (!state.enabled) return;
    const engine = try state.ensure(runtime, effects);
    for (modules) |module| {
        const filename = try moduleFilename(runtime.allocator(), module.path);
        defer runtime.allocator().free(filename);
        // package所有moduleはrootも `/` 区切りへ正規化して渡す。bridge側の
        // module_normalizeが、このmoduleおよびroot配下で読まれたmoduleの
        // import解決にroot包含を強制し、graph収集の盲点となった形でも
        // root外へのFS fallbackを拒否する。
        const package_root: ?[:0]u8 = if (module.package_root) |root| blk: {
            const normalized = try runtime.allocator().dupeSentinel(u8, root, 0);
            for (normalized) |*character| if (character.* == '\\') {
                character.* = '/';
            };
            break :blk normalized;
        } else null;
        defer if (package_root) |root| runtime.allocator().free(root);
        if (lnako_qjs_add_module_source(engine, filename.ptr, module.source.ptr, module.source.len, if (package_root) |root| root.ptr else null) < 0) return error.QuickJsModuleRegistrationFailed;
        for (module.bare_aliases) |alias| {
            const alias_z = try runtime.allocator().dupeSentinel(u8, alias, 0);
            defer runtime.allocator().free(alias_z);
            if (lnako_qjs_add_module_alias(engine, alias_z.ptr, filename.ptr) < 0) return error.QuickJsModuleRegistrationFailed;
        }
    }
    for (modules) |module| {
        if (!module.is_plugin) continue;
        const filename = try moduleFilename(runtime.allocator(), module.path);
        defer runtime.allocator().free(filename);
        // `pkg:` import経由のESM pluginは修飾名のみ公開する（native pluginの
        // namespace契約と同じ）。評価中の自己登録（addPluginObject）も修飾名へ
        // 誘導するため、eval前にactive namespaceを設定する。直接path importと
        // 併存する module は namespaces に空エントリを含み、それを active
        // namespace として渡すと shim が無修飾登録する。
        for (module.namespaces) |namespace| {
            // 空エントリは「直接path import由来の無修飾公開」を表す sentinel
            // であり、package namespace 一覧には登録しない（`{ns}__{名}`
            // 判定で任意の `__x` に一致してしまう）。
            if (namespace.len == 0) continue;
            var listed = false;
            for (state.package_namespaces.items) |existing| {
                if (std.mem.eql(u8, existing, namespace)) {
                    listed = true;
                    break;
                }
            }
            if (!listed) try state.package_namespaces.append(runtime.allocator(), try runtime.allocator().dupe(u8, namespace));
        }
        const begin = try globalProperty(engine, "__lnako_beginModuleEval");
        defer lnako_qjs_value_free(begin);
        const active_namespace = if (module.namespaces.len > 0)
            lnako_qjs_string(engine, module.namespaces[0].ptr, module.namespaces[0].len) orelse return quickJsError(engine)
        else
            lnako_qjs_undefined(engine) orelse return error.QuickJsEngineUnavailable;
        defer lnako_qjs_value_free(active_namespace);
        const begin_arguments = [_]*const RawValue{active_namespace};
        const begin_result = lnako_qjs_call(engine, begin, &begin_arguments, begin_arguments.len) orelse return quickJsError(engine);
        lnako_qjs_value_free(begin_result);
        const plugin = lnako_qjs_eval_module(engine, module.source.ptr, module.source.len, filename.ptr) orelse return quickJsError(engine);
        defer lnako_qjs_value_free(plugin);
        const register = try globalProperty(engine, "__lnako_registerPlugin");
        defer lnako_qjs_value_free(register);
        if (module.namespaces.len == 0) {
            const arguments = [_]*const RawValue{plugin};
            const result = lnako_qjs_call(engine, register, &arguments, arguments.len) orelse return quickJsError(engine);
            lnako_qjs_value_free(result);
        } else {
            // 同一pathを複数aliasでimportした場合は全namespace分を登録する。
            // JS shim側が (plugin, namespace) 単位で重複登録を弾き、`初期化`は
            // plugin単位で一度だけ実行する。
            for (module.namespaces) |namespace| {
                const namespace_value = lnako_qjs_string(engine, namespace.ptr, namespace.len) orelse return quickJsError(engine);
                defer lnako_qjs_value_free(namespace_value);
                const arguments = [_]*const RawValue{ plugin, namespace_value };
                const result = lnako_qjs_call(engine, register, &arguments, arguments.len) orelse return quickJsError(engine);
                lnako_qjs_value_free(result);
            }
        }
        // eval中に `addPluginObject` で自己登録したpluginは active namespace
        // （namespaces[0]）にしか登録されていないため、全非空namespaceへ
        // 再登録する。shim側がdrainしかつ (plugin, namespace) 単位で重複
        // 登録を弾くため重複分は無害（namespacesが0件または空sentinelのみ
        // の場合はdrainのみ）。
        var extra_namespaces: std.ArrayList(u8) = .empty;
        defer extra_namespaces.deinit(runtime.allocator());
        try extra_namespaces.appendSlice(runtime.allocator(), "[");
        var extra_index: usize = 0;
        for (module.namespaces) |namespace| {
            // 空エントリは「直接path import由来の無修飾公開」のsentinelであり
            // 登録対象外（install時の修飾登録と同じ規則）。
            if (namespace.len == 0) continue;
            if (extra_index != 0) try extra_namespaces.append(runtime.allocator(), ',');
            extra_index += 1;
            // JSON文字列として安全な形へ打ち延す。namespaceに `"` が含まれる
            // とJSONが壊れてreregisterが解釈不能になり、自己登録pluginが
            // 一部namespaceへ残留するため `\` と `"` を escape する。
            try extra_namespaces.appendSlice(runtime.allocator(), "\"");
            for (namespace) |character| {
                if (character == '\\' or character == '"') {
                    try extra_namespaces.append(runtime.allocator(), '\\');
                }
                try extra_namespaces.append(runtime.allocator(), character);
            }
            try extra_namespaces.appendSlice(runtime.allocator(), "\"");
        }
        try extra_namespaces.appendSlice(runtime.allocator(), "]");
        const extra_json = lnako_qjs_string(engine, extra_namespaces.items.ptr, extra_namespaces.items.len) orelse return quickJsError(engine);
        defer lnako_qjs_value_free(extra_json);
        const reregister = try globalProperty(engine, "__lnako_reregisterEvalPlugins");
        defer lnako_qjs_value_free(reregister);
        const reregister_arguments = [_]*const RawValue{extra_json};
        const reregister_result = lnako_qjs_call(engine, reregister, &reregister_arguments, reregister_arguments.len) orelse return quickJsError(engine);
        lnako_qjs_value_free(reregister_result);
    }
    state.modules_loaded = true;
    const commands = try globalProperty(engine, "__lnako_commands");
    defer lnako_qjs_value_free(commands);
    const keys = lnako_qjs_keys(commands) orelse return quickJsError(engine);
    defer lnako_qjs_keys_free(keys);
    for (0..lnako_qjs_keys_length(keys)) |index| {
        var name_length: usize = 0;
        const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator().dupeSentinel(u8, name, 0);
        defer runtime.allocator().free(name_z);
        const definition_value = lnako_qjs_get_property(commands, name_z.ptr) orelse return quickJsError(engine);
        defer lnako_qjs_value_free(definition_value);
        const type_value = lnako_qjs_get_property(definition_value, "type") orelse continue;
        defer lnako_qjs_value_free(type_value);
        const type_text = rawText(type_value) catch continue;
        defer lnako_qjs_free_string(type_text.pointer);
        if (!std.mem.eql(u8, type_text.slice(), "const")) continue;
        const raw_value = lnako_qjs_get_property(definition_value, "value") orelse return quickJsError(engine);
        try effects.setGlobal(name, try fromRaw(state, runtime, raw_value));
    }
}

/// `__lnako_commands` に登録された command key 一覧を返す（Issue #52 の
/// `lnako check --load-plugins` 用・実登録照合）。`allocator` が返却値を
/// 所有する。engine が無い（未評価）場合は null を返す。
pub fn registeredCommandKeys(state: *State, allocator: std.mem.Allocator) !?[][]const u8 {
    const engine = state.engine orelse return null;
    const commands = try globalProperty(engine, "__lnako_commands");
    defer lnako_qjs_value_free(commands);
    const keys = lnako_qjs_keys(commands) orelse return quickJsError(engine);
    defer lnako_qjs_keys_free(keys);
    const length = lnako_qjs_keys_length(keys);
    var names = try allocator.alloc([]const u8, length);
    errdefer allocator.free(names);
    var filled: usize = 0;
    for (0..length) |index| {
        var name_length: usize = 0;
        const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
        names[filled] = try allocator.dupe(u8, name_pointer[0..name_length]);
        filled += 1;
    }
    if (filled != length) names = try allocator.realloc(names, filled);
    return names;
}

fn moduleFilename(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const filename = try allocator.dupeSentinel(u8, path, 0);
    for (filename) |*character| if (character.* == '\\') {
        character.* = '/';
    };
    return filename;
}

fn callPlugin(self: *State, runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const engine = self.engine orelse return null;
    const commands = try globalProperty(engine, "__lnako_commands");
    defer lnako_qjs_value_free(commands);
    var lookup_name = name;
    var name_z = try runtime.allocator().dupeSentinel(u8, lookup_name, 0);
    defer runtime.allocator().free(name_z);
    var definition_value = lnako_qjs_get_property(commands, name_z.ptr) orelse return quickJsError(engine);
    if (lnako_qjs_kind(definition_value) == .undefined and !isPackageNamespacedName(self, name)) {
        if (std.mem.lastIndexOf(u8, name, "__")) |separator| {
            lnako_qjs_value_free(definition_value);
            lookup_name = name[separator + 2 ..];
            runtime.allocator().free(name_z);
            name_z = try runtime.allocator().dupeSentinel(u8, lookup_name, 0);
            definition_value = lnako_qjs_get_property(commands, name_z.ptr) orelse return quickJsError(engine);
        }
    }
    defer lnako_qjs_value_free(definition_value);
    if (lnako_qjs_kind(definition_value) == .undefined) return null;
    const function = lnako_qjs_get_property(definition_value, "fn") orelse return quickJsError(engine);
    defer lnako_qjs_value_free(function);
    if (lnako_qjs_kind(function) != .function) return null;
    const snapshot = try snapshotArguments(runtime, arguments);
    defer runtime.allocator().free(snapshot);
    var snapshot_frame = runtime.rootFrame();
    defer snapshot_frame.deinit();
    for (snapshot) |*value| try snapshot_frame.protect(value);
    const raw_arguments = try runtime.allocator().alloc(*const RawValue, snapshot.len + 1);
    defer runtime.allocator().free(raw_arguments);
    var initialized: usize = 0;
    defer for (raw_arguments[0..initialized]) |value| lnako_qjs_value_free(@constCast(value));
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    for (snapshot, 0..) |argument, index| {
        raw_arguments[index] = try toRaw(self, runtime, engine, argument, &cache);
        initialized += 1;
    }
    raw_arguments[arguments.len] = try globalProperty(engine, "sys");
    initialized += 1;
    var result = lnako_qjs_call(engine, function, raw_arguments.ptr, raw_arguments.len) orelse {
        const saved = lnako_qjs_take_error(engine);
        for (snapshot, raw_arguments[0..snapshot.len]) |argument, raw_argument| {
            refreshExternal(self, runtime, argument, @constCast(raw_argument)) catch {};
        }
        if (saved) |text| {
            defer lnako_qjs_free_string(text);
            try runtime.setFailureMessage(std.mem.span(text));
            return error.QuickJsExecutionFailed;
        }
        return quickJsError(engine);
    };
    if (lnako_qjs_drain_jobs(engine) < 0) {
        lnako_qjs_value_free(result);
        return quickJsError(engine);
    }
    if (lnako_qjs_kind(result) == .promise) {
        const promise = result;
        result = lnako_qjs_await(engine, promise) orelse {
            lnako_qjs_value_free(promise);
            return quickJsError(engine);
        };
        lnako_qjs_value_free(promise);
    }
    for (snapshot, raw_arguments[0..snapshot.len]) |argument, raw_argument| {
        refreshExternal(self, runtime, argument, @constCast(raw_argument)) catch |failure| {
            lnako_qjs_value_free(result);
            return failure;
        };
    }
    const return_none_value = lnako_qjs_get_property(definition_value, "return_none") orelse return quickJsError(engine);
    defer lnako_qjs_value_free(return_none_value);
    if (lnako_qjs_to_boolean(return_none_value) != 0) {
        lnako_qjs_value_free(result);
        return @as(?Value, .undefined);
    }
    return @as(?Value, try fromRaw(self, runtime, result));
}

/// `name` がpackage namespaceに属する修飾名か。該当する場合は
/// `callPlugin` の末尾`__`除去fallbackを適用しない。修飾名がpackage外の
/// 無修飾命令へ漏れると `{ns}__{名}` 契約が破れるため（native plugin側の
/// findCommand と同じ規則）。既知namespaceに一致しない `plugin__cmd` 形式は
/// cnako互換の名前付き呼出しとして従来どおりfallbackを許す。
fn isPackageNamespacedName(state: *State, name: []const u8) bool {
    for (state.package_namespaces.items) |namespace| {
        if (name.len > namespace.len + 2 and
            std.mem.startsWith(u8, name, namespace) and
            name[namespace.len] == '_' and name[namespace.len + 1] == '_') return true;
    }
    return false;
}

fn globalProperty(engine: *Engine, name: [:0]const u8) !*RawValue {
    return lnako_qjs_global(engine, name.ptr) orelse quickJsError(engine);
}

fn isCompatCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, "JS実行") or std.mem.eql(u8, name, "JSオブジェクト取得") or std.mem.eql(u8, name, "JS関数実行") or std.mem.eql(u8, name, "JSメソッド実行");
}

/// `JS関数実行` のexternal関数呼出し。実引数と戻り値は `JS実行` と同じfull変換
/// （BigInt・関数値・ネスト/循環/疎配列・bytes）で扱う。戻り値がPromiseなら
/// `JS実行` と同じdrain/await経路で解決値を待ち、reject/pendingはbridgeの文言で
/// 明示エラーにする。Nako関数値の呼出しはこの経路を通らないため制限しない。
pub fn callExternalCallResult(state: *State, runtime: *Runtime, callable: Value, arguments: []const Value) !Value {
    if (callable != .function or callable.function.kind != .external) return error.QuickJsValueNotCallable;
    const external = callable.function.kind.external;
    if (external.binding.context != @as(*anyopaque, @ptrCast(state))) return error.QuickJsEngineMismatch;
    const engine = state.engine orelse return error.QuickJsEngineClosed;
    const function: *RawValue = @ptrCast(@alignCast(external.binding.handle));
    // refreshは実引数コンテナ自身のpayloadを差し替え得るため、呼出し側の
    // 配列itemsバッファを直接指すsliceをrootedなローカルへ複製して使う。
    const snapshot = try snapshotArguments(runtime, arguments);
    defer runtime.allocator().free(snapshot);
    var snapshot_frame = runtime.rootFrame();
    defer snapshot_frame.deinit();
    for (snapshot) |*value| try snapshot_frame.protect(value);
    // Promiseは同期変換できないため、AOTと同じ共通文言の明示エラーにする。
    const raw_arguments = rawArguments(state, runtime, engine, snapshot) catch |failure| {
        if (failure == error.QuickJsPromiseBridgePending) {
            try runtime.setFailureMessage(unsupported_call_argument_message);
            return error.QuickJsUnsupportedArgument;
        }
        return failure;
    };
    defer freeRawArguments(runtime.allocator(), raw_arguments);
    var result = lnako_qjs_call(engine, function, raw_arguments.ptr, raw_arguments.len) orelse {
        const saved = lnako_qjs_take_error(engine);
        for (snapshot, raw_arguments) |argument, raw_argument| {
            refreshExternal(state, runtime, argument, @constCast(raw_argument)) catch {};
        }
        if (saved) |text| {
            defer lnako_qjs_free_string(text);
            try runtime.setFailureMessage(std.mem.span(text));
            return error.QuickJsExecutionFailed;
        }
        return quickJsError(engine);
    };
    // `callPlugin` と同じく、Promiseは解決値を待ってから引数の書き戻しと
    // 戻り値変換を行う。rejectはreject理由、pendingは
    // "QuickJS promise is still pending" が `quickJsError` の文言になる。
    if (lnako_qjs_drain_jobs(engine) < 0) {
        lnako_qjs_value_free(result);
        return quickJsError(engine);
    }
    if (lnako_qjs_kind(result) == .promise) {
        const promise = result;
        result = lnako_qjs_await(engine, promise) orelse {
            lnako_qjs_value_free(promise);
            return quickJsError(engine);
        };
        lnako_qjs_value_free(promise);
    }
    for (snapshot, raw_arguments) |argument, raw_argument| {
        refreshExternal(state, runtime, argument, @constCast(raw_argument)) catch |failure| {
            lnako_qjs_value_free(result);
            return failure;
        };
    }
    return fromRaw(state, runtime, result);
}

pub fn callExternalMethod(state: *State, runtime: *Runtime, engine: *Engine, object: Value, method: [:0]const u8, arguments: []const Value) !Value {
    // refreshはレシーバ/実引数コンテナのpayloadを差し替え得るため、呼出し側の
    // 配列itemsバッファを直接指すsliceをrootedなローカルへ複製して使う。
    const snapshot = try snapshotArguments(runtime, arguments);
    defer runtime.allocator().free(snapshot);
    var snapshot_frame = runtime.rootFrame();
    defer snapshot_frame.deinit();
    for (snapshot) |*value| try snapshot_frame.protect(value);
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    const raw_object = toRaw(state, runtime, engine, object, &cache) catch |failure| {
        if (failure == error.QuickJsPromiseBridgePending) {
            try runtime.setFailureMessage(unsupported_method_message);
            return error.QuickJsUnsupportedArgument;
        }
        return failure;
    };
    defer lnako_qjs_value_free(raw_object);
    const raw_arguments = rawArgumentsWithCache(state, runtime, engine, snapshot, &cache) catch |failure| {
        if (failure == error.QuickJsPromiseBridgePending) {
            try runtime.setFailureMessage(unsupported_method_message);
            return error.QuickJsUnsupportedArgument;
        }
        return failure;
    };
    defer freeRawArguments(runtime.allocator(), raw_arguments);
    const result = lnako_qjs_call_method(engine, raw_object, method.ptr, raw_arguments.ptr, raw_arguments.len) orelse {
        const saved = lnako_qjs_take_error(engine);
        refreshExternal(state, runtime, object, raw_object) catch {};
        for (snapshot, raw_arguments) |argument, raw_argument| {
            refreshExternal(state, runtime, argument, @constCast(raw_argument)) catch {};
        }
        if (saved) |text| {
            defer lnako_qjs_free_string(text);
            try runtime.setFailureMessage(std.mem.span(text));
            return error.QuickJsExecutionFailed;
        }
        return quickJsError(engine);
    };
    if (lnako_qjs_drain_jobs(engine) < 0) {
        lnako_qjs_value_free(result);
        return quickJsError(engine);
    }
    refreshExternal(state, runtime, object, raw_object) catch |failure| {
        lnako_qjs_value_free(result);
        return failure;
    };
    for (snapshot, raw_arguments) |argument, raw_argument| {
        refreshExternal(state, runtime, argument, @constCast(raw_argument)) catch |failure| {
            lnako_qjs_value_free(result);
            return failure;
        };
    }
    return interopFromRaw(state, runtime, result) catch |failure| {
        if (failure == error.QuickJsUnsupportedInteropResult) {
            try runtime.setFailureMessage(unsupported_method_message);
        }
        return failure;
    };
}

fn externalCall(context: *anyopaque, handle: *anyopaque, runtime: *Runtime, arguments: []const Value) !Value {
    const state: *State = @ptrCast(@alignCast(context));
    const engine = state.engine orelse return error.QuickJsEngineClosed;
    const function: *RawValue = @ptrCast(@alignCast(handle));
    // refreshが引数コンテナのpayloadを差し替えても安全なよう、sliceを複製してrootする。
    const snapshot = try snapshotArguments(runtime, arguments);
    defer runtime.allocator().free(snapshot);
    var snapshot_frame = runtime.rootFrame();
    defer snapshot_frame.deinit();
    for (snapshot) |*value| try snapshot_frame.protect(value);
    // Promiseは同期変換できないため、AOTと同じ共通文言の明示エラーにする。
    const raw_arguments = rawArguments(state, runtime, engine, snapshot) catch |failure| {
        if (failure == error.QuickJsPromiseBridgePending) {
            try runtime.setFailureMessage(unsupported_call_argument_message);
            return error.QuickJsUnsupportedArgument;
        }
        return failure;
    };
    defer freeRawArguments(runtime.allocator(), raw_arguments);
    const result = lnako_qjs_call(engine, function, raw_arguments.ptr, raw_arguments.len) orelse return quickJsError(engine);
    if (lnako_qjs_drain_jobs(engine) < 0) {
        lnako_qjs_value_free(result);
        return quickJsError(engine);
    }
    for (snapshot, raw_arguments) |argument, raw_argument| {
        refreshExternal(state, runtime, argument, @constCast(raw_argument)) catch |failure| {
            lnako_qjs_value_free(result);
            return failure;
        };
    }
    return fromRaw(state, runtime, result);
}

fn releaseExternal(_: *anyopaque, handle: *anyopaque) void {
    lnako_qjs_value_free(@ptrCast(@alignCast(handle)));
}

fn objectBinding(engine: *Engine, raw: *RawValue) value_mod.ExternalHandle {
    return .{
        .context = @ptrCast(engine),
        .handle = @ptrCast(raw),
        .releaseFn = releaseExternal,
    };
}

fn functionBinding(state: *State, raw: *RawValue) value_mod.ExternalHandle {
    return .{
        .context = @ptrCast(state),
        .handle = @ptrCast(raw),
        .releaseFn = releaseExternal,
    };
}

/// 呼出し後のrefreshで引数コンテナのpayloadがswapされても安全なように、
/// 実引数スライスをruntime.allocatorへ複製する。
fn snapshotArguments(runtime: *Runtime, arguments: []const Value) ![]Value {
    const snapshot = try runtime.allocator().alloc(Value, arguments.len);
    @memcpy(snapshot, arguments);
    return snapshot;
}

fn rawArguments(state: *State, runtime: *Runtime, engine: *Engine, arguments: []const Value) ![]*const RawValue {
    var cache = SyncCache{};
    defer cache.deinit(runtime.allocator());
    return rawArgumentsWithCache(state, runtime, engine, arguments, &cache);
}

fn rawArgumentsWithCache(state: *State, runtime: *Runtime, engine: *Engine, arguments: []const Value, cache: *SyncCache) ![]*const RawValue {
    const result = try runtime.allocator().alloc(*const RawValue, arguments.len);
    errdefer runtime.allocator().free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |value| lnako_qjs_value_free(@constCast(value));
    for (arguments, 0..) |argument, index| {
        result[index] = try toRaw(state, runtime, engine, argument, cache);
        initialized += 1;
    }
    return result;
}

fn freeRawArguments(allocator: std.mem.Allocator, arguments: []*const RawValue) void {
    for (arguments) |value| lnako_qjs_value_free(@constCast(value));
    allocator.free(arguments);
}

fn toRaw(state: *State, runtime: *Runtime, engine: *Engine, value: Value, cache: *SyncCache) anyerror!*RawValue {
    if (cache.depth >= max_interop_conversion_depth) return error.QuickJsNestingTooDeep;
    cache.depth += 1;
    defer cache.depth -= 1;
    return switch (value) {
        .undefined => lnako_qjs_undefined(engine) orelse error.OutOfMemory,
        .null_value => lnako_qjs_null(engine) orelse error.OutOfMemory,
        .boolean => |boolean| lnako_qjs_boolean(engine, @intFromBool(boolean)) orelse error.OutOfMemory,
        .number => |number| lnako_qjs_number(engine, number) orelse error.OutOfMemory,
        .bigint => |bigint| blk: {
            const text = try bigint.toString(runtime.allocator(), 10);
            defer runtime.allocator().free(text);
            break :blk lnako_qjs_bigint(engine, text.ptr, text.len) orelse return quickJsError(engine);
        },
        .string => |string| blk: {
            // 孤立サロゲートを置換せず保持する（QuickJSのUTF-8デコーダは
            // WTF-8のサロゲート符号点を16bitコード単位として受理する）。
            const text = try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator(), string.units);
            defer runtime.allocator().free(text);
            break :blk lnako_qjs_string(engine, text.ptr, text.len) orelse error.OutOfMemory;
        },
        .bytes => |bytes| blk: {
            if (bytes.bytes.len > std.math.maxInt(u32) or bytes.bytes.len > interop_collection_limit) {
                return error.QuickJsCollectionTooLarge;
            }
            const result = lnako_qjs_array(engine) orelse return error.OutOfMemory;
            errdefer lnako_qjs_value_free(result);
            for (bytes.bytes, 0..) |byte, index| {
                const item = lnako_qjs_number(engine, @floatFromInt(byte)) orelse return error.OutOfMemory;
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_index(result, @intCast(index), item) < 0) return quickJsError(engine);
            }
            break :blk result;
        },
        .array => |array| blk: {
            const identity = @intFromPtr(array);
            if (cache.cache.get(identity)) |cached| {
                try syncContents(state, runtime, engine, value, cached, cache);
                break :blk lnako_qjs_dup(cached) orelse error.OutOfMemory;
            }
            if (cache.converting.get(identity)) |existing| break :blk lnako_qjs_dup(existing) orelse error.OutOfMemory;
            if (array.external) |external| if (external.context == @as(*anyopaque, @ptrCast(engine))) {
                const result = lnako_qjs_dup(@ptrCast(@alignCast(external.handle))) orelse return error.OutOfMemory;
                errdefer lnako_qjs_value_free(result);
                try syncExternal(state, runtime, engine, value, result, cache);
                break :blk result;
            };
            const result = lnako_qjs_array(engine) orelse return error.OutOfMemory;
            errdefer lnako_qjs_value_free(result);
            try cache.converting.put(runtime.allocator(), identity, result);
            defer _ = cache.converting.remove(identity);
            try syncContents(state, runtime, engine, value, result, cache);
            try cache.cacheRaw(runtime.allocator(), identity, result);
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            const identity = @intFromPtr(dictionary);
            if (cache.cache.get(identity)) |cached| {
                try syncContents(state, runtime, engine, value, cached, cache);
                break :blk lnako_qjs_dup(cached) orelse error.OutOfMemory;
            }
            if (cache.converting.get(identity)) |existing| break :blk lnako_qjs_dup(existing) orelse error.OutOfMemory;
            if (dictionary.external) |external| if (external.context == @as(*anyopaque, @ptrCast(engine))) {
                const result = lnako_qjs_dup(@ptrCast(@alignCast(external.handle))) orelse return error.OutOfMemory;
                errdefer lnako_qjs_value_free(result);
                try syncExternal(state, runtime, engine, value, result, cache);
                break :blk result;
            };
            const result = lnako_qjs_object(engine) orelse return error.OutOfMemory;
            errdefer lnako_qjs_value_free(result);
            try cache.converting.put(runtime.allocator(), identity, result);
            defer _ = cache.converting.remove(identity);
            try syncContents(state, runtime, engine, value, result, cache);
            try cache.cacheRaw(runtime.allocator(), identity, result);
            break :blk result;
        },
        .function => |function| switch (function.kind) {
            .external => |external| if (external.binding.context == @as(*anyopaque, @ptrCast(state)))
                lnako_qjs_dup(@ptrCast(@alignCast(external.binding.handle))) orelse error.OutOfMemory
            else
                error.QuickJsEngineMismatch,
            else => state.hostFunction(engine, value),
        },
        .promise => error.QuickJsPromiseBridgePending,
    };
}

fn syncExternal(state: *State, runtime: *Runtime, engine: *Engine, value: Value, raw: *RawValue, cache: *SyncCache) anyerror!void {
    const identity = switch (value) {
        .array => |array| @intFromPtr(array),
        .dictionary => |dictionary| @intFromPtr(dictionary),
        else => return,
    };
    if (cache.cache.get(identity)) |cached| {
        try syncContents(state, runtime, engine, value, cached, cache);
        return;
    }
    try syncContents(state, runtime, engine, value, raw, cache);
    try cache.cacheRaw(runtime.allocator(), identity, raw);
}

fn nakoIndexIsPresent(array: *value_mod.Array, index: usize) bool {
    if (index >= array.items.items.len) return false;
    return if (index < array.presence.items.len) array.presence.items[index] else true;
}

fn syncContents(state: *State, runtime: *Runtime, engine: *Engine, value: Value, raw: *RawValue, cache: *SyncCache) anyerror!void {
    const identity = switch (value) {
        .array => |array| @intFromPtr(array),
        .dictionary => |dictionary| @intFromPtr(dictionary),
        else => return,
    };
    if (cache.syncing.contains(identity)) return;
    try cache.syncing.put(runtime.allocator(), identity, {});
    defer _ = cache.syncing.remove(identity);
    switch (value) {
        .array => |array| {
            if (array.items.items.len > std.math.maxInt(u32) or array.items.items.len > interop_collection_limit) return error.QuickJsCollectionTooLarge;

            if (lnako_qjs_set_array_length(raw, @intCast(array.items.items.len)) < 0) return quickJsError(engine);
            // getter/host callbackの再入で配列が再割当てされても安全なよう複製する。
            const items = try runtime.allocator().alloc(Value, array.items.items.len);
            defer runtime.allocator().free(items);
            @memcpy(items, array.items.items);
            var items_frame = runtime.rootFrame();
            defer items_frame.deinit();
            for (items) |*item| try items_frame.protect(item);
            for (items, 0..) |item_value, index| {
                // Nako側で穴のインデックスはJSでも穴のままにする。
                if (!nakoIndexIsPresent(array, index)) {
                    if (lnako_qjs_delete_index(raw, @intCast(index)) < 0) return quickJsError(engine);
                    continue;
                }
                const item = try toRaw(state, runtime, engine, item_value, cache);
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_index(raw, @intCast(index), item) < 0) return quickJsError(engine);
            }
        },
        .dictionary => |dictionary| {
            var names: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (names.items) |name| runtime.allocator().free(name);
                names.deinit(runtime.allocator());
            }
            const key_count = dictionary.len();
            const nako_keys = try runtime.allocator().alloc(Value, key_count);
            defer runtime.allocator().free(nako_keys);
            const nako_values = try runtime.allocator().alloc(Value, key_count);
            defer runtime.allocator().free(nako_values);
            for (dictionary.keys(), 0..) |key, index| nako_keys[index] = .{ .string = key };
            @memcpy(nako_values, dictionary.values());
            var entries_frame = runtime.rootFrame();
            defer entries_frame.deinit();
            for (nako_keys) |*key| try entries_frame.protect(key);
            for (nako_values) |*item_value_ptr| try entries_frame.protect(item_value_ptr);
            for (nako_keys, nako_values) |key_value, item_value| {
                const key = key_value.string;
                const name = try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator(), key.units);
                defer runtime.allocator().free(name);
                // 定義/取得/削除判定はすべてWTF-8で揃える。`lnako_qjs_key` も
                // 孤立サロゲートをWTF-8で返すため、lossy UTF-8で比較すると
                // 孤立サロゲートのキーが直後の削除ループで消える。
                const owned_name = try runtime.allocator().dupe(u8, name);
                names.append(runtime.allocator(), owned_name) catch |failure| {
                    runtime.allocator().free(owned_name);
                    return failure;
                };
                const name_z = try runtime.allocator().dupeSentinel(u8, name, 0);
                defer runtime.allocator().free(name_z);
                const item = try toRaw(state, runtime, engine, item_value, cache);
                defer lnako_qjs_value_free(item);
                // 未変更のプロパティは再代入しない（frozen objectでも不要な失敗を
                // 起こさない）。変更されたキーだけをown data propertyとして定義する。
                const has_own = lnako_qjs_has_own_property(raw, name_z.ptr);
                if (has_own < 0) return quickJsError(engine);
                if (has_own != 0) {
                    const current = lnako_qjs_get_own_property(raw, name_z.ptr) orelse return quickJsError(engine);
                    defer lnako_qjs_value_free(current);
                    const equal = lnako_qjs_strict_equal(current, item);
                    if (equal < 0) return quickJsError(engine);
                    if (equal != 0) continue;
                }
                if (lnako_qjs_define_property(raw, name_z.ptr, item) < 0) return quickJsError(engine);
            }
            // ProxyのownKeysが投げた例外は内部エラー名に置き換えず元の文言を残す。
            const keys = lnako_qjs_keys(raw) orelse return conversionFailure(runtime, raw);
            defer lnako_qjs_keys_free(keys);
            var index: usize = 0;
            while (index < lnako_qjs_keys_length(keys)) : (index += 1) {
                var name_length: usize = 0;
                const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
                const name = name_pointer[0..name_length];
                var listed = false;
                for (names.items) |candidate| {
                    if (std.mem.eql(u8, candidate, name)) {
                        listed = true;
                        break;
                    }
                }
                if (listed) continue;
                const name_z = try runtime.allocator().dupeSentinel(u8, name, 0);
                defer runtime.allocator().free(name_z);
                if (lnako_qjs_delete_property(raw, name_z.ptr) < 0) return quickJsError(engine);
            }
        },
        else => unreachable,
    }
}

fn refreshExternal(state: *State, runtime: *Runtime, value: Value, raw: *RawValue) !void {
    if ((value != .array and value != .dictionary) or lnako_qjs_identity(raw) == 0) return;
    var conversion = Conversion{ .state = state, .runtime = runtime, .wtf8_strings = true };
    defer conversion.seen.deinit(runtime.allocator());
    try conversion.refresh(value, raw);
}

pub fn fromRaw(state: *State, runtime: *Runtime, raw: *RawValue) !Value {
    var conversion = Conversion{ .state = state, .runtime = runtime, .wtf8_strings = true };
    defer conversion.seen.deinit(runtime.allocator());
    return conversion.convert(raw);
}

/// `JSオブジェクト取得` / `JSメソッド実行` の戻り値変換。AOTの
/// `resultFromRaw` と同じ規則で、プリミティブに加えて配列/辞書を再帰変換し、
/// 各配列/辞書へexternal bindingを付与する。Promise・関数・BigInt・bytesは
/// 明示的な未対応エラーにしてAOTと文言を揃える。
pub fn interopFromRaw(state: *State, runtime: *Runtime, raw: *RawValue) !Value {
    var conversion = Conversion{ .state = state, .runtime = runtime, .mode = .interop_result };
    defer conversion.seen.deinit(runtime.allocator());
    return conversion.convert(raw);
}

pub const ConversionMode = enum { full, interop_result };

/// JS→Nako結果変換のネスト上限。AOTの同名上限と同じ値にし、深い非循環
/// オブジェクトでもスタック枯渇しないよう明示エラーにする。
pub const max_interop_conversion_depth: usize = 64;

/// `JSオブジェクト取得` / `JSメソッド実行` の戻り値変換で受け付ける配列要素/
/// 辞書キー数の上限（テストで差し替え可能）。AOTの `safe_array_element_limit`
/// と同じ値にして、疎配列の巨大lengthや巨大なキー数で一括確保しない。
const interop_collection_limit: usize = 1_000_000;

/// 1回のdispatch（引数変換〜呼出し後の再同期）に閉じた同期キャッシュ。
/// Stateに持たせると入れ子dispatchで解放・再利用が競合するため、呼出し側が
/// ローカルに生成してtoRaw/syncExternalへ渡す。
const SyncCache = struct {
    converting: std.AutoHashMapUnmanaged(usize, *RawValue) = .empty,
    syncing: std.AutoHashMapUnmanaged(usize, void) = .empty,
    cache: std.AutoHashMapUnmanaged(usize, *RawValue) = .empty,
    owned: std.ArrayListUnmanaged(*RawValue) = .empty,
    depth: usize = 0,

    fn deinit(self: *SyncCache, allocator: std.mem.Allocator) void {
        for (self.owned.items) |raw| lnako_qjs_value_free(raw);
        self.owned.deinit(allocator);
        self.cache.deinit(allocator);
        self.syncing.deinit(allocator);
        self.converting.deinit(allocator);
    }

    fn cacheRaw(self: *SyncCache, allocator: std.mem.Allocator, identity: usize, raw: *RawValue) !void {
        const cached = lnako_qjs_dup(raw) orelse return error.OutOfMemory;
        errdefer lnako_qjs_value_free(cached);
        try self.owned.append(allocator, cached);
        errdefer _ = self.owned.pop();
        try self.cache.put(allocator, identity, cached);
    }
};

pub const Conversion = struct {
    state: *State,
    runtime: *Runtime,
    mode: ConversionMode = .full,
    /// 今回の変換で受け付ける配列要素/辞書キー数の上限（テストで差し替え可能）。
    limit: usize = interop_collection_limit,
    depth: usize = 0,
    /// refreshではJS側の孤立サロゲート文字列を可逆に保持する。
    wtf8_strings: bool = false,
    seen: std.AutoHashMapUnmanaged(usize, Value) = .empty,

    /// external値のNako側コピーをJS側の現在値で再構築する。途中で変換に失敗して
    /// も元の内容を失わないよう、まず一時的な配列/辞書へ構築し、成功後に中身だけ
    /// 差し替える（clear→再構築の破壊的な経路を避ける）。キー列挙の例外文言は
    /// `conversionFailure` で保持する（回帰テストから直接呼べるようpubにする）。
    pub fn refresh(self: *Conversion, value: Value, raw: *RawValue) !void {
        try self.seen.put(self.runtime.allocator(), lnako_qjs_identity(raw), value);
        switch (value) {
            .array => |array| {
                const length = lnako_qjs_array_length(raw);
                if (length > self.limit) return error.QuickJsCollectionTooLarge;
                var fresh = try self.runtime.createArray();
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&fresh);
                for (0..length) |index| {
                    const present = lnako_qjs_has_index(raw, @intCast(index));
                    if (present < 0) return error.QuickJsConversionFailed;
                    if (present == 0) {
                        _ = try fresh.array.push(.undefined);
                        fresh.array.presence.items[fresh.array.presence.items.len - 1] = false;
                        continue;
                    }
                    const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
                    _ = try fresh.array.push(try self.convert(item));
                }
                std.mem.swap(std.ArrayList(Value), &array.items, &fresh.array.items);
                std.mem.swap(std.ArrayList(bool), &array.presence, &fresh.array.presence);
            },
            .dictionary => |dictionary| {
                var fresh = try self.runtime.createDictionary();
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&fresh);
                const keys = lnako_qjs_keys(raw) orelse return conversionFailure(self.runtime, raw);
                defer lnako_qjs_keys_free(keys);
                const key_count = lnako_qjs_keys_length(keys);
                if (key_count > self.limit) return error.QuickJsCollectionTooLarge;
                for (0..key_count) |index| {
                    var name_length: usize = 0;
                    const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
                    const name = name_pointer[0..name_length];
                    const name_z = try self.runtime.allocator().dupeSentinel(u8, name, 0);
                    defer self.runtime.allocator().free(name_z);
                    const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
                    try dictionarySetBridgeKey(self.runtime, fresh.dictionary, name, try self.convert(item));
                }
                std.mem.swap(@TypeOf(dictionary.map), &dictionary.map, &fresh.dictionary.map);
            },
            else => {},
        }
    }

    pub fn convert(self: *Conversion, raw: *RawValue) anyerror!Value {
        if (self.depth >= max_interop_conversion_depth) {
            lnako_qjs_value_free(raw);
            return error.QuickJsNestingTooDeep;
        }
        self.depth += 1;
        defer self.depth -= 1;
        const kind = lnako_qjs_kind(raw);
        switch (kind) {
            .undefined => {
                lnako_qjs_value_free(raw);
                return .undefined;
            },
            .null_value => {
                lnako_qjs_value_free(raw);
                return .null_value;
            },
            .boolean => {
                const result = Value{ .boolean = lnako_qjs_to_boolean(raw) != 0 };
                lnako_qjs_value_free(raw);
                return result;
            },
            .number => {
                var number: f64 = 0;
                if (lnako_qjs_to_number(raw, &number) < 0) {
                    lnako_qjs_value_free(raw);
                    return error.QuickJsConversionFailed;
                }
                lnako_qjs_value_free(raw);
                return .{ .number = number };
            },
            .string => {
                const text = rawText(raw) catch |failure| {
                    lnako_qjs_value_free(raw);
                    return failure;
                };
                defer lnako_qjs_free_string(text.pointer);
                // `JS関数実行` の戻り値はAOTと同じく、孤立サロゲートを保持した
                // WTF-8経路でNako文字列へ変換する。他の経路は既存のstrict UTF-8。
                const result = if (self.mode != .full or self.wtf8_strings)
                    wtf8Value(self.runtime, text.slice()) catch |failure| {
                        lnako_qjs_value_free(raw);
                        return failure;
                    }
                else
                    self.runtime.stringUtf8(text.slice()) catch |failure| {
                        lnako_qjs_value_free(raw);
                        return failure;
                    };
                lnako_qjs_value_free(raw);
                return result;
            },
            .bigint => {
                // BigIntは `JS実行` のfull変換・resyncで共有する。`JSオブジェクト取得`
                // / `JSメソッド実行` の制限付き結果変換ではAOTと同じく拒否する。
                // 変換・割当て失敗時もrawを確実に解放する。
                if (self.mode == .interop_result) {
                    lnako_qjs_value_free(raw);
                    return error.QuickJsUnsupportedInteropResult;
                }
                defer lnako_qjs_value_free(raw);
                const text = try rawText(raw);
                defer lnako_qjs_free_string(text.pointer);
                const literal = try std.fmt.allocPrint(self.runtime.allocator(), "{s}n", .{text.slice()});
                defer self.runtime.allocator().free(literal);
                return self.runtime.bigIntLiteral(literal);
            },
            .function => {
                if (self.mode == .interop_result) {
                    lnako_qjs_value_free(raw);
                    return error.QuickJsUnsupportedInteropResult;
                }
                errdefer lnako_qjs_value_free(raw);
                const engine = rawEngine(raw);
                const name_value = lnako_qjs_get_property(raw, "name");
                defer if (name_value) |value| lnako_qjs_value_free(value);
                if (name_value == null) {
                    if (lnako_qjs_take_error(engine)) |text| lnako_qjs_free_string(text);
                }
                const name_text = if (name_value) |value| rawText(value) catch blk: {
                    if (lnako_qjs_take_error(engine)) |text| lnako_qjs_free_string(text);
                    break :blk null;
                } else null;
                defer if (name_text) |text| lnako_qjs_free_string(text.pointer);
                var name = try wtf8Value(self.runtime, if (name_text) |text| text.slice() else "<js>");
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&name);
                return self.runtime.createExternalFunction(name.string, 0, .{ .binding = functionBinding(self.state, raw), .callFn = externalCall });
            },
            .array => return self.convertArray(raw),
            .object => {
                if (self.mode == .interop_result and lnako_qjs_is_bytes(raw) != 0) {
                    lnako_qjs_value_free(raw);
                    return error.QuickJsUnsupportedInteropResult;
                }
                return self.convertObject(raw);
            },
            .promise => {
                if (self.mode == .interop_result) {
                    lnako_qjs_value_free(raw);
                    return error.QuickJsUnsupportedInteropResult;
                }
                return self.convertObject(raw);
            },
        }
    }

    fn convertArray(self: *Conversion, raw: *RawValue) anyerror!Value {
        const identity = lnako_qjs_identity(raw);
        if (self.seen.get(identity)) |existing| {
            lnako_qjs_value_free(raw);
            return existing;
        }
        const length = lnako_qjs_array_length(raw);
        if (length > self.limit) {
            lnako_qjs_value_free(raw);
            return error.QuickJsCollectionTooLarge;
        }
        var raw_owned = true;
        errdefer if (raw_owned) lnako_qjs_value_free(raw);
        var result = try self.runtime.createArray();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        result.array.external = objectBinding(@ptrCast(rawEngine(raw)), raw);
        raw_owned = false;
        try self.seen.put(self.runtime.allocator(), identity, result);
        for (0..length) |index| {
            const present = lnako_qjs_has_index(raw, @intCast(index));
            if (present < 0) return error.QuickJsConversionFailed;
            if (present == 0) {
                _ = try result.array.push(.undefined);
                result.array.presence.items[result.array.presence.items.len - 1] = false;
                continue;
            }
            const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
            _ = try result.array.push(try self.convert(item));
        }
        return result;
    }

    fn convertObject(self: *Conversion, raw: *RawValue) anyerror!Value {
        const identity = lnako_qjs_identity(raw);
        if (self.seen.get(identity)) |existing| {
            lnako_qjs_value_free(raw);
            return existing;
        }
        // キー数上限の判定は所有権を辞書へ移す前に行う。移した後のrawは辞書の
        // external bindingが所有するため、ここで明示解放してはならない。
        const keys = lnako_qjs_keys(raw) orelse {
            // rawはまだ辞書へ所有権を移していないため、例外文言を取り出してから
            // 解放する（解放後のraw参照を避ける）。
            const failure = conversionFailure(self.runtime, raw);
            lnako_qjs_value_free(raw);
            return failure;
        };
        defer lnako_qjs_keys_free(keys);
        const key_count = lnako_qjs_keys_length(keys);
        if (key_count > self.limit) {
            lnako_qjs_value_free(raw);
            return error.QuickJsCollectionTooLarge;
        }
        var raw_owned = true;
        errdefer if (raw_owned) lnako_qjs_value_free(raw);
        var result = try self.runtime.createDictionary();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        result.dictionary.external = objectBinding(@ptrCast(rawEngine(raw)), raw);
        raw_owned = false;
        try self.seen.put(self.runtime.allocator(), identity, result);
        for (0..key_count) |index| {
            var name_length: usize = 0;
            const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
            const name = name_pointer[0..name_length];
            const name_z = try self.runtime.allocator().dupeSentinel(u8, name, 0);
            defer self.runtime.allocator().free(name_z);
            const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
            // AOTのfull変換（jsEvalResult）と同じくWTF-8キーを使い、孤立サロゲートを
            // 含むJS辞書キーでもAOT/interpreterの観測を揃える。`wtf8_strings` は
            // refresh/fromRaw が真にする。
            const converted = try self.convert(item);
            if (self.mode != .full or self.wtf8_strings) {
                try dictionarySetBridgeKey(self.runtime, result.dictionary, name, converted);
            } else {
                try common.dictionarySetUtf8(self.runtime, result.dictionary, name, converted);
            }
        }
        return result;
    }
};

const RawText = struct {
    pointer: [*:0]u8,
    length: usize,

    fn slice(self: RawText) []const u8 {
        return self.pointer[0..self.length];
    }
};

fn rawText(raw: *const RawValue) !RawText {
    var length: usize = 0;
    const pointer = lnako_qjs_to_string(raw, &length) orelse return error.QuickJsConversionFailed;
    return .{ .pointer = pointer, .length = length };
}

/// JSのWTF-8（孤立サロゲートを含み得る）をNakoのUTF-16文字列へ可逆変換する。
/// AOTのfull変換（compat_js_result.zigのwtf8ToWtf16LeAlloc）と同じ規則。
pub fn wtf8Value(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.wtf8ToWtf16LeAlloc(runtime.allocator(), text);
    defer runtime.allocator().free(units);
    return runtime.stringCodeUnits(units);
}

/// WTF-8のキーをNako辞書へ設定する。`common.dictionarySetUtf8` はUTF-8 strict
/// だが、JS→Nakoのfull変換はJS文字列の孤立サロゲートを保持するため、
/// AOTと同じWTF-8経路を使う。
pub fn dictionarySetBridgeKey(runtime: *Runtime, dictionary: *value_mod.Dictionary, key: []const u8, value: Value) !void {
    var value_root = value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&value_root);
    var key_value = try wtf8Value(runtime, key);
    try roots.protect(&key_value);
    try dictionary.set(key_value.string, value_root);
}

fn rawEngine(raw: *RawValue) *Engine {
    return lnako_qjs_value_engine(raw) orelse unreachable;
}

fn quickJsError(engine: *Engine) anyerror {
    if (lnako_qjs_take_error(engine)) |message| {
        std.debug.print("QuickJS: {s}\n", .{std.mem.span(message)});
        lnako_qjs_free_string(message);
    }
    return error.QuickJsExecutionFailed;
}

/// 変換途中のQuickJS例外を失わずに報告する。AOT側 `conversionFailure` と
/// 同じく、bridgeがNULLを返した場合はengineのlast_errorをNakoのfailure
/// messageへ記録し、内部エラー名ではなくJS例外の文言を残したまま実行失敗を
/// 返す。例外文言が無い場合だけ変換失敗にする。
fn conversionFailure(runtime: *Runtime, raw: *const RawValue) anyerror {
    const engine = lnako_qjs_value_engine(raw) orelse return error.QuickJsConversionFailed;
    const message = lnako_qjs_take_error(engine) orelse return error.QuickJsConversionFailed;
    defer lnako_qjs_free_string(message);
    try runtime.setFailureMessage(std.mem.span(message));
    return error.QuickJsExecutionFailed;
}

test "QuickJS互換ビルド状態を公開する" {
    try std.testing.expectEqual(build_options.quickjs_enabled, available());
}

test "QuickJSモジュール名のWindows区切りを正規化する" {
    const filename = try moduleFilename(std.testing.allocator, "C:\\work\\plugin\\main.mjs");
    defer std.testing.allocator.free(filename);
    try std.testing.expectEqualStrings("C:/work/plugin/main.mjs", filename);
}

test "package所有moduleのimport解決はpackage root外へのFS fallbackを拒否する" {
    if (!build_options.quickjs_enabled) return;
    // graph側の収集をすり抜けたimport形でも、referrerがpackage所有なら
    // module_normalizeの段でroot外解決を拒否する — loaderのfopen fallback
    // が境界の逃げ道にならないことを実FS上のfileで検証する。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.mjs", .data = "export const secret = 1;" });
    const base_abs = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_abs);
    const pkg_root = try std.fs.path.resolve(std.testing.allocator, &.{ base_abs, "pkg" });
    defer std.testing.allocator.free(pkg_root);
    const main_path = try std.fs.path.resolve(std.testing.allocator, &.{ pkg_root, "main.mjs" });
    defer std.testing.allocator.free(main_path);
    const inner_path = try std.fs.path.resolve(std.testing.allocator, &.{ pkg_root, "inner.mjs" });
    defer std.testing.allocator.free(inner_path);
    const helper_path = try std.fs.path.resolve(std.testing.allocator, &.{ pkg_root, "helper.mjs" });
    defer std.testing.allocator.free(helper_path);
    const free_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_abs, "free.mjs" });
    defer std.testing.allocator.free(free_path);
    const missing_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_abs, "missing.mjs" });
    defer std.testing.allocator.free(missing_path);

    const engine = lnako_qjs_new() orelse return error.SkipZigTest;
    defer lnako_qjs_release(engine);
    const root_name = try moduleFilename(std.testing.allocator, pkg_root);
    defer std.testing.allocator.free(root_name);
    const main_name = try moduleFilename(std.testing.allocator, main_path);
    defer std.testing.allocator.free(main_name);
    const inner_name = try moduleFilename(std.testing.allocator, inner_path);
    defer std.testing.allocator.free(inner_name);
    const helper_name = try moduleFilename(std.testing.allocator, helper_path);
    defer std.testing.allocator.free(helper_name);
    const free_name = try moduleFilename(std.testing.allocator, free_path);
    defer std.testing.allocator.free(free_name);
    const missing_name = try moduleFilename(std.testing.allocator, missing_path);
    defer std.testing.allocator.free(missing_name);

    // package所有として登録されたmoduleのimportがroot外を指す場合、
    // 静的form・動的formともに実行時のmodule解決は失敗する（fopenへ到達しない）。
    const escaping = "import { secret } from '../outside.mjs'; export default secret;";
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, main_name.ptr, escaping.ptr, escaping.len, root_name.ptr));
    try std.testing.expect(lnako_qjs_eval_module(engine, escaping.ptr, escaping.len, main_name.ptr) == null);
    const message = lnako_qjs_take_error(engine) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_free_string(message);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(message), "package root") != null);

    // 動的importのrejection経路 — specifierがroot外ならnormalize段で
    // 例外を投げ、module解決はrejectedになる。
    const dynamic_escaping = "export default await import('../outside.mjs');";
    const dynamic_path = try std.fs.path.resolve(std.testing.allocator, &.{ pkg_root, "dynamic.mjs" });
    defer std.testing.allocator.free(dynamic_path);
    const dynamic_name = try moduleFilename(std.testing.allocator, dynamic_path);
    defer std.testing.allocator.free(dynamic_name);
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, dynamic_name.ptr, dynamic_escaping.ptr, dynamic_escaping.len, root_name.ptr));
    try std.testing.expect(lnako_qjs_eval_module(engine, dynamic_escaping.ptr, dynamic_escaping.len, dynamic_name.ptr) == null);
    const dynamic_message = lnako_qjs_take_error(engine) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_free_string(dynamic_message);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(dynamic_message), "package root") != null);

    // root内のspecifierは受理され、登録済みsourceが使われる。
    const inside = "import { ok } from './helper.mjs'; export default ok;";
    const helper = "export const ok = 7;";
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, inner_name.ptr, inside.ptr, inside.len, root_name.ptr));
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, helper_name.ptr, helper.ptr, helper.len, root_name.ptr));
    const inside_result = lnako_qjs_eval_module(engine, inside.ptr, inside.len, inner_name.ptr) orelse return error.TestUnexpectedResult;
    var actual: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_to_number(inside_result, &actual));
    try std.testing.expectEqual(@as(f64, 7), actual);
    lnako_qjs_value_free(inside_result);

    // package外module（root未登録）のFS fallbackは従来どおり動く。
    const free_source = "import { secret } from './outside.mjs'; export default secret;";
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, free_name.ptr, free_source.ptr, free_source.len, null));
    const free_result = lnako_qjs_eval_module(engine, free_source.ptr, free_source.len, free_name.ptr) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_to_number(free_result, &actual));
    try std.testing.expectEqual(@as(f64, 1), actual);
    lnako_qjs_value_free(free_result);

    // in-root symlink経由のroot外参照 — lexicalにはroot内だがcanonical
    // 解決後はroot外になるため、module_normalizeのcanonical検査で拒否
    // される（symlink非対応環境ではこの経路をskipする）。
    const link_ok = blk: {
        tmp.dir.symLink(std.testing.io, "../outside.mjs", "pkg/link.mjs", .{}) catch break :blk false;
        break :blk true;
    };
    if (link_ok) {
        const link_path = try std.fs.path.resolve(std.testing.allocator, &.{ pkg_root, "via_link.mjs" });
        defer std.testing.allocator.free(link_path);
        const link_name = try moduleFilename(std.testing.allocator, link_path);
        defer std.testing.allocator.free(link_name);
        const via_link = "import { secret } from './link.mjs'; export default secret;";
        try std.testing.expectEqual(@as(c_int, 0), lnako_qjs_add_module_source(engine, link_name.ptr, via_link.ptr, via_link.len, root_name.ptr));
        try std.testing.expect(lnako_qjs_eval_module(engine, via_link.ptr, via_link.len, link_name.ptr) == null);
        const link_message = lnako_qjs_take_error(engine) orelse return error.TestUnexpectedResult;
        defer lnako_qjs_free_string(link_message);
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(link_message), "package root") != null);
    }

    // root外moduleのroot外import — 未登録fileのfopen失敗は従来の拒否経路。
    const missing_source = "export default await import('./missing-target.mjs');";
    try std.testing.expect(lnako_qjs_eval_module(engine, missing_source.ptr, missing_source.len, missing_name.ptr) == null);
    const missing_message = lnako_qjs_take_error(engine) orelse return error.TestUnexpectedResult;
    defer lnako_qjs_free_string(missing_message);
}

/// ESM plugin の登録 shim を含む bootstrap。AOT runtime（`runtime/aot/compat_js.zig`）
/// も同じ JS 環境を必要とするため、source を公開して共有する。
pub const bootstrapSource =
    \\globalThis.sys = globalThis.sys || Object.create(null);
    \\sys.__findFunc = function(name, parent) { const f = sys.__findVar(name, undefined); if (typeof f === 'function') return f; throw new Error(`『${parent}』に実行できない関数が指定されました。`); };
    \\sys.__exec = function(name, params) { return globalThis.__lnako_hostExec(name, ...(Array.isArray(params) ? params : [params])); };
    \\sys.__setSore = function(value) { sys.__setSysVar('それ', value); return value; };
    \\sys.__getSore = function() { return sys.__getSysVar('それ'); };
    \\sys.pathSeparator = '/';
    \\sys.tags = Object.create(null);
    \\globalThis.__lnako_commands = Object.create(null);
    \\globalThis.__lnako_plugins = new WeakSet();
    \\globalThis.__lnako_plugin_registrations = new Map();
    \\globalThis.__lnako_qualified_keys = new Set();
    \\globalThis.__lnako_active_namespace = undefined;
    \\globalThis.__lnako_eval_plugins = [];
    \\globalThis.__lnako_registerPlugin = function(plugin, namespace) {
    \\  if (!plugin || (typeof plugin !== 'object' && typeof plugin !== 'function')) return;
    \\  const prefix = (typeof namespace === 'string' && namespace.length > 0) ? namespace + '__' : '';
    \\  let registrations = globalThis.__lnako_plugin_registrations.get(plugin);
    \\  if (!registrations) {
    \\    registrations = new Set();
    \\    globalThis.__lnako_plugin_registrations.set(plugin, registrations);
    \\  }
    \\  if (!registrations.has(prefix)) {
    \\    registrations.add(prefix);
    \\    for (const name of Object.keys(plugin || {})) {
    \\      if (name === 'meta' || name === '初期化') continue;
    \\      if (prefix.length > 0 && name.indexOf('__') >= 0) continue;
    \\      const key = prefix + name;
    \\      // 無修飾登録がpackage修飾keyを上書きしないよう、修飾済みkeyは
    \\      // raw export による再代入を拒否する。逆方向（修飾がrawを
    \\      // 上書き）は許容し、登録順序に依らず修飾側を優先させる。
    \\      if (prefix.length === 0 && globalThis.__lnako_qualified_keys.has(key)) continue;
    \\      globalThis.__lnako_commands[key] = plugin[name];
    \\      if (prefix.length > 0) globalThis.__lnako_qualified_keys.add(key);
    \\    }
    \\  }
    \\  if (!globalThis.__lnako_plugins.has(plugin)) {
    \\    globalThis.__lnako_plugins.add(plugin);
    \\    const initializer = plugin['初期化'];
    \\    if (typeof initializer === 'function') initializer(sys);
    \\    else if (initializer && typeof initializer.fn === 'function') initializer.fn(sys);
    \\  }
    \\};
    \\globalThis.__lnako_beginModuleEval = function(namespace) {
    \\  globalThis.__lnako_active_namespace = namespace;
    \\  globalThis.__lnako_eval_plugins = [];
    \\};
    \\globalThis.__lnako_reregisterEvalPlugins = function(namespacesJson) {
    \\  const pending = globalThis.__lnako_eval_plugins;
    \\  globalThis.__lnako_eval_plugins = [];
    \\  for (const plugin of pending) {
    \\    for (const ns of JSON.parse(namespacesJson)) globalThis.__lnako_registerPlugin(plugin, ns);
    \\  }
    \\};
    \\globalThis.navigator = globalThis.navigator || { nako3: { addPluginObject: function(_name, plugin) { globalThis.__lnako_eval_plugins.push(plugin); globalThis.__lnako_registerPlugin(plugin, globalThis.__lnako_active_namespace); } } };
    \\globalThis.console = globalThis.console || { log: function(){}, error: function(){}, warn: function(){} };
;

comptime {
    _ = @import("quickjs_test.zig");
}
