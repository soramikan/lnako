const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");
const environment = @import("../environment.zig");
const counters = @import("../counters.zig");
const allocator_telemetry = @import("../allocator_telemetry.zig");
const dictionary_module = @import("dictionary.zig");
const http_ingress = @import("../../http_ingress.zig");
const byte_storage = @import("byte_storage.zig");
const csv_state = @import("csv_state.zig");
const async_types = @import("async_types.zig");
const low_level_io = @import("../low_level_io.zig");

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
const aotCanonicalArrayIndex = aot_state.aotCanonicalArrayIndex;
const sameKey = aot_state.sameKey;
const isString = aot_state.isString;
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

/// Number of entries at which a dictionary builds its lookup index.  Below
/// the threshold a linear scan over the ordered list is cheaper than
/// hashing; at and above it an open-addressed slot table maps each key's
/// hash to entry positions.
pub const aot_dictionary_index_threshold: usize = 24;

const aot_index_seed: u64 = 0x9e3779b97f4a7c15;

pub fn aotIndexHashUnits(units: []const u16) u64 {
    return std.hash.Wyhash.hash(aot_index_seed, std.mem.sliceAsBytes(units));
}

fn aotIndexHashUtf8(bytes: []const u8) u64 {
    // Hash the decoded UTF-16 unit stream so a static literal and an equal
    // runtime string land in the same slot.  Malformed input can never match
    // a UTF-16 key, so the remaining bytes are hashed verbatim only to keep
    // identical byte strings colliding together.
    var hasher = std.hash.Wyhash.init(aot_index_seed);
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            hasher.update(bytes[index..]);
            break;
        };
        if (index + length > bytes.len) {
            hasher.update(bytes[index..]);
            break;
        }
        const codepoint = std.unicode.utf8Decode(bytes[index .. index + length]) catch {
            hasher.update(bytes[index..]);
            break;
        };
        index += length;
        if (codepoint <= 0xffff) {
            const unit: u16 = @intCast(codepoint);
            hasher.update(std.mem.asBytes(&unit));
        } else {
            const offset = codepoint - 0x10000;
            const pair = [2]u16{ @intCast(0xd800 + (offset >> 10)), @intCast(0xdc00 + (offset & 0x3ff)) };
            hasher.update(std.mem.sliceAsBytes(&pair));
        }
    }
    return hasher.final();
}

fn aotIndexHash(key: Value) u64 {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .utf16_string => aotIndexHashUnits(key.object().?.payload.utf16_string),
        .static_utf8_string => aotIndexHashUtf8(staticUtf8(key)),
        // BigInt keys compare by value, not identity; a fixed bucket keeps
        // indexed lookups correct while rare keys stay out of the fast path.
        .bigint => aot_index_seed,
        else => blk: {
            var hasher = std.hash.Wyhash.init(aot_index_seed);
            hasher.update(std.mem.asBytes(&key.tag));
            hasher.update(std.mem.asBytes(&key.payload));
            break :blk hasher.final();
        },
    };
}

fn aotIndexKeyMatchesUnits(key: Value, units: []const u16) bool {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string => staticUtf8EqualsUtf16(staticUtf8(key), units),
        .utf16_string => std.mem.eql(u16, key.object().?.payload.utf16_string, units),
        else => false,
    };
}

