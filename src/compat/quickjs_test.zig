//! interpreter 側 `--compat-js` の JS↔Nako 変換境界テスト（Issue #55）。
//!
//! `quickjs.zig` の `comptime { _ = @import("quickjs_test.zig"); }` から
//! 同一テストビルドへ取り込む。`*_test.zig` はソースサイズ検査の対象外なので、
//! 変換規則の回帰テストはこのファイルへ集約する。
const std = @import("std");
const build_options = @import("build_options");
const q = @import("quickjs.zig");
const value_mod = @import("../runtime/value.zig");

const Value = q.Value;
const Runtime = q.Runtime;
const Engine = q.Engine;
const RawValue = q.RawValue;

fn newEngine() !*Engine {
    return q.lnako_qjs_new() orelse error.SkipZigTest;
}

fn evalRaw(engine: *Engine, source: []const u8) !*RawValue {
    return q.lnako_qjs_eval(engine, source.ptr, source.len, "<quickjs-test>") orelse error.TestUnexpectedResult;
}

/// `State` は engine を所有しない（呼出し側で release する）ため、deinit 前に
/// engine を外す。`callExternalCallResult` は external binding の context が
/// 同じ State であることを要求するので、変換と実行で同じ State を共有する。
fn initState(runtime: *Runtime, engine: *Engine) q.State {
    var state = q.State.init(true);
    state.engine = engine;
    state.runtime = runtime;
    return state;
}

fn deinitState(state: *q.State) void {
    // この helper は engine を呼出し側が所有する形にするため、State.deinit より
    // 先に解放通知を外す（engine は後から release され、finalizer が走る）。
    if (state.engine) |engine| q.lnako_qjs_set_host_release(engine, null);
    state.engine = null;
    state.deinit();
}

fn fullValue(state: *q.State, runtime: *Runtime, engine: *Engine, source: []const u8) !Value {
    return q.fromRaw(state, runtime, try evalRaw(engine, source));
}

fn interopValue(state: *q.State, runtime: *Runtime, engine: *Engine, source: []const u8) !Value {
    return q.interopFromRaw(state, runtime, try evalRaw(engine, source));
}

/// JS関数式を評価して `JS関数実行` の呼出し経路へ渡す。
fn callJs(state: *q.State, runtime: *Runtime, engine: *Engine, source: []const u8, arguments: []const Value) !Value {
    var callable = try fullValue(state, runtime, engine, source);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&callable);
    return q.callExternalCallResult(state, runtime, callable, arguments);
}

fn expectString(value: Value, expected: []const u8) !void {
    try std.testing.expect(value == .string);
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(units);
    try std.testing.expectEqualSlices(u16, units, value.string.units);
}

fn expectBigIntText(value: Value, expected: []const u8) !void {
    try std.testing.expect(value == .bigint);
    const text = try value.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn nativeNoop(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

fn key(runtime: *Runtime, text: []const u8) !*value_mod.String {
    return (try runtime.stringUtf8(text)).string;
}

fn stubInvoke(_: *anyopaque, _: Value, _: []const Value) anyerror!Value {
    return error.QuickJsValueNotCallable;
}

fn stubResolve(_: *anyopaque, _: []const u8) anyerror!Value {
    return error.QuickJsValueNotCallable;
}

fn ambiguousResolve(_: *anyopaque, _: []const u8) anyerror!Value {
    return error.AmbiguousGlobal;
}

fn stubGetGlobal(_: *anyopaque, _: []const u8) ?Value {
    return null;
}

fn stubSetGlobal(_: *anyopaque, _: []const u8, _: Value) anyerror!void {}

fn stubExec(_: *anyopaque, _: []const u8, _: []const Value) anyerror!Value {
    return error.QuickJsValueNotCallable;
}

const test_effects = q.Effects{
    .context = @ptrCast(&test_effect_context),
    .invokeFn = stubInvoke,
    .resolveFn = stubResolve,
    .getGlobalFn = stubGetGlobal,
    .setGlobalFn = stubSetGlobal,
    .execFn = stubExec,
};

var test_effect_context: u8 = 0;

const ambiguous_effects = q.Effects{
    .context = @ptrCast(&test_effect_context),
    .invokeFn = stubInvoke,
    .resolveFn = ambiguousResolve,
    .getGlobalFn = stubGetGlobal,
    .setGlobalFn = stubSetGlobal,
    .execFn = stubExec,
};

test "interpreter JSオブジェクト取得は1引数の曖昧名を伝播し未解決名はnullにする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var requested = try runtime.stringUtf8("X");
    try roots.protect(&requested);

    // AOT（compat_js.zig）と同じく、複数候補で曖昧な名前はnullへ潰さず
    // 呼出し側へ伝播する。
    try std.testing.expectError(
        error.AmbiguousGlobal,
        q.call(&runtime, &state, ambiguous_effects, "JSオブジェクト取得", &.{requested}),
    );

    // 未解決名だけが従来どおり .null_value になる。
    const unresolved = try q.call(&runtime, &state, test_effects, "JSオブジェクト取得", &.{requested});
    try std.testing.expect(unresolved != null);
    try std.testing.expect(unresolved.? == .null_value);
}

test "interpreter JS関数実行はネストした配列・辞書をfull変換する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var scratch: [8]Value = @splat(Value{ .undefined = {} });
    for (&scratch) |*value| try roots.protect(value);
    var arguments: [3]Value = @splat(Value{ .undefined = {} });
    for (&arguments) |*value| try roots.protect(value);

    // [[1,2]]
    scratch[0] = try runtime.createArray();
    _ = try scratch[0].array.push(.{ .number = 1 });
    _ = try scratch[0].array.push(.{ .number = 2 });
    scratch[1] = try runtime.createArray();
    _ = try scratch[1].array.push(scratch[0]);
    const nested_array = try callJs(&state, &runtime, engine, "a => a[0][0] + a[0][1]", &.{scratch[1]});
    try std.testing.expectEqual(@as(f64, 3), nested_array.number);

    // {a:{b:5}}
    const a_key = (try key(&runtime, "a"));
    const b_key = (try key(&runtime, "b"));
    scratch[2] = try runtime.createDictionary();
    try scratch[2].dictionary.set(b_key, .{ .number = 5 });
    scratch[3] = try runtime.createDictionary();
    try scratch[3].dictionary.set(a_key, scratch[2]);
    const nested_dictionary = try callJs(&state, &runtime, engine, "o => o.a.b", &.{scratch[3]});
    try std.testing.expectEqual(@as(f64, 5), nested_dictionary.number);

    // BigIntは10進文字列経由で往復する。
    scratch[4] = try runtime.bigIntLiteral("9007199254740993");
    const bigint_result = try callJs(&state, &runtime, engine, "v => v + 1n", &.{scratch[4]});
    try expectBigIntText(bigint_result, "9007199254740994");

    // bytesは0..255の数値配列として渡る。
    scratch[5] = try runtime.createBytes(&.{ 1, 2, 255 });
    const bytes_result = try callJs(&state, &runtime, engine, "b => b[0] + b[2]", &.{scratch[5]});
    try std.testing.expectEqual(@as(f64, 256), bytes_result.number);

    // Nako関数値はhost callbackとして渡る（呼出しはしない）。
    const function_name = try key(&runtime, "callback");
    scratch[6] = try runtime.createNativeFunction(function_name, 0, nativeNoop, &.{});
    const function_result = try callJs(&state, &runtime, engine, "f => typeof f", &.{scratch[6]});
    try expectString(function_result, "function");

    // JS関数値は同じJS参照のまま実引数へ渡り、JSから直接呼べる。
    scratch[7] = try fullValue(&state, &runtime, engine, "x => x + 1");
    const js_function_result = try callJs(&state, &runtime, engine, "f => f(41)", &.{scratch[7]});
    try std.testing.expectEqual(@as(f64, 42), js_function_result.number);

    // 引数コンテナへspreadされる配列も同じfull変換を通る。
    arguments[0] = try runtime.createArray();
    _ = try arguments[0].array.push(.{ .number = 2 });
    _ = try arguments[0].array.push(.{ .number = 3 });
    const spread_result = try callJs(&state, &runtime, engine, "(a, b) => a + b", arguments[0].array.items.items);
    try std.testing.expectEqual(@as(f64, 5), spread_result.number);
}

