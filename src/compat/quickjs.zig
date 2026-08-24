const std = @import("std");
const build_options = @import("build_options");
const value_mod = @import("../runtime/value.zig");
const common = @import("../plugins/system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const Engine = opaque {};
const RawValue = opaque {};
const RawKeys = opaque {};

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

extern fn lnako_qjs_new() ?*Engine;
const HostGetFn = *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) ?*RawValue;
const HostSetFn = *const fn (*anyopaque, [*:0]const u8, *const RawValue) callconv(.c) c_int;
const HostInvokeFn = *const fn (*anyopaque, usize, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
const HostExecFn = *const fn (*anyopaque, [*:0]const u8, [*c]const *const RawValue, usize) callconv(.c) ?*RawValue;
extern fn lnako_qjs_set_host(engine: *Engine, context: *anyopaque, get: HostGetFn, set: HostSetFn, invoke: HostInvokeFn, exec: HostExecFn) void;
extern fn lnako_qjs_add_module_source(engine: *Engine, name: [*:0]const u8, source: [*]const u8, length: usize) c_int;
extern fn lnako_qjs_release(engine: *Engine) void;
extern fn lnako_qjs_take_error(engine: *Engine) ?[*:0]u8;
extern fn lnako_qjs_free_string(text: [*:0]u8) void;
extern fn lnako_qjs_eval(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_eval_module(engine: *Engine, source: [*]const u8, length: usize, filename: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_global(engine: *Engine, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_call(engine: *Engine, function: *const RawValue, arguments: [*]const *const RawValue, count: usize) ?*RawValue;
extern fn lnako_qjs_call_method(engine: *Engine, object: *const RawValue, name: [*:0]const u8, arguments: [*]const *const RawValue, count: usize) ?*RawValue;
extern fn lnako_qjs_drain_jobs(engine: *Engine) c_int;
extern fn lnako_qjs_await(engine: *Engine, promise: *const RawValue) ?*RawValue;
extern fn lnako_qjs_undefined(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_null(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_boolean(engine: *Engine, value: c_int) ?*RawValue;
extern fn lnako_qjs_number(engine: *Engine, value: f64) ?*RawValue;
extern fn lnako_qjs_string(engine: *Engine, value: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_bigint(engine: *Engine, decimal: [*]const u8, length: usize) ?*RawValue;
extern fn lnako_qjs_array(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_object(engine: *Engine) ?*RawValue;
extern fn lnako_qjs_host_function(engine: *Engine, function_id: usize, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_dup(value: *const RawValue) ?*RawValue;
extern fn lnako_qjs_value_engine(value: *const RawValue) ?*Engine;
extern fn lnako_qjs_value_free(value: *RawValue) void;
extern fn lnako_qjs_kind(value: *const RawValue) Kind;
extern fn lnako_qjs_identity(value: *const RawValue) usize;
extern fn lnako_qjs_to_boolean(value: *const RawValue) c_int;
extern fn lnako_qjs_to_number(value: *const RawValue, result: *f64) c_int;
extern fn lnako_qjs_to_string(value: *const RawValue, length: *usize) ?[*:0]u8;
extern fn lnako_qjs_array_length(value: *const RawValue) u32;
extern fn lnako_qjs_get_index(value: *const RawValue, index: u32) ?*RawValue;
extern fn lnako_qjs_set_index(value: *RawValue, index: u32, item: *const RawValue) c_int;
extern fn lnako_qjs_set_array_length(value: *RawValue, length: u32) c_int;
extern fn lnako_qjs_get_property(value: *const RawValue, name: [*:0]const u8) ?*RawValue;
extern fn lnako_qjs_set_property(value: *RawValue, name: [*:0]const u8, item: *const RawValue) c_int;
extern fn lnako_qjs_clear_properties(value: *RawValue) c_int;
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
    host_functions: std.ArrayList(Value) = .empty,
    syncing: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn init(enabled: bool) State {
        return .{ .enabled = enabled };
    }

    pub fn deinit(self: *State) void {
        if (build_options.quickjs_enabled) if (self.engine) |engine| lnako_qjs_release(engine);
        if (self.runtime) |runtime| {
            self.host_functions.deinit(runtime.allocator());
            self.syncing.deinit(runtime.allocator());
        }
        self.* = undefined;
    }

    pub fn trace(self: *State, runtime: *Runtime) !void {
        for (self.host_functions.items) |value| try runtime.traceExternal(value);
    }

    fn hostFunction(self: *State, engine: *Engine, value: Value) !*RawValue {
        const function = value.function;
        var function_id: usize = 0;
        while (function_id < self.host_functions.items.len) : (function_id += 1) {
            const candidate = self.host_functions.items[function_id];
            if (candidate == .function and candidate.function == function) break;
        }
        if (function_id == self.host_functions.items.len) {
            const runtime = self.runtime orelse return error.QuickJsHostUnavailable;
            try self.host_functions.append(runtime.allocator(), value);
        }
        const runtime = self.runtime orelse return error.QuickJsHostUnavailable;
        const name = try function.name.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(name);
        const name_z = try runtime.allocator().dupeZ(u8, name);
        defer runtime.allocator().free(name_z);
        return lnako_qjs_host_function(engine, function_id, name_z.ptr) orelse error.OutOfMemory;
    }

    fn ensure(self: *State, runtime: *Runtime, effects: Effects) !*Engine {
        if (!self.enabled or !build_options.quickjs_enabled) return error.QuickJsCompatibilityRequired;
        self.runtime = runtime;
        self.effects = effects;
        if (self.engine) |engine| {
            lnako_qjs_set_host(engine, self, hostGet, hostSet, hostInvoke, hostExec);
            return engine;
        }
        const engine = lnako_qjs_new() orelse return error.QuickJsInitializationFailed;
        self.engine = engine;
        lnako_qjs_set_host(engine, self, hostGet, hostSet, hostInvoke, hostExec);
        const bootstrap =
            \\globalThis.sys = globalThis.sys || Object.create(null);
            \\sys.__findFunc = function(name, parent) { const f = sys.__findVar(name, undefined); if (typeof f === 'function') return f; throw new Error(`『${parent}』に実行できない関数が指定されました。`); };
            \\sys.__exec = function(name, params) { return globalThis.__lnako_hostExec(name, ...(Array.isArray(params) ? params : [params])); };
            \\sys.__setSore = function(value) { sys.__setSysVar('それ', value); return value; };
            \\sys.__getSore = function() { return sys.__getSysVar('それ'); };
            \\sys.pathSeparator = '/';
            \\sys.tags = Object.create(null);
            \\globalThis.__lnako_commands = Object.create(null);
            \\globalThis.__lnako_plugins = new WeakSet();
            \\globalThis.__lnako_registerPlugin = function(plugin) {
            \\  if (!plugin || (typeof plugin !== 'object' && typeof plugin !== 'function')) return;
            \\  if (globalThis.__lnako_plugins.has(plugin)) return;
            \\  globalThis.__lnako_plugins.add(plugin);
            \\  for (const name of Object.keys(plugin || {})) {
            \\    if (name !== 'meta' && name !== '初期化') globalThis.__lnako_commands[name] = plugin[name];
            \\  }
            \\  const initializer = plugin['初期化'];
            \\  if (typeof initializer === 'function') initializer(sys);
            \\  else if (initializer && typeof initializer.fn === 'function') initializer.fn(sys);
            \\};
            \\globalThis.navigator = globalThis.navigator || { nako3: { addPluginObject: function(_name, plugin) { globalThis.__lnako_registerPlugin(plugin); } } };
            \\globalThis.console = globalThis.console || { log: function(){}, error: function(){}, warn: function(){} };
        ;
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
    return toRaw(state, runtime, engine, value) catch null;
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

fn hostInvoke(context: *anyopaque, function_id: usize, raw_arguments: [*c]const *const RawValue, count: usize) callconv(.c) ?*RawValue {
    const state: *State = @ptrCast(@alignCast(context));
    if (function_id >= state.host_functions.items.len) return null;
    return hostCall(state, state.host_functions.items[function_id], null, raw_arguments, count);
}

fn hostExec(context: *anyopaque, name: [*:0]const u8, raw_arguments: [*c]const *const RawValue, count: usize) callconv(.c) ?*RawValue {
    const state: *State = @ptrCast(@alignCast(context));
    return hostCall(state, null, std.mem.span(name), raw_arguments, count);
}

fn hostCall(state: *State, callable: ?Value, command: ?[]const u8, raw_arguments: [*c]const *const RawValue, count: usize) ?*RawValue {
    const runtime = state.runtime orelse return null;
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
        const synchronized = toRaw(state, runtime, engine, argument) catch return null;
        lnako_qjs_value_free(synchronized);
    }
    return toRaw(state, runtime, engine, result) catch null;
}

pub fn available() bool {
    return build_options.quickjs_enabled;
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
        if (callable == .function and callable.function.kind != .external) return @as(?Value, try effects.invoke(callable, slice));
        return @as(?Value, try callExternalValue(state, runtime, callable, slice));
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
        const method = try common.toUtf8Alloc(runtime, common.argument(arguments, 1));
        defer runtime.allocator().free(method);
        const method_z = try runtime.allocator().dupeZ(u8, method);
        defer runtime.allocator().free(method_z);
        const call_arguments = common.argument(arguments, 2);
        const slice = if (call_arguments == .array) call_arguments.array.items.items else arguments[2..@min(arguments.len, 3)];
        return @as(?Value, try callExternalMethod(state, runtime, engine, object, method_z, slice));
    }
    unreachable;
}

pub fn installModules(runtime: *Runtime, state: *State, modules: []const @import("../ir/nako_ir.zig").JavaScriptModule, effects: Effects) !void {
    if (!state.enabled) return;
    const engine = try state.ensure(runtime, effects);
    for (modules) |module| {
        const filename = try runtime.allocator().dupeZ(u8, module.path);
        defer runtime.allocator().free(filename);
        if (lnako_qjs_add_module_source(engine, filename.ptr, module.source.ptr, module.source.len) < 0) return error.QuickJsModuleRegistrationFailed;
    }
    for (modules) |module| {
        if (!module.is_plugin) continue;
        const filename = try runtime.allocator().dupeZ(u8, module.path);
        defer runtime.allocator().free(filename);
        const plugin = lnako_qjs_eval_module(engine, module.source.ptr, module.source.len, filename.ptr) orelse return quickJsError(engine);
        defer lnako_qjs_value_free(plugin);
        const register = try globalProperty(engine, "__lnako_registerPlugin");
        defer lnako_qjs_value_free(register);
        const arguments = [_]*const RawValue{plugin};
        const result = lnako_qjs_call(engine, register, &arguments, arguments.len) orelse return quickJsError(engine);
        lnako_qjs_value_free(result);
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
        const name_z = try runtime.allocator().dupeZ(u8, name);
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

fn callPlugin(self: *State, runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const engine = self.engine orelse return null;
    const commands = try globalProperty(engine, "__lnako_commands");
    defer lnako_qjs_value_free(commands);
    var lookup_name = name;
    var name_z = try runtime.allocator().dupeZ(u8, lookup_name);
    defer runtime.allocator().free(name_z);
    var definition_value = lnako_qjs_get_property(commands, name_z.ptr) orelse return quickJsError(engine);
    if (lnako_qjs_kind(definition_value) == .undefined) {
        if (std.mem.lastIndexOf(u8, name, "__")) |separator| {
            lnako_qjs_value_free(definition_value);
            lookup_name = name[separator + 2 ..];
            runtime.allocator().free(name_z);
            name_z = try runtime.allocator().dupeZ(u8, lookup_name);
            definition_value = lnako_qjs_get_property(commands, name_z.ptr) orelse return quickJsError(engine);
        }
    }
    defer lnako_qjs_value_free(definition_value);
    if (lnako_qjs_kind(definition_value) == .undefined) return null;
    const function = lnako_qjs_get_property(definition_value, "fn") orelse return quickJsError(engine);
    defer lnako_qjs_value_free(function);
    if (lnako_qjs_kind(function) != .function) return null;
    const raw_arguments = try runtime.allocator().alloc(*const RawValue, arguments.len + 1);
    defer runtime.allocator().free(raw_arguments);
    var initialized: usize = 0;
    defer for (raw_arguments[0..initialized]) |value| lnako_qjs_value_free(@constCast(value));
    for (arguments, 0..) |argument, index| {
        raw_arguments[index] = try toRaw(self, runtime, engine, argument);
        initialized += 1;
    }
    raw_arguments[arguments.len] = try globalProperty(engine, "sys");
    initialized += 1;
    var result = lnako_qjs_call(engine, function, raw_arguments.ptr, raw_arguments.len) orelse return quickJsError(engine);
    if (lnako_qjs_kind(result) == .promise) {
        const promise = result;
        result = lnako_qjs_await(engine, promise) orelse {
            lnako_qjs_value_free(promise);
            return quickJsError(engine);
        };
        lnako_qjs_value_free(promise);
    }
    for (arguments, raw_arguments[0..arguments.len]) |argument, raw_argument| try refreshExternal(self, runtime, argument, @constCast(raw_argument));
    const return_none_value = lnako_qjs_get_property(definition_value, "return_none") orelse return quickJsError(engine);
    defer lnako_qjs_value_free(return_none_value);
    if (lnako_qjs_to_boolean(return_none_value) != 0) {
        lnako_qjs_value_free(result);
        return @as(?Value, .undefined);
    }
    return @as(?Value, try fromRaw(self, runtime, result));
}

fn globalProperty(engine: *Engine, name: [:0]const u8) !*RawValue {
    return lnako_qjs_global(engine, name.ptr) orelse quickJsError(engine);
}

fn isCompatCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, "JS実行") or std.mem.eql(u8, name, "JSオブジェクト取得") or std.mem.eql(u8, name, "JS関数実行") or std.mem.eql(u8, name, "JSメソッド実行");
}

fn callExternalValue(state: *State, runtime: *Runtime, callable: Value, arguments: []const Value) !Value {
    if (callable != .function or callable.function.kind != .external) return error.QuickJsValueNotCallable;
    const external = callable.function.kind.external;
    if (external.binding.context != @as(*anyopaque, @ptrCast(state))) return error.QuickJsEngineMismatch;
    return external.callFn(external.binding.context, external.binding.handle, runtime, arguments);
}

fn callExternalMethod(state: *State, runtime: *Runtime, engine: *Engine, object: Value, method: [:0]const u8, arguments: []const Value) !Value {
    const raw_object = try toRaw(state, runtime, engine, object);
    defer lnako_qjs_value_free(raw_object);
    const raw_arguments = try rawArguments(state, runtime, engine, arguments);
    defer freeRawArguments(runtime.allocator(), raw_arguments);
    const result = lnako_qjs_call_method(engine, raw_object, method.ptr, raw_arguments.ptr, raw_arguments.len) orelse return quickJsError(engine);
    if (lnako_qjs_drain_jobs(engine) < 0) return quickJsError(engine);
    try refreshExternal(state, runtime, object, raw_object);
    for (arguments, raw_arguments) |argument, raw_argument| try refreshExternal(state, runtime, argument, @constCast(raw_argument));
    return fromRaw(state, runtime, result);
}

fn externalCall(context: *anyopaque, handle: *anyopaque, runtime: *Runtime, arguments: []const Value) !Value {
    const state: *State = @ptrCast(@alignCast(context));
    const engine = state.engine orelse return error.QuickJsEngineClosed;
    const function: *RawValue = @ptrCast(@alignCast(handle));
    const raw_arguments = try rawArguments(state, runtime, engine, arguments);
    defer freeRawArguments(runtime.allocator(), raw_arguments);
    const result = lnako_qjs_call(engine, function, raw_arguments.ptr, raw_arguments.len) orelse return quickJsError(engine);
    if (lnako_qjs_drain_jobs(engine) < 0) return quickJsError(engine);
    for (arguments, raw_arguments) |argument, raw_argument| try refreshExternal(state, runtime, argument, @constCast(raw_argument));
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

fn rawArguments(state: *State, runtime: *Runtime, engine: *Engine, arguments: []const Value) ![]*const RawValue {
    const result = try runtime.allocator().alloc(*const RawValue, arguments.len);
    errdefer runtime.allocator().free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |value| lnako_qjs_value_free(@constCast(value));
    for (arguments, 0..) |argument, index| {
        result[index] = try toRaw(state, runtime, engine, argument);
        initialized += 1;
    }
    return result;
}

fn freeRawArguments(allocator: std.mem.Allocator, arguments: []*const RawValue) void {
    for (arguments) |value| lnako_qjs_value_free(@constCast(value));
    allocator.free(arguments);
}

fn toRaw(state: *State, runtime: *Runtime, engine: *Engine, value: Value) anyerror!*RawValue {
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
            const text = try string.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(text);
            break :blk lnako_qjs_string(engine, text.ptr, text.len) orelse error.OutOfMemory;
        },
        .bytes => |bytes| blk: {
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
            if (array.external) |external| if (external.context == @as(*anyopaque, @ptrCast(engine))) {
                const result = lnako_qjs_dup(@ptrCast(@alignCast(external.handle))) orelse return error.OutOfMemory;
                errdefer lnako_qjs_value_free(result);
                try syncExternal(state, runtime, engine, value, result);
                break :blk result;
            };
            const result = lnako_qjs_array(engine) orelse return error.OutOfMemory;
            errdefer lnako_qjs_value_free(result);
            for (array.items.items, 0..) |item_value, index| {
                const item = try toRaw(state, runtime, engine, item_value);
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_index(result, @intCast(index), item) < 0) return quickJsError(engine);
            }
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            if (dictionary.external) |external| if (external.context == @as(*anyopaque, @ptrCast(engine))) {
                const result = lnako_qjs_dup(@ptrCast(@alignCast(external.handle))) orelse return error.OutOfMemory;
                errdefer lnako_qjs_value_free(result);
                try syncExternal(state, runtime, engine, value, result);
                break :blk result;
            };
            const result = lnako_qjs_object(engine) orelse return error.OutOfMemory;
            errdefer lnako_qjs_value_free(result);
            for (dictionary.keys(), dictionary.values()) |key, item_value| {
                const name = try key.toUtf8Lossy(runtime.allocator());
                defer runtime.allocator().free(name);
                const name_z = try runtime.allocator().dupeZ(u8, name);
                defer runtime.allocator().free(name_z);
                const item = try toRaw(state, runtime, engine, item_value);
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_property(result, name_z.ptr, item) < 0) return quickJsError(engine);
            }
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

fn syncExternal(state: *State, runtime: *Runtime, engine: *Engine, value: Value, raw: *RawValue) anyerror!void {
    const identity = switch (value) {
        .array => |array| @intFromPtr(array),
        .dictionary => |dictionary| @intFromPtr(dictionary),
        else => return,
    };
    if (state.syncing.contains(identity)) return;
    try state.syncing.put(runtime.allocator(), identity, {});
    defer _ = state.syncing.remove(identity);
    switch (value) {
        .array => |array| {
            if (array.items.items.len > std.math.maxInt(u32)) return error.QuickJsCollectionTooLarge;
            if (lnako_qjs_set_array_length(raw, @intCast(array.items.items.len)) < 0) return quickJsError(engine);
            for (array.items.items, 0..) |item_value, index| {
                const item = try toRaw(state, runtime, engine, item_value);
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_index(raw, @intCast(index), item) < 0) return quickJsError(engine);
            }
        },
        .dictionary => |dictionary| {
            if (lnako_qjs_clear_properties(raw) < 0) return quickJsError(engine);
            for (dictionary.keys(), dictionary.values()) |key, item_value| {
                const name = try key.toUtf8Lossy(runtime.allocator());
                defer runtime.allocator().free(name);
                const name_z = try runtime.allocator().dupeZ(u8, name);
                defer runtime.allocator().free(name_z);
                const item = try toRaw(state, runtime, engine, item_value);
                defer lnako_qjs_value_free(item);
                if (lnako_qjs_set_property(raw, name_z.ptr, item) < 0) return quickJsError(engine);
            }
        },
        else => unreachable,
    }
}

fn refreshExternal(state: *State, runtime: *Runtime, value: Value, raw: *RawValue) !void {
    if ((value != .array and value != .dictionary) or lnako_qjs_identity(raw) == 0) return;
    var conversion = Conversion{ .state = state, .runtime = runtime };
    defer conversion.seen.deinit(runtime.allocator());
    try conversion.refresh(value, raw);
}

fn fromRaw(state: *State, runtime: *Runtime, raw: *RawValue) !Value {
    var conversion = Conversion{ .state = state, .runtime = runtime };
    defer conversion.seen.deinit(runtime.allocator());
    return conversion.convert(raw);
}

const Conversion = struct {
    state: *State,
    runtime: *Runtime,
    seen: std.AutoHashMapUnmanaged(usize, Value) = .empty,

    fn refresh(self: *Conversion, value: Value, raw: *RawValue) !void {
        try self.seen.put(self.runtime.allocator(), lnako_qjs_identity(raw), value);
        switch (value) {
            .array => |array| {
                array.items.clearRetainingCapacity();
                const length = lnako_qjs_array_length(raw);
                for (0..length) |index| {
                    const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
                    _ = try array.push(try self.convert(item));
                }
            },
            .dictionary => |dictionary| {
                dictionary.map.clearRetainingCapacity();
                const keys = lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
                defer lnako_qjs_keys_free(keys);
                for (0..lnako_qjs_keys_length(keys)) |index| {
                    var name_length: usize = 0;
                    const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
                    const name = name_pointer[0..name_length];
                    const name_z = try self.runtime.allocator().dupeZ(u8, name);
                    defer self.runtime.allocator().free(name_z);
                    const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
                    try common.dictionarySetUtf8(self.runtime, dictionary, name, try self.convert(item));
                }
            },
            else => {},
        }
    }

    fn convert(self: *Conversion, raw: *RawValue) !Value {
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
                if (lnako_qjs_to_number(raw, &number) < 0) return error.QuickJsConversionFailed;
                lnako_qjs_value_free(raw);
                return .{ .number = number };
            },
            .string => {
                const text = try rawText(raw);
                defer lnako_qjs_free_string(text.pointer);
                lnako_qjs_value_free(raw);
                return self.runtime.stringUtf8(text.slice());
            },
            .bigint => {
                const text = try rawText(raw);
                defer lnako_qjs_free_string(text.pointer);
                const literal = try std.fmt.allocPrint(self.runtime.allocator(), "{s}n", .{text.slice()});
                defer self.runtime.allocator().free(literal);
                lnako_qjs_value_free(raw);
                return self.runtime.bigIntLiteral(literal);
            },
            .function => {
                const name_value = lnako_qjs_get_property(raw, "name") orelse return error.QuickJsConversionFailed;
                const name_text = rawText(name_value) catch null;
                defer {
                    if (name_text) |text| lnako_qjs_free_string(text.pointer);
                    lnako_qjs_value_free(name_value);
                }
                const name = try self.runtime.stringUtf8(if (name_text) |text| text.slice() else "<js>");
                errdefer lnako_qjs_value_free(raw);
                return self.runtime.createExternalFunction(name.string, 0, .{ .binding = functionBinding(self.state, raw), .callFn = externalCall });
            },
            .array => return self.convertArray(raw),
            .object, .promise => return self.convertObject(raw),
        }
    }

    fn convertArray(self: *Conversion, raw: *RawValue) !Value {
        const identity = lnako_qjs_identity(raw);
        if (self.seen.get(identity)) |existing| {
            lnako_qjs_value_free(raw);
            return existing;
        }
        var result = try self.runtime.createArray();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        result.array.external = objectBinding(@ptrCast(rawEngine(raw)), raw);
        try self.seen.put(self.runtime.allocator(), identity, result);
        const length = lnako_qjs_array_length(raw);
        for (0..length) |index| {
            const item = lnako_qjs_get_index(raw, @intCast(index)) orelse return error.QuickJsConversionFailed;
            _ = try result.array.push(try self.convert(item));
        }
        return result;
    }

    fn convertObject(self: *Conversion, raw: *RawValue) !Value {
        const identity = lnako_qjs_identity(raw);
        if (self.seen.get(identity)) |existing| {
            lnako_qjs_value_free(raw);
            return existing;
        }
        var result = try self.runtime.createDictionary();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        result.dictionary.external = objectBinding(@ptrCast(rawEngine(raw)), raw);
        try self.seen.put(self.runtime.allocator(), identity, result);
        const keys = lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
        defer lnako_qjs_keys_free(keys);
        for (0..lnako_qjs_keys_length(keys)) |index| {
            var name_length: usize = 0;
            const name_pointer = lnako_qjs_key(keys, index, &name_length) orelse continue;
            const name = name_pointer[0..name_length];
            const name_z = try self.runtime.allocator().dupeZ(u8, name);
            defer self.runtime.allocator().free(name_z);
            const item = lnako_qjs_get_property(raw, name_z.ptr) orelse return error.QuickJsConversionFailed;
            try common.dictionarySetUtf8(self.runtime, result.dictionary, name, try self.convert(item));
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

test "QuickJS互換ビルド状態を公開する" {
    try std.testing.expectEqual(build_options.quickjs_enabled, available());
}
