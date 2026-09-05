const shared = @import("shared.zig");
const builtins = @import("builtins.zig");

const std = shared.std;
const builtin = shared.builtin;
const aot_abi = shared.aot_abi;
pub const aot_builtin = shared.aot_builtin;
pub const BigInt = shared.BigInt;
const error_message = shared.error_message;
const unicode_case = shared.unicode_case;
const number_mod = shared.number_mod;
const string_mod = shared.string_mod;
const system_constant = shared.system_constant;
pub const crypto = shared.crypto;
const encoding = shared.encoding;
const zip_archive = shared.zip_archive;
const regexp = shared.regexp;
const markup = shared.markup;
const lexer = shared.lexer;
const josi = shared.josi;
const builtin_catalog = shared.builtin_catalog;
const dynamic_ir = shared.dynamic_ir;
const dynamic_interpreter = shared.dynamic_interpreter;
const dynamic_value = shared.dynamic_value;
pub const toml_temporal = shared.toml_temporal;

pub const lnako_aot_builtin_call = builtins.lnako_aot_builtin_call;
pub const lnako_aot_builtin_call_site = builtins.lnako_aot_builtin_call_site;
pub const lnako_aot_debug_breakpoint_wait_call = builtins.lnako_aot_debug_breakpoint_wait_call;
pub extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
pub extern "c" fn time(timer: ?*i64) i64;

const AotWindowsStdout = shared.AotWindowsStdout;
pub const Tag = shared.Tag;
pub const AotPrimitiveHint = shared.AotPrimitiveHint;
const no_dispatch_call_id = shared.no_dispatch_call_id;
pub const safe_array_element_limit = shared.safe_array_element_limit;
pub const aot_timer_event_limit = shared.aot_timer_event_limit;

const trace_module = @import("trace.zig");

pub const DispatchTrace = trace_module.DispatchTrace;
pub const GlobalTrace = trace_module.GlobalTrace;
pub const LiteralTrace = trace_module.LiteralTrace;

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

const dynamic_module = @import("dynamic.zig");

pub const DynamicGlobal = dynamic_module.DynamicGlobal;
pub const DynamicPromiseBridge = dynamic_module.DynamicPromiseBridge;
pub const AotFunctionBridge = dynamic_module.AotFunctionBridge;
pub const DynamicInterpreterState = dynamic_module.DynamicInterpreterState;
pub const traceDynamicBridges = dynamic_module.traceDynamicBridges;
pub const dynamicGlobal = dynamic_module.dynamicGlobal;
pub const upsertDynamicGlobal = dynamic_module.upsertDynamicGlobal;
pub const removeAotFunctionBridge = dynamic_module.removeAotFunctionBridge;
pub const releaseAotFunctionBridge = dynamic_module.releaseAotFunctionBridge;
pub const callAotFunctionBridge = dynamic_module.callAotFunctionBridge;
pub const aotFunctionToDynamicValue = dynamic_module.aotFunctionToDynamicValue;
pub const dynamicPromiseToAotValue = dynamic_module.dynamicPromiseToAotValue;
pub const aotToDynamicValue = dynamic_module.aotToDynamicValue;
pub const dynamicToAotValue = dynamic_module.dynamicToAotValue;
pub const prepareDynamic = dynamic_module.prepareDynamic;
pub const syncDynamicGlobals = dynamic_module.syncDynamicGlobals;
pub const dynamicInterpreterState = dynamic_module.dynamicInterpreterState;
pub const nativePluginBuiltin = dynamic_module.nativePluginBuiltin;
pub const dynamicBuiltin = dynamic_module.dynamicBuiltin;
pub const concatAotValues = dynamic_module.concatAotValues;

const node_module = @import("node.zig");

pub const runAotExternal = node_module.runAotExternal;
pub const nodeProcessBuiltin = node_module.nodeProcessBuiltin;
pub const nodeBasenameWideFor = node_module.nodeBasenameWideFor;
pub const nodeNetworkAddressesBuiltin = node_module.nodeNetworkAddressesBuiltin;
pub const nodeEnvironmentBuiltin = node_module.nodeEnvironmentBuiltin;
pub const nodeProcessExitCode = node_module.nodeProcessExitCode;
pub const nodeCryptoBuiltin = node_module.nodeCryptoBuiltin;
pub const nodeDirectoryBuiltin = node_module.nodeDirectoryBuiltin;
pub const nodeTemporaryDirectoryPrefixAlloc = node_module.nodeTemporaryDirectoryPrefixAlloc;
pub const nodeCreateTemporaryDirectoryBuiltin = node_module.nodeCreateTemporaryDirectoryBuiltin;
pub const nodeMotherPathBuiltin = node_module.nodeMotherPathBuiltin;
pub const nodeEnvironmentValueBuiltin = node_module.nodeEnvironmentValueBuiltin;
pub const nodeEnvironmentListBuiltin = node_module.nodeEnvironmentListBuiltin;
pub const nodeCurrentDirectoryBuiltin = node_module.nodeCurrentDirectoryBuiltin;
pub const currentDirectoryAlloc = node_module.currentDirectoryAlloc;
pub const aotProcessEnvironment = node_module.aotProcessEnvironment;
pub const nodeChangeDirectoryBuiltin = node_module.nodeChangeDirectoryBuiltin;
pub const nodePathBuiltin = node_module.nodePathBuiltin;
pub const nodePathComponentBuiltin = node_module.nodePathComponentBuiltin;
pub const systemPathComponentBuiltin = node_module.systemPathComponentBuiltin;
pub const nodePathArgument = node_module.nodePathArgument;
pub const nodePathReceivedType = node_module.nodePathReceivedType;
pub const nodePathPrimitiveReceivedType = node_module.nodePathPrimitiveReceivedType;

const node_file_module = @import("node_file.zig");

pub const isNodeFileOperationCommand = node_file_module.isNodeFileOperationCommand;
pub const isNodeFileCallbackCommand = node_file_module.isNodeFileCallbackCommand;
pub const nodeFileExistenceBuiltin = node_file_module.nodeFileExistenceBuiltin;
pub const nodeFileReadBuiltin = node_file_module.nodeFileReadBuiltin;
pub const nodeEncodedFileReadBuiltin = node_file_module.nodeEncodedFileReadBuiltin;
pub const nodeFileSaveBuiltin = node_file_module.nodeFileSaveBuiltin;
pub const nodeEncodedFileSaveBuiltin = node_file_module.nodeEncodedFileSaveBuiltin;
pub const nodeEncodingName = node_file_module.nodeEncodingName;
pub const nodeEncodingValueBytesAlloc = node_file_module.nodeEncodingValueBytesAlloc;
pub const nodeEncodingBuiltin = node_file_module.nodeEncodingBuiltin;
pub const nodeFileCallbackBuiltin = node_file_module.nodeFileCallbackBuiltin;
pub const nodeFileOperationBuiltin = node_file_module.nodeFileOperationBuiltin;
pub const nodeFileListBuiltin = node_file_module.nodeFileListBuiltin;
pub const nodeFileDeleteBuiltin = node_file_module.nodeFileDeleteBuiltin;
pub const nodeFileCopyDefaultOverwrite = node_file_module.nodeFileCopyDefaultOverwrite;
pub const nodeFileCopyMoveBuiltin = node_file_module.nodeFileCopyMoveBuiltin;
pub const nodeFileSizeBuiltin = node_file_module.nodeFileSizeBuiltin;
pub const nodeFileInfoBuiltin = node_file_module.nodeFileInfoBuiltin;
pub const nodeFileInfoTrue = node_file_module.nodeFileInfoTrue;
pub const nodeFileInfoFalse = node_file_module.nodeFileInfoFalse;
pub const nodeEncodingSupportsBuiltin = node_file_module.nodeEncodingSupportsBuiltin;
pub const nodeStdinCallbackBuiltin = node_file_module.nodeStdinCallbackBuiltin;
pub const nodeStdinLineBuiltin = node_file_module.nodeStdinLineBuiltin;
pub const nodeStdinAllBuiltin = node_file_module.nodeStdinAllBuiltin;
pub const nodeStdinValueBuiltin = node_file_module.nodeStdinValueBuiltin;
pub const ensureAotStdin = node_file_module.ensureAotStdin;
pub const aotFileCopyMoveWithIo = node_file_module.aotFileCopyMoveWithIo;

