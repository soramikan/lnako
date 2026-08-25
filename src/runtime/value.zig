const std = @import("std");
const string_mod = @import("string.zig");
const bigint_mod = @import("bigint.zig");

pub const String = string_mod.String;
pub const BigInt = bigint_mod.BigInt;

pub const ByteKind = enum { buffer, uint8_array, array_buffer };

pub const ExternalHandle = struct {
    context: *anyopaque,
    handle: *anyopaque,
    releaseFn: *const fn (context: *anyopaque, handle: *anyopaque) void,

    pub fn deinit(self: ExternalHandle) void {
        self.releaseFn(self.context, self.handle);
    }
};

pub const ByteBuffer = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    bytes: []u8,
    kind: ByteKind = .buffer,

    pub fn deinit(self: *ByteBuffer) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn get(self: ByteBuffer, index: usize) Value {
        if (index >= self.bytes.len) return .undefined;
        return .{ .number = @floatFromInt(self.bytes[index]) };
    }

    pub fn set(self: *ByteBuffer, index: usize, value: u8) void {
        if (index < self.bytes.len) self.bytes[index] = value;
    }
};

pub const Array = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    items: std.ArrayList(Value) = .empty,
    external: ?ExternalHandle = null,

    pub fn deinit(self: *Array) void {
        if (self.external) |binding| binding.deinit();
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: Array) usize {
        return self.items.items.len;
    }

    pub fn get(self: Array, index: usize) Value {
        if (index >= self.items.items.len) return .undefined;
        return self.items.items[index];
    }

    pub fn set(self: *Array, index: usize, value: Value) !void {
        if (index >= self.items.items.len) {
            const old_len = self.items.items.len;
            try self.items.resize(self.allocator, index + 1);
            @memset(self.items.items[old_len..], .undefined);
        }
        self.items.items[index] = value;
    }

    pub fn push(self: *Array, value: Value) !usize {
        try self.items.append(self.allocator, value);
        return self.items.items.len;
    }

    pub fn pop(self: *Array) Value {
        return self.items.pop() orelse .undefined;
    }

    pub fn unshift(self: *Array, value: Value) !usize {
        try self.items.insert(self.allocator, 0, value);
        return self.items.items.len;
    }

    pub fn shift(self: *Array) Value {
        if (self.items.items.len == 0) return .undefined;
        return self.items.orderedRemove(0);
    }

    pub fn insert(self: *Array, index: usize, value: Value) !void {
        try self.items.insert(self.allocator, @min(index, self.items.items.len), value);
    }

    pub fn remove(self: *Array, index: usize) Value {
        if (index >= self.items.items.len) return .undefined;
        return self.items.orderedRemove(index);
    }
};

const StringKeyContext = struct {
    pub fn hash(_: @This(), key: *String) u32 {
        return @truncate(key.hash());
    }

    pub fn eql(_: @This(), left: *String, right: *String, right_index: usize) bool {
        _ = right_index;
        return String.eql(left.*, right.*);
    }
};

const DictionaryMap = std.ArrayHashMapUnmanaged(*String, Value, StringKeyContext, true);

pub const DictionaryKind = enum { ordinary, http_response };

pub const Dictionary = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    kind: DictionaryKind = .ordinary,
    map: DictionaryMap = .empty,
    external: ?ExternalHandle = null,

    pub fn deinit(self: *Dictionary) void {
        if (self.external) |binding| binding.deinit();
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: Dictionary) usize {
        return self.map.count();
    }

    pub fn set(self: *Dictionary, key: *String, value: Value) !void {
        try self.map.putContext(self.allocator, key, value, .{});
    }

    pub fn get(self: Dictionary, key: *String) ?Value {
        return self.map.getContext(key, .{});
    }

    pub fn has(self: Dictionary, key: *String) bool {
        return self.map.getIndexContext(key, .{}) != null;
    }

    pub fn remove(self: *Dictionary, key: *String) bool {
        return self.map.orderedRemoveContext(key, .{});
    }

    pub fn keys(self: Dictionary) []*String {
        return self.map.keys();
    }

    pub fn values(self: Dictionary) []Value {
        return self.map.values();
    }
};

/// Lexical bindings live in GC-managed cells so closures created from the same
/// frame observe and update one shared value.
pub const BindingCell = struct {
    gc_marked: bool = false,
    value: Value,

    pub fn deinit(self: *BindingCell) void {
        self.* = undefined;
    }
};

/// Native callbacks may retain an immutable value directly. IR closures use a
/// binding cell, which preserves JavaScript/Nadesiko mutable-capture semantics.
pub const Capture = struct {
    name: *String,
    value: Value = .undefined,
    cell: ?*BindingCell = null,
};
pub const NativeCallback = *const fn (runtime: *Runtime, arguments: []const Value) anyerror!Value;
pub const ExternalFunction = struct {
    binding: ExternalHandle,
    callFn: *const fn (context: *anyopaque, handle: *anyopaque, runtime: *Runtime, arguments: []const Value) anyerror!Value,
};
pub const FunctionKind = union(enum) { ir: u32, native: NativeCallback, external: ExternalFunction };

pub const Function = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    name: *String,
    arity: usize,
    is_async: bool = false,
    pure: bool = false,
    kind: FunctionKind,
    captures: []Capture,

    pub fn deinit(self: *Function) void {
        if (self.kind == .external) self.kind.external.binding.deinit();
        self.allocator.free(self.captures);
        self.* = undefined;
    }

    pub fn captured(self: Function, name: *String) ?Value {
        for (self.captures) |capture| if (String.eql(capture.name.*, name.*))
            return if (capture.cell) |cell| cell.value else capture.value;
        return null;
    }
};

