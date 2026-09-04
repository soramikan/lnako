const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../ir/nako_ir.zig");
const ast = @import("../../frontend/ast.zig");
const parser = @import("../../frontend/parser.zig");
const lexer = @import("../../frontend/lexer.zig");
const josi = @import("../../frontend/josi.zig");
const semantic = @import("../../semantic/analyzer.zig");
const builtin_catalog = @import("../../semantic/builtin_catalog.zig");
const hir = @import("../../ir/hir.zig");
const lower_ssa = @import("../../ir/lower_ssa.zig");
const verifier = @import("../../ir/verifier.zig");
const error_message = @import("../error_message.zig");
const value_mod = @import("../value.zig");
const operators = @import("../operators.zig");
const plugin_system = @import("../../plugins/system.zig");
const plugin_math = @import("../../plugins/math.zig");
const plugin_csv = @import("../../plugins/csv.zig");
const plugin_toml = @import("../../plugins/toml.zig");
const plugin_node = @import("../../plugins/node.zig");
const plugin_encoding = @import("../../plugins/encoding.zig");
const plugin_http_server = @import("../../plugins/http_server.zig");
const plugin_markup = @import("../../plugins/markup.zig");
const plugin_caniuse = @import("../../plugins/caniuse.zig");
const plugin_kansuji = @import("../../plugins/kansuji.zig");
const plugin_native = @import("../../plugins/native.zig");
const quickjs = @import("../../compat/quickjs.zig");
const environment = @import("../environment.zig");
const istate = @import("state.zig");
const shared = @import("shared.zig");

const Interpreter = istate.Interpreter;
const TestResult = shared.TestResult;
const Value = shared.Value;
const Runtime = shared.Runtime;
const DynamicPreparationFn = istate.DynamicPreparationFn;
const Frame = shared.Frame;
const IteratorKind = shared.IteratorKind;
const IteratorState = shared.IteratorState;
const Timer = shared.Timer;
const PromiseResolver = shared.PromiseResolver;
const PromiseAllState = shared.PromiseAllState;
const PromiseAllHandler = shared.PromiseAllHandler;
const PromiseChainKind = shared.PromiseChainKind;
const NamespaceFrame = shared.NamespaceFrame;
const HatenaCallback = shared.HatenaCallback;
const DispatchTraceWriteFn = shared.DispatchTraceWriteFn;
const DispatchTrace = shared.DispatchTrace;
const CompatJsTrace = shared.CompatJsTrace;
const GlobalTrace = shared.GlobalTrace;
const LiteralTrace = shared.LiteralTrace;
const default_plugin_names = shared.default_plugin_names;
const traceBuiltinName = shared.traceBuiltinName;
const compatJsOperation = shared.compatJsOperation;
const interpreterArrayIndex = shared.interpreterArrayIndex;
const repeatCount = shared.repeatCount;
const valueIndex = shared.valueIndex;
const getArrayProperty = shared.getArrayProperty;
const maxValueId = shared.maxValueId;
const isPrototypeObject = shared.isPrototypeObject;
const interpreterByteBufferReadOnlyProperty = shared.interpreterByteBufferReadOnlyProperty;
const ownProperty = shared.ownProperty;
const setOwnProperty = shared.setOwnProperty;
const objectPrimitiveMethod = shared.objectPrimitiveMethod;
const preservesResultVariable = shared.preservesResultVariable;
const promiseResolverSentinel = shared.promiseResolverSentinel;
const promiseAllSentinel = shared.promiseAllSentinel;
const localValue = shared.localValue;
const traceRoots = istate.traceRoots;

pub fn callExternalCommand(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
    try self.activateExternalRuntime();
    return self.callBuiltin(name, arguments, null);
}

pub fn pollExternalPlugins(self: *Interpreter) !bool {
    try self.activateExternalRuntime();
    return plugin_native.poll(self.runtime, &self.native_plugin_state);
}