const node_http_module = @import("node_http.zig");

pub const nodePostDataBuiltin = node_http_module.nodePostDataBuiltin;
pub const appendNodeUriComponent = node_http_module.appendNodeUriComponent;
pub const aotClientDictionaryGetAscii = node_http_module.aotClientDictionaryGetAscii;
pub const aotClientValueBytes = node_http_module.aotClientValueBytes;
pub const aotClientPrepareAjax = node_http_module.aotClientPrepareAjax;
pub const aotClientAppendUriComponent = node_http_module.aotClientAppendUriComponent;
pub const aotClientFormEncodedBody = node_http_module.aotClientFormEncodedBody;
pub const aotClientMultipartFields = node_http_module.aotClientMultipartFields;
pub const aotClientPreparePost = node_http_module.aotClientPreparePost;
pub const aotClientPrepareDiscord = node_http_module.aotClientPrepareDiscord;
pub const aotClientPrepareDiscordFile = node_http_module.aotClientPrepareDiscordFile;
pub const aotClientHttpMethod = node_http_module.aotClientHttpMethod;
pub const aotClientHttpRequest = node_http_module.aotClientHttpRequest;
pub const aotClientHttpBodyValue = node_http_module.aotClientHttpBodyValue;
pub const aotClientHttpResponseValue = node_http_module.aotClientHttpResponseValue;
pub const isAotHttpResponse = node_http_module.isAotHttpResponse;
pub const aotClientHttpResponseBody = node_http_module.aotClientHttpResponseBody;
pub const aotClientHttpResponseStatus = node_http_module.aotClientHttpResponseStatus;
pub const aotClientHttpBodyKind = node_http_module.aotClientHttpBodyKind;
pub const aotClientPrepareHttpCommand = node_http_module.aotClientPrepareHttpCommand;
pub const aotClientIsCallbackCommand = node_http_module.aotClientIsCallbackCommand;
pub const aotClientIsResponsePromiseCommand = node_http_module.aotClientIsResponsePromiseCommand;
pub const nodeHttpBuiltin = node_http_module.nodeHttpBuiltin;

const conversion_module = @import("conversion.zig");

pub const valueIndex = conversion_module.valueIndex;
pub const aotByteBufferAllowsStandardPrototype = conversion_module.aotByteBufferAllowsStandardPrototype;
pub const aotByteBufferScalarProperty = conversion_module.aotByteBufferScalarProperty;
pub const aotByteBufferReadOnlyProperty = conversion_module.aotByteBufferReadOnlyProperty;
pub const valueToNumber = conversion_module.valueToNumber;
pub const valueToNumberRuntime = conversion_module.valueToNumberRuntime;
pub const explicitRangeNumber = conversion_module.explicitRangeNumber;
pub const valueToParseFloatRuntime = conversion_module.valueToParseFloatRuntime;
pub const parseStringNumber = conversion_module.parseStringNumber;
pub const validDecimalNumber = conversion_module.validDecimalNumber;
pub const incrementNumber = conversion_module.incrementNumber;
pub const incrementValue = conversion_module.incrementValue;
pub const isString = conversion_module.isString;
pub const isObject = conversion_module.isObject;
pub const stringUtf8Alloc = conversion_module.stringUtf8Alloc;
pub const valueUtf16Alloc = conversion_module.valueUtf16Alloc;
pub const byteBufferUtf16Alloc = conversion_module.byteBufferUtf16Alloc;
pub const functionStringUtf16Alloc = conversion_module.functionStringUtf16Alloc;
pub const arrayUtf16Alloc = conversion_module.arrayUtf16Alloc;
pub const isAotObjectValue = conversion_module.isAotObjectValue;
pub const valueToPrimitive = conversion_module.valueToPrimitive;
pub const hostObjectToPrimitive = conversion_module.hostObjectToPrimitive;
pub const aotCustomObjectPrototypeProperty = conversion_module.aotCustomObjectPrototypeProperty;
pub const arrayToPrimitive = conversion_module.arrayToPrimitive;
pub const dictionaryToPrimitive = conversion_module.dictionaryToPrimitive;
pub const stringEqual = conversion_module.stringEqual;
pub const stringOrder = conversion_module.stringOrder;
pub const strictEqual = conversion_module.strictEqual;
pub const sameValue = conversion_module.sameValue;
pub const sameValueZero = conversion_module.sameValueZero;
pub const abstractEqual = conversion_module.abstractEqual;
pub const relationalOrder = conversion_module.relationalOrder;
pub const deepEqual = conversion_module.deepEqual;
pub const isJsonStringifyObject = conversion_module.isJsonStringifyObject;
pub const compareValues = conversion_module.compareValues;
pub const numberString = conversion_module.numberString;
pub const concat = conversion_module.concat;
pub const bigIntArithmetic = conversion_module.bigIntArithmetic;
pub const arithmetic = conversion_module.arithmetic;
pub const bigIntEqualsString = conversion_module.bigIntEqualsString;
pub const compareBigIntString = conversion_module.compareBigIntString;
pub const bigIntFromString = conversion_module.bigIntFromString;
pub const shift = conversion_module.shift;
pub const bitNot = conversion_module.bitNot;
pub const valueTruthy = conversion_module.valueTruthy;
pub const toInt32 = conversion_module.toInt32;
pub const toUint32 = conversion_module.toUint32;
pub const bigIntEqualsNumber = conversion_module.bigIntEqualsNumber;
pub const compareBigIntNumber = conversion_module.compareBigIntNumber;
pub const invertOrder = conversion_module.invertOrder;
pub const repeatCount = conversion_module.repeatCount;
pub const sameKey = conversion_module.sameKey;
pub const staticUtf8EqualsUtf16 = conversion_module.staticUtf8EqualsUtf16;
pub const staticUtf8 = conversion_module.staticUtf8;

const regexp_module = @import("regexp.zig");

pub const RegexpCallResult = regexp_module.RegexpCallResult;
pub const regexpCommandName = regexp_module.regexpCommandName;
pub const setRegexpCompileFailureMessage = regexp_module.setRegexpCompileFailureMessage;
pub const regexpBuiltin = regexp_module.regexpBuiltin;

/// Dedicated ABI because regexp match/extract update the system global
/// `抽出文字列` in addition to returning their normal value.
const json_module = @import("json.zig");