pub const PromiseState = enum { pending, fulfilled, rejected };
pub const PromiseReactionMode = enum { standard, settled_pair, finally };

pub const PromiseReaction = struct {
    on_fulfilled: Value = .undefined,
    on_rejected: Value = .undefined,
    next: *Promise,
    mode: PromiseReactionMode = .standard,
};

pub const Promise = struct {
    gc_marked: bool = false,
    allocator: std.mem.Allocator,
    state: PromiseState = .pending,
    result: Value = .undefined,
    reactions: std.ArrayList(PromiseReaction) = .empty,

    pub fn deinit(self: *Promise) void {
        self.reactions.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const PromiseTask = struct {
    callback: Value,
    settled_value: Value,
    rejected: bool,
    next: *Promise,
    mode: PromiseReactionMode,
};

pub const Value = union(enum) {
    undefined,
    null_value,
    boolean: bool,
    number: f64,
    bigint: *BigInt,
    string: *String,
    bytes: *ByteBuffer,
    array: *Array,
    dictionary: *Dictionary,
    function: *Function,
    promise: *Promise,

    pub fn tagName(self: Value) []const u8 {
        return @tagName(self);
    }

    pub fn toBoolean(self: Value) bool {
        return switch (self) {
            .undefined, .null_value => false,
            .boolean => |value| value,
            .number => |value| value != 0 and !std.math.isNan(value),
            .bigint => |value| !value.isZero(),
            .string => |value| value.len() != 0,
            .bytes, .array, .dictionary, .function, .promise => true,
        };
    }

    pub fn toNumber(self: Value, scratch_allocator: std.mem.Allocator) !f64 {
        return switch (self) {
            .undefined => std.math.nan(f64),
            .null_value => 0,
            .boolean => |value| if (value) 1 else 0,
            .number => |value| value,
            .bigint => error.CannotConvertBigIntToNumber,
            .string => |value| parseNumber(value.*, scratch_allocator),
            .bytes, .array, .dictionary, .function, .promise => error.CannotConvertObjectToNumber,
        };
    }

    pub fn strictEqual(left: Value, right: Value) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .undefined, .null_value => true,
            .boolean => |value| value == right.boolean,
            .number => |value| !std.math.isNan(value) and !std.math.isNan(right.number) and value == right.number,
            .bigint => |value| BigInt.eql(value.*, right.bigint.*),
            .string => |value| String.eql(value.*, right.string.*),
            .bytes => |value| value == right.bytes,
            .array => |value| value == right.array,
            .dictionary => |value| value == right.dictionary,
            .function => |value| value == right.function,
            .promise => |value| value == right.promise,
        };
    }

    pub fn sameValue(left: Value, right: Value) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .number => |value| blk: {
                if (std.math.isNan(value) and std.math.isNan(right.number)) break :blk true;
                break :blk @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number));
            },
            else => strictEqual(left, right),
        };
    }

    pub fn abstractEqual(left: Value, scratch_allocator: std.mem.Allocator, right: Value) !bool {
        const left_tag = std.meta.activeTag(left);
        const right_tag = std.meta.activeTag(right);
        if (left_tag == right_tag) return strictEqual(left, right);
        if ((left_tag == .undefined and right_tag == .null_value) or (left_tag == .null_value and right_tag == .undefined)) return true;
        return switch (left) {
            .boolean => (Value{ .number = if (left.boolean) 1 else 0 }).abstractEqual(scratch_allocator, right),
            .number => switch (right) {
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                .string => left.number == try right.toNumber(scratch_allocator),
                .bigint => numberEqualsBigInt(left.number, scratch_allocator, right.bigint.*),
                else => false,
            },
            .string => switch (right) {
                .number => (try left.toNumber(scratch_allocator)) == right.number,
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                .bigint => stringEqualsBigInt(left.string.*, scratch_allocator, right.bigint.*),
                else => false,
            },
            .bigint => switch (right) {
                .number => numberEqualsBigInt(right.number, scratch_allocator, left.bigint.*),
                .string => stringEqualsBigInt(right.string.*, scratch_allocator, left.bigint.*),
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                else => false,
            },
            else => false,
        };
    }
};

fn isObjectValue(value: Value) bool {
    return switch (value) {
        .bytes, .array, .dictionary, .function, .promise => true,
        else => false,
    };
}

const HeapObject = union(enum) {
    string: *String,
    bigint: *BigInt,
    bytes: *ByteBuffer,
    binding_cell: *BindingCell,
    array: *Array,
    dictionary: *Dictionary,
    function: *Function,
    promise: *Promise,
};

pub const CollectionStats = struct { before: usize, after: usize, collected: usize };
pub const RootProvider = struct {
    context: *anyopaque,
    traceFn: *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void,
};

/// 生成コードはValueを格納したスタック領域のアドレスをこのフレームへ登録する。
pub const RootFrame = struct {
    runtime: *Runtime,
    depth: usize,

    pub fn protect(self: *RootFrame, value: *Value) !void {
        try self.runtime.roots.append(self.runtime.backing_allocator, value);
    }

    pub fn deinit(self: *RootFrame) void {
        self.runtime.roots.shrinkRetainingCapacity(self.depth);
        self.* = undefined;
    }
};

