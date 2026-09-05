const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const dynamic_ir = shared.dynamic_ir;
const dynamic_interpreter = shared.dynamic_interpreter;
const dynamic_value = shared.dynamic_value;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
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

    pub fn init(allocator: std.mem.Allocator, owner: *Runtime) !*@This() {
        const state = try allocator.create(@This());
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.owner = owner;
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
        interpreter_initialized = false;
        dynamic_bridge_provider_initialized = false;
        program_initialized = false;
        value_runtime_initialized = false;
        return state;
    }

    pub fn deinit(self: *@This()) void {
        self.interpreter.deactivateExternalRuntime();
        self.interpreter.deinit();
        self.value_runtime.unregisterRootProvider(self);
        self.program.deinit();
        self.value_runtime.deinit();
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
        entry.value = value;
        if (entry.slot) |slot| slot.* = value;
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
    errdefer removeAotFunctionBridge(state.owner, bridge);
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

pub fn aotToDynamicValue(state: *DynamicInterpreterState, value: Value) anyerror!dynamic_value.Value {
    const owner = state.owner;
    switch (@as(Tag, @enumFromInt(value.tag))) {
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
            var result = try state.value_runtime.createArray();
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            var prototype = try aotToDynamicValue(state, value.object().?.prototype);
            try roots.protect(&prototype);
            result.array.prototype = prototype;
            for (value.object().?.payload.array.items) |item| _ = try result.array.push(try aotToDynamicValue(state, item));
            for (value.object().?.array_properties.items) |property| {
                var key = try aotToDynamicValue(state, property.key);
                var item = try aotToDynamicValue(state, property.value);
                try roots.protect(&key);
                try roots.protect(&item);
                if (key != .string) return error.DynamicValueUnsupported;
                try result.array.setProperty(key.string, item);
            }
            return result;
        },
        .dictionary => {
            if (value.object().?.toml_temporal) |temporal| {
                return state.value_runtime.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            var result = try state.value_runtime.createDictionary();
            var roots = state.value_runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            for (value.object().?.payload.dictionary.items) |entry| {
                var key = try aotToDynamicValue(state, entry.key);
                var item = try aotToDynamicValue(state, entry.value);
                try roots.protect(&key);
                try roots.protect(&item);
                if (key != .string) return error.DynamicValueUnsupported;
                try result.dictionary.set(key.string, item);
            }
            return result;
        },
        .function => return aotFunctionToDynamicValue(state, value),
        .promise, .iterator, .binding_cell => return error.DynamicValueUnsupported,
    }
}

pub fn dynamicToAotValue(state: *DynamicInterpreterState, value: dynamic_value.Value) anyerror!Value {
    const owner = state.owner;
    return switch (value) {
        .undefined => .{},
        .null_value => .{ .tag = @intFromEnum(Tag.null_value) },
        .boolean => |boolean| .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(boolean) },
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
            var result = try owner.createArray(&.{});
            var roots = RootFrame{};
            owner.pushRoots(&roots, @ptrCast(&result), 1);
            defer owner.popRoots(&roots);
            result.object().?.prototype = try dynamicToAotValue(state, array.prototype);
            for (array.items.items) |item| try result.object().?.payload.array.append(owner.allocator, try dynamicToAotValue(state, item));
            for (array.properties.items) |property| {
                var converted_key = try owner.createString(property.key.units);
                var key_roots = RootFrame{};
                owner.pushRoots(&key_roots, @ptrCast(&converted_key), 1);
                var converted_item = try dynamicToAotValue(state, property.value);
                var item_roots = RootFrame{};
                owner.pushRoots(&item_roots, @ptrCast(&converted_item), 1);
                try owner.setDictionary(&result.object().?.array_properties, converted_key, converted_item);
                owner.popRoots(&item_roots);
                owner.popRoots(&key_roots);
            }
            break :blk result;
        },
        .dictionary => |dictionary| blk: {
            if (dictionary.kind == .toml_temporal) {
                const temporal = dictionary.toml_temporal orelse return error.DynamicValueUnsupported;
                break :blk owner.createTomlTemporal(temporal.kind, temporal.json_text, temporal.toml_text);
            }
            var result = try owner.createDictionary(&.{});
            var result_roots = RootFrame{};
            owner.pushRoots(&result_roots, @ptrCast(&result), 1);
            defer owner.popRoots(&result_roots);
            for (dictionary.keys(), dictionary.values()) |key, item| {
                var converted_key = try owner.createString(key.units);
                var key_roots = RootFrame{};
                owner.pushRoots(&key_roots, @ptrCast(&converted_key), 1);
                var converted_item = try dynamicToAotValue(state, item);
                var item_roots = RootFrame{};
                owner.pushRoots(&item_roots, @ptrCast(&converted_item), 1);
                try owner.setDictionary(&result.object().?.payload.dictionary, converted_key, converted_item);
                owner.popRoots(&item_roots);
                owner.popRoots(&key_roots);
            }
            break :blk result;
        },
        .function => error.DynamicValueUnsupported,
        .promise => |promise| dynamicPromiseToAotValue(state, promise),
    };
}

pub fn prepareDynamic(context: *anyopaque, interpreter: *dynamic_interpreter.Interpreter) anyerror!void {
    const state: *DynamicInterpreterState = @ptrCast(@alignCast(context));
    const owner = state.owner;
    for (owner.dynamic_globals.items) |*entry| {
        if (entry.slot) |slot| entry.value = slot.*;
    }
    for (owner.dynamic_globals.items) |entry| {
        var value = aotToDynamicValue(state, entry.value) catch |failure| switch (failure) {
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
    var iterator = state.interpreter.globals.iterator();
    while (iterator.next()) |entry| {
        const value = dynamicToAotValue(state, entry.value_ptr.*) catch |failure| switch (failure) {
            error.DynamicValueUnsupported => continue,
            else => return failure,
        };
        try upsertDynamicGlobal(state.owner, entry.key_ptr.*, value);
    }
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
    for (arguments, dynamic_arguments) |argument, *converted| {
        converted.* = try aotToDynamicValue(state, argument);
        try roots.protect(converted);
    }
    var result = try state.interpreter.callExternalCommand(name, dynamic_arguments);
    try roots.protect(&result);
    return dynamicToAotValue(state, result);
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
        if (entry.slot) |slot| entry.value = slot.*;
        previous_log = entry.value;
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
    const left_units = if (left.tag == @intFromEnum(Tag.undefined)) &.{} else try valueUtf16Alloc(runtime, left);
    defer if (left.tag != @intFromEnum(Tag.undefined)) runtime.allocator.free(left_units);
    const right_units = if (right.tag == @intFromEnum(Tag.undefined)) &.{} else try valueUtf16Alloc(runtime, right);
    defer if (right.tag != @intFromEnum(Tag.undefined)) runtime.allocator.free(right_units);
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(runtime.allocator);
    try units.appendSlice(runtime.allocator, left_units);
    try units.appendSlice(runtime.allocator, right_units);
    return runtime.createString(units.items);
}