pub const appendAsciiUnits = json_module.appendAsciiUnits;
pub const appendUtf8Units = json_module.appendUtf8Units;
pub const jsonEncodeBuiltin = json_module.jsonEncodeBuiltin;
pub const jsonDecodeBuiltin = json_module.jsonDecodeBuiltin;
pub const jsonAotContainerCount = json_module.jsonAotContainerCount;

pub extern "c" fn putchar(character: c_int) c_int;

const display_module = @import("display.zig");

pub const writeUtf16 = display_module.writeUtf16;
pub const valueUtf8LossyAlloc = display_module.valueUtf8LossyAlloc;
pub const utf16UnitsToUtf8LossyAlloc = display_module.utf16UnitsToUtf8LossyAlloc;
pub const appendDisplayLog = display_module.appendDisplayLog;
pub const emitDisplayLine = display_module.emitDisplayLine;
pub const displayValue = display_module.displayValue;
pub const continueDisplayValue = display_module.continueDisplayValue;
pub const joinValuesUtf8Alloc = display_module.joinValuesUtf8Alloc;
pub const displayMany = display_module.displayMany;
pub const configureHatenaBuiltin = display_module.configureHatenaBuiltin;
pub const configureInterruptBuiltin = display_module.configureInterruptBuiltin;
pub const invokeHatenaNamedCallback = display_module.invokeHatenaNamedCallback;
pub const invokeHatenaCallbacks = display_module.invokeHatenaCallbacks;
pub const writeAllValues = display_module.writeAllValues;
pub const isStdioCommand = display_module.isStdioCommand;
pub const isNodeProcessCommand = display_module.isNodeProcessCommand;
pub const isNodeHttpCommand = display_module.isNodeHttpCommand;
pub const isArchiveCommand = display_module.isArchiveCommand;
pub const isPluginManagementCommand = display_module.isPluginManagementCommand;
pub const stdioBuiltin = display_module.stdioBuiltin;
pub const pluginManagementArgument = display_module.pluginManagementArgument;
pub const pluginManagementBuiltin = display_module.pluginManagementBuiltin;

const http_server_module = @import("http_server.zig");

pub const isHttpServerCommand = http_server_module.isHttpServerCommand;
pub const httpServerBuiltin = http_server_module.httpServerBuiltin;
pub const aotHttpDictionarySetUtf8 = http_server_module.aotHttpDictionarySetUtf8;
pub const pollAotHttpServer = http_server_module.pollAotHttpServer;

const async_module = @import("async.zig");

pub const sleepAotUntil = async_module.sleepAotUntil;
pub const runAotShellCommand = async_module.runAotShellCommand;
pub const aotRuntimeIo = async_module.aotRuntimeIo;
pub const writeAotStderr = async_module.writeAotStderr;
pub const waitAotMilliseconds = async_module.waitAotMilliseconds;
pub const queueAotProcess = async_module.queueAotProcess;
pub const queueAotFileTask = async_module.queueAotFileTask;
pub const readyAotProcessTaskIndex = async_module.readyAotProcessTaskIndex;
pub const readyAotFileTaskIndex = async_module.readyAotFileTaskIndex;
pub const writeAotAjaxReceiveError = async_module.writeAotAjaxReceiveError;
pub const aotArchiveExecute = async_module.aotArchiveExecute;
pub const drainAotProcessTasks = async_module.drainAotProcessTasks;
pub const drainAotFileTasks = async_module.drainAotFileTasks;
pub const drainAotArchiveTasks = async_module.drainAotArchiveTasks;
pub const drainAotPromiseTasks = async_module.drainAotPromiseTasks;
pub const drainAotNativePluginTasks = async_module.drainAotNativePluginTasks;
pub const drainAotClientHttpTasks = async_module.drainAotClientHttpTasks;
pub const drainAotEvents = async_module.drainAotEvents;
pub const drainAotTimers = async_module.drainAotTimers;
pub const timerBuiltin = async_module.timerBuiltin;
pub const timerWaitBuiltin = async_module.timerWaitBuiltin;
pub const countAotEvent = async_module.countAotEvent;
pub const earliestAotTimerIndex = async_module.earliestAotTimerIndex;
pub const executeAotTimer = async_module.executeAotTimer;
pub const aotPromiseObject = async_module.aotPromiseObject;
pub const aotPromiseValue = async_module.aotPromiseValue;
pub const createAotPromise = async_module.createAotPromise;
pub const aotPromiseThen = async_module.aotPromiseThen;
pub const resolveAotPromise = async_module.resolveAotPromise;
pub const rejectAotPromise = async_module.rejectAotPromise;
pub const enqueueAotPromiseReaction = async_module.enqueueAotPromiseReaction;
pub const enqueueAotPromiseReactions = async_module.enqueueAotPromiseReactions;
pub const createAotPromiseResolver = async_module.createAotPromiseResolver;
pub const createAotPromiseWithExecutor = async_module.createAotPromiseWithExecutor;
pub const chainAotPromise = async_module.chainAotPromise;
pub const bundleAotPromises = async_module.bundleAotPromises;
pub const createAotPromiseAllHandler = async_module.createAotPromiseAllHandler;
pub const promiseAotBuiltin = async_module.promiseAotBuiltin;
pub const awaitAotPromise = async_module.awaitAotPromise;
pub const forwardAotPromiseTask = async_module.forwardAotPromiseTask;
pub const executeAotPromiseTask = async_module.executeAotPromiseTask;
pub const callbackFailureReason = async_module.callbackFailureReason;
pub const destroyAotPromiseAllState = async_module.destroyAotPromiseAllState;
pub const handleAotPromiseAll = async_module.handleAotPromiseAll;

