const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");
const low_level = @import("low_level.zig");
const low_level_state = @import("../low_level/state.zig");
const foundation = @import("../low_level_foundation.zig");

const aot_builtin = shared.aot_builtin;
const dynamic_ir = shared.dynamic_ir;
const dynamic_interpreter = shared.dynamic_interpreter;
const dynamic_value = shared.dynamic_value;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const staticUtf8 = aot_state.staticUtf8;
const invokeAotCallback = aot_state.invokeAotCallback;
const createAotPromise = aot_state.createAotPromise;
const writeBytes = aot_state.writeBytes;
const currentTimeMilliseconds = aot_state.currentTimeMilliseconds;
const monotonicTimeMilliseconds = aot_state.monotonicTimeMilliseconds;
const nextRandom = aot_state.nextRandom;

pub const DynamicGlobal = struct {
    name: []u8,
    value: Value = .{},
    slot: ?*Value = null,
};

pub const DynamicPromiseBridge = struct {
    state: *DynamicInterpreterState,
    promise: *dynamic_value.Promise,
    aot_promise: Value,
};

pub const AotFunctionBridge = struct {
    owner: *Runtime,
    state: *DynamicInterpreterState,
    value: Value,
};

const DynamicHostContext = struct {
    owner: *Runtime,

    pub fn host(self: *DynamicHostContext) dynamic_interpreter.Host {
        return .{
            .context = self,
            .writeFn = write,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
            .lowlevel_context = low_level.pluginContext(self.owner),
        };
    }

    pub fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        _ = self;
        writeBytes(bytes, false);
    }

    pub fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        self.owner.elapsed_milliseconds = std.math.add(u64, self.owner.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    }

    pub fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return currentTimeMilliseconds(self.owner);
    }

    pub fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return monotonicTimeMilliseconds(self.owner);
    }

    pub fn random(context: *anyopaque) !f64 {
        const self: *DynamicHostContext = @ptrCast(@alignCast(context));
        return nextRandom(self.owner);
    }
};