pub fn callBuiltin(self: *Interpreter, name: []const u8, arguments: []const Value, site_id: ?u64) !Value {
    self.beginDispatchRoute();
    const compat_operation = compatJsOperation(name);
    if (compat_operation) |operation| self.compat_js_trace.emit(name, operation, "compat-js-attempt", null, site_id);
    const result = self.callBuiltinImpl(name, arguments) catch |failure| {
        const route = self.endDispatchRoute();
        const result_kind = if (failure == error.ProcessExitRequested) "success" else "failure";
        self.dispatch_trace.emit(traceBuiltinName(name), route, result_kind, site_id);
        if (compat_operation) |operation| self.compat_js_trace.emit(name, operation, "compat-js-result", if (failure == error.ProcessExitRequested) "success" else "failure", site_id);
        return failure;
    };
    const route = self.endDispatchRoute();
    self.dispatch_trace.emit(traceBuiltinName(name), route, "success", site_id);
    if (compat_operation) |operation| self.compat_js_trace.emit(name, operation, "compat-js-result", "success", site_id);
    return result;
}

pub fn beginDispatchRoute(self: *Interpreter) void {
    if (self.dispatch_route_depth >= self.dispatch_route_stack.len) {
        self.dispatch_route_overflow += 1;
        return;
    }
    self.dispatch_route_stack[self.dispatch_route_depth] = "interpreter-core";
    self.dispatch_route_depth += 1;
}

pub fn setDispatchRoute(self: *Interpreter, route: []const u8) void {
    if (self.dispatch_route_overflow > 0) return;
    if (self.dispatch_route_depth == 0) return;
    self.dispatch_route_stack[self.dispatch_route_depth - 1] = route;
}

pub fn endDispatchRoute(self: *Interpreter) []const u8 {
    if (self.dispatch_route_overflow > 0) {
        self.dispatch_route_overflow -= 1;
        return "unknown";
    }
    if (self.dispatch_route_depth == 0) return "unknown";
    const route = self.dispatch_route_stack[self.dispatch_route_depth - 1];
    self.dispatch_route_depth -= 1;
    return route;
}