pub fn stringArrayBuiltin(runtime: *Runtime, names: []const []const u8) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (names) |name| {
        roots[1] = try runtimeUtf8String(runtime, name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

pub fn systemFunctionExistsBuiltin(runtime: *Runtime, values: []const Value) !Value {
    const source = if (values.len > 0) values[values.len - 1] else Value{};
    const text = try valueUtf8LossyAlloc(runtime, source);
    defer runtime.allocator.free(text);
    for (builtin_catalog.default_names) |candidate| {
        if (std.mem.eql(u8, text, candidate)) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
    }
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
}

/// Convert a UTF-16 exception message to UTF-8 without rejecting lone
/// surrogates.  JavaScript strings can contain unpaired surrogates, while the
/// process stderr stream is UTF-8; use U+FFFD for an unpaired code unit just
/// as the normal AOT output path does.
pub fn utf16FailureMessageUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) anyerror![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }

        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidUnicodeScalar;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

pub fn pendingExceptionMessageUtf8Alloc(runtime: *Runtime) anyerror![]u8 {
    if (!runtime.has_pending_exception) return error.NoPendingException;
    const units = try valueUtf16Alloc(runtime, runtime.pending_exception);
    defer runtime.allocator.free(units);
    return utf16FailureMessageUtf8Alloc(runtime.allocator, units);
}

pub fn writeBytes(bytes: []const u8, newline: bool) void {
    for (bytes) |byte| _ = putchar(byte);
    if (newline) _ = putchar('\n');
}

pub const AotHttpPathStat = enum { file, directory, missing };

pub fn runtimeFailure(failure: anyerror) noreturn {
    std.debug.print("[実行時エラー] {s}\n", .{@errorName(failure)});
    std.process.exit(1);
}

pub var active_runtime: ?Runtime = null;
pub var aot_interrupt_requested = std.atomic.Value(bool).init(false);

const AotPosixInterrupt = if (builtin.os.tag == .windows) struct {} else struct {
    pub fn handler(_: std.posix.SIG) callconv(.c) void {
        aot_interrupt_requested.store(true, .release);
    }
};

const AotWindowsInterrupt = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetConsoleCtrlHandler(handler_fn: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;

    pub fn handler(control_type: u32) callconv(.winapi) i32 {
        if (control_type != 0 and control_type != 1) return 0;
        aot_interrupt_requested.store(true, .release);
        return 1;
    }
} else struct {};

pub fn installAotInterrupt() !void {
    if (builtin.os.tag == .windows) {
        if (AotWindowsInterrupt.SetConsoleCtrlHandler(AotWindowsInterrupt.handler, 1) == 0) return error.InterruptHandlingUnavailable;
    } else {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = AotPosixInterrupt.handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
    }
}

pub fn pollAotInterrupt(runtime: *Runtime) !void {
    if (!aot_interrupt_requested.swap(false, .acquire)) return;
    if (runtime.interrupt_callback.tag != @intFromEnum(Tag.function)) return;

    var undefined_value = Value{};
    const result = try invokeAotCallback(runtime, runtime.interrupt_callback, @ptrCast(&undefined_value), 1);
    if (valueTruthy(result)) {
        runtime.dispatch_trace.finishTerminal("interrupt-callback", 0);
        _ = fflush(null);
        std.process.exit(0);
    }
}

/// Records execution of one statically identified global load. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified global store. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified typed literal. The
/// generated module supplies the ID from its pre-optimization literal
/// manifest.
/// Initializes Node-host constants whose values depend on the generated
/// executable's process arguments.  The generated main has already rooted
/// every referenced global before this function is called, so newly allocated
/// strings and the command-line array remain visible to the collector while
/// the values are being assembled.
/// Windows' `wmain` receives UTF-16 command-line arguments.  Keep those code
/// units intact so WTF-16 input, including unpaired surrogates, follows the
/// same value representation as the rest of the runtime.
/// Initializes Node directory values that are exposed as globals when a
/// program uses the shorthand form without parentheses.
/// Initializes the source directory used by Node's mother-path global and
/// function. Relative source paths are resolved against the executable's
/// current working directory, matching the interpreter host context.
/// Runs callbacks that were registered by the generated program before its
/// global roots are removed. This gives AOT the same top-level timer drain as
/// the Interpreter while keeping callback values inside the native runtime.
/// Installs the four mutable globals used by the built-in HTTP server. The
/// generated main roots these globals for the lifetime of the event loop.
/// Dedicated ABI for the six synchronous commands exposed by
/// `plugin_httpserver.mjs`. The implementation is native AOT code and does
/// not load or evaluate JavaScript.
/// Site-aware display hooks used by generated LLVM.  The hooks are additive;
/// the runtime ABI for existing generated modules remains unchanged.
/// Begins a direct-display trace and returns the failure epoch observed at the
/// same boundary through `epoch_out`.  The extra out parameter avoids making
/// the call ID carry two independent pieces of state across LLVM IR.
/// Records a source-level `エラー発生` throw. This is intentionally a
/// separate ABI from `lnako_aot_builtin_call_site`: the compiler lowers the
/// command to a throw terminator so exception handler control flow remains
/// explicit and no generic builtin dispatch is introduced.
pub fn debugDisplayBuiltin(runtime: *Runtime, value: Value, line: u64, source_path: []const u8, display_log: ?*Value) !void {
    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var printable = value;
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .array, .dictionary => {
            roots[1] = try jsonEncodeBuiltin(runtime, value, false);
            printable = roots[1];
        },
        else => {},
    }
    const text = try valueUtf8LossyAlloc(runtime, printable);
    defer runtime.allocator.free(text);
    const normalized_source_path = normalizeDebugSourcePath(source_path, builtin.os.tag == .windows);
    const message = try std.fmt.allocPrint(runtime.allocator, "{s}({d}): {s}", .{ normalized_source_path, line, text });
    defer runtime.allocator.free(message);
    roots[2] = try runtimeUtf8String(runtime, message);
    try displayValue(runtime, roots[2], true, display_log);
}

pub fn normalizeDebugSourcePath(source_path: []const u8, windows: bool) []const u8 {
    if (windows) {
        if (std.mem.indexOfScalar(u8, source_path, ':')) |separator| return source_path[0..separator];
    }
    return source_path;
}

/// AOT版`ハテナ関数実行`は、カスタムコールバックが未設定なら公式既定動作
/// （`デバッグ表示`）を、設定済みなら純Zigのコールバック列を専用ABIで実行する。
/// `JS:`コールバックの評価だけは通常AOTへ持ち込まず、明示的なcompat-js境界に残す。
/// Dedicated ABI for plugin and namespace state.  These commands mutate
/// system globals, so the targets are explicit instead of being looked up by
/// name inside the AOT runtime.
/// Dedicated ABI for Node's archive tool path setter. The setter mutates a
/// system global, while archive execution itself remains a separate external
/// tool boundary.
/// Dedicated ABI for Node's ZIP archive commands. The default path keeps the
/// existing pure-Zig stored-ZIP implementation; an explicitly changed tool
/// path is invoked with argv semantics, matching the command's external-tool
/// boundary without introducing a JavaScript runtime into AOT.
/// Dedicated ABI for Node's AJAX option setter. The option object is kept in
/// the corresponding rooted system global; actual HTTP execution remains a
/// separate external boundary.
/// Dedicated ABI for Node's AJAX error callback setter. The callback value is
/// kept in the corresponding rooted system global; invoking it on a failed
/// HTTP operation remains a separate external boundary.
/// Dedicated ABI for Node's HTTP client commands. Requests use Zig's native
/// HTTP client; callback and Response-Promise results are returned through the
/// AOT event queue so their observable ordering remains compatible with the
/// interpreter without embedding a JavaScript runtime.
pub fn promiseSentinel(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
}

pub fn byteBufferUnboundSliceCallback(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    runtime.setFailureText("Cannot read properties of undefined (reading 'subarray')");
}

/// Dedicated ABI for Node's synchronous standard-input callback command. The
/// callback and `対象` storage are passed explicitly so a local variable with
/// the same source-level name cannot redirect the command's side effect.
pub fn builtinDispatchRoute(command: aot_builtin.Command) []const u8 {
    return aot_builtin.dispatchRoute(command);
}

pub fn typeNameValue(value: Value) Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => staticStringValue("undefined"),
        .null_value, .byte_buffer, .array, .dictionary, .iterator, .promise => staticStringValue("object"),
        .boolean => staticStringValue("boolean"),
        .number => staticStringValue("number"),
        .static_utf8_string, .utf16_string => staticStringValue("string"),
        .bigint => staticStringValue("bigint"),
        .function => staticStringValue("function"),
        .binding_cell => typeNameValue(value.object().?.payload.binding_cell),
    };
}

pub fn parseIntBuiltin(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return number_mod.parseIntPrefix(units, null);
}

const math_module = @import("math.zig");

pub const parseFloatBuiltin = math_module.parseFloatBuiltin;
pub const mathBuiltin = math_module.mathBuiltin;
pub const initialRandomState = math_module.initialRandomState;
pub const nextRandom = math_module.nextRandom;