pub const DynamicInterpreterState = struct {
    allocator: std.mem.Allocator,
    owner: *Runtime,
    value_runtime: dynamic_value.Runtime,
    program: dynamic_ir.Program,
    interpreter: dynamic_interpreter.Interpreter,
    host_context: DynamicHostContext,
    reset_display_log: bool = false,
    /// AOT 側 `dynamic_globals` を plugin 実行前に interpreter へ同期した時点の
    /// 構造fingerprint。plugin が上書きした値（`.function` などAOTへ変換不能な
    /// 値を含む）を、AOT側が変化していないのに再同期で潰さないために使う。
    synced_aot_hashes: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator, owner: *Runtime) !*@This() {
        const state = try allocator.create(@This());
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.owner = owner;
        state.synced_aot_hashes = .empty;
        var synced_hashes_initialized = true;
        errdefer if (synced_hashes_initialized) {
            var hash_iterator = state.synced_aot_hashes.keyIterator();
            while (hash_iterator.next()) |name| allocator.free(name.*);
            state.synced_aot_hashes.deinit(allocator);
        };
        state.value_runtime = dynamic_value.Runtime.init(allocator);
        var value_runtime_initialized = true;
        errdefer if (value_runtime_initialized) state.value_runtime.deinit();
        try state.value_runtime.registerRootProvider(.{ .context = state, .traceFn = traceDynamicBridges });
        var dynamic_bridge_provider_initialized = true;
        errdefer if (dynamic_bridge_provider_initialized) state.value_runtime.unregisterRootProvider(state);
        state.program = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .functions = &.{},
            .module_entries = &.{},
        };
        var program_initialized = true;
        errdefer if (program_initialized) state.program.deinit();
        const path_allocator = state.program.arena.allocator();
        const paths = try path_allocator.alloc([]const u8, owner.native_plugin_paths.items.len);
        for (owner.native_plugin_paths.items, paths) |path, *copy| copy.* = try path_allocator.dupe(u8, path);
        state.program.native_plugin_paths = paths;
        const packages = try path_allocator.alloc(dynamic_ir.NativePluginPackage, owner.native_plugin_packages.items.len);
        for (owner.native_plugin_packages.items, packages) |package, *copy| copy.* = .{
            .path = try path_allocator.dupe(u8, package.path),
            .namespace = try path_allocator.dupe(u8, package.namespace),
        };
        state.program.native_plugin_packages = packages;
        // compat ESM manifest の module を埋め込み interpreter へ引き継ぐ。
        // `Interpreter` の初期化時に `installModules` が走り、plugin 命令が
        // この state の `__lnako_commands` に登録される。これが無いと
        // `callExternalCommand` が `UnknownCommand` になる。
        if (owner.esm_modules.items.len > 0) {
            const modules = try path_allocator.alloc(dynamic_ir.JavaScriptModule, owner.esm_modules.items.len);
            for (owner.esm_modules.items, modules) |module, *copy| {
                copy.* = .{
                    .path = try path_allocator.dupe(u8, module.path),
                    .source = try path_allocator.dupe(u8, module.source),
                    .is_plugin = module.is_plugin,
                    .package_root = if (module.package_root) |root| try path_allocator.dupe(u8, root) else null,
                    .namespaces = blk: {
                        const list = try path_allocator.alloc([]const u8, module.namespaces.len);
                        for (module.namespaces, list) |namespace, *slot| slot.* = try path_allocator.dupe(u8, namespace);
                        break :blk list;
                    },
                    .bare_aliases = blk: {
                        const list = try path_allocator.alloc([]const u8, module.bare_aliases.len);
                        for (module.bare_aliases, list) |alias, *slot| slot.* = try path_allocator.dupe(u8, alias);
                        break :blk list;
                    },
                };
            }
            state.program.javascript_modules = modules;
            // `Interpreter` は `program.compat_js` で QuickJS state を有効化
            // する。ESM module を持つなら compat 経路なので有効にする。
            state.program.compat_js = true;
        }
        state.host_context = .{ .owner = owner };
        state.interpreter = dynamic_interpreter.Interpreter.init(
            allocator,
            &state.value_runtime,
            state.program,
            state.host_context.host(),
        );
        var interpreter_initialized = true;
        errdefer if (interpreter_initialized) state.interpreter.deinit();
        try state.interpreter.activateExternalRuntime();
        // plugin の `初期化` はここまでに interpreter.globals を書き換え得る。
        // AOTへ変換不能な値（JS関数など）を最初の `esmPluginBuiltin` で
        // AOT値に上書きしないよう、現在のAOT fingerprintを記録しておく。
        try seedPluginInitializedHashes(state);
        interpreter_initialized = false;
        dynamic_bridge_provider_initialized = false;
        program_initialized = false;
        value_runtime_initialized = false;
        synced_hashes_initialized = false;
        // Runtime側からinterpreterへの静的呼び出しを避けるため、
        // 解放とnative plugin drainはここで間接呼び出しとして登録する。
        owner.dynamic_deinit = deinitDynamicState;
        owner.dynamic_drain = drainNativePluginTasks;
        owner.dynamic_forget_handle = forgetDynamicHandle;
        return state;
    }

    pub fn deinit(self: *@This()) void {
        self.interpreter.deactivateExternalRuntime();
        self.interpreter.deinit();
        self.value_runtime.unregisterRootProvider(self);
        self.program.deinit();
        self.value_runtime.deinit();
        var hash_iterator = self.synced_aot_hashes.keyIterator();
        while (hash_iterator.next()) |name| self.allocator.free(name.*);
        self.synced_aot_hashes.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn traceDynamicBridges(context: *anyopaque, runtime: *dynamic_value.Runtime) !void {
    const state: *DynamicInterpreterState = @ptrCast(@alignCast(context));
    for (state.owner.dynamic_promise_bridges.items) |bridge| {
        if (bridge.state == state) try runtime.traceExternal(.{ .promise = bridge.promise });
    }
}

pub fn dynamicGlobal(runtime: *Runtime, name: []const u8) ?*DynamicGlobal {
    for (runtime.dynamic_globals.items) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

pub fn upsertDynamicGlobal(runtime: *Runtime, name: []const u8, value: Value) !void {
    if (dynamicGlobal(runtime, name)) |entry| {
        // slotを持つ静的グローバルはslotだけが正本。entry.valueにも複製する
        // と、なでしこ側の上書き後も古い値がGCルートとして残り続ける。
        if (entry.slot) |slot| slot.* = value else entry.value = value;
        return;
    }
    const owned_name = try runtime.allocator.dupe(u8, name);
    errdefer runtime.allocator.free(owned_name);
    try runtime.dynamic_globals.append(runtime.allocator, .{ .name = owned_name, .value = value });
}

pub fn removeAotFunctionBridge(owner: *Runtime, bridge: *AotFunctionBridge) void {
    for (owner.dynamic_function_bridges.items, 0..) |candidate, index| {
        if (candidate != bridge) continue;
        _ = owner.dynamic_function_bridges.swapRemove(index);
        owner.allocator.destroy(bridge);
        return;
    }
}

pub fn releaseAotFunctionBridge(context: *anyopaque, handle: *anyopaque) void {
    const owner: *Runtime = @ptrCast(@alignCast(context));
    const bridge: *AotFunctionBridge = @ptrCast(@alignCast(handle));
    removeAotFunctionBridge(owner, bridge);
}

pub fn callAotFunctionBridge(
    context: *anyopaque,
    handle: *anyopaque,
    _: *dynamic_value.Runtime,
    arguments: []const dynamic_value.Value,
) anyerror!dynamic_value.Value {
    const owner: *Runtime = @ptrCast(@alignCast(context));
    const bridge: *AotFunctionBridge = @ptrCast(@alignCast(handle));
    const aot_arguments = try owner.allocator.alloc(Value, arguments.len);
    defer owner.allocator.free(aot_arguments);
    @memset(aot_arguments, .{});
    var aot_roots = RootFrame{};
    owner.pushRoots(&aot_roots, aot_arguments.ptr, aot_arguments.len);
    defer owner.popRoots(&aot_roots);
    for (arguments, aot_arguments) |argument, *converted| converted.* = try dynamicToAotValue(bridge.state, argument);
    const result = try invokeAotCallback(owner, bridge.value, if (aot_arguments.len > 0) aot_arguments.ptr else null, aot_arguments.len);
    return aotToDynamicValue(bridge.state, result);
}

pub fn aotFunctionToDynamicValue(state: *DynamicInterpreterState, value: Value) anyerror!dynamic_value.Value {
    const object = value.object() orelse return error.DynamicValueUnsupported;
    if (object.payload != .function) return error.DynamicValueUnsupported;
    const function = object.payload.function;
    var dynamic_name = try state.value_runtime.stringUtf8(function.name);
    var name_roots = state.value_runtime.rootFrame();
    defer name_roots.deinit();
    try name_roots.protect(&dynamic_name);
    const bridge = try state.owner.allocator.create(AotFunctionBridge);
    bridge.* = .{ .owner = state.owner, .state = state, .value = value };
    errdefer state.owner.allocator.destroy(bridge);
    try state.owner.dynamic_function_bridges.append(state.owner.allocator, bridge);
    errdefer _ = state.owner.dynamic_function_bridges.pop();
    return state.value_runtime.createExternalFunction(
        dynamic_name.string,
        function.arity,
        .{
            .binding = .{
                .context = @ptrCast(state.owner),
                .handle = @ptrCast(bridge),
                .releaseFn = releaseAotFunctionBridge,
            },
            .callFn = callAotFunctionBridge,
        },
    );
}

pub fn dynamicPromiseToAotValue(state: *DynamicInterpreterState, promise: *dynamic_value.Promise) !Value {
    for (state.owner.dynamic_promise_bridges.items) |bridge| {
        if (bridge.state == state and bridge.promise == promise) return bridge.aot_promise;
    }

    var aot_promise = try createAotPromise(state.owner);
    var roots = RootFrame{};
    state.owner.pushRoots(&roots, @ptrCast(&aot_promise), 1);
    defer state.owner.popRoots(&roots);

    const bridge = try state.owner.allocator.create(DynamicPromiseBridge);
    bridge.* = .{ .state = state, .promise = promise, .aot_promise = aot_promise };
    errdefer state.owner.allocator.destroy(bridge);
    try state.owner.dynamic_promise_bridges.append(state.owner.allocator, bridge);
    return aot_promise;
}

const ContainerPair = struct {
    aot: Value,
    dynamic: dynamic_value.Value,
};

const AotToDynamicCache = struct {
    state: *DynamicInterpreterState,
    seen: std.AutoHashMapUnmanaged(usize, dynamic_value.Value) = .empty,
    containers: std.ArrayList(ContainerPair) = .empty,
    holder: dynamic_value.Value = .undefined,
    roots: dynamic_value.RootFrame,
    holder_protected: bool = false,
    aot_holder: Value = .{},
    aot_roots: RootFrame = .{},
    aot_roots_pushed: bool = false,

    fn init(state: *DynamicInterpreterState) AotToDynamicCache {
        return .{
            .state = state,
            .roots = state.value_runtime.rootFrame(),
        };
    }

    fn enter(self: *AotToDynamicCache) !void {
        if (!self.holder_protected) {
            try self.roots.protect(&self.holder);
            self.holder_protected = true;
        }
        if (!self.aot_roots_pushed) {
            self.state.owner.pushRoots(&self.aot_roots, @ptrCast(&self.aot_holder), 1);
            self.aot_roots_pushed = true;
        }
    }

    fn deinit(self: *AotToDynamicCache) void {
        if (self.aot_roots_pushed) self.state.owner.popRoots(&self.aot_roots);
        self.roots.deinit();
        self.containers.deinit(self.state.allocator);
        self.seen.deinit(self.state.allocator);
    }

    fn hold(self: *AotToDynamicCache, aot_value: Value, dyn_value: dynamic_value.Value) !void {
        try self.enter();
        if (self.holder == .undefined) {
            self.holder = try self.state.value_runtime.createArray();
        }
        _ = try self.holder.array.push(dyn_value);
        const owner = self.state.owner;
        if (self.aot_holder.tag == @backingInt(Tag.undefined)) {
            var tmp_aot = aot_value;
            var tmp_roots = RootFrame{};
            owner.pushRoots(&tmp_roots, @ptrCast(&tmp_aot), 1);
            defer owner.popRoots(&tmp_roots);
            self.aot_holder = try owner.createArray(&.{});
        }
        try self.aot_holder.object().?.payload.array.append(owner.allocator, aot_value);
    }
};

const DynamicToAotCache = struct {
    state: *DynamicInterpreterState,
    seen: std.AutoHashMapUnmanaged(usize, Value) = .empty,
    holder: Value = .{},
    roots: RootFrame = .{},
    roots_pushed: bool = false,

    fn init(state: *DynamicInterpreterState) DynamicToAotCache {
        return .{ .state = state };
    }

    fn enter(self: *DynamicToAotCache) void {
        if (!self.roots_pushed) {
            self.state.owner.pushRoots(&self.roots, @ptrCast(&self.holder), 1);
            self.roots_pushed = true;
        }
    }

    fn deinit(self: *DynamicToAotCache) void {
        if (self.roots_pushed) self.state.owner.popRoots(&self.roots);
        self.seen.deinit(self.state.owner.allocator);
    }

    fn hold(self: *DynamicToAotCache, value: Value) !void {
        const owner = self.state.owner;
        if (self.holder.tag == @backingInt(Tag.undefined)) {
            self.enter();
            var tmp = value;
            var tmp_roots = RootFrame{};
            owner.pushRoots(&tmp_roots, @ptrCast(&tmp), 1);
            defer owner.popRoots(&tmp_roots);
            self.holder = try owner.createArray(&.{});
        }
        try self.holder.object().?.payload.array.append(owner.allocator, value);
    }
};

pub fn aotToDynamicValue(state: *DynamicInterpreterState, value: Value) anyerror!dynamic_value.Value {
    var cache = AotToDynamicCache.init(state);
    defer cache.deinit();
    try cache.enter();
    return aotToDynamicValueWithCache(&cache, value);
}

fn aotToDynamicValueWithCache(cache: *AotToDynamicCache, value: Value) anyerror!dynamic_value.Value {
    const state = cache.state;
    const owner = state.owner;
    switch (@as(Tag, @fromBackingInt(@intCast(value.tag)))) {
        .undefined => return .undefined,
        .null_value => return .null_value,
        .boolean => return .{ .boolean = value.payload != 0 },
        .number => return .{ .number = @bitCast(value.payload) },
        .static_utf8_string => return state.value_runtime.stringUtf8(staticUtf8(value)),
        .utf16_string => return state.value_runtime.stringCodeUnits(value.object().?.payload.utf16_string),
        .bigint => {
            const text = try value.object().?.payload.bigint.toString(owner.allocator, 10);
            defer owner.allocator.free(text);
            return state.value_runtime.bigIntLiteral(text);
        },
        .byte_buffer => {
            const buffer = value.object().?.payload.byte_buffer;
            return switch (buffer.kind) {
                .buffer => state.value_runtime.createBytes(buffer.bytes),
                .uint8_array => state.value_runtime.createUint8Array(buffer.bytes),
                .array_buffer => state.value_runtime.createArrayBuffer(buffer.bytes),
            };
        },
        .array => {
            const object = value.object() orelse return error.DynamicValueUnsupported;
            const ptr = @intFromPtr(object);
            if (cache.seen.get(ptr)) |existing| return existing;

            var result = try state.value_runtime.createArray();
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            try cache.hold(value, result);
            try cache.seen.put(state.allocator, ptr, result);
            errdefer _ = cache.seen.remove(ptr);

            var prototype = try aotToDynamicValueWithCache(cache, object.prototype);
            try roots.protect(&prototype);
            result.array.prototype = prototype;

            const items = object.payload.array.items;
            const has_sparse_presence = object.array_presence.items.len > 0;
            for (items, 0..) |item, index| {
                const converted = try aotToDynamicValueWithCache(cache, item);
                _ = try result.array.push(converted);
                if (has_sparse_presence and index < object.array_presence.items.len and !object.array_presence.items[index]) {
                    result.array.presence.items[index] = false;
                }
            }

            var key_slot: dynamic_value.Value = .undefined;
            var item_slot: dynamic_value.Value = .undefined;
            try roots.protect(&key_slot);
            try roots.protect(&item_slot);
            for (object.array_properties.entries.items) |property| {
                key_slot = try aotToDynamicValueWithCache(cache, property.key);
                item_slot = try aotToDynamicValueWithCache(cache, property.value);
                if (key_slot != .string) return error.DynamicValueUnsupported;
                try result.array.setProperty(key_slot.string, item_slot);
            }
            // 子要素がすべて成功したコンテナだけを write-back 対象にする。
            try cache.containers.append(state.allocator, .{ .aot = value, .dynamic = result });
            return result;
        },
        .dictionary => {
            if (low_level.handleIdFor(owner, value)) |id| {
                if (low_level_state.handleForId(&state.interpreter.lowlevel_state, id)) |existing| return existing;
                var result = try state.value_runtime.createDictionary();
                var roots = state.value_runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&result);
                try low_level_state.rememberHandle(&state.interpreter.lowlevel_state, state.value_runtime.allocator(), result, id);
                return result;
            }
            const object = value.object() orelse return error.DynamicValueUnsupported;
            if (object.toml_temporal) |temporal| {
                return state.value_runtime.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            const ptr = @intFromPtr(object);
            if (cache.seen.get(ptr)) |existing| return existing;

            const kind: dynamic_value.DictionaryKind = if (object.structured_error) .structured_error else .ordinary;
            var result = try state.value_runtime.createDictionaryKind(kind);
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            try cache.hold(value, result);
            try cache.seen.put(state.allocator, ptr, result);
            errdefer _ = cache.seen.remove(ptr);

            var key_slot: dynamic_value.Value = .undefined;
            var item_slot: dynamic_value.Value = .undefined;
            try roots.protect(&key_slot);
            try roots.protect(&item_slot);
            for (object.payload.dictionary.entries.items) |entry| {
                key_slot = try aotToDynamicValueWithCache(cache, entry.key);
                item_slot = try aotToDynamicValueWithCache(cache, entry.value);
                if (key_slot != .string) return error.DynamicValueUnsupported;
                try result.dictionary.set(key_slot.string, item_slot);
            }
            try cache.containers.append(state.allocator, .{ .aot = value, .dynamic = result });
            return result;
        },
        .function => {
            const object = value.object() orelse return error.DynamicValueUnsupported;
            const ptr = @intFromPtr(object);
            if (cache.seen.get(ptr)) |existing| return existing;
            var converted = try aotFunctionToDynamicValue(state, value);
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&converted);
            try cache.hold(value, converted);
            try cache.seen.put(state.allocator, ptr, converted);
            return converted;
        },
        .promise, .iterator, .binding_cell => return error.DynamicValueUnsupported,
    }
}

/// 非循環の深い入れ子を止める安全上限。循環参照は `DynamicToAotCache.seen` が
/// 先に検出して既存値へ解決する。
const max_conversion_depth: usize = 256;

pub fn dynamicToAotValue(state: *DynamicInterpreterState, value: dynamic_value.Value) anyerror!Value {
    var cache = DynamicToAotCache.init(state);
    defer cache.deinit();
    cache.enter();
    return dynamicToAotValueCached(&cache, value, 0);
}

fn dynamicToAotValueCached(cache: *DynamicToAotCache, value: dynamic_value.Value, depth: usize) anyerror!Value {
    const state = cache.state;
    const owner = state.owner;
    return switch (value) {
        .undefined => .{},
        .null_value => .{ .tag = @backingInt(Tag.null_value) },
        .boolean => |boolean| .{ .tag = @backingInt(Tag.boolean), .payload = @intFromBool(boolean) },
        .number => |number| numberValue(number),
        .string => |string| owner.createString(string.units),
        .bigint => |bigint| blk: {
            const text = try bigint.toString(owner.allocator, 10);
            defer owner.allocator.free(text);
            break :blk owner.createBigInt(text);
        },
        .bytes => |bytes| switch (bytes.kind) {
            .buffer => owner.createBytes(bytes.bytes),
            .uint8_array => owner.createUint8Array(bytes.bytes),
            .array_buffer => owner.createArrayBuffer(bytes.bytes),
        },
        .array => |array| blk: {
            const ptr = @intFromPtr(array);
            if (cache.seen.get(ptr)) |existing| break :blk existing;
            if (depth > max_conversion_depth) return error.ValueNestingTooDeep;

            var result = try owner.createArray(&.{});
            var roots = RootFrame{};
            owner.pushRoots(&roots, @ptrCast(&result), 1);
            defer owner.popRoots(&roots);
            try cache.hold(result);
            try cache.seen.put(owner.allocator, ptr, result);
            errdefer _ = cache.seen.remove(ptr);

            result.object().?.prototype = try dynamicToAotValueCached(cache, array.prototype, depth + 1);
            for (array.items.items) |item| {
                const converted_item = try dynamicToAotValueCached(cache, item, depth + 1);
                try result.object().?.payload.array.append(owner.allocator, converted_item);
            }
            if (array.presence.items.len > 0) {
                const check_len = @min(array.presence.items.len, array.items.items.len);
                if (std.mem.indexOfScalar(bool, array.presence.items[0..check_len], false) != null) {
                    try result.object().?.array_presence.resize(owner.allocator, array.items.items.len);
                    for (0..array.items.items.len) |index| {
                        result.object().?.array_presence.items[index] = array.isPresent(index);
                    }
                }
            }
            var pair_slots = [_]Value{ .{}, .{} };
            var pair_roots = RootFrame{};
            owner.pushRoots(&pair_roots, &pair_slots, pair_slots.len);
            defer owner.popRoots(&pair_roots);
            for (array.properties.items) |property| {
                pair_slots[0] = try owner.createString(property.key.units);
                pair_slots[1] = try dynamicToAotValueCached(cache, property.value, depth + 1);
                try owner.setDictionary(&result.object().?.array_properties, pair_slots[0], pair_slots[1]);
            }
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            if (low_level_state.lookupHandle(&state.interpreter.lowlevel_state, value)) |id| {
                if (low_level.handleValueForId(owner, id)) |existing| break :blk existing;
                var result = try owner.createDictionary(&.{});
                var result_roots = RootFrame{};
                owner.pushRoots(&result_roots, @ptrCast(&result), 1);
                defer owner.popRoots(&result_roots);
                try low_level.rememberHandle(owner, result, id);
                break :blk result;
            }
            if (dictionary.kind == .toml_temporal) {
                const temporal = dictionary.toml_temporal orelse return error.DynamicValueUnsupported;
                break :blk owner.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            const ptr = @intFromPtr(dictionary);
            if (cache.seen.get(ptr)) |existing| break :blk existing;
            if (depth > max_conversion_depth) return error.ValueNestingTooDeep;

            var result = try owner.createDictionary(&.{});
            var result_roots = RootFrame{};
            owner.pushRoots(&result_roots, @ptrCast(&result), 1);
            defer owner.popRoots(&result_roots);
            try cache.hold(result);
            try cache.seen.put(owner.allocator, ptr, result);
            errdefer _ = cache.seen.remove(ptr);

            var pair_slots = [_]Value{ .{}, .{} };
            var pair_roots = RootFrame{};
            owner.pushRoots(&pair_roots, &pair_slots, pair_slots.len);
            defer owner.popRoots(&pair_roots);
            for (dictionary.keys(), dictionary.values()) |key, item| {
                pair_slots[0] = try owner.createString(key.units);
                pair_slots[1] = try dynamicToAotValueCached(cache, item, depth + 1);
                try owner.setDictionary(&result.object().?.payload.dictionary, pair_slots[0], pair_slots[1]);
            }
            if (dictionary.kind == .structured_error) result.object().?.structured_error = true;
            break :blk result;
        },
        .function => |function| if (function.kind == .external) blk: {
            const binding = function.kind.external.binding;
            if (binding.releaseFn == releaseAotFunctionBridge and binding.context == @as(*anyopaque, @ptrCast(owner))) {
                const bridge: *AotFunctionBridge = @ptrCast(@alignCast(binding.handle));
                break :blk bridge.value;
            }
            return error.DynamicValueUnsupported;
        } else return error.DynamicValueUnsupported,
        .promise => |promise| dynamicPromiseToAotValue(state, promise),
    };
}

pub fn prepareDynamic(context: *anyopaque, interpreter: *dynamic_interpreter.Interpreter) anyerror!void {
    const state: *DynamicInterpreterState = @ptrCast(@alignCast(context));
    const owner = state.owner;
    var cache = AotToDynamicCache.init(state);
    defer cache.deinit();
    try cache.enter();
    for (owner.named_functions.items) |registered| {
        const fn_value = Value{ .tag = @backingInt(Tag.function), .payload = @intFromPtr(registered.object) };
        var value = aotToDynamicValueWithCache(&cache, fn_value) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&value);
        try interpreter.setGlobalValue(registered.name, value);
    }
    for (owner.dynamic_globals.items) |entry| {
        // slotを持つ静的グローバルはslotだけを読み、entry.valueへは複製
        // しない（GCが古い値を保持し続けるのを防ぐ）。
        const raw = if (entry.slot) |slot| slot.* else entry.value;
        // 未代入のグローバルは動的側へ渡さない（globalThisのシャドウ防止）。
        if (raw.isUnbound()) continue;
        var value = aotToDynamicValueWithCache(&cache, raw) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&value);
        try interpreter.setGlobalValue(entry.name, value);
    }
    if (state.reset_display_log) {
        var empty = try state.value_runtime.stringUtf8("");
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&empty);
        try interpreter.setGlobalValue("表示ログ", empty);
    }
}