test "interpreter JS関数実行は循環・疎配列・WTF-8を保持する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var scratch: [4]Value = @splat(Value{ .undefined = {} });
    for (&scratch) |*value| try roots.protect(value);

    // 自己参照配列は同じJS参照の循環として渡る。
    scratch[0] = try runtime.createArray();
    _ = try scratch[0].array.push(scratch[0]);
    const cyclic_result = try callJs(&state, &runtime, engine, "a => a === a[0]", &.{scratch[0]});
    try std.testing.expect(cyclic_result.boolean);

    // 疎配列の穴はJSでも穴のまま渡る。
    scratch[1] = try runtime.createArray();
    _ = try scratch[1].array.push(.{ .number = 1 });
    _ = try scratch[1].array.push(.{ .number = 2 });
    _ = try scratch[1].array.push(.{ .number = 3 });
    scratch[1].array.presence.items[1] = false;
    const sparse_result = try callJs(&state, &runtime, engine, "a => (1 in a) ? 0 : (a.length === 3 ? 1 : 2)", &.{scratch[1]});
    try std.testing.expectEqual(@as(f64, 1), sparse_result.number);

    // 孤立サロゲートの文字列・辞書キーはWTF-8で往復する。
    scratch[2] = try runtime.stringCodeUnits(&.{0xD800});
    scratch[3] = try runtime.createDictionary();
    try scratch[3].dictionary.set(scratch[2].string, .{ .number = 1 });
    const surrogate_code = try callJs(&state, &runtime, engine, "(s) => s.charCodeAt(0)", &.{scratch[2]});
    try std.testing.expectEqual(@as(f64, 55296), surrogate_code.number);
    const surrogate_keys = try callJs(
        &state,
        &runtime,
        engine,
        "(o) => { const ks = Object.getOwnPropertyNames(o); return ks.length + ':' + (ks.length ? ks[0].charCodeAt(0) : -1); }",
        &.{scratch[3]},
    );
    try expectString(surrogate_keys, "1:55296");
    const surrogate_key_value = try callJs(&state, &runtime, engine, "(o) => o['\\uD800']", &.{scratch[3]});
    try std.testing.expectEqual(@as(f64, 1), surrogate_key_value.number);

    // 戻り値の孤立サロゲートも文字列・辞書キーの両方で保持する。
    const returned_string = try callJs(&state, &runtime, engine, "() => '\\uD800'", &.{});
    try std.testing.expect(returned_string == .string);
    try std.testing.expectEqualSlices(u16, &.{0xD800}, returned_string.string.units);
    const returned_dictionary = try callJs(&state, &runtime, engine, "() => ({'\\uD800': 1})", &.{});
    try std.testing.expect(returned_dictionary == .dictionary);
    const keys = returned_dictionary.dictionary.keys();
    try std.testing.expectEqualSlices(u16, &.{0xD800}, keys[0].units);
    try std.testing.expectEqual(@as(f64, 1), returned_dictionary.dictionary.get(keys[0]).?.number);
}

test "interpreter JS関数実行は戻り値をJS実行と同じfull変換にする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);

    // ネストした配列・辞書・BigInt・bytes（TypedArray）を保持する。
    const nested = try callJs(&state, &runtime, engine, "() => [1, {x: 2}]", &.{});
    try std.testing.expect(nested == .array);
    try std.testing.expectEqual(@as(f64, 1), nested.array.items.items[0].number);
    try std.testing.expectEqual(@as(f64, 2), nested.array.items.items[1].dictionary.get(nested.array.items.items[1].dictionary.keys()[0]).?.number);

    const bigint_value = try callJs(&state, &runtime, engine, "() => 1n", &.{});
    try expectBigIntText(bigint_value, "1");

    const bytes_value = try callJs(&state, &runtime, engine, "() => new Uint8Array([1, 2])", &.{});
    try std.testing.expect(bytes_value == .dictionary);

    // JS関数値はexternal関数値として保持し、同じJS参照を直接呼べる。
    const function_value = try callJs(&state, &runtime, engine, "() => (x) => x + 1", &.{});
    try std.testing.expect(function_value == .function);
    try std.testing.expect(function_value.function.kind == .external);
    const function_result = try q.callExternalCallResult(&state, &runtime, function_value, &.{.{ .number = 41 }});
    try std.testing.expectEqual(@as(f64, 42), function_result.number);

    // 自己参照・疎配列も同じfull変換で保持する。
    const cyclic = try callJs(&state, &runtime, engine, "() => { const a = [1]; a.push(a); return a; }", &.{});
    try std.testing.expect(cyclic == .array);
    try std.testing.expect(cyclic.array.items.items[1].array == cyclic.array);
    const sparse = try callJs(&state, &runtime, engine, "() => [1, , 3]", &.{});
    try std.testing.expect(sparse == .array);
    try std.testing.expectEqual(@as(usize, 3), sparse.array.items.items.len);
    try std.testing.expect(!sparse.array.isPresent(1));
}