/// 循環参照を扱う正確なmark-and-sweepヒープと、生成コード向けルートスタック。
pub const Runtime = struct {
    backing_allocator: std.mem.Allocator,
    objects: std.ArrayList(HeapObject) = .empty,
    roots: std.ArrayList(*Value) = .empty,
    grey_objects: std.ArrayList(HeapObject) = .empty,
    root_providers: std.ArrayList(RootProvider) = .empty,
    promise_tasks: std.ArrayList(PromiseTask) = .empty,
    stringifying_arrays: std.ArrayList(*Array) = .empty,
    next_collection: usize = 64,
    stress_collection: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator) Runtime {
        return .{ .backing_allocator = backing_allocator };
    }

    pub fn deinit(self: *Runtime) void {
        for (self.objects.items) |object| self.destroyObject(object);
        self.objects.deinit(self.backing_allocator);
        self.roots.deinit(self.backing_allocator);
        self.grey_objects.deinit(self.backing_allocator);
        self.root_providers.deinit(self.backing_allocator);
        self.promise_tasks.deinit(self.backing_allocator);
        self.stringifying_arrays.deinit(self.backing_allocator);
        self.* = undefined;
    }

    pub fn allocator(self: *Runtime) std.mem.Allocator {
        return self.backing_allocator;
    }

    pub fn rootFrame(self: *Runtime) RootFrame {
        return .{ .runtime = self, .depth = self.roots.items.len };
    }

    pub fn objectCount(self: Runtime) usize {
        return self.objects.items.len;
    }

    pub fn registerRootProvider(self: *Runtime, provider: RootProvider) !void {
        try self.root_providers.append(self.allocator(), provider);
    }

    pub fn unregisterRootProvider(self: *Runtime, context: *anyopaque) void {
        var index = self.root_providers.items.len;
        while (index > 0) {
            index -= 1;
            if (self.root_providers.items[index].context == context) {
                _ = self.root_providers.swapRemove(index);
                return;
            }
        }
    }

    pub fn traceExternal(self: *Runtime, value: Value) !void {
        try self.markValue(value);
    }

    pub fn traceExternalBindingCell(self: *Runtime, cell: *BindingCell) !void {
        try self.markComposite(.{ .binding_cell = cell });
    }

    pub fn setGcStress(self: *Runtime, enabled: bool) void {
        self.stress_collection = enabled;
    }

    pub fn stringUtf8(self: *Runtime, utf8: []const u8) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(String);
        errdefer self.allocator().destroy(result);
        result.* = try String.fromUtf8(self.allocator(), utf8);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .string = result });
        return .{ .string = result };
    }

    pub fn stringUtf8Lossy(self: *Runtime, utf8: []const u8) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(String);
        errdefer self.allocator().destroy(result);
        result.* = try String.fromUtf8Lossy(self.allocator(), utf8);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .string = result });
        return .{ .string = result };
    }

    pub fn stringCodeUnits(self: *Runtime, units: []const u16) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(String);
        errdefer self.allocator().destroy(result);
        result.* = try String.fromCodeUnits(self.allocator(), units);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .string = result });
        return .{ .string = result };
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

    fn createByteBuffer(self: *Runtime, bytes: []const u8, kind: ByteKind) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(ByteBuffer);
        errdefer self.allocator().destroy(result);
        result.* = .{ .allocator = self.allocator(), .bytes = try self.allocator().dupe(u8, bytes), .kind = kind };
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .bytes = result });
        return .{ .bytes = result };
    }

    pub fn bigIntLiteral(self: *Runtime, source: []const u8) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(BigInt);
        errdefer self.allocator().destroy(result);
        result.* = try BigInt.parseLiteral(self.allocator(), source);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .bigint = result });
        return .{ .bigint = result };
    }

    pub fn bigIntString(self: *Runtime, source: *String) !Value {
        const trimmed = string_mod.trimWhitespace(source.units);
        var temporary = try String.fromCodeUnits(self.allocator(), trimmed);
        defer temporary.deinit();
        const utf8 = try temporary.toUtf8Lossy(self.allocator());
        defer self.allocator().free(utf8);
        try self.beforeAllocationPreserving(&.{.{ .string = source }});
        const result = try self.allocator().create(BigInt);
        errdefer self.allocator().destroy(result);
        result.* = try BigInt.parseString(self.allocator(), utf8);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .bigint = result });
        return .{ .bigint = result };
    }

    pub fn ownBigInt(self: *Runtime, value: BigInt) !Value {
        var owned = value;
        errdefer owned.deinit();
        try self.beforeAllocation();
        const result = try self.allocator().create(BigInt);
        errdefer self.allocator().destroy(result);
        result.* = owned;
        try self.objects.append(self.allocator(), .{ .bigint = result });
        return .{ .bigint = result };
    }

    pub fn concatStrings(self: *Runtime, left: *String, right: *String) !Value {
        try self.beforeAllocationPreserving(&.{ .{ .string = left }, .{ .string = right } });
        const result = try self.allocator().create(String);
        errdefer self.allocator().destroy(result);
        result.* = try left.concat(self.allocator(), right.*);
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .string = result });
        return .{ .string = result };
    }

    pub fn createArray(self: *Runtime) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(Array);
        errdefer self.allocator().destroy(result);
        result.* = .{ .allocator = self.allocator() };
        try self.objects.append(self.allocator(), .{ .array = result });
        return .{ .array = result };
    }

    pub fn createDictionary(self: *Runtime) !Value {
        return self.createDictionaryKind(.ordinary);
    }

    pub fn createDictionaryKind(self: *Runtime, kind: DictionaryKind) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(Dictionary);
        errdefer self.allocator().destroy(result);
        result.* = .{ .allocator = self.allocator(), .kind = kind };
        try self.objects.append(self.allocator(), .{ .dictionary = result });
        return .{ .dictionary = result };
    }

    pub fn createPromise(self: *Runtime) !Value {
        try self.beforeAllocation();
        const result = try self.allocator().create(Promise);
        errdefer self.allocator().destroy(result);
        result.* = .{ .allocator = self.allocator() };
        try self.objects.append(self.allocator(), .{ .promise = result });
        return .{ .promise = result };
    }

    pub fn promiseThen(self: *Runtime, source: *Promise, on_fulfilled: Value, on_rejected: Value) !Value {
        return self.promiseThenMode(source, on_fulfilled, on_rejected, .standard);
    }

    pub fn promiseThenMode(self: *Runtime, source: *Promise, on_fulfilled: Value, on_rejected: Value, mode: PromiseReactionMode) !Value {
        var source_root = Value{ .promise = source };
        var fulfilled_root = on_fulfilled;
        var rejected_root = on_rejected;
        var frame = self.rootFrame();
        defer frame.deinit();
        try frame.protect(&source_root);
        try frame.protect(&fulfilled_root);
        try frame.protect(&rejected_root);
        const next_value = try self.createPromise();
        const reaction = PromiseReaction{
            .on_fulfilled = fulfilled_root,
            .on_rejected = rejected_root,
            .next = next_value.promise,
            .mode = mode,
        };
        if (source.state == .pending) {
            try source.reactions.append(self.allocator(), reaction);
        } else {
            try self.enqueueReaction(source, reaction);
        }
        return next_value;
    }

    pub fn resolvePromise(self: *Runtime, promise: *Promise, value: Value) !void {
        if (promise.state != .pending) return;
        if (value == .promise) {
            if (value.promise == promise) return error.PromiseResolutionCycle;
            if (value.promise.state == .pending) {
                try value.promise.reactions.append(self.allocator(), .{ .next = promise });
            } else {
                try self.enqueueReaction(value.promise, .{ .next = promise });
            }
            return;
        }
        promise.state = .fulfilled;
        promise.result = value;
        try self.enqueuePromiseReactions(promise);
    }

    pub fn rejectPromise(self: *Runtime, promise: *Promise, reason: Value) !void {
        if (promise.state != .pending) return;
        promise.state = .rejected;
        promise.result = reason;
        try self.enqueuePromiseReactions(promise);
    }

    pub fn takePromiseTask(self: *Runtime) ?PromiseTask {
        if (self.promise_tasks.items.len == 0) return null;
        return self.promise_tasks.orderedRemove(0);
    }

    pub fn forwardPromiseTask(self: *Runtime, task: PromiseTask) !void {
        if (task.rejected) return self.rejectPromise(task.next, task.settled_value);
        return self.resolvePromise(task.next, task.settled_value);
    }

    fn enqueuePromiseReactions(self: *Runtime, promise: *Promise) !void {
        for (promise.reactions.items) |reaction| try self.enqueueReaction(promise, reaction);
        promise.reactions.clearRetainingCapacity();
    }

    fn enqueueReaction(self: *Runtime, promise: *Promise, reaction: PromiseReaction) !void {
        try self.promise_tasks.append(self.allocator(), .{
            .callback = if (promise.state == .rejected) reaction.on_rejected else reaction.on_fulfilled,
            .settled_value = promise.result,
            .rejected = promise.state == .rejected,
            .next = reaction.next,
            .mode = reaction.mode,
        });
    }

    pub fn createIrFunction(self: *Runtime, name: *String, arity: usize, function_id: u32, captures: []const Capture) !Value {
        return self.createFunction(name, arity, .{ .ir = function_id }, captures);
    }

    pub fn createBindingCell(self: *Runtime, value: Value) !*BindingCell {
        try self.beforeAllocationPreserving(&.{value});
        const result = try self.allocator().create(BindingCell);
        errdefer self.allocator().destroy(result);
        result.* = .{ .value = value };
        try self.objects.append(self.allocator(), .{ .binding_cell = result });
        return result;
    }

    pub fn createNativeFunction(self: *Runtime, name: *String, arity: usize, callback: NativeCallback, captures: []const Capture) !Value {
        return self.createFunction(name, arity, .{ .native = callback }, captures);
    }

    pub fn createExternalFunction(self: *Runtime, name: *String, arity: usize, external: ExternalFunction) !Value {
        return self.createFunction(name, arity, .{ .external = external }, &.{});
    }

    fn createFunction(self: *Runtime, name: *String, arity: usize, kind: FunctionKind, captures: []const Capture) !Value {
        if (self.stress_collection or self.objects.items.len >= self.next_collection) {
            errdefer self.clearAllMarks();
            try self.markValue(.{ .string = name });
            for (captures) |capture| {
                try self.markValue(.{ .string = capture.name });
                if (capture.cell) |cell|
                    try self.markComposite(.{ .binding_cell = cell })
                else
                    try self.markValue(capture.value);
            }
            _ = try self.collect();
        }
        const result = try self.allocator().create(Function);
        errdefer self.allocator().destroy(result);
        result.* = .{
            .allocator = self.allocator(),
            .name = name,
            .arity = arity,
            .kind = kind,
            .captures = try self.allocator().dupe(Capture, captures),
        };
        errdefer result.deinit();
        try self.objects.append(self.allocator(), .{ .function = result });
        return .{ .function = result };
    }

    pub fn call(self: *Runtime, function_value: Value, arguments: []const Value) !Value {
        if (function_value != .function) return error.NotCallable;
        var function_root = function_value;
        const argument_roots = try self.allocator().dupe(Value, arguments);
        defer self.allocator().free(argument_roots);
        var frame = self.rootFrame();
        defer frame.deinit();
        try frame.protect(&function_root);
        for (argument_roots) |*argument| try frame.protect(argument);
        return switch (function_root.function.kind) {
            .native => |callback| callback(self, arguments),
            .external => |external| external.callFn(external.binding.context, external.binding.handle, self, arguments),
            .ir => error.IrFunctionNotExecutable,
        };
    }

    pub fn valueToString(self: *Runtime, value: Value) anyerror!Value {
        var rooted_value = value;
        var frame = self.rootFrame();
        defer frame.deinit();
        try frame.protect(&rooted_value);
        return switch (rooted_value) {
            .undefined => self.stringUtf8("undefined"),
            .null_value => self.stringUtf8("null"),
            .boolean => |boolean| self.stringUtf8(if (boolean) "true" else "false"),
            .number => |number| blk: {
                const utf8 = try numberToStringAlloc(self.allocator(), number);
                defer self.allocator().free(utf8);
                break :blk self.stringUtf8(utf8);
            },
            .bigint => |bigint| blk: {
                const utf8 = try bigint.toString(self.allocator(), 10);
                defer self.allocator().free(utf8);
                break :blk self.stringUtf8(utf8);
            },
            .string => value,
            .bytes => |buffer| switch (buffer.kind) {
                .buffer => self.stringUtf8Lossy(buffer.bytes),
                .uint8_array => blk: {
                    var text: std.ArrayList(u8) = .empty;
                    defer text.deinit(self.allocator());
                    for (buffer.bytes, 0..) |byte, index| {
                        if (index > 0) try text.append(self.allocator(), ',');
                        var number_buffer: [3]u8 = undefined;
                        const number = std.fmt.bufPrint(&number_buffer, "{d}", .{byte}) catch unreachable;
                        try text.appendSlice(self.allocator(), number);
                    }
                    break :blk self.stringUtf8(text.items);
                },
                .array_buffer => self.stringUtf8("[object ArrayBuffer]"),
            },
            .array => |array| self.arrayToString(array),
            .dictionary => |dictionary| self.stringUtf8(if (dictionary.kind == .http_response) "[object Response]" else "[object Object]"),
            .function => |function| blk: {
                const name = try function.name.toUtf8Lossy(self.allocator());
                defer self.allocator().free(name);
                const text = try std.fmt.allocPrint(self.allocator(), "function {s}() {{ [native code] }}", .{name});
                defer self.allocator().free(text);
                break :blk self.stringUtf8(text);
            },
            .promise => self.stringUtf8("[object Promise]"),
        };
    }

    pub fn valueToPrimitive(self: *Runtime, value: Value) !Value {
        return switch (value) {
            .bytes, .array, .dictionary, .function, .promise => self.valueToString(value),
            else => value,
        };
    }

    pub fn valueToNumber(self: *Runtime, value: Value) !f64 {
        const primitive = try self.valueToPrimitive(value);
        return primitive.toNumber(self.allocator());
    }

    pub fn abstractEqual(self: *Runtime, left: Value, right: Value) !bool {
        var left_root = left;
        var right_root = right;
        var frame = self.rootFrame();
        defer frame.deinit();
        try frame.protect(&left_root);
        try frame.protect(&right_root);
        if (std.meta.activeTag(left_root) == std.meta.activeTag(right_root)) return Value.strictEqual(left_root, right_root);
        const left_is_object = isObjectValue(left_root);
        const right_is_object = isObjectValue(right_root);
        if (left_is_object and right_is_object) return false;
        const left_primitive = if (left_is_object) try self.valueToPrimitive(left_root) else left_root;
        const right_primitive = if (right_is_object) try self.valueToPrimitive(right_root) else right_root;
        return left_primitive.abstractEqual(self.allocator(), right_primitive);
    }

    fn arrayToString(self: *Runtime, array: *Array) !Value {
        for (self.stringifying_arrays.items) |active| if (active == array) return self.stringUtf8("");
        try self.stringifying_arrays.append(self.allocator(), array);
        defer _ = self.stringifying_arrays.pop();
        var output: std.Io.Writer.Allocating = .init(self.allocator());
        defer output.deinit();
        for (array.items.items, 0..) |item, index| {
            if (index > 0) try output.writer.writeByte(',');
            if (item == .undefined or item == .null_value) continue;
            const text_value = try self.valueToString(item);
            const utf8 = try text_value.string.toUtf8Lossy(self.allocator());
            defer self.allocator().free(utf8);
            try output.writer.writeAll(utf8);
        }
        return self.stringUtf8(output.written());
    }

    pub fn collect(self: *Runtime) !CollectionStats {
        errdefer self.clearAllMarks();
        const before = self.objects.items.len;
        for (self.roots.items) |root| try self.markValue(root.*);
        for (self.root_providers.items) |provider| try provider.traceFn(provider.context, self);
        for (self.promise_tasks.items) |task| {
            try self.markValue(task.callback);
            try self.markValue(task.settled_value);
            try self.markValue(.{ .promise = task.next });
        }
        try self.traceGreyObjects();
        var index: usize = 0;
        while (index < self.objects.items.len) {
            if (self.objectMarked(self.objects.items[index])) {
                self.clearMark(self.objects.items[index]);
                index += 1;
            } else {
                const dead = self.objects.swapRemove(index);
                self.destroyObject(dead);
            }
        }
        self.next_collection = @max(@as(usize, 64), self.objects.items.len * 2);
        return .{ .before = before, .after = self.objects.items.len, .collected = before - self.objects.items.len };
    }

    fn beforeAllocation(self: *Runtime) !void {
        if (self.stress_collection or self.objects.items.len >= self.next_collection) _ = try self.collect();
    }

    fn beforeAllocationPreserving(self: *Runtime, values: []const Value) !void {
        if (self.stress_collection or self.objects.items.len >= self.next_collection) {
            errdefer self.clearAllMarks();
            for (values) |value| try self.markValue(value);
            _ = try self.collect();
        }
    }

    fn markValue(self: *Runtime, value: Value) !void {
        switch (value) {
            .string => |object| object.gc_marked = true,
            .bigint => |object| object.gc_marked = true,
            .bytes => |object| object.gc_marked = true,
            .array => |object| try self.markComposite(.{ .array = object }),
            .dictionary => |object| try self.markComposite(.{ .dictionary = object }),
            .function => |object| try self.markComposite(.{ .function = object }),
            .promise => |object| try self.markComposite(.{ .promise = object }),
            else => {},
        }
    }

    fn markComposite(self: *Runtime, object: HeapObject) !void {
        if (self.objectMarked(object)) return;
        try self.grey_objects.append(self.allocator(), object);
        switch (object) {
            inline else => |value| value.gc_marked = true,
        }
    }

    fn traceGreyObjects(self: *Runtime) !void {
        while (self.grey_objects.pop()) |object| switch (object) {
            .binding_cell => |cell| try self.markValue(cell.value),
            .array => |array| for (array.items.items) |item| try self.markValue(item),
            .dictionary => |dictionary| {
                for (dictionary.keys()) |key| try self.markValue(.{ .string = key });
                for (dictionary.values()) |item| try self.markValue(item);
            },
            .function => |function| {
                try self.markValue(.{ .string = function.name });
                for (function.captures) |capture| {
                    try self.markValue(.{ .string = capture.name });
                    if (capture.cell) |cell|
                        try self.markComposite(.{ .binding_cell = cell })
                    else
                        try self.markValue(capture.value);
                }
            },
            .promise => |promise| {
                try self.markValue(promise.result);
                for (promise.reactions.items) |reaction| {
                    try self.markValue(reaction.on_fulfilled);
                    try self.markValue(reaction.on_rejected);
                    try self.markValue(.{ .promise = reaction.next });
                }
            },
            .string, .bigint, .bytes => unreachable,
        };
    }

    fn objectMarked(self: Runtime, object: HeapObject) bool {
        _ = self;
        return switch (object) {
            inline else => |value| value.gc_marked,
        };
    }

    fn clearMark(self: *Runtime, object: HeapObject) void {
        _ = self;
        switch (object) {
            inline else => |value| value.gc_marked = false,
        }
    }

    fn clearAllMarks(self: *Runtime) void {
        self.grey_objects.clearRetainingCapacity();
        for (self.objects.items) |object| self.clearMark(object);
    }

    fn destroyObject(self: *Runtime, object: HeapObject) void {
        switch (object) {
            inline else => |value| {
                value.deinit();
                self.backing_allocator.destroy(value);
            },
        }
    }
};