pub fn syncDynamicGlobals(state: *DynamicInterpreterState) anyerror!void {
    var cache = DynamicToAotCache.init(state);
    defer cache.deinit();
    cache.enter();
    var iterator = state.interpreter.globals.iterator();
    while (iterator.next()) |entry| {
        const value = dynamicToAotValueCached(&cache, entry.value_ptr.*, 0) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        try upsertDynamicGlobal(state.owner, entry.key_ptr.*, value);
    }
}

// AOT 値の完全構造fingerprint。visited テーブルで各ヒープオブジェクトを
// 高々1回だけ走査し、配列長・入れ子深さ・文字列長の上限なしに循環グラフも
// 含めて全要素・全プロパティの差分を検出する。
fn fingerprintAotValue(allocator: std.mem.Allocator, value: Value) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    var visited: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    defer visited.deinit(allocator);
    var next_id: u32 = 0;
    try fingerprintAotValueInto(allocator, &hasher, &visited, &next_id, value);
    return hasher.final();
}

fn fingerprintAotValueAssumeCapacity(visited: *std.AutoHashMapUnmanaged(usize, u32), value: Value) u64 {
    visited.clearRetainingCapacity();
    var hasher = std.hash.Wyhash.init(0);
    var next_id: u32 = 0;
    fingerprintAotValueInto(null, &hasher, visited, &next_id, value) catch unreachable;
    return hasher.final();
}

