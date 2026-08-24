const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../runtime/value.zig");
const builtin_catalog = @import("../semantic/builtin_catalog.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const abi_version: u32 = 1;
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_pending: c_int = 2;
const flag_sync: u32 = 1 << 0;
const flag_async: u32 = 1 << 1;
const flag_pure: u32 = 1 << 2;

const OpaqueValue = opaque {};

const CommandV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    flags: u32,
    name: ?[*:0]const u8,
    particles: ?[*:0]const u8,
    minimum_arguments: usize,
    maximum_arguments: usize,
    command_context: ?*anyopaque,
    invoke: ?*const fn (?*anyopaque, *const HostV1, [*c]const *const OpaqueValue, usize, u64, [*c]?*OpaqueValue) callconv(.c) c_int,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
};

const HostV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    context: ?*anyopaque,
    value_kind: *const fn (?*anyopaque, ?*const OpaqueValue) callconv(.c) u32,
    value_retain: *const fn (?*anyopaque, ?*OpaqueValue) callconv(.c) void,
    value_release: *const fn (?*anyopaque, ?*OpaqueValue) callconv(.c) void,
    make_undefined: *const fn (?*anyopaque) callconv(.c) ?*OpaqueValue,
    make_null: *const fn (?*anyopaque) callconv(.c) ?*OpaqueValue,
    make_boolean: *const fn (?*anyopaque, c_int) callconv(.c) ?*OpaqueValue,
    make_number: *const fn (?*anyopaque, f64) callconv(.c) ?*OpaqueValue,
    make_bigint: *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) ?*OpaqueValue,
    make_string: *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) ?*OpaqueValue,
    make_bytes: *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) ?*OpaqueValue,
    make_array: *const fn (?*anyopaque) callconv(.c) ?*OpaqueValue,
    make_dictionary: *const fn (?*anyopaque) callconv(.c) ?*OpaqueValue,
    get_boolean: *const fn (?*anyopaque, ?*const OpaqueValue, ?*c_int) callconv(.c) c_int,
    get_number: *const fn (?*anyopaque, ?*const OpaqueValue, ?*f64) callconv(.c) c_int,
    get_utf8: *const fn (?*anyopaque, ?*OpaqueValue, ?*usize) callconv(.c) ?[*]const u8,
    get_bytes: *const fn (?*anyopaque, ?*const OpaqueValue, ?*usize) callconv(.c) ?[*]const u8,
    array_length: *const fn (?*anyopaque, ?*const OpaqueValue) callconv(.c) usize,
    array_get: *const fn (?*anyopaque, ?*const OpaqueValue, usize) callconv(.c) ?*OpaqueValue,
    array_push: *const fn (?*anyopaque, ?*OpaqueValue, ?*const OpaqueValue) callconv(.c) c_int,
    dictionary_get: *const fn (?*anyopaque, ?*const OpaqueValue, ?[*]const u8, usize) callconv(.c) ?*OpaqueValue,
    dictionary_set: *const fn (?*anyopaque, ?*OpaqueValue, ?[*]const u8, usize, ?*const OpaqueValue) callconv(.c) c_int,
    call_command: *const fn (?*anyopaque, ?[*:0]const u8, [*c]const *const OpaqueValue, usize, [*c]?*OpaqueValue) callconv(.c) c_int,
    call_function: *const fn (?*anyopaque, ?*const OpaqueValue, [*c]const *const OpaqueValue, usize, [*c]?*OpaqueValue) callconv(.c) c_int,
    complete_async: *const fn (?*anyopaque, u64, c_int, ?*OpaqueValue) callconv(.c) c_int,
};

const RegistryV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    context: ?*anyopaque,
    register_command: *const fn (?*anyopaque, ?*const CommandV1) callconv(.c) c_int,
};

const DescriptorV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    plugin_context: ?*anyopaque,
    initialize: ?*const fn (?*anyopaque, *const HostV1, *const RegistryV1) callconv(.c) c_int,
    deinitialize: ?*const fn (?*anyopaque) callconv(.c) void,
};

