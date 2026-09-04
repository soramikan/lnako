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
const shared = @import("shared.zig");
const execute = @import("execute.zig");
const events = @import("events.zig");
const plugins = @import("plugins.zig");

pub const Value = shared.Value;
pub const Runtime = shared.Runtime;
pub const TestResult = shared.TestResult;
pub const DynamicPreparationFn = *const fn (context: *anyopaque, interpreter: *Interpreter) anyerror!void;
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

pub const Host = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    dispatch_trace_path: ?[]const u8 = null,
    dispatch_trace_writeFn: ?DispatchTraceWriteFn = null,
    compat_js_trace_path: ?[]const u8 = null,
    compat_js_trace_writeFn: ?DispatchTraceWriteFn = null,
    global_trace_path: ?[]const u8 = null,
    global_trace_writeFn: ?DispatchTraceWriteFn = null,
    literal_trace_path: ?[]const u8 = null,
    literal_trace_writeFn: ?DispatchTraceWriteFn = null,
    sleepMillisecondsFn: ?*const fn (context: *anyopaque, milliseconds: u64) anyerror!void = null,
    nowMillisecondsFn: ?*const fn (context: *anyopaque) anyerror!i64 = null,
    monotonicMillisecondsFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,
    randomFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,
    node_context: ?plugin_node.Context = null,
    http_server_context: ?plugin_http_server.Context = null,

    pub fn write(self: Host, bytes: []const u8) !void {
        try self.writeFn(self.context, bytes);
    }

    pub fn sleepMilliseconds(self: Host, milliseconds: u64) !void {
        if (self.sleepMillisecondsFn) |sleepFn| try sleepFn(self.context, milliseconds);
    }

    pub fn nowMilliseconds(self: Host) !i64 {
        return if (self.nowMillisecondsFn) |function| function(self.context) else 0;
    }

    pub fn monotonicMilliseconds(self: Host) !f64 {
        return if (self.monotonicMillisecondsFn) |function| function(self.context) else 0;
    }

    pub fn random(self: Host) !f64 {
        return if (self.randomFn) |function| function(self.context) else error.RandomSourceUnavailable;
    }
};

pub const BufferHost = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    dispatch_trace: std.ArrayList(u8) = .empty,
    compat_js_trace: std.ArrayList(u8) = .empty,
    global_trace: std.ArrayList(u8) = .empty,
    literal_trace: std.ArrayList(u8) = .empty,
    elapsed_milliseconds: u64 = 0,
    now_milliseconds: i64 = 1_735_689_845_678,
    random_state: u64 = 0x4d595df4d0f33173,

    pub fn deinit(self: *BufferHost) void {
        self.output.deinit(self.allocator);
        self.dispatch_trace.deinit(self.allocator);
        self.compat_js_trace.deinit(self.allocator);
        self.global_trace.deinit(self.allocator);
        self.literal_trace.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn host(self: *BufferHost) Host {
        return .{
            .context = self,
            .writeFn = write,
            .compat_js_trace_writeFn = BufferHost.writeCompatJsTrace,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
        };
    }

    pub fn written(self: BufferHost) []const u8 {
        return self.output.items;
    }

    pub fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.output.appendSlice(self.allocator, bytes);
    }

    pub fn writeDispatchTrace(context: *anyopaque, _: []const u8, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.dispatch_trace.appendSlice(self.allocator, bytes);
    }

    pub fn writeCompatJsTrace(context: *anyopaque, _: []const u8, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.compat_js_trace.appendSlice(self.allocator, bytes);
    }

    pub fn writeGlobalTrace(context: *anyopaque, _: []const u8, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.global_trace.appendSlice(self.allocator, bytes);
    }

    pub fn writeLiteralTrace(context: *anyopaque, _: []const u8, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.literal_trace.appendSlice(self.allocator, bytes);
    }

    pub fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        self.elapsed_milliseconds = std.math.add(u64, self.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    }

    pub fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        return self.now_milliseconds;
    }

    pub fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        return @floatFromInt(self.elapsed_milliseconds);
    }

    pub fn random(context: *anyopaque) !f64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        var value = self.random_state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.random_state = value;
        const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
        return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
    }
};

