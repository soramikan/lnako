const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const builtin = shared.builtin;
const aot_builtin = shared.aot_builtin;
const dynamic_value = shared.dynamic_value;
const error_message = shared.error_message;
const dynamic_interpreter = shared.dynamic_interpreter;
const toml_temporal = shared.toml_temporal;
const crypto = shared.crypto;
const BigInt = shared.BigInt;
const Tag = aot_state.Tag;
const DispatchTrace = aot_state.DispatchTrace;
const GlobalTrace = aot_state.GlobalTrace;
const LiteralTrace = aot_state.LiteralTrace;
const DynamicGlobal = aot_state.DynamicGlobal;
const DynamicPromiseBridge = aot_state.DynamicPromiseBridge;
const AotFunctionBridge = aot_state.AotFunctionBridge;
const DynamicInterpreterState = aot_state.DynamicInterpreterState;
const numberValue = aot_state.numberValue;
const staticStringValue = aot_state.staticStringValue;
const runtimeFailure = aot_state.runtimeFailure;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueIndex = aot_state.valueIndex;
const sameKey = aot_state.sameKey;
const staticUtf8 = aot_state.staticUtf8;
const staticUtf8EqualsUtf16 = aot_state.staticUtf8EqualsUtf16;
const repeatCount = aot_state.repeatCount;
const aotByteBufferAllowsStandardPrototype = aot_state.aotByteBufferAllowsStandardPrototype;
const aotByteBufferScalarProperty = aot_state.aotByteBufferScalarProperty;
const aotByteBufferReadOnlyProperty = aot_state.aotByteBufferReadOnlyProperty;
const dictionaryOwnProperty = aot_state.dictionaryOwnProperty;
const tableInheritedProperty = aot_state.tableInheritedProperty;
const tablePropertyIndex = aot_state.tablePropertyIndex;
const tableRowProperty = aot_state.tableRowProperty;
const aotFileCopyMoveWithIo = aot_state.aotFileCopyMoveWithIo;
const aotRuntimeIo = aot_state.aotRuntimeIo;
const runAotShellCommand = aot_state.runAotShellCommand;
const shouldRegisterNamedFunction = aot_state.shouldRegisterNamedFunction;
const promiseSentinel = aot_state.promiseSentinel;
const byteBufferUnboundSliceCallback = aot_state.byteBufferUnboundSliceCallback;
const safe_array_element_limit = aot_state.safe_array_element_limit;
const aot_timer_event_limit = aot_state.aot_timer_event_limit;

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.payload == 0) return null;
        return switch (@as(Tag, @enumFromInt(self.tag))) {
            .utf16_string, .array, .dictionary, .iterator, .bigint, .function, .binding_cell, .byte_buffer, .promise => @ptrFromInt(self.payload),
            else => null,
        };
    }
};

pub const RootFrame = extern struct {
    previous: ?*RootFrame = null,
    values: ?[*]Value = null,
    len: usize = 0,
};

pub const DictionaryEntry = struct { key: Value, value: Value };
pub const AotTomlTemporal = struct {
    kind: toml_temporal.Kind,
    json_text: []u8,
    toml_text: []u8,

    pub fn deinit(self: *AotTomlTemporal, allocator: std.mem.Allocator) void {
        allocator.free(self.json_text);
        allocator.free(self.toml_text);
        self.* = undefined;
    }
};
pub const ByteKind = enum { buffer, uint8_array, array_buffer };
const ByteStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    ref_count: usize = 1,
    /// Keep one stable ArrayBuffer wrapper for all views sharing this storage.
    /// The Value is traced from each live byte-buffer object below.
    backing: Value = .{},

    pub fn retain(self: *ByteStorage) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count += 1;
    }

    pub fn release(self: *ByteStorage) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

pub const ByteBuffer = struct {
    bytes: []u8,
    kind: ByteKind,
    storage: *ByteStorage,
    /// Offset of this view from the beginning of the shared backing storage.
    /// This remains meaningful for zero-length views, where pointer arithmetic
    /// alone cannot recover the original subarray position.
    byte_offset: usize = 0,
};
pub const AotTimer = struct {
    id: u64,
    due_milliseconds: u64,
    interval_milliseconds: u64,
    repeating: bool,
    callback: Value,
};
const IteratorKind = enum { repeat, range, bytes, string, array, dictionary };
const Iterator = struct {
    kind: IteratorKind,
    source: Value = .{},
    index: usize = 0,
    count: usize = 0,
    current: f64 = 0,
    end: f64 = 0,
    step: f64 = 1,
};

pub const AotPromiseState = enum { pending, fulfilled, rejected };
pub const AotPromiseReactionMode = enum { standard, settled_pair, finally };

pub const AotPromiseReaction = struct {
    on_fulfilled: Value = .{},
    on_rejected: Value = .{},
    next: *Object,
    mode: AotPromiseReactionMode = .standard,
    target_global: ?*Value = null,
};

const AotPromise = struct {
    state: AotPromiseState = .pending,
    result: Value = .{},
    reactions: std.ArrayList(AotPromiseReaction) = .empty,
};

pub const AotPromiseTask = struct {
    callback: Value,
    settled_value: Value,
    rejected: bool,
    next: *Object,
    mode: AotPromiseReactionMode,
    target_global: ?*Value,
};

pub const AotPromiseAllState = struct {
    promise: *Object,
    results: Value,
    remaining: usize = 0,
};

pub const AotPromiseResolver = struct {
    promise: *Object,
    rejected: bool,
};

pub const AotPromiseAllHandler = struct {
    state: *AotPromiseAllState,
    index: usize,
    rejected: bool,
};

const PromiseFunctionKind = union(enum) {
    none,
    resolver: AotPromiseResolver,
    all_handler: AotPromiseAllHandler,
};

pub const AotPromiseChainKind = enum { success, failure, settled, finally };

/// Generated callbacks cross the Zig/LLVM boundary. Returning the 16-byte
/// Value aggregate directly is not portable to the Windows x64 C ABI, so the
/// result is always written through an explicit pointer.
pub const FunctionCallback = *const fn (*Value, *anyopaque, ?[*]const Value, usize) callconv(.c) void;
const FunctionObject = struct {
    callback: FunctionCallback,
    arity: usize,
    /// The generated wrapper name is retained as UTF-8 bytes so converting a
    /// function value to a string can preserve the same observable name that
    /// the interpreter exposes. The slice is owned by the function object.
    name: []u8,
    captures: []Value,
    promise_kind: PromiseFunctionKind = .none,
    /// Ordinary generated functions expose one stable prototype object.  It
    /// is created lazily by the table property resolver and points back to
    /// the function through its own `constructor` property.
    prototype: Value = .{},
};