pub fn callBuiltinImpl(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
    if (std.mem.eql(u8, name, "連続加算") and arguments.len == 0) return self.systemContext();
    if (std.mem.eql(u8, name, "ください") or std.mem.eql(u8, name, "お願") or std.mem.eql(u8, name, "です")) {
        if (!std.math.isFinite(self.courtesy_level) or self.courtesy_level == 0) self.courtesy_level = 0;
        self.courtesy_level += 1;
        return .undefined;
    }
    if (std.mem.eql(u8, name, "拝啓")) {
        self.courtesy_level = 0;
        return .undefined;
    }
    if (std.mem.eql(u8, name, "敬具")) {
        self.courtesy_level += 100;
        return .undefined;
    }
    if (std.mem.eql(u8, name, "礼節レベル取得")) {
        if (!std.math.isFinite(self.courtesy_level) or self.courtesy_level == 0) self.courtesy_level = 0;
        return .{ .number = self.courtesy_level };
    }
    if (std.mem.eql(u8, name, "プラグイン名設定")) {
        try self.setGlobal("プラグイン名", try self.stringArgument(arguments));
        return .undefined;
    }
    if (std.mem.eql(u8, name, "名前空間設定")) {
        try self.namespace_stack.append(self.allocator, .{
            .namespace = self.globals.get("名前空間") orelse .undefined,
            .plugin_name = self.globals.get("プラグイン名") orelse .undefined,
        });
        try self.setGlobal("名前空間", try self.stringArgument(arguments));
        return .undefined;
    }
    if (std.mem.eql(u8, name, "名前空間ポップ")) {
        if (self.namespace_stack.pop()) |previous| {
            try self.setGlobal("名前空間", previous.namespace);
            try self.setGlobal("プラグイン名", previous.plugin_name);
        }
        return .undefined;
    }
    if (std.mem.eql(u8, name, "グローバル関数一覧取得")) return self.globalFunctionNames();
    if (std.mem.eql(u8, name, "システム関数一覧取得")) return self.stringArray(&builtin_catalog.default_names);
    if (std.mem.eql(u8, name, "システム関数存在")) return .{ .boolean = try self.defaultSystemNameExists(arguments) };
    if (std.mem.eql(u8, name, "プラグイン一覧取得") or std.mem.eql(u8, name, "モジュール一覧取得")) return self.stringArray(&default_plugin_names);
    if (std.mem.eql(u8, name, "助詞一覧取得")) return self.stringArray(&josi.exported_list);
    if (std.mem.eql(u8, name, "予約語一覧取得")) return self.stringArray(&lexer.exported_reserved_words);
    if (std.mem.eql(u8, name, "ASYNC")) return .undefined;
    if (std.mem.eql(u8, name, "AWAIT実行")) return self.awaitExecute(arguments);
    if (std.mem.eql(u8, name, "ナデシコ") or std.mem.eql(u8, name, "ナデシコ続")) {
        if (arguments.len == 0) return .undefined;
        return self.executeDynamicValue(arguments[arguments.len - 1]);
    }
    if (std.mem.eql(u8, name, "実行")) return self.executeCallable(arguments);
    if (std.mem.eql(u8, name, "実行時間計測")) return self.measureCallable(arguments);
    if (std.mem.eql(u8, name, "デバッグ表示")) return self.debugDisplay(arguments);
    if (std.mem.eql(u8, name, "ハテナ関数設定")) return self.configureHatena(arguments);
    if (std.mem.eql(u8, name, "ハテナ関数実行")) return self.invokeHatena(arguments);
    if (std.mem.eql(u8, name, "__DEBUG")) {
        self.debug_enabled = true;
        return .undefined;
    }
    if (std.mem.eql(u8, name, "__DEBUG_BP_WAIT")) return self.debugBreakpointWait(arguments);
    if (std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する")) return self.display(arguments);
    if (std.mem.eql(u8, name, "継続表示")) return self.continueDisplay(arguments);
    if (std.mem.eql(u8, name, "連続表示")) return self.displayMany(arguments);
    if (std.mem.eql(u8, name, "連続無改行表示")) return self.continueDisplayMany(arguments);
    if (std.mem.eql(u8, name, "表示ログクリア")) {
        try self.setGlobal("表示ログ", try self.runtime.stringUtf8(""));
        return .undefined;
    }
    if (std.mem.eql(u8, name, "言")) {
        try self.writeValues(arguments, false);
        try self.writeOutput("\n");
        return .undefined;
    }
    if (std.mem.eql(u8, name, "コンソール表示")) {
        try self.writeValues(arguments, false);
        try self.writeOutput("\n");
        return .undefined;
    }
    if (std.mem.eql(u8, name, "エラー発生")) {
        const thrown = if (arguments.len > 0) arguments[arguments.len - 1] else try self.runtime.stringUtf8("エラー");
        self.exception_value = try self.errorMessageValue(thrown);
        return error.NakoException;
    }
    if (self.host.node_context == null and std.mem.eql(u8, name, "終")) {
        self.setDispatchRoute("plugin_system");
        self.exception_value = try self.runtime.stringUtf8("__終わる__");
        return error.NakoException;
    }
    if (std.mem.eql(u8, name, "ASSERT") or std.mem.eql(u8, name, "確認")) {
        if (arguments.len == 0 or !arguments[arguments.len - 1].toBoolean()) return error.AssertionFailed;
        return arguments[arguments.len - 1];
    }
    if (std.mem.eql(u8, name, "ASSERT等") or std.mem.eql(u8, name, "テスト実行") or std.mem.eql(u8, name, "テスト等")) {
        if (arguments.len < 2 or !Value.sameValue(arguments[0], arguments[1])) return error.AssertionFailed;
        return .undefined;
    }
    if (std.mem.eql(u8, name, "秒待") or std.mem.eql(u8, name, "秒待機") or std.mem.eql(u8, name, "秒逐次待機")) {
        const milliseconds = try self.delayMilliseconds(if (arguments.len > 0) arguments[arguments.len - 1] else .undefined);
        try self.waitMilliseconds(milliseconds);
        return .undefined;
    }
    if (std.mem.eql(u8, name, "秒後")) return self.scheduleTimer(arguments, false);
    if (std.mem.eql(u8, name, "秒毎") or std.mem.eql(u8, name, "秒タイマー開始時")) return self.scheduleTimer(arguments, true);
    if (std.mem.eql(u8, name, "タイマー停止")) {
        if (arguments.len == 0 or arguments[arguments.len - 1] != .number) return .{ .boolean = false };
        const number = arguments[arguments.len - 1].number;
        if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return .{ .boolean = false };
        return .{ .boolean = self.stopTimer(@intFromFloat(@trunc(number))) };
    }
    if (std.mem.eql(u8, name, "全タイマー停止")) {
        self.timers.clearRetainingCapacity();
        return .undefined;
    }
    if (std.mem.eql(u8, name, "動時")) return self.createPromiseWithExecutor(arguments);
    if (std.mem.eql(u8, name, "成功時")) return self.chainPromise(arguments, .success);
    if (std.mem.eql(u8, name, "失敗時")) return self.chainPromise(arguments, .failure);
    if (std.mem.eql(u8, name, "処理時")) return self.chainPromise(arguments, .settled);
    if (std.mem.eql(u8, name, "終了時")) return self.chainPromise(arguments, .finally);
    if (std.mem.eql(u8, name, "束")) return self.bundlePromises(arguments);
    if (std.mem.eql(u8, name, "二進表示")) {
        self.setDispatchRoute("plugin_system");
        const text = (try plugin_system.types.call(self.runtime, "二進", arguments)).?;
        const utf8 = try text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(utf8);
        try self.writeOutput(utf8);
        try self.writeOutput("\n");
        return .undefined;
    }
    if (std.mem.eql(u8, name, "切取")) {
        self.setDispatchRoute("plugin_system");
        const result = try plugin_system.strings.cut(self.runtime, if (arguments.len > 0) arguments[0] else .undefined, if (arguments.len > 1) arguments[1] else .undefined);
        try self.setGlobal("対象", result.remainder);
        return result.result;
    }
    if (std.mem.eql(u8, name, "範囲切取")) {
        self.setDispatchRoute("plugin_system");
        const result = try plugin_system.strings.cutRange(self.runtime, if (arguments.len > 0) arguments[0] else .undefined, if (arguments.len > 1) arguments[1] else .undefined, if (arguments.len > 2) arguments[2] else .undefined);
        try self.setGlobal("対象", result.remainder);
        return result.result;
    }
    if (std.mem.eql(u8, name, "正規表現マッチ") or std.mem.eql(u8, name, "正規表現抽出")) {
        self.setDispatchRoute("plugin_system");
        const result = (try plugin_system.regexp.callWithEffects(self.runtime, name, arguments)).?;
        if (result.captures) |captures| try self.setGlobal("抽出文字列", captures);
        return result.value;
    }
    self.setDispatchRoute("plugin_system");
    const plugin_context = try self.pluginContext();
    self.setDispatchRoute("plugin_math");
    if (try plugin_math.call(self.runtime, name, arguments, .{
        .context = self,
        .randomFn = pluginRandom,
    })) |value| return value;
    self.setDispatchRoute("plugin_csv");
    if (try plugin_csv.call(self.runtime, &self.csv_state, name, arguments)) |value| return value;
    self.setDispatchRoute("plugin_toml");
    if (try plugin_toml.call(self.runtime, name, arguments)) |value| return value;
    if (self.host.node_context) |node_context| {
        self.setDispatchRoute("plugin_node");
        if (try plugin_node.call(self.runtime, &self.node_state, node_context, self.nodeEffects(), name, arguments)) |value| return value;
    }
    if (self.host.http_server_context) |server_context| {
        self.setDispatchRoute("plugin_http_server");
        if (try plugin_http_server.call(self.runtime, &self.http_server_state, server_context, self.httpServerEffects(), name, arguments)) |value| return value;
    }
    self.setDispatchRoute("plugin_markup");
    if (try plugin_markup.call(self.runtime, name, arguments)) |value| return value;
    self.setDispatchRoute("plugin_caniuse");
    if (try plugin_caniuse.call(self.runtime, &self.caniuse_state, name, arguments)) |value| return value;
    self.setDispatchRoute("plugin_kansuji");
    if (try plugin_kansuji.call(self.runtime, name, arguments)) |value| return value;
    self.setDispatchRoute("plugin_native");
    if (try plugin_native.call(self.runtime, &self.native_plugin_state, self.nativePluginEffects(), name, arguments)) |value| return value;
    self.setDispatchRoute("quickjs");
    if (try quickjs.call(self.runtime, &self.quickjs_state, self.quickJsEffects(), name, arguments)) |value| return value;
    self.setDispatchRoute("plugin_encoding");
    if (try plugin_encoding.call(self.runtime, name, arguments)) |value| return value;
    self.setDispatchRoute(if (datetimePluginRouteEnabled() and isDatetimePluginCommandName(name)) "plugin_datetime" else "plugin_system");
    if (try plugin_system.callWithContext(self.runtime, name, arguments, plugin_context)) |value| return value;
    self.setDispatchRoute("unknown");
    return error.UnknownCommand;
}

pub fn isDatetimePluginCommandName(name: []const u8) bool {
    const names = [_][]const u8{
        "今",
        "システム時間",
        "今日",
        "明日",
        "昨日",
        "今年",
        "来年",
        "去年",
        "今月",
        "来月",
        "先月",
        "曜日",
        "曜日番号取得",
        "UNIX時間変換",
        "UNIXTIME変換",
        "日時変換",
        "和暦変換",
        "年数差",
        "月数差",
        "日数差",
        "日時差",
        "時間差",
        "分差",
        "秒差",
        "時間加算",
        "日付加算",
        "日時加算",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

pub fn datetimePluginRouteEnabled() bool {
    return environment.valueEquals("LNAKO_PLUGIN_ROUTE", "plugin_datetime");
}

pub fn initializeSystem(self: *Interpreter) !void {
    if (self.system_initialized) return;
    try plugin_system.constants.install(self.runtime, .{ .context = self, .setFn = installSystemConstant });
    try plugin_system.datetime.install(self.runtime, .{ .context = self, .setFn = installSystemConstant });
    if (self.host.node_context) |node_context| try plugin_node.install(self.runtime, node_context, .{ .context = self, .setFn = installSystemConstant });
    if (self.host.http_server_context != null) try plugin_http_server.install(self.runtime, .{ .context = self, .setFn = installSystemConstant });
    try plugin_caniuse.install(self.runtime, &self.caniuse_state, .{ .context = self, .setFn = installSystemConstant });
    try plugin_native.install(self.runtime, &self.native_plugin_state, self.program.native_plugin_paths, self.nativePluginEffects());
    try quickjs.installModules(self.runtime, &self.quickjs_state, self.program.javascript_modules, self.quickJsEffects());
    try self.setGlobal("名前空間", try self.runtime.stringUtf8(self.primaryModuleName()));
    self.system_initialized = true;
}

pub fn stringArgument(self: *Interpreter, arguments: []const Value) !Value {
    const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    return self.runtime.valueToString(value);
}

pub fn stringArray(self: *Interpreter, values: []const []const u8) !Value {
    var result = try self.runtime.createArray();
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (values) |item| {
        const string = try self.runtime.stringUtf8(item);
        _ = try result.array.push(string);
    }
    return result;
}

pub fn globalFunctionNames(self: *Interpreter) !Value {
    var result = try self.runtime.createArray();
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (self.currentProgramOwner().functions) |function| {
        if (std.mem.endsWith(u8, function.name, "__$entry") or std.mem.indexOf(u8, function.name, "__lambda$") != null) continue;
        const name = try self.runtime.stringUtf8(function.name);
        _ = try result.array.push(name);
    }
    return result;
}

pub fn defaultSystemNameExists(self: *Interpreter, arguments: []const Value) !bool {
    const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    const string = try self.runtime.valueToString(value);
    const name = try string.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(name);
    for (builtin_catalog.default_names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

pub fn executeCallable(self: *Interpreter, arguments: []const Value) !Value {
    if (arguments.len == 0) return .undefined;
    const candidate = arguments[arguments.len - 1];
    if (candidate == .function) return self.callFunctionValue(candidate.function, &.{});
    if (candidate == .string) {
        const callable = try self.resolveCallback(candidate);
        return self.callFunctionValue(callable.function, &.{});
    }
    return candidate;
}

pub fn measureCallable(self: *Interpreter, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.NotCallable;
    const callable = try self.resolveCallback(arguments[arguments.len - 1]);
    const started = try self.host.monotonicMilliseconds();
    _ = try self.callFunctionValue(callable.function, &.{});
    const finished = try self.host.monotonicMilliseconds();
    return .{ .number = finished - started };
}

pub fn debugDisplay(self: *Interpreter, arguments: []const Value) !Value {
    const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    const printable = switch (value) {
        .null_value, .array, .dictionary, .bytes => (try plugin_system.json.call(self.runtime, "JSON変換", &.{value})).?,
        else => value,
    };
    const text = try self.runtime.valueToString(printable);
    const utf8 = try text.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(utf8);
    const line = if (self.current_span) |span| span.line + 1 else 1;
    const raw_source_path = if (self.current_source_path.len > 0) self.current_source_path else self.primaryModuleName();
    const source_path = normalizeDebugSourcePath(raw_source_path, builtin.os.tag == .windows);
    const message = try std.fmt.allocPrint(self.allocator, "{s}({d}): {s}", .{ source_path, line, utf8 });
    defer self.allocator.free(message);
    var message_value = try self.runtime.stringUtf8(message);
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&message_value);
    _ = try self.display(&.{message_value});
    return .undefined;
}

pub fn normalizeDebugSourcePath(source_path: []const u8, windows: bool) []const u8 {
    if (windows) {
        if (std.mem.indexOfScalar(u8, source_path, ':')) |separator| return source_path[0..separator];
    }
    return source_path;
}

pub fn configureHatena(self: *Interpreter, arguments: []const Value) !Value {
    self.hatena_callbacks.clearRetainingCapacity();
    if (arguments.len == 0) return .undefined;
    const setting = arguments[arguments.len - 1];
    switch (setting) {
        .function => try self.hatena_callbacks.append(self.allocator, .{ .function = setting }),
        .string => try self.appendHatenaName(setting),
        .array => |array| for (array.items.items) |item| {
            if (item != .string) return error.InvalidHatenaCallback;
            const utf8 = try item.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            if (std.mem.startsWith(u8, utf8, "JS:")) {
                var code = try self.runtime.stringUtf8(utf8[3..]);
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&code);
                const callback = try self.callBuiltin("JS実行", &.{code}, null);
                if (callback != .function) return error.InvalidHatenaCallback;
                try self.hatena_callbacks.append(self.allocator, .{ .function = callback });
            } else try self.appendHatenaName(item);
        },
        else => {},
    }
    return .undefined;
}

pub fn appendHatenaName(self: *Interpreter, name: Value) !void {
    try self.hatena_callbacks.append(self.allocator, .{ .name = name });
}

pub fn invokeHatena(self: *Interpreter, arguments: []const Value) !Value {
    var parameter = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&parameter);
    if (self.hatena_callbacks.items.len == 0) {
        _ = try self.debugDisplay(&.{parameter});
        return .undefined;
    }
    for (self.hatena_callbacks.items) |callback| parameter = switch (callback) {
        .function => |function| try self.callFunctionValue(function.function, &.{parameter}),
        .name => |name| try self.callNamedHatena(name, parameter),
    };
    return .undefined;
}

pub fn callNamedHatena(self: *Interpreter, name_value: Value, parameter: Value) !Value {
    const name = try name_value.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(name);
    return self.callBuiltin(name, &.{parameter}, null);
}

pub fn debugBreakpointWait(self: *Interpreter, arguments: []const Value) !Value {
    const line_value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    const line = try self.runtime.valueToNumber(line_value);
    const force_value: Value = self.globals.get("__DEBUG強制待機") orelse .undefined;
    const force_wait = force_value.toBoolean();
    try self.setGlobal("__DEBUG強制待機", .{ .number = 0 });
    var breakpoint_hit = false;
    if (self.globals.get("__DEBUGブレイクポイント一覧")) |breakpoints| if (breakpoints == .array) {
        for (breakpoints.array.items.items) |candidate| if (Value.strictEqual(candidate, .{ .number = line })) {
            breakpoint_hit = true;
            break;
        };
    };
    if (!force_wait and !breakpoint_hit) return .{ .number = line };

    const plugin_name = self.globals.get("プラグイン名") orelse .undefined;
    const main_name = try self.runtime.stringUtf8("メイン");
    if (!Value.strictEqual(plugin_name, main_name)) return self.runtime.createPromise();
    while (true) {
        const flag = self.globals.get("__DEBUG待機フラグ") orelse .undefined;
        if (flag == .number and flag.number == 1) {
            try self.setGlobal("__DEBUG待機フラグ", .{ .number = 0 });
            return .{ .number = line };
        }
        try self.waitMilliseconds(500);
    }
}

pub fn display(self: *Interpreter, arguments: []const Value) !Value {
    const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    const text = try self.runtime.valueToString(value);
    const utf8 = try text.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(utf8);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.allocator);
    try output.appendSlice(self.allocator, self.print_pool.items);
    try output.appendSlice(self.allocator, utf8);
    self.print_pool.clearRetainingCapacity();
    try self.writeOutput(output.items);
    try self.writeOutput("\n");
    try self.appendDisplayLog(output.items);
    return .undefined;
}

pub fn continueDisplay(self: *Interpreter, arguments: []const Value) !Value {
    const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
    const text = try self.runtime.valueToString(value);
    const utf8 = try text.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(utf8);
    try self.print_pool.appendSlice(self.allocator, utf8);
    return .undefined;
}

pub fn displayMany(self: *Interpreter, arguments: []const Value) !Value {
    var text = try self.joinValues(arguments);
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&text);
    return self.display(&.{text});
}