const datetime_module = @import("datetime.zig");

pub const currentTimeMilliseconds = datetime_module.currentTimeMilliseconds;
pub const monotonicTimeMilliseconds = datetime_module.monotonicTimeMilliseconds;
pub const eraDataBuiltin = datetime_module.eraDataBuiltin;
pub const datetimeBuiltin = datetime_module.datetimeBuiltin;
pub const datetimeAddDatePluginEpoch = datetime_module.datetimeAddDatePluginEpoch;
pub const datetimeAddDateSystemEpoch = datetime_module.datetimeAddDateSystemEpoch;
pub const datetimeConstructLocal = datetime_module.datetimeConstructLocal;
pub const datetimeFieldsFromEpoch = datetime_module.datetimeFieldsFromEpoch;

const caniuse_module = @import("caniuse.zig");

pub const caniuseAgentsBuiltin = caniuse_module.caniuseAgentsBuiltin;
pub const caniuseBrowsersBuiltin = caniuse_module.caniuseBrowsersBuiltin;

pub fn runtimeUtf8String(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn runtimeUtf8StringLossy(runtime: *Runtime, text: []const u8) !Value {
    const decoded = try string_mod.String.fromUtf8Lossy(runtime.allocator, text);
    return runtime.ownString(decoded.units);
}

const url_path_module = @import("url_path.zig");

pub const urlBuiltin = url_path_module.urlBuiltin;
pub const pathBuiltin = url_path_module.pathBuiltin;
pub const pathExtractExtensionBuiltin = url_path_module.pathExtractExtensionBuiltin;
pub const pathChangeExtensionBuiltin = url_path_module.pathChangeExtensionBuiltin;
pub const pathAddTrailingSeparatorBuiltin = url_path_module.pathAddTrailingSeparatorBuiltin;
pub const pathRemoveTrailingSeparatorBuiltin = url_path_module.pathRemoveTrailingSeparatorBuiltin;
pub const pathSeparatorUnit = url_path_module.pathSeparatorUnit;
pub const pathBasenameUnits = url_path_module.pathBasenameUnits;
pub const pathAllExtensionUnits = url_path_module.pathAllExtensionUnits;
pub const urlEncodeBuiltin = url_path_module.urlEncodeBuiltin;
pub const urlDecodeBuiltin = url_path_module.urlDecodeBuiltin;
pub const urlDecodeUnits = url_path_module.urlDecodeUnits;
pub const urlParametersBuiltin = url_path_module.urlParametersBuiltin;
pub const base64EncodeBuiltin = url_path_module.base64EncodeBuiltin;
pub const base64DecodeBuiltin = url_path_module.base64DecodeBuiltin;
pub const urlIsComponentByte = url_path_module.urlIsComponentByte;
pub const urlHexDigit = url_path_module.urlHexDigit;
pub const base64Digit = url_path_module.base64Digit;

const kansuji_module = @import("kansuji.zig");

pub const kansujiBuiltin = kansuji_module.kansujiBuiltin;
pub const kansujiToKanjiBuiltin = kansuji_module.kansujiToKanjiBuiltin;
pub const kansujiToArabicBuiltin = kansuji_module.kansujiToArabicBuiltin;
pub const kansujiMatchAny = kansuji_module.kansujiMatchAny;
pub const kansujiMatchDigit = kansuji_module.kansujiMatchDigit;
pub const kansujiAddDefaultedBase = kansuji_module.kansujiAddDefaultedBase;
pub const kansujiAddFinalBase = kansuji_module.kansujiAddFinalBase;
pub const kansujiAddPair = kansuji_module.kansujiAddPair;
pub const kansujiAddBig = kansuji_module.kansujiAddBig;
pub const kansujiFullwidthDigits = kansuji_module.kansujiFullwidthDigits;
pub const kansujiExpandDecimal = kansuji_module.kansujiExpandDecimal;
pub const kansujiValidExponentMantissa = kansuji_module.kansujiValidExponentMantissa;
pub const kansujiValidDecimal = kansuji_module.kansujiValidDecimal;
pub const kansujiIsJsNumberString = kansuji_module.kansujiIsJsNumberString;
pub const kansujiTrimJsWhitespace = kansuji_module.kansujiTrimJsWhitespace;
pub const kansujiIsJsWhitespace = kansuji_module.kansujiIsJsWhitespace;
pub const kansujiKanjiDigit = kansuji_module.kansujiKanjiDigit;
pub const kansujiAllAsciiDigits = kansuji_module.kansujiAllAsciiDigits;
pub const kansujiAllAsciiDigitUnits = kansuji_module.kansujiAllAsciiDigitUnits;

const text_module = @import("text.zig");

pub const csvBuiltin = text_module.csvBuiltin;
pub const csvParse = text_module.csvParse;
pub const csvStringify = text_module.csvStringify;
pub const tomlBuiltin = text_module.tomlBuiltin;
pub const tomlParse = text_module.tomlParse;
pub const tomlStringify = text_module.tomlStringify;
pub const markupBuiltin = text_module.markupBuiltin;
pub const courtesyBuiltin = text_module.courtesyBuiltin;
pub const systemExecutionBuiltin = text_module.systemExecutionBuiltin;

pub fn debugBreakpointWaitBuiltin(
    runtime: *Runtime,
    breakpoints: *Value,
    force_wait: *Value,
    wait_flag: *Value,
    plugin_name: *Value,
    arguments: []const Value,
) !Value {
    const line_value = if (arguments.len > 0) arguments[arguments.len - 1] else Value{};
    const line = try valueToNumberRuntime(runtime, line_value);
    const force = valueTruthy(force_wait.*);
    force_wait.* = numberValue(0);
    var breakpoint_hit = false;
    if (breakpoints.object()) |object| if (object.payload == .array) {
        const line_number = numberValue(line);
        for (object.payload.array.items) |candidate| if (try strictEqual(runtime, candidate, line_number)) {
            breakpoint_hit = true;
            break;
        };
    };
    if (!force and !breakpoint_hit) return numberValue(line);
    if (!(try strictEqual(runtime, plugin_name.*, staticStringValue("メイン")))) return createAotPromise(runtime);

    const line_text = try numberString(runtime.allocator, line);
    defer runtime.allocator.free(line_text);
    const marker = try std.fmt.allocPrint(runtime.allocator, "@__DEBUG_BP_WAIT({s})", .{line_text});
    defer runtime.allocator.free(marker);
    writeBytes(marker, true);

    while (true) {
        const flag = wait_flag.*;
        if (flag.tag == @intFromEnum(Tag.number) and @as(f64, @bitCast(flag.payload)) == 1) {
            wait_flag.* = numberValue(0);
            return numberValue(line);
        }
        try waitAotMilliseconds(runtime, 500);
    }
}

pub fn measureCallableBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.NotCallable;
    var roots = [_]Value{ arguments[arguments.len - 1], .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try resolveAotCallback(runtime, roots[0]);
    const started = monotonicTimeMilliseconds(runtime);
    roots[2] = try invokeAotCallback(runtime, roots[1], null, 0);
    const finished = monotonicTimeMilliseconds(runtime);
    return numberValue(finished - started);
}

pub fn shouldRegisterNamedFunction(name: []const u8) bool {
    // HIR gives anonymous functions an internal name for calls and debug
    // metadata, but the official global-function list exposes named language
    // functions only.  Closures must therefore not enter named_functions.
    return name.len > 0 and std.mem.indexOf(u8, name, "__lambda$") == null;
}

pub fn systemGlobalFunctionNamesBuiltin(runtime: *Runtime) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (runtime.named_functions.items) |registered| {
        roots[1] = try runtimeUtf8String(runtime, registered.name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

const node_path_module = @import("node_path.zig");

pub const isWindowsDriveLetter = node_path_module.isWindowsDriveLetter;
pub const isWindowsDriveLetterWide = node_path_module.isWindowsDriveLetterWide;
pub const nodeBasename = node_path_module.nodeBasename;
pub const nodeBasenameFor = node_path_module.nodeBasenameFor;
pub const nodeDirname = node_path_module.nodeDirname;
pub const nodeDirnameFor = node_path_module.nodeDirnameFor;
pub const nodeDirnameWindowsFor = node_path_module.nodeDirnameWindowsFor;
pub const nodePathSeparator = node_path_module.nodePathSeparator;
pub const nodePathSeparatorWide = node_path_module.nodePathSeparatorWide;

pub fn aotOsName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

pub fn aotArchitectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn radixBuiltin(runtime: *Runtime, value: Value, radix_value: Value) !Value {
    const number = try parseIntBuiltin(runtime, value);
    const radix_number: f64 = if (radix_value.tag == @intFromEnum(Tag.undefined)) 10 else try valueToNumberRuntime(runtime, radix_value);
    const truncated = @trunc(radix_number);
    if (!std.math.isFinite(radix_number) or truncated < 2 or truncated > 36) return error.InvalidRadix;
    const text = try number_mod.integerToRadixAlloc(runtime.allocator, number, @intFromFloat(truncated));
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rgbBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    var components: [3]f64 = undefined;
    for (0..3) |index| components[index] = try parseIntBuiltin(runtime, arguments[index]);
    const text = try number_mod.rgbAlloc(runtime.allocator, components);
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rangeBuiltin(runtime: *Runtime, first: Value, last: Value) !Value {
    var roots = [_]Value{ first, last, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createString(&.{ 0x5148, 0x982d });
    roots[3] = try runtime.createString(&.{ 0x672b, 0x5c3e });
    roots[4] = try runtime.createDictionary(&.{ roots[2], roots[0], roots[3], roots[1] });
    return roots[4];
}

pub fn repeatMultiplyBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (!isString(roots[0]) and roots[0].tag != @intFromEnum(Tag.array)) return arithmetic(runtime, .multiply, roots[0], roots[1]);
    const count_number = try parseIntBuiltin(runtime, roots[1]);
    const count: usize = if (std.math.isNan(count_number) or count_number <= 0)
        0
    else if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize))))
        return error.RepetitionTooLarge
    else
        @intFromFloat(@trunc(count_number));
    if (isString(roots[0])) {
        const source = try valueUtf16Alloc(runtime, roots[0]);
        defer runtime.allocator.free(source);
        const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
        const units = try runtime.allocator.alloc(u16, length);
        for (0..count) |index| @memcpy(units[index * source.len ..][0..source.len], source);
        return runtime.ownString(units);
    }
    const source = roots[0].object().?.payload.array.items;
    const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
    const values = try runtime.allocator.alloc(Value, length);
    defer runtime.allocator.free(values);
    for (0..count) |index| @memcpy(values[index * source.len ..][0..source.len], source);
    roots[2] = try runtime.createArray(values);
    return roots[2];
}