pub fn parseNumber(value: String, scratch_allocator: std.mem.Allocator) !f64 {
    const trimmed_units = string_mod.trimWhitespace(value.units);
    if (trimmed_units.len == 0) return 0;
    for (trimmed_units) |unit| if (unit > 0x7f) return std.math.nan(f64);
    var ascii = try scratch_allocator.alloc(u8, trimmed_units.len);
    defer scratch_allocator.free(ascii);
    for (trimmed_units, 0..) |unit, index| ascii[index] = @intCast(unit);
    if (std.mem.eql(u8, ascii, "Infinity") or std.mem.eql(u8, ascii, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "NaN")) return std.math.nan(f64);
    if (ascii.len >= 2 and ascii[0] == '0') {
        const prefix = std.ascii.toLower(ascii[1]);
        if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
            const base: u8 = if (prefix == 'x') 16 else if (prefix == 'o') 8 else 2;
            if (ascii.len == 2) return std.math.nan(f64);
            var result: f64 = 0;
            for (ascii[2..]) |character| {
                const digit = std.fmt.charToDigit(character, base) catch return std.math.nan(f64);
                result = result * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(digit));
            }
            return result;
        }
    }
    if (!validDecimalNumber(ascii)) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64);
}

pub fn numberToStringAlloc(allocator: std.mem.Allocator, value: f64) ![]u8 {
    if (std.math.isNan(value)) return allocator.dupe(u8, "NaN");
    if (value == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (value == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    if (value == 0) return allocator.dupe(u8, "0");
    var fixed_output: std.Io.Writer.Allocating = .init(allocator);
    defer fixed_output.deinit();
    try fixed_output.writer.print("{d}", .{value});
    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) return fixedToScientific(allocator, fixed_output.written());
    return allocator.dupe(u8, fixed_output.written());
}

fn fixedToScientific(allocator: std.mem.Allocator, fixed: []const u8) ![]u8 {
    const negative = fixed.len > 0 and fixed[0] == '-';
    const digits_start: usize = @intFromBool(negative);
    const dot = std.mem.indexOfScalarPos(u8, fixed, digits_start, '.') orelse fixed.len;
    var first_nonzero = digits_start;
    while (first_nonzero < fixed.len and (fixed[first_nonzero] == '0' or fixed[first_nonzero] == '.')) first_nonzero += 1;
    if (first_nonzero == fixed.len) return allocator.dupe(u8, "0");
    const exponent: i64 = if (dot < first_nonzero)
        -@as(i64, @intCast(first_nonzero - dot))
    else
        @as(i64, @intCast(dot - first_nonzero - 1));
    var significant = try allocator.alloc(u8, fixed.len - first_nonzero);
    defer allocator.free(significant);
    var length: usize = 0;
    for (fixed[first_nonzero..]) |character| if (character != '.') {
        significant[length] = character;
        length += 1;
    };
    while (length > 1 and significant[length - 1] == '0') length -= 1;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (negative) try output.writer.writeByte('-');
    try output.writer.writeByte(significant[0]);
    if (length > 1) {
        try output.writer.writeByte('.');
        try output.writer.writeAll(significant[1..length]);
    }
    try output.writer.writeByte('e');
    if (exponent >= 0) try output.writer.writeByte('+');
    try output.writer.print("{d}", .{exponent});
    return output.toOwnedSlice();
}

fn validDecimalNumber(text: []const u8) bool {
    var index: usize = 0;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
    var digits: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == text.len;
}

fn numberEqualsBigInt(number: f64, allocator: std.mem.Allocator, bigint: BigInt) !bool {
    var converted = BigInt.fromF64(allocator, number) catch return false;
    defer converted.deinit();
    return BigInt.eql(converted, bigint);
}

fn stringEqualsBigInt(string: String, allocator: std.mem.Allocator, bigint: BigInt) !bool {
    var trimmed = try String.fromCodeUnits(allocator, string_mod.trimWhitespace(string.units));
    defer trimmed.deinit();
    const utf8 = try trimmed.toUtf8Lossy(allocator);
    defer allocator.free(utf8);
    var converted = BigInt.parseString(allocator, utf8) catch return false;
    defer converted.deinit();
    return BigInt.eql(converted, bigint);
}

test "動的値の真偽変換と同値性をJS規則で扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const empty = try runtime.stringUtf8("");
    const zero_bigint = try runtime.bigIntLiteral("0n");
    const undefined_value: Value = .undefined;
    try std.testing.expect(!undefined_value.toBoolean());
    try std.testing.expect(!empty.toBoolean());
    try std.testing.expect(!zero_bigint.toBoolean());
    try std.testing.expect(!Value.strictEqual(.{ .number = std.math.nan(f64) }, .{ .number = std.math.nan(f64) }));
    try std.testing.expect(Value.sameValue(.{ .number = std.math.nan(f64) }, .{ .number = std.math.nan(f64) }));
    try std.testing.expect(!Value.sameValue(.{ .number = 0.0 }, .{ .number = -0.0 }));
}