pub fn continueDisplayMany(self: *Interpreter, arguments: []const Value) !Value {
    var text = try self.joinValues(arguments);
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&text);
    return self.continueDisplay(&.{text});
}

pub fn joinValues(self: *Interpreter, arguments: []const Value) !Value {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.allocator);
    for (arguments) |value| {
        const text = try self.runtime.valueToString(value);
        const utf8 = try text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(utf8);
        try output.appendSlice(self.allocator, utf8);
    }
    return self.runtime.stringUtf8(output.items);
}

pub fn writeValues(self: *Interpreter, arguments: []const Value, all: bool) !void {
    const values = if (all) arguments else if (arguments.len > 0) arguments[arguments.len - 1 ..] else &.{};
    for (values) |value| {
        const text = try self.runtime.valueToString(value);
        const utf8 = try text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(utf8);
        try self.writeOutput(utf8);
    }
}

pub fn appendDisplayLog(self: *Interpreter, line: []const u8) !void {
    const current = self.globals.get("表示ログ") orelse try self.runtime.stringUtf8("");
    const current_text = try self.runtime.valueToString(current);
    const current_utf8 = try current_text.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(current_utf8);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.allocator);
    try output.appendSlice(self.allocator, current_utf8);
    try output.appendSlice(self.allocator, line);
    try output.append(self.allocator, '\n');
    try self.setGlobal("表示ログ", try self.runtime.stringUtf8(output.items));
}