test "interpreter JS関数実行のPromiseは解決/拒否/pending/Nako Promise引数を扱う" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var arguments: [2]Value = @splat(Value{ .undefined = {} });
    for (&arguments) |*value| try roots.protect(value);

    const resolved = try callJs(&state, &runtime, engine, "() => Promise.resolve([1, {x: 1n}])", &.{});
    try std.testing.expect(resolved == .array);
    const resolved_entry = resolved.array.items.items[1];
    try std.testing.expect(resolved_entry == .dictionary);
    try expectBigIntText(resolved_entry.dictionary.get(resolved_entry.dictionary.keys()[0]).?, "1");

    // rejectはreject理由、pendingはbridgeの文言で明示エラーにする。
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        callJs(&state, &runtime, engine, "() => Promise.reject(new Error('x'))", &.{}),
    );
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        callJs(&state, &runtime, engine, "() => new Promise(() => {})", &.{}),
    );

    // Nako Promiseは実引数として同期変換できない。
    arguments[0] = try runtime.createPromise();
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        callJs(&state, &runtime, engine, "x => x", &.{arguments[0]}),
    );
    try std.testing.expectEqualStrings(q.unsupported_call_argument_message, runtime.failureMessage().?);

    // 配列の入れ子に入れたPromiseも同じ文言で拒否する。
    arguments[1] = try runtime.createArray();
    _ = try arguments[1].array.push(arguments[0]);
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        callJs(&state, &runtime, engine, "x => x", &.{arguments[1]}),
    );
    try std.testing.expectEqualStrings(q.unsupported_call_argument_message, runtime.failureMessage().?);
}

test "interpreter JSオブジェクト取得は非externalコンテナをfull変換する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var scratch: [6]Value = @splat(Value{ .undefined = {} });
    for (&scratch) |*value| try roots.protect(value);

    // JSオブジェクト取得([[1]], "0") は成功し、external bindingを保持する。
    scratch[0] = try runtime.createArray();
    _ = try scratch[0].array.push(.{ .number = 1 });
    scratch[1] = try runtime.createArray();
    _ = try scratch[1].array.push(scratch[0]);
    var index_key = try runtime.stringUtf8("0");
    try roots.protect(&index_key);
    const nested = try q.lookupExternalProperty(&state, &runtime, engine, scratch[1], index_key);
    try std.testing.expect(nested == .array);
    try std.testing.expectEqual(@as(f64, 1), nested.array.items.items[0].number);
    try std.testing.expect(nested.array.external != null);

    // ネストした辞書もfull変換で取得する。
    var a_key = try runtime.stringUtf8("a");
    try roots.protect(&a_key);
    var b_key = try runtime.stringUtf8("b");
    try roots.protect(&b_key);
    scratch[2] = try runtime.createDictionary();
    try scratch[2].dictionary.set(b_key.string, .{ .number = 5 });
    scratch[3] = try runtime.createDictionary();
    try scratch[3].dictionary.set(a_key.string, scratch[2]);
    const nested_dictionary = try q.lookupExternalProperty(&state, &runtime, engine, scratch[3], a_key);
    try std.testing.expect(nested_dictionary == .dictionary);
    try std.testing.expectEqual(@as(f64, 5), nested_dictionary.dictionary.get(b_key.string).?.number);

    // コンテナ内のBigIntも、制限付き結果変換ではAOTと同じく明示エラーにする。
    // レシーバ自体は`JS実行`相当のfull変換で作る（BigIntを保持する）。
    scratch[4] = try fullValue(&state, &runtime, engine, "[1n]");
    try std.testing.expectError(
        error.QuickJsUnsupportedInteropResult,
        q.lookupExternalProperty(&state, &runtime, engine, scratch[4], index_key),
    );
    try std.testing.expectEqualStrings(q.unsupported_object_get_message, runtime.failureMessage().?);

    // コンテナ内のbytesはAOTと同じく明示エラーにする。
    scratch[5] = try runtime.createBytes(&.{1});
    var bytes_array = try runtime.createArray();
    try roots.protect(&bytes_array);
    _ = try bytes_array.array.push(scratch[5]);
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        q.lookupExternalProperty(&state, &runtime, engine, bytes_array, index_key),
    );
    try std.testing.expectEqualStrings(q.unsupported_object_get_message, runtime.failureMessage().?);

    // トップレベルの関数・BigInt・bytes・Promiseは拒否する。
    const function_name = try key(&runtime, "f");
    const rejected = [_]Value{
        try runtime.createNativeFunction(function_name, 0, nativeNoop, &.{}),
        try runtime.bigIntLiteral("1"),
        try runtime.createBytes(&.{1}),
        try runtime.createPromise(),
    };
    for (rejected) |value| {
        try std.testing.expect(!q.isSupportedInteropValue(value));
        try std.testing.expectError(
            error.QuickJsUnsupportedArgument,
            q.lookupExternalProperty(&state, &runtime, engine, value, index_key),
        );
        try std.testing.expectEqualStrings(q.unsupported_object_get_message, runtime.failureMessage().?);
    }
}