test "文字列数値変換と抽象等価をJS規則で扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const hex = try runtime.stringUtf8(" 0x10 ");
    const fullwidth_space = try runtime.stringUtf8("　42　");
    const invalid = try runtime.stringUtf8("12x");
    try std.testing.expectEqual(@as(f64, 16), try hex.toNumber(std.testing.allocator));
    try std.testing.expectEqual(@as(f64, 42), try fullwidth_space.toNumber(std.testing.allocator));
    try std.testing.expect(std.math.isNan(try invalid.toNumber(std.testing.allocator)));
    try std.testing.expect(try Value.abstractEqual(.{ .number = 16 }, std.testing.allocator, hex));
    const bigint = try runtime.bigIntLiteral("9007199254740993n");
    const bigint_string = try runtime.stringUtf8("9007199254740993");
    try std.testing.expect(try bigint.abstractEqual(std.testing.allocator, bigint_string));
}

test "数値文字列化の固定小数と指数表記境界をJSへ合わせる" {
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = -0.0, .expected = "0" },
        .{ .value = 0.000001, .expected = "0.000001" },
        .{ .value = 0.0000001, .expected = "1e-7" },
        .{ .value = 1e20, .expected = "100000000000000000000" },
        .{ .value = 1e21, .expected = "1e+21" },
    };
    for (cases) |case| {
        const actual = try numberToStringAlloc(std.testing.allocator, case.value);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "配列の伸長と挿入順辞書の更新を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const array = try runtime.createArray();
    _ = try array.array.push(.{ .number = 1 });
    try array.array.set(3, .{ .number = 4 });
    try std.testing.expectEqual(@as(usize, 4), array.array.len());
    try std.testing.expect(array.array.get(1) == .undefined);
    try std.testing.expectEqual(@as(f64, 4), array.array.get(3).number);

    const dictionary = try runtime.createDictionary();
    const first_a = try runtime.stringUtf8("a");
    const second_a = try runtime.stringUtf8("a");
    const key_b = try runtime.stringUtf8("b");
    try dictionary.dictionary.set(first_a.string, .{ .number = 1 });
    try dictionary.dictionary.set(key_b.string, .{ .number = 2 });
    try dictionary.dictionary.set(second_a.string, .{ .number = 3 });
    try std.testing.expectEqual(@as(usize, 2), dictionary.dictionary.len());
    try std.testing.expectEqual(@as(f64, 3), dictionary.dictionary.get(first_a.string).?.number);
    try std.testing.expect(dictionary.dictionary.keys()[0] == first_a.string);
    try std.testing.expect(dictionary.dictionary.keys()[1] == key_b.string);
    try std.testing.expect(try runtime.abstractEqual(array, .{ .number = std.math.nan(f64) }) == false);
    const singleton = try runtime.createArray();
    _ = try singleton.array.push(.{ .number = 1 });
    try std.testing.expect(try runtime.abstractEqual(singleton, .{ .number = 1 }));
    const other_singleton = try runtime.createArray();
    _ = try other_singleton.array.push(.{ .number = 1 });
    try std.testing.expect(try runtime.abstractEqual(singleton, singleton));
    try std.testing.expect(!(try runtime.abstractEqual(singleton, other_singleton)));
    const other_dictionary = try runtime.createDictionary();
    const other_key = try runtime.stringUtf8("a");
    try other_dictionary.dictionary.set(other_key.string, .{ .number = 3 });
    try std.testing.expect(!(try runtime.abstractEqual(dictionary, other_dictionary)));
}