const search_module = @import("search.zig");

pub const codePointCount = search_module.codePointCount;
pub const codePointLength = search_module.codePointLength;
pub const codePointFindStringBuiltin = search_module.codePointFindStringBuiltin;
pub const search_element_limit = search_module.search_element_limit;
pub const SearchElements = search_module.SearchElements;
pub const SearchElement = search_module.SearchElement;
pub const searchArrayFromLength = search_module.searchArrayFromLength;
pub const appendStringSearchElements = search_module.appendStringSearchElements;
pub const appendDictionarySearchElements = search_module.appendDictionarySearchElements;
pub const byteBufferArrayLikeProperty = search_module.byteBufferArrayLikeProperty;
pub const appendArrayBufferSearchElements = search_module.appendArrayBufferSearchElements;
pub const searchIndexKey = search_module.searchIndexKey;
pub const appendSearchElements = search_module.appendSearchElements;
pub const joinedSearchElementsEqual = search_module.joinedSearchElementsEqual;
pub const codePointFindBuiltin = search_module.codePointFindBuiltin;
pub const stringBoundaryBuiltin = search_module.stringBoundaryBuiltin;
pub const requireStringReceiver = search_module.requireStringReceiver;
pub const elementCountBuiltin = search_module.elementCountBuiltin;

const primitive_module = @import("primitive.zig");

pub const addParsedBuiltin = primitive_module.addParsedBuiltin;
pub const sumParsedBuiltin = primitive_module.sumParsedBuiltin;
pub const toBigIntBuiltin = primitive_module.toBigIntBuiltin;
pub const jsAdd = primitive_module.jsAdd;
pub const CutResult = primitive_module.CutResult;
pub const cutLengthProperty = primitive_module.cutLengthProperty;
pub const dictionaryLengthValue = primitive_module.dictionaryLengthValue;
pub const cutEndIndex = primitive_module.cutEndIndex;
pub const cutBuiltin = primitive_module.cutBuiltin;
pub const sequentialAddBuiltin = primitive_module.sequentialAddBuiltin;
pub const chrBuiltin = primitive_module.chrBuiltin;
pub const codePointStringBuiltin = primitive_module.codePointStringBuiltin;
pub const ascBuiltin = primitive_module.ascBuiltin;
pub const firstCodePointBuiltin = primitive_module.firstCodePointBuiltin;
pub const stringInsertBuiltin = primitive_module.stringInsertBuiltin;
pub const stringSearchBuiltin = primitive_module.stringSearchBuiltin;
pub const codePointOffsetBuiltin = primitive_module.codePointOffsetBuiltin;
pub const stringCollectionIndex = primitive_module.stringCollectionIndex;
pub const appendBuiltin = primitive_module.appendBuiltin;
pub const joinBuiltin = primitive_module.joinBuiltin;
pub const arrayJoinBuiltin = primitive_module.arrayJoinBuiltin;
pub const arraySearchBuiltin = primitive_module.arraySearchBuiltin;

const sort_module = @import("sort.zig");