const AotHttpRouteKind = enum { static, callback };

pub const AotHttpRoute = struct {
    kind: AotHttpRouteKind,
    prefix: []u8,
    path: []u8 = &.{},
    callback: Value = .{},

    pub fn deinit(self: *AotHttpRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        if (self.path.len > 0) allocator.free(self.path);
        self.* = undefined;
    }
};

pub const AotHttpHeader = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: *AotHttpHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const AotHttpServerState = struct {
    routes: std.ArrayList(AotHttpRoute) = .empty,
    response_headers: std.ArrayList(AotHttpHeader) = .empty,
    started: bool = false,
    request_active: bool = false,
    response_status: u16 = 200,

    pub fn deinit(self: *AotHttpServerState, allocator: std.mem.Allocator) void {
        for (self.routes.items) |*route| route.deinit(allocator);
        self.routes.deinit(allocator);
        self.clearHeaders(allocator);
        self.response_headers.deinit(allocator);
        self.* = undefined;
    }

    pub fn clearHeaders(self: *AotHttpServerState, allocator: std.mem.Allocator) void {
        for (self.response_headers.items) |*header| header.deinit(allocator);
        self.response_headers.clearRetainingCapacity();
    }
};

pub const AotArchiveOperation = enum { create, extract };

pub const AotArchiveTask = struct {
    operation: AotArchiveOperation,
    use_external_tool: bool,
    source: []u8,
    destination: []u8,
    tool_path: []u8,
    callback: Value,

    pub fn deinit(self: *AotArchiveTask, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.destination);
        allocator.free(self.tool_path);
        self.* = undefined;
    }
};

pub const AotProcessMode = enum { command_output, output_callback };

pub const AotCommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *AotCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const AotProcessTask = struct {
    runtime: *Runtime,
    command: []u8,
    cwd: []u8,
    mode: AotProcessMode,
    callback: Value = .{},
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: u64 = 0,
    result: ?AotCommandResult = null,
    failure: ?anyerror = null,

    pub fn run(self: *@This()) void {
        const result = runAotShellCommand(self.runtime, self.command, self.cwd) catch |failure| {
            self.failure = failure;
            self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
            self.complete.store(true, .release);
            return;
        };
        self.result = result;
        self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
        self.complete.store(true, .release);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, join: bool) void {
        if (join) if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit(allocator);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.destroy(self);
    }
};

pub const AotFileTaskOperation = enum { copy, move, delete };

pub const AotFileTask = struct {
    runtime: *Runtime,
    operation: AotFileTaskOperation,
    source: []u8,
    destination: []u8,
    overwrite: bool,
    callback: Value = .{},
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: u64 = 0,
    failure: ?anyerror = null,

    pub fn run(self: *@This()) void {
        const io = aotRuntimeIo(self.runtime);
        const result = switch (self.operation) {
            .copy => aotFileCopyMoveWithIo(self.runtime, io, self.source, self.destination, self.overwrite, false),
            .move => aotFileCopyMoveWithIo(self.runtime, io, self.source, self.destination, self.overwrite, true),
            .delete => std.Io.Dir.cwd().deleteTree(io, self.source),
        };
        if (result) |_| {} else |failure| self.failure = failure;
        self.completion_order = self.runtime.process_completion_sequence.fetchAdd(1, .monotonic);
        self.complete.store(true, .release);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, join: bool) void {
        if (join) if (self.thread) |thread| thread.join();
        allocator.free(self.source);
        allocator.free(self.destination);
        allocator.destroy(self);
    }
};