pub fn interpreterPrimitiveHook(
    context: *anyopaque,
    runtime: *Runtime,
    value: Value,
    hint: value_mod.PrimitiveHint,
) anyerror!?Value {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    std.debug.assert(self.runtime == runtime);
    return self.objectToPrimitive(value, hint);
}

pub fn traceRoots(context: *anyopaque, runtime: *Runtime) !void {
    const self: *Interpreter = @ptrCast(@alignCast(context));
    var globals = self.globals.valueIterator();
    while (globals.next()) |value| try runtime.traceExternal(value.*);
    try runtime.traceExternal(self.exception_value);
    try runtime.traceExternal(self.system_context);
    var frame = self.active_frame;
    while (frame) |active| : (frame = active.parent) {
        for (active.values) |value| try runtime.traceExternal(value);
        var locals = active.locals.valueIterator();
        while (locals.next()) |cell| try runtime.traceExternalBindingCell(cell.*);
        var iterators = active.iterators.valueIterator();
        while (iterators.next()) |iterator| try runtime.traceExternal(iterator.source);
    }
    for (self.timers.items) |timer| try runtime.traceExternal(timer.callback);
    var resolvers = self.promise_resolvers.iterator();
    while (resolvers.next()) |entry| {
        try runtime.traceExternal(.{ .function = entry.key_ptr.* });
        try runtime.traceExternal(.{ .promise = entry.value_ptr.promise });
    }
    var promise_all_handlers = self.promise_all_handlers.iterator();
    while (promise_all_handlers.next()) |entry| try runtime.traceExternal(.{ .function = entry.key_ptr.* });
    for (self.promise_all_states.items) |state| {
        try runtime.traceExternal(.{ .promise = state.promise });
        try runtime.traceExternal(.{ .array = state.results });
    }
    for (self.namespace_stack.items) |entry| {
        try runtime.traceExternal(entry.namespace);
        try runtime.traceExternal(entry.plugin_name);
    }
    for (self.hatena_callbacks.items) |callback| switch (callback) {
        .function => |function| try runtime.traceExternal(function),
        .name => |name| try runtime.traceExternal(name),
    };
    try self.node_state.trace(runtime);
    try self.http_server_state.trace(runtime);
    try self.caniuse_state.trace(runtime);
    try self.quickjs_state.trace(runtime);
    try self.native_plugin_state.trace(runtime);
}

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    program: ir.Program,
    /// Keep the initial program at a stable address while `program` is
    /// temporarily replaced by a dynamically compiled program.  IR function
    /// values use this owner to survive callbacks during that replacement.
    root_program: ir.Program,
    host: Host,
    globals: std.StringHashMapUnmanaged(Value) = .empty,
    global_names: std.ArrayList([]u8) = .empty,
    active_frame: ?*Frame = null,
    exception_value: Value = .undefined,
    system_context: Value = .undefined,
    call_depth: usize = 0,
    max_call_depth: usize = 4096,
    dynamic_depth: usize = 0,
    max_dynamic_depth: usize = 64,
    test_results: std.ArrayList(TestResult) = .empty,
    output_captures: std.ArrayList(*std.ArrayList(u8)) = .empty,
    print_pool: std.ArrayList(u8) = .empty,
    csv_state: plugin_csv.State,
    node_state: plugin_node.State = .{},
    http_server_state: plugin_http_server.State = .{},
    caniuse_state: plugin_caniuse.State = .{},
    quickjs_state: quickjs.State,
    native_plugin_state: plugin_native.State,
    timers: std.ArrayList(Timer) = .empty,
    promise_resolvers: std.AutoHashMapUnmanaged(*value_mod.Function, PromiseResolver) = .empty,
    promise_all_handlers: std.AutoHashMapUnmanaged(*value_mod.Function, PromiseAllHandler) = .empty,
    promise_all_states: std.ArrayList(*PromiseAllState) = .empty,
    elapsed_milliseconds: u64 = 0,
    next_timer_id: u64 = 1,
    event_count: usize = 0,
    max_event_count: usize = 100_000,
    courtesy_level: f64 = std.math.nan(f64),
    namespace_stack: std.ArrayList(NamespaceFrame) = .empty,
    hatena_callbacks: std.ArrayList(HatenaCallback) = .empty,
    current_span: ?ast.Span = null,
    current_source_path: []const u8 = "",
    debug_enabled: bool = false,
    system_initialized: bool = false,
    external_root_provider: bool = false,
    process_exit_reason: []const u8 = "process-exit",
    dispatch_trace: DispatchTrace = .{},
    compat_js_trace: CompatJsTrace = .{},
    global_trace: GlobalTrace = .{},
    literal_trace: LiteralTrace = .{},
    dispatch_route_stack: [64][]const u8 = undefined,
    dispatch_route_depth: usize = 0,
    dispatch_route_overflow: usize = 0,
    dynamic_programs: std.ArrayList(*ir.Program) = .empty,
    active_program_owner: ?*const ir.Program = null,

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime, program: ir.Program, host: Host) Interpreter {
        return .{ .allocator = allocator, .runtime = runtime, .program = program, .root_program = program, .host = host, .dispatch_trace = .{ .path = host.dispatch_trace_path, .context = host.context, .writeFn = host.dispatch_trace_writeFn }, .compat_js_trace = .{ .path = host.compat_js_trace_path, .context = host.context, .writeFn = host.compat_js_trace_writeFn }, .global_trace = .{ .path = host.global_trace_path, .context = host.context, .writeFn = host.global_trace_writeFn }, .literal_trace = .{ .path = host.literal_trace_path, .context = host.context, .writeFn = host.literal_trace_writeFn }, .csv_state = plugin_csv.State.init(allocator), .quickjs_state = quickjs.State.init(program.compat_js), .native_plugin_state = plugin_native.State.init() };
    }

    pub fn deinit(self: *Interpreter) void {
        self.deactivateExternalRuntime();
        self.runtime.clearPrimitiveHook(self);
        self.dispatch_trace.finish();
        self.compat_js_trace.finish();
        self.global_trace.finish();
        self.literal_trace.finish();
        // Native plugins may retain host handles and stop worker threads from
        // deinitialize, so tear them down while all interpreter services exist.
        self.native_plugin_state.deinit();
        self.globals.deinit(self.allocator);
        for (self.global_names.items) |name| self.allocator.free(name);
        self.global_names.deinit(self.allocator);
        for (self.test_results.items) |result| {
            self.allocator.free(result.name);
            if (result.message.len > 0) self.allocator.free(result.message);
        }
        self.test_results.deinit(self.allocator);
        self.output_captures.deinit(self.allocator);
        self.print_pool.deinit(self.allocator);
        self.csv_state.deinit();
        self.node_state.deinit(self.allocator);
        self.http_server_state.deinit(self.allocator);
        self.quickjs_state.deinit();
        self.timers.deinit(self.allocator);
        self.promise_resolvers.deinit(self.allocator);
        self.promise_all_handlers.deinit(self.allocator);
        for (self.promise_all_states.items) |state| self.allocator.destroy(state);
        self.promise_all_states.deinit(self.allocator);
        self.namespace_stack.deinit(self.allocator);
        self.hatena_callbacks.deinit(self.allocator);
        for (self.dynamic_programs.items) |program| {
            program.deinit();
            self.allocator.destroy(program);
        }
        self.dynamic_programs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn run(self: *Interpreter) !Value {
        return execute.run(self);
    }

    pub fn runTests(self: *Interpreter) ![]const TestResult {
        return execute.runTests(self);
    }

    pub fn getGlobal(self: Interpreter, name: []const u8) ?Value {
        return self.globals.get(name);
    }

    pub fn setGlobalValue(self: *Interpreter, name: []const u8, value: Value) !void {
        try self.setGlobal(name, value);
    }

    pub fn runDynamicSource(
        self: *Interpreter,
        source: []const u8,
        prepare: ?DynamicPreparationFn,
        context: ?*anyopaque,
    ) !Value {
        return execute.runDynamicSource(self, source, prepare, context);
    }

    pub fn activateExternalRuntime(self: *Interpreter) !void {
        self.ensurePrimitiveHook();
        const newly_registered = !self.external_root_provider;
        if (newly_registered) {
            try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
            self.external_root_provider = true;
        }
        self.initializeSystem() catch |failure| {
            if (newly_registered) {
                self.runtime.unregisterRootProvider(self);
                self.external_root_provider = false;
            }
            return failure;
        };
    }

    pub fn deactivateExternalRuntime(self: *Interpreter) void {
        if (!self.external_root_provider) return;
        self.runtime.unregisterRootProvider(self);
        self.external_root_provider = false;
    }

    pub fn callExternalCommand(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
        return plugins.callExternalCommand(self, name, arguments);
    }

    pub fn ensurePrimitiveHook(self: *Interpreter) void {
        self.runtime.setPrimitiveHook(.{ .context = self, .callFn = interpreterPrimitiveHook });
    }

    pub fn objectToPrimitive(self: *Interpreter, value: Value, hint: value_mod.PrimitiveHint) anyerror!?Value {
        return execute.objectToPrimitive(self, value, hint);
    }

    pub fn pollExternalPlugins(self: *Interpreter) !bool {
        return plugins.pollExternalPlugins(self);
    }

    pub fn runEntries(self: *Interpreter) !Value {
        return execute.runEntries(self);
    }

    pub fn executeFunction(self: *Interpreter, function: *const ir.Function, arguments: []const Value, closure: ?*value_mod.Function, owner_program: *const ir.Program) anyerror!Value {
        return execute.executeFunction(self, function, arguments, closure, owner_program);
    }

    pub fn errorMessageValue(self: *Interpreter, value: Value) !Value {
        return execute.errorMessageValue(self, value);
    }

    pub fn executeInstruction(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, predecessor: ?ir.BlockId) anyerror!void {
        return execute.executeInstruction(self, frame, instruction, predecessor);
    }

    pub fn operand(self: Interpreter, frame: *Frame, instruction: ir.Instruction, index: usize) Value {
        return execute.operand(self, frame, instruction, index);
    }

    pub fn bindLocal(self: *Interpreter, frame: *Frame, name: []const u8, value: Value) !void {
        return execute.bindLocal(self, frame, name, value);
    }

    pub fn storeLocal(self: *Interpreter, frame: *Frame, name: []const u8, value: Value) !void {
        return execute.storeLocal(self, frame, name, value);
    }

    pub fn executeDestructure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        return execute.executeDestructure(self, frame, instruction);
    }

    pub fn executeBinary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.executeBinary(self, frame, instruction);
    }

    pub fn executeUnary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.executeUnary(self, frame, instruction);
    }

    pub fn executeCall(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.executeCall(self, frame, instruction);
    }

    pub fn executeCallValue(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.executeCallValue(self, frame, instruction);
    }

    pub fn callFunctionValue(self: *Interpreter, function: *value_mod.Function, arguments: []const Value) !Value {
        return execute.callFunctionValue(self, function, arguments);
    }

    pub fn callIrFunctionValue(self: *Interpreter, function_id: ir.FunctionId, function: *value_mod.Function, arguments: []const Value) !Value {
        return execute.callIrFunctionValue(self, function_id, function, arguments);
    }

    pub fn systemContext(self: *Interpreter) !Value {
        if (self.system_context == .undefined) self.system_context = try self.runtime.createDictionary();
        return self.system_context;
    }

    pub fn callBuiltin(self: *Interpreter, name: []const u8, arguments: []const Value, site_id: ?u64) !Value {
        return plugins.callBuiltin(self, name, arguments, site_id);
    }

    pub fn beginDispatchRoute(self: *Interpreter) void {
        return plugins.beginDispatchRoute(self);
    }

    pub fn setDispatchRoute(self: *Interpreter, route: []const u8) void {
        return plugins.setDispatchRoute(self, route);
    }

    pub fn endDispatchRoute(self: *Interpreter) []const u8 {
        return plugins.endDispatchRoute(self);
    }

    pub fn callBuiltinImpl(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
        return plugins.callBuiltinImpl(self, name, arguments);
    }

    pub fn isDatetimePluginCommandName(name: []const u8) bool {
        return plugins.isDatetimePluginCommandName(name);
    }

    pub fn datetimePluginRouteEnabled() bool {
        return plugins.datetimePluginRouteEnabled();
    }

    pub fn initializeSystem(self: *Interpreter) !void {
        return plugins.initializeSystem(self);
    }

    pub fn stringArgument(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.stringArgument(self, arguments);
    }

    pub fn stringArray(self: *Interpreter, values: []const []const u8) !Value {
        return plugins.stringArray(self, values);
    }

    pub fn globalFunctionNames(self: *Interpreter) !Value {
        return plugins.globalFunctionNames(self);
    }

    pub fn defaultSystemNameExists(self: *Interpreter, arguments: []const Value) !bool {
        return plugins.defaultSystemNameExists(self, arguments);
    }

    pub fn primaryModuleName(self: Interpreter) []const u8 {
        const owner_program = self.currentProgramOwner();
        if (owner_program.module_entries.len == 0) return "";
        const id = owner_program.module_entries[0];
        if (id >= owner_program.functions.len) return "";
        const entry_name = owner_program.functions[id].name;
        const suffix = "__$entry";
        if (!std.mem.endsWith(u8, entry_name, suffix)) return "";
        return entry_name[0 .. entry_name.len - suffix.len];
    }

    pub fn currentProgramOwner(self: *const Interpreter) *const ir.Program {
        if (self.active_program_owner) |owner| return owner;
        if (self.active_frame) |frame| return frame.owner_program;
        return &self.root_program;
    }

    pub fn sourcePathForFunction(self: Interpreter, owner_program: *const ir.Program, function_name: []const u8) []const u8 {
        var best: ?usize = null;
        for (owner_program.module_names, 0..) |module_name, index| {
            if (index >= owner_program.module_paths.len or !std.mem.startsWith(u8, function_name, module_name)) continue;
            if (function_name.len <= module_name.len + 1 or !std.mem.eql(u8, function_name[module_name.len .. module_name.len + 2], "__")) continue;
            if (best == null or module_name.len > owner_program.module_names[best.?].len) best = index;
        }
        return if (best) |index| owner_program.module_paths[index] else self.current_source_path;
    }

    pub fn awaitExecute(self: *Interpreter, arguments: []const Value) !Value {
        return events.awaitExecute(self, arguments);
    }

    pub fn awaitValue(self: *Interpreter, value: Value) !Value {
        return events.awaitValue(self, value);
    }

    pub fn executeCallable(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.executeCallable(self, arguments);
    }

    pub fn measureCallable(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.measureCallable(self, arguments);
    }

    pub fn debugDisplay(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.debugDisplay(self, arguments);
    }

    pub fn normalizeDebugSourcePath(source_path: []const u8, windows: bool) []const u8 {
        return plugins.normalizeDebugSourcePath(source_path, windows);
    }

    pub fn configureHatena(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.configureHatena(self, arguments);
    }

    pub fn appendHatenaName(self: *Interpreter, name: Value) !void {
        return plugins.appendHatenaName(self, name);
    }

    pub fn invokeHatena(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.invokeHatena(self, arguments);
    }

    pub fn callNamedHatena(self: *Interpreter, name_value: Value, parameter: Value) !Value {
        return plugins.callNamedHatena(self, name_value, parameter);
    }

    pub fn debugBreakpointWait(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.debugBreakpointWait(self, arguments);
    }

    pub fn display(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.display(self, arguments);
    }

    pub fn continueDisplay(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.continueDisplay(self, arguments);
    }

    pub fn displayMany(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.displayMany(self, arguments);
    }

    pub fn continueDisplayMany(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.continueDisplayMany(self, arguments);
    }

    pub fn joinValues(self: *Interpreter, arguments: []const Value) !Value {
        return plugins.joinValues(self, arguments);
    }

    pub fn writeValues(self: *Interpreter, arguments: []const Value, all: bool) !void {
        return plugins.writeValues(self, arguments, all);
    }

    pub fn appendDisplayLog(self: *Interpreter, line: []const u8) !void {
        return plugins.appendDisplayLog(self, line);
    }

    pub fn pluginContext(self: *Interpreter) !plugin_system.Context {
        return plugins.pluginContext(self);
    }

    pub fn requestedExitCode(self: Interpreter) ?u8 {
        return self.node_state.requested_exit_code;
    }

    pub fn finishProcessExitTrace(self: *Interpreter) void {
        self.dispatch_trace.finishTerminal(self.process_exit_reason, self.requestedExitCode() orelse 0);
    }

    pub fn nodeEffects(self: *Interpreter) plugin_node.Effects {
        return plugins.nodeEffects(self);
    }

    pub fn httpServerEffects(self: *Interpreter) plugin_http_server.Effects {
        return plugins.httpServerEffects(self);
    }

    pub fn quickJsEffects(self: *Interpreter) quickjs.Effects {
        return plugins.quickJsEffects(self);
    }

    pub fn nativePluginEffects(self: *Interpreter) plugin_native.Effects {
        return plugins.nativePluginEffects(self);
    }

    pub fn nodeResolve(context: *anyopaque, value: Value) !Value {
        return plugins.nodeResolve(context, value);
    }

    pub fn nodeSetGlobal(context: *anyopaque, name: []const u8, value: Value) !void {
        return plugins.nodeSetGlobal(context, name, value);
    }

    pub fn nodeGetGlobal(context: *anyopaque, name: []const u8) ?Value {
        return plugins.nodeGetGlobal(context, name);
    }

    pub fn handleNodeInterrupt(self: *Interpreter) !void {
        return plugins.handleNodeInterrupt(self);
    }

    pub fn pluginRandom(context: *anyopaque) !f64 {
        return plugins.pluginRandom(context);
    }

    pub fn pluginCall(context: *anyopaque, callable: Value, arguments: []const Value) !Value {
        return plugins.pluginCall(context, callable, arguments);
    }

    pub fn pluginResolve(context: *anyopaque, name: []const u8) !Value {
        return plugins.pluginResolve(context, name);
    }

    pub fn quickJsResolve(context: *anyopaque, name: []const u8) !Value {
        return plugins.quickJsResolve(context, name);
    }

    pub fn quickJsExec(context: *anyopaque, name: []const u8, arguments: []const Value) !Value {
        return plugins.quickJsExec(context, name, arguments);
    }

    pub fn installSystemConstant(context: *anyopaque, name: []const u8, value: Value) !void {
        return plugins.installSystemConstant(context, name, value);
    }

    pub fn delayMilliseconds(self: *Interpreter, value: Value) !u64 {
        return events.delayMilliseconds(self, value);
    }

    pub fn scheduleTimer(self: *Interpreter, arguments: []const Value, repeating: bool) !Value {
        return events.scheduleTimer(self, arguments, repeating);
    }

    pub fn resolveCallback(self: *Interpreter, callback: Value) !Value {
        return events.resolveCallback(self, callback);
    }

    pub fn stopTimer(self: *Interpreter, timer_id: u64) bool {
        return events.stopTimer(self, timer_id);
    }

    pub fn createPromiseWithExecutor(self: *Interpreter, arguments: []const Value) !Value {
        return events.createPromiseWithExecutor(self, arguments);
    }

    pub fn createPromiseResolver(self: *Interpreter, promise: *value_mod.Promise, rejected: bool) !Value {
        return events.createPromiseResolver(self, promise, rejected);
    }

    pub fn removePromiseResolvers(self: *Interpreter, promise: *value_mod.Promise) !void {
        return events.removePromiseResolvers(self, promise);
    }

    pub fn chainPromise(self: *Interpreter, arguments: []const Value, kind: PromiseChainKind) !Value {
        return events.chainPromise(self, arguments, kind);
    }

    pub fn bundlePromises(self: *Interpreter, arguments: []const Value) !Value {
        return events.bundlePromises(self, arguments);
    }

    pub fn handlePromiseAll(self: *Interpreter, function: *value_mod.Function, handler: PromiseAllHandler, arguments: []const Value) !Value {
        return events.handlePromiseAll(self, function, handler, arguments);
    }

    pub fn destroyPromiseAllState(self: *Interpreter, state: *PromiseAllState) void {
        return events.destroyPromiseAllState(self, state);
    }

    pub fn drainEventLoop(self: *Interpreter) !void {
        return events.drainEventLoop(self);
    }

    pub fn waitMilliseconds(self: *Interpreter, milliseconds: u64) !void {
        return events.waitMilliseconds(self, milliseconds);
    }

    pub fn drainPromiseTasks(self: *Interpreter) !void {
        return events.drainPromiseTasks(self);
    }

    pub fn earliestTimerIndex(self: Interpreter) ?usize {
        return events.earliestTimerIndex(self);
    }

    pub fn executeTimer(self: *Interpreter, index: usize) !void {
        return events.executeTimer(self, index);
    }

    pub fn sleepUntil(self: *Interpreter, target: u64) !void {
        return events.sleepUntil(self, target);
    }

    pub fn sleepEventSlice(self: *Interpreter, milliseconds: u64) !void {
        return events.sleepEventSlice(self, milliseconds);
    }

    pub fn pollNodeCommands(self: *Interpreter) !bool {
        return events.pollNodeCommands(self);
    }

    pub fn pollHttpServer(self: *Interpreter) !bool {
        return events.pollHttpServer(self);
    }

    pub fn executePromiseTask(self: *Interpreter, task: value_mod.PromiseTask) !void {
        return events.executePromiseTask(self, task);
    }

    pub fn countEvent(self: *Interpreter) !void {
        return events.countEvent(self);
    }

    pub fn makeArray(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.makeArray(self, frame, instruction);
    }

    pub fn makeDictionary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.makeDictionary(self, frame, instruction);
    }

    pub fn getIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.getIndexed(self, frame, instruction);
    }

    pub fn getOne(self: *Interpreter, container: Value, key: Value) !Value {
        return execute.getOne(self, container, key);
    }

    pub fn setIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        return execute.setIndexed(self, frame, instruction);
    }

    pub fn increment(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        return execute.increment(self, frame, instruction);
    }

    pub fn makeClosure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.makeClosure(self, frame, instruction);
    }

    pub fn iteratorBegin(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.iteratorBegin(self, frame, instruction);
    }

    pub fn iteratorHasNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !bool {
        return execute.iteratorHasNext(self, frame, instruction);
    }

    pub fn iteratorNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        return execute.iteratorNext(self, frame, instruction);
    }

    pub fn executeDynamicValue(self: *Interpreter, source_value: Value) !Value {
        return execute.executeDynamicValue(self, source_value);
    }

    pub fn writeOutput(self: *Interpreter, bytes: []const u8) !void {
        try self.host.write(bytes);
        for (self.output_captures.items) |capture| try capture.appendSlice(self.allocator, bytes);
    }

    pub fn setGlobal(self: *Interpreter, name: []const u8, value: Value) !void {
        if (self.globals.getPtr(name)) |existing| {
            existing.* = value;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.globals.put(self.allocator, owned_name, value);
        errdefer _ = self.globals.remove(owned_name);
        try self.global_names.append(self.allocator, owned_name);
    }

    pub fn findFunction(_: Interpreter, owner_program: *const ir.Program, name: []const u8) ?*const ir.Function {
        for (owner_program.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;

        // The semantic analyzer qualifies module-level declarations as
        // `module__name`, while Nadesiko callback-taking commands receive the
        // source spelling as a string (for example, `"二倍"`).  Accept an
        // unqualified spelling only when it identifies exactly one function.
        var match: ?*const ir.Function = null;
        for (owner_program.functions) |*function| {
            const separator = std.mem.lastIndexOf(u8, function.name, "__") orelse continue;
            if (!std.mem.eql(u8, function.name[separator + 2 ..], name)) continue;
            if (match != null) return null;
            match = function;
        }
        return match;
    }
};