pub fn pluginContext(self: *Interpreter) !plugin_system.Context {
    return .{
        .arrays = .{
            .context = self,
            .randomFn = pluginRandom,
            .callFn = pluginCall,
            .resolveFn = pluginResolve,
        },
        .strings = .{
            .context = self,
            .callFn = pluginCall,
        },
        .datetime = .{
            .now_milliseconds = try self.host.nowMilliseconds(),
            .monotonic_milliseconds = try self.host.monotonicMilliseconds(),
        },
        .path_separator = if (self.host.node_context == null) "/" else std.fs.path.sep_str,
    };
}

pub fn nodeEffects(self: *Interpreter) plugin_node.Effects {
    return .{
        .context = self,
        .invokeFn = pluginCall,
        .resolveFn = nodeResolve,
        .getGlobalFn = nodeGetGlobal,
        .setGlobalFn = nodeSetGlobal,
    };
}

pub fn httpServerEffects(self: *Interpreter) plugin_http_server.Effects {
    return .{
        .context = self,
        .invokeFn = pluginCall,
        .resolveFn = nodeResolve,
        .setGlobalFn = nodeSetGlobal,
    };
}

pub fn quickJsEffects(self: *Interpreter) quickjs.Effects {
    return .{
        .context = self,
        .invokeFn = pluginCall,
        .resolveFn = quickJsResolve,
        .getGlobalFn = nodeGetGlobal,
        .setGlobalFn = nodeSetGlobal,
        .execFn = quickJsExec,
    };
}