fn fingerprintAotValueInto(
    allocator: ?std.mem.Allocator,
    hasher: *std.hash.Wyhash,
    visited: *std.AutoHashMapUnmanaged(usize, u32),
    next_id: *u32,
    value: Value,
) !void {
    hasher.update(std.mem.asBytes(&value.tag));
    switch (@as(Tag, @fromBackingInt(@intCast(value.tag)))) {
        .undefined, .null_value, .boolean, .number => {
            hasher.update(std.mem.asBytes(&value.payload));
        },
        .static_utf8_string => {
            const bytes = staticUtf8(value);
            hasher.update(std.mem.asBytes(&bytes.len));
            hasher.update(bytes);
        },
        .utf16_string,
        .array,
        .dictionary,
        .byte_buffer,
        .iterator,
        .bigint,
        .function,
        .binding_cell,
        .promise,
        => |tag| {
            const object = value.object() orelse {
                const null_marker: u8 = 0;
                hasher.update(&.{null_marker});
                return;
            };
            const ptr = @intFromPtr(object);
            if (visited.get(ptr)) |backref_id| {
                const backref_marker: u8 = 1;
                hasher.update(&.{backref_marker});
                hasher.update(std.mem.asBytes(&backref_id));
                return;
            }
            const node_id = next_id.*;
            next_id.* += 1;
            if (allocator) |alloc| {
                try visited.put(alloc, ptr, node_id);
            } else {
                visited.putAssumeCapacity(ptr, node_id);
            }
            const node_marker: u8 = 2;
            hasher.update(&.{node_marker});
            hasher.update(std.mem.asBytes(&node_id));

            switch (tag) {
                .utf16_string => fingerprintUnits(hasher, object.payload.utf16_string),
                .array => {
                    try fingerprintAotValueInto(allocator, hasher, visited, next_id, object.prototype);
                    const items = object.payload.array.items;
                    hasher.update(std.mem.asBytes(&items.len));
                    for (items, 0..) |item, index| {
                        const present = if (index < object.array_presence.items.len) object.array_presence.items[index] else true;
                        hasher.update(std.mem.asBytes(&present));
                        try fingerprintAotValueInto(allocator, hasher, visited, next_id, item);
                    }
                    const prop_entries = object.array_properties.entries.items;
                    hasher.update(std.mem.asBytes(&prop_entries.len));
                    for (prop_entries) |entry| {
                        try fingerprintAotValueInto(allocator, hasher, visited, next_id, entry.key);
                        try fingerprintAotValueInto(allocator, hasher, visited, next_id, entry.value);
                    }
                },
                .dictionary => {
                    const is_structured: u8 = @intFromBool(object.structured_error);
                    hasher.update(&.{is_structured});
                    const has_temporal: u8 = @intFromBool(object.toml_temporal != null);
                    hasher.update(&.{has_temporal});
                    if (object.toml_temporal) |temporal| {
                        hasher.update(temporal.json_text);
                        hasher.update(temporal.toml_text);
                    }
                    const entries = object.payload.dictionary.entries.items;
                    hasher.update(std.mem.asBytes(&entries.len));
                    for (entries) |entry| {
                        try fingerprintAotValueInto(allocator, hasher, visited, next_id, entry.key);
                        try fingerprintAotValueInto(allocator, hasher, visited, next_id, entry.value);
                    }
                },
                .byte_buffer => {
                    const bytes = object.payload.byte_buffer.bytes;
                    const kind_byte: u8 = @backingInt(object.payload.byte_buffer.kind);
                    hasher.update(&.{kind_byte});
                    hasher.update(std.mem.asBytes(&bytes.len));
                    hasher.update(bytes);
                },
                .iterator, .bigint, .function, .binding_cell, .promise => {
                    hasher.update(std.mem.asBytes(&value.payload));
                },
                else => unreachable,
            }
        },
    }
}

fn fingerprintUnits(hasher: *std.hash.Wyhash, units: []const u16) void {
    hasher.update(std.mem.asBytes(&units.len));
    hasher.update(std.mem.sliceAsBytes(units));
}

fn rememberSyncedHash(state: *DynamicInterpreterState, name: []const u8, fingerprint: u64) !void {
    if (state.synced_aot_hashes.getPtr(name)) |slot| {
        slot.* = fingerprint;
        return;
    }
    const owned_name = try state.allocator.dupe(u8, name);
    errdefer state.allocator.free(owned_name);
    try state.synced_aot_hashes.put(state.allocator, owned_name, fingerprint);
}