const EntryV1 = *const fn () callconv(.c) ?*const DescriptorV1;

pub const Effects = struct {
    context: *anyopaque,
    invokeFn: *const fn (context: *anyopaque, callable: Value, arguments: []const Value) anyerror!Value,
    execFn: *const fn (context: *anyopaque, name: []const u8, arguments: []const Value) anyerror!Value,

    fn invoke(self: Effects, callable: Value, arguments: []const Value) !Value {
        return self.invokeFn(self.context, callable, arguments);
    }

    fn exec(self: Effects, name: []const u8, arguments: []const Value) !Value {
        return self.execFn(self.context, name, arguments);
    }
};

const Box = struct {
    state: *State,
    references: std.atomic.Value(usize) = .init(1),
    value: Value,
    utf8_cache: ?[]u8 = null,
};

const Command = struct {
    name: []u8,
    particles: []u8,
    flags: u32,
    minimum_arguments: usize,
    maximum_arguments: usize,
    context: ?*anyopaque,
    invoke: *const fn (?*anyopaque, *const HostV1, [*c]const *const OpaqueValue, usize, u64, [*c]?*OpaqueValue) callconv(.c) c_int,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
};

const Plugin = struct {
    library: NativeLibrary,
    descriptor: *const DescriptorV1,
    path: []u8,
    name: []u8,
    version: []u8,
};

const AsyncTask = struct {
    state: *State,
    promise: *value_mod.Promise,
    claimed: std.atomic.Value(bool) = .init(false),
    complete: std.atomic.Value(bool) = .init(false),
    status: c_int = status_pending,
    result: ?*Box = null,
};

pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    runtime: ?*Runtime = null,
    effects: ?Effects = null,
    host: HostV1 = undefined,
    host_initialized: bool = false,
    plugins: std.ArrayList(Plugin) = .empty,
    commands: std.ArrayList(Command) = .empty,
    boxes: std.ArrayList(*Box) = .empty,
    tasks: std.ArrayList(*AsyncTask) = .empty,

    pub fn init() State {
        return .{};
    }

    pub fn deinit(self: *State) void {
        const allocator = self.allocator orelse {
            self.* = undefined;
            return;
        };
        // Stop plugin-owned worker threads while every async token and host
        // callback is still valid. Libraries remain loaded until command
        // contexts have also been destroyed.
        for (self.plugins.items) |*plugin| {
            if (plugin.descriptor.deinitialize) |deinitialize| deinitialize(plugin.descriptor.plugin_context);
        }
        for (self.tasks.items) |task| {
            if (task.result) |result| self.releaseBox(result);
            allocator.destroy(task);
        }
        self.tasks.deinit(allocator);
        for (self.commands.items) |command| {
            if (command.destroy) |destroy| destroy(command.context);
            allocator.free(command.name);
            allocator.free(command.particles);
        }
        self.commands.deinit(allocator);
        for (self.plugins.items) |*plugin| {
            plugin.library.close();
            allocator.free(plugin.path);
            allocator.free(plugin.name);
            allocator.free(plugin.version);
        }
        self.plugins.deinit(allocator);
        while (self.boxes.pop()) |box| {
            if (box.utf8_cache) |cache| allocator.free(cache);
            allocator.destroy(box);
        }
        self.boxes.deinit(allocator);
        self.* = undefined;
    }

    pub fn trace(self: *State, runtime: *Runtime) !void {
        for (self.boxes.items) |box| try runtime.traceExternal(box.value);
        for (self.tasks.items) |task| try runtime.traceExternal(.{ .promise = task.promise });
    }

    fn configure(self: *State, runtime: *Runtime, effects: Effects) void {
        self.allocator = runtime.allocator();
        self.runtime = runtime;
        self.effects = effects;
        if (self.host_initialized) return;
        self.host = .{
            .struct_size = @sizeOf(HostV1),
            .abi_version = abi_version,
            .context = self,
            .value_kind = hostValueKind,
            .value_retain = hostValueRetain,
            .value_release = hostValueRelease,
            .make_undefined = hostMakeUndefined,
            .make_null = hostMakeNull,
            .make_boolean = hostMakeBoolean,
            .make_number = hostMakeNumber,
            .make_bigint = hostMakeBigInt,
            .make_string = hostMakeString,
            .make_bytes = hostMakeBytes,
            .make_array = hostMakeArray,
            .make_dictionary = hostMakeDictionary,
            .get_boolean = hostGetBoolean,
            .get_number = hostGetNumber,
            .get_utf8 = hostGetUtf8,
            .get_bytes = hostGetBytes,
            .array_length = hostArrayLength,
            .array_get = hostArrayGet,
            .array_push = hostArrayPush,
            .dictionary_get = hostDictionaryGet,
            .dictionary_set = hostDictionarySet,
            .call_command = hostCallCommand,
            .call_function = hostCallFunction,
            .complete_async = hostCompleteAsync,
        };
        self.host_initialized = true;
    }

    fn createBox(self: *State, value: Value) !*Box {
        const allocator = self.allocator orelse return error.NativePluginStateUnavailable;
        const box = try allocator.create(Box);
        errdefer allocator.destroy(box);
        box.* = .{ .state = self, .value = value };
        try self.boxes.append(allocator, box);
        return box;
    }

    fn retainBox(self: *State, box: *Box) void {
        if (box.state != self) return;
        _ = box.references.fetchAdd(1, .monotonic);
    }

    fn releaseBox(self: *State, box: *Box) void {
        if (box.state != self or box.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator orelse return;
        for (self.boxes.items, 0..) |candidate, index| {
            if (candidate != box) continue;
            _ = self.boxes.swapRemove(index);
            if (box.utf8_cache) |cache| allocator.free(cache);
            allocator.destroy(box);
            return;
        }
    }

    fn loadPlugin(self: *State, path: []const u8) !void {
        const allocator = self.allocator orelse return error.NativePluginStateUnavailable;
        for (self.plugins.items) |plugin| if (std.mem.eql(u8, plugin.path, path)) return;
        var library = NativeLibrary.open(allocator, path) catch return error.NativePluginOpenFailed;
        errdefer library.close();
        const entry = library.lookup(EntryV1, "lnako_plugin_v1") orelse return error.NativePluginEntryMissing;
        const descriptor = entry() orelse return error.NativePluginDescriptorMissing;
        if (descriptor.struct_size < @sizeOf(DescriptorV1) or descriptor.abi_version != abi_version) return error.NativePluginAbiMismatch;
        const name = std.mem.span(descriptor.name orelse return error.NativePluginNameMissing);
        const version = std.mem.span(descriptor.version orelse return error.NativePluginVersionMissing);
        if (name.len == 0 or version.len == 0 or !std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(version)) return error.NativePluginMetadataInvalid;
        const command_start = self.commands.items.len;
        errdefer self.rollbackCommands(command_start);
        const registry = RegistryV1{
            .struct_size = @sizeOf(RegistryV1),
            .abi_version = abi_version,
            .context = self,
            .register_command = registerCommand,
        };
        const initialize = descriptor.initialize orelse return error.NativePluginInitializerMissing;
        if (initialize(descriptor.plugin_context, &self.host, &registry) != status_ok) return error.NativePluginInitializationFailed;
        errdefer if (descriptor.deinitialize) |deinitialize| deinitialize(descriptor.plugin_context);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const version_copy = try allocator.dupe(u8, version);
        errdefer allocator.free(version_copy);
        try self.plugins.append(allocator, .{
            .library = library,
            .descriptor = descriptor,
            .path = path_copy,
            .name = name_copy,
            .version = version_copy,
        });
    }

    fn rollbackCommands(self: *State, start: usize) void {
        const allocator = self.allocator orelse return;
        while (self.commands.items.len > start) {
            const command = self.commands.pop().?;
            if (command.destroy) |destroy| destroy(command.context);
            allocator.free(command.name);
            allocator.free(command.particles);
        }
    }

    fn findCommand(self: *State, requested: []const u8) ?*Command {
        for (self.commands.items) |*command| if (std.mem.eql(u8, command.name, requested)) return command;
        if (std.mem.lastIndexOf(u8, requested, "__")) |separator| {
            const name = requested[separator + 2 ..];
            for (self.commands.items) |*command| if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};

const NativeLibrary = if (builtin.os.tag == .windows) WindowsLibrary else PosixLibrary;

const PosixLibrary = struct {
    inner: std.DynLib,

    fn open(_: std.mem.Allocator, path: []const u8) !PosixLibrary {
        return .{ .inner = try std.DynLib.open(path) };
    }

    fn lookup(self: *PosixLibrary, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }

    fn close(self: *PosixLibrary) void {
        self.inner.close();
        self.* = undefined;
    }
};

const WindowsLibrary = struct {
    handle: *anyopaque,

    fn open(allocator: std.mem.Allocator, path: []const u8) !WindowsLibrary {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        return .{ .handle = LoadLibraryW(path_w.ptr) orelse return error.NativePluginOpenFailed };
    }

    fn lookup(self: *WindowsLibrary, comptime T: type, name: [:0]const u8) ?T {
        const symbol = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(symbol);
    }

    fn close(self: *WindowsLibrary) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;
};

pub fn install(runtime: *Runtime, state: *State, paths: []const []const u8, effects: Effects) !void {
    state.configure(runtime, effects);
    for (paths) |path| try state.loadPlugin(path);
}

pub fn call(runtime: *Runtime, state: *State, effects: Effects, name: []const u8, arguments: []const Value) !?Value {
    state.configure(runtime, effects);
    const command = state.findCommand(name) orelse return null;
    if (arguments.len < command.minimum_arguments or arguments.len > command.maximum_arguments) return error.NativePluginArityMismatch;
    const boxes = try makeArgumentBoxes(state, arguments);
    defer freeArgumentBoxes(state, boxes);
    if ((command.flags & flag_async) != 0) return @as(?Value, try invokeAsync(runtime, state, command, boxes));
    var raw_result: ?*OpaqueValue = null;
    const status = command.invoke(command.context, &state.host, boxes.ptr, boxes.len, 0, @ptrCast(&raw_result));
    if (status != status_ok) {
        if (raw_result) |result| state.releaseBox(boxFromOpaque(result));
        return error.NativePluginCommandFailed;
    }
    return @as(?Value, takeResult(state, raw_result));
}

fn invokeAsync(runtime: *Runtime, state: *State, command: *Command, arguments: []*const OpaqueValue) !Value {
    var promise = try runtime.createPromise();
    var root = runtime.rootFrame();
    defer root.deinit();
    try root.protect(&promise);
    const allocator = state.allocator orelse return error.NativePluginStateUnavailable;
    const task = try allocator.create(AsyncTask);
    task.* = .{ .state = state, .promise = promise.promise };
    state.tasks.append(allocator, task) catch |err| {
        allocator.destroy(task);
        return err;
    };
    var task_needs_cleanup = true;
    errdefer if (task_needs_cleanup) {
        removeTask(state, task);
        allocator.destroy(task);
    };
    var raw_result: ?*OpaqueValue = null;
    const status = command.invoke(command.context, &state.host, arguments.ptr, arguments.len, @intFromPtr(task), @ptrCast(&raw_result));
    if (status == status_pending) {
        if (raw_result) |result| state.releaseBox(boxFromOpaque(result));
        return promise;
    }
    if (task.claimed.load(.acquire)) {
        if (raw_result) |result| state.releaseBox(boxFromOpaque(result));
        return promise;
    }
    removeTask(state, task);
    task_needs_cleanup = false;
    defer allocator.destroy(task);
    const value = takeResult(state, raw_result);
    if (status == status_ok) {
        try runtime.resolvePromise(promise.promise, value);
    } else {
        const reason = if (value == .undefined) try runtime.stringUtf8("NativePluginCommandFailed") else value;
        try runtime.rejectPromise(promise.promise, reason);
    }
    return promise;
}

fn removeTask(state: *State, task: *AsyncTask) void {
    for (state.tasks.items, 0..) |candidate, index| {
        if (candidate != task) continue;
        _ = state.tasks.swapRemove(index);
        return;
    }
}

pub fn poll(runtime: *Runtime, state: *State) !bool {
    var index: usize = 0;
    while (index < state.tasks.items.len) {
        const task = state.tasks.items[index];
        if (!task.complete.load(.acquire)) {
            index += 1;
            continue;
        }
        try settleTask(runtime, state, task);
    }
    return state.tasks.items.len > 0;
}

fn settleTask(runtime: *Runtime, state: *State, task: *AsyncTask) !void {
    const allocator = state.allocator orelse return error.NativePluginStateUnavailable;
    const value = takeResult(state, if (task.result) |box| opaqueFromBox(box) else null);
    task.result = null;
    defer {
        removeTask(state, task);
        allocator.destroy(task);
    }
    if (task.status == status_ok) {
        try runtime.resolvePromise(task.promise, value);
    } else {
        const reason = if (value == .undefined) try runtime.stringUtf8("NativePluginCommandFailed") else value;
        try runtime.rejectPromise(task.promise, reason);
    }
}

fn makeArgumentBoxes(state: *State, arguments: []const Value) ![]*const OpaqueValue {
    const allocator = state.allocator orelse return error.NativePluginStateUnavailable;
    const result = try allocator.alloc(*const OpaqueValue, arguments.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |raw| state.releaseBox(boxFromOpaque(@constCast(raw)));
    for (arguments, 0..) |argument, index| {
        result[index] = opaqueFromBox(try state.createBox(argument));
        initialized += 1;
    }
    return result;
}

fn freeArgumentBoxes(state: *State, arguments: []*const OpaqueValue) void {
    const allocator = state.allocator orelse return;
    for (arguments) |raw| state.releaseBox(boxFromOpaque(@constCast(raw)));
    allocator.free(arguments);
}

fn takeResult(state: *State, raw: ?*OpaqueValue) Value {
    const box = boxFromOpaque(raw orelse return .undefined);
    if (box.state != state) return .undefined;
    const result = box.value;
    state.releaseBox(box);
    return result;
}

fn stateFromContext(context: ?*anyopaque) ?*State {
    return @ptrCast(@alignCast(context orelse return null));
}

fn boxFromOpaque(value: *OpaqueValue) *Box {
    return @ptrCast(@alignCast(value));
}

fn opaqueFromBox(box: *Box) *OpaqueValue {
    return @ptrCast(box);
}

fn checkedBox(state: *State, raw: ?*const OpaqueValue) ?*Box {
    const box = boxFromOpaque(@constCast(raw orelse return null));
    return if (box.state == state) box else null;
}

fn registerCommand(context: ?*anyopaque, raw: ?*const CommandV1) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    const command = raw orelse return -1;
    if (command.struct_size < @sizeOf(CommandV1) or command.abi_version != abi_version or command.invoke == null or command.name == null) return -1;
    if ((command.flags & ~(flag_sync | flag_async | flag_pure)) != 0 or ((command.flags & flag_sync) == 0) == ((command.flags & flag_async) == 0)) return -1;
    if (command.minimum_arguments > command.maximum_arguments) return -1;
    const name = std.mem.span(command.name.?);
    if (name.len == 0 or state.findCommand(name) != null or isBuiltinName(name)) return -1;
    const particles = if (command.particles) |text| std.mem.span(text) else "";
    if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(particles)) return -1;
    const allocator = state.allocator orelse return -1;
    const name_copy = allocator.dupe(u8, name) catch return -1;
    const particles_copy = allocator.dupe(u8, particles) catch {
        allocator.free(name_copy);
        return -1;
    };
    state.commands.append(allocator, .{
        .name = name_copy,
        .particles = particles_copy,
        .flags = command.flags,
        .minimum_arguments = command.minimum_arguments,
        .maximum_arguments = command.maximum_arguments,
        .context = command.command_context,
        .invoke = command.invoke.?,
        .destroy = command.destroy,
    }) catch {
        allocator.free(name_copy);
        allocator.free(particles_copy);
        return -1;
    };
    return status_ok;
}

fn isBuiltinName(name: []const u8) bool {
    for (builtin_catalog.names) |builtin_name| if (std.mem.eql(u8, builtin_name, name)) return true;
    return false;
}

fn hostValueKind(context: ?*anyopaque, raw: ?*const OpaqueValue) callconv(.c) u32 {
    const state = stateFromContext(context) orelse return 0;
    const box = checkedBox(state, raw) orelse return 0;
    return switch (box.value) {
        .undefined => 0,
        .null_value => 1,
        .boolean => 2,
        .number => 3,
        .bigint => 4,
        .string => 5,
        .bytes => 6,
        .array => 7,
        .dictionary => 8,
        .function => 9,
        .promise => 10,
    };
}

fn hostValueRetain(context: ?*anyopaque, raw: ?*OpaqueValue) callconv(.c) void {
    const state = stateFromContext(context) orelse return;
    const box = checkedBox(state, raw) orelse return;
    state.retainBox(box);
}

fn hostValueRelease(context: ?*anyopaque, raw: ?*OpaqueValue) callconv(.c) void {
    const state = stateFromContext(context) orelse return;
    const box = checkedBox(state, raw) orelse return;
    state.releaseBox(box);
}

fn makeHostValue(context: ?*anyopaque, value: Value) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    return opaqueFromBox(state.createBox(value) catch return null);
}

