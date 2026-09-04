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

pub fn awaitExecute(self: *Interpreter, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidAwaitArguments;
    const callable = try self.resolveCallback(arguments[0]);
    const call_arguments = if (arguments[1] == .array) arguments[1].array.items.items else arguments[1..2];
    const result = try self.callFunctionValue(callable.function, call_arguments);
    return self.awaitValue(result);
}

pub fn awaitValue(self: *Interpreter, value: Value) !Value {
    if (value != .promise) return value;
    var promise_root = value;
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&promise_root);
    if (promise_root.promise.state == .pending) try self.drainEventLoop();
    return switch (promise_root.promise.state) {
        .fulfilled => promise_root.promise.result,
        .rejected => {
            self.exception_value = promise_root.promise.result;
            return error.NakoException;
        },
        .pending => error.PromiseStillPending,
    };
}

pub fn delayMilliseconds(self: *Interpreter, value: Value) !u64 {
    const seconds = try self.runtime.valueToNumber(value);
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = @floor(seconds * 1000);
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.TimerOverflow;
    return @intFromFloat(milliseconds);
}

pub fn scheduleTimer(self: *Interpreter, arguments: []const Value, repeating: bool) !Value {
    if (arguments.len < 2) return error.InvalidTimerArguments;
    var callback = try self.resolveCallback(arguments[0]);
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&callback);
    const delay = try self.delayMilliseconds(arguments[1]);
    const timer_id = self.next_timer_id;
    self.next_timer_id = std.math.add(u64, self.next_timer_id, 1) catch return error.TimerOverflow;
    const due = std.math.add(u64, self.elapsed_milliseconds, delay) catch return error.TimerOverflow;
    try self.timers.append(self.allocator, .{
        .id = timer_id,
        .due_milliseconds = due,
        .interval_milliseconds = if (repeating) delay else 0,
        .repeating = repeating,
        .callback = callback,
    });
    const result = Value{ .number = @floatFromInt(timer_id) };
    try self.setGlobal("対象", result);
    return result;
}

pub fn resolveCallback(self: *Interpreter, callback: Value) !Value {
    if (callback == .function) return callback;
    if (callback != .string) return error.NotCallable;
    const name = try callback.string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(name);
    if (self.globals.get(name)) |candidate| {
        if (candidate == .function) return candidate;
    }
    const function = self.findFunction(self.currentProgramOwner(), name) orelse return error.UnknownFunction;
    var name_value = try self.runtime.stringUtf8(function.name);
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&name_value);
    const result = try self.runtime.createIrFunction(name_value.string, function.parameters.len, function.id, &.{});
    result.function.ir_program = @ptrCast(self.currentProgramOwner());
    return result;
}

pub fn stopTimer(self: *Interpreter, timer_id: u64) bool {
    for (self.timers.items, 0..) |timer, index| {
        if (timer.id != timer_id) continue;
        _ = self.timers.orderedRemove(index);
        return true;
    }
    return false;
}

pub fn createPromiseWithExecutor(self: *Interpreter, arguments: []const Value) !Value {
    if (arguments.len == 0 or arguments[0] != .function) return error.NotCallable;
    var promise = try self.runtime.createPromise();
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&promise);
    var resolve = try self.createPromiseResolver(promise.promise, false);
    try root.protect(&resolve);
    var reject = try self.createPromiseResolver(promise.promise, true);
    try root.protect(&reject);
    _ = self.callFunctionValue(arguments[0].function, &.{ resolve, reject }) catch |failure| {
        const reason = try self.runtime.stringUtf8(error_message.forFailure(failure));
        try self.runtime.rejectPromise(promise.promise, reason);
    };
    if (promise.promise.state != .pending) try self.removePromiseResolvers(promise.promise);
    try self.setGlobal("そ", promise);
    return promise;
}

pub fn createPromiseResolver(self: *Interpreter, promise: *value_mod.Promise, rejected: bool) !Value {
    var promise_root = Value{ .promise = promise };
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&promise_root);
    var name = try self.runtime.stringUtf8(if (rejected) "reject" else "resolve");
    try root.protect(&name);
    const resolver = try self.runtime.createNativeFunction(name.string, 1, promiseResolverSentinel, &.{});
    try self.promise_resolvers.put(self.allocator, resolver.function, .{ .promise = promise, .rejected = rejected });
    return resolver;
}

pub fn removePromiseResolvers(self: *Interpreter, promise: *value_mod.Promise) !void {
    var keys: std.ArrayList(*value_mod.Function) = .empty;
    defer keys.deinit(self.allocator);
    var iterator = self.promise_resolvers.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.promise == promise) try keys.append(self.allocator, entry.key_ptr.*);
    for (keys.items) |key| _ = self.promise_resolvers.remove(key);
}