/// `dynamicToAotValue` が `error.DynamicValueUnsupported` を返す値か。
/// 循環参照を含めて各コンテナを高々1回走査し、plugin の `初期化` や
/// `sys.__setSysVar` が残した JS 関数等を判定する。
fn dynamicValueAotUnsupported(allocator: std.mem.Allocator, owner: *Runtime, value: dynamic_value.Value) !bool {
    var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer visited.deinit(allocator);
    return dynamicValueAotUnsupportedInto(allocator, owner, &visited, value);
}

fn dynamicValueAotUnsupportedInto(
    allocator: std.mem.Allocator,
    owner: *Runtime,
    visited: *std.AutoHashMapUnmanaged(usize, void),
    value: dynamic_value.Value,
) !bool {
    return switch (value) {
        .promise => true,
        .function => |function| if (function.kind == .external) blk: {
            const binding = function.kind.external.binding;
            break :blk !(binding.releaseFn == releaseAotFunctionBridge and binding.context == @as(*anyopaque, @ptrCast(owner)));
        } else true,
        .array => |array| blk: {
            const ptr = @intFromPtr(array);
            if (visited.contains(ptr)) break :blk false;
            try visited.put(allocator, ptr, {});
            if (try dynamicValueAotUnsupportedInto(allocator, owner, visited, array.prototype)) break :blk true;
            for (array.items.items) |item| {
                if (try dynamicValueAotUnsupportedInto(allocator, owner, visited, item)) break :blk true;
            }
            for (array.properties.items) |property| {
                if (try dynamicValueAotUnsupportedInto(allocator, owner, visited, property.value)) break :blk true;
            }
            break :blk false;
        },
        .dictionary => |dictionary| blk: {
            const ptr = @intFromPtr(dictionary);
            if (visited.contains(ptr)) break :blk false;
            try visited.put(allocator, ptr, {});
            var iterator = dictionary.map.iterator();
            while (iterator.next()) |entry| {
                if (try dynamicValueAotUnsupportedInto(allocator, owner, visited, entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// interpreter 初期化中の plugin `初期化` が残したAOT変換不能値について、
/// 現在のAOT fingerprintを記録する。AOT側が後で変化すれば fingerprint が
/// 変わり、次の `syncAotGlobalsForPlugin` が通常どおり上書きする。
fn seedPluginInitializedHashes(state: *DynamicInterpreterState) !void {
    for (state.owner.dynamic_globals.items) |entry| {
        const raw = if (entry.slot) |slot| slot.* else entry.value;
        if (raw.isUnbound()) continue;
        const current = state.interpreter.getGlobal(entry.name) orelse continue;
        if (!try dynamicValueAotUnsupported(state.allocator, state.owner, current)) continue;
        if (state.synced_aot_hashes.get(entry.name) != null) continue;
        try rememberSyncedHash(state, entry.name, try fingerprintAotValue(state.allocator, raw));
    }
}

/// ESM plugin 呼出し前に AOT の named functions / dynamic globals を interpreter
/// へ同期する。引数変換と同じ `AotToDynamicCache` を共有して、引数・複数グローバル・
/// エイリアス間でオブジェクト同一性を保つ。plugin が上書きした AOT 変換不能値は、
/// AOT 側 fingerprint が前回同期時と同一なら保持する。
fn syncAotGlobalsForPlugin(cache: *AotToDynamicCache) anyerror!void {
    const state = cache.state;
    const owner = state.owner;
    for (owner.named_functions.items) |registered| {
        // plugin が同名を上書きしている場合は触らない。
        if (state.interpreter.getGlobal(registered.name) != null) continue;
        const fn_value = Value{ .tag = @backingInt(Tag.function), .payload = @intFromPtr(registered.object) };
        var value = aotToDynamicValueWithCache(cache, fn_value) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&value);
        try state.interpreter.setGlobalValue(registered.name, value);
    }
    for (owner.dynamic_globals.items) |entry| {
        const raw = if (entry.slot) |slot| slot.* else entry.value;
        if (raw.isUnbound()) continue;
        const fingerprint = try fingerprintAotValue(state.allocator, raw);
        if (state.interpreter.getGlobal(entry.name)) |existing_dyn| {
            if (try dynamicValueAotUnsupported(state.allocator, owner, existing_dyn)) {
                if (state.synced_aot_hashes.get(entry.name)) |previous| {
                    // plugin 固有の変換不能値であり AOT 側も変化していないなら保持する。
                    if (previous == fingerprint) continue;
                }
            }
        }
        var value = aotToDynamicValueWithCache(cache, raw) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        var roots = state.value_runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&value);
        try state.interpreter.setGlobalValue(entry.name, value);
        try rememberSyncedHash(state, entry.name, fingerprint);
    }
}

fn sameDynamicBinding(left: dynamic_value.Value, right: dynamic_value.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .undefined, .null_value => true,
        .boolean => |value| value == right.boolean,
        .number => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number)),
        .bigint => |value| value == right.bigint,
        .string => |value| value == right.string,
        .bytes => |value| value == right.bytes,
        .array => |value| value == right.array,
        .dictionary => |value| value == right.dictionary,
        .function => |value| value == right.function,
        .promise => |value| value == right.promise,
    };
}

const BeforeGlobalsSnapshot = struct {
    state: *DynamicInterpreterState,
    bindings: std.StringHashMapUnmanaged(dynamic_value.Value) = .empty,
    holder: dynamic_value.Value = .undefined,
    roots: dynamic_value.RootFrame,
    holder_protected: bool = false,

    fn init(state: *DynamicInterpreterState) BeforeGlobalsSnapshot {
        return .{
            .state = state,
            .roots = state.value_runtime.rootFrame(),
        };
    }

    fn capture(self: *BeforeGlobalsSnapshot) !void {
        if (self.state.interpreter.globals.count() > 0) {
            self.holder = try self.state.value_runtime.createArray();
            try self.roots.protect(&self.holder);
            self.holder_protected = true;
            var iterator = self.state.interpreter.globals.iterator();
            while (iterator.next()) |entry| {
                // interpreter が再代入して古い値を解放しても ABA ポインタ再利用が
                // 起きないよう、call 中は snapshot 側でも GC ルートに繋ぐ。
                _ = try self.holder.array.push(entry.value_ptr.*);
                try self.bindings.put(self.state.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    fn deinit(self: *BeforeGlobalsSnapshot) void {
        self.roots.deinit();
        self.bindings.deinit(self.state.allocator);
    }
};

fn sameShallowDynamicValue(left: dynamic_value.Value, right: dynamic_value.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .undefined, .null_value => true,
        .boolean => |value| value == right.boolean,
        .number => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number)),
        .bigint => |value| dynamic_value.BigInt.eql(value.*, right.bigint.*),
        .string => |value| dynamic_value.String.eql(value.*, right.string.*),
        .bytes => |value| value.kind == right.bytes.kind and std.mem.eql(u8, value.bytes, right.bytes.bytes),
        .array => |value| value == right.array,
        .dictionary => |value| value == right.dictionary,
        .function => |value| value == right.function,
        .promise => |value| value == right.promise,
    };
}

const ArraySnapshot = struct {
    prototype: dynamic_value.Value,
    items: []dynamic_value.Value,
    presence: []bool,
    properties: []dynamic_value.ArrayProperty,

    fn deinit(self: *ArraySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.free(self.presence);
        allocator.free(self.properties);
    }
};

const DictSnapshot = struct {
    keys: []*dynamic_value.String,
    values: []dynamic_value.Value,

    fn deinit(self: *DictSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.values);
    }
};

const ContainerSnapshot = union(enum) {
    array: ArraySnapshot,
    dictionary: DictSnapshot,

    fn deinit(self: *ContainerSnapshot, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |*arr| arr.deinit(allocator),
            .dictionary => |*dict| dict.deinit(allocator),
        }
    }
};