fn hostMakeUndefined(context: ?*anyopaque) callconv(.c) ?*OpaqueValue {
    return makeHostValue(context, .undefined);
}

fn hostMakeNull(context: ?*anyopaque) callconv(.c) ?*OpaqueValue {
    return makeHostValue(context, .null_value);
}

fn hostMakeBoolean(context: ?*anyopaque, value: c_int) callconv(.c) ?*OpaqueValue {
    return makeHostValue(context, .{ .boolean = value != 0 });
}

fn hostMakeNumber(context: ?*anyopaque, value: f64) callconv(.c) ?*OpaqueValue {
    return makeHostValue(context, .{ .number = value });
}

fn hostMakeBigInt(context: ?*anyopaque, decimal: ?[*]const u8, length: usize) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const runtime = state.runtime orelse return null;
    if (decimal == null and length != 0) return null;
    const source = if (decimal) |pointer| pointer[0..length] else "";
    const allocator = state.allocator orelse return null;
    const literal = std.fmt.allocPrint(allocator, "{s}n", .{source}) catch return null;
    defer allocator.free(literal);
    return makeHostValue(context, runtime.bigIntLiteral(literal) catch return null);
}

fn hostMakeString(context: ?*anyopaque, utf8: ?[*]const u8, length: usize) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const runtime = state.runtime orelse return null;
    if (utf8 == null and length != 0) return null;
    const source = if (utf8) |pointer| pointer[0..length] else "";
    return makeHostValue(context, runtime.stringUtf8(source) catch return null);
}