pub fn chainPromise(self: *Interpreter, arguments: []const Value, kind: PromiseChainKind) !Value {
    if (arguments.len < 2 or arguments[0] != .function or arguments[1] != .promise) return error.InvalidPromiseArguments;
    const callback = arguments[0];
    const source = arguments[1].promise;
    const result = switch (kind) {
        .success => try self.runtime.promiseThen(source, callback, .undefined),
        .failure => try self.runtime.promiseThen(source, .undefined, callback),
        .settled => try self.runtime.promiseThenMode(source, callback, callback, .settled_pair),
        .finally => try self.runtime.promiseThenMode(source, callback, callback, .finally),
    };
    try self.setGlobal("そ", result);
    return result;
}

pub fn bundlePromises(self: *Interpreter, arguments: []const Value) !Value {
    var promise = try self.runtime.createPromise();
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&promise);
    var results = try self.runtime.createArray();
    try roots.protect(&results);
    for (arguments) |_| _ = try results.array.push(.undefined);

    const state = try self.allocator.create(PromiseAllState);
    errdefer self.allocator.destroy(state);
    state.* = .{ .promise = promise.promise, .results = results.array };
    try self.promise_all_states.append(self.allocator, state);
    errdefer _ = self.promise_all_states.pop();

    for (arguments, 0..) |argument, index| {
        if (argument != .promise) {
            try results.array.set(index, argument);
            continue;
        }
        state.remaining += 1;
        var handler_roots = self.runtime.rootFrame();
        defer handler_roots.deinit();
        var fulfilled_name = try self.runtime.stringUtf8("Promise.all fulfilled");
        try handler_roots.protect(&fulfilled_name);
        var fulfilled = try self.runtime.createNativeFunction(fulfilled_name.string, 1, promiseAllSentinel, &.{});
        try handler_roots.protect(&fulfilled);
        var rejected_name = try self.runtime.stringUtf8("Promise.all rejected");
        try handler_roots.protect(&rejected_name);
        var rejected = try self.runtime.createNativeFunction(rejected_name.string, 1, promiseAllSentinel, &.{});
        try handler_roots.protect(&rejected);
        try self.promise_all_handlers.put(self.allocator, fulfilled.function, .{ .state = state, .index = index, .rejected = false, .peer = rejected.function });
        errdefer _ = self.promise_all_handlers.remove(fulfilled.function);
        try self.promise_all_handlers.put(self.allocator, rejected.function, .{ .state = state, .index = index, .rejected = true, .peer = fulfilled.function });
        errdefer _ = self.promise_all_handlers.remove(rejected.function);
        _ = try self.runtime.promiseThen(argument.promise, fulfilled, rejected);
    }
    if (state.remaining == 0) {
        if (promise.promise.state == .pending) try self.runtime.resolvePromise(promise.promise, results);
        self.destroyPromiseAllState(state);
    }
    try self.setGlobal("そ", promise);
    return promise;
}

pub fn handlePromiseAll(self: *Interpreter, function: *value_mod.Function, handler: PromiseAllHandler, arguments: []const Value) !Value {
    _ = self.promise_all_handlers.remove(function);
    _ = self.promise_all_handlers.remove(handler.peer);
    const settled = if (arguments.len > 0) arguments[0] else Value.undefined;
    if (handler.rejected) {
        try self.runtime.rejectPromise(handler.state.promise, settled);
    } else try handler.state.results.set(handler.index, settled);
    std.debug.assert(handler.state.remaining > 0);
    handler.state.remaining -= 1;
    if (handler.state.remaining == 0) {
        if (handler.state.promise.state == .pending) try self.runtime.resolvePromise(handler.state.promise, .{ .array = handler.state.results });
        self.destroyPromiseAllState(handler.state);
    }
    return .undefined;
}

pub fn destroyPromiseAllState(self: *Interpreter, state: *PromiseAllState) void {
    for (self.promise_all_states.items, 0..) |candidate, index| {
        if (candidate != state) continue;
        _ = self.promise_all_states.orderedRemove(index);
        self.allocator.destroy(state);
        return;
    }
    unreachable;
}

pub fn drainEventLoop(self: *Interpreter) !void {
    while (true) {
        try self.drainPromiseTasks();
        const commands_pending = try self.pollNodeCommands();
        const native_plugins_pending = try plugin_native.poll(self.runtime, &self.native_plugin_state);
        try self.drainPromiseTasks();
        if (self.timers.items.len > 0) {
            try self.executeTimer(self.earliestTimerIndex().?);
        } else if (commands_pending or native_plugins_pending) {
            try self.sleepEventSlice(1);
        } else if (try self.pollHttpServer()) {
            try self.countEvent();
        } else return;
    }
}