/// 呼出し前の動的コンテナ（配列・辞書）の浅い内容をスナップショットし、
/// 呼出し中も値が GC で解放・再利用されないようルート保護する。
/// 動的側が未変更のままなら、AOT callback が加えた変更を書き戻しで上書きしない。
const BeforeContainersSnapshot = struct {
    state: *DynamicInterpreterState,
    entries: std.AutoHashMapUnmanaged(usize, ContainerSnapshot) = .empty,
    holder: dynamic_value.Value = .undefined,
    roots: dynamic_value.RootFrame,

    fn init(state: *DynamicInterpreterState) BeforeContainersSnapshot {
        return .{
            .state = state,
            .roots = state.value_runtime.rootFrame(),
        };
    }

    fn capture(self: *BeforeContainersSnapshot, aot_to_dyn: *const AotToDynamicCache) !void {
        if (aot_to_dyn.containers.items.len == 0) return;
        const allocator = self.state.allocator;
        self.holder = try self.state.value_runtime.createArray();
        try self.roots.protect(&self.holder);
        for (aot_to_dyn.containers.items) |pair| {
            switch (pair.dynamic) {
                .array => |arr| {
                    const ptr = @intFromPtr(arr);
                    if (self.entries.contains(ptr)) continue;
                    _ = try self.holder.array.push(pair.dynamic);
                    _ = try self.holder.array.push(arr.prototype);
                    const items = try allocator.dupe(dynamic_value.Value, arr.items.items);
                    errdefer allocator.free(items);
                    const presence = try allocator.alloc(bool, arr.items.items.len);
                    errdefer allocator.free(presence);
                    for (0..arr.items.items.len) |index| {
                        presence[index] = arr.isPresent(index);
                        _ = try self.holder.array.push(items[index]);
                    }
                    const properties = try allocator.dupe(dynamic_value.ArrayProperty, arr.properties.items);
                    errdefer allocator.free(properties);
                    for (properties) |prop| {
                        _ = try self.holder.array.push(.{ .string = prop.key });
                        _ = try self.holder.array.push(prop.value);
                    }
                    try self.entries.put(allocator, ptr, .{ .array = .{
                        .prototype = arr.prototype,
                        .items = items,
                        .presence = presence,
                        .properties = properties,
                    } });
                },
                .dictionary => |dict| {
                    const ptr = @intFromPtr(dict);
                    if (self.entries.contains(ptr)) continue;
                    _ = try self.holder.array.push(pair.dynamic);
                    const keys = try allocator.dupe(*dynamic_value.String, dict.keys());
                    errdefer allocator.free(keys);
                    const values = try allocator.dupe(dynamic_value.Value, dict.values());
                    errdefer allocator.free(values);
                    for (keys, values) |key, val| {
                        _ = try self.holder.array.push(.{ .string = key });
                        _ = try self.holder.array.push(val);
                    }
                    try self.entries.put(allocator, ptr, .{ .dictionary = .{
                        .keys = keys,
                        .values = values,
                    } });
                },
                else => {},
            }
        }
    }

    fn unchanged(self: *const BeforeContainersSnapshot, value: dynamic_value.Value) bool {
        return switch (value) {
            .array => |arr| {
                const entry = self.entries.get(@intFromPtr(arr)) orelse return false;
                const snap = switch (entry) {
                    .array => |s| s,
                    else => return false,
                };
                if (!sameShallowDynamicValue(snap.prototype, arr.prototype)) return false;
                if (snap.items.len != arr.items.items.len) return false;
                for (0..snap.items.len) |index| {
                    if (snap.presence[index] != arr.isPresent(index)) return false;
                    if (snap.presence[index] and !sameShallowDynamicValue(snap.items[index], arr.items.items[index])) return false;
                }
                if (snap.properties.len != arr.properties.items.len) return false;
                for (snap.properties) |prop| {
                    const current = arr.getProperty(prop.key) orelse return false;
                    if (!sameShallowDynamicValue(prop.value, current)) return false;
                }
                return true;
            },
            .dictionary => |dict| {
                const entry = self.entries.get(@intFromPtr(dict)) orelse return false;
                const snap = switch (entry) {
                    .dictionary => |s| s,
                    else => return false,
                };
                if (snap.keys.len != dict.len()) return false;
                for (snap.keys, snap.values) |key, val| {
                    const current = dict.get(key) orelse return false;
                    if (!sameShallowDynamicValue(val, current)) return false;
                }
                return true;
            },
            else => false,
        };
    }

    fn deinit(self: *BeforeContainersSnapshot) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |snap| snap.deinit(self.state.allocator);
        self.entries.deinit(self.state.allocator);
        self.roots.deinit();
    }
};