test "interpreter JSメソッド実行は非externalコンテナをfull変換する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var scratch: [8]Value = @splat(Value{ .undefined = {} });
    for (&scratch) |*value| try roots.protect(value);

    // メソッドを持つJSオブジェクトはfull変換でexternal binding付きの辞書に
    // なる。`callExternalMethod` は同じJS参照の上で実行する。
    var receiver = try fullValue(
        &state,
        &runtime,
        engine,
        "({m(...a){return String(a[0][0].x) + typeof a[1][0] + typeof a[2].n + (a[3] === a[3][0])}})",
    );
    try roots.protect(&receiver);
    var method_name = try runtime.stringUtf8("m");
    try roots.protect(&method_name);

    // ネスト配列・callback・BigInt入り辞書・循環配列を同じfull変換で渡す。
    scratch[0] = try runtime.createDictionary();
    try scratch[0].dictionary.set((try key(&runtime, "x")), .{ .number = 5 });
    scratch[1] = try runtime.createArray();
    _ = try scratch[1].array.push(scratch[0]);
    scratch[2] = try runtime.createArray();
    _ = try scratch[2].array.push(scratch[1]);
    const function_name = try key(&runtime, "cb");
    scratch[3] = try runtime.createNativeFunction(function_name, 0, nativeNoop, &.{});
    scratch[4] = try runtime.createArray();
    _ = try scratch[4].array.push(scratch[3]);
    scratch[5] = try runtime.createDictionary();
    try scratch[5].dictionary.set((try key(&runtime, "n")), try runtime.bigIntLiteral("42"));
    scratch[6] = try runtime.createArray();
    _ = try scratch[6].array.push(scratch[6]);
    const method_arguments = [_]Value{ scratch[1], scratch[4], scratch[5], scratch[6] };
    const result = try q.callExternalMethod(&state, &runtime, engine, receiver, "m", &method_arguments);
    try expectString(result, "5functionbiginttrue");

    // コンテナ内のbytesはAOTと同じく明示エラーにする。
    scratch[7] = try runtime.createBytes(&.{1});
    var bytes_container = try runtime.createArray();
    try roots.protect(&bytes_container);
    _ = try bytes_container.array.push(scratch[7]);
    var bytes_args_container = try runtime.createArray();
    try roots.protect(&bytes_args_container);
    _ = try bytes_args_container.array.push(bytes_container);
    var bytes_invoke_arguments = [_]Value{ receiver, method_name, bytes_args_container };
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        q.call(&runtime, &state, test_effects, "JSメソッド実行", &bytes_invoke_arguments),
    );
    try std.testing.expectEqualStrings(q.unsupported_method_message, runtime.failureMessage().?);

    // コンテナ内のPromiseも同期変換できないため同じ文言で拒否する。
    var promise_container = try runtime.createArray();
    try roots.protect(&promise_container);
    _ = try promise_container.array.push(try runtime.createPromise());
    var promise_args_container = try runtime.createArray();
    try roots.protect(&promise_args_container);
    _ = try promise_args_container.array.push(promise_container);
    var promise_invoke_arguments = [_]Value{ receiver, method_name, promise_args_container };
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        q.call(&runtime, &state, test_effects, "JSメソッド実行", &promise_invoke_arguments),
    );
    try std.testing.expectEqualStrings(q.unsupported_method_message, runtime.failureMessage().?);

    // JSメソッド実行のトップレベル関数実引数も拒否する。
    var function_args_container = try runtime.createArray();
    try roots.protect(&function_args_container);
    _ = try function_args_container.array.push(try runtime.createNativeFunction(function_name, 0, nativeNoop, &.{}));
    var function_invoke_arguments = [_]Value{ receiver, method_name, function_args_container };
    try std.testing.expectError(
        error.QuickJsUnsupportedArgument,
        q.call(&runtime, &state, test_effects, "JSメソッド実行", &function_invoke_arguments),
    );
    try std.testing.expectEqualStrings(q.unsupported_method_message, runtime.failureMessage().?);

    // トップレベルの関数・BigInt・bytes・Promiseレシーバも拒否する。
    const rejected = [_]Value{
        try runtime.createNativeFunction(function_name, 0, nativeNoop, &.{}),
        try runtime.bigIntLiteral("1"),
        try runtime.createBytes(&.{1}),
        try runtime.createPromise(),
    };
    for (rejected) |value| {
        var rejected_arguments = [_]Value{ value, method_name };
        try std.testing.expectError(
            error.QuickJsUnsupportedArgument,
            q.call(&runtime, &state, test_effects, "JSメソッド実行", &rejected_arguments),
        );
        try std.testing.expectEqualStrings(q.unsupported_method_message, runtime.failureMessage().?);
    }
}

test "interop結果のキー数上限は所有権移動前に判定し二重解放しない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const raw = try evalRaw(engine, "({a:1,b:2})");
    var conversion = q.Conversion{ .state = &state, .runtime = &runtime, .mode = .interop_result, .limit = 1 };
    defer conversion.seen.deinit(runtime.allocator());
    try std.testing.expectError(error.QuickJsCollectionTooLarge, conversion.convert(raw));
    // rawは上限判定で1回だけ解放済み。GCで辞書が回収されても二重解放しない。
    _ = try runtime.collect();
}

test "interop結果の変換深度は上限で明示エラーにする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const raw = try evalRaw(engine, "(()=>{let o={};for(let i=0;i<70;i++)o={a:o};return o})()");
    var conversion = q.Conversion{ .state = &state, .runtime = &runtime, .mode = .interop_result };
    defer conversion.seen.deinit(runtime.allocator());
    try std.testing.expectError(error.QuickJsNestingTooDeep, conversion.convert(raw));
    _ = try runtime.collect();
}

test "interpreter 関数戻り値の孤立サロゲート名とname getter例外でリーク・失敗しない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var surrogate_fn = try fullValue(
        &state,
        &runtime,
        engine,
        "(()=>{const f=()=>7;Object.defineProperty(f,'name',{value:'\\uD800'});return f;})()",
    );
    try roots.protect(&surrogate_fn);
    try std.testing.expectEqual(@as(u16, 0xD800), surrogate_fn.function.name.units[0]);

    var throwing_fn = try fullValue(
        &state,
        &runtime,
        engine,
        "(()=>{const f=()=>8;Object.defineProperty(f,'name',{get(){throw new Error('boom')}});return f;})()",
    );
    try roots.protect(&throwing_fn);
    const out = try q.callExternalCallResult(&state, &runtime, throwing_fn, &.{});
    try std.testing.expectEqual(@as(f64, 8), out.number);
}

test "interpreter JS関数実行の巨大ByteBuffer引数はAOTと同じ上限で明示エラーにする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var function_value = try fullValue(&state, &runtime, engine, "b => b.length");
    try roots.protect(&function_value);
    const large = try std.testing.allocator.alloc(u8, 1_000_001);
    defer std.testing.allocator.free(large);
    @memset(large, 0);
    var bytes_value = try runtime.createBytes(large);
    try roots.protect(&bytes_value);
    try std.testing.expectError(
        error.QuickJsCollectionTooLarge,
        q.callExternalCallResult(&state, &runtime, function_value, &.{bytes_value}),
    );
}