pub fn waitMilliseconds(self: *Interpreter, milliseconds: u64) !void {
    const target = std.math.add(u64, self.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    while (true) {
        try self.drainPromiseTasks();
        const earliest = self.earliestTimerIndex() orelse break;
        if (self.timers.items[earliest].due_milliseconds > target) break;
        try self.executeTimer(earliest);
    }
    try self.sleepUntil(target);
}

pub fn drainPromiseTasks(self: *Interpreter) !void {
    while (self.runtime.takePromiseTask()) |task| {
        try self.countEvent();
        try self.executePromiseTask(task);
    }
}

pub fn earliestTimerIndex(self: Interpreter) ?usize {
    if (self.timers.items.len == 0) return null;
    var earliest: usize = 0;
    for (self.timers.items[1..], 1..) |timer, index| {
        if (timer.due_milliseconds < self.timers.items[earliest].due_milliseconds) earliest = index;
    }
    return earliest;
}

pub fn executeTimer(self: *Interpreter, index: usize) !void {
    try self.countEvent();
    const timer = self.timers.orderedRemove(index);
    var callback = timer.callback;
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&callback);
    try self.sleepUntil(timer.due_milliseconds);
    if (timer.repeating) {
        var next = timer;
        next.due_milliseconds = std.math.add(u64, self.elapsed_milliseconds, timer.interval_milliseconds) catch return error.TimerOverflow;
        try self.timers.append(self.allocator, next);
    }
    const id = Value{ .number = @floatFromInt(timer.id) };
    _ = self.callFunctionValue(callback.function, &.{id}) catch |failure| {
        self.exception_value = try self.runtime.stringUtf8(@errorName(failure));
    };
}

pub fn sleepUntil(self: *Interpreter, target: u64) !void {
    while (target > self.elapsed_milliseconds) {
        const remaining = target - self.elapsed_milliseconds;
        const slice = @min(remaining, 20);
        try self.sleepEventSlice(slice);
    }
}

pub fn sleepEventSlice(self: *Interpreter, milliseconds: u64) !void {
    try self.host.sleepMilliseconds(milliseconds);
    self.elapsed_milliseconds += milliseconds;
    try self.handleNodeInterrupt();
    _ = try self.pollNodeCommands();
}

pub fn pollNodeCommands(self: *Interpreter) !bool {
    const context = self.host.node_context orelse return false;
    return plugin_node.pollOperations(self.runtime, &self.node_state, context, self.nodeEffects());
}

pub fn pollHttpServer(self: *Interpreter) !bool {
    if (self.call_depth != 0) return false;
    const context = self.host.http_server_context orelse return false;
    return plugin_http_server.poll(self.runtime, &self.http_server_state, context, self.httpServerEffects());
}

pub fn executePromiseTask(self: *Interpreter, task: value_mod.PromiseTask) !void {
    var callback = task.callback;
    var settled = task.settled_value;
    var next = Value{ .promise = task.next };
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&callback);
    try root.protect(&settled);
    try root.protect(&next);
    if (callback == .undefined) return self.runtime.forwardPromiseTask(task);
    if (callback != .function) {
        const reason = try self.runtime.stringUtf8("NotCallable");
        return self.runtime.rejectPromise(task.next, reason);
    }
    if (task.mode != .finally) try self.setGlobal("対象", settled);
    const result = switch (task.mode) {
        .standard => self.callFunctionValue(callback.function, &.{settled}),
        .settled_pair => self.callFunctionValue(callback.function, &.{ .{ .boolean = !task.rejected }, settled }),
        .finally => self.callFunctionValue(callback.function, &.{}),
    } catch |failure| {
        const reason = if (self.exception_value != .undefined) blk: {
            const captured = self.exception_value;
            self.exception_value = .undefined;
            break :blk captured;
        } else try self.runtime.stringUtf8(error_message.forFailure(failure));
        return self.runtime.rejectPromise(task.next, reason);
    };
    if (task.mode == .finally) {
        if (task.rejected) return self.runtime.rejectPromise(task.next, task.settled_value);
        return self.runtime.resolvePromise(task.next, task.settled_value);
    }
    return self.runtime.resolvePromise(task.next, result);
}

pub fn countEvent(self: *Interpreter) !void {
    if (self.event_count >= self.max_event_count) return error.EventLoopLimitExceeded;
    self.event_count += 1;
}