fn hostMakeBytes(context: ?*anyopaque, bytes: ?[*]const u8, length: usize) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const runtime = state.runtime orelse return null;
    if (bytes == null and length != 0) return null;
    const source = if (bytes) |pointer| pointer[0..length] else "";
    return makeHostValue(context, runtime.createBytes(source) catch return null);
}

fn hostMakeArray(context: ?*anyopaque) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const runtime = state.runtime orelse return null;
    return makeHostValue(context, runtime.createArray() catch return null);
}

fn hostMakeDictionary(context: ?*anyopaque) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const runtime = state.runtime orelse return null;
    return makeHostValue(context, runtime.createDictionary() catch return null);
}

fn hostGetBoolean(context: ?*anyopaque, raw: ?*const OpaqueValue, result: ?*c_int) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    const box = checkedBox(state, raw) orelse return -1;
    const output = result orelse return -1;
    output.* = @intFromBool(box.value.toBoolean());
    return status_ok;
}

fn hostGetNumber(context: ?*anyopaque, raw: ?*const OpaqueValue, result: ?*f64) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    const box = checkedBox(state, raw) orelse return -1;
    const runtime = state.runtime orelse return -1;
    const output = result orelse return -1;
    output.* = runtime.valueToNumber(box.value) catch return -1;
    return status_ok;
}