pub const arrayOrderingBuiltin = sort_module.arrayOrderingBuiltin;
pub const arrayShuffleBuiltin = sort_module.arrayShuffleBuiltin;
pub const arrayCallbackBuiltin = sort_module.arrayCallbackBuiltin;
pub const stableArrayCallbackSort = sort_module.stableArrayCallbackSort;
pub const v8_small_callback_sort_limit = sort_module.v8_small_callback_sort_limit;
pub const V8TableSortContext = sort_module.V8TableSortContext;
pub const V8SortContext = sort_module.V8SortContext;
pub const compareV8Sort = sort_module.compareV8Sort;
pub const v8SmallArrayCallbackSort = sort_module.v8SmallArrayCallbackSort;
pub const v8CopyArrayRange = sort_module.v8CopyArrayRange;
pub const v8ComputeMinRunLengthArray = sort_module.v8ComputeMinRunLengthArray;
pub const v8CountAndMakeRunArrayCallback = sort_module.v8CountAndMakeRunArrayCallback;
pub const v8BinaryInsertionSortArrayCallback = sort_module.v8BinaryInsertionSortArrayCallback;
pub const v8GallopLeftArrayCallback = sort_module.v8GallopLeftArrayCallback;
pub const v8GallopRightArrayCallback = sort_module.v8GallopRightArrayCallback;
pub const v8MergeLowArrayCallback = sort_module.v8MergeLowArrayCallback;
pub const v8MergeHighArrayCallback = sort_module.v8MergeHighArrayCallback;
pub const v8MergeAtArrayCallback = sort_module.v8MergeAtArrayCallback;
pub const v8RunInvariantEstablishedArray = sort_module.v8RunInvariantEstablishedArray;
pub const v8MergeCollapseArrayCallback = sort_module.v8MergeCollapseArrayCallback;
pub const v8MergeForceCollapseArrayCallback = sort_module.v8MergeForceCollapseArrayCallback;
pub const v8TimSortArrayCallback = sort_module.v8TimSortArrayCallback;
pub const compareAotCallback = sort_module.compareAotCallback;
pub const invokeAotCallback = sort_module.invokeAotCallback;
pub const resolveAotCallback = sort_module.resolveAotCallback;
pub const registeredFunctionMatches = sort_module.registeredFunctionMatches;
pub const stableArraySort = sort_module.stableArraySort;
pub const compareArraySortValues = sort_module.compareArraySortValues;
pub const utf16Order = sort_module.utf16Order;

const collection_module = @import("collection.zig");

pub const arrayItems = collection_module.arrayItems;
pub const spliceIndexRuntime = collection_module.spliceIndexRuntime;
pub const spliceIndexNumber = collection_module.spliceIndexNumber;
pub const spliceCountRuntime = collection_module.spliceCountRuntime;
pub const spliceCountNumber = collection_module.spliceCountNumber;
pub const dictionaryOwnProperty = collection_module.dictionaryOwnProperty;
pub const dictionaryPrototypeProperty = collection_module.dictionaryPrototypeProperty;
pub const dictionaryPrototypeBlocksStandard = collection_module.dictionaryPrototypeBlocksStandard;
pub const arrayPrototypeProperty = collection_module.arrayPrototypeProperty;
pub const arrayPrototypeBlocksStandard = collection_module.arrayPrototypeBlocksStandard;
pub const dictionaryProperty = collection_module.dictionaryProperty;
pub const aotCanonicalArrayIndex = collection_module.aotCanonicalArrayIndex;
pub const aotDictionaryOrder = collection_module.aotDictionaryOrder;
pub const aotDictionaryOrderBefore = collection_module.aotDictionaryOrderBefore;
pub const aotPropertyKeysEqual = collection_module.aotPropertyKeysEqual;
pub const aotEnumerableKeyWasYielded = collection_module.aotEnumerableKeyWasYielded;
pub const aotEnumerableDictionaryEntries = collection_module.aotEnumerableDictionaryEntries;
pub const aotPropertyKeyEqual = collection_module.aotPropertyKeyEqual;
pub const dictionaryKeysBuiltin = collection_module.dictionaryKeysBuiltin;
pub const dictionaryValuesBuiltin = collection_module.dictionaryValuesBuiltin;
pub const dictionaryRemoveBuiltin = collection_module.dictionaryRemoveBuiltin;
pub const byteBufferIndexDeleteFailure = collection_module.byteBufferIndexDeleteFailure;
pub const dictionaryHasBuiltin = collection_module.dictionaryHasBuiltin;
pub const stringValuesEqual = collection_module.stringValuesEqual;
pub const arrayRange = collection_module.arrayRange;
pub const spliceArrayBuiltin = collection_module.spliceArrayBuiltin;
pub const insertValuesAssumeCapacity = collection_module.insertValuesAssumeCapacity;
pub const insertPresenceAssumeCapacity = collection_module.insertPresenceAssumeCapacity;
pub const arrayInsertBuiltin = collection_module.arrayInsertBuiltin;
pub const arrayInsertManyBuiltin = collection_module.arrayInsertManyBuiltin;
pub const arrayCutBuiltin = collection_module.arrayCutBuiltin;
pub const arrayTakeBuiltin = collection_module.arrayTakeBuiltin;
pub const arrayPopBuiltin = collection_module.arrayPopBuiltin;
pub const arrayPushBuiltin = collection_module.arrayPushBuiltin;
pub const arrayMutationBuiltin = collection_module.arrayMutationBuiltin;
pub const sliceIndex = collection_module.sliceIndex;
pub const directIndex = collection_module.directIndex;
pub const bigIntPropertyIndex = collection_module.bigIntPropertyIndex;
pub const charAtIndex = collection_module.charAtIndex;
pub const sliceRange = collection_module.sliceRange;
pub const substringRange = collection_module.substringRange;
pub const arrayRangeCopyBuiltin = collection_module.arrayRangeCopyBuiltin;
pub const referenceBuiltin = collection_module.referenceBuiltin;
pub const invalidStringRangeBuiltin = collection_module.invalidStringRangeBuiltin;
pub const appendAotArraySlot = collection_module.appendAotArraySlot;
pub const arrayAddBuiltin = collection_module.arrayAddBuiltin;
pub const arrayExtremumBuiltin = collection_module.arrayExtremumBuiltin;
pub const isNegativeZero = collection_module.isNegativeZero;
pub const arraySumBuiltin = collection_module.arraySumBuiltin;
pub const arraySwapBuiltin = collection_module.arraySwapBuiltin;
pub const fillArrayLength = collection_module.fillArrayLength;
pub const arraySequenceBuiltin = collection_module.arraySequenceBuiltin;
pub const arrayFillBuiltin = collection_module.arrayFillBuiltin;
pub const validateFillDimensions = collection_module.validateFillDimensions;
pub const cloneFillValue = collection_module.cloneFillValue;
pub const arrayFillAtDepth = collection_module.arrayFillAtDepth;
pub const explodeBuiltin = collection_module.explodeBuiltin;
pub const refrainBuiltin = collection_module.refrainBuiltin;
pub const occurrenceBuiltin = collection_module.occurrenceBuiltin;
pub const occurrenceCountBuiltin = collection_module.occurrenceCountBuiltin;
pub const substringBuiltin = collection_module.substringBuiltin;
pub const substringNumberBuiltin = collection_module.substringNumberBuiltin;
pub const sliceIndexBuiltin = collection_module.sliceIndexBuiltin;
pub const splitBuiltin = collection_module.splitBuiltin;
pub const appendStringPart = collection_module.appendStringPart;
pub const stringRemoveBuiltin = collection_module.stringRemoveBuiltin;
pub const spliceDeleteCountBuiltin = collection_module.spliceDeleteCountBuiltin;
pub const trimBuiltin = collection_module.trimBuiltin;
pub const unicodeCaseBuiltin = collection_module.unicodeCaseBuiltin;
pub const isFinalSigmaBuiltin = collection_module.isFinalSigmaBuiltin;
pub const appendCodePointBuiltin = collection_module.appendCodePointBuiltin;

const table_module = @import("table.zig");