test "循環した配列と辞書を正確なmark-and-sweepで回収する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var array = try runtime.createArray();
    const dictionary = try runtime.createDictionary();
    const key = try runtime.stringUtf8("cycle");
    _ = try array.array.push(dictionary);
    try dictionary.dictionary.set(key.string, array);
    _ = try runtime.stringUtf8("unreachable");
    var frame = runtime.rootFrame();
    try frame.protect(&array);
    const rooted = try runtime.collect();
    try std.testing.expectEqual(@as(usize, 3), rooted.after);
    try std.testing.expectEqual(@as(usize, 1), rooted.collected);
    frame.deinit();
    const released = try runtime.collect();
    try std.testing.expectEqual(@as(usize, 0), released.after);
    try std.testing.expectEqual(@as(usize, 3), released.collected);
}

test "GCストレス中もルートと循環文字列化を保護する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    _ = try runtime.stringUtf8("discarded");
    var array = try runtime.createArray();
    _ = try array.array.push(array);
    var frame = runtime.rootFrame();
    defer frame.deinit();
    try frame.protect(&array);
    const text = try runtime.valueToString(array);
    const utf8 = try text.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("", utf8);
    try std.testing.expect(runtime.objectCount() >= 2);
}

test "Bufferの文字列化は不正UTF-8を置換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var buffer = try runtime.createBytes(&.{ 0xe3, 0x81, 0x41 });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&buffer);
    const string = try runtime.valueToString(buffer);
    const utf8 = try string.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("�A", utf8);
}