fn hostGetUtf8(context: ?*anyopaque, raw: ?*OpaqueValue, length: ?*usize) callconv(.c) ?[*]const u8 {
    const state = stateFromContext(context) orelse return null;
    const box = checkedBox(state, raw) orelse return null;
    if (box.value != .string and box.value != .bigint) return null;
    const runtime = state.runtime orelse return null;
    const allocator = state.allocator orelse return null;
    if (box.utf8_cache == null) {
        const text = runtime.valueToString(box.value) catch return null;
        box.utf8_cache = text.string.toUtf8Lossy(allocator) catch return null;
    }
    if (length) |output| output.* = box.utf8_cache.?.len;
    return box.utf8_cache.?.ptr;
}

fn hostGetBytes(context: ?*anyopaque, raw: ?*const OpaqueValue, length: ?*usize) callconv(.c) ?[*]const u8 {
    const state = stateFromContext(context) orelse return null;
    const box = checkedBox(state, raw) orelse return null;
    if (box.value != .bytes) return null;
    if (length) |output| output.* = box.value.bytes.bytes.len;
    return box.value.bytes.bytes.ptr;
}

fn hostArrayLength(context: ?*anyopaque, raw: ?*const OpaqueValue) callconv(.c) usize {
    const state = stateFromContext(context) orelse return 0;
    const box = checkedBox(state, raw) orelse return 0;
    return if (box.value == .array) box.value.array.items.items.len else 0;
}