test "interpreter JS関数実行の巨大配列引数はJS呼出し前にAOTと同じ上限で拒否する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var function_value = try fullValue(
        &state,
        &runtime,
        engine,
        "a => { globalThis.__lnako_called = (globalThis.__lnako_called || 0) + 1; return a.length; }",
    );
    try roots.protect(&function_value);
    var big_array = try runtime.createArray();
    try roots.protect(&big_array);
    try big_array.array.items.appendNTimes(runtime.allocator(), .{ .number = 1 }, 1_000_001);
    try std.testing.expectError(
        error.QuickJsCollectionTooLarge,
        q.callExternalCallResult(&state, &runtime, function_value, &.{big_array}),
    );

    const called = try fullValue(&state, &runtime, engine, "globalThis.__lnako_called || 0");
    try std.testing.expectEqual(@as(f64, 0), called.number);
}

test "interpreter full変換はBigIntと配列の割当て失敗時にRawValueをリークしない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var runtime = Runtime.init(failing.allocator());
        defer runtime.deinit();
        const engine = try newEngine();
        defer q.lnako_qjs_release(engine);
        var state = initState(&runtime, engine);
        defer deinitState(&state);

        if (fail_index == 0) {
            const bigint_raw = try evalRaw(engine, "42n");
            var bigint_conv = q.Conversion{ .state = &state, .runtime = &runtime, .mode = .full };
            defer bigint_conv.seen.deinit(runtime.allocator());
            try std.testing.expectError(error.OutOfMemory, bigint_conv.convert(bigint_raw));
        }

        var failing_arr = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var runtime_arr = Runtime.init(failing_arr.allocator());
        defer runtime_arr.deinit();
        var state_arr = initState(&runtime_arr, engine);
        defer deinitState(&state_arr);
        const array_raw = try evalRaw(engine, "[1, 2]");
        var array_conv = q.Conversion{ .state = &state_arr, .runtime = &runtime_arr, .mode = .full };
        defer array_conv.seen.deinit(runtime_arr.allocator());
        try std.testing.expectError(error.OutOfMemory, array_conv.convert(array_raw));
    }
}

test "interpreter full変換は関数戻り値の各割当て失敗位置でRawValueを二重解放・リークしない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var runtime = Runtime.init(failing.allocator());
        defer runtime.deinit();
        var state = initState(&runtime, engine);
        defer deinitState(&state);
        const raw = try evalRaw(engine, "function namedFn() { return 9; } namedFn");
        var conv = q.Conversion{ .state = &state, .runtime = &runtime, .mode = .full };
        defer conv.seen.deinit(runtime.allocator());
        if (conv.convert(raw)) |value| {
            try std.testing.expectEqual(q.Value.function, std.meta.activeTag(value));
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
        }
    }
    try std.testing.expect(fail_index > 0 and fail_index < 32);
}

fn expectFailureContains(runtime: *Runtime, expected: []const u8) !void {
    const message = runtime.failureMessage() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, expected) != null);
}

fn releaseTestExternal(_: *anyopaque, handle: *anyopaque) void {
    q.lnako_qjs_value_free(@ptrCast(@alignCast(handle)));
}

/// Nako配列/辞書へJS値のexternal bindingを付ける。`JS関数実行` の実引数同期
/// （syncContents）がownKeys例外を投げる外部辞書や、Proxyをプロパティに持つ
/// 外部配列を作るためだけに使う。
fn attachTestExternal(value: Value, engine: *Engine, raw: *RawValue) void {
    const external = value_mod.ExternalHandle{
        .context = @ptrCast(engine),
        .handle = @ptrCast(raw),
        .releaseFn = releaseTestExternal,
    };
    switch (value) {
        .array => |array| array.external = external,
        .dictionary => |dictionary| dictionary.external = external,
        else => unreachable,
    }
}

test "interpreterはキー列挙中のJS例外文言を保持する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    const proxy_source = "new Proxy({}, {ownKeys(){throw new Error('keys-boom');}})";

    // `JS実行` の full 変換（convertObject）はownKeys例外の文言を残す。
    runtime.clearFailureMessage();
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        q.fromRaw(&state, &runtime, try evalRaw(engine, proxy_source)),
    );
    try expectFailureContains(&runtime, "keys-boom");

    // `JS関数実行` の戻り値も #280 以降は full 変換を通るため同じ文言を残す。
    runtime.clearFailureMessage();
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        callJs(
            &state,
            &runtime,
            engine,
            "() => new Proxy({}, {ownKeys(){throw new Error('keys-boom');}})",
            &.{},
        ),
    );
    try expectFailureContains(&runtime, "keys-boom");

    // `JSオブジェクト取得` の戻り値変換（interopFromRaw）も同じ文言を残す。
    // Proxyを持つオブジェクトをfull変換すると先に例外になるため、JS側の配列へ
    // プロパティとして載せ、external binding付きのNako配列をレシーバにする。
    const setup = try evalRaw(engine, "globalThis.__lnako_keys_proxy = new Proxy({}, {ownKeys(){throw new Error('keys-boom');}}), 0");
    q.lnako_qjs_value_free(setup);
    const holder_raw = try evalRaw(engine, "(() => { const a = []; a.p = globalThis.__lnako_keys_proxy; return a; })()");
    var holder = try runtime.createArray();
    try roots.protect(&holder);
    attachTestExternal(holder, engine, holder_raw);
    var property = try runtime.stringUtf8("p");
    try roots.protect(&property);
    runtime.clearFailureMessage();
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        q.call(&runtime, &state, test_effects, "JSオブジェクト取得", &.{ holder, property }),
    );
    try expectFailureContains(&runtime, "keys-boom");

    // `JSメソッド実行` の戻り値変換（同じ interopFromRaw）も同じ文言を残す。
    // 配列の同期はインデックスだけを扱うため、追加したメソッドは削除されない。
    const method_raw = try evalRaw(engine, "(() => { const a = []; a.get = () => globalThis.__lnako_keys_proxy; return a; })()");
    var method_holder = try runtime.createArray();
    try roots.protect(&method_holder);
    attachTestExternal(method_holder, engine, method_raw);
    var method_name = try runtime.stringUtf8("get");
    try roots.protect(&method_name);
    var method_arguments = try runtime.createArray();
    try roots.protect(&method_arguments);
    runtime.clearFailureMessage();
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        q.call(&runtime, &state, test_effects, "JSメソッド実行", &.{ method_holder, method_name, method_arguments }),
    );
    try expectFailureContains(&runtime, "keys-boom");

    // `JS関数実行` の実引数同期（syncContents）でexternal辞書のownKeysが投げる。
    // bridgeがNULLを返した例外は内部エラー名ではなく元の文言として残る。
    const sync_raw = try evalRaw(engine, proxy_source);
    var sync_dictionary = try runtime.createDictionary();
    try roots.protect(&sync_dictionary);
    attachTestExternal(sync_dictionary, engine, sync_raw);
    var sync_function = try fullValue(&state, &runtime, engine, "(o) => 1");
    try roots.protect(&sync_function);
    runtime.clearFailureMessage();
    try std.testing.expectError(
        error.QuickJsExecutionFailed,
        q.callExternalCallResult(&state, &runtime, sync_function, &.{sync_dictionary}),
    );
    try expectFailureContains(&runtime, "keys-boom");

    // `Conversion.refresh` の辞書ブランチ（呼出し後の再同期）も同じ文言を残す。
    const refresh_raw = try evalRaw(engine, proxy_source);
    defer q.lnako_qjs_value_free(refresh_raw);
    var refresh_dictionary = try runtime.createDictionary();
    try roots.protect(&refresh_dictionary);
    var conversion = q.Conversion{ .state = &state, .runtime = &runtime, .wtf8_strings = true };
    defer conversion.seen.deinit(runtime.allocator());
    runtime.clearFailureMessage();
    try std.testing.expectError(error.QuickJsExecutionFailed, conversion.refresh(refresh_dictionary, refresh_raw));
    try expectFailureContains(&runtime, "keys-boom");
}