fn containsStringSlice(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

const StagedArrayMutation = struct {
    target: *aot_state.Object,
    prototype: Value,
    items: std.ArrayList(Value) = .empty,
    presence: std.ArrayList(bool) = .empty,
    properties: aot_state.AotDictionary = .{},

    fn deinit(self: *StagedArrayMutation, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.presence.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

const StagedDictMutation = struct {
    target: *aot_state.Object,
    entries: aot_state.AotDictionary = .{},

    fn deinit(self: *StagedDictMutation, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};

const StagedGlobalUpdate = struct {
    name: []const u8,
    value: Value,
    owned_new_name: ?[]u8 = null,
};

fn stageArrayMutation(cache: *DynamicToAotCache, target: Value, source: *dynamic_value.Array) !StagedArrayMutation {
    const owner = cache.state.owner;
    const object = target.object() orelse return error.DynamicValueUnsupported;
    var staged = StagedArrayMutation{
        .target = object,
        .prototype = try dynamicToAotValueCached(cache, source.prototype, 0),
    };
    errdefer staged.deinit(owner.allocator);
    try cache.hold(staged.prototype);

    try staged.items.ensureTotalCapacity(owner.allocator, source.items.items.len);
    for (source.items.items) |item| {
        const converted = try dynamicToAotValueCached(cache, item, 0);
        try cache.hold(converted);
        staged.items.appendAssumeCapacity(converted);
    }

    if (source.presence.items.len > 0) {
        const check_len = @min(source.presence.items.len, source.items.items.len);
        if (std.mem.indexOfScalar(bool, source.presence.items[0..check_len], false) != null) {
            try staged.presence.resize(owner.allocator, source.items.items.len);
            for (0..source.items.items.len) |index| {
                staged.presence.items[index] = source.isPresent(index);
            }
        }
    }

    var pair_slots = [_]Value{ .{}, .{} };
    var pair_roots = RootFrame{};
    owner.pushRoots(&pair_roots, &pair_slots, pair_slots.len);
    defer owner.popRoots(&pair_roots);
    for (source.properties.items) |property| {
        pair_slots[0] = try owner.createString(property.key.units);
        try cache.hold(pair_slots[0]);
        pair_slots[1] = try dynamicToAotValueCached(cache, property.value, 0);
        try cache.hold(pair_slots[1]);
        try staged.properties.set(owner.allocator, pair_slots[0], pair_slots[1]);
    }
    return staged;
}

fn stageDictMutation(cache: *DynamicToAotCache, target: Value, source: *dynamic_value.Dictionary) !StagedDictMutation {
    const owner = cache.state.owner;
    const object = target.object() orelse return error.DynamicValueUnsupported;
    var staged = StagedDictMutation{ .target = object };
    errdefer staged.deinit(owner.allocator);

    var pair_slots = [_]Value{ .{}, .{} };
    var pair_roots = RootFrame{};
    owner.pushRoots(&pair_roots, &pair_slots, pair_slots.len);
    defer owner.popRoots(&pair_roots);
    for (source.keys(), source.values()) |key, item| {
        pair_slots[0] = try owner.createString(key.units);
        try cache.hold(pair_slots[0]);
        pair_slots[1] = try dynamicToAotValueCached(cache, item, 0);
        try cache.hold(pair_slots[1]);
        try staged.entries.set(owner.allocator, pair_slots[0], pair_slots[1]);
    }
    return staged;
}

fn commitArrayMutation(owner: *Runtime, staged: *StagedArrayMutation) void {
    const target = staged.target;
    target.prototype = staged.prototype;
    target.payload.array.deinit(owner.allocator);
    target.payload.array = staged.items;
    staged.items = .empty;
    target.array_presence.deinit(owner.allocator);
    target.array_presence = staged.presence;
    staged.presence = .empty;
    target.array_properties.deinit(owner.allocator);
    target.array_properties = staged.properties;
    staged.properties = .{};
}

fn commitDictMutation(owner: *Runtime, staged: *StagedDictMutation) void {
    const target = staged.target;
    target.payload.dictionary.deinit(owner.allocator);
    target.payload.dictionary = staged.entries;
    staged.entries = .{};
}

fn finalizePluginCall(
    state: *DynamicInterpreterState,
    aot_to_dyn: *const AotToDynamicCache,
    before_globals: *const BeforeGlobalsSnapshot,
    before_containers: *const BeforeContainersSnapshot,
    dyn_cache: *DynamicToAotCache,
) anyerror!void {
    const owner = state.owner;

    // 変換済みコンテナを先に逆写像へ登録し、自己参照サイクルやエイリアス、
    // 戻り値でも元の AOT オブジェクト同一性を保つ。
    for (aot_to_dyn.containers.items) |pair| {
        try dyn_cache.hold(pair.aot);
        const dyn_ptr = switch (pair.dynamic) {
            .array => |array| @intFromPtr(array),
            .dictionary => |dictionary| @intFromPtr(dictionary),
            else => continue,
        };
        try dyn_cache.seen.put(owner.allocator, dyn_ptr, pair.aot);
    }

    var staged_arrays: std.ArrayList(StagedArrayMutation) = .empty;
    defer {
        for (staged_arrays.items) |*item| item.deinit(owner.allocator);
        staged_arrays.deinit(owner.allocator);
    }
    var staged_dicts: std.ArrayList(StagedDictMutation) = .empty;
    defer {
        for (staged_dicts.items) |*item| item.deinit(owner.allocator);
        staged_dicts.deinit(owner.allocator);
    }
    var committed_objects: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer committed_objects.deinit(state.allocator);

    for (aot_to_dyn.containers.items) |pair| {
        if (before_containers.unchanged(pair.dynamic)) continue;
        switch (pair.dynamic) {
            .array => |array| if (@as(Tag, @fromBackingInt(@intCast(pair.aot.tag))) == .array) {
                try staged_arrays.ensureUnusedCapacity(owner.allocator, 1);
                const staged = try stageArrayMutation(dyn_cache, pair.aot, array);
                staged_arrays.appendAssumeCapacity(staged);
                try committed_objects.put(state.allocator, @intFromPtr(staged.target), {});
            },
            .dictionary => |dictionary| if (@as(Tag, @fromBackingInt(@intCast(pair.aot.tag))) == .dictionary) {
                try staged_dicts.ensureUnusedCapacity(owner.allocator, 1);
                const staged = try stageDictMutation(dyn_cache, pair.aot, dictionary);
                staged_dicts.appendAssumeCapacity(staged);
                try committed_objects.put(state.allocator, @intFromPtr(staged.target), {});
            },
            else => {},
        }
    }

    var staged_globals: std.ArrayList(StagedGlobalUpdate) = .empty;
    defer {
        for (staged_globals.items) |item| {
            if (item.owned_new_name) |owned| owner.allocator.free(owned);
        }
        staged_globals.deinit(owner.allocator);
    }
    var unsupported_global_names: std.ArrayList([]const u8) = .empty;
    defer unsupported_global_names.deinit(state.allocator);

    var iterator = state.interpreter.globals.iterator();
    var new_global_count: usize = 0;
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const current_dyn = entry.value_ptr.*;
        const existing_aot = dynamicGlobal(owner, name);
        const aot_bound = if (existing_aot) |existing|
            !(if (existing.slot) |slot| slot.* else existing.value).isUnbound()
        else
            false;
        if (aot_bound) {
            if (before_globals.bindings.get(name)) |previous_dyn| {
                // プラグインが再束縛していないグローバル（コンテナのインプレース変更は
                // staged_arrays / staged_dicts が反映済み）は上書きしない。
                // 未作成または未束縛の静的slotには `初期化` が書いた初期値を反映する。
                if (sameDynamicBinding(previous_dyn, current_dyn)) continue;
            }
        }
        const value = dynamicToAotValueCached(dyn_cache, current_dyn, 0) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => {
                try unsupported_global_names.append(state.allocator, name);
                continue;
            },
            else => return failure,
        };
        try dyn_cache.hold(value);
        try staged_globals.ensureUnusedCapacity(owner.allocator, 1);
        var owned_new_name: ?[]u8 = null;
        if (existing_aot == null) {
            owned_new_name = try owner.allocator.dupe(u8, name);
            new_global_count += 1;
        }
        staged_globals.appendAssumeCapacity(.{
            .name = name,
            .value = value,
            .owned_new_name = owned_new_name,
        });
    }
    try owner.dynamic_globals.ensureUnusedCapacity(owner.allocator, new_global_count);

    var staged_hash_names: std.ArrayList(?[]u8) = .empty;
    defer {
        for (staged_hash_names.items) |maybe_name| {
            if (maybe_name) |owned| state.allocator.free(owned);
        }
        staged_hash_names.deinit(state.allocator);
    }
    for (staged_globals.items) |staged| {
        if (!state.synced_aot_hashes.contains(staged.name)) {
            try staged_hash_names.ensureUnusedCapacity(state.allocator, 1);
            staged_hash_names.appendAssumeCapacity(try state.allocator.dupe(u8, staged.name));
        }
    }
    try state.synced_aot_hashes.ensureUnusedCapacity(state.allocator, @intCast(staged_hash_names.items.len));
    var fingerprint_visited: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    defer fingerprint_visited.deinit(state.allocator);
    try fingerprint_visited.ensureTotalCapacity(state.allocator, @intCast(@min(std.math.maxInt(u32), owner.object_count)));

    // ここからは非失敗（commit）。全変換と事前確保が成功した後にだけ元コンテナ・
    // グローバル・実際に同期した fingerprint を更新する。
    for (staged_arrays.items) |*staged| commitArrayMutation(owner, staged);
    for (staged_dicts.items) |*staged| commitDictMutation(owner, staged);
    for (staged_globals.items) |*staged| {
        if (dynamicGlobal(owner, staged.name)) |existing| {
            if (existing.slot) |slot| slot.* = staged.value else existing.value = staged.value;
        } else {
            const owned_name = staged.owned_new_name.?;
            staged.owned_new_name = null;
            owner.dynamic_globals.appendAssumeCapacity(.{ .name = owned_name, .value = staged.value });
        }
    }
    for (staged_hash_names.items) |*maybe_name| {
        const owned = maybe_name.*.?;
        maybe_name.* = null;
        state.synced_aot_hashes.putAssumeCapacity(owned, 0);
    }

    for (staged_globals.items) |staged| {
        if (dynamicGlobal(owner, staged.name)) |synced| {
            const raw = if (synced.slot) |slot| slot.* else synced.value;
            if (!raw.isUnbound()) {
                if (state.synced_aot_hashes.getPtr(staged.name)) |slot| {
                    slot.* = fingerprintAotValueAssumeCapacity(&fingerprint_visited, raw);
                }
            }
        }
    }
    // 変換不能値として保持したグローバルや callback 変更で未同期の値は前回の
    // fingerprint を維持し、コンテナ変更が実際に書き戻されたグローバルだけ更新する。
    for (owner.dynamic_globals.items) |entry| {
        if (containsStringSlice(unsupported_global_names.items, entry.name)) continue;
        if (state.synced_aot_hashes.getPtr(entry.name)) |slot| {
            const raw = if (entry.slot) |slot_ptr| slot_ptr.* else entry.value;
            if (!raw.isUnbound()) {
                if (raw.object()) |obj| {
                    if (committed_objects.contains(@intFromPtr(obj))) {
                        slot.* = fingerprintAotValueAssumeCapacity(&fingerprint_visited, raw);
                    }
                }
            }
        }
    }
}

fn deinitDynamicState(runtime: *Runtime) void {
    const state = runtime.dynamic_state orelse return;
    state.deinit();
    runtime.allocator.destroy(state);
    runtime.dynamic_state = null;
    runtime.dynamic_deinit = null;
    runtime.dynamic_drain = null;
    runtime.dynamic_forget_handle = null;
}

fn forgetDynamicHandle(runtime: *Runtime, raw: u64) void {
    const state = runtime.dynamic_state orelse return;
    low_level_state.forgetHandleId(&state.interpreter.lowlevel_state, foundation.HandleId.fromRaw(raw));
}

// runtime.dynamic_drain 経由でのみ呼ばれる。drain_events など常時到達する
// コードからの直接参照を切り、動的実行を使わない生成物から埋め込み
// interpreter と plugin 群をdead-stripできるようにする。
fn drainNativePluginTasks(runtime: *Runtime) anyerror!bool {
    const state = runtime.dynamic_state orelse return false;
    const native_pending = try state.interpreter.pollExternalPlugins();
    var pending_bridge = false;
    var index: usize = 0;
    while (index < runtime.dynamic_promise_bridges.items.len) {
        const bridge = runtime.dynamic_promise_bridges.items[index];
        if (bridge.state != state or bridge.promise.state == .pending) {
            pending_bridge = pending_bridge or bridge.state == state;
            index += 1;
            continue;
        }

        var rooted = [_]Value{ bridge.aot_promise, .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &rooted, rooted.len);
        defer runtime.popRoots(&frame);
        rooted[1] = try dynamicToAotValue(state, bridge.promise.result);
        if (bridge.promise.state == .fulfilled) {
            try aot_state.resolveAotPromise(runtime, rooted[0].object().?, rooted[1]);
        } else {
            try aot_state.rejectAotPromise(runtime, rooted[0].object().?, rooted[1]);
        }
        _ = runtime.dynamic_promise_bridges.orderedRemove(index);
        runtime.allocator.destroy(bridge);
    }
    return native_pending or pending_bridge;
}

pub fn dynamicInterpreterState(runtime: *Runtime) !*DynamicInterpreterState {
    return if (runtime.dynamic_state) |existing| existing else blk: {
        const created = try DynamicInterpreterState.init(runtime.allocator, runtime);
        runtime.dynamic_state = created;
        break :blk created;
    };
}

pub fn nativePluginBuiltin(runtime: *Runtime, name: []const u8, arguments: []const Value) !Value {
    const state = try dynamicInterpreterState(runtime);
    const dynamic_arguments = try runtime.allocator.alloc(dynamic_value.Value, arguments.len);
    defer runtime.allocator.free(dynamic_arguments);
    @memset(dynamic_arguments, .undefined);
    var roots = state.value_runtime.rootFrame();
    defer roots.deinit();
    var aot_to_dyn = AotToDynamicCache.init(state);
    defer aot_to_dyn.deinit();
    try aot_to_dyn.enter();
    for (arguments, dynamic_arguments) |argument, *converted| {
        converted.* = try aotToDynamicValueWithCache(&aot_to_dyn, argument);
        try roots.protect(converted);
    }
    var result = try state.interpreter.callExternalCommand(name, dynamic_arguments);
    try roots.protect(&result);
    // plugin が配列・辞書の引数を書き換えた場合、その変更は複製側にしか
    // 無い。呼出し後に AOT 側の実引数へ書き戻す（interpreter と同じ観測）。
    for (arguments, dynamic_arguments) |argument, converted| {
        switch (converted) {
            .array, .dictionary => writeBackMutation(state, argument, converted) catch {},
            else => {},
        }
    }
    return dynamicToAotValue(state, result);
}

/// `dynamic` 側の配列/辞書の中身を AOT 側の値へ書き戻す。変換をすべて
/// 完了してから元コンテナへ入れ替え、途中失敗で元配列/辞書を破壊しない。
fn writeBackMutation(state: *DynamicInterpreterState, target: Value, source: dynamic_value.Value) !void {
    const owner = state.owner;
    var dyn_cache = DynamicToAotCache.init(state);
    defer dyn_cache.deinit();
    dyn_cache.enter();
    try dyn_cache.hold(target);
    switch (source) {
        .array => |array| {
            if (@as(Tag, @fromBackingInt(@intCast(target.tag))) != .array) return;
            try dyn_cache.seen.put(owner.allocator, @intFromPtr(array), target);
            var staged = try stageArrayMutation(&dyn_cache, target, array);
            defer staged.deinit(owner.allocator);
            commitArrayMutation(owner, &staged);
        },
        .dictionary => |dictionary| {
            if (@as(Tag, @fromBackingInt(@intCast(target.tag))) != .dictionary) return;
            try dyn_cache.seen.put(owner.allocator, @intFromPtr(dictionary), target);
            var staged = try stageDictMutation(&dyn_cache, target, dictionary);
            defer staged.deinit(owner.allocator);
            commitDictMutation(owner, &staged);
        },
        else => {},
    }
}

pub fn dynamicBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len == 0) return .{};
    const state = try dynamicInterpreterState(runtime);
    const source = try valueUtf8LossyAlloc(runtime, arguments[arguments.len - 1]);
    defer runtime.allocator.free(source);
    state.reset_display_log = true;
    defer state.reset_display_log = false;

    var previous_log: Value = .{};
    if (dynamicGlobal(runtime, "表示ログ")) |entry| {
        // 正本はslot（あれば）。entry.valueは書き換えない。
        previous_log = if (entry.slot) |slot| slot.* else entry.value;
    }
    var previous_roots = RootFrame{};
    runtime.pushRoots(&previous_roots, @ptrCast(&previous_log), 1);
    defer runtime.popRoots(&previous_roots);
    _ = try state.interpreter.runDynamicSource(source, prepareDynamic, state);
    const nested_log = state.interpreter.getGlobal("表示ログ") orelse dynamic_value.Value.undefined;
    try syncDynamicGlobals(state);

    var returned = try dynamicToAotValue(state, nested_log);
    var returned_roots = RootFrame{};
    runtime.pushRoots(&returned_roots, @ptrCast(&returned), 1);
    defer runtime.popRoots(&returned_roots);
    const combined = concatAotValues(runtime, previous_log, returned) catch |failure| {
        if (failure == error.DynamicValueUnsupported) return returned;
        return failure;
    };
    var rooted_combined = combined;
    var combined_roots = RootFrame{};
    runtime.pushRoots(&combined_roots, @ptrCast(&rooted_combined), 1);
    defer runtime.popRoots(&combined_roots);
    try upsertDynamicGlobal(runtime, "表示ログ", rooted_combined);
    _ = command;
    return returned;
}