fn hostArrayGet(context: ?*anyopaque, raw: ?*const OpaqueValue, index: usize) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const box = checkedBox(state, raw) orelse return null;
    if (box.value != .array) return null;
    return opaqueFromBox(state.createBox(box.value.array.get(index)) catch return null);
}

fn hostArrayPush(context: ?*anyopaque, raw: ?*OpaqueValue, item_raw: ?*const OpaqueValue) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    const box = checkedBox(state, raw) orelse return -1;
    const item = checkedBox(state, item_raw) orelse return -1;
    if (box.value != .array) return -1;
    _ = box.value.array.push(item.value) catch return -1;
    return status_ok;
}

fn hostDictionaryGet(context: ?*anyopaque, raw: ?*const OpaqueValue, key: ?[*]const u8, key_length: usize) callconv(.c) ?*OpaqueValue {
    const state = stateFromContext(context) orelse return null;
    const box = checkedBox(state, raw) orelse return null;
    if (box.value != .dictionary or (key == null and key_length != 0)) return null;
    const name = if (key) |pointer| pointer[0..key_length] else "";
    const runtime = state.runtime orelse return null;
    const name_value = runtime.stringUtf8(name) catch return null;
    const value = box.value.dictionary.get(name_value.string) orelse .undefined;
    return opaqueFromBox(state.createBox(value) catch return null);
}

fn hostDictionarySet(context: ?*anyopaque, raw: ?*OpaqueValue, key: ?[*]const u8, key_length: usize, item_raw: ?*const OpaqueValue) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    const box = checkedBox(state, raw) orelse return -1;
    const item = checkedBox(state, item_raw) orelse return -1;
    if (box.value != .dictionary or (key == null and key_length != 0)) return -1;
    const name = if (key) |pointer| pointer[0..key_length] else "";
    common.dictionarySetUtf8(state.runtime orelse return -1, box.value.dictionary, name, item.value) catch return -1;
    return status_ok;
}

fn hostCallCommand(context: ?*anyopaque, name: ?[*:0]const u8, arguments: [*c]const *const OpaqueValue, count: usize, result: [*c]?*OpaqueValue) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return status_error;
    const effects = state.effects orelse return status_error;
    return callHost(state, arguments, count, result, .{ .command = .{ .command = std.mem.span(name orelse return status_error), .effects = effects } });
}