/// Issue #278: interpreter 側 host 関数スロットの解放・参照カウント・世代・
/// Function 意味論・teardown 安全性の回帰テスト。
const empty_call_arguments: [0]*const RawValue = .{};

fn nativeEffectsInvoke(context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    if (callable != .function) return error.QuickJsValueNotCallable;
    return switch (callable.function.kind) {
        .native => |callback| callback(runtime, arguments),
        else => error.QuickJsValueNotCallable,
    };
}

fn nativeAddOne(_: *Runtime, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0 or arguments[0] != .number) return .undefined;
    return .{ .number = arguments[0].number + 1 };
}

fn nativeConstant42(_: *Runtime, _: []const Value) anyerror!Value {
    return .{ .number = 42 };
}

test "interpreterはhostFunctionの最後のJS参照で登録を解放する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 1, nativeAddOne, &.{});

    const raw = try state.hostFunction(engine, callback);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(callback));
    q.lnako_qjs_value_free(raw);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 0), state.hostFunctionInstanceCount(callback));
}

test "interpreterはhostFunctionの複数JSインスタンスを参照カウントする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 1, nativeConstant42, &.{});
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const first = try state.hostFunction(engine, callback);
    const second = try state.hostFunction(engine, callback);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 2), state.hostFunctionInstanceCount(callback));

    q.lnako_qjs_value_free(first);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(callback));
    const result = q.lnako_qjs_call(engine, second, &empty_call_arguments, 0) orelse return error.TestUnexpectedResult;
    // `fromRaw` は RawValue の所有権を消費する（二重解放しない）。
    const converted = q.fromRaw(&state, &runtime, result) catch |failure| {
        q.lnako_qjs_value_free(result);
        return failure;
    };
    try std.testing.expectEqual(@as(f64, 42), converted.number);

    q.lnako_qjs_value_free(second);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
}

test "interpreterはhostFunctionスロットを新世代で再利用し古いIDを拒否する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };
    const first_name = try key(&runtime, "first");
    const second_name = try key(&runtime, "second");
    const first_value = try runtime.createNativeFunction(first_name, 0, nativeConstant42, &.{});
    const second_value = try runtime.createNativeFunction(second_name, 0, nativeConstant42, &.{});

    const raw_first = try state.hostFunction(engine, first_value);
    const first_handle = state.hostFunctionHandle(first_value) orelse return error.TestUnexpectedResult;
    q.lnako_qjs_value_free(raw_first);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());

    const raw_second = try state.hostFunction(engine, second_value);
    defer q.lnako_qjs_value_free(raw_second);
    const second_handle = state.hostFunctionHandle(second_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first_handle.index, second_handle.index);
    try std.testing.expect(second_handle.generation > first_handle.generation);

    const stale = q.lnako_qjs_host_function(engine, first_handle.index, first_handle.generation, "stale") orelse
        return error.TestUnexpectedResult;
    defer q.lnako_qjs_value_free(stale);
    try std.testing.expect(q.lnako_qjs_call(engine, stale, &empty_call_arguments, 0) == null);
    const message = q.lnako_qjs_take_error(engine) orelse return error.TestUnexpectedResult;
    defer q.lnako_qjs_free_string(message);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(message), "InternalError") != null);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());

    const result = q.lnako_qjs_call(engine, raw_second, &empty_call_arguments, 0) orelse return error.TestUnexpectedResult;
    const converted = q.fromRaw(&state, &runtime, result) catch |failure| {
        q.lnako_qjs_value_free(result);
        return failure;
    };
    try std.testing.expectEqual(@as(f64, 42), converted.number);
}

test "interpreterはhostFunctionのFunction意味論とJS生存期間を維持する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 1, nativeAddOne, &.{});
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const result = try callJs(
        &state,
        &runtime,
        engine,
        "(f)=>{globalThis.__interp_cb=f;return [typeof f,f instanceof Function,f.name,f.length," ++
            "f(41),f.call(null,41),f.apply(null,[41]),f.bind(null,41)(),f.constructor===Function].join(',');}",
        &.{callback},
    );
    try expectString(result, "function,true,callback,0,42,42,42,42,true");
    // JS 側 global が保持している間はスロットが生存する。
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    const drop = try evalRaw(engine, "globalThis.__interp_cb = null; 0");
    q.lnako_qjs_value_free(drop);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
}