/// Insertion-ordered key/value storage with an optional open-addressed
/// index.  `entries` alone defines membership and enumeration order; the
/// index is a pure lookup cache whose slots store `entry_index + 1` and
/// whose zero value marks an empty slot.  Every mutation funnels through
/// `set`, `appendEntry`, `orderedRemoveEntry`, or `clearRetainingCapacity`
/// so the index never observes a stale view, and removal rebuilds it
/// because `orderedRemove` shifts every later position.  A probe walks the
/// whole hash cluster and returns the smallest matching index, so a
/// duplicated key resolves to the same first entry a linear scan finds.
pub const AotDictionary = dictionary_module.make(Value, DictionaryEntry, aotIndexHash, aotIndexHashUnits, aotIndexKeyMatchesUnits, sameKey, aot_dictionary_index_threshold);
pub const io_tasks = @import("io_tasks.zig");
pub const AotTomlTemporal = io_tasks.AotTomlTemporal;
pub const AotHttpRoute = io_tasks.AotHttpRoute;
pub const AotHttpHeader = io_tasks.AotHttpHeader;
const AotHttpServerState = io_tasks.AotHttpServerState;
const AotHttpGlobals = io_tasks.AotHttpGlobals;
pub const AotArchiveOperation = io_tasks.AotArchiveOperation;
pub const AotArchiveTask = io_tasks.AotArchiveTask;
pub const AotProcessMode = io_tasks.AotProcessMode;
pub const AotCommandResult = io_tasks.AotCommandResult;
pub const AotProcessTask = io_tasks.AotProcessTask;
pub const AotFileTaskOperation = io_tasks.AotFileTaskOperation;
pub const AotFileTask = io_tasks.AotFileTask;
pub const AotClientHttpResult = io_tasks.AotClientHttpResult;
pub const AotClientHttpMode = io_tasks.AotClientHttpMode;
pub const AotClientHttpBodyKind = io_tasks.AotClientHttpBodyKind;
pub const AotClientHttpTask = io_tasks.AotClientHttpTask;

pub const indexing = @import("indexing.zig");
pub const ByteKind = byte_storage.Kind;
const ByteStorage = byte_storage.Storage(Value);
pub const ByteBuffer = byte_storage.Buffer(ByteStorage);
pub const AotTimer = async_types.Timer(Value);
const IteratorKind = async_types.IteratorKind;
const Iterator = async_types.Iterator(Value);

pub const AotPromiseState = async_types.PromiseState;
pub const AotPromiseReactionMode = async_types.PromiseReactionMode;
pub const AotPromiseReaction = async_types.PromiseReaction(Value, Object);
const AotPromise = async_types.Promise(Value, Object);
pub const AotPromiseTask = async_types.PromiseTask(Value, Object);
pub const AotPromiseAllState = async_types.PromiseAllState(Value, Object);
pub const AotPromiseResolver = async_types.PromiseResolver(Object);
pub const AotPromiseAllHandler = async_types.PromiseAllHandler(AotPromiseAllState);

pub const AotPromiseChainKind = enum { success, failure, settled, finally };
const PromiseFunctionKind = union(enum) {
    none,
    resolver: AotPromiseResolver,
    all_handler: AotPromiseAllHandler,
};
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

pub const AotCsvDelimiterDefault = csv_state.DelimiterDefault;
pub const AotCsvState = csv_state.State;