pub fn nativePluginEffects(self: *Interpreter) plugin_native.Effects {
    return .{
        .context = self,
        .invokeFn = pluginCall,
        .execFn = quickJsExec,
    };
}

pub fn nodeResolve(context: *anyopaque, value: Value) !Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    return self.resolveCallback(value);
}

pub fn nodeSetGlobal(context: *anyopaque, name: []const u8, value: Value) !void {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    try self.setGlobal(name, value);
}

pub fn nodeGetGlobal(context: *anyopaque, name: []const u8) ?Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    return self.globals.get(name);
}

pub fn handleNodeInterrupt(self: *Interpreter) !void {
    const context = self.host.node_context orelse return;
    const consume = context.consumeInterruptFn orelse return;
    if (!consume(context.context) or self.node_state.interrupt_callback == .undefined) return;
    const result = try self.callFunctionValue(self.node_state.interrupt_callback.function, &.{.undefined});
    if (result.toBoolean()) {
        self.node_state.requested_exit_code = 0;
        self.process_exit_reason = "interrupt-callback";
        return error.ProcessExitRequested;
    }
}

pub fn pluginRandom(context: *anyopaque) !f64 {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    return self.host.random();
}

pub fn pluginCall(context: *anyopaque, callable: Value, arguments: []const Value) !Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    if (callable != .function) return error.NotCallable;
    return self.callFunctionValue(callable.function, arguments);
}