test "interpreterはhostFunctionを残したままState deinitしても安全に終了する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    var state = initState(&runtime, engine);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 0, nativeConstant42, &.{});
    const raw = try state.hostFunction(engine, callback);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());

    // State.deinit が通知とテーブルを解除して engine 参照を1つ落とす。
    state.deinit();
    // engine は wrapper が保持している。finalizer は解除済みの通知を呼ばない。
    q.lnako_qjs_value_free(raw);
}

// Issue #278 レビュー指摘: JS 自己循環内の callback は参照カウントゼロでは
// 解放されず、QuickJS GC でのみ finalizer が走る。
test "interpreterはJS自己循環内のcallbackをQuickJS GCでのみ解放する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 0, nativeConstant42, &.{});
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const result = try callJs(
        &state,
        &runtime,
        engine,
        "(f)=>{ const box = { cb: f }; box.self = box; return 0; }",
        &.{callback},
    );
    try std.testing.expectEqual(@as(f64, 0), result.number);
    // 自己循環が残っている間は生存する。
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(callback));
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 0), state.hostFunctionInstanceCount(callback));
}

// Issue #278 レビュー指摘: 2個目の生成が Zig 割当てで失敗しても、先予約
// acquire の rollback が既存インスタンスとスロットを壊さない。
test "interpreterは新インスタンス生成失敗で既存インスタンスを保護する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var runtime = Runtime.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        runtime.deinit();
    }
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 0, nativeConstant42, &.{});
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const first = try state.hostFunction(engine, callback);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(callback));

    var saw_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        failing.alloc_index = 0;
        failing.fail_index = fail_index;
        const second = state.hostFunction(engine, callback);
        if (second) |raw| {
            q.lnako_qjs_value_free(raw);
        } else |failure| {
            saw_failure = true;
            try std.testing.expectEqual(error.OutOfMemory, failure);
        }
        try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
        try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(callback));
    }
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(saw_failure);

    const result = q.lnako_qjs_call(engine, first, &empty_call_arguments, 0) orelse return error.TestUnexpectedResult;
    const converted = q.fromRaw(&state, &runtime, result) catch |failure| {
        q.lnako_qjs_value_free(result);
        return failure;
    };
    try std.testing.expectEqual(@as(f64, 42), converted.number);
    q.lnako_qjs_value_free(first);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
}

fn traceQuickJsState(context: *anyopaque, runtime: *Runtime) anyerror!void {
    const state: *q.State = @ptrCast(@alignCast(context));
    try state.trace(runtime);
}

// Issue #278 レビュー指摘: capture した Nako オブジェクトは JS 保持中は
// Nako GC でも生存し、JS 参照破棄 + QuickJS GC 後の Nako GC で回収される。
test "interpreterはhostFunctionのcaptureをJS保持中は維持し解放後に回収する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    try runtime.registerRootProvider(.{ .context = &state, .traceFn = traceQuickJsState });
    defer runtime.unregisterRootProvider(&state);
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const name = try key(&runtime, "callback");
    const capture_name = try key(&runtime, "captured");
    const base = runtime.objectCount();
    const captured_text = try runtime.stringUtf8("captured-value");
    var captured_array = try runtime.createArray();
    _ = try captured_array.array.push(captured_text);
    const callback = try runtime.createNativeFunction(
        name,
        0,
        nativeConstant42,
        &.{.{ .name = capture_name, .value = captured_array }},
    );

    const result = try callJs(
        &state,
        &runtime,
        engine,
        "(f)=>{globalThis.__interp_capture_cb=f;return 0;}",
        &.{callback},
    );
    try std.testing.expectEqual(@as(f64, 0), result.number);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());

    // Nako 側の root を落としても、JS が保持している間は capture が生存する。
    _ = try runtime.collect();
    try std.testing.expect(runtime.objectCount() > base);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());

    // JS 側の参照を落として QuickJS GC を回すと finalizer が登録を解除し、
    // 次の Nako GC で closure と capture が回収される。
    const drop = try evalRaw(engine, "globalThis.__interp_capture_cb = null; 0");
    q.lnako_qjs_value_free(drop);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
    _ = try runtime.collect();
    try std.testing.expect(runtime.objectCount() <= base);
}

// Issue #278 レビュー指摘: 管理外 engine への登録を拒否し、既存テーブルと
// 別 engine の teardown に影響を与えない。
test "interpreterは不一致engineのhostFunctionを拒否する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 0, nativeConstant42, &.{});

    const foreign = try newEngine();
    defer q.lnako_qjs_release(foreign);
    try std.testing.expectError(error.QuickJsHostUnavailable, state.hostFunction(foreign, callback));
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());

    const raw = try state.hostFunction(engine, callback);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    q.lnako_qjs_value_free(raw);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
}

// Issue #278 レビュー指摘: engine 生成・破棄を繰り返してもプロセス共通の
// class ID を消費し尽くさない。
test "interpreterは複数engineの生成破棄を繰り返してもclass IDを枯渇させない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        const created = try newEngine();
        q.lnako_qjs_release(created);
    }

    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 0, nativeConstant42, &.{});
    const raw = try state.hostFunction(engine, callback);
    q.lnako_qjs_value_free(raw);
    q.lnako_qjs_run_gc(engine);
    try std.testing.expectEqual(@as(usize, 0), state.registeredHostFunctionCount());
}

// Issue #278 レビュー指摘: `globalThis.Function` を壊しても、生成した host
// 関数は intrinsic な `Function.prototype` を継承し、call/apply/bind が壊れない。
test "interpreterはglobalThis.Function改変下でもhost関数の意味論を維持する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    const name = try key(&runtime, "callback");
    const callback = try runtime.createNativeFunction(name, 1, nativeAddOne, &.{});
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const broken = try evalRaw(engine, "globalThis.Function = 0; 0");
    q.lnako_qjs_value_free(broken);
    const result = try callJs(
        &state,
        &runtime,
        engine,
        "(f)=>{globalThis.__interp_broken_f=f;return [typeof f,typeof f.call,typeof f.apply," ++
            "typeof f.bind,f.name,f(41),f.call(null,41),f.apply(null,[41]),f.bind(null,41)()].join(',');}",
        &.{callback},
    );
    try expectString(result, "function,function,function,function,callback,42,42,42,42");
}