pub fn concatAotValues(runtime: *Runtime, left: Value, right: Value) !Value {
    var rooted = [_]Value{ left, right };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    const left_view: aot_state.Utf16View = if (rooted[0].tag == @backingInt(Tag.undefined)) .{ .units = &.{} } else try aot_state.valueUtf16View(runtime, rooted[0]);
    defer left_view.deinit(runtime);
    const right_view: aot_state.Utf16View = if (rooted[1].tag == @backingInt(Tag.undefined)) .{ .units = &.{} } else try aot_state.valueUtf16View(runtime, rooted[1]);
    defer right_view.deinit(runtime);
    const combined = try runtime.allocator.alloc(u16, left_view.units.len + right_view.units.len);
    errdefer runtime.allocator.free(combined);
    @memcpy(combined[0..left_view.units.len], left_view.units);
    @memcpy(combined[left_view.units.len..], right_view.units);
    return runtime.ownString(combined);
}

/// ESM plugin の命令を名前で呼ぶ（Issue #55）。
///
/// AOT の compat runtime は plugin module を評価して `__lnako_commands` へ
/// 命令を登録する。呼出し側は命令名と実引数だけを渡し、解決は embedded
/// interpreter の `callExternalCommand`（plugin 命令を含む dispatch 表）へ
/// 委譲する。native plugin の `nativePluginBuiltin` と同じ変換経路を使う。
pub fn esmPluginBuiltin(runtime: *Runtime, name: []const u8, arguments: []const Value) !Value {
    const dynamic_state = try dynamicInterpreterState(runtime);
    const dynamic_arguments = try runtime.allocator.alloc(dynamic_value.Value, arguments.len);
    defer runtime.allocator.free(dynamic_arguments);
    @memset(dynamic_arguments, .undefined);
    var roots = dynamic_state.value_runtime.rootFrame();
    defer roots.deinit();
    var aot_to_dyn = AotToDynamicCache.init(dynamic_state);
    defer aot_to_dyn.deinit();
    try aot_to_dyn.enter();
    for (arguments, dynamic_arguments) |argument, *converted| {
        converted.* = try aotToDynamicValueWithCache(&aot_to_dyn, argument);
        try roots.protect(converted);
    }
    // plugin はAOTグローバルを `sys.__getSysVar` / `sys.__findVar` 経由で観測
    // し得る。引数変換と同一のキャッシュで同期し、参照同一性を保つ。
    try syncAotGlobalsForPlugin(&aot_to_dyn);
    var before_globals = BeforeGlobalsSnapshot.init(dynamic_state);
    defer before_globals.deinit();
    try before_globals.capture();
    var before_containers = BeforeContainersSnapshot.init(dynamic_state);
    defer before_containers.deinit();
    try before_containers.capture(&aot_to_dyn);

    var result = dynamic_state.interpreter.callExternalCommand(name, dynamic_arguments) catch |failure| {
        var err_dyn_cache = DynamicToAotCache.init(dynamic_state);
        defer err_dyn_cache.deinit();
        err_dyn_cache.enter();
        // 例外送出経路でも、送出前の引数変更や `sys.__setSysVar` 副作用を
        // AOT 側へ反映する。元の例外を優先し、失敗時も元コンテナを壊さない。
        finalizePluginCall(dynamic_state, &aot_to_dyn, &before_globals, &before_containers, &err_dyn_cache) catch {};
        return failure;
    };
    try roots.protect(&result);

    var dyn_cache = DynamicToAotCache.init(dynamic_state);
    defer dyn_cache.deinit();
    dyn_cache.enter();
    try finalizePluginCall(dynamic_state, &aot_to_dyn, &before_globals, &before_containers, &dyn_cache);
    return dynamicToAotValueCached(&dyn_cache, result, 0);
}