pub fn pluginResolve(context: *anyopaque, name: []const u8) !Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    var name_value = try self.runtime.stringUtf8(name);
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&name_value);
    return self.resolveCallback(name_value);
}

pub fn quickJsResolve(context: *anyopaque, name: []const u8) !Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    var frame = self.active_frame;
    while (frame) |current| : (frame = current.parent) {
        if (localValue(current, name)) |value| return value;
    }
    if (self.globals.get(name)) |value| return value;

    // Module-level variables are stored under `module__name`.  The
    // official JS bridge accepts the unqualified source spelling, so use
    // it only when it identifies exactly one global across all modules.
    var match: ?Value = null;
    var iterator = self.globals.iterator();
    while (iterator.next()) |entry| {
        const separator = std.mem.lastIndexOf(u8, entry.key_ptr.*, "__") orelse continue;
        if (!std.mem.eql(u8, entry.key_ptr.*[separator + 2 ..], name)) continue;
        if (match != null) return error.AmbiguousGlobal;
        match = entry.value_ptr.*;
    }
    if (match) |value| return value;
    return pluginResolve(context, name);
}

pub fn quickJsExec(context: *anyopaque, name: []const u8, arguments: []const Value) !Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    if (quickJsResolve(self, name)) |callable| {
        if (callable == .function) return self.callFunctionValue(callable.function, arguments);
    } else |_| {}
    return self.callBuiltin(name, arguments, null);
}

pub fn installSystemConstant(context: *anyopaque, name: []const u8, value: Value) !void {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    try self.setGlobal(name, value);
}