test "Uint8Arrayは添字アクセス・更新とカンマ区切り文字列化を行う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var bytes = try runtime.createUint8Array(&.{ 1, 2, 255 });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&bytes);
    try std.testing.expectEqual(@as(f64, 2), bytes.bytes.get(1).number);
    bytes.bytes.set(1, 7);
    try std.testing.expectEqual(@as(f64, 7), bytes.bytes.get(1).number);
    try std.testing.expect(bytes.bytes.get(9) == .undefined);
    const string = try runtime.valueToString(bytes);
    const utf8 = try string.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("1,7,255", utf8);
}

test "深いオブジェクトグラフを再帰せずマークする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var root = try runtime.createArray();
    var frame = runtime.rootFrame();
    try frame.protect(&root);
    var current = root.array;
    for (0..4096) |_| {
        const child = try runtime.createArray();
        _ = try current.push(child);
        current = child.array;
    }
    try std.testing.expectEqual(@as(usize, 4097), (try runtime.collect()).after);
    frame.deinit();
    try std.testing.expectEqual(@as(usize, 4097), (try runtime.collect()).collected);
}

fn testNativeSum(runtime: *Runtime, arguments: []const Value) !Value {
    var result: f64 = 0;
    for (arguments) |argument| result += try argument.toNumber(runtime.allocator());
    return .{ .number = result };
}