// Issue #278 再レビュー指摘: C 側の関数名文字列生成（JS_NewString）が OOM で
// 失敗した場合に、例外を name に格納した半端な wrapper を返さず失敗し、
// 先予約した参照カウントもロールバックして既存インスタンスを保護する。
test "interpreterはhostFunctionのJS側名前割当てOOM時に失敗し既存インスタンスを保護する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);
    state.effects = q.Effects{
        .context = @ptrCast(&runtime),
        .invokeFn = nativeEffectsInvoke,
        .resolveFn = stubResolve,
        .getGlobalFn = stubGetGlobal,
        .setGlobalFn = stubSetGlobal,
        .execFn = stubExec,
    };

    const large_name_bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large_name_bytes);
    @memset(large_name_bytes, 'a');
    const large_name = try key(&runtime, large_name_bytes);
    const first_fn = try runtime.createNativeFunction(large_name, 0, nativeConstant42, &.{});
    const second_fn = try runtime.createNativeFunction(large_name, 0, nativeConstant42, &.{});

    // 既存インスタンスを 1 つ登録した状態で QuickJS メモリ上限を絞る。
    const existing = try state.hostFunction(engine, first_fn);
    defer q.lnako_qjs_value_free(existing);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(first_fn));

    q.lnako_qjs_set_memory_limit(engine, 256 * 1024);
    defer q.lnako_qjs_set_memory_limit(engine, std.math.maxInt(usize));

    try std.testing.expectError(error.OutOfMemory, state.hostFunction(engine, first_fn));
    if (q.lnako_qjs_take_error(engine)) |err_text| q.lnako_qjs_free_string(err_text);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), state.hostFunctionInstanceCount(first_fn));

    try std.testing.expectError(error.OutOfMemory, state.hostFunction(engine, second_fn));
    if (q.lnako_qjs_take_error(engine)) |err_text| q.lnako_qjs_free_string(err_text);
    try std.testing.expectEqual(@as(usize, 1), state.registeredHostFunctionCount());
    try std.testing.expectEqual(@as(usize, 0), state.hostFunctionInstanceCount(second_fn));

    q.lnako_qjs_set_memory_limit(engine, std.math.maxInt(usize));
    const call_res = q.lnako_qjs_call(engine, existing, &empty_call_arguments, 0) orelse return error.TestUnexpectedResult;
    const converted = q.fromRaw(&state, &runtime, call_res) catch |failure| {
        q.lnako_qjs_value_free(call_res);
        return failure;
    };
    try std.testing.expectEqual(@as(f64, 42), converted.number);
}

test "hasRegisteredFunctionKeyはfallback名再確保OOM時に二重解放せずOutOfMemoryを返す" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);

    const setup = try evalRaw(engine, "globalThis.__lnako_commands = { 登録命令: { type: 'func' } }; 0");
    q.lnako_qjs_value_free(setup);

    try std.testing.expect(try q.hasRegisteredFunctionKey(&state, std.testing.allocator, "plugin__登録命令"));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        q.hasRegisteredFunctionKey(&state, failing.allocator(), "plugin__登録命令"),
    );
}

test "hasCallableCommandはfn取得の例外を未登録にせずエラーで返しundefinedはfalseにする" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);

    const setup = try evalRaw(
        engine,
        "globalThis.__lnako_commands = { 例外: { type: 'func', get fn() { throw new Error('boom'); } }, 未定義: { type: 'func' }, 非関数: { type: 'func', fn: 1 }, 正常: { type: 'func', fn: () => 1 } }; 0",
    );
    q.lnako_qjs_value_free(setup);

    // getter 例外は未登録（false）として握りつぶさず、実行失敗として報告する。
    try std.testing.expectError(error.QuickJsExecutionFailed, q.hasCallableCommand(&state, std.testing.allocator, "例外"));
    // fn が undefined / 非関数なら従来どおり未登録扱い。
    try std.testing.expect(!try q.hasCallableCommand(&state, std.testing.allocator, "未定義"));
    try std.testing.expect(!try q.hasCallableCommand(&state, std.testing.allocator, "非関数"));
    try std.testing.expect(try q.hasCallableCommand(&state, std.testing.allocator, "正常"));
    try std.testing.expect(!try q.hasCallableCommand(&state, std.testing.allocator, "存在しない"));
}

test "commandJosiMetadataは後続スロット・候補の不正で部分確保を解放する" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);

    // 各 entry は先頭スロット・先頭候補まで実際に確保してから不正値へ入る。
    // std.testing.allocator はテスト終了時にリークを検出する。
    const setup = try evalRaw(
        engine,
        "globalThis.__lnako_commands = {" ++
            "第二スロット不正: { type: 'func', josi: [['を'], null], isVariableJosi: true }," ++
            "第二候補不正: { type: 'func', josi: [['を', null]], isVariableJosi: false }," ++
            "成功: { type: 'func', josi: [['を'], ['に']], isVariableJosi: true }" ++
            "}; 0",
    );
    q.lnako_qjs_value_free(setup);

    try std.testing.expect(try q.commandJosiMetadata(&state, std.testing.allocator, "第二スロット不正") == null);
    try std.testing.expect(try q.commandJosiMetadata(&state, std.testing.allocator, "第二候補不正") == null);

    var metadata = (try q.commandJosiMetadata(&state, std.testing.allocator, "成功")) orelse return error.TestUnexpectedResult;
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), metadata.slots.len);
    try std.testing.expectEqualStrings("を", metadata.slots[0][0]);
    try std.testing.expectEqualStrings("に", metadata.slots[1][0]);
    try std.testing.expect(metadata.variable_final);
}

test "commandJosiMetadataは各確保位置のエラーでも部分確保を二重解放しない" {
    if (!build_options.quickjs_enabled) return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const engine = try newEngine();
    defer q.lnako_qjs_release(engine);
    var state = initState(&runtime, engine);
    defer deinitState(&state);

    const setup = try evalRaw(
        engine,
        "globalThis.__lnako_commands = { 成功: { type: 'func', josi: [['を'], ['に']], isVariableJosi: true } }; 0",
    );
    q.lnako_qjs_value_free(setup);

    // slots(1) + スロット表(2) + 助詞文字列(2) の各確保位置で失敗させる。
    for (0..6) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (q.commandJosiMetadata(&state, allocator, "成功")) |metadata_optional| {
            if (metadata_optional) |metadata_value| {
                var metadata = metadata_value;
                metadata.deinit(allocator);
            }
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
        }
    }
}