fn hostCallFunction(context: ?*anyopaque, function_raw: ?*const OpaqueValue, arguments: [*c]const *const OpaqueValue, count: usize, result: [*c]?*OpaqueValue) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return status_error;
    const callable = checkedBox(state, function_raw) orelse return status_error;
    if (callable.value != .function) return status_error;
    const effects = state.effects orelse return status_error;
    return callHost(state, arguments, count, result, .{ .function = .{ .function = callable.value, .effects = effects } });
}

const HostTarget = union(enum) {
    command: struct { command: []const u8, effects: Effects },
    function: struct { function: Value, effects: Effects },
};

fn callHost(state: *State, raw_arguments: [*c]const *const OpaqueValue, count: usize, output: [*c]?*OpaqueValue, target: HostTarget) c_int {
    if (output == null) return status_error;
    output[0] = null;
    const allocator = state.allocator orelse return status_error;
    const arguments = allocator.alloc(Value, count) catch return status_error;
    defer allocator.free(arguments);
    for (0..count) |index| {
        const box = checkedBox(state, raw_arguments[index]) orelse return status_error;
        arguments[index] = box.value;
    }
    const value = switch (target) {
        .command => |command| command.effects.exec(command.command, arguments),
        .function => |function| function.effects.invoke(function.function, arguments),
    } catch return status_error;
    output[0] = opaqueFromBox(state.createBox(value) catch return status_error);
    return status_ok;
}

fn hostCompleteAsync(context: ?*anyopaque, token: u64, status: c_int, raw: ?*OpaqueValue) callconv(.c) c_int {
    const state = stateFromContext(context) orelse return -1;
    if (token == 0 or (status != status_ok and status != status_error)) return -1;
    const task: *AsyncTask = @ptrFromInt(token);
    if (task.state != state) return -1;
    if (raw) |value| if (checkedBox(state, value) == null) return -1;
    if (task.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return -1;
    task.status = status;
    task.result = if (raw) |value| boxFromOpaque(value) else null;
    task.complete.store(true, .release);
    return status_ok;
}

test "ネイティブABIの定数と構造体サイズを固定する" {
    try std.testing.expectEqual(@as(u32, 1), abi_version);
    try std.testing.expect(@sizeOf(HostV1) >= 3 * @sizeOf(usize));
    try std.testing.expect(@sizeOf(CommandV1) >= 8 * @sizeOf(usize));
}

test "ネイティブ命令登録の属性と重複を検証する" {
    var state = State.init();
    state.allocator = std.testing.allocator;
    defer state.deinit();
    var command = CommandV1{
        .struct_size = @sizeOf(CommandV1),
        .abi_version = abi_version,
        .flags = flag_sync | flag_pure,
        .name = "外部加算",
        .particles = "AとBを",
        .minimum_arguments = 2,
        .maximum_arguments = 2,
        .command_context = null,
        .invoke = testCommandInvoke,
        .destroy = null,
    };
    try std.testing.expectEqual(status_ok, registerCommand(&state, &command));
    try std.testing.expectEqual(@as(c_int, -1), registerCommand(&state, &command));
    command.name = "不正属性";
    command.flags = flag_sync | flag_async;
    try std.testing.expectEqual(@as(c_int, -1), registerCommand(&state, &command));
    command.name = "不正引数";
    command.flags = flag_sync;
    command.minimum_arguments = 3;
    command.maximum_arguments = 2;
    try std.testing.expectEqual(@as(c_int, -1), registerCommand(&state, &command));
    command.name = "表示";
    command.minimum_arguments = 0;
    command.maximum_arguments = 1;
    try std.testing.expectEqual(@as(c_int, -1), registerCommand(&state, &command));
}

fn testCommandInvoke(_: ?*anyopaque, _: *const HostV1, _: [*c]const *const OpaqueValue, _: usize, _: u64, _: [*c]?*OpaqueValue) callconv(.c) c_int {
    return status_ok;
}