test "関数・クロージャの捕捉値を追跡して呼び出す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const name = try runtime.stringUtf8("加算");
    const capture_name = try runtime.stringUtf8("基準");
    const captured = try runtime.stringUtf8("保持値");
    var function = try runtime.createNativeFunction(name.string, 2, testNativeSum, &.{.{ .name = capture_name.string, .value = captured }});
    var frame = runtime.rootFrame();
    try frame.protect(&function);
    const stats = try runtime.collect();
    try std.testing.expectEqual(@as(usize, 4), stats.after);
    const result = try runtime.call(function, &.{ .{ .number = 2 }, .{ .number = 3 } });
    try std.testing.expectEqual(@as(f64, 5), result.number);
    frame.deinit();
    try std.testing.expectEqual(@as(usize, 4), (try runtime.collect()).collected);
}

test "Promiseの解決・拒否と連鎖をマイクロタスクへ送る" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var fulfilled = try runtime.createPromise();
    var rejected = try runtime.createPromise();
    var frame = runtime.rootFrame();
    defer frame.deinit();
    try frame.protect(&fulfilled);
    try frame.protect(&rejected);

    var fulfilled_next = try runtime.promiseThen(fulfilled.promise, .undefined, .undefined);
    try frame.protect(&fulfilled_next);
    try runtime.resolvePromise(fulfilled.promise, .{ .number = 42 });
    const fulfilled_task = runtime.takePromiseTask().?;
    try std.testing.expect(!fulfilled_task.rejected);
    try runtime.forwardPromiseTask(fulfilled_task);
    try std.testing.expectEqual(PromiseState.fulfilled, fulfilled_next.promise.state);
    try std.testing.expectEqual(@as(f64, 42), fulfilled_next.promise.result.number);

    var rejected_next = try runtime.promiseThen(rejected.promise, .undefined, .undefined);
    try frame.protect(&rejected_next);
    const reason = try runtime.stringUtf8("失敗");
    try runtime.rejectPromise(rejected.promise, reason);
    const rejected_task = runtime.takePromiseTask().?;
    try std.testing.expect(rejected_task.rejected);
    try runtime.forwardPromiseTask(rejected_task);
    try std.testing.expectEqual(PromiseState.rejected, rejected_next.promise.state);
    try std.testing.expect(Value.strictEqual(reason, rejected_next.promise.result));
}

test "Promise反応とマイクロタスクをGCルートとして追跡する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var source = try runtime.createPromise();
    var frame = runtime.rootFrame();
    try frame.protect(&source);
    const next = try runtime.promiseThen(source.promise, .undefined, .undefined);
    try runtime.resolvePromise(source.promise, .{ .number = 1 });
    frame.deinit();
    const pending = try runtime.collect();
    try std.testing.expectEqual(@as(usize, 1), pending.after);
    const task = runtime.takePromiseTask().?;
    try runtime.forwardPromiseTask(task);
    try std.testing.expectEqual(PromiseState.fulfilled, next.promise.state);
    const released = try runtime.collect();
    try std.testing.expectEqual(@as(usize, 0), released.after);
}