pub const tableAsciiUnitsEqual = table_module.tableAsciiUnitsEqual;
pub const tableInheritedMethodName = table_module.tableInheritedMethodName;
pub const tableBufferEnumerableFunctionName = table_module.tableBufferEnumerableFunctionName;
pub const tableInheritedFunctionWithCallback = table_module.tableInheritedFunctionWithCallback;
pub const tableInheritedFunction = table_module.tableInheritedFunction;
pub const tableInheritedByteBufferMethod = table_module.tableInheritedByteBufferMethod;
pub const tableInheritedProperty = table_module.tableInheritedProperty;
pub const tableRowProperty = table_module.tableRowProperty;
pub const setTableRowPropertyFailure = table_module.setTableRowPropertyFailure;
pub const tablePropertyKeyEqual = table_module.tablePropertyKeyEqual;
pub const tablePropertyIndex = table_module.tablePropertyIndex;
pub const tableColumnCountBuiltin = table_module.tableColumnCountBuiltin;
pub const tableSearchBuiltin = table_module.tableSearchBuiltin;
pub const tableColumnIterationCount = table_module.tableColumnIterationCount;
pub const tableTransposeBuiltin = table_module.tableTransposeBuiltin;
pub const tableDictionaryHasKey = table_module.tableDictionaryHasKey;
pub const tableIsObjectPrototypeKey = table_module.tableIsObjectPrototypeKey;
pub const tableUniqueBuiltin = table_module.tableUniqueBuiltin;
pub const tableInsertColumnBuiltin = table_module.tableInsertColumnBuiltin;
pub const aotByteBufferSlice = table_module.aotByteBufferSlice;
pub const tableDeleteColumnBuiltin = table_module.tableDeleteColumnBuiltin;
pub const tableColumnSumBuiltin = table_module.tableColumnSumBuiltin;
pub const tableRegexpPatternUnitsAlloc = table_module.tableRegexpPatternUnitsAlloc;
pub const tableRegexpSearchBuiltin = table_module.tableRegexpSearchBuiltin;
pub const tableRegexpPickupBuiltin = table_module.tableRegexpPickupBuiltin;
pub const incrementTableSearchRow = table_module.incrementTableSearchRow;
pub const compareTableRowsBuiltin = table_module.compareTableRowsBuiltin;
pub const tableSortBuiltin = table_module.tableSortBuiltin;
pub const v8SmallTableSortBuiltin = table_module.v8SmallTableSortBuiltin;
pub const tableBuiltin = table_module.tableBuiltin;
pub const deepCloneBuiltin = table_module.deepCloneBuiltin;
pub const deepCloneValue = table_module.deepCloneValue;
pub const CloneState = table_module.CloneState;
pub const table_byte_buffer_buffer_enumerable_property_names = table_module.table_byte_buffer_buffer_enumerable_property_names;

const string_module = @import("string.zig");

pub const kanaOffsetBuiltin = string_module.kanaOffsetBuiltin;
pub const asciiWidthBuiltin = string_module.asciiWidthBuiltin;
pub const kanaWidthBuiltin = string_module.kanaWidthBuiltin;
pub const widthBuiltin = string_module.widthBuiltin;
pub const currencyBuiltin = string_module.currencyBuiltin;
pub const padBuiltin = string_module.padBuiltin;
pub const stringPredicateBuiltin = string_module.stringPredicateBuiltin;
pub const numberSequenceBuiltin = string_module.numberSequenceBuiltin;
pub const isAsciiDigitBuiltin = string_module.isAsciiDigitBuiltin;
pub const isSequenceDigitBuiltin = string_module.isSequenceDigitBuiltin;
pub const isSequenceSignBuiltin = string_module.isSequenceSignBuiltin;
pub const kanaMapBuiltin = string_module.kanaMapBuiltin;
pub const kanaMapDictionaryFullWidthBuiltin = string_module.kanaMapDictionaryFullWidthBuiltin;
pub const kanaMapDictionaryHalfWidthBuiltin = string_module.kanaMapDictionaryHalfWidthBuiltin;
pub const unitIndexBuiltin = string_module.unitIndexBuiltin;
pub const indexOfUnitsBuiltin = string_module.indexOfUnitsBuiltin;
pub const replaceBuiltin = string_module.replaceBuiltin;
pub const appendFirstReplacementBuiltin = string_module.appendFirstReplacementBuiltin;

pub fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

pub fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}

const values_module = @import("values.zig");
const instructions_module = @import("instructions.zig");
const functions_module = @import("functions.zig");

pub const lnako_aot_string_new = values_module.lnako_aot_string_new;
pub const lnako_aot_print_utf16 = values_module.lnako_aot_print_utf16;
pub const lnako_aot_print_number = values_module.lnako_aot_print_number;
pub const lnako_aot_bigint_new = values_module.lnako_aot_bigint_new;
pub const lnako_aot_print_bigint = values_module.lnako_aot_print_bigint;
pub const lnako_aot_print_collection = values_module.lnako_aot_print_collection;
pub const lnako_aot_display_value = values_module.lnako_aot_display_value;
pub const lnako_aot_array_new = values_module.lnako_aot_array_new;
pub const lnako_aot_dictionary_new = values_module.lnako_aot_dictionary_new;
pub const lnako_aot_caniuse_agents_new = values_module.lnako_aot_caniuse_agents_new;
pub const lnako_aot_era_data_new = values_module.lnako_aot_era_data_new;

pub const lnako_aot_bigint_truthy = instructions_module.lnako_aot_bigint_truthy;
pub const lnako_aot_arithmetic = instructions_module.lnako_aot_arithmetic;
pub const lnako_aot_compare = instructions_module.lnako_aot_compare;
pub const lnako_aot_shift = instructions_module.lnako_aot_shift;
pub const lnako_aot_concat = instructions_module.lnako_aot_concat;
pub const lnako_aot_increment = instructions_module.lnako_aot_increment;
pub const lnako_aot_index_get = instructions_module.lnako_aot_index_get;
pub const lnako_aot_index_set = instructions_module.lnako_aot_index_set;
pub const lnako_aot_destructure_get = instructions_module.lnako_aot_destructure_get;
pub const lnako_aot_iterator_new = instructions_module.lnako_aot_iterator_new;
pub const lnako_aot_iterator_has_next = instructions_module.lnako_aot_iterator_has_next;
pub const lnako_aot_iterator_next = instructions_module.lnako_aot_iterator_next;
pub const lnako_aot_binding_cell_new = instructions_module.lnako_aot_binding_cell_new;
pub const lnako_aot_binding_cell_value = instructions_module.lnako_aot_binding_cell_value;
pub const lnako_aot_cut = instructions_module.lnako_aot_cut;
pub const lnako_aot_cut_site = instructions_module.lnako_aot_cut_site;

pub const lnako_aot_native_plugin_register = functions_module.lnako_aot_native_plugin_register;
pub const lnako_aot_dynamic_global_register = functions_module.lnako_aot_dynamic_global_register;
pub const lnako_aot_dynamic_call = functions_module.lnako_aot_dynamic_call;
pub const lnako_aot_native_plugin_call = functions_module.lnako_aot_native_plugin_call;
pub const lnako_aot_function_new = functions_module.lnako_aot_function_new;
pub const lnako_aot_function_new_named = functions_module.lnako_aot_function_new_named;
pub const lnako_aot_function_capture = functions_module.lnako_aot_function_capture;
pub const lnako_aot_function_call = functions_module.lnako_aot_function_call;