pub const AotClientHttpResult = struct {
    body: []u8,
    status: u16 = 0,
    content_length_zero: bool = false,
    failure: ?anyerror = null,

    pub fn deinit(self: *AotClientHttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const AotClientHttpMode = enum { callback, set_target, response_promise };

pub const AotClientHttpBodyKind = enum { text, json, binary };

pub const AotClientHttpTask = struct {
    result: AotClientHttpResult,
    mode: AotClientHttpMode,
    callback: Value = .{},
    promise: Value = .{},
    target: ?*Value = null,
    onerror: ?*Value = null,

    pub fn deinit(self: *AotClientHttpTask, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

const AotHttpGlobals = struct {
    method: ?*Value = null,
    get_data: ?*Value = null,
    post_data: ?*Value = null,
    files_data: ?*Value = null,
};

pub const AotCsvDelimiterDefault = enum { comma, tab };

const aot_csv_comma = [_]u16{','};
const aot_csv_tab = [_]u16{'\t'};
const aot_csv_crlf = [_]u16{ '\r', '\n' };

pub const default_plugin_names = [_][]const u8{
    "plugin_system",
    "plugin_math",
    "plugin_promise",
    "plugin_test",
    "plugin_csv",
    "plugin_toml",
    "plugin_node",
};

/// CSV options are process-local in the official plugin. Keep the same
/// lifetime as the AOT runtime so separate builtin calls observe updates from
/// CSVオプション設定 without introducing a JavaScript runtime.
pub const AotCsvState = struct {
    custom_delimiter: ?[]u16 = null,
    custom_eol: ?[]u16 = null,
    delimiter_default: AotCsvDelimiterDefault = .comma,
    auto_convert_number: bool = true,

    pub fn deinit(self: *AotCsvState, allocator: std.mem.Allocator) void {
        if (self.custom_delimiter) |value| allocator.free(value);
        if (self.custom_eol) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn delimiter(self: *const AotCsvState) []const u16 {
        return self.custom_delimiter orelse switch (self.delimiter_default) {
            .comma => &aot_csv_comma,
            .tab => &aot_csv_tab,
        };
    }

    pub fn eol(self: *const AotCsvState) []const u16 {
        return self.custom_eol orelse &aot_csv_crlf;
    }

    pub fn useDelimiter(self: *AotCsvState, allocator: std.mem.Allocator, value: AotCsvDelimiterDefault) void {
        if (self.custom_delimiter) |owned| allocator.free(owned);
        self.custom_delimiter = null;
        self.delimiter_default = value;
    }

    pub fn setDelimiter(self: *AotCsvState, allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_delimiter) |old| allocator.free(old);
        self.custom_delimiter = owned;
    }

    pub fn setEol(self: *AotCsvState, allocator: std.mem.Allocator, value: []const u16) !void {
        const owned = try allocator.dupe(u16, value);
        if (self.custom_eol) |old| allocator.free(old);
        self.custom_eol = owned;
    }
};

pub const Arithmetic = enum(u8) {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    power,
    integer_divide,
    bit_and,
    bit_or,
    bit_xor,
};

pub const Comparison = enum(u8) {
    abstract_equal,
    strict_equal,
    abstract_not_equal,
    strict_not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    deep_equal,
    deep_not_equal,
};

pub const ShiftOperator = enum(u8) {
    left,
    right,
    right_unsigned,
};

const Payload = union(enum) {
    utf16_string: []u16,
    byte_buffer: ByteBuffer,
    bigint: BigInt,
    array: std.ArrayList(Value),
    dictionary: std.ArrayList(DictionaryEntry),
    iterator: Iterator,
    function: FunctionObject,
    binding_cell: Value,
    promise: AotPromise,
};

pub const Object = struct {
    next: ?*Object = null,
    grey_next: ?*Object = null,
    marked: bool = false,
    /// Object-literal `__proto__`; the undefined value means the ordinary
    /// Object prototype and explicit null preserves a null-prototype object.
    prototype: Value = .{},
    /// Own properties for arrays and for the other extensible object kinds.
    /// The legacy field name is retained because array operations and their
    /// serialized fixtures already use it.
    array_properties: std.ArrayList(DictionaryEntry) = .empty,
    array_presence: std.ArrayList(bool) = .empty,
    toml_temporal: ?AotTomlTemporal = null,
    payload: Payload,
};

const RegisteredFunction = struct {
    name: []u8,
    object: *Object,
};

const NamespaceFrame = struct {
    namespace: Value,
    plugin_name: Value,
};

/// Standard prototype values are singletons within one generated runtime.
/// Keep lazily synthesized property values alive and reuse them on subsequent
/// reads so AOT identity comparisons match the JavaScript prototype chain.
const StandardPropertyCacheEntry = struct {
    kind: u8,
    name: []u8,
    value: Value,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    objects: ?*Object = null,
    roots: ?*RootFrame = null,
    grey: ?*Object = null,
    object_count: usize = 0,
    next_collection: usize = 64,
    stringifying_arrays: std.ArrayList(*Object) = .empty,
    pending_exception: Value = .{},
    has_pending_exception: bool = false,
    /// Monotonic-with-wrap generation of the pending failure slot. Dispatch
    /// tracing compares this value at call boundaries so an exception left by
    /// an earlier call does not make a later successful call look failed.
    failure_epoch: u64 = 0,
    system_context: Value = .{},
    courtesy_level: f64 = std.math.nan(f64),
    print_pool: std.ArrayList(u8) = .empty,
    dispatch_trace: DispatchTrace = .{},
    global_trace: GlobalTrace = .{},
    literal_trace: LiteralTrace = .{},
    random_state: u64 = 0,
    clock_milliseconds: ?i64 = null,
    monotonic_milliseconds: ?f64 = null,
    debug_enabled: bool = false,
    aot_source_directory: ?[]u8 = null,
    caniuse_browsers: Value = .{},
    caniuse_agents: Value = .{},
    era_data: Value = .{},
    csv_state: AotCsvState = .{},
    namespace_stack: std.ArrayList(NamespaceFrame) = .empty,
    named_functions: std.ArrayList(RegisteredFunction) = .empty,
    hatena_callbacks: std.ArrayList(Value) = .empty,
    interrupt_callback: Value = .{},
    timers: std.ArrayList(AotTimer) = .empty,
    promise_tasks: std.ArrayList(AotPromiseTask) = .empty,
    promise_all_states: std.ArrayList(*AotPromiseAllState) = .empty,
    elapsed_milliseconds: u64 = 0,
    next_timer_id: u64 = 1,
    timer_event_count: usize = 0,
    stdin_bytes: ?[]u8 = null,
    stdin_offset: usize = 0,
    http_server_state: AotHttpServerState = .{},
    http_server: ?std.Io.net.Server = null,
    http_connection: ?std.Io.net.Stream = null,
    http_head_request: bool = false,
    held_http_connections: std.ArrayList(std.Io.net.Stream) = .empty,
    upload_sequence: u64 = 1,
    http_globals: ?AotHttpGlobals = null,
    archive_tool_path_custom: bool = false,
    archive_tasks: std.ArrayList(AotArchiveTask) = .empty,
    client_http_tasks: std.ArrayList(AotClientHttpTask) = .empty,
    file_process_callback: Value = .{},
    file_process_target: ?*Value = null,
    file_process_stop: bool = false,
    file_tasks: std.ArrayList(*AotFileTask) = .empty,
    process_tasks: std.ArrayList(*AotProcessTask) = .empty,
    process_completion_sequence: std.atomic.Value(u64) = .init(1),
    process_io: std.Io.Threaded = .init_single_threaded,
    process_io_initialized: bool = false,
    native_plugin_paths: std.ArrayList([]u8) = .empty,
    dynamic_globals: std.ArrayList(DynamicGlobal) = .empty,
    dynamic_state: ?*DynamicInterpreterState = null,
    dynamic_promise_bridges: std.ArrayList(*DynamicPromiseBridge) = .empty,
    dynamic_function_bridges: std.ArrayList(*AotFunctionBridge) = .empty,
    standard_property_cache: std.ArrayList(StandardPropertyCacheEntry) = .empty,

    pub fn deinit(self: *Runtime) void {
        self.dispatch_trace.deinit();
        self.global_trace.deinit();
        self.literal_trace.deinit();
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.http_connection) |*stream| stream.close(io);
        for (self.held_http_connections.items) |*stream| stream.close(io);
        self.held_http_connections.deinit(self.allocator);
        if (self.http_server) |*server| server.deinit(io);
        self.http_server_state.deinit(self.allocator);
        for (self.archive_tasks.items) |*task| task.deinit(self.allocator);
        self.archive_tasks.deinit(self.allocator);
        while (self.client_http_tasks.pop()) |task| {
            var owned = task;
            owned.deinit(self.allocator);
        }
        self.client_http_tasks.deinit(self.allocator);
        while (self.file_tasks.pop()) |task| task.deinit(self.allocator, true);
        self.file_tasks.deinit(self.allocator);
        while (self.process_tasks.pop()) |task| task.deinit(self.allocator, true);
        self.process_tasks.deinit(self.allocator);
        if (self.process_io_initialized) self.process_io.deinit();
        if (self.dynamic_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        for (self.dynamic_promise_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_promise_bridges.deinit(self.allocator);
        for (self.dynamic_function_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_function_bridges.deinit(self.allocator);
        for (self.standard_property_cache.items) |entry| self.allocator.free(entry.name);
        self.standard_property_cache.deinit(self.allocator);
        for (self.native_plugin_paths.items) |path| self.allocator.free(path);
        self.native_plugin_paths.deinit(self.allocator);
        for (self.dynamic_globals.items) |entry| self.allocator.free(entry.name);
        self.dynamic_globals.deinit(self.allocator);
        self.csv_state.deinit(self.allocator);
        self.print_pool.deinit(self.allocator);
        self.namespace_stack.deinit(self.allocator);
        self.hatena_callbacks.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.promise_tasks.deinit(self.allocator);
        for (self.promise_all_states.items) |state| self.allocator.destroy(state);
        self.promise_all_states.deinit(self.allocator);
        if (self.stdin_bytes) |bytes| self.allocator.free(bytes);
        if (self.aot_source_directory) |path| self.allocator.free(path);
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.destroyObject(object);
            current = next;
        }
        self.named_functions.deinit(self.allocator);
        self.stringifying_arrays.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn cachedStandardProperty(self: *Runtime, kind: u8, name: []const u8) ?Value {
        for (self.standard_property_cache.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn cacheStandardProperty(self: *Runtime, kind: u8, name: []const u8, value: Value) !void {
        if (self.cachedStandardProperty(kind, name) != null) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.standard_property_cache.append(self.allocator, .{ .kind = kind, .name = owned_name, .value = value });
    }

    pub fn createString(self: *Runtime, units: []const u16) !Value {
        try self.beforeAllocation();
        const owned = try self.allocator.dupe(u16, units);
        errdefer self.allocator.free(owned);
        return self.createObject(.{ .utf16_string = owned }, .utf16_string);
    }

    pub fn createBytes(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .buffer);
    }

    pub fn createUint8Array(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .uint8_array);
    }

    pub fn createArrayBuffer(self: *Runtime, bytes: []const u8) !Value {
        return self.createByteBuffer(bytes, .array_buffer);
    }

    pub fn createByteStorage(self: *Runtime, bytes: []const u8) !*ByteStorage {
        const storage = try self.allocator.create(ByteStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = .{ .allocator = self.allocator, .bytes = try self.allocator.dupe(u8, bytes) };
        return storage;
    }

    pub fn createByteBuffer(self: *Runtime, bytes: []const u8, kind: ByteKind) !Value {
        try self.beforeAllocation();
        const storage = try self.createByteStorage(bytes);
        errdefer storage.release();
        return self.createObject(.{ .byte_buffer = .{ .bytes = storage.bytes, .kind = kind, .storage = storage } }, .byte_buffer);
    }

    pub fn createByteBufferView(self: *Runtime, buffer: ByteBuffer, start: usize, end: usize) !Value {
        if (start > end or end > buffer.bytes.len) return error.InvalidByteBufferSlice;
        const storage = buffer.storage;
        const bytes = buffer.bytes[start..end];
        const kind = buffer.kind;
        const byte_offset = std.math.add(usize, buffer.byte_offset, start) catch return error.InvalidByteBufferSlice;
        // Retain before a possible collection so the source object may be
        // reclaimed without invalidating the view's backing allocation.
        storage.retain();
        errdefer storage.release();
        try self.beforeAllocation();
        return self.createObject(.{ .byte_buffer = .{ .bytes = bytes, .kind = kind, .storage = storage, .byte_offset = byte_offset } }, .byte_buffer);
    }

    /// Return the complete backing allocation as an ArrayBuffer view.  Keep
    /// the storage shared so a Buffer/Uint8Array and its `.buffer` observe the
    /// same bytes; the caller's GC roots keep the source live while allocating.
    pub fn createByteBufferBackingBuffer(self: *Runtime, buffer: ByteBuffer) !Value {
        const storage = buffer.storage;
        if (storage.backing.tag != @intFromEnum(Tag.undefined)) return storage.backing;
        storage.retain();
        errdefer storage.release();
        try self.beforeAllocation();
        const result = try self.createObject(.{ .byte_buffer = .{ .bytes = storage.bytes, .kind = .array_buffer, .storage = storage } }, .byte_buffer);
        storage.backing = result;
        return result;
    }

    pub fn setAotSourceDirectory(self: *Runtime, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.aot_source_directory) |previous| self.allocator.free(previous);
        self.aot_source_directory = owned;
    }

    pub fn ownString(self: *Runtime, source: []u16) !Value {
        errdefer self.allocator.free(source);
        try self.beforeAllocation();
        return self.createObject(.{ .utf16_string = source }, .utf16_string);
    }

    pub fn createBigInt(self: *Runtime, source: []const u8) !Value {
        try self.beforeAllocation();
        var value = try BigInt.parseLiteral(self.allocator, source);
        errdefer value.deinit();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    pub fn ownBigInt(self: *Runtime, source: BigInt) !Value {
        var value = source;
        errdefer value.deinit();
        try self.beforeAllocation();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    pub fn createArray(self: *Runtime, values: []const Value) !Value {
        try self.beforeAllocation();
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);
        try items.appendSlice(self.allocator, values);
        return self.createObject(.{ .array = items }, .array);
    }

    pub fn createDictionary(self: *Runtime, values: []const Value) !Value {
        var source_frame = RootFrame{};
        self.pushRoots(&source_frame, if (values.len == 0) null else @constCast(values.ptr), values.len);
        defer self.popRoots(&source_frame);
        try self.beforeAllocation();
        var roots = [_]Value{ try self.createObject(.{ .dictionary = .empty }, .dictionary), .{}, .{} };
        var result_frame = RootFrame{};
        self.pushRoots(&result_frame, &roots, roots.len);
        defer self.popRoots(&result_frame);
        var index: usize = 0;
        while (index + 1 < values.len) : (index += 2) {
            roots[1] = values[index];
            roots[2] = values[index + 1];
            roots[1] = try self.propertyKey(roots[1]);
            try self.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
        return roots[0];
    }

    pub fn createTomlTemporal(self: *Runtime, kind: toml_temporal.Kind, json_text: []const u8, toml_text: []const u8) !Value {
        try self.beforeAllocation();
        const owned_json = try self.allocator.dupe(u8, json_text);
        errdefer self.allocator.free(owned_json);
        const owned_toml = try self.allocator.dupe(u8, toml_text);
        errdefer self.allocator.free(owned_toml);
        const result = try self.createObject(.{ .dictionary = .empty }, .dictionary);
        result.object().?.toml_temporal = .{ .kind = kind, .json_text = owned_json, .toml_text = owned_toml };
        return result;
    }

    pub fn createObjectLiteral(self: *Runtime, values: []const Value) !Value {
        var source_frame = RootFrame{};
        self.pushRoots(&source_frame, if (values.len == 0) null else @constCast(values.ptr), values.len);
        defer self.popRoots(&source_frame);

        var roots = [_]Value{ try self.createDictionary(&.{}), .{}, .{} };
        var result_frame = RootFrame{};
        self.pushRoots(&result_frame, &roots, roots.len);
        defer self.popRoots(&result_frame);
        var index: usize = 0;
        while (index + 1 < values.len) : (index += 2) {
            roots[1] = try self.propertyKey(values[index]);
            roots[2] = values[index + 1];
            if (sameKey(roots[1], staticStringValue("__proto__"))) {
                if (roots[2].tag == @intFromEnum(Tag.null_value) or roots[2].object() != null) {
                    roots[0].object().?.prototype = roots[2];
                }
            } else try self.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
        return roots[0];
    }

    pub fn createIterator(self: *Runtime, values: []const Value, is_range: bool, direction: u8) !Value {
        if (values.len == 0) return error.InvalidIterator;
        try self.beforeAllocation();
        const iterator: Iterator = if (is_range) blk: {
            if (values.len < 2) return error.InvalidIterator;
            const start = valueToNumber(values[0]);
            const end = valueToNumber(values[1]);
            var step: f64 = if (values.len >= 3 and values[2].tag != @intFromEnum(Tag.undefined))
                valueToNumber(values[2])
            else if (direction == 2 or (direction == 0 and start > end)) -1 else 1;
            if (direction == 2 and step > 0) step = -step;
            if (direction == 1 and step < 0) step = -step;
            if (!std.math.isFinite(start) or !std.math.isFinite(end)) return error.InvalidIteratorRange;
            if (!std.math.isFinite(step) or step == 0) return error.InvalidIteratorStep;
            break :blk .{ .kind = .range, .current = start, .end = end, .step = step };
        } else switch (@as(Tag, @enumFromInt(values[0].tag))) {
            .number => .{ .kind = .repeat, .count = try repeatCount(valueToNumber(values[0])) },
            .utf16_string => .{ .kind = .string, .source = values[0], .count = values[0].object().?.payload.utf16_string.len },
            .byte_buffer => .{ .kind = .bytes, .source = values[0], .count = values[0].object().?.payload.byte_buffer.bytes.len },
            .array => .{ .kind = .array, .source = values[0], .count = values[0].object().?.payload.array.items.len },
            .dictionary => .{ .kind = .dictionary, .source = values[0], .count = values[0].object().?.payload.dictionary.items.len },
            else => .{ .kind = .repeat, .count = 0 },
        };
        return self.createObject(.{ .iterator = iterator }, .iterator);
    }

    pub fn createFunction(self: *Runtime, callback: FunctionCallback, arity: usize, captures: []const Value) !Value {
        return self.createNamedFunction(callback, arity, &.{}, captures);
    }

    pub fn createNamedFunction(self: *Runtime, callback: FunctionCallback, arity: usize, name: []const u8, captures: []const Value) !Value {
        return self.createFunctionObject(callback, arity, name, captures, true, .none);
    }

    pub fn createMethodFunction(self: *Runtime, callback: FunctionCallback, arity: usize, name: []const u8, captures: []const Value) !Value {
        return self.createFunctionObject(callback, arity, name, captures, false, .none);
    }

    pub fn createFunctionObject(
        self: *Runtime,
        callback: FunctionCallback,
        arity: usize,
        name: []const u8,
        captures: []const Value,
        register_global: bool,
        promise_kind: PromiseFunctionKind,
    ) !Value {
        var frame: RootFrame = .{};
        self.pushRoots(&frame, if (captures.len > 0) @constCast(captures.ptr) else null, captures.len);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        const result = blk: {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_captures = try self.allocator.dupe(Value, captures);
            errdefer self.allocator.free(owned_captures);
            break :blk try self.createObject(.{ .function = .{ .callback = callback, .arity = arity, .name = owned_name, .captures = owned_captures, .promise_kind = promise_kind } }, .function);
        };
        if (register_global and shouldRegisterNamedFunction(name)) {
            const registered_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(registered_name);
            try self.named_functions.append(self.allocator, .{ .name = registered_name, .object = result.object().? });
        }
        return result;
    }

    pub fn createPromiseSpecialFunction(self: *Runtime, name: []const u8, promise_kind: PromiseFunctionKind) !Value {
        return self.createFunctionObject(promiseSentinel, 1, name, &.{}, false, promise_kind);
    }

    pub fn createBindingCell(self: *Runtime, initial: Value) !Value {
        var rooted = initial;
        var frame: RootFrame = .{};
        self.pushRoots(&frame, @ptrCast(&rooted), 1);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        return self.createObject(.{ .binding_cell = rooted }, .binding_cell);
    }

    pub fn createObject(self: *Runtime, payload: Payload, tag: Tag) !Value {
        const object = try self.allocator.create(Object);
        errdefer {
            object.array_presence.deinit(self.allocator);
            self.allocator.destroy(object);
        }
        object.* = .{
            .next = self.objects,
            .payload = payload,
        };
        if (tag == .array) {
            try object.array_presence.resize(self.allocator, object.payload.array.items.len);
            @memset(object.array_presence.items, true);
        }
        self.objects = object;
        self.object_count += 1;
        return .{ .tag = @intFromEnum(tag), .payload = @intFromPtr(object) };
    }

    pub fn beforeAllocation(self: *Runtime) !void {
        if (self.object_count < self.next_collection) return;
        _ = self.collect();
        self.next_collection = @max(@as(usize, 64), self.object_count * 2);
    }

    pub fn pushRoots(self: *Runtime, frame: *RootFrame, values: ?[*]Value, len: usize) void {
        frame.* = .{ .previous = self.roots, .values = values, .len = len };
        self.roots = frame;
    }

    pub fn popRoots(self: *Runtime, frame: *RootFrame) void {
        if (self.roots != frame) return;
        self.roots = frame.previous;
        frame.* = .{};
    }

    pub fn collect(self: *Runtime) usize {
        var frame = self.roots;
        while (frame) |current| : (frame = current.previous) {
            if (current.values) |values| for (values[0..current.len]) |value| self.markValue(value);
        }
        if (self.has_pending_exception) self.markValue(self.pending_exception);
        self.markValue(self.system_context);
        for (self.dynamic_globals.items) |entry| self.markValue(entry.value);
        for (self.dynamic_promise_bridges.items) |bridge| self.markValue(bridge.aot_promise);
        for (self.dynamic_function_bridges.items) |bridge| self.markValue(bridge.value);
        self.markValue(self.caniuse_browsers);
        self.markValue(self.caniuse_agents);
        self.markValue(self.era_data);
        for (self.namespace_stack.items) |entry| {
            self.markValue(entry.namespace);
            self.markValue(entry.plugin_name);
        }
        for (self.hatena_callbacks.items) |callback| self.markValue(callback);
        self.markValue(self.interrupt_callback);
        for (self.timers.items) |timer| self.markValue(timer.callback);
        for (self.promise_tasks.items) |task| {
            self.markValue(task.callback);
            self.markValue(task.settled_value);
            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(task.next) });
        }
        for (self.promise_all_states.items) |state| {
            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(state.promise) });
            self.markValue(state.results);
        }
        for (self.http_server_state.routes.items) |route| {
            if (route.kind == .callback) self.markValue(route.callback);
        }
        for (self.archive_tasks.items) |task| self.markValue(task.callback);
        for (self.client_http_tasks.items) |task| {
            self.markValue(task.callback);
            self.markValue(task.promise);
            if (task.target) |target| self.markValue(target.*);
            if (task.onerror) |onerror| self.markValue(onerror.*);
        }
        self.markValue(self.file_process_callback);
        for (self.file_tasks.items) |task| self.markValue(task.callback);
        for (self.process_tasks.items) |task| self.markValue(task.callback);
        for (self.standard_property_cache.items) |entry| self.markValue(entry.value);
        while (self.grey) |object| {
            self.grey = object.grey_next;
            object.grey_next = null;
            switch (object.payload) {
                .utf16_string, .bigint => {},
                .byte_buffer => {
                    self.markValue(object.prototype);
                    self.markValue(object.payload.byte_buffer.storage.backing);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .function => |function| {
                    self.markValue(function.prototype);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                    for (function.captures) |capture| self.markValue(capture);
                    switch (function.promise_kind) {
                        .none => {},
                        .resolver => |resolver| self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(resolver.promise) }),
                        .all_handler => |handler| {
                            self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(handler.state.promise) });
                            self.markValue(handler.state.results);
                        },
                    }
                },
                .binding_cell => |value| self.markValue(value),
                .array => |items| {
                    self.markValue(object.prototype);
                    for (items.items) |value| self.markValue(value);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .dictionary => |entries| {
                    self.markValue(object.prototype);
                    for (entries.items) |entry| {
                        self.markValue(entry.key);
                        self.markValue(entry.value);
                    }
                },
                .iterator => |iterator| self.markValue(iterator.source),
                .promise => |promise| {
                    self.markValue(promise.result);
                    for (object.array_properties.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                    for (promise.reactions.items) |reaction| {
                        self.markValue(reaction.on_fulfilled);
                        self.markValue(reaction.on_rejected);
                        self.markValue(.{ .tag = @intFromEnum(Tag.promise), .payload = @intFromPtr(reaction.next) });
                    }
                },
            }
        }
        var reclaimed: usize = 0;
        var link = &self.objects;
        while (link.*) |object| {
            if (object.marked) {
                object.marked = false;
                link = &object.next;
                continue;
            }
            link.* = object.next;
            self.destroyObject(object);
            self.object_count -= 1;
            reclaimed += 1;
        }
        return reclaimed;
    }

    pub fn markValue(self: *Runtime, value: Value) void {
        const object = value.object() orelse return;
        if (object.marked) return;
        object.marked = true;
        object.grey_next = self.grey;
        self.grey = object;
    }

    pub fn setException(self: *Runtime, value: Value) void {
        self.pending_exception = value;
        self.has_pending_exception = true;
        self.failure_epoch +%= 1;
    }

    pub fn setFailure(self: *Runtime, failure: anyerror) void {
        self.setFailureText(error_message.forFailure(failure));
    }

    pub fn setFailureText(self: *Runtime, text: []const u8) void {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |allocation_failure| runtimeFailure(allocation_failure);
        defer self.allocator.free(units);
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    pub fn setFailureUnits(self: *Runtime, units: []const u16) void {
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    pub fn setErrorMessage(self: *Runtime, value: Value) void {
        // JavaScript's Error(undefined).message is the empty string.  The
        // other cases use the same String(value) conversion as ordinary AOT
        // text operations, including arrays and dictionaries.
        if (value.tag == @intFromEnum(Tag.undefined)) {
            self.setFailureUnits(&.{});
            return;
        }
        const units = valueUtf16Alloc(self, value) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(units);
        self.setFailureUnits(units);
    }

    pub fn setIndexAssignmentFailure(self: *Runtime, container: Value, key: Value) void {
        const key_units = valueUtf16Alloc(self, key) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_units);
        const key_utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, key_units) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_utf8);
        const container_name: []const u8 = if (container.tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
        const message = std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 }) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(message);
        self.setFailureText(message);
    }

    pub fn systemContext(self: *Runtime) !Value {
        if (self.system_context.tag == @intFromEnum(Tag.undefined)) self.system_context = try self.createDictionary(&.{});
        return self.system_context;
    }

    pub fn takeException(self: *Runtime) Value {
        if (!self.has_pending_exception) return .{};
        const result = self.pending_exception;
        self.pending_exception = .{};
        self.has_pending_exception = false;
        return result;
    }

    pub fn destroyObject(self: *Runtime, object: *Object) void {
        if (object.toml_temporal) |*temporal| temporal.deinit(self.allocator);
        switch (object.payload) {
            .utf16_string => |units| self.allocator.free(units),
            .byte_buffer => |buffer| {
                buffer.storage.release();
                object.array_properties.deinit(self.allocator);
            },
            .bigint => |*value| value.deinit(),
            .array => |*items| {
                items.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
                object.array_presence.deinit(self.allocator);
            },
            .dictionary => |*entries| entries.deinit(self.allocator),
            .function => |function| {
                var index: usize = 0;
                while (index < self.named_functions.items.len) {
                    if (self.named_functions.items[index].object == object) {
                        self.allocator.free(self.named_functions.items[index].name);
                        _ = self.named_functions.swapRemove(index);
                    } else {
                        index += 1;
                    }
                }
                self.allocator.free(function.name);
                self.allocator.free(function.captures);
                object.array_properties.deinit(self.allocator);
            },
            .iterator, .binding_cell => {},
            .promise => |*promise| {
                promise.reactions.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
            },
        }
        self.allocator.destroy(object);
    }

    pub fn indexGet(self: *Runtime, container: Value, key: Value) Value {
        if (container.tag == @intFromEnum(Tag.utf16_string)) {
            const index = valueIndex(key) orelse return .{};
            return self.stringAt(container, index);
        }
        const object = container.object() orelse return .{};
        return switch (object.payload) {
            .byte_buffer => {
                var rooted = [_]Value{ container, key };
                var frame = RootFrame{};
                self.pushRoots(&frame, &rooted, rooted.len);
                defer self.popRoots(&frame);
                const source = rooted[0];
                const rooted_buffer = source.object().?.payload.byte_buffer;
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    return .{};
                };
                defer self.allocator.free(key_units);
                if (self.aotObjectOwnPropertyGetUnits(source.object().?, key_units)) |value| return value;
                if (tablePropertyIndex(key_units) == null) {
                    const inherited = tableInheritedProperty(self, source, .byte_buffer, key_units) catch |failure| {
                        self.setFailure(failure);
                        return .{};
                    };
                    if (inherited) |value| return value;
                }
                if (!aotByteBufferAllowsStandardPrototype(source)) {
                    const index = tablePropertyIndex(key_units) orelse return .{};
                    return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len)
                        .{}
                    else
                        numberValue(@floatFromInt(rooted_buffer.bytes[index]));
                }
                if (sameKey(rooted[1], staticStringValue("length"))) {
                    return if (rooted_buffer.kind == .array_buffer) .{} else numberValue(@floatFromInt(rooted_buffer.bytes.len));
                }
                if (sameKey(rooted[1], staticStringValue("buffer")) and rooted_buffer.kind != .array_buffer) {
                    return self.createByteBufferBackingBuffer(rooted_buffer) catch |failure| {
                        self.setFailure(failure);
                        return .{};
                    };
                }
                if (aotByteBufferScalarProperty(rooted_buffer, rooted[1])) |value| return value;
                const index = tablePropertyIndex(key_units) orelse return .{};
                return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len) .{} else numberValue(@floatFromInt(rooted_buffer.bytes[index]));
            },
            .array => aotArrayPropertyGet(self, object, key),
            .dictionary => blk: {
                var rooted = [_]Value{ container, key, .{} };
                var dictionary_frame = RootFrame{};
                self.pushRoots(&dictionary_frame, &rooted, rooted.len);
                defer self.popRoots(&dictionary_frame);
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                };
                defer self.allocator.free(key_units);
                if (dictionaryOwnProperty(rooted[0], key_units)) |value| break :blk value;
                rooted[2] = (tableInheritedProperty(self, rooted[0], .dictionary, key_units) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                }) orelse .{};
                break :blk rooted[2];
            },
            .function => tableRowProperty(self, container, key) catch |failure| {
                self.setFailure(failure);
                return .{};
            },
            .promise => blk: {
                var rooted = [_]Value{ container, key };
                var promise_frame = RootFrame{};
                self.pushRoots(&promise_frame, &rooted, rooted.len);
                defer self.popRoots(&promise_frame);
                const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                    self.setFailure(failure);
                    break :blk .{};
                };
                defer self.allocator.free(key_units);
                break :blk self.aotObjectOwnPropertyGetUnits(rooted[0].object().?, key_units) orelse .{};
            },
            else => .{},
        };
    }

    pub fn destructureGet(_: *Runtime, source: Value, index: usize) Value {
        if (source.tag == @intFromEnum(Tag.array)) {
            const items = source.object().?.payload.array.items;
            return if (index < items.len) items[index] else .{};
        }
        return if (index == 0) source else .{};
    }

    pub fn indexSet(self: *Runtime, container: Value, key: Value, value: Value) !void {
        const object = container.object() orelse return switch (@as(Tag, @enumFromInt(container.tag))) {
            .undefined, .null_value => error.InvalidContainer,
            else => {},
        };
        switch (object.payload) {
            .array => {
                try aotArrayPropertySet(self, object, key, value);
            },
            .dictionary => |*entries| {
                var rooted = [_]Value{ container, key, value };
                var frame = RootFrame{};
                self.pushRoots(&frame, &rooted, rooted.len);
                defer self.popRoots(&frame);
                rooted[1] = try self.propertyKey(rooted[1]);
                var has_own_prototype_key = false;
                if (sameKey(rooted[1], staticStringValue("__proto__"))) for (entries.items) |entry| {
                    if (sameKey(entry.key, rooted[1])) {
                        has_own_prototype_key = true;
                        break;
                    }
                };
                if (!has_own_prototype_key and sameKey(rooted[1], staticStringValue("__proto__"))) {
                    if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) {
                        object.prototype = rooted[2];
                    }
                    return;
                }
                try self.setDictionary(entries, rooted[1], rooted[2]);
            },
            .byte_buffer => |*buffer| {
                if (buffer.kind != .array_buffer) if (valueIndex(key)) |index| {
                    const number = try valueToNumberRuntime(self, value);
                    const byte: u8 = if (!std.math.isFinite(number) or number == 0)
                        0
                    else
                        @intFromFloat(@mod(@trunc(number), 256));
                    if (index < buffer.bytes.len) buffer.bytes[index] = byte;
                    return;
                };
                const key_units = valueUtf16Alloc(self, key) catch |failure| {
                    self.setFailure(failure);
                    return failure;
                };
                defer self.allocator.free(key_units);
                if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
                    self.aotObjectOwnPropertyGetUnits(object, key_units) == null)
                {
                    if (value.tag == @intFromEnum(Tag.null_value) or value.object() != null) object.prototype = value;
                    return;
                }
                if (aotByteBufferReadOnlyProperty(buffer.kind, key_units)) return;
                try self.setAotOwnProperty(container, object, key, value);
            },
            .function => try self.setAotFunctionProperty(container, object, key, value),
            .promise => try self.setAotOwnProperty(container, object, key, value),
            .utf16_string, .bigint, .iterator, .binding_cell => {},
        }
    }

    pub fn setAotOwnProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{ container, key, value, .{} };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        rooted[3] = try self.propertyKey(rooted[1]);
        try self.setDictionary(&object.array_properties, rooted[3], rooted[2]);
    }

    pub fn setAotFunctionProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{ container, key, value, .{} };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        rooted[3] = try self.propertyKey(rooted[1]);
        // Function.prototype's length and name are non-writable own properties.
        // Keep writes ignored in AOT just as the interpreter does, rather than
        // allowing an own-property shadow to change the built-in value.
        if (sameKey(rooted[3], staticStringValue("length")) or sameKey(rooted[3], staticStringValue("name"))) return;
        try self.setDictionary(&object.array_properties, rooted[3], rooted[2]);
    }

    pub fn aotArrayPropertyGet(self: *Runtime, object: *const Object, key: Value) Value {
        var rooted = [_]Value{
            .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
            key,
        };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        const key_units = valueUtf16Alloc(self, rooted[1]) catch return .{};
        defer self.allocator.free(key_units);
        return self.aotArrayPropertyGetUnits(rooted[0].object().?, key_units);
    }

    pub fn aotArrayIsPresent(_: *Runtime, object: *const Object, index: usize) bool {
        if (object.payload.array.items.len <= index) return false;
        return if (index < object.array_presence.items.len) object.array_presence.items[index] else true;
    }

    pub fn normalizeAotArrayPresence(self: *Runtime, object: *Object) !void {
        if (object.array_presence.items.len >= object.payload.array.items.len) return;
        const previous_len = object.array_presence.items.len;
        try object.array_presence.resize(self.allocator, object.payload.array.items.len);
        // Low-level append sites predate presence tracking; existing slots are
        // dense values when the metadata is first synchronized.
        @memset(object.array_presence.items[previous_len..], true);
    }

    pub fn aotArraySetIndex(self: *Runtime, object: *Object, index: usize, value: Value) !void {
        try self.normalizeAotArrayPresence(object);
        if (index >= object.payload.array.items.len) {
            const previous_len = object.payload.array.items.len;
            try object.payload.array.resize(self.allocator, index + 1);
            @memset(object.payload.array.items[previous_len..], .{});
            try object.array_presence.resize(self.allocator, index + 1);
            @memset(object.array_presence.items[previous_len..], false);
        }
        object.payload.array.items[index] = value;
        object.array_presence.items[index] = true;
    }

    pub fn aotArrayDeleteIndex(self: *Runtime, object: *Object, index: usize) !bool {
        if (index >= object.payload.array.items.len) return false;
        try self.normalizeAotArrayPresence(object);
        object.payload.array.items[index] = .{};
        object.array_presence.items[index] = false;
        return true;
    }

    pub fn aotArrayAppend(self: *Runtime, object: *Object, value: Value) !void {
        try self.normalizeAotArrayPresence(object);
        try object.payload.array.append(self.allocator, value);
        errdefer _ = object.payload.array.pop();
        try object.array_presence.append(self.allocator, true);
    }

    pub fn aotArrayPropertySet(self: *Runtime, object: *Object, key: Value, value: Value) !void {
        var rooted = [_]Value{
            .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
            key,
            value,
        };
        var frame = RootFrame{};
        self.pushRoots(&frame, &rooted, rooted.len);
        defer self.popRoots(&frame);
        const key_units = try valueUtf16Alloc(self, rooted[1]);
        defer self.allocator.free(key_units);
        if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
        if (self.aotCanonicalArrayIndexUnits(key_units)) |index| {
            try self.aotArraySetIndex(rooted[0].object().?, index, rooted[2]);
            return;
        }
        const normalized = try self.propertyKey(rooted[1]);
        if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            self.aotArrayOwnPropertyGetUnits(rooted[0].object().?, key_units) == null)
        {
            if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) rooted[0].object().?.prototype = rooted[2];
            return;
        }
        try self.setDictionary(&rooted[0].object().?.array_properties, normalized, rooted[2]);
    }

    pub fn aotArrayPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) Value {
        if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return numberValue(@floatFromInt(object.payload.array.items.len));
        if (self.aotArrayOwnPropertyGetUnits(object, key_units)) |value| return value;
        const source = Value{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) };
        return (tableInheritedProperty(self, source, .array, key_units) catch |failure| {
            self.setFailure(failure);
            return .{};
        }) orelse .{};
    }

    pub fn aotArrayOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        if (self.aotCanonicalArrayIndexUnits(key_units)) |index| return if (index < object.payload.array.items.len) object.payload.array.items[index] else null;
        return self.aotObjectOwnPropertyGetUnits(object, key_units);
    }

    /// Resolve an own named property shared by all extensible AOT objects.
    /// Array indices remain handled by `aotArrayOwnPropertyGetUnits` before
    /// reaching this helper.
    pub fn aotObjectOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        for (object.array_properties.items) |property| {
            if (self.aotPropertyKeyMatchesUnits(property.key, key_units)) return property.value;
        }
        return null;
    }

    pub fn aotPropertyKeyMatchesUnits(_: *Runtime, key: Value, units: []const u16) bool {
        return switch (@as(Tag, @enumFromInt(key.tag))) {
            .static_utf8_string => staticUtf8EqualsUtf16(staticUtf8(key), units),
            .utf16_string => std.mem.eql(u16, key.object().?.payload.utf16_string, units),
            else => false,
        };
    }

    pub fn aotCanonicalArrayIndexUnits(_: *Runtime, units: []const u16) ?usize {
        if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
        var result: usize = 0;
        for (units) |unit| {
            if (unit < '0' or unit > '9') return null;
            result = std.math.mul(usize, result, 10) catch return null;
            result = std.math.add(usize, result, unit - '0') catch return null;
        }
        return if (result <= 4_294_967_294) result else null;
    }

    pub fn iteratorHasNext(_: *Runtime, value: Value) bool {
        const object = value.object() orelse return false;
        if (object.payload != .iterator) return false;
        const iterator = object.payload.iterator;
        return switch (iterator.kind) {
            .range => if (iterator.step > 0) iterator.current <= iterator.end else iterator.current >= iterator.end,
            else => iterator.index < iterator.count,
        };
    }

    pub fn iteratorNext(self: *Runtime, value: Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) Value {
        const object = value.object() orelse return .{};
        if (object.payload != .iterator) return .{};
        const iterator = &object.payload.iterator;
        if (!self.iteratorHasNext(value)) return .{};
        return switch (iterator.kind) {
            .repeat => blk: {
                iterator.index += 1;
                const result = numberValue(@floatFromInt(iterator.index));
                if (repeat_target) |target| target.* = result;
                break :blk result;
            },
            .range => blk: {
                const result = numberValue(iterator.current);
                iterator.current += iterator.step;
                if (range_target) |target| target.* = result;
                break :blk result;
            },
            .bytes => blk: {
                const result = numberValue(@floatFromInt(iterator.source.object().?.payload.byte_buffer.bytes[iterator.index]));
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .string => blk: {
                const result = self.stringAt(iterator.source, iterator.index);
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .array => blk: {
                const result = iterator.source.object().?.payload.array.items[iterator.index];
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
                iterator.index += 1;
                if (value_target) |target| target.* = result;
                break :blk result;
            },
            .dictionary => blk: {
                const entry = iterator.source.object().?.payload.dictionary.items[iterator.index];
                if (key_target) |target| target.* = entry.key;
                iterator.index += 1;
                if (value_target) |target| target.* = entry.value;
                break :blk entry.value;
            },
        };
    }

    pub fn stringAt(self: *Runtime, source: Value, index: usize) Value {
        const object = source.object() orelse return .{};
        if (object.payload != .utf16_string) return .{};
        const units = object.payload.utf16_string;
        if (index >= units.len) return .{};
        return self.createString(units[index .. index + 1]) catch .{};
    }

    pub fn setDictionary(self: *Runtime, entries: *std.ArrayList(DictionaryEntry), key: Value, value: Value) !void {
        for (entries.items) |*entry| if (sameKey(entry.key, key)) {
            entry.value = value;
            return;
        };
        try entries.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn propertyKey(self: *Runtime, key: Value) !Value {
        return switch (@as(Tag, @enumFromInt(key.tag))) {
            .static_utf8_string, .utf16_string => key,
            else => blk: {
                const units = try valueUtf16Alloc(self, key);
                defer self.allocator.free(units);
                break :blk try self.createString(units);
            },
        };
    }
};