pub const default_plugin_names = [_][]const u8{
    "plugin_system",
    "plugin_math",
    "plugin_promise",
    "plugin_test",
    "plugin_csv",
    "plugin_toml",
    "plugin_node",
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

pub const UnaryOperator = enum(u8) {
    minus,
    plus,
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
    dictionary: AotDictionary,
    iterator: Iterator,
    function: FunctionObject,
    binding_cell: Value,
    promise: AotPromise,
};

pub const Object = struct {
    next: ?*Object = null,
    grey_next: ?*Object = null,
    marked: bool = false,
    /// UTF-16 string objects may keep their code units directly after the
    /// Object header.  The flag distinguishes that allocation from the
    /// standalone payload used by `ownString`.
    inline_utf16: bool = false,
    /// Object-literal `__proto__`; the undefined value means the ordinary
    /// Object prototype and explicit null preserves a null-prototype object.
    prototype: Value = .{},
    /// Own properties for arrays and for the other extensible object kinds.
    /// The legacy field name is retained because array operations and their
    /// serialized fixtures already use it.
    array_properties: AotDictionary = .{},
    array_presence: std.ArrayList(bool) = .empty,
    toml_temporal: ?AotTomlTemporal = null,
    structured_error: bool = false,
    payload: Payload,
};

/// A freshly allocated, exact-sized UTF-16 string payload.  The Object is
/// already linked into the runtime's GC list, but this helper performs no
/// further allocation after returning; callers can fill `units` before the
/// next GC point and return `value` without an intermediate copy.
pub const StringAllocation = struct {
    value: Value,
    units: []u16,
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
    http_ingress: ?*http_ingress.Engine = null,
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
    counters: counters.Counters = .{},
    allocator_telemetry: ?*allocator_telemetry.Telemetry = null,
    allocator_telemetry_checked: bool = false,
    perf_counters_checked: bool = false,
    perf_counters_enabled: bool = false,
    live_roots: u64 = 0,
    dynamic_globals: std.ArrayList(DynamicGlobal) = .empty,
    dynamic_state: ?*DynamicInterpreterState = null,
    // dynamic_stateの解放とnative plugin drainはdynamic.zigがinit時に
    // 登録する間接呼び出しで行う。直接メソッドを呼ぶと生成物が常に
    // 埋め込みinterpreterと全pluginを静的参照し、dead-stripできなくなる。
    dynamic_deinit: ?*const fn (*Runtime) void = null,
    dynamic_drain: ?*const fn (*Runtime) anyerror!bool = null,
    dynamic_forget_handle: ?*const fn (*Runtime, u64) void = null,
    dynamic_promise_bridges: std.ArrayList(*DynamicPromiseBridge) = .empty,
    dynamic_function_bridges: std.ArrayList(*AotFunctionBridge) = .empty,
    standard_property_cache: std.ArrayList(StandardPropertyCacheEntry) = .empty,
    low_level_handles: ?low_level_io.FileHandleTable = null,
    low_level_handle_ids: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    low_level_handle_by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    /// Canonical storage for emitted string literals.  `lnako_aot_string_literal`
    /// fills each slot once so every use of the same literal shares one string
    /// object; the list also keeps the cached strings reachable for GC.
    literal_values: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *Runtime) void {
        self.dispatch_trace.deinit();
        self.global_trace.deinit();
        self.literal_trace.deinit();
        const io = std.Io.Threaded.global_single_threaded.io();
        aot_state.aotHttpIngressStop(self);
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
        if (self.low_level_handles) |*table| table.deinit(io);
        self.low_level_handle_ids.deinit(self.allocator);
        self.low_level_handle_by_id.deinit(self.allocator);
        if (self.dynamic_deinit) |deinit_dynamic| deinit_dynamic(self);
        for (self.dynamic_promise_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_promise_bridges.deinit(self.allocator);
        for (self.dynamic_function_bridges.items) |bridge| self.allocator.destroy(bridge);
        self.dynamic_function_bridges.deinit(self.allocator);
        for (self.standard_property_cache.items) |entry| self.allocator.free(entry.name);
        self.standard_property_cache.deinit(self.allocator);
        self.literal_values.deinit(self.allocator);
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
        self.aggregateDictionaryCounters();
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.destroyObject(object);
            current = next;
        }
        self.named_functions.deinit(self.allocator);
        self.stringifying_arrays.deinit(self.allocator);
        self.syncAllocatorTelemetry();
        self.reportCounters();
        self.releaseAllocatorTelemetry();
        self.* = undefined;
    }

    pub fn ensureAllocatorTelemetry(self: *Runtime) !void {
        if (self.allocator_telemetry_checked) return;
        self.allocator_telemetry_checked = true;
        if (!allocator_telemetry.enabled() and !self.perf_counters_enabled) return;
        if (allocator_telemetry.Telemetry.init(self.allocator)) |telemetry| {
            self.allocator_telemetry = telemetry;
            self.allocator = telemetry.allocator();
            self.counters.allocator_telemetry_active = 1;
        } else |_| {
            self.counters.allocator_telemetry_init_failures +|= 1;
        }
    }

    fn perfCountersEnabled(self: *Runtime) bool {
        if (!self.perf_counters_checked) {
            self.perf_counters_checked = true;
            self.perf_counters_enabled = allocator_telemetry.enabled();
        }
        return self.perf_counters_enabled;
    }

    pub fn recordAotEntry(self: *Runtime, entry: *counters.Counters.AotEntryCounters, success: bool) void {
        if (!self.perfCountersEnabled()) return;
        entry.calls +|= 1;
        if (success) entry.successes +|= 1 else entry.failures +|= 1;
    }

    pub fn syncAllocatorTelemetry(self: *Runtime) void {
        const telemetry = self.allocator_telemetry orelse return;
        const snapshot = telemetry.snapshot();
        self.counters.allocator_alloc_calls = snapshot.alloc_calls;
        self.counters.allocator_resize_calls = snapshot.resize_calls;
        self.counters.allocator_remap_calls = snapshot.remap_calls;
        self.counters.allocator_free_calls = snapshot.free_calls;
        self.counters.allocator_live_bytes = snapshot.live_bytes;
        self.counters.allocator_peak_live_bytes = snapshot.peak_live_bytes;
        self.counters.gc_mark_ns = snapshot.gc_mark_ns;
        self.counters.gc_sweep_ns = snapshot.gc_sweep_ns;
    }

    fn releaseAllocatorTelemetry(self: *Runtime) void {
        const telemetry = self.allocator_telemetry orelse return;
        self.allocator = telemetry.base;
        telemetry.deinit();
        self.allocator_telemetry = null;
    }

    pub fn cachedStandardProperty(self: *Runtime, kind: u8, name: []const u8) ?Value {
        for (self.standard_property_cache.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn cacheStandardProperty(self: *Runtime, kind: u8, name: []const u8, value: Value) !void {
        if (self.cachedStandardProperty(kind, name) != null) return;
        try self.ensureAllocatorTelemetry();
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.standard_property_cache.append(self.allocator, .{ .kind = kind, .name = owned_name, .value = value });
    }

    pub fn createString(self: *Runtime, units: []const u16) !Value {
        // Callers may pass a borrowed slice from an unrooted string. Preserve
        // copy-before-collection semantics without a temporary payload copy.
        const collect_due = self.object_count >= self.next_collection;
        const allocation = try self.allocStringWithoutCollection(units.len);
        @memcpy(allocation.units, units);
        if (collect_due) {
            var roots = [_]Value{allocation.value};
            var frame: RootFrame = .{};
            self.pushRoots(&frame, &roots, roots.len);
            defer self.popRoots(&frame);
            try self.beforeAllocation();
        }
        return allocation.value;
    }

    /// Allocate an Object and its exact UTF-16 payload in one block.  The
    /// payload is intentionally left uninitialized so callers that already
    /// know the output length (notably concat) can write each operand exactly
    /// once.  No operation that can trigger GC may occur between returning
    /// this value and filling `units`.
    pub fn allocString(self: *Runtime, len: usize) !StringAllocation {
        try self.beforeAllocation();
        return self.allocStringWithoutCollection(len);
    }

    fn allocStringWithoutCollection(self: *Runtime, len: usize) !StringAllocation {
        try self.ensureAllocatorTelemetry();
        const payload_bytes = std.math.mul(usize, len, @sizeOf(u16)) catch return error.OutOfMemory;
        const allocation_size = std.math.add(usize, @sizeOf(Object), payload_bytes) catch return error.OutOfMemory;
        const block = try self.allocator.alignedAlloc(u8, .of(Object), allocation_size);
        errdefer self.allocator.free(block);

        const object: *Object = @ptrCast(@alignCast(block.ptr));
        const payload_ptr: [*]u16 = @ptrCast(@alignCast(block.ptr + @sizeOf(Object)));
        const owned = payload_ptr[0..len];
        object.* = .{
            .next = self.objects,
            .inline_utf16 = true,
            .payload = .{ .utf16_string = owned },
        };
        self.objects = object;
        self.object_count += 1;
        self.counters.allocations +|= 1;
        self.counters.allocated_bytes +|= @as(u64, @intCast(allocation_size));
        self.counters.string_payload_allocations +|= 1;
        self.counters.string_payload_bytes +|= @as(u64, @intCast(payload_bytes));
        self.counters.object_high_water = @max(self.counters.object_high_water, self.object_count);
        return .{ .value = .{ .tag = @intFromEnum(Tag.utf16_string), .payload = @intFromPtr(object) }, .units = owned };
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
        try self.ensureAllocatorTelemetry();
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
        try self.ensureAllocatorTelemetry();
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
            .dictionary => .{ .kind = .dictionary, .source = values[0], .count = values[0].object().?.payload.dictionary.entries.items.len },
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
        try self.ensureAllocatorTelemetry();
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
        try self.ensureAllocatorTelemetry();
        const object = try self.allocator.create(Object);
        self.counters.allocations +|= 1;
        self.counters.allocated_bytes +|= @sizeOf(Object);
        errdefer {
            object.array_presence.deinit(self.allocator);
            self.allocator.destroy(object);
        }
        object.* = .{
            .next = self.objects,
            .payload = payload,
        };
        if (tag == .utf16_string) {
            self.counters.string_payload_allocations +|= 1;
            self.counters.string_payload_bytes +|= @as(u64, @intCast(payload.utf16_string.len)) *| @sizeOf(u16);
        }
        if (tag == .array) {
            try object.array_presence.resize(self.allocator, object.payload.array.items.len);
            @memset(object.array_presence.items, true);
        }
        self.objects = object;
        self.object_count += 1;
        self.counters.object_high_water = @max(self.counters.object_high_water, self.object_count);
        return .{ .tag = @intFromEnum(tag), .payload = @intFromPtr(object) };
    }

    pub fn beforeAllocation(self: *Runtime) !void {
        try self.ensureAllocatorTelemetry();
        if (self.object_count < self.next_collection) return;
        _ = self.collect();
        self.next_collection = @max(@as(usize, 64), self.object_count * 2);
    }

    pub fn pushRoots(self: *Runtime, frame: *RootFrame, values: ?[*]Value, len: usize) void {
        frame.* = .{ .previous = self.roots, .values = values, .len = len };
        self.roots = frame;
        self.counters.root_pushes +|= 1;
        self.live_roots +|= len;
        self.counters.root_high_water = @max(self.counters.root_high_water, self.live_roots);
    }

    pub fn popRoots(self: *Runtime, frame: *RootFrame) void {
        if (self.roots != frame) return;
        self.roots = frame.previous;
        self.live_roots -|= frame.len;
        frame.* = .{};
    }

    pub fn collect(self: *Runtime) usize {
        self.counters.gc_collections +|= 1;
        const mark_started = if (self.allocator_telemetry != null) allocator_telemetry.nowNs() else 0;
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
        for (self.literal_values.items) |value| self.markValue(value);
        var low_level_handles = self.low_level_handle_ids.iterator();
        while (low_level_handles.next()) |entry| {
            self.markValue(.{ .tag = @intFromEnum(Tag.dictionary), .payload = entry.key_ptr.* });
        }
        while (self.grey) |object| {
            self.grey = object.grey_next;
            object.grey_next = null;
            self.counters.gc_scanned_objects +|= 1;
            self.counters.gc_scanned_bytes +|= @sizeOf(Object);
            switch (object.payload) {
                .utf16_string, .bigint => {},
                .byte_buffer => {
                    self.markValue(object.prototype);
                    self.markValue(object.payload.byte_buffer.storage.backing);
                    for (object.array_properties.entries.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .function => |function| {
                    self.markValue(function.prototype);
                    for (object.array_properties.entries.items) |property| {
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
                    for (object.array_properties.entries.items) |property| {
                        self.markValue(property.key);
                        self.markValue(property.value);
                    }
                },
                .dictionary => |*entries| {
                    self.markValue(object.prototype);
                    for (entries.entries.items) |entry| {
                        self.markValue(entry.key);
                        self.markValue(entry.value);
                    }
                },
                .iterator => |iterator| self.markValue(iterator.source),
                .promise => |promise| {
                    self.markValue(promise.result);
                    for (object.array_properties.entries.items) |property| {
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
        if (self.allocator_telemetry) |telemetry| telemetry.recordMarkNs(allocator_telemetry.nowNs() - mark_started);
        const sweep_started = if (self.allocator_telemetry != null) allocator_telemetry.nowNs() else 0;
        var reclaimed: usize = 0;
        var link = &self.objects;
        while (link.*) |object| {
            if (object.marked) {
                object.marked = false;
                link = &object.next;
                continue;
            }
            link.* = object.next;
            self.counters.gc_reclaimed_objects +|= 1;
            // Keep the established counter definition as reclaimed Object
            // header bytes; string payload bytes are reported separately by
            // `string_payload_bytes` and `allocated_bytes`.
            self.counters.gc_reclaimed_bytes +|= @sizeOf(Object);
            self.destroyObject(object);
            self.object_count -= 1;
            reclaimed += 1;
        }
        if (self.allocator_telemetry) |telemetry| telemetry.recordSweepNs(allocator_telemetry.nowNs() - sweep_started);
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
        self.ensureAllocatorTelemetry() catch |allocation_failure| runtimeFailure(allocation_failure);
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
        self.ensureAllocatorTelemetry() catch |allocation_failure| runtimeFailure(allocation_failure);
        const key_units = valueUtf16Alloc(self, key) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_units);
        const key_utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, key_units) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_utf8);
        const container_name: []const u8 = if (container.tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
        const message = std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 }) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(message);
        self.setFailureText(message);
    }

    /// 未宣言変数への添字アクセス失敗（公式の TypeError『Cannot read properties
    /// of undefined/null (reading '<key>')』相当）。
    pub fn setIndexReadFailure(self: *Runtime, container: ?Value, key: Value) void {
        self.ensureAllocatorTelemetry() catch |allocation_failure| runtimeFailure(allocation_failure);
        const key_units = valueUtf16Alloc(self, key) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_units);
        const key_utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, key_units) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_utf8);
        const container_name: []const u8 = if (container != null and container.?.tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
        const message = std.fmt.allocPrint(self.allocator, "Cannot read properties of {s} (reading '{s}')", .{ container_name, key_utf8 }) catch |failure| runtimeFailure(failure);
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
        const inline_utf16 = object.inline_utf16;
        switch (object.payload) {
            .utf16_string => |units| if (!inline_utf16) self.allocator.free(units),
            .byte_buffer => |buffer| {
                buffer.storage.release();
                object.array_properties.deinit(self.allocator);
            },
            .bigint => |*value| value.deinit(),
            .array => |*items| {
                items.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
            },
            .dictionary => |*entries| {
                entries.deinit(self.allocator);
                object.array_properties.deinit(self.allocator);
            },
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
        object.array_presence.deinit(self.allocator);
        if (inline_utf16) {
            const units_len = switch (object.payload) {
                .utf16_string => |units| units.len,
                else => unreachable,
            };
            const payload_bytes = std.math.mul(usize, units_len, @sizeOf(u16)) catch unreachable;
            const allocation_size = std.math.add(usize, @sizeOf(Object), payload_bytes) catch unreachable;
            const block_ptr: [*]align(@alignOf(Object)) u8 = @ptrCast(object);
            const block: []align(@alignOf(Object)) u8 = block_ptr[0..allocation_size];
            self.allocator.free(block);
        } else {
            self.allocator.destroy(object);
        }
    }

    pub fn indexGet(self: *Runtime, container: Value, key: Value) Value {
        return indexing.indexGet(self, container, key);
    }

    pub fn destructureGet(self: *Runtime, source: Value, index: usize) Value {
        return indexing.destructureGet(self, source, index);
    }

    pub fn indexSet(self: *Runtime, container: Value, key: Value, value: Value) !void {
        return indexing.indexSet(self, container, key, value);
    }

    pub fn setAotOwnProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        return indexing.setAotOwnProperty(self, container, object, key, value);
    }

    pub fn setAotFunctionProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
        return indexing.setAotFunctionProperty(self, container, object, key, value);
    }

    pub fn aotArrayPropertyGet(self: *Runtime, object: *const Object, key: Value) Value {
        return indexing.aotArrayPropertyGet(self, object, key);
    }

    pub fn aotArrayIsPresent(self: *Runtime, object: *const Object, index: usize) bool {
        return indexing.aotArrayIsPresent(self, object, index);
    }

    pub fn normalizeAotArrayPresence(self: *Runtime, object: *Object) !void {
        return indexing.normalizeAotArrayPresence(self, object);
    }

    pub fn aotArraySetIndex(self: *Runtime, object: *Object, index: usize, value: Value) !void {
        return indexing.aotArraySetIndex(self, object, index, value);
    }

    pub fn aotArrayDeleteIndex(self: *Runtime, object: *Object, index: usize) !bool {
        return indexing.aotArrayDeleteIndex(self, object, index);
    }

    pub fn aotArrayAppend(self: *Runtime, object: *Object, value: Value) !void {
        return indexing.aotArrayAppend(self, object, value);
    }

    pub fn aotArrayPropertySet(self: *Runtime, object: *Object, key: Value, value: Value) !void {
        return indexing.aotArrayPropertySet(self, object, key, value);
    }

    pub fn aotArrayPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) Value {
        return indexing.aotArrayPropertyGetUnits(self, object, key_units);
    }

    pub fn aotArrayOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        return indexing.aotArrayOwnPropertyGetUnits(self, object, key_units);
    }

    pub fn aotObjectOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
        return indexing.aotObjectOwnPropertyGetUnits(self, object, key_units);
    }

    pub fn aotPropertyKeyMatchesUnits(self: *Runtime, key: Value, units: []const u16) bool {
        return indexing.aotPropertyKeyMatchesUnits(self, key, units);
    }

    pub fn aotCanonicalArrayIndexUnits(self: *Runtime, units: []const u16) ?usize {
        return indexing.aotCanonicalArrayIndexUnits(self, units);
    }

    pub fn iteratorHasNext(self: *Runtime, value: Value) bool {
        return indexing.iteratorHasNext(self, value);
    }

    pub fn iteratorNext(self: *Runtime, value: Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) Value {
        return indexing.iteratorNext(self, value, repeat_target, value_target, key_target, range_target);
    }

    pub fn stringAt(self: *Runtime, source: Value, index: usize) Value {
        return indexing.stringAt(self, source, index);
    }

    pub fn setDictionary(self: *Runtime, entries: *AotDictionary, key: Value, value: Value) !void {
        return indexing.setDictionary(self, entries, key, value);
    }

    pub fn propertyKey(self: *Runtime, key: Value) !Value {
        return indexing.propertyKey(self, key);
    }

    fn aggregateAotDictionaryCounters(self: *Runtime, dict: *AotDictionary) void {
        self.counters.dictionary_probes +|= dict.indexed_lookups + dict.linear_lookups;
        self.counters.dictionary_hits +|= dict.hits;
        self.counters.dictionary_misses +|= dict.misses;
        self.counters.dictionary_linear_steps +|= dict.linear_lookups;
        self.counters.dictionary_index_lookups +|= dict.indexed_lookups;
        self.counters.dictionary_entry_comparisons +|= dict.entry_comparisons;
        self.counters.dictionary_index_rebuilds +|= dict.index_rebuilds;
    }

    fn aggregateDictionaryCounters(self: *Runtime) void {
        var current = self.objects;
        while (current) |object| : (current = object.next) {
            self.aggregateAotDictionaryCounters(&object.array_properties);
            switch (object.payload) {
                .dictionary => |*dict| self.aggregateAotDictionaryCounters(dict),
                else => {},
            }
        }
    }

    fn reportCounters(self: *const Runtime) void {
        if (!allocator_telemetry.enabled() and !environment.valueEquals("LNAKO_PERF_COUNTERS", "1")) return;
        std.debug.print("lnako perf counters: {}\n", .{self.counters});
    }
};

test {
    _ = @import("runtime_core_test.zig");
}
