const std = @import("std");
const aot_abi = @import("aot_abi.zig");
const aot_builtin = @import("aot_builtin.zig");
const BigInt = @import("bigint.zig").BigInt;
const error_message = @import("error_message.zig");
const unicode_case = @import("unicode_case");
const number_mod = @import("number.zig");
const string_mod = @import("string.zig");
const system_constant = @import("system_constant.zig");
const regexp = @import("../plugins/system/regexp.zig");

extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
extern "c" fn time(timer: ?*i64) i64;

pub const Tag = aot_abi.Tag;

const safe_array_element_limit: usize = 1_000_000;

/// AOT dispatch tracing is opt-in through LNAKO_DISPATCH_TRACE. It records
/// only static dispatch metadata; arguments, values, and addresses never
/// cross this boundary. C stdio keeps the helper available to generated
/// executables on POSIX and Windows without requiring a runtime Io object.
pub const no_dispatch_call_id = std.math.maxInt(u64);

const DispatchTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    next_call_id: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *DispatchTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *DispatchTrace) void {
        self.locked.store(false, .release);
    }

    fn deinit(self: *DispatchTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    fn ensureFile(self: *DispatchTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    fn writeLine(self: *DispatchTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    fn begin(self: *DispatchTrace, command: []const u8, opcode: u16, route: []const u8, site_id: u64) u64 {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return no_dispatch_call_id;
        if (self.next_call_id == no_dispatch_call_id) {
            self.disabled = true;
            return no_dispatch_call_id;
        }
        const call_id = self.next_call_id;
        self.next_call_id += 1;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, site_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            };
        if (!self.writeLine(file, rendered)) return no_dispatch_call_id;
        return call_id;
    }

    fn result(self: *DispatchTrace, call_id: u64, command: []const u8, opcode: u16, route: []const u8, site_id: u64, success: bool) void {
        if (call_id == no_dispatch_call_id) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, site_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            };
        _ = self.writeLine(file, rendered);
    }

    fn finish(self: *DispatchTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
        }
        const file = self.ensureFile() orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

pub const Value = extern struct {
    tag: u8 = @intFromEnum(Tag.undefined),
    payload: u64 = 0,

    pub fn object(self: Value) ?*Object {
        if (self.payload == 0) return null;
        return switch (@as(Tag, @enumFromInt(self.tag))) {
            .utf16_string, .array, .dictionary, .iterator, .bigint, .function, .binding_cell => @ptrFromInt(self.payload),
            else => null,
        };
    }
};

pub const RootFrame = extern struct {
    previous: ?*RootFrame = null,
    values: ?[*]Value = null,
    len: usize = 0,
};

const DictionaryEntry = struct { key: Value, value: Value };
const IteratorKind = enum { repeat, range, string, array, dictionary };
const Iterator = struct {
    kind: IteratorKind,
    source: Value = .{},
    index: usize = 0,
    count: usize = 0,
    current: f64 = 0,
    end: f64 = 0,
    step: f64 = 1,
};

/// Generated callbacks cross the Zig/LLVM boundary. Returning the 16-byte
/// Value aggregate directly is not portable to the Windows x64 C ABI, so the
/// result is always written through an explicit pointer.
const FunctionCallback = *const fn (*Value, *anyopaque, ?[*]const Value, usize) callconv(.c) void;
const FunctionObject = struct {
    callback: FunctionCallback,
    arity: usize,
    /// The generated wrapper name is retained as UTF-8 bytes so converting a
    /// function value to a string can preserve the same observable name that
    /// the interpreter exposes. The slice is owned by the function object.
    name: []u8,
    captures: []Value,
};

const Arithmetic = enum(u8) {
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

const Comparison = enum(u8) {
    abstract_equal,
    strict_equal,
    abstract_not_equal,
    strict_not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

const ShiftOperator = enum(u8) {
    left,
    right,
    right_unsigned,
};

const Payload = union(enum) {
    utf16_string: []u16,
    bigint: BigInt,
    array: std.ArrayList(Value),
    dictionary: std.ArrayList(DictionaryEntry),
    iterator: Iterator,
    function: FunctionObject,
    binding_cell: Value,
};

const Object = struct {
    next: ?*Object = null,
    grey_next: ?*Object = null,
    marked: bool = false,
    payload: Payload,
};

const Runtime = struct {
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
    dispatch_trace: DispatchTrace = .{},
    random_state: u64 = 0,
    clock_milliseconds: ?i64 = null,
    caniuse_browsers: Value = .{},

    fn deinit(self: *Runtime) void {
        self.dispatch_trace.deinit();
        var current = self.objects;
        while (current) |object| {
            const next = object.next;
            self.destroyObject(object);
            current = next;
        }
        self.stringifying_arrays.deinit(self.allocator);
        self.* = undefined;
    }

    fn createString(self: *Runtime, units: []const u16) !Value {
        try self.beforeAllocation();
        const owned = try self.allocator.dupe(u16, units);
        errdefer self.allocator.free(owned);
        return self.createObject(.{ .utf16_string = owned }, .utf16_string);
    }

    fn ownString(self: *Runtime, source: []u16) !Value {
        errdefer self.allocator.free(source);
        try self.beforeAllocation();
        return self.createObject(.{ .utf16_string = source }, .utf16_string);
    }

    fn createBigInt(self: *Runtime, source: []const u8) !Value {
        try self.beforeAllocation();
        var value = try BigInt.parseLiteral(self.allocator, source);
        errdefer value.deinit();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    fn ownBigInt(self: *Runtime, source: BigInt) !Value {
        var value = source;
        errdefer value.deinit();
        try self.beforeAllocation();
        return self.createObject(.{ .bigint = value }, .bigint);
    }

    fn createArray(self: *Runtime, values: []const Value) !Value {
        try self.beforeAllocation();
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);
        try items.appendSlice(self.allocator, values);
        return self.createObject(.{ .array = items }, .array);
    }

    fn createDictionary(self: *Runtime, values: []const Value) !Value {
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

    fn createIterator(self: *Runtime, values: []const Value, is_range: bool, direction: u8) !Value {
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
            .array => .{ .kind = .array, .source = values[0], .count = values[0].object().?.payload.array.items.len },
            .dictionary => .{ .kind = .dictionary, .source = values[0], .count = values[0].object().?.payload.dictionary.items.len },
            else => .{ .kind = .repeat, .count = 0 },
        };
        return self.createObject(.{ .iterator = iterator }, .iterator);
    }

    fn createFunction(self: *Runtime, callback: FunctionCallback, arity: usize, captures: []const Value) !Value {
        return self.createNamedFunction(callback, arity, &.{}, captures);
    }

    fn createNamedFunction(self: *Runtime, callback: FunctionCallback, arity: usize, name: []const u8, captures: []const Value) !Value {
        var frame: RootFrame = .{};
        self.pushRoots(&frame, if (captures.len > 0) @constCast(captures.ptr) else null, captures.len);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_captures = try self.allocator.dupe(Value, captures);
        errdefer self.allocator.free(owned_captures);
        return self.createObject(.{ .function = .{ .callback = callback, .arity = arity, .name = owned_name, .captures = owned_captures } }, .function);
    }

    fn createBindingCell(self: *Runtime, initial: Value) !Value {
        var rooted = initial;
        var frame: RootFrame = .{};
        self.pushRoots(&frame, @ptrCast(&rooted), 1);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        return self.createObject(.{ .binding_cell = rooted }, .binding_cell);
    }

    fn createObject(self: *Runtime, payload: Payload, tag: Tag) !Value {
        const object = try self.allocator.create(Object);
        errdefer self.allocator.destroy(object);
        object.* = .{
            .next = self.objects,
            .payload = payload,
        };
        self.objects = object;
        self.object_count += 1;
        return .{ .tag = @intFromEnum(tag), .payload = @intFromPtr(object) };
    }

    fn beforeAllocation(self: *Runtime) !void {
        if (self.object_count < self.next_collection) return;
        _ = self.collect();
        self.next_collection = @max(@as(usize, 64), self.object_count * 2);
    }

    fn pushRoots(self: *Runtime, frame: *RootFrame, values: ?[*]Value, len: usize) void {
        frame.* = .{ .previous = self.roots, .values = values, .len = len };
        self.roots = frame;
    }

    fn popRoots(self: *Runtime, frame: *RootFrame) void {
        if (self.roots != frame) return;
        self.roots = frame.previous;
        frame.* = .{};
    }

    fn collect(self: *Runtime) usize {
        var frame = self.roots;
        while (frame) |current| : (frame = current.previous) {
            if (current.values) |values| for (values[0..current.len]) |value| self.markValue(value);
        }
        if (self.has_pending_exception) self.markValue(self.pending_exception);
        self.markValue(self.system_context);
        self.markValue(self.caniuse_browsers);
        while (self.grey) |object| {
            self.grey = object.grey_next;
            object.grey_next = null;
            switch (object.payload) {
                .utf16_string, .bigint => {},
                .function => |function| for (function.captures) |capture| self.markValue(capture),
                .binding_cell => |value| self.markValue(value),
                .array => |items| for (items.items) |value| self.markValue(value),
                .dictionary => |entries| for (entries.items) |entry| {
                    self.markValue(entry.key);
                    self.markValue(entry.value);
                },
                .iterator => |iterator| self.markValue(iterator.source),
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

    fn markValue(self: *Runtime, value: Value) void {
        const object = value.object() orelse return;
        if (object.marked) return;
        object.marked = true;
        object.grey_next = self.grey;
        self.grey = object;
    }

    fn setException(self: *Runtime, value: Value) void {
        self.pending_exception = value;
        self.has_pending_exception = true;
        self.failure_epoch +%= 1;
    }

    fn setFailure(self: *Runtime, failure: anyerror) void {
        self.setFailureText(error_message.forFailure(failure));
    }

    fn setFailureText(self: *Runtime, text: []const u8) void {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |allocation_failure| runtimeFailure(allocation_failure);
        defer self.allocator.free(units);
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    fn setFailureUnits(self: *Runtime, units: []const u16) void {
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
    }

    fn setIndexAssignmentFailure(self: *Runtime, container: Value, key: Value) void {
        const key_units = valueUtf16Alloc(self, key) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_units);
        const key_utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, key_units) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(key_utf8);
        const container_name: []const u8 = if (container.tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
        const message = std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 }) catch |failure| runtimeFailure(failure);
        defer self.allocator.free(message);
        self.setFailureText(message);
    }

    fn systemContext(self: *Runtime) !Value {
        if (self.system_context.tag == @intFromEnum(Tag.undefined)) self.system_context = try self.createDictionary(&.{});
        return self.system_context;
    }

    fn takeException(self: *Runtime) Value {
        if (!self.has_pending_exception) return .{};
        const result = self.pending_exception;
        self.pending_exception = .{};
        self.has_pending_exception = false;
        return result;
    }

    fn destroyObject(self: *Runtime, object: *Object) void {
        switch (object.payload) {
            .utf16_string => |units| self.allocator.free(units),
            .bigint => |*value| value.deinit(),
            .array => |*items| items.deinit(self.allocator),
            .dictionary => |*entries| entries.deinit(self.allocator),
            .function => |function| {
                self.allocator.free(function.name);
                self.allocator.free(function.captures);
            },
            .iterator, .binding_cell => {},
        }
        self.allocator.destroy(object);
    }

    fn indexGet(self: *Runtime, container: Value, key: Value) Value {
        if (container.tag == @intFromEnum(Tag.utf16_string)) {
            const index = valueIndex(key) orelse return .{};
            return self.stringAt(container, index);
        }
        const object = container.object() orelse return .{};
        return switch (object.payload) {
            .array => |items| if (valueIndex(key)) |index| if (index < items.items.len) items.items[index] else .{} else .{},
            .dictionary => |entries| blk: {
                for (entries.items) |entry| if (sameKey(entry.key, key)) break :blk entry.value;
                break :blk .{};
            },
            else => .{},
        };
    }

    fn destructureGet(_: *Runtime, source: Value, index: usize) Value {
        if (source.tag == @intFromEnum(Tag.array)) {
            const items = source.object().?.payload.array.items;
            return if (index < items.len) items[index] else .{};
        }
        return if (index == 0) source else .{};
    }

    fn indexSet(self: *Runtime, container: Value, key: Value, value: Value) !void {
        const object = container.object() orelse return switch (@as(Tag, @enumFromInt(container.tag))) {
            .undefined, .null_value => error.InvalidContainer,
            else => {},
        };
        switch (object.payload) {
            .array => |*items| {
                const index = valueIndex(key) orelse return error.InvalidIndex;
                if (index >= items.items.len) {
                    const previous_len = items.items.len;
                    try items.resize(self.allocator, index + 1);
                    @memset(items.items[previous_len..], .{});
                }
                items.items[index] = value;
            },
            .dictionary => |*entries| {
                var rooted = [_]Value{ container, key, value };
                var frame = RootFrame{};
                self.pushRoots(&frame, &rooted, rooted.len);
                defer self.popRoots(&frame);
                try self.setDictionary(entries, try self.propertyKey(rooted[1]), rooted[2]);
            },
            .utf16_string, .bigint, .function, .iterator, .binding_cell => {},
        }
    }

    fn iteratorHasNext(_: *Runtime, value: Value) bool {
        const object = value.object() orelse return false;
        if (object.payload != .iterator) return false;
        const iterator = object.payload.iterator;
        return switch (iterator.kind) {
            .range => if (iterator.step > 0) iterator.current <= iterator.end else iterator.current >= iterator.end,
            else => iterator.index < iterator.count,
        };
    }

    fn iteratorNext(self: *Runtime, value: Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) Value {
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

    fn stringAt(self: *Runtime, source: Value, index: usize) Value {
        const object = source.object() orelse return .{};
        if (object.payload != .utf16_string) return .{};
        const units = object.payload.utf16_string;
        if (index >= units.len) return .{};
        return self.createString(units[index .. index + 1]) catch .{};
    }

    fn setDictionary(self: *Runtime, entries: *std.ArrayList(DictionaryEntry), key: Value, value: Value) !void {
        for (entries.items) |*entry| if (sameKey(entry.key, key)) {
            entry.value = value;
            return;
        };
        try entries.append(self.allocator, .{ .key = key, .value = value });
    }

    fn propertyKey(self: *Runtime, key: Value) !Value {
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

fn valueIndex(value: Value) ?usize {
    if (value.tag != @intFromEnum(Tag.number)) return null;
    const number: f64 = @bitCast(value.payload);
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

fn valueToNumber(value: Value) f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        else => std.math.nan(f64),
    };
}

fn valueToNumberRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => std.math.nan(f64),
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => parseStringNumber(runtime, value),
        .bigint => error.CannotConvertBigIntToNumber,
        .array, .dictionary, .iterator, .function => valueToNumberRuntime(runtime, try valueToPrimitive(runtime, value)),
        .binding_cell => unreachable,
    };
}

/// `Number(i['末尾'])` 相当。暗黙のBigInt数値変換は他の演算で拒否し、
/// 明示的な範囲終端の変換だけBigInt.toF64を許可する。
fn explicitRangeNumber(runtime: *Runtime, value: Value) !f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    return valueToNumberRuntime(runtime, value);
}

fn valueToParseFloatRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk string_mod.parseFloatNumber(runtime.allocator, units);
        },
        .bigint => error.CannotConvertBigIntToNumber,
        .array, .dictionary, .iterator, .function => valueToParseFloatRuntime(runtime, try valueToPrimitive(runtime, value)),
        .binding_cell => unreachable,
        .undefined, .null_value, .boolean => std.math.nan(f64),
    };
}

fn parseStringNumber(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    if (trimmed.len == 0) return 0;
    for (trimmed) |unit| if (unit > 0x7f) return std.math.nan(f64);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| ascii[index] = @intCast(unit);
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

fn incrementNumber(runtime: *Runtime, value: Value) f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    if (isString(value)) {
        const utf8 = stringUtf8Alloc(runtime, value) catch return std.math.nan(f64);
        defer runtime.allocator.free(utf8);
        const trimmed = std.mem.trim(u8, utf8, " \t\r\n\x0b\x0c");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    return valueToNumber(value);
}

fn incrementValue(runtime: *Runtime, old: Value, amount: Value) Value {
    const old_number: f64 = if (old.tag == @intFromEnum(Tag.undefined)) 0 else incrementNumber(runtime, old);
    return numberValue(old_number + incrementNumber(runtime, amount));
}

fn isString(value: Value) bool {
    return value.tag == @intFromEnum(Tag.static_utf8_string) or value.tag == @intFromEnum(Tag.utf16_string);
}

fn isObject(value: Value) bool {
    return value.tag == @intFromEnum(Tag.array) or value.tag == @intFromEnum(Tag.dictionary) or
        value.tag == @intFromEnum(Tag.iterator) or value.tag == @intFromEnum(Tag.function);
}

fn stringUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => (string_mod.String{
            .allocator = runtime.allocator,
            .units = value.object().?.payload.utf16_string,
        }).toUtf8Lossy(runtime.allocator),
        else => error.ExpectedString,
    };
}

const RegexpCallResult = struct { value: Value, captures: ?Value = null };

fn regexpCommandName(command: aot_builtin.Command) ?[]const u8 {
    return switch (command) {
        .regexp_match => "正規表現マッチ",
        .regexp_extract => "正規表現抽出",
        .regexp_replace => "正規表現置換",
        .regexp_split => "正規表現区切",
        else => null,
    };
}

fn regexpBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !RegexpCallResult {
    _ = regexpCommandName(command) orelse return error.UnknownCommand;
    const required: usize = if (command == .regexp_replace) 3 else 2;
    if (arguments.len < required) return error.InvalidArgumentCount;

    var rooted = [_]Value{ arguments[0], arguments[1], if (arguments.len > 2) arguments[2] else .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, rooted[0]);
    defer runtime.allocator.free(source_units);
    const pattern_units = try valueUtf16Alloc(runtime, rooted[1]);
    defer runtime.allocator.free(pattern_units);
    var compiled = try regexp.compilePattern(runtime.allocator, pattern_units, true);
    defer compiled.deinit();

    if (command == .regexp_replace) {
        const replacement_units = try valueUtf16Alloc(runtime, rooted[2]);
        defer runtime.allocator.free(replacement_units);
        const output_units = try regexp.replaceUnits(runtime.allocator, source_units, replacement_units, &compiled);
        defer runtime.allocator.free(output_units);
        rooted[3] = try runtime.createString(output_units);
        return .{ .value = rooted[3] };
    }

    if (command == .regexp_extract or command == .regexp_split) compiled.flags.global = true;
    const matches = try regexp.findMatches(runtime.allocator, source_units, &compiled);
    defer runtime.allocator.free(matches);
    rooted[3] = try runtime.createArray(&.{});

    if (command == .regexp_match) {
        if (matches.len == 0) return .{ .value = .{ .tag = @intFromEnum(Tag.null_value) }, .captures = rooted[3] };
        if (!compiled.flags.global) {
            for (matches[0].captures[0..compiled.capture_count]) |span| {
                const item: Value = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                try rooted[3].object().?.payload.array.append(runtime.allocator, item);
            }
            rooted[4] = try runtime.createString(source_units[matches[0].span.start..matches[0].span.end]);
            return .{ .value = rooted[4], .captures = rooted[3] };
        }
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            const item = try runtime.createString(source_units[match.span.start..match.span.end]);
            try rooted[4].object().?.payload.array.append(runtime.allocator, item);
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    if (command == .regexp_extract) {
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            var has_named = false;
            for (compiled.capture_names[0..compiled.capture_count]) |capture_name| if (capture_name != null) {
                has_named = true;
                break;
            };
            if (has_named) {
                rooted[5] = try runtime.createDictionary(&.{});
                for (compiled.capture_names[0..compiled.capture_count], 0..) |capture_name, index| if (capture_name) |key_units| {
                    rooted[6] = if (match.captures[index].matched) try runtime.createString(source_units[match.captures[index].start..match.captures[index].end]) else .{};
                    rooted[7] = try runtime.createString(key_units);
                    try rooted[5].object().?.payload.dictionary.append(runtime.allocator, .{ .key = rooted[7], .value = rooted[6] });
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                };
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            } else {
                rooted[5] = try runtime.createArray(&.{});
                if (compiled.capture_count == 0) {
                    rooted[6] = try runtime.createString(source_units[match.span.start..match.span.end]);
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                } else for (match.captures[0..compiled.capture_count]) |span| {
                    rooted[6] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                }
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            }
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    // String.split(RegExp) always uses global matching and includes captures.
    rooted[4] = rooted[3];
    var cursor: usize = 0;
    for (matches) |match| {
        if (match.span.start == match.span.end and (match.span.start == 0 or match.span.start == source_units.len or match.span.start == cursor)) continue;
        rooted[5] = try runtime.createString(source_units[cursor..match.span.start]);
        try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        for (match.captures[0..compiled.capture_count]) |span| {
            rooted[5] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
            try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        }
        cursor = match.span.end;
    }
    rooted[5] = try runtime.createString(source_units[cursor..]);
    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
    if (source_units.len == 0 and matches.len > 0) rooted[4].object().?.payload.array.clearRetainingCapacity();
    return .{ .value = rooted[4] };
}

/// Dedicated ABI because regexp match/extract update the system global
/// `抽出文字列` in addition to returning their normal value.
pub export fn lnako_aot_regexp_call(out: *Value, captures: ?*Value, arguments: ?[*]const Value, len: usize, opcode: u16) callconv(.c) void {
    lnako_aot_regexp_call_site(out, captures, arguments, len, opcode, 0);
}

pub export fn lnako_aot_regexp_call_site(out: *Value, captures: ?*Value, arguments: ?[*]const Value, len: usize, opcode: u16, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "regexp", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "regexp", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "regexp", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "regexp", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = if (arguments) |pointer| pointer[0..len] else &.{};
    const result = regexpBuiltin(runtime, command, values) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    out.* = result.value;
    if (captures) |target| {
        if (result.captures) |value| target.* = value;
    }
    success = runtime.failure_epoch == start_epoch;
}

const JsonAotPath = union(enum) {
    array_index: usize,
    property: Value,
};

const JsonAotActive = struct {
    object: *Object,
    constructor: []const u8,
    path: ?JsonAotPath,
};

const JsonAotEntry = struct {
    key: Value,
    value: Value,
    insertion_index: usize,
    array_index: ?u32,
};

/// Pure AOT implementation of the JSON.stringify-backed command family.
/// Keep this serializer independent from QuickJS: the generated executable
/// must retain the same ECMAScript JSON boundary without a JavaScript engine.
fn jsonEncodeBuiltin(runtime: *Runtime, value: Value, pretty: bool) !Value {
    if (value.tag == @intFromEnum(Tag.undefined) or value.tag == @intFromEnum(Tag.function)) return .{};
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var active_objects: std.ArrayList(JsonAotActive) = .empty;
    defer active_objects.deinit(runtime.allocator);
    try jsonWriteValue(runtime, &output.writer, value, pretty, 0, &active_objects, false, null);
    return runtime.ownString(try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, output.written()));
}

fn jsonWriteValue(
    runtime: *Runtime,
    writer: *std.Io.Writer,
    value: Value,
    pretty: bool,
    depth: usize,
    active_objects: *std.ArrayList(JsonAotActive),
    in_array: bool,
    path: ?JsonAotPath,
) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .function => if (in_array) try writer.writeAll("null") else return,
        .null_value => try writer.writeAll("null"),
        .boolean => try writer.writeAll(if (value.payload != 0) "true" else "false"),
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number)) return writer.writeAll("null");
            const text = try numberString(runtime.allocator, number);
            defer runtime.allocator.free(text);
            try writer.writeAll(text);
        },
        .bigint => return error.CannotSerializeBigInt,
        .static_utf8_string => {
            const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(value));
            defer runtime.allocator.free(units);
            try jsonWriteQuotedString(writer, units);
        },
        .utf16_string => try jsonWriteQuotedString(writer, value.object().?.payload.utf16_string),
        .iterator => try writer.writeAll("{}"),
        .binding_cell => unreachable,
        .array => {
            const object = value.object().?;
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Array", .path = path });
            defer _ = active_objects.pop();
            const items = object.payload.array.items;
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteValue(runtime, writer, item, pretty, depth + 1, active_objects, true, .{ .array_index = index });
            }
            if (pretty and items.len > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => {
            const object = value.object().?;
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Object", .path = path });
            defer _ = active_objects.pop();
            const dictionary_length = object.payload.dictionary.items.len;
            const key_roots = try runtime.allocator.alloc(Value, dictionary_length);
            defer runtime.allocator.free(key_roots);
            @memset(key_roots, .{});
            var key_frame = RootFrame{};
            runtime.pushRoots(&key_frame, if (dictionary_length > 0) key_roots.ptr else null, dictionary_length);
            defer runtime.popRoots(&key_frame);
            var entries: std.ArrayList(JsonAotEntry) = .empty;
            defer entries.deinit(runtime.allocator);
            for (object.payload.dictionary.items, 0..) |entry, insertion_index| {
                const normalized_key = try jsonAotPropertyKey(runtime, entry.key);
                key_roots[insertion_index] = normalized_key;
                var replaced = false;
                for (entries.items) |*existing| if (sameKey(existing.key, normalized_key)) {
                    // JavaScript property assignment keeps the first insertion
                    // position while a later numeric/string spelling wins.
                    existing.value = entry.value;
                    replaced = true;
                    break;
                };
                if (!replaced) try entries.append(runtime.allocator, .{
                    .key = normalized_key,
                    .value = entry.value,
                    .insertion_index = insertion_index,
                    .array_index = jsonAotArrayIndex(runtime, normalized_key),
                });
            }
            std.sort.pdq(JsonAotEntry, entries.items, {}, lessJsonAotEntry);
            try writer.writeByte('{');
            var emitted: usize = 0;
            for (entries.items) |entry| {
                if (entry.value.tag == @intFromEnum(Tag.undefined) or entry.value.tag == @intFromEnum(Tag.function)) continue;
                if (emitted > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteKey(runtime, writer, entry.key);
                try writer.writeAll(if (pretty) ": " else ":");
                try jsonWriteValue(runtime, writer, entry.value, pretty, depth + 1, active_objects, false, .{ .property = entry.key });
                emitted += 1;
            }
            if (pretty and emitted > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte('}');
        },
    }
}

fn jsonActiveIndex(objects: []JsonAotActive, object: *Object) ?usize {
    for (objects, 0..) |active, index| if (active.object == object) return index;
    return null;
}

fn jsonAotArrayIndex(runtime: *Runtime, key: Value) ?u32 {
    const units = jsonAotKeyUnits(runtime, key) catch return null;
    defer runtime.allocator.free(units);
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: u64 = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: u64 = unit - '0';
        if (number > (0xffff_ffff - digit) / 10) return null;
        number = number * 10 + digit;
        if (number >= 0xffff_ffff) return null;
    }
    if (units.len == 1 and units[0] == '0') return 0;
    return @intCast(number);
}

fn jsonAotKeyUnits(runtime: *Runtime, key: Value) ![]u16 {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(key)),
        .utf16_string => runtime.allocator.dupe(u16, key.object().?.payload.utf16_string),
        else => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined"),
    };
}

fn jsonAotPropertyKey(runtime: *Runtime, key: Value) !Value {
    return runtime.ownString(try valueUtf16Alloc(runtime, key));
}

fn lessJsonAotEntry(_: void, left: JsonAotEntry, right: JsonAotEntry) bool {
    if (left.array_index) |left_index| {
        if (right.array_index) |right_index| return left_index < right_index;
        return true;
    }
    if (right.array_index != null) return false;
    return left.insertion_index < right.insertion_index;
}

fn jsonWriteKey(runtime: *Runtime, writer: *std.Io.Writer, key: Value) !void {
    const units = try jsonAotKeyUnits(runtime, key);
    defer runtime.allocator.free(units);
    try jsonWriteQuotedString(writer, units);
}

fn jsonWriteQuotedString(writer: *std.Io.Writer, units: []const u16) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        switch (unit) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x09 => try writer.writeAll("\\t"),
            0x0a => try writer.writeAll("\\n"),
            0x0c => try writer.writeAll("\\f"),
            0x0d => try writer.writeAll("\\r"),
            0x0000...0x0007, 0x000b, 0x000e...0x001f => try jsonWriteUnicodeEscape(writer, unit),
            0xd800...0xdbff => {
                if (index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
                    const codepoint: u21 = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + (@as(u32, units[index + 1]) - 0xdc00));
                    var encoded: [4]u8 = undefined;
                    const length = try std.unicode.utf8Encode(codepoint, &encoded);
                    try writer.writeAll(encoded[0..length]);
                    index += 1;
                } else try jsonWriteUnicodeEscape(writer, unit);
            },
            0xdc00...0xdfff => try jsonWriteUnicodeEscape(writer, unit),
            else => {
                var encoded: [3]u8 = undefined;
                const length = try std.unicode.utf8Encode(@intCast(unit), &encoded);
                try writer.writeAll(encoded[0..length]);
            },
        }
        index += 1;
    }
    try writer.writeByte('"');
}

fn jsonWriteUnicodeEscape(writer: *std.Io.Writer, unit: u16) !void {
    const digits = "0123456789abcdef";
    try writer.writeAll("\\u");
    try writer.writeByte(digits[(unit >> 12) & 0xf]);
    try writer.writeByte(digits[(unit >> 8) & 0xf]);
    try writer.writeByte(digits[(unit >> 4) & 0xf]);
    try writer.writeByte(digits[unit & 0xf]);
}

fn jsonWriteIndent(writer: *std.Io.Writer, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try writer.writeAll("  ");
}

fn jsonSetCircularFailureMessage(runtime: *Runtime, active: []JsonAotActive, cycle_start: usize, closing_path: ?JsonAotPath) !void {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    const start_constructor = if (cycle_start < active.len) active[cycle_start].constructor else "Object";
    try output.writer.print("Converting circular structure to JSON\n    --> starting at object with constructor '{s}'\n", .{start_constructor});
    // Every active entry after the root is an edge on the current path. V8
    // prints those edges before the final edge that closes the cycle.
    var index: usize = cycle_start + 1;
    while (index < active.len) : (index += 1) {
        try output.writer.writeAll("    |     ");
        try jsonWritePath(&output.writer, runtime, active[index].path, false);
        try output.writer.print(" -> object with constructor '{s}'\n", .{active[index].constructor});
    }
    try output.writer.writeAll("    --- ");
    try jsonWritePath(&output.writer, runtime, closing_path, true);
    runtime.setFailureText(output.written());
}

fn jsonWritePath(writer: *std.Io.Writer, runtime: *Runtime, path: ?JsonAotPath, closing: bool) !void {
    if (path) |cycle_path| switch (cycle_path) {
        .array_index => |index| try writer.print("index {d}{s}", .{ index, if (closing) " closes the circle" else "" }),
        .property => |key| {
            const units = try jsonAotKeyUnits(runtime, key);
            defer runtime.allocator.free(units);
            const utf8 = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
            defer runtime.allocator.free(utf8);
            try writer.print("property '{s}'{s}", .{ utf8, if (closing) " closes the circle" else "" });
        },
    } else if (closing) try writer.writeAll("cycle closes the circle") else try writer.writeAll("cycle");
}

fn expectJsonAotString(runtime: *Runtime, value: Value, pretty: bool, expected: []const u8) !void {
    const encoded = try jsonEncodeBuiltin(runtime, value, pretty);
    const actual_units = try valueUtf16Alloc(runtime, encoded);
    defer runtime.allocator.free(actual_units);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
    defer runtime.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, actual_units);
}

/// JSON.parse-compatible decoder for the native runtime.  The input and
/// output strings are UTF-16 code-unit sequences, so escaped and literal
/// lone surrogates are retained exactly as ECMAScript does.  Using
/// `std.json` here would reject those values before the Nako value layer saw
/// them; this explicit-stack parser deliberately works on u16.
const JsonAotFrameKind = enum { array, dictionary };

const JsonAotFrameState = enum {
    array_open,
    array_need_value,
    array_after_value,
    dictionary_open,
    dictionary_need_key,
    dictionary_need_value,
    dictionary_after_value,
};

const JsonAotFrame = struct {
    kind: JsonAotFrameKind,
    state: JsonAotFrameState,
    result_index: usize,
    root_base: usize,
};

const JsonAotParser = struct {
    runtime: *Runtime,
    units: []const u16,
    index: usize = 0,

    fn parse(self: *JsonAotParser) anyerror!Value {
        if (jsonAsciiEquals(self.units, "undefined") or jsonAsciiEquals(self.units, "Infinity") or jsonAsciiEquals(self.units, "NaN") or jsonAsciiEquals(self.units, "[object Object]")) {
            return self.failWholeSourceInvalid();
        }
        self.skipWhitespace();
        if (self.index >= self.units.len) return self.failEnd();
        // JSON nesting is not bounded by the host call stack.  Allocate all
        // parser frames and roots up front so reallocating either collection
        // can never invalidate the root slice registered with the GC.
        const max_frames = jsonAotContainerCount(self.units);
        const frame_root_count = std.math.mul(usize, max_frames, 3) catch return error.OutOfMemory;
        const root_count = std.math.add(usize, frame_root_count, 1) catch return error.OutOfMemory;
        var roots = try self.runtime.allocator.alloc(Value, root_count);
        defer self.runtime.allocator.free(roots);
        @memset(roots, .{});
        var frames = try self.runtime.allocator.alloc(JsonAotFrame, max_frames);
        defer self.runtime.allocator.free(frames);
        var root_frame = RootFrame{};
        self.runtime.pushRoots(&root_frame, roots.ptr, roots.len);
        defer self.runtime.popRoots(&root_frame);

        var frame_count: usize = 0;
        var root_done = false;
        while (true) {
            if (frame_count == 0) {
                if (root_done) {
                    self.skipWhitespace();
                    if (self.index != self.units.len) return self.failTrailing();
                    return roots[0];
                }
                if (try self.beginValue(roots, frames, &frame_count, 0)) continue;
                roots[0] = try self.parseScalar();
                root_done = true;
                continue;
            }

            const frame_index = frame_count - 1;
            const frame = frames[frame_index];
            const base = frame.root_base;
            switch (frame.state) {
                .array_open, .array_need_value => {
                    self.skipWhitespace();
                    if (frame.state == .array_open and self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .array_after_value => {
                    self.skipWhitespace();
                    if (self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .array_need_value;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or ']' after array element");
                    } else return self.failToken(self.index);
                },
                .dictionary_open, .dictionary_need_key => {
                    self.skipWhitespace();
                    if (frame.state == .dictionary_open and self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (frame.state == .dictionary_need_key and self.index >= self.units.len) return self.failJsonMessage("Expected double-quoted property name");
                    if (frame.state == .dictionary_need_key and self.units[self.index] != '"') return self.failJsonMessage("Expected double-quoted property name");
                    if (self.index >= self.units.len or self.units[self.index] != '"') return self.failJsonMessage("Expected property name or '}'");
                    roots[base + 1] = try self.parseStringValue();
                    self.skipWhitespace();
                    if (!self.consume(':')) return self.failJsonMessage("Expected ':' after property name");
                    frames[frame_index].state = .dictionary_need_value;
                },
                .dictionary_need_value => {
                    self.skipWhitespace();
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .dictionary_after_value => {
                    self.skipWhitespace();
                    if (self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .dictionary_need_key;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or '}' after property value");
                    } else return self.failToken(self.index);
                },
            }
        }
    }

    /// Start a scalar or container at `result_index`.  A container gets an
    /// explicit frame; a scalar is left for parseScalar so the caller can
    /// store it in a GC root before any append/set operation.
    fn beginValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize, result_index: usize) !bool {
        if (self.index >= self.units.len) return self.failEnd();
        switch (self.units[self.index]) {
            '[' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createArray(&.{});
                frames[frame_count.*] = .{ .kind = .array, .state = .array_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            '{' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createDictionary(&.{});
                frames[frame_count.*] = .{ .kind = .dictionary, .state = .dictionary_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            else => return false,
        }
    }

    fn parseScalar(self: *JsonAotParser) anyerror!Value {
        if (self.index >= self.units.len) return self.failEnd();
        return switch (self.units[self.index]) {
            'n' => try self.parseLiteral("null", .{ .tag = @intFromEnum(Tag.null_value) }),
            't' => try self.parseLiteral("true", .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }),
            'f' => try self.parseLiteral("false", .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 }),
            '"' => try self.parseStringValue(),
            '-', '0'...'9' => try self.parseNumber(),
            else => self.failToken(self.index),
        };
    }

    fn attachValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: usize, value_index: usize) !void {
        const parent_index = frame_count - 1;
        const parent = frames[parent_index];
        const parent_base = parent.root_base;
        switch (frames[parent_index].kind) {
            .array => {
                try roots[parent.result_index].object().?.payload.array.append(self.runtime.allocator, roots[value_index]);
                frames[parent_index].state = .array_after_value;
            },
            .dictionary => {
                try self.runtime.setDictionary(&roots[parent.result_index].object().?.payload.dictionary, roots[parent_base + 1], roots[value_index]);
                frames[parent_index].state = .dictionary_after_value;
            },
        }
    }

    fn closeFrame(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize) !void {
        const child_index = frame_count.* - 1;
        const child_base = frames[child_index].result_index;
        frame_count.* -= 1;
        if (frame_count.* == 0) {
            roots[0] = roots[child_base];
            return;
        }
        try self.attachValue(roots, frames, frame_count.*, child_base);
    }

    fn parseLiteral(self: *JsonAotParser, comptime literal: []const u8, value: Value) anyerror!Value {
        if (self.index + literal.len > self.units.len) return self.failEnd();
        for (literal, 0..) |byte, offset| if (self.units[self.index + offset] != byte) return self.failToken(self.index + offset);
        self.index += literal.len;
        return value;
    }

    fn parseStringValue(self: *JsonAotParser) anyerror!Value {
        const units = try self.parseStringUnits();
        defer self.runtime.allocator.free(units);
        return self.runtime.createString(units);
    }

    fn parseStringUnits(self: *JsonAotParser) anyerror![]u16 {
        if (self.index >= self.units.len or self.units[self.index] != '"') return self.failToken(self.index);
        self.index += 1;
        var result: std.ArrayList(u16) = .empty;
        errdefer result.deinit(self.runtime.allocator);
        while (self.index < self.units.len) {
            const unit = self.units[self.index];
            self.index += 1;
            switch (unit) {
                '"' => return result.toOwnedSlice(self.runtime.allocator),
                '\\' => {
                    if (self.index >= self.units.len) return self.failEnd();
                    const escaped = self.units[self.index];
                    self.index += 1;
                    switch (escaped) {
                        '"', '\\', '/' => try result.append(self.runtime.allocator, escaped),
                        'b' => try result.append(self.runtime.allocator, 0x08),
                        'f' => try result.append(self.runtime.allocator, 0x0c),
                        'n' => try result.append(self.runtime.allocator, 0x0a),
                        'r' => try result.append(self.runtime.allocator, 0x0d),
                        't' => try result.append(self.runtime.allocator, 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) return self.failJsonMessageAt("Bad Unicode escape", if (self.units.len > 0 and self.units[self.units.len - 1] == '"') self.units.len - 1 else self.units.len);
                            var code_unit: u16 = 0;
                            for (self.units[self.index .. self.index + 4], 0..) |digit, offset| {
                                const value = jsonHexDigit(digit) orelse return self.failJsonMessageAt("Bad Unicode escape", self.index + offset);
                                code_unit = (code_unit << 4) | value;
                            }
                            self.index += 4;
                            // ECMAScript JSON.parse preserves lone surrogates.
                            // A valid pair is also kept as two UTF-16 units.
                            try result.append(self.runtime.allocator, code_unit);
                        },
                        else => return self.failJsonMessageAt("Bad escaped character", self.index - 1),
                    }
                },
                0...0x1f => return self.failJsonMessageAt("Bad control character in string literal", self.index - 1),
                else => try result.append(self.runtime.allocator, unit),
            }
        }
        return self.failJsonMessage("Unterminated string");
    }

    fn parseNumber(self: *JsonAotParser) anyerror!Value {
        const start = self.index;
        if (self.consume('-') and (self.index >= self.units.len or !isJsonDigit(self.units[self.index]))) return self.failJsonMessage("No number after minus sign");
        if (self.consume('0')) {
            if (self.index < self.units.len and isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unexpected number");
        } else {
            if (self.index >= self.units.len or self.units[self.index] < '1' or self.units[self.index] > '9') return self.failToken(self.index);
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.consume('.')) {
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unterminated fractional number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.index < self.units.len and (self.units[self.index] == 'e' or self.units[self.index] == 'E')) {
            self.index += 1;
            _ = self.consume('+') or self.consume('-');
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Exponent part is missing a number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        const number_units = self.units[start..self.index];
        var ascii = try self.runtime.allocator.alloc(u8, number_units.len);
        defer self.runtime.allocator.free(ascii);
        for (number_units, 0..) |unit, offset| ascii[offset] = @intCast(unit);
        const number = std.fmt.parseFloat(f64, ascii) catch jsonParseDecimal(number_units);
        return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
    }

    fn consume(self: *JsonAotParser, expected: u16) bool {
        if (self.index < self.units.len and self.units[self.index] == expected) {
            self.index += 1;
            return true;
        }
        return false;
    }

    fn skipWhitespace(self: *JsonAotParser) void {
        while (self.index < self.units.len) switch (self.units[self.index]) {
            ' ', '\n', '\r', '\t' => self.index += 1,
            else => return,
        };
    }

    fn failEnd(self: *JsonAotParser) anyerror {
        self.runtime.setFailureText("Unexpected end of JSON input");
        return error.InvalidJsonCloneValue;
    }

    fn failJsonMessage(self: *JsonAotParser, prefix: []const u8) anyerror {
        return self.failJsonMessageAt(prefix, self.index);
    }

    fn failJsonMessageAt(self: *JsonAotParser, prefix: []const u8, position: usize) anyerror {
        var line: usize = 1;
        var column: usize = 1;
        const bounded = @min(position, self.units.len);
        var offset: usize = 0;
        while (offset < bounded) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < bounded and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
                continue;
            }
            if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "{s} in JSON at position {d} (line {d} column {d})", .{ prefix, bounded, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }

    fn failToken(self: *JsonAotParser, position: usize) anyerror {
        if (position >= self.units.len) return self.failEnd();
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try appendAsciiUnits(&message, self.runtime.allocator, "Unexpected token '");
        try message.append(self.runtime.allocator, self.units[position]);
        try appendAsciiUnits(&message, self.runtime.allocator, "', ");
        try self.appendJsonErrorSourceUnits(&message, true, position);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    fn failWholeSourceInvalid(self: *JsonAotParser) anyerror {
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try self.appendJsonErrorSourceUnits(&message, false, 0);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    /// V8 shows a UTF-16 window of at most ten code units on either side of
    /// the invalid token.  Diagnostic source text is not JSON-escaped: raw
    /// quotes, backslashes, and control units are retained by Node 24.
    fn appendJsonErrorSourceUnits(self: *JsonAotParser, output: *std.ArrayList(u16), truncate: bool, position: usize) !void {
        const bounded = @min(position, self.units.len);
        const should_truncate = truncate and self.units.len > 20;
        const start = if (should_truncate and bounded > 10) bounded - 10 else 0;
        const end = if (should_truncate) @min(self.units.len, bounded + 10) else self.units.len;
        const leading_ellipsis = should_truncate and (start > 0 or bounded >= 10);
        if (leading_ellipsis) try appendAsciiUnits(output, self.runtime.allocator, "...");
        try output.append(self.runtime.allocator, '"');
        try output.appendSlice(self.runtime.allocator, self.units[start..end]);
        try output.append(self.runtime.allocator, '"');
        if (should_truncate and end < self.units.len) try appendAsciiUnits(output, self.runtime.allocator, "...");
    }

    fn failTrailing(self: *JsonAotParser) anyerror {
        const position = self.index;
        var line: usize = 1;
        var column: usize = 1;
        var offset: usize = 0;
        while (offset < position) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < position and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
            } else if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "Unexpected non-whitespace character after JSON at position {d} (line {d} column {d})", .{ position, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }
};

fn appendAsciiUnits(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

fn appendUtf8Units(output: *std.ArrayList(u16), allocator: std.mem.Allocator, text: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try output.appendSlice(allocator, units);
}

fn jsonHexDigit(unit: u16) ?u16 {
    return if (unit >= '0' and unit <= '9') unit - '0' else if (unit >= 'a' and unit <= 'f') unit - 'a' + 10 else if (unit >= 'A' and unit <= 'F') unit - 'A' + 10 else null;
}

fn isJsonDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

fn jsonAsciiEquals(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

/// Count only container starts outside JSON strings.  This is a sizing scan,
/// not validation: malformed input may still be rejected by the parser, but
/// every opening token the parser could process is counted unless it is inside
/// the same string/escape state that parseStringUnits uses.
fn jsonAotContainerCount(units: []const u16) usize {
    var count: usize = 0;
    var in_string = false;
    var escaped = false;
    for (units) |unit| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (unit == '\\') {
                escaped = true;
            } else if (unit == '"') {
                in_string = false;
            }
            continue;
        }
        if (unit == '"') {
            in_string = true;
        } else if (unit == '[' or unit == '{') {
            count = std.math.add(usize, count, 1) catch return std.math.maxInt(usize);
        }
    }
    return @max(count, 1);
}

fn jsonParseDecimal(units: []const u16) f64 {
    var index: usize = 0;
    const negative = units.len > 0 and units[0] == '-';
    if (negative) index += 1;
    var value: f64 = 0;
    while (index < units.len and isJsonDigit(units[index])) : (index += 1) value = value * 10 + @as(f64, @floatFromInt(units[index] - '0'));
    if (index < units.len and units[index] == '.') {
        index += 1;
        var scale: f64 = 0.1;
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) {
            value += @as(f64, @floatFromInt(units[index] - '0')) * scale;
            scale *= 0.1;
        }
    }
    var exponent: i32 = 0;
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        index += 1;
        var exponent_negative = false;
        if (index < units.len and (units[index] == '+' or units[index] == '-')) {
            exponent_negative = units[index] == '-';
            index += 1;
        }
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) exponent = @min(@as(i32, 10000), exponent * 10 + @as(i32, @intCast(units[index] - '0')));
        if (exponent_negative) exponent = -exponent;
    }
    const result = value * std.math.pow(f64, 10, @floatFromInt(exponent));
    return if (negative) -result else result;
}

fn jsonDecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var parser = JsonAotParser{ .runtime = runtime, .units = units };
    return parser.parse();
}

test "AOT JSONデコードはUTF-16・数値境界・重複キーを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try createJsonTestString(&runtime, "{\"a\":1,\"b\":[true,null,-0,9007199254740993,1e400,1e-4000],\"a\":3,\"s\":\"\\ud800\\udc00\\ud800\"}");
    roots[1] = try jsonDecodeBuiltin(&runtime, roots[0]);
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[1].tag)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(jsonTestDictionaryGet(roots[1], &.{'a'}).payload)));
    roots[2] = jsonTestDictionaryGet(roots[1], &.{'b'});
    try std.testing.expectEqual(@as(usize, 6), roots[2].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), roots[2].object().?.payload.array.items[2].payload);
    try std.testing.expect(std.math.isInf(@as(f64, @bitCast(roots[2].object().?.payload.array.items[4].payload))));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(roots[2].object().?.payload.array.items[5].payload)));
    roots[3] = jsonTestDictionaryGet(roots[1], &.{'s'});
    try std.testing.expectEqualSlices(u16, &.{ 0xd800, 0xdc00, 0xd800 }, roots[3].object().?.payload.utf16_string);

    roots[4] = try createJsonTestString(&runtime, "[1,2]");
    roots[5] = try jsonDecodeBuiltin(&runtime, roots[4]);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[5].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[5].object().?.payload.array.items[1].payload)));

    roots[6] = try createJsonTestString(&runtime, "x");
    try std.testing.expectError(error.InvalidJsonCloneValue, jsonDecodeBuiltin(&runtime, roots[6]));
    const invalid_message = runtime.takeException();
    try expectUtf16String(&runtime, invalid_message, "Unexpected token 'x', \"x\" is not valid JSON");
    roots[7] = try createJsonTestString(&runtime, "");
    try std.testing.expectError(error.InvalidJsonCloneValue, jsonDecodeBuiltin(&runtime, roots[7]));
    const empty_message = runtime.takeException();
    try expectUtf16String(&runtime, empty_message, "Unexpected end of JSON input");
    try std.testing.expectError(error.InvalidJsonCloneValue, jsonDecodeBuiltin(&runtime, .{}));
    const undefined_message = runtime.takeException();
    try expectUtf16String(&runtime, undefined_message, "\"undefined\" is not valid JSON");

    const invalid_cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "[1", .message = "Expected ',' or ']' after array element in JSON at position 2 (line 1 column 3)" },
        .{ .source = "{", .message = "Expected property name or '}' in JSON at position 1 (line 1 column 2)" },
        .{ .source = "{\"a\"}", .message = "Expected ':' after property name in JSON at position 4 (line 1 column 5)" },
        .{ .source = "{\"a\":1", .message = "Expected ',' or '}' after property value in JSON at position 6 (line 1 column 7)" },
        .{ .source = "1.", .message = "Unterminated fractional number in JSON at position 2 (line 1 column 3)" },
        .{ .source = "1e+", .message = "Exponent part is missing a number in JSON at position 3 (line 1 column 4)" },
        .{ .source = "-Infinity", .message = "No number after minus sign in JSON at position 1 (line 1 column 2)" },
        .{ .source = "NaN", .message = "\"NaN\" is not valid JSON" },
        .{ .source = "[object Object]", .message = "\"[object Object]\" is not valid JSON" },
        .{ .source = "01", .message = "Unexpected number in JSON at position 1 (line 1 column 2)" },
        .{ .source = "-01", .message = "Unexpected number in JSON at position 2 (line 1 column 3)" },
        .{ .source = "{\"a\":1,}", .message = "Expected double-quoted property name in JSON at position 7 (line 1 column 8)" },
        .{ .source = "{\"a\":1,", .message = "Expected double-quoted property name in JSON at position 7 (line 1 column 8)" },
        .{ .source = "{\"a\":1, x:2}", .message = "Expected double-quoted property name in JSON at position 8 (line 1 column 9)" },
        .{ .source = "\"\x1f\"", .message = "Bad control character in string literal in JSON at position 1 (line 1 column 2)" },
        .{ .source = "\"\\u12\"", .message = "Bad Unicode escape in JSON at position 5 (line 1 column 6)" },
        .{ .source = "\"\\u12x4\"", .message = "Bad Unicode escape in JSON at position 5 (line 1 column 6)" },
        .{ .source = "あ", .message = "Unexpected token 'あ', \"あ\" is not valid JSON" },
        .{ .source = "\"abc", .message = "Unterminated string in JSON at position 4 (line 1 column 5)" },
        .{ .source = "\"\\x00\"", .message = "Bad escaped character in JSON at position 2 (line 1 column 3)" },
        .{ .source = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaax", .message = "Unexpected token 'a', \"aaaaaaaaaa\"... is not valid JSON" },
        .{ .source = "          xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .message = "Unexpected token 'x', ...\"          xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "           xbbbbbbbb", .message = "Unexpected token 'x', \"           xbbbbbbbb\" is not valid JSON" },
        .{ .source = "          xbbbbbbbbbb", .message = "Unexpected token 'x', ...\"          xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "         xbbbbbbbbbbb", .message = "Unexpected token 'x', \"         xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "x\n", .message = "Unexpected token 'x', \"x\n\" is not valid JSON" },
        .{ .source = "x\"q", .message = "Unexpected token 'x', \"x\"q\" is not valid JSON" },
        .{ .source = "x\\q", .message = "Unexpected token 'x', \"x\\q\" is not valid JSON" },
    };
    for (invalid_cases) |case| {
        roots[8] = try createJsonTestString(&runtime, case.source);
        try std.testing.expectError(error.InvalidJsonCloneValue, jsonDecodeBuiltin(&runtime, roots[8]));
        const message = runtime.takeException();
        try expectUtf16String(&runtime, message, case.message);
    }
}

test "AOT JSONエラー文言は孤立サロゲートをUTF-16で保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 2;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createString(&.{ 0xd83d, 0xde00 });
    try std.testing.expectError(error.InvalidJsonCloneValue, jsonDecodeBuiltin(&runtime, roots[0]));
    const message = runtime.takeException();

    var expected: std.ArrayList(u16) = .empty;
    defer expected.deinit(runtime.allocator);
    try appendAsciiUnits(&expected, runtime.allocator, "Unexpected token '");
    try expected.append(runtime.allocator, 0xd83d);
    try appendAsciiUnits(&expected, runtime.allocator, "', \"");
    try expected.appendSlice(runtime.allocator, &.{ 0xd83d, 0xde00 });
    try appendAsciiUnits(&expected, runtime.allocator, "\" is not valid JSON");
    try std.testing.expectEqualSlices(u16, expected.items, message.object().?.payload.utf16_string);
}

test "AOT JSONデコードは深い配列と辞書を明示スタックで処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    // Keep collections frequent enough to exercise the parser's root slice,
    // while avoiding a collection for every single nested container.
    runtime.next_collection = 128;
    const depth: usize = 100_000;
    var roots = [_]Value{ .{}, .{} };
    var root_frame = RootFrame{};
    runtime.pushRoots(&root_frame, &roots, roots.len);
    defer runtime.popRoots(&root_frame);

    var array_source: std.ArrayList(u8) = .empty;
    defer array_source.deinit(runtime.allocator);
    try array_source.appendNTimes(runtime.allocator, '[', depth);
    try array_source.append(runtime.allocator, '0');
    try array_source.appendNTimes(runtime.allocator, ']', depth);
    roots[0] = try createJsonTestString(&runtime, array_source.items);
    roots[1] = try jsonDecodeBuiltin(&runtime, roots[0]);
    var array_current = roots[1];
    for (0..depth) |_| {
        try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(array_current.tag)));
        const items = array_current.object().?.payload.array.items;
        try std.testing.expectEqual(@as(usize, 1), items.len);
        array_current = items[0];
    }
    try std.testing.expectEqual(Tag.number, @as(Tag, @enumFromInt(array_current.tag)));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(array_current.payload)));

    var dictionary_source: std.ArrayList(u8) = .empty;
    defer dictionary_source.deinit(runtime.allocator);
    try dictionary_source.ensureTotalCapacity(runtime.allocator, depth * 5 + 1);
    for (0..depth) |_| try dictionary_source.appendSlice(runtime.allocator, "{\"a\":");
    try dictionary_source.append(runtime.allocator, '0');
    try dictionary_source.appendNTimes(runtime.allocator, '}', depth);
    roots[0] = try createJsonTestString(&runtime, dictionary_source.items);
    roots[1] = try jsonDecodeBuiltin(&runtime, roots[0]);
    var dictionary_current = roots[1];
    for (0..depth) |_| {
        try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(dictionary_current.tag)));
        dictionary_current = jsonTestDictionaryGet(dictionary_current, &.{'a'});
    }
    try std.testing.expectEqual(Tag.number, @as(Tag, @enumFromInt(dictionary_current.tag)));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(dictionary_current.payload)));
}

test "AOT JSONデコードのフレーム数は文字列内の括弧を除外する" {
    try std.testing.expectEqual(@as(usize, 2), jsonAotContainerCount(&.{ '[', '{', '"', '[', '{', '"', '}', ']' }));
    try std.testing.expectEqual(@as(usize, 1), jsonAotContainerCount(&.{ '[', '"', '\\', '"', '[', '"', ']' }));
}

fn expectUtf16String(runtime: *Runtime, value: Value, expected: []const u8) !void {
    const actual = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(actual);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
    defer runtime.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, actual);
}

fn createJsonTestString(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

fn jsonTestDictionaryGet(value: Value, key: []const u16) Value {
    return dictionaryProperty(value, key);
}

fn valueUtf16Alloc(runtime: *Runtime, value: Value) anyerror![]u16 {
    if (value.tag == @intFromEnum(Tag.utf16_string)) return runtime.allocator.dupe(u16, value.object().?.payload.utf16_string);
    if (value.tag == @intFromEnum(Tag.function)) return functionStringUtf16Alloc(runtime, value.object().?.payload.function.name);
    const utf8 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => try runtime.allocator.dupe(u8, "undefined"),
        .null_value => try runtime.allocator.dupe(u8, "null"),
        .boolean => try runtime.allocator.dupe(u8, if (value.payload == 0) "false" else "true"),
        .number => try numberString(runtime.allocator, @bitCast(value.payload)),
        .static_utf8_string => try runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => unreachable,
        .bigint => try value.object().?.payload.bigint.toString(runtime.allocator, 10),
        .array => return arrayUtf16Alloc(runtime, value.object().?),
        .dictionary, .iterator => try runtime.allocator.dupe(u8, "[object Object]"),
        .function => unreachable,
        .binding_cell => unreachable,
    };
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

fn functionStringUtf16Alloc(runtime: *Runtime, name: []const u8) ![]u16 {
    const utf8 = try std.fmt.allocPrint(runtime.allocator, "function {s}() {{ [native code] }}", .{name});
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

fn arrayUtf16Alloc(runtime: *Runtime, object: *Object) anyerror![]u16 {
    for (runtime.stringifying_arrays.items) |active| if (active == object) return runtime.allocator.alloc(u16, 0);
    try runtime.stringifying_arrays.append(runtime.allocator, object);
    defer _ = runtime.stringifying_arrays.pop();
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (object.payload.array.items, 0..) |item, index| {
        if (index > 0) try output.append(runtime.allocator, ',');
        if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
        const units = try valueUtf16Alloc(runtime, item);
        defer runtime.allocator.free(units);
        try output.appendSlice(runtime.allocator, units);
    }
    return output.toOwnedSlice(runtime.allocator);
}

fn valueToPrimitive(runtime: *Runtime, value: Value) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .array => blk: {
            const units = try arrayUtf16Alloc(runtime, value.object().?);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        .dictionary, .iterator => staticStringValue("[object Object]"),
        .function => blk: {
            const units = try functionStringUtf16Alloc(runtime, value.object().?.payload.function.name);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        else => value,
    };
}

fn stringEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.eql(u16, left_units, right_units);
}

fn stringOrder(runtime: *Runtime, left: Value, right: Value) !std.math.Order {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.order(u16, left_units, right_units);
}

fn strictEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean => (left.payload != 0) == (right.payload != 0),
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk !std.math.isNan(left_number) and !std.math.isNan(right_number) and left_number == right_number;
        },
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .static_utf8_string, .utf16_string => unreachable,
        .array, .dictionary, .iterator, .function => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

/// Array.prototype.includes uses SameValueZero: NaN matches NaN and signed
/// zeroes compare equal, while objects retain reference identity.
fn sameValueZero(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk (std.math.isNan(left_number) and std.math.isNan(right_number)) or left_number == right_number;
        },
        else => strictEqual(runtime, left, right),
    };
}

fn abstractEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if ((isString(left) and isString(right)) or left.tag == right.tag) return strictEqual(runtime, left, right);
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .undefined and right_tag == .null_value) or (left_tag == .null_value and right_tag == .undefined)) return true;
    if (isObject(left) and isObject(right)) return false;
    if (left_tag == .boolean) return abstractEqual(runtime, numberValue(if (left.payload == 0) 0 else 1), right);
    if (right_tag == .boolean) return abstractEqual(runtime, left, numberValue(if (right.payload == 0) 0 else 1));
    if (left_tag == .array or left_tag == .dictionary or left_tag == .iterator or left_tag == .function) return abstractEqual(runtime, try valueToPrimitive(runtime, left), right);
    if (right_tag == .array or right_tag == .dictionary or right_tag == .iterator or right_tag == .function) return abstractEqual(runtime, left, try valueToPrimitive(runtime, right));
    if (left_tag == .number and isString(right)) return @as(f64, @bitCast(left.payload)) == try valueToNumberRuntime(runtime, right);
    if (isString(left) and right_tag == .number) return try valueToNumberRuntime(runtime, left) == @as(f64, @bitCast(right.payload));
    if (left_tag == .bigint and isString(right)) return bigIntEqualsString(runtime, left.object().?.payload.bigint, right);
    if (isString(left) and right_tag == .bigint) return bigIntEqualsString(runtime, right.object().?.payload.bigint, left);
    if (left_tag == .bigint and right_tag == .number) return bigIntEqualsNumber(runtime, left.object().?.payload.bigint, @bitCast(right.payload));
    if (left_tag == .number and right_tag == .bigint) return bigIntEqualsNumber(runtime, right.object().?.payload.bigint, @bitCast(left.payload));
    return false;
}

fn relationalOrder(runtime: *Runtime, left: Value, right: Value) !?std.math.Order {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0]);
    roots[3] = try valueToPrimitive(runtime, roots[1]);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (isString(left_primitive) and isString(right_primitive)) return @as(?std.math.Order, try stringOrder(runtime, left_primitive, right_primitive));
    const left_tag: Tag = @enumFromInt(left_primitive.tag);
    const right_tag: Tag = @enumFromInt(right_primitive.tag);
    if (left_tag == .bigint and right_tag == .bigint) return @as(?std.math.Order, BigInt.order(left_primitive.object().?.payload.bigint, right_primitive.object().?.payload.bigint));
    if (left_tag == .bigint and isString(right_primitive)) return compareBigIntString(runtime, left_primitive.object().?.payload.bigint, right_primitive);
    if (isString(left_primitive) and right_tag == .bigint) {
        const order = (try compareBigIntString(runtime, right_primitive.object().?.payload.bigint, left_primitive)) orelse return null;
        return invertOrder(order);
    }
    if (left_tag == .bigint) return compareBigIntNumber(runtime, left_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, right_primitive));
    if (right_tag == .bigint) {
        const order = (try compareBigIntNumber(runtime, right_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, left_primitive))) orelse return null;
        return invertOrder(order);
    }
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const right_number = try valueToNumberRuntime(runtime, right_primitive);
    if (std.math.isNan(left_number) or std.math.isNan(right_number)) return null;
    return std.math.order(left_number, right_number);
}

fn compareValues(runtime: *Runtime, operator: Comparison, left: Value, right: Value) !bool {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    return switch (operator) {
        .abstract_equal => abstractEqual(runtime, roots[0], roots[1]),
        .strict_equal => strictEqual(runtime, roots[0], roots[1]),
        .abstract_not_equal => !try abstractEqual(runtime, roots[0], roots[1]),
        .strict_not_equal => !try strictEqual(runtime, roots[0], roots[1]),
        .less, .less_equal, .greater, .greater_equal => blk: {
            const order = (try relationalOrder(runtime, roots[0], roots[1])) orelse break :blk false;
            break :blk switch (operator) {
                .less => order == .lt,
                .less_equal => order != .gt,
                .greater => order == .gt,
                .greater_equal => order != .lt,
                else => unreachable,
            };
        },
    };
}

fn numberString(allocator: std.mem.Allocator, number: f64) ![]u8 {
    return number_mod.toStringAlloc(allocator, number);
}

fn concat(runtime: *Runtime, left: Value, right: Value) !Value {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    const combined = try runtime.allocator.alloc(u16, left_units.len + right_units.len);
    @memcpy(combined[0..left_units.len], left_units);
    @memcpy(combined[left_units.len..], right_units);
    return runtime.ownString(combined);
}

fn bigIntArithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    if (left.tag != @intFromEnum(Tag.bigint) or right.tag != @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const left_bigint = left.object().?.payload.bigint;
    const right_bigint = right.object().?.payload.bigint;
    const result = switch (operator) {
        .add => try left_bigint.add(runtime.allocator, right_bigint),
        .subtract => try left_bigint.sub(runtime.allocator, right_bigint),
        .multiply => try left_bigint.mul(runtime.allocator, right_bigint),
        .divide => try left_bigint.divTrunc(runtime.allocator, right_bigint),
        .remainder => try left_bigint.rem(runtime.allocator, right_bigint),
        .power => blk: {
            if (right_bigint.isNegative()) return error.NegativeBigIntExponent;
            break :blk try left_bigint.pow(runtime.allocator, right_bigint.toU32() catch return error.BigIntExponentTooLarge);
        },
        .integer_divide => return error.CannotConvertBigIntToNumber,
        .bit_and => try left_bigint.bitAnd(runtime.allocator, right_bigint),
        .bit_or => try left_bigint.bitOr(runtime.allocator, right_bigint),
        .bit_xor => try left_bigint.bitXor(runtime.allocator, right_bigint),
    };
    return runtime.ownBigInt(result);
}

fn arithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0]);
    roots[3] = try valueToPrimitive(runtime, roots[1]);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (left_primitive.tag == @intFromEnum(Tag.bigint) or right_primitive.tag == @intFromEnum(Tag.bigint)) {
        return bigIntArithmetic(runtime, operator, left_primitive, right_primitive);
    }
    const left_number = if (operator == .add) try valueToParseFloatRuntime(runtime, left_primitive) else try valueToNumberRuntime(runtime, left_primitive);
    const right_number = if (operator == .add) try valueToParseFloatRuntime(runtime, right_primitive) else try valueToNumberRuntime(runtime, right_primitive);
    const result: f64 = switch (operator) {
        .add => left_number + right_number,
        .subtract => left_number - right_number,
        .multiply => left_number * right_number,
        .divide => left_number / right_number,
        .remainder => @rem(left_number, right_number),
        .power => std.math.pow(f64, left_number, right_number),
        .integer_divide => @floor(left_number / right_number),
        .bit_and => @floatFromInt(toInt32(left_number) & toInt32(right_number)),
        .bit_or => @floatFromInt(toInt32(left_number) | toInt32(right_number)),
        .bit_xor => @floatFromInt(toInt32(left_number) ^ toInt32(right_number)),
    };
    return numberValue(result);
}

fn bigIntEqualsString(runtime: *Runtime, bigint: BigInt, string: Value) !bool {
    var converted = bigIntFromString(runtime, string) catch return false;
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

fn compareBigIntString(runtime: *Runtime, bigint: BigInt, string: Value) !?std.math.Order {
    var converted = bigIntFromString(runtime, string) catch return null;
    defer converted.deinit();
    return BigInt.order(bigint, converted);
}

fn bigIntFromString(runtime: *Runtime, string: Value) !BigInt {
    const units = try valueUtf16Alloc(runtime, string);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| {
        if (unit > 0x7f) return error.InvalidBigInt;
        ascii[index] = @intCast(unit);
    }
    return BigInt.parseString(runtime.allocator, ascii);
}

fn shift(runtime: *Runtime, operator: ShiftOperator, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0]);
    roots[3] = try valueToPrimitive(runtime, roots[1]);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    const left_is_bigint = left_primitive.tag == @intFromEnum(Tag.bigint);
    const right_is_bigint = right_primitive.tag == @intFromEnum(Tag.bigint);
    if (left_is_bigint or right_is_bigint) {
        if (!left_is_bigint or !right_is_bigint) return error.CannotMixBigIntAndNumber;
        if (operator == .right_unsigned) return error.UnsignedShiftOfBigInt;
        const left_bigint = left_primitive.object().?.payload.bigint;
        const amount = right_primitive.object().?.payload.bigint.toI64() catch return error.BigIntShiftTooLarge;
        const magnitude = if (amount < 0) @as(u64, @intCast(-(amount + 1))) + 1 else @as(u64, @intCast(amount));
        const shift_amount: usize = std.math.cast(usize, magnitude) orelse return error.BigIntShiftTooLarge;
        const shift_left = (operator == .left) != (amount < 0);
        const result = if (shift_left)
            try left_bigint.shiftLeft(runtime.allocator, shift_amount)
        else
            try left_bigint.shiftRight(runtime.allocator, shift_amount);
        return runtime.ownBigInt(result);
    }
    const amount: u5 = @truncate(toUint32(try valueToNumberRuntime(runtime, right_primitive)) & 31);
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const shifted: f64 = switch (operator) {
        .left => @floatFromInt(toInt32(left_number) << amount),
        .right => @floatFromInt(toInt32(left_number) >> amount),
        .right_unsigned => @floatFromInt(toUint32(left_number) >> amount),
    };
    return numberValue(shifted);
}

fn bitNot(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0]);
    const primitive = roots[1];
    if (primitive.tag == @intFromEnum(Tag.bigint)) {
        const result = try primitive.object().?.payload.bigint.bitNot(runtime.allocator);
        return runtime.ownBigInt(result);
    }
    return numberValue(@floatFromInt(~toInt32(try valueToNumberRuntime(runtime, primitive))));
}

fn valueTruthy(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => false,
        .boolean => value.payload != 0,
        .number => blk: {
            const number: f64 = @bitCast(value.payload);
            break :blk number != 0 and !std.math.isNan(number);
        },
        .static_utf8_string => staticUtf8(value).len != 0,
        .utf16_string => value.object().?.payload.utf16_string.len != 0,
        .bigint => !value.object().?.payload.bigint.isZero(),
        .array, .dictionary, .iterator, .function => true,
        .binding_cell => valueTruthy(value.object().?.payload.binding_cell),
    };
}

fn toInt32(number: f64) i32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    if (value >= 2147483648.0) value -= 4294967296.0;
    return @intFromFloat(value);
}

fn toUint32(number: f64) u32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    return @intFromFloat(value);
}

fn bigIntEqualsNumber(runtime: *Runtime, bigint: BigInt, number: f64) !bool {
    if (!std.math.isFinite(number) or @trunc(number) != number) return false;
    var converted = try BigInt.fromF64(runtime.allocator, number);
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

fn compareBigIntNumber(runtime: *Runtime, bigint: BigInt, number: f64) !?std.math.Order {
    if (std.math.isNan(number)) return null;
    if (number == std.math.inf(f64)) return .lt;
    if (number == -std.math.inf(f64)) return .gt;
    var integer = try BigInt.fromF64(runtime.allocator, @trunc(number));
    defer integer.deinit();
    const integer_order = BigInt.order(bigint, integer);
    if (integer_order != .eq) return integer_order;
    const fraction = number - @trunc(number);
    if (fraction > 0) return .lt;
    if (fraction < 0) return .gt;
    return .eq;
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn repeatCount(number: f64) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IteratorCountTooLarge;
    return @intFromFloat(@trunc(number));
}

fn sameKey(left: Value, right: Value) bool {
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .static_utf8_string or left_tag == .utf16_string) and
        (right_tag == .static_utf8_string or right_tag == .utf16_string))
    {
        if (left_tag == .static_utf8_string and right_tag == .static_utf8_string) return std.mem.eql(u8, staticUtf8(left), staticUtf8(right));
        if (left_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(left), right.object().?.payload.utf16_string);
        if (right_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(right), left.object().?.payload.utf16_string);
        return std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string);
    }
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean, .number => left.payload == right.payload,
        .static_utf8_string => std.mem.eql(u8, staticUtf8(left), staticUtf8(right)),
        .utf16_string => std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string),
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .array, .dictionary, .iterator, .function => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

fn staticUtf8EqualsUtf16(text: []const u8, units: []const u16) bool {
    var text_index: usize = 0;
    var unit_index: usize = 0;
    while (text_index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[text_index]) catch return false;
        if (text_index + length > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[text_index .. text_index + length]) catch return false;
        text_index += length;
        if (codepoint <= 0xffff) {
            if (unit_index >= units.len or units[unit_index] != @as(u16, @intCast(codepoint))) return false;
            unit_index += 1;
        } else {
            if (unit_index + 1 >= units.len) return false;
            const offset = codepoint - 0x10000;
            if (units[unit_index] != @as(u16, @intCast(0xd800 + (offset >> 10))) or
                units[unit_index + 1] != @as(u16, @intCast(0xdc00 + (offset & 0x3ff)))) return false;
            unit_index += 2;
        }
    }
    return unit_index == units.len;
}

fn staticUtf8(value: Value) []const u8 {
    const pointer: [*:0]const u8 = @ptrFromInt(value.payload);
    return std.mem.span(pointer);
}

extern "c" fn putchar(character: c_int) c_int;

fn writeUtf16(units: []const u16, newline: bool) void {
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
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
        for (encoded[0..length]) |byte| _ = putchar(byte);
    }
    if (newline) _ = putchar('\n');
}

/// Convert a UTF-16 exception message to UTF-8 without rejecting lone
/// surrogates.  JavaScript strings can contain unpaired surrogates, while the
/// process stderr stream is UTF-8; use U+FFFD for an unpaired code unit just
/// as the normal AOT output path does.
fn utf16FailureMessageUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) anyerror![]u8 {
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

fn pendingExceptionMessageUtf8Alloc(runtime: *Runtime) anyerror![]u8 {
    if (!runtime.has_pending_exception) return error.NoPendingException;
    const units = try valueUtf16Alloc(runtime, runtime.pending_exception);
    defer runtime.allocator.free(units);
    return utf16FailureMessageUtf8Alloc(runtime.allocator, units);
}

fn writeBytes(bytes: []const u8, newline: bool) void {
    for (bytes) |byte| _ = putchar(byte);
    if (newline) _ = putchar('\n');
}

fn runtimeFailure(failure: anyerror) noreturn {
    std.debug.print("[実行時エラー] {s}\n", .{@errorName(failure)});
    std.process.exit(1);
}

var active_runtime: ?Runtime = null;

pub export fn lnako_aot_runtime_init() callconv(.c) c_int {
    if (active_runtime == null) active_runtime = .{ .allocator = std.heap.c_allocator, .random_state = initialRandomState() };
    return 0;
}

pub export fn lnako_aot_runtime_deinit() callconv(.c) void {
    if (active_runtime) |*runtime| runtime.deinit();
    active_runtime = null;
}

/// Site-aware display hooks used by generated LLVM.  The hooks are additive;
/// the runtime ABI for existing generated modules remains unchanged.
pub export fn lnako_aot_dispatch_display_begin(site_id: u64) callconv(.c) u64 {
    var ignored_epoch: u64 = 0;
    return lnako_aot_dispatch_display_begin_with_epoch(site_id, &ignored_epoch);
}

/// Begins a direct-display trace and returns the failure epoch observed at the
/// same boundary through `epoch_out`.  The extra out parameter avoids making
/// the call ID carry two independent pieces of state across LLVM IR.
pub export fn lnako_aot_dispatch_display_begin_with_epoch(site_id: u64, epoch_out: *u64) callconv(.c) u64 {
    const runtime = if (active_runtime) |*active| active else {
        epoch_out.* = 0;
        return no_dispatch_call_id;
    };
    epoch_out.* = runtime.failure_epoch;
    return runtime.dispatch_trace.begin("display", 0, "direct-display", site_id);
}

pub export fn lnako_aot_dispatch_result(call_id: u64, site_id: u64, start_epoch: u64) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    runtime.dispatch_trace.result(call_id, "display", 0, "direct-display", site_id, runtime.failure_epoch == start_epoch);
}

pub export fn lnako_aot_push_roots(frame: *RootFrame, values: ?[*]Value, len: usize) callconv(.c) void {
    if (active_runtime) |*runtime| runtime.pushRoots(frame, values, len);
}

pub export fn lnako_aot_pop_roots(frame: *RootFrame) callconv(.c) void {
    if (active_runtime) |*runtime| runtime.popRoots(frame);
}

pub export fn lnako_aot_collect() callconv(.c) usize {
    return if (active_runtime) |*runtime| runtime.collect() else 0;
}

pub export fn lnako_aot_exception_set(value: *const Value) callconv(.c) void {
    if (active_runtime) |*runtime| runtime.setException(value.*);
}

pub export fn lnako_aot_exception_pending() callconv(.c) c_int {
    return if (active_runtime) |runtime| @intFromBool(runtime.has_pending_exception) else 0;
}

pub export fn lnako_aot_exception_take(out: *Value) callconv(.c) void {
    out.* = if (active_runtime) |*runtime| runtime.takeException() else .{};
}

pub export fn lnako_aot_exception_abort() callconv(.c) noreturn {
    if (active_runtime) |*runtime| {
        if (runtime.has_pending_exception) {
            const message = pendingExceptionMessageUtf8Alloc(runtime) catch {
                // The exception is already pending, but formatting it may
                // allocate (for example for an array value).  Never replace
                // this path with an allocator panic or recurse through the
                // exception machinery: retain the established safe fallback.
                runtimeFailure(error.NakoException);
            };
            defer runtime.allocator.free(message);
            std.debug.print("[実行時エラー] {s}\n", .{message});
            std.process.exit(1);
        }
    }
    runtimeFailure(error.NakoException);
}

pub export fn lnako_aot_string_new(out: *Value, units: ?[*]const u16, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (units) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createString(source) catch return;
}

pub export fn lnako_aot_print_utf16(value: *const Value, newline: bool) callconv(.c) void {
    const object = value.object() orelse return;
    if (object.payload != .utf16_string) return;
    writeUtf16(object.payload.utf16_string, newline);
}

pub export fn lnako_aot_print_number(value: *const Value, newline: bool) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    if (value.tag != @intFromEnum(Tag.number)) return;
    const text = numberString(runtime.allocator, @bitCast(value.payload)) catch return;
    defer runtime.allocator.free(text);
    writeBytes(text, newline);
}

pub export fn lnako_aot_bigint_new(out: *Value, source: ?[*]const u8, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const text = if (source) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createBigInt(text) catch return;
}

pub export fn lnako_aot_print_bigint(value: *const Value, newline: bool) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    const object = value.object() orelse return;
    if (object.payload != .bigint) return;
    const text = object.payload.bigint.toString(runtime.allocator, 10) catch return;
    defer runtime.allocator.free(text);
    writeBytes(text, newline);
}

pub export fn lnako_aot_print_collection(value: *const Value, newline: bool) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    if (value.tag != @intFromEnum(Tag.array) and value.tag != @intFromEnum(Tag.dictionary)) return;
    const units = valueUtf16Alloc(runtime, value.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(units);
    writeUtf16(units, newline);
}

pub export fn lnako_aot_bigint_truthy(value: *const Value) callconv(.c) c_int {
    const object = value.object() orelse return 0;
    if (object.payload != .bigint) return 0;
    return @intFromBool(!object.payload.bigint.isZero());
}

pub export fn lnako_aot_arithmetic(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(Arithmetic, opcode) orelse {
        runtime.setFailure(error.InvalidArithmeticOperator);
        return;
    };
    out.* = arithmetic(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_compare(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(Comparison, opcode) orelse {
        runtime.setFailure(error.InvalidComparison);
        return;
    };
    out.* = .{
        .tag = @intFromEnum(Tag.boolean),
        .payload = @intFromBool(compareValues(runtime, operator, left.*, right.*) catch |failure| {
            runtime.setFailure(failure);
            return;
        }),
    };
}

pub export fn lnako_aot_shift(out: *Value, left: *const Value, right: *const Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(ShiftOperator, opcode) orelse {
        runtime.setFailure(error.InvalidShiftOperator);
        return;
    };
    out.* = shift(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_concat(out: *Value, left: *const Value, right: *const Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    out.* = concat(runtime, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_increment(target: *Value, amount: *const Value) callconv(.c) void {
    const runtime = if (active_runtime) |*active| active else return;
    target.* = incrementValue(runtime, target.*, amount.*);
}

pub export fn lnako_aot_array_new(out: *Value, values: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createArray(source) catch return;
}

pub export fn lnako_aot_dictionary_new(out: *Value, values: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createDictionary(source) catch return;
}

pub export fn lnako_aot_index_get(out: *Value, container: *const Value, key: *const Value) callconv(.c) void {
    const container_value = container.*;
    const key_value = key.*;
    out.* = if (active_runtime) |*runtime| runtime.indexGet(container_value, key_value) else .{};
}

pub export fn lnako_aot_index_set(container: *const Value, key: *const Value, value: *const Value) callconv(.c) c_int {
    const runtime = if (active_runtime) |*active| active else return -1;
    if (container.tag == @intFromEnum(Tag.undefined) or container.tag == @intFromEnum(Tag.null_value)) {
        runtime.setIndexAssignmentFailure(container.*, key.*);
        return -1;
    }
    runtime.indexSet(container.*, key.*, value.*) catch return -1;
    return 0;
}

pub export fn lnako_aot_destructure_get(out: *Value, source: *const Value, index: usize) callconv(.c) void {
    out.* = if (active_runtime) |*runtime| runtime.destructureGet(source.*, index) else .{};
}

pub export fn lnako_aot_iterator_new(out: *Value, values: ?[*]const Value, len: usize, is_range: bool, direction: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createIterator(source, is_range, direction) catch |failure| runtimeFailure(failure);
}

pub export fn lnako_aot_iterator_has_next(iterator: *const Value) callconv(.c) c_int {
    return if (active_runtime) |*runtime| @intFromBool(runtime.iteratorHasNext(iterator.*)) else 0;
}

pub export fn lnako_aot_iterator_next(out: *Value, iterator: *const Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value) callconv(.c) void {
    out.* = if (active_runtime) |*runtime| runtime.iteratorNext(iterator.*, repeat_target, value_target, key_target, range_target) else .{};
}

pub export fn lnako_aot_binding_cell_new(out: *Value, initial: ?*const Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    out.* = runtime.createBindingCell(if (initial) |value| value.* else .{}) catch |failure| runtimeFailure(failure);
}

pub export fn lnako_aot_binding_cell_value(cell: *Value) callconv(.c) *Value {
    if (cell.tag != @intFromEnum(Tag.binding_cell)) runtimeFailure(error.InvalidBindingCell);
    const object = cell.object() orelse runtimeFailure(error.InvalidBindingCell);
    if (object.payload != .binding_cell) runtimeFailure(error.InvalidBindingCell);
    return &object.payload.binding_cell;
}

pub export fn lnako_aot_function_new(out: *Value, callback: FunctionCallback, arity: usize, captures: ?[*]const Value, capture_count: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const source = if (captures) |pointer| pointer[0..capture_count] else if (capture_count == 0) &.{} else runtimeFailure(error.InvalidCaptures);
    for (source) |capture| if (capture.tag != @intFromEnum(Tag.binding_cell)) runtimeFailure(error.InvalidBindingCell);
    out.* = runtime.createFunction(callback, arity, source) catch |failure| runtimeFailure(failure);
}

/// Named variant used by LLVM-generated functions. The original ABI remains
/// available for embedders and unit tests that intentionally create an
/// anonymous native function.
pub export fn lnako_aot_function_new_named(
    out: *Value,
    callback: FunctionCallback,
    arity: usize,
    name: ?[*]const u8,
    name_len: usize,
    captures: ?[*]const Value,
    capture_count: usize,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*value| value else return;
    const function_name = if (name) |pointer| pointer[0..name_len] else if (name_len == 0) &.{} else runtimeFailure(error.InvalidFunctionName);
    const source = if (captures) |pointer| pointer[0..capture_count] else if (capture_count == 0) &.{} else runtimeFailure(error.InvalidCaptures);
    for (source) |capture| if (capture.tag != @intFromEnum(Tag.binding_cell)) runtimeFailure(error.InvalidBindingCell);
    out.* = runtime.createNamedFunction(callback, arity, function_name, source) catch |failure| runtimeFailure(failure);
}

pub export fn lnako_aot_function_capture(out: *Value, context: *anyopaque, index: usize) callconv(.c) void {
    const object: *Object = @ptrCast(@alignCast(context));
    if (object.payload != .function or index >= object.payload.function.captures.len) runtimeFailure(error.InvalidClosureCapture);
    out.* = object.payload.function.captures[index];
}

pub export fn lnako_aot_function_call(out: *Value, callable: *const Value, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    if (callable.tag != @intFromEnum(Tag.function)) runtimeFailure(error.NotCallable);
    const object = callable.object() orelse runtimeFailure(error.NotCallable);
    if (object.payload != .function) runtimeFailure(error.NotCallable);
    const function = object.payload.function;
    if (arguments == null and len != 0) runtimeFailure(error.InvalidArguments);
    var padded: ?[]Value = null;
    defer if (padded) |values| runtime.allocator.free(values);
    var call_arguments = arguments;
    if (len < function.arity) {
        const values = runtime.allocator.alloc(Value, function.arity) catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        padded = values;
        if (arguments) |source| @memcpy(values[0..len], source[0..len]);
        values[len] = runtime.systemContext() catch |failure| {
            runtime.setFailure(failure);
            return;
        };
        @memset(values[len + 1 ..], .{});
        call_arguments = values.ptr;
    }
    function.callback(out, @ptrCast(object), call_arguments, function.arity);
}

/// Dedicated ABI for the two commands that update the system `対象` value.
/// The target is explicit so a local variable named 対象 can never shadow the
/// command's side effect in generated LLVM.
pub export fn lnako_aot_cut(out: *Value, target: *Value, arguments: ?[*]const Value, len: usize, mode: u8) callconv(.c) void {
    lnako_aot_cut_site(out, target, arguments, len, mode, 0);
}

pub export fn lnako_aot_cut_site(out: *Value, target: *Value, arguments: ?[*]const Value, len: usize, mode: u8, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command: aot_builtin.Command = if (mode == 0) .cut else .cut_range;
    const opcode = @intFromEnum(command);
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "cut", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "cut", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const required: usize = if (mode == 0) 2 else if (mode == 1) 3 else 0;
    if (required == 0 or len < required) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = arguments.?;
    const result = cutBuiltin(runtime, values[0], values[1], if (mode == 1) values[2] else null, mode == 1) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    // cutBuiltin roots both values until this point; assign only after both
    // allocations and all delayed property accesses have succeeded.
    out.* = result.result;
    target.* = result.remainder;
    success = runtime.failure_epoch == start_epoch;
}

pub export fn lnako_aot_builtin_call(out: *Value, arguments: ?[*]const Value, len: usize, opcode: u16) callconv(.c) void {
    lnako_aot_builtin_call_site(out, arguments, len, opcode, 0);
}

pub export fn lnako_aot_builtin_call_site(out: *Value, arguments: ?[*]const Value, len: usize, opcode: u16, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "builtin", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "builtin", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "builtin", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "builtin", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    if (len == 0 and command != .empty_array and command != .empty_dictionary and command != .sum_parsed and command != .sequential_add and command != .concat_join and command != .json_decode and command != .math_random and command != .datetime_now and command != .datetime_system_time and command != .datetime_system_time_milliseconds and command != .datetime_today and command != .datetime_tomorrow and command != .datetime_yesterday and command != .datetime_current_year and command != .datetime_next_year and command != .datetime_last_year and command != .datetime_current_month and command != .datetime_next_month and command != .datetime_previous_month and command != .caniuse_browsers) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const value = if (len > 0) arguments.?[0] else Value{};
    switch (command) {
        .regexp_match, .regexp_extract, .regexp_replace, .regexp_split => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .json_encode, .json_encode_pretty => {
            out.* = jsonEncodeBuiltin(runtime, value, command == .json_encode_pretty) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .json_decode => {
            out.* = jsonDecodeBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .math_sin, .math_cos, .math_tan, .math_arcsin, .math_arccos, .math_arctan, .math_atan2, .math_coordinate_angle, .math_rad2deg, .math_deg2rad, .math_sign, .math_abs, .math_exp, .math_hypot, .math_log, .math_logn, .math_frac, .math_integer, .math_sqrt, .math_round, .math_decimal_ceil, .math_decimal_floor, .math_decimal_round, .math_ceil, .math_floor, .math_random, .math_random_range => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = mathBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .datetime_now, .datetime_system_time, .datetime_system_time_milliseconds, .datetime_today, .datetime_tomorrow, .datetime_yesterday, .datetime_current_year, .datetime_next_year, .datetime_last_year, .datetime_current_month, .datetime_next_month, .datetime_previous_month => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = datetimeBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .caniuse_browsers => {
            out.* = caniuseBrowsersBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .to_string => {
            const units = valueUtf16Alloc(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(units);
            out.* = runtime.createString(units) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .type_of => out.* = typeNameValue(value),
        .to_int => {
            out.* = numberValue(parseIntBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .to_float => {
            out.* = numberValue(parseFloatBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .is_nan => {
            const number = valueToNumberRuntime(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(std.math.isNan(number)) };
        },
        .is_number_nan => {
            const is_nan = value.tag == @intFromEnum(Tag.number) and std.math.isNan(@as(f64, @bitCast(value.payload)));
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(is_nan) };
        },
        .radix16, .radix, .radix2, .radix2_display => {
            if (command == .radix and len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const radix_value = if (command == .radix) arguments.?[1] else numberValue(if (command == .radix16) 16 else 2);
            const result = radixBuiltin(runtime, value, radix_value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            if (command == .radix2_display) {
                writeUtf16(result.object().?.payload.utf16_string, true);
            } else out.* = result;
        },
        .rgb => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = rgbBuiltin(runtime, arguments.?[0..3]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .bit_or, .bit_and, .bit_xor => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: Arithmetic = switch (command) {
                .bit_or => .bit_or,
                .bit_and => .bit_and,
                .bit_xor => .bit_xor,
                else => unreachable,
            };
            out.* = arithmetic(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .bit_not => {
            out.* = bitNot(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .shift_left, .shift_right, .shift_right_unsigned => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: ShiftOperator = switch (command) {
                .shift_left => .left,
                .shift_right => .right,
                .shift_right_unsigned => .right_unsigned,
                else => unreachable,
            };
            out.* = shift(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .subtract, .multiply, .divide, .remainder => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: Arithmetic = switch (command) {
                .subtract => .subtract,
                .multiply => .multiply,
                .divide => .divide,
                .remainder => .remainder,
                else => unreachable,
            };
            out.* = arithmetic(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .square => {
            out.* = arithmetic(runtime, .multiply, value, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .power_number => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const left = valueToNumberRuntime(runtime, arguments.?[0]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const right = valueToNumberRuntime(runtime, arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = numberValue(std.math.pow(f64, left, right));
        },
        .is_even, .is_odd => {
            const integer = parseIntBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const expected: f64 = if (command == .is_even) 0 else 1;
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(@rem(integer, 2) == expected) };
        },
        .greater_equal, .less_equal, .less, .greater, .strict_equal, .strict_not_equal => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const comparison: Comparison = switch (command) {
                .greater_equal => .greater_equal,
                .less_equal => .less_equal,
                .less => .less,
                .greater => .greater,
                .strict_equal => .strict_equal,
                .strict_not_equal => .strict_not_equal,
                else => unreachable,
            };
            const result = compareValues(runtime, comparison, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
        },
        .in_range => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const lower = compareValues(runtime, .greater_equal, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const upper = compareValues(runtime, .less_equal, arguments.?[0], arguments.?[2]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(lower and upper) };
        },
        .maximum, .minimum => {
            var result = valueToNumberRuntime(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            var has_nan = std.math.isNan(result);
            for (arguments.?[1..len]) |argument| {
                const number = valueToNumberRuntime(runtime, argument) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
                if (std.math.isNan(number)) {
                    has_nan = true;
                } else if (!has_nan) {
                    result = if (command == .maximum) @max(result, number) else @min(result, number);
                }
            }
            out.* = numberValue(if (has_nan) std.math.nan(f64) else result);
        },
        .clamp => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const number = valueToNumberRuntime(runtime, arguments.?[0]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const minimum = valueToNumberRuntime(runtime, arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const maximum = valueToNumberRuntime(runtime, arguments.?[2]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = numberValue(@min(@max(number, minimum), maximum));
        },
        .logical_or => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (valueTruthy(arguments.?[0])) arguments.?[0] else arguments.?[1];
        },
        .logical_and => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (valueTruthy(arguments.?[0])) arguments.?[1] else arguments.?[0];
        },
        .logical_not => out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(!valueTruthy(value)) },
        .range => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = rangeBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .empty_array => {
            out.* = runtime.createArray(&.{}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .empty_dictionary => {
            out.* = runtime.createDictionary(&.{}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_keys, .hash_keys => {
            if (len < 1) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = dictionaryKeysBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .hash_values => {
            if (len < 1) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = dictionaryValuesBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_remove, .hash_remove => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = dictionaryRemoveBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_has, .hash_has => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const found = dictionaryHasBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(found) };
        },
        .truth_label => {
            out.* = runtime.createString(if (valueTruthy(value)) &.{0x771f} else &.{0x507d}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .repeat_multiply => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = repeatMultiplyBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .unicode_length => {
            const units = valueUtf16Alloc(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(units);
            out.* = numberValue(@floatFromInt(codePointCount(units)));
        },
        .codepoint_find => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = numberValue(@floatFromInt(codePointFindBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            }));
        },
        .string_starts, .string_ends => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = stringBoundaryBuiltin(runtime, arguments.?[0], arguments.?[1], command == .string_starts) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .element_count => {
            out.* = numberValue(@floatFromInt(elementCountBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            }));
        },
        .array_join, .array_join_only => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            const separator: Value = if (len > 1) arguments.?[1] else .{};
            out.* = arrayJoinBuiltin(runtime, source, separator, command == .array_join_only) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .array_search => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            const needle: Value = if (len > 1) arguments.?[1] else .{};
            out.* = numberValue(arraySearchBuiltin(runtime, source, needle) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .array_sort, .array_numeric_convert, .array_numeric_sort, .array_reverse => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            out.* = arrayOrderingBuiltin(runtime, command, source) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .array_insert, .array_insert_many, .array_cut, .array_take, .array_pop, .array_push, .array_clone, .array_range_copy, .reference, .array_add, .array_maximum, .array_minimum, .array_sum, .array_swap, .array_sequence, .array_fill => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = arrayMutationBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .table_pickup, .table_exact_pickup, .table_search, .table_column_count, .table_row_count, .table_column, .table_transpose, .table_rotate, .table_unique, .table_insert_column, .table_delete_column, .table_column_sum, .table_regexp_search, .table_regexp_pickup => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = tableBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .add_parsed => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = addParsedBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .sum_parsed => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = sumParsedBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .sequential_add => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = sequentialAddBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .chr => {
            out.* = chrBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .asc => {
            out.* = ascBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .string_insert, .string_search => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            if (command == .string_insert) {
                out.* = stringInsertBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            } else {
                out.* = numberValue(stringSearchBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                });
            }
        },
        .append, .append_line => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = appendBuiltin(runtime, arguments.?[0], arguments.?[1], command == .append_line) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .concat_join => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = joinBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .explode => {
            out.* = explodeBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .refrain, .occurrence_count => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            if (command == .refrain) {
                out.* = refrainBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            } else {
                out.* = numberValue(@floatFromInt(occurrenceCountBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                }));
            }
        },
        .occurrence => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const found = occurrenceBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(found) };
        },
        // LLVM lowers these side-effecting commands through lnako_aot_cut,
        // which receives the mandatory global 対象 pointer.  Keep the generic
        // dispatcher explicit so an accidental ABI mismatch fails safely.
        .cut, .cut_range => runtime.setFailure(error.CutRequiresTarget),
        .substring_mid, .substring_left, .substring_right => {
            const required: usize = if (command == .substring_mid) 3 else 2;
            if (len < required) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = substringBuiltin(runtime, command, arguments.?[0..required]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .split_all, .split_first, .string_remove => {
            const required: usize = if (command == .string_remove) 3 else 2;
            if (len < required) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (command == .string_remove)
                stringRemoveBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                }
            else
                splitBuiltin(runtime, arguments.?[0], arguments.?[1], command == .split_first) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
        },
        .trim_both, .trim_right, .trim_left => {
            out.* = trimBuiltin(runtime, value, command != .trim_right, command != .trim_left) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .replace_all, .replace_first => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = replaceBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2], command == .replace_all) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .uppercase, .lowercase => {
            out.* = unicodeCaseBuiltin(runtime, value, command == .uppercase) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .hiragana, .katakana => {
            out.* = kanaOffsetBuiltin(runtime, value, command == .katakana) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .ascii_full_width, .ascii_half_width, .ascii_symbol_full_width, .ascii_symbol_half_width => {
            const to_full = command == .ascii_full_width or command == .ascii_symbol_full_width;
            const symbols = command == .ascii_symbol_full_width or command == .ascii_symbol_half_width;
            out.* = asciiWidthBuiltin(runtime, value, to_full, symbols) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .katakana_full_width, .katakana_half_width => {
            out.* = kanaWidthBuiltin(runtime, value, command == .katakana_full_width) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .full_width, .half_width => {
            out.* = widthBuiltin(runtime, value, command == .full_width) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .currency_format => {
            out.* = currencyBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .zero_pad, .space_pad => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = padBuiltin(runtime, arguments.?[0], arguments.?[1], if (command == .zero_pad) '0' else ' ') catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .hiragana_predicate, .katakana_predicate, .digit_predicate, .number_sequence_predicate => {
            out.* = stringPredicateBuiltin(runtime, value, command) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
    }
    success = runtime.failure_epoch == start_epoch;
}

fn typeNameValue(value: Value) Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => staticStringValue("undefined"),
        .null_value, .array, .dictionary, .iterator => staticStringValue("object"),
        .boolean => staticStringValue("boolean"),
        .number => staticStringValue("number"),
        .static_utf8_string, .utf16_string => staticStringValue("string"),
        .bigint => staticStringValue("bigint"),
        .function => staticStringValue("function"),
        .binding_cell => typeNameValue(value.object().?.payload.binding_cell),
    };
}

fn parseIntBuiltin(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return number_mod.parseIntPrefix(units, null);
}

fn parseFloatBuiltin(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk try number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

fn mathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const a: Value = if (arguments.len > 0) arguments[0] else .{};
    const b: Value = if (arguments.len > 1) arguments[1] else .{};
    return switch (command) {
        .math_sin => numberValue(@sin(try valueToNumberRuntime(runtime, a))),
        .math_cos => numberValue(@cos(try valueToNumberRuntime(runtime, a))),
        .math_tan => numberValue(@tan(try valueToNumberRuntime(runtime, a))),
        .math_arcsin => numberValue(std.math.asin(try valueToNumberRuntime(runtime, a))),
        .math_arccos => numberValue(std.math.acos(try valueToNumberRuntime(runtime, a))),
        .math_arctan => numberValue(std.math.atan(try valueToNumberRuntime(runtime, a))),
        .math_atan2 => numberValue(std.math.atan2(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_coordinate_angle => numberValue(try mathCoordinateAngle(runtime, a)),
        .math_rad2deg => numberValue(try valueToNumberRuntime(runtime, a) / std.math.pi * 180),
        .math_deg2rad => numberValue(try valueToNumberRuntime(runtime, a) / 180 * std.math.pi),
        .math_sign => numberValue(try mathSign(runtime, a)),
        .math_abs => numberValue(@abs(try valueToNumberRuntime(runtime, a))),
        .math_exp => numberValue(@exp(try valueToNumberRuntime(runtime, a))),
        .math_hypot => numberValue(std.math.hypot(try valueToNumberRuntime(runtime, a), try valueToNumberRuntime(runtime, b))),
        .math_log => numberValue(@log(try valueToNumberRuntime(runtime, a))),
        .math_logn => numberValue(try mathLogarithm(runtime, a, b)),
        .math_frac => numberValue(@rem(try valueToNumberRuntime(runtime, a), 1)),
        .math_integer => numberValue(@trunc(try valueToNumberRuntime(runtime, a))),
        .math_sqrt => numberValue(@sqrt(try valueToNumberRuntime(runtime, a))),
        .math_round => numberValue(mathRound(try valueToNumberRuntime(runtime, a))),
        .math_decimal_ceil => numberValue(try mathDecimalRound(runtime, a, b, .ceil)),
        .math_decimal_floor => numberValue(try mathDecimalRound(runtime, a, b, .floor)),
        .math_decimal_round => numberValue(try mathDecimalRound(runtime, a, b, .round)),
        .math_ceil => numberValue(@ceil(try valueToNumberRuntime(runtime, a))),
        .math_floor => numberValue(@floor(try valueToNumberRuntime(runtime, a))),
        .math_random => try mathRandom(runtime, a),
        .math_random_range => try mathRandomRange(runtime, a, b),
        else => error.UnknownCommand,
    };
}

const default_random_seed: u64 = 5573589319906701683;

fn initialRandomState() u64 {
    const environment = std.c.getenv("LNAKO_TEST_RANDOM_SEED") orelse {
        const timestamp: u64 = @bitCast(time(null));
        const mixed = timestamp ^ @intFromPtr(&active_runtime);
        return if (mixed == 0) default_random_seed else mixed;
    };
    const parsed = std.fmt.parseInt(u64, std.mem.span(environment), 10) catch return default_random_seed;
    return if (parsed == 0) default_random_seed else parsed;
}

fn nextRandom(runtime: *Runtime) f64 {
    if (runtime.random_state == 0) runtime.random_state = initialRandomState();
    var value = runtime.random_state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    runtime.random_state = value;
    const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
    return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
}

fn mathRandom(runtime: *Runtime, source: Value) !Value {
    const random = nextRandom(runtime);
    if (source.tag == @intFromEnum(Tag.number)) return numberValue(@floor(random * @as(f64, @bitCast(source.payload))));

    var minimum: Value = .{};
    var maximum: Value = .{};
    switch (@as(Tag, @enumFromInt(source.tag))) {
        .array => {
            const items = source.object().?.payload.array.items;
            minimum = if (items.len > 0) items[0] else .{};
            maximum = if (items.len > 1) items[1] else .{};
        },
        .dictionary => {
            minimum = runtime.indexGet(source, staticStringValue("先頭"));
            maximum = runtime.indexGet(source, staticStringValue("末尾"));
        },
        else => return .{},
    }
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}

fn mathRandomRange(runtime: *Runtime, minimum: Value, maximum: Value) !Value {
    const random = nextRandom(runtime);
    const lower = try valueToNumberRuntime(runtime, minimum);
    const upper = try valueToNumberRuntime(runtime, maximum);
    return numberValue(@floor(random * (upper - lower + 1)) + lower);
}

fn caniuseBrowsersBuiltin(runtime: *Runtime) !Value {
    if (runtime.caniuse_browsers.tag != @intFromEnum(Tag.undefined)) return runtime.caniuse_browsers;

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    for (caniuse_browsers) |browser| {
        roots[1] = try runtime.createArray(&.{});
        for (browser.versions) |version| {
            const value = try runtimeUtf8String(runtime, version);
            try roots[1].object().?.payload.array.append(runtime.allocator, value);
        }
        roots[2] = try runtimeUtf8String(runtime, browser.key);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[2], roots[1]);
    }
    runtime.caniuse_browsers = roots[0];
    return roots[0];
}

const CaniuseBrowser = struct { key: []const u8, versions: []const []const u8 };

// This is the generated v3.7.24 browsers.mjs snapshot. The AOT runtime owns
// its copy so normal execution never loads the JavaScript caniuse plugin.
const caniuse_browsers = [_]CaniuseBrowser{
    .{ .key = "and_chr", .versions = &.{"145"} },
    .{ .key = "and_ff", .versions = &.{"147"} },
    .{ .key = "and_qq", .versions = &.{"14.9"} },
    .{ .key = "and_uc", .versions = &.{"15.5"} },
    .{ .key = "android", .versions = &.{"145"} },
    .{ .key = "chrome", .versions = &.{ "145", "144", "143", "142", "139", "133", "131", "125", "112", "109" } },
    .{ .key = "edge", .versions = &.{ "145", "144", "143", "142" } },
    .{ .key = "firefox", .versions = &.{ "147", "146", "145", "140" } },
    .{ .key = "ios_saf", .versions = &.{ "26.3", "26.2", "26.1", "18.5-18.7", "16.6-16.7" } },
    .{ .key = "kaios", .versions = &.{ "3.0-3.1", "2.5" } },
    .{ .key = "node", .versions = &.{ "25.1.0", "24.11.0", "22.21.0" } },
    .{ .key = "op_mini", .versions = &.{"all"} },
    .{ .key = "op_mob", .versions = &.{"80"} },
    .{ .key = "opera", .versions = &.{ "125", "124" } },
    .{ .key = "safari", .versions = &.{ "26.3", "26.2" } },
    .{ .key = "samsung", .versions = &.{ "29", "28" } },
};

const datetime_milliseconds_per_second: i64 = 1000;
const datetime_milliseconds_per_minute: i64 = 60 * datetime_milliseconds_per_second;
const datetime_milliseconds_per_hour: i64 = 60 * datetime_milliseconds_per_minute;
const datetime_milliseconds_per_day: i64 = 24 * datetime_milliseconds_per_hour;
const datetime_tokyo_offset_milliseconds: i64 = 9 * datetime_milliseconds_per_hour;

const AotDateFields = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    weekday: u8,
};

fn datetimeBuiltin(runtime: *Runtime, command: aot_builtin.Command, _: []const Value) !Value {
    const now = currentTimeMilliseconds(runtime);
    return switch (command) {
        .datetime_now => datetimeTimeString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_system_time => numberValue(@floor(@as(f64, @floatFromInt(now)) / datetime_milliseconds_per_second)),
        .datetime_system_time_milliseconds => numberValue(@as(f64, @floatFromInt(now))),
        .datetime_today => datetimeDateString(runtime, datetimeFieldsFromEpoch(now)),
        .datetime_tomorrow => datetimeDateString(runtime, datetimeFieldsFromEpoch(now + datetime_milliseconds_per_day)),
        .datetime_yesterday => datetimeDateString(runtime, datetimeFieldsFromEpoch(now - datetime_milliseconds_per_day)),
        .datetime_current_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year))),
        .datetime_next_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year + 1))),
        .datetime_last_year => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).year - 1))),
        .datetime_current_month => numberValue(@as(f64, @floatFromInt(datetimeFieldsFromEpoch(now).month))),
        .datetime_next_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month, 12) + 1))),
        .datetime_previous_month => numberValue(@as(f64, @floatFromInt(@mod(datetimeFieldsFromEpoch(now).month + 10, 12) + 1))),
        else => error.UnknownCommand,
    };
}

fn currentTimeMilliseconds(runtime: *Runtime) i64 {
    if (runtime.clock_milliseconds) |value| return value;
    if (std.c.getenv("LNAKO_TEST_NOW_MS")) |environment| {
        return std.fmt.parseInt(i64, std.mem.span(environment), 10) catch hostWallClockMilliseconds();
    }
    return hostWallClockMilliseconds();
}

fn hostWallClockMilliseconds() i64 {
    const seconds = time(null);
    return std.math.mul(i64, seconds, datetime_milliseconds_per_second) catch if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn datetimeFieldsFromEpoch(milliseconds: i64) AotDateFields {
    const local = milliseconds + datetime_tokyo_offset_milliseconds;
    const days = @divFloor(local, datetime_milliseconds_per_day);
    const within_day = @mod(local, datetime_milliseconds_per_day);
    const civil = datetimeCivilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @divTrunc(within_day, datetime_milliseconds_per_hour),
        .minute = @divTrunc(@mod(within_day, datetime_milliseconds_per_hour), datetime_milliseconds_per_minute),
        .second = @divTrunc(@mod(within_day, datetime_milliseconds_per_minute), datetime_milliseconds_per_second),
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

fn datetimeDateString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{d}/{:02}/{:02}", .{ fields.year, @as(u64, @intCast(fields.month)), @as(u64, @intCast(fields.day)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

fn datetimeTimeString(runtime: *Runtime, fields: AotDateFields) !Value {
    const text = try std.fmt.allocPrint(runtime.allocator, "{:02}:{:02}:{:02}", .{ @as(u64, @intCast(fields.hour)), @as(u64, @intCast(fields.minute)), @as(u64, @intCast(fields.second)) });
    defer runtime.allocator.free(text);
    return runtimeUtf8String(runtime, text);
}

fn runtimeUtf8String(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

fn datetimeCivilFromDays(days_input: i64) struct { year: i64, month: i64, day: i64 } {
    const days = days_input + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

fn mathCoordinateAngle(runtime: *Runtime, source: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return std.math.nan(f64);
    const items = source.object().?.payload.array.items;
    const x = try valueToNumberRuntime(runtime, if (items.len > 0) items[0] else .{});
    const y = try valueToNumberRuntime(runtime, if (items.len > 1) items[1] else .{});
    return std.math.atan2(y, x) / std.math.pi * 180;
}

fn mathParseFloat(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .bigint => value.object().?.payload.bigint.toF64(),
        else => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk number_mod.parseFloatPrefix(runtime.allocator, units);
        },
    };
}

fn mathSign(runtime: *Runtime, source: Value) !f64 {
    const parsed = try mathParseFloat(runtime, source);
    if (parsed == 0) return 0;
    const coerced = try valueToNumberRuntime(runtime, source);
    return if (coerced > 0) 1 else -1;
}

fn mathLogarithm(runtime: *Runtime, base_value: Value, source_value: Value) !f64 {
    const base = try valueToNumberRuntime(runtime, base_value);
    const source = try valueToNumberRuntime(runtime, source_value);
    if (base == 2) return std.math.log2e * @log(source);
    if (base == 10) return std.math.log10e * @log(source);
    return @log(source) / @log(base);
}

const MathDecimalMode = enum { ceil, floor, round };

fn mathDecimalRound(runtime: *Runtime, source: Value, digits_value: Value, mode: MathDecimalMode) !f64 {
    const value = try valueToNumberRuntime(runtime, source);
    const digits = try valueToNumberRuntime(runtime, digits_value);
    const base = std.math.pow(f64, 10, digits);
    const scaled = value * base;
    const rounded = switch (mode) {
        .ceil => @ceil(scaled),
        .floor => @floor(scaled),
        .round => mathRound(scaled),
    };
    return rounded / base;
}

fn mathRound(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const result = @floor(value + 0.5);
    if (result == 0 and value < 0) return -0.0;
    return result;
}

fn radixBuiltin(runtime: *Runtime, value: Value, radix_value: Value) !Value {
    const number = try parseIntBuiltin(runtime, value);
    const radix_number: f64 = if (radix_value.tag == @intFromEnum(Tag.undefined)) 10 else try valueToNumberRuntime(runtime, radix_value);
    const truncated = @trunc(radix_number);
    if (!std.math.isFinite(radix_number) or truncated < 2 or truncated > 36) return error.InvalidRadix;
    const text = try number_mod.integerToRadixAlloc(runtime.allocator, number, @intFromFloat(truncated));
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

fn rgbBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    var components: [3]f64 = undefined;
    for (0..3) |index| components[index] = try parseIntBuiltin(runtime, arguments[index]);
    const text = try number_mod.rgbAlloc(runtime.allocator, components);
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

fn rangeBuiltin(runtime: *Runtime, first: Value, last: Value) !Value {
    var roots = [_]Value{ first, last, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createString(&.{ 0x5148, 0x982d });
    roots[3] = try runtime.createString(&.{ 0x672b, 0x5c3e });
    roots[4] = try runtime.createDictionary(&.{ roots[2], roots[0], roots[3], roots[1] });
    return roots[4];
}

fn repeatMultiplyBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
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

fn codePointCount(units: []const u16) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (count += 1) index += codePointLength(units, index);
    return count;
}

fn codePointLength(units: []const u16, index: usize) usize {
    return if (index + 1 < units.len and units[index] >= 0xd800 and units[index] <= 0xdbff and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) 2 else 1;
}

/// Fast path for the common string/string form of `何文字目`.  Both
/// operands are already strings, so allocating one UTF-16 buffer per value
/// is enough.  The window width is measured in Array.from elements rather
/// than UTF-16 units; this is important for a lone high surrogate not to
/// match the prefix of a supplementary pair.
fn codePointFindStringBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    if (source_units.len == 0) return 0;

    const needle_count = codePointCount(needle_units);
    var end: usize = 0;
    var initial: usize = 0;
    while (initial < needle_count and end < source_units.len) : (initial += 1) end += codePointLength(source_units, end);

    var start: usize = 0;
    var scalar_index: usize = 0;
    while (start < source_units.len) : (scalar_index += 1) {
        if (std.mem.eql(u16, source_units[start..end], needle_units)) return scalar_index + 1;
        start += codePointLength(source_units, start);
        if (end < source_units.len) end += codePointLength(source_units, end);
    }
    return 0;
}

const search_element_limit: usize = 1_000_000;

/// `何文字目` uses `Array.from(value)` and then compares joined windows.  A
/// single concatenated string is not sufficient: a match may start only at
/// an Array.from element boundary (for example, `['AB', 'C']` must not match
/// `BC`).  Keep each element as owned UTF-16 while searching so no temporary
/// GC value needs to remain rooted between allocations.
const SearchElements = struct {
    runtime: *Runtime,
    items: std.ArrayList([]u16) = .empty,

    fn deinit(self: *SearchElements) void {
        for (self.items.items) |units| if (units.len != 0) self.runtime.allocator.free(units);
        self.items.deinit(self.runtime.allocator);
        self.* = undefined;
    }

    fn appendEmpty(self: *SearchElements) !void {
        try self.items.append(self.runtime.allocator, &.{});
    }

    fn appendOwned(self: *SearchElements, units: []u16) !void {
        errdefer if (units.len != 0) self.runtime.allocator.free(units);
        try self.items.append(self.runtime.allocator, units);
    }

    fn appendValue(self: *SearchElements, value: Value) !void {
        const tag: Tag = @enumFromInt(value.tag);
        switch (tag) {
            .undefined, .null_value => try self.appendEmpty(),
            .binding_cell => try self.appendValue(value.object().?.payload.binding_cell),
            else => try self.appendOwned(try valueUtf16Alloc(self.runtime, value)),
        }
    }
};

fn searchArrayFromLength(runtime: *Runtime, value: Value) !usize {
    const number = try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(search_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@trunc(number));
}

fn appendStringSearchElements(elements: *SearchElements, value: Value) !void {
    const units = try valueUtf16Alloc(elements.runtime, value);
    defer elements.runtime.allocator.free(units);
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        try elements.appendOwned(try elements.runtime.allocator.dupe(u16, units[index .. index + length]));
        index += length;
    }
}

fn appendDictionarySearchElements(elements: *SearchElements, value: Value) !void {
    // TODO: aot-array-from-dictionary-lazy-length
    // Array.from({length: huge, 0: "hit"}) can observe index 0 before any
    // later index is read.  The bounded eager representation is retained for
    // OOM safety until the AOT value model grows a lazy array-like view.
    const length = searchArrayFromLength(elements.runtime, dictionaryProperty(value, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) catch |failure| return failure;
    var key_buffer: [32]u16 = undefined;
    for (0..length) |index| {
        const key = searchIndexKey(&key_buffer, index);
        try elements.appendValue(dictionaryProperty(value, key));
    }
}

fn searchIndexKey(buffer: *[32]u16, index: usize) []const u16 {
    var utf8: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "{d}", .{index}) catch unreachable;
    const length = std.unicode.utf8ToUtf16Le(buffer, text) catch unreachable;
    return buffer[0..length];
}

fn appendSearchElements(runtime: *Runtime, value: Value) !SearchElements {
    const tag: Tag = @enumFromInt(value.tag);
    if (tag == .null_value) {
        runtime.setFailureText("object null is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }
    if (tag == .undefined) {
        runtime.setFailureText("undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }

    var elements = SearchElements{ .runtime = runtime };
    errdefer elements.deinit();
    switch (tag) {
        .static_utf8_string, .utf16_string => try appendStringSearchElements(&elements, value),
        .array => for (value.object().?.payload.array.items) |item| try elements.appendValue(item),
        .dictionary => try appendDictionarySearchElements(&elements, value),
        // The official generated function wrapper is not an iterable or
        // array-like value for this command, so Array.from(function) is []
        // regardless of the source function's language-level arity.
        .function => {},
        else => {},
    }
    return elements;
}

fn joinedSearchElementsEqual(source: SearchElements, start: usize, count: usize, needle: SearchElements) bool {
    const source_end = start + count;
    var source_index = start;
    var source_offset: usize = 0;
    var needle_index: usize = 0;
    var needle_offset: usize = 0;
    while (true) {
        while (source_index < source_end and source_offset == source.items.items[source_index].len) {
            source_index += 1;
            source_offset = 0;
        }
        while (needle_index < needle.items.items.len and needle_offset == needle.items.items[needle_index].len) {
            needle_index += 1;
            needle_offset = 0;
        }
        const source_done = source_index == source_end;
        const needle_done = needle_index == needle.items.items.len;
        if (source_done or needle_done) return source_done and needle_done;
        if (source.items.items[source_index][source_offset] != needle.items.items[needle_index][needle_offset]) return false;
        source_offset += 1;
        needle_offset += 1;
    }
}

fn codePointFindBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    var roots = [_]Value{ source, needle };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    if (isString(roots[0]) and isString(roots[1])) return codePointFindStringBuiltin(runtime, roots[0], roots[1]);

    var source_elements = try appendSearchElements(runtime, roots[0]);
    defer source_elements.deinit();
    var needle_elements = try appendSearchElements(runtime, roots[1]);
    defer needle_elements.deinit();
    for (source_elements.items.items, 0..) |_, index| {
        const count = @min(needle_elements.items.items.len, source_elements.items.items.len - index);
        if (joinedSearchElementsEqual(source_elements, index, count, needle_elements)) return index + 1;
    }
    return 0;
}

fn stringBoundaryBuiltin(runtime: *Runtime, source: Value, needle: Value, starts: bool) !Value {
    try requireStringReceiver(source, starts);
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    const matches = if (starts)
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[0..needle_units.len], needle_units)
    else
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[source_units.len - needle_units.len ..], needle_units);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(matches) };
}

fn requireStringReceiver(value: Value, starts: bool) !void {
    if (isString(value)) return;
    const tag: Tag = @enumFromInt(value.tag);
    if (starts) return switch (tag) {
        .null_value => error.StartsWithNullReceiver,
        .undefined => error.StartsWithUndefinedReceiver,
        else => error.StartsWithReceiverExpected,
    };
    return switch (tag) {
        .null_value => error.EndsWithNullReceiver,
        .undefined => error.EndsWithUndefinedReceiver,
        else => error.EndsWithReceiverExpected,
    };
}

fn elementCountBuiltin(runtime: *Runtime, value: Value) !usize {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .array => value.object().?.payload.array.items.len,
        .dictionary => value.object().?.payload.dictionary.items.len,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk units.len;
        },
        .function, .iterator => 0,
        .binding_cell => elementCountBuiltin(runtime, value.object().?.payload.binding_cell),
        else => 1,
    };
}

fn addParsedBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.bigint) and roots[1].tag != @intFromEnum(Tag.bigint)) {
        return numberValue(try parseFloatBuiltin(runtime, roots[0]) + try parseFloatBuiltin(runtime, roots[1]));
    }
    roots[2] = try toBigIntBuiltin(runtime, roots[0]);
    roots[3] = try toBigIntBuiltin(runtime, roots[1]);
    return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
}

fn sumParsedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len > 0 and arguments[0].tag == @intFromEnum(Tag.array)) {
        var total: f64 = 0;
        for (arguments[0].object().?.payload.array.items) |item| {
            const number = try parseFloatBuiltin(runtime, item);
            if (!std.math.isNan(number)) total += number;
        }
        return numberValue(total);
    }
    var has_bigint = false;
    for (arguments) |argument| if (argument.tag == @intFromEnum(Tag.bigint)) {
        has_bigint = true;
        break;
    };
    if (!has_bigint) {
        var total: f64 = 0;
        for (arguments) |argument| total += try parseFloatBuiltin(runtime, argument);
        return numberValue(total);
    }
    var roots = [_]Value{ try runtime.createBigInt("0n"), .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments) |argument| {
        roots[1] = try toBigIntBuiltin(runtime, argument);
        roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[1]);
    }
    return roots[0];
}

fn toBigIntBuiltin(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0]);
    const primitive = roots[1];
    return switch (@as(Tag, @enumFromInt(primitive.tag))) {
        .bigint => primitive,
        .number => runtime.ownBigInt(try BigInt.fromF64(runtime.allocator, @bitCast(primitive.payload))),
        .static_utf8_string, .utf16_string => blk: {
            const converted = try bigIntFromString(runtime, primitive);
            break :blk try runtime.ownBigInt(converted);
        },
        .boolean => runtime.ownBigInt(try BigInt.init(runtime.allocator, @as(u1, @intCast(primitive.payload)))),
        .null_value => error.CannotConvertNullToBigInt,
        .undefined => error.CannotConvertUndefinedToBigInt,
        else => error.InvalidBigIntConversion,
    };
}

fn jsAdd(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0]);
    roots[3] = try valueToPrimitive(runtime, roots[1]);
    if (isString(roots[2]) or isString(roots[3])) return concat(runtime, roots[2], roots[3]);
    if (roots[2].tag == @intFromEnum(Tag.bigint) or roots[3].tag == @intFromEnum(Tag.bigint)) return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
    return numberValue(try valueToNumberRuntime(runtime, roots[2]) + try valueToNumberRuntime(runtime, roots[3]));
}

const CutResult = struct { result: Value, remainder: Value };

/// `切取` and `範囲切取` deliberately use two different lengths for a
/// delimiter: `indexOf` stringifies the argument, but the following
/// `substring(index + delimiter.length)` reads the original value's property.
/// Keep this helper in the AOT runtime so the generated executable does not
/// need a JavaScript compatibility layer.
fn cutLengthProperty(runtime: *Runtime, value: Value) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => error.CutUndefinedDelimiterLength,
        .null_value => error.CutNullDelimiterLength,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk numberValue(@floatFromInt(units.len));
        },
        .array => numberValue(@floatFromInt(value.object().?.payload.array.items.len)),
        .function => numberValue(@floatFromInt(value.object().?.payload.function.arity)),
        .dictionary => dictionaryLengthValue(value),
        else => .{},
    };
}

fn dictionaryLengthValue(value: Value) Value {
    const entries = value.object().?.payload.dictionary.items;
    for (entries) |entry| {
        const is_length = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => std.mem.eql(u8, staticUtf8(entry.key), "length"),
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, &.{ 'l', 'e', 'n', 'g', 't', 'h' }),
            else => false,
        };
        if (is_length) return entry.value;
    }
    return .{};
}

fn cutEndIndex(runtime: *Runtime, match_index: usize, delimiter: Value, source_length: usize) !usize {
    const length = try cutLengthProperty(runtime, delimiter);
    const sum = try jsAdd(runtime, numberValue(@floatFromInt(match_index)), length);
    const number = try valueToNumberRuntime(runtime, sum);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(source_length))) return source_length;
    return @intFromFloat(@trunc(number));
}

fn cutBuiltin(runtime: *Runtime, source: Value, first: Value, last: ?Value, range: bool) !CutResult {
    var roots = [_]Value{ source, first, last orelse .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, roots[0]);
    defer runtime.allocator.free(source_units);
    const first_units = try valueUtf16Alloc(runtime, roots[1]);
    defer runtime.allocator.free(first_units);
    const first_index = indexOfUnitsBuiltin(source_units, first_units, 0);
    if (first_index == null) {
        if (range) {
            roots[3] = try runtime.createString(&.{});
            roots[4] = try runtime.createString(source_units);
        } else {
            roots[3] = try runtime.createString(source_units);
            roots[4] = try runtime.createString(&.{});
        }
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const first_start = first_index.?;
    const middle_start = try cutEndIndex(runtime, first_start, roots[1], source_units.len);
    if (!range) {
        roots[3] = try runtime.createString(source_units[0..first_start]);
        roots[4] = try runtime.createString(source_units[middle_start..]);
        return .{ .result = roots[3], .remainder = roots[4] };
    }

    // Delimiter B is converted only after A matched.  In particular, a null
    // or undefined B is harmless when A is absent, matching String#indexOf.
    const last_value = roots[2];
    const last_units = try valueUtf16Alloc(runtime, last_value);
    defer runtime.allocator.free(last_units);
    const prefix = source_units[0..first_start];
    const relative_last = indexOfUnitsBuiltin(source_units[middle_start..], last_units, 0);
    if (relative_last == null) {
        roots[3] = try runtime.createString(source_units[middle_start..]);
        roots[4] = try runtime.createString(prefix);
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const last_relative = relative_last.?;
    const last_end = middle_start + try cutEndIndex(runtime, last_relative, last_value, source_units.len - middle_start);
    roots[3] = try runtime.createString(source_units[middle_start .. middle_start + last_relative]);
    roots[4] = try runtime.createString(prefix);
    if (last_end < source_units.len) {
        const combined_len = std.math.add(usize, prefix.len, source_units.len - last_end) catch return error.StringTooLarge;
        const combined = try runtime.allocator.alloc(u16, combined_len);
        @memcpy(combined[0..prefix.len], prefix);
        @memcpy(combined[prefix.len..], source_units[last_end..]);
        roots[4] = try runtime.ownString(combined);
    }
    return .{ .result = roots[3], .remainder = roots[4] };
}

fn sequentialAddBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return runtime.systemContext();
    if (arguments.len == 1) return arguments[0];
    var roots = [_]Value{ arguments[1], .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments[2..]) |argument| roots[0] = try jsAdd(runtime, roots[0], argument);
    roots[1] = try jsAdd(runtime, roots[0], arguments[0]);
    return roots[1];
}

fn chrBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, value));
    var roots = [_]Value{ value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        roots[2] = try codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, item));
        try roots[1].object().?.payload.array.append(runtime.allocator, roots[2]);
    }
    return roots[1];
}

fn codePointStringBuiltin(runtime: *Runtime, number: f64) !Value {
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > 0x10ffff) {
        const number_text = try number_mod.toStringAlloc(runtime.allocator, number);
        defer runtime.allocator.free(number_text);
        const message = try std.fmt.allocPrint(runtime.allocator, "Invalid code point {s}", .{number_text});
        defer runtime.allocator.free(message);
        runtime.setFailureText(message);
        return error.NakoException;
    }
    const codepoint: u21 = @intFromFloat(number);
    if (codepoint <= 0xffff) return runtime.createString(&.{@intCast(codepoint)});
    const offset: u32 = codepoint - 0x10000;
    return runtime.createString(&.{ @intCast(0xd800 + (offset >> 10)), @intCast(0xdc00 + (offset & 0x3ff)) });
}

fn ascBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, value)));
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        try roots[1].object().?.payload.array.append(runtime.allocator, numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, item))));
    }
    return roots[1];
}

fn firstCodePointBuiltin(runtime: *Runtime, value: Value) !u21 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    if (units.len == 0) return 0;
    if (units[0] >= 0xd800 and units[0] <= 0xdbff and units.len > 1 and units[1] >= 0xdc00 and units[1] <= 0xdfff) {
        return @intCast(0x10000 + ((@as(u32, units[0]) - 0xd800) << 10) + (@as(u32, units[1]) - 0xdc00));
    }
    return @intCast(units[0]);
}

fn stringInsertBuiltin(runtime: *Runtime, source_value: Value, position_value: Value, addition_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const addition = try valueUtf16Alloc(runtime, addition_value);
    defer runtime.allocator.free(addition);
    var position = try valueToNumberRuntime(runtime, position_value);
    if (position <= 0) position = 1;
    const scalar_index = stringCollectionIndex(position - 1, codePointCount(source));
    const unit_index = codePointOffsetBuiltin(source, scalar_index);
    const output = try runtime.allocator.alloc(u16, source.len + addition.len);
    @memcpy(output[0..unit_index], source[0..unit_index]);
    @memcpy(output[unit_index .. unit_index + addition.len], addition);
    @memcpy(output[unit_index + addition.len ..], source[unit_index..]);
    return runtime.ownString(output);
}

fn stringSearchBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, needle_value: Value) !f64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var start = try valueToNumberRuntime(runtime, start_value);
    if (start <= 0) start = 1;
    var index = start - 1;
    const source_count = codePointCount(source);
    const needle_count = codePointCount(needle);
    while (index < @as(f64, @floatFromInt(source_count))) : (index += 1) {
        const scalar_index = stringCollectionIndex(index, source_count);
        const unit_start = codePointOffsetBuiltin(source, scalar_index);
        const unit_end = codePointOffsetBuiltin(source, @min(source_count, scalar_index +| needle_count));
        if (std.mem.eql(u16, source[unit_start..unit_end], needle)) return index + 1;
    }
    return 0;
}

fn codePointOffsetBuiltin(units: []const u16, target: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len and count < target) : (count += 1) index += codePointLength(units, index);
    return index;
}

fn stringCollectionIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(@trunc(number));
}

fn appendBuiltin(runtime: *Runtime, source: Value, addition: Value, newline: bool) !Value {
    if (source.tag == @intFromEnum(Tag.array)) {
        try source.object().?.payload.array.append(runtime.allocator, addition);
        return source;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const addition_units = try valueUtf16Alloc(runtime, addition);
    defer runtime.allocator.free(addition_units);
    const extra: usize = @intFromBool(newline);
    const base_length = std.math.add(usize, source_units.len, addition_units.len) catch return error.StringTooLarge;
    const length = std.math.add(usize, base_length, extra) catch return error.StringTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    @memcpy(output[0..source_units.len], source_units);
    @memcpy(output[source_units.len .. source_units.len + addition_units.len], addition_units);
    if (newline) output[output.len - 1] = '\n';
    return runtime.ownString(output);
}

fn joinBuiltin(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    errdefer units.deinit(runtime.allocator);
    for (values) |value| switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => {},
        else => {
            const part = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(part);
            try units.appendSlice(runtime.allocator, part);
        },
    };
    return runtime.ownString(try units.toOwnedSlice(runtime.allocator));
}

/// `配列結合` is intentionally separate from `連結`.  The former delegates
/// to JavaScript's Array.join when its first value is an array, while the
/// official plugin also accepts other values by splitting their String form
/// at LF before joining.  `配列只結合` is the same operation with an empty
/// separator.
fn arrayJoinBuiltin(runtime: *Runtime, source: Value, separator: Value, only: bool) !Value {
    var separator_units: []const u16 = &.{};
    var allocated_separator: ?[]u16 = null;
    defer if (allocated_separator) |units| runtime.allocator.free(units);
    if (!only) {
        allocated_separator = try valueUtf16Alloc(runtime, separator);
        separator_units = allocated_separator.?;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (source.tag == @intFromEnum(Tag.array)) {
        const object = source.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        for (object.payload.array.items, 0..) |item, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, separator_units);
            if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
            const item_units = try valueUtf16Alloc(runtime, item);
            defer runtime.allocator.free(item_units);
            try output.appendSlice(runtime.allocator, item_units);
        }
    } else {
        const source_units = try valueUtf16Alloc(runtime, source);
        defer runtime.allocator.free(source_units);
        // String(a).split("\n").join(separator) preserves empty pieces at
        // both ends, including the trailing piece after a final LF.
        var start: usize = 0;
        var first = true;
        for (source_units, 0..) |unit, index| {
            if (unit != '\n') continue;
            if (!first) try output.appendSlice(runtime.allocator, separator_units);
            try output.appendSlice(runtime.allocator, source_units[start..index]);
            start = index + 1;
            first = false;
        }
        if (!first) try output.appendSlice(runtime.allocator, separator_units);
        try output.appendSlice(runtime.allocator, source_units[start..]);
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

fn arraySearchBuiltin(runtime: *Runtime, source: Value, needle: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return -1;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    for (object.payload.array.items, 0..) |item, index| {
        if (try strictEqual(runtime, item, needle)) return @floatFromInt(index);
    }
    return -1;
}

fn arrayOrderingBuiltin(runtime: *Runtime, command: aot_builtin.Command, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    switch (command) {
        .array_reverse => {
            std.mem.reverse(Value, items.items);
            return source;
        },
        .array_numeric_convert => {
            var source_root = source;
            var roots = RootFrame{};
            runtime.pushRoots(&roots, @ptrCast(&source_root), 1);
            defer runtime.popRoots(&roots);
            for (items.items) |*item| item.* = numberValue(try parseFloatBuiltin(runtime, item.*));
            return source_root;
        },
        .array_sort, .array_numeric_sort => return try stableArraySort(runtime, source, command == .array_numeric_sort),
        else => unreachable,
    }
}

fn stableArraySort(runtime: *Runtime, source: Value, numeric: bool) !Value {
    const items = &source.object().?.payload.array;
    if (items.items.len < 2) return source;

    // Keep the live array unchanged until the merge completes. The contiguous
    // root storage protects both the source object and every temporary value
    // while ToString/parseFloat allocate and may trigger collection.
    const allocator = runtime.allocator;
    const root_count = std.math.add(usize, items.items.len, 1) catch return error.ArrayTooLarge;
    const root_values = try allocator.alloc(Value, root_count);
    defer allocator.free(root_values);
    root_values[0] = source;
    std.mem.copyForwards(Value, root_values[1..], items.items);
    var roots = RootFrame{};
    runtime.pushRoots(&roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&roots);
    const temporary = root_values[1..];

    var width: usize = 1;
    var from_source = true;
    while (width < items.items.len) : (width = std.math.mul(usize, width, 2) catch items.items.len) {
        const input = if (from_source) items.items else temporary;
        const output = if (from_source) temporary else items.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareArraySortValues(runtime, input[left], input[right], numeric);
                if (order == .gt) {
                    output[destination] = input[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) output[destination] = input[left];
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) output[destination] = input[right];
            start = end;
        }
        from_source = !from_source;
    }
    if (!from_source) std.mem.copyForwards(Value, items.items, temporary);
    return source;
}

fn compareArraySortValues(runtime: *Runtime, left: Value, right: Value, numeric: bool) !std.math.Order {
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    if (numeric) {
        const left_number = try parseFloatBuiltin(runtime, left);
        const right_number = try parseFloatBuiltin(runtime, right);
        if (std.math.isNan(left_number) or std.math.isNan(right_number)) return .eq;
        return std.math.order(left_number, right_number);
    }

    const left_text = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_text);
    const right_text = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_text);
    return utf16Order(left_text, right_text);
}

fn utf16Order(left: []const u16, right: []const u16) std.math.Order {
    return std.mem.order(u16, left, right);
}

const ArrayRange = struct { start: usize, count: usize };

fn arrayItems(value: Value) !*std.ArrayList(Value) {
    if (value.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = value.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    return &object.payload.array;
}

/// JavaScript's Array splice uses ToIntegerOrInfinity for the start argument.
/// In particular, strings are converted with Number (not parseInt), NaN and
/// -Infinity become zero, and +Infinity becomes the current array length.
fn spliceIndexRuntime(runtime: *Runtime, value: Value, length: usize) !usize {
    return spliceIndexNumber(try valueToNumberRuntime(runtime, value), length);
}

fn spliceIndexNumber(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == -std.math.inf(f64)) return 0;
    if (number == std.math.inf(f64)) return length;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

fn spliceCountRuntime(runtime: *Runtime, value: Value, maximum: usize) !usize {
    return spliceCountNumber(try valueToNumberRuntime(runtime, value), maximum);
}

fn spliceCountNumber(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

fn dictionaryProperty(value: Value, key: []const u16) Value {
    if (value.tag != @intFromEnum(Tag.dictionary)) return .{};
    const object = value.object() orelse return .{};
    if (object.payload != .dictionary) return .{};
    for (object.payload.dictionary.items) |entry| {
        const matches = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => blk: {
                var units: [64]u16 = undefined;
                const utf8 = staticUtf8(entry.key);
                if (utf8.len > units.len) break :blk false;
                const converted = std.unicode.utf8ToUtf16Le(&units, utf8) catch break :blk false;
                break :blk std.mem.eql(u16, units[0..converted], key);
            },
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, key),
            else => false,
        };
        if (matches) return entry.value;
    }
    return .{};
}

fn aotCanonicalArrayIndex(value: Value) ?usize {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number) or number < 0 or number > 4_294_967_294 or @trunc(number) != number) return null;
            const index: usize = @intFromFloat(number);
            return if (index <= 4_294_967_294) index else null;
        },
        .bigint => {
            const integer = value.object().?.payload.bigint.toI64() catch return null;
            if (integer < 0) return null;
            const index = std.math.cast(usize, integer) orelse return null;
            return if (index <= 4_294_967_294) index else null;
        },
        else => {},
    }
    const units: []const u16 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => {
            const text = staticUtf8(value);
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
            var number: usize = 0;
            for (text) |unit| {
                if (unit < '0' or unit > '9') return null;
                number = std.math.mul(usize, number, 10) catch return null;
                number = std.math.add(usize, number, unit - '0') catch return null;
            }
            return if (number <= 4_294_967_294) number else null;
        },
        .utf16_string => value.object().?.payload.utf16_string,
        else => return null,
    };
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        number = std.math.mul(usize, number, 10) catch return null;
        number = std.math.add(usize, number, unit - '0') catch return null;
    }
    return if (number <= 4_294_967_294) number else null;
}

fn aotDictionaryOrder(runtime: *Runtime, entries: []const DictionaryEntry) ![]usize {
    const order = try runtime.allocator.alloc(usize, entries.len);
    for (order, 0..) |*entry, index| entry.* = index;
    std.sort.pdq(usize, order, entries, aotDictionaryOrderBefore);
    return order;
}

fn aotDictionaryOrderBefore(entries: []const DictionaryEntry, left_index: usize, right_index: usize) bool {
    const left = aotCanonicalArrayIndex(entries[left_index].key);
    const right = aotCanonicalArrayIndex(entries[right_index].key);
    return if (left) |left_number| if (right) |right_number| left_number < right_number else true else if (right != null) false else left_index < right_index;
}

fn aotPropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

fn dictionaryKeysBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = roots[0].object().?.payload.dictionary.items;
            const order = try aotDictionaryOrder(runtime, entries);
            defer runtime.allocator.free(order);
            for (order) |index| {
                const units = try valueUtf16Alloc(runtime, entries[index].key);
                defer runtime.allocator.free(units);
                const key = try runtime.createString(units);
                try result.append(runtime.allocator, key);
            }
        },
        .array => {
            const items = roots[0].object().?.payload.array.items;
            for (items, 0..) |_, index| {
                var text: [32]u8 = undefined;
                const encoded = std.fmt.bufPrint(&text, "{d}", .{index}) catch return error.ArrayTooLarge;
                var units: [32]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, encoded) catch return error.ArrayTooLarge;
                const key = try runtime.createString(units[0..unit_len]);
                try result.append(runtime.allocator, key);
            }
        },
        .function => {},
        else => return error.DictionaryKeysReceiver,
    }
    return roots[1];
}

fn dictionaryValuesBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = roots[0].object().?.payload.dictionary.items;
            const order = try aotDictionaryOrder(runtime, entries);
            defer runtime.allocator.free(order);
            for (order) |index| try result.append(runtime.allocator, entries[index].value);
        },
        .array => {
            const items = roots[0].object().?.payload.array.items;
            try result.appendSlice(runtime.allocator, items);
        },
        .function => {},
        else => return error.DictionaryValuesReceiver,
    }
    return roots[1];
}

fn dictionaryRemoveBuiltin(runtime: *Runtime, source: Value, key: Value) !Value {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = &roots[0].object().?.payload.dictionary;
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (entries.items, 0..) |entry, index| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) {
                _ = entries.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthDelete;
            if (aotCanonicalArrayIndex(roots[1])) |index| {
                const items = &roots[0].object().?.payload.array;
                if (index < items.items.len) items.items[index] = .{};
            }
            return roots[0];
        },
        .function => return roots[0],
        else => return error.DictionaryRemoveReceiver,
    }
}

fn dictionaryHasBuiltin(runtime: *Runtime, source: Value, key: Value) !bool {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.payload.dictionary.items) |entry| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) return true;
            return false;
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
            const index = aotCanonicalArrayIndex(roots[1]) orelse return false;
            const items = roots[0].object().?.payload.array.items;
            return index < items.len;
        },
        .function => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            return std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' });
        },
        else => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const receiver_units = try valueUtf16Alloc(runtime, roots[0]);
            defer runtime.allocator.free(receiver_units);
            const key_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, key_units);
            defer runtime.allocator.free(key_utf8);
            const receiver_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, receiver_units);
            defer runtime.allocator.free(receiver_utf8);
            const message = try std.fmt.allocPrint(runtime.allocator, "Cannot use 'in' operator to search for '{s}' in {s}", .{ key_utf8, receiver_utf8 });
            defer runtime.allocator.free(message);
            runtime.setFailureText(message);
            return error.DictionaryHasReceiver;
        },
    }
}

fn stringValuesEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (!isString(left) or !isString(right)) return false;
    return stringEqual(runtime, left, right);
}

fn arrayRange(runtime: *Runtime, index: Value, length: usize) !?ArrayRange {
    // The official implementation checks `typeof i === 'object'` before
    // reading i['先頭'].  Accessing a null value therefore throws, while an
    // array or dictionary without a numeric 先頭 simply falls through to the
    // null return value.
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    const tag: Tag = @enumFromInt(index.tag);
    if (tag != .array and tag != .dictionary) return null;
    const first_value = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first_value.tag != @intFromEnum(Tag.number)) return null;
    const first_number: f64 = @bitCast(first_value.payload);
    const last_value = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    // `last - first + 1` is a JavaScript subtraction expression.  A BigInt
    // on either side would throw instead of silently converting to f64.
    if (last_value.tag == @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const last_number = try valueToNumberRuntime(runtime, last_value);
    const count_number = last_number - first_number + 1;
    return .{
        .start = spliceIndexNumber(first_number, length),
        .count = spliceCountNumber(count_number, length - spliceIndexNumber(first_number, length)),
    };
}

fn spliceArrayBuiltin(runtime: *Runtime, source: Value, start: usize, count: usize) !Value {
    var roots = [_]Value{ source, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const items = try arrayItems(roots[0]);
    const old_length = items.items.len;
    const actual = @min(count, old_length - start);
    roots[1] = try runtime.createArray(&.{});
    const removed = try arrayItems(roots[1]);
    try removed.ensureTotalCapacity(runtime.allocator, actual);
    removed.items.len = actual;
    if (actual > 0) @memcpy(removed.items, items.items[start .. start + actual]);
    if (actual > 0) {
        @memmove(items.items[start .. old_length - actual], items.items[start + actual .. old_length]);
        items.items.len = old_length - actual;
    }
    return roots[1];
}

fn insertValuesAssumeCapacity(items: *std.ArrayList(Value), start: usize, values: []const Value) void {
    const old_length = items.items.len;
    _ = items.addManyAtAssumeCapacity(start, values.len);
    @memcpy(items.items[start .. start + values.len], values);
    // Keep this assertion next to the low-level mutation: all callers reserve
    // capacity before entering this function, so OOM cannot leave a partial
    // array update behind.
    std.debug.assert(items.items.len == old_length + values.len);
}

fn arrayInsertBuiltin(runtime: *Runtime, source: Value, index: Value, item: Value) !Value {
    var roots = [_]Value{ source, index, item, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayInsertReceiver;
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    roots[3] = try runtime.createArray(&.{});
    const old_length = items.items.len;
    try items.ensureTotalCapacity(runtime.allocator, std.math.add(usize, old_length, 1) catch return error.ArrayTooLarge);
    insertValuesAssumeCapacity(items, start, roots[2..3]);
    return roots[3];
}

fn arrayInsertManyBuiltin(runtime: *Runtime, source: Value, index: Value, values: Value) !Value {
    var roots = [_]Value{ source, index, values, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array) or roots[2].tag != @intFromEnum(Tag.array)) return error.ArrayInsertManyReceiver;
    const target = try arrayItems(roots[0]);
    const insertion = try arrayItems(roots[2]);
    // The official loop reads b[j] while mutating a.  Copying first is
    // intentional here: for a === b the upstream loop grows forever.  AOT
    // keeps the useful, finite value semantics and documents this safety
    // boundary in COMPATIBILITY_QUIRKS.md.
    const copy = try runtime.allocator.dupe(Value, insertion.items);
    defer runtime.allocator.free(copy);
    const positions = try runtime.allocator.alloc(usize, copy.len);
    defer runtime.allocator.free(positions);
    const old_length = target.items.len;
    for (copy, 0..) |_, offset| {
        // `i + j` is evaluated before splice.  This deliberately preserves
        // JavaScript's string concatenation and BigInt mixed-type errors.
        roots[3] = try jsAdd(runtime, roots[1], numberValue(@floatFromInt(offset)));
        positions[offset] = try spliceIndexRuntime(runtime, roots[3], std.math.add(usize, old_length, offset) catch return error.ArrayTooLarge);
    }
    const final_length = std.math.add(usize, old_length, copy.len) catch return error.ArrayTooLarge;
    try target.ensureTotalCapacity(runtime.allocator, final_length);
    for (positions, 0..) |start, offset| {
        insertValuesAssumeCapacity(target, start, copy[offset .. offset + 1]);
    }
    return roots[0];
}

fn arrayCutBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var roots = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(roots[0]);
        if (roots[1].tag == @intFromEnum(Tag.number)) {
            const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
            roots[2] = try spliceArrayBuiltin(runtime, roots[0], start, 1);
            const removed = try arrayItems(roots[2]);
            return if (removed.items.len == 0) .{} else removed.items[0];
        }
        if (try arrayRange(runtime, roots[1], items.items.len)) |range| {
            return spliceArrayBuiltin(runtime, roots[0], range.start, range.count);
        }
        return .{ .tag = @intFromEnum(Tag.null_value) };
    }
    if (roots[0].tag == @intFromEnum(Tag.dictionary) and isString(roots[1])) {
        const object = roots[0].object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        const entries = &object.payload.dictionary;
        for (entries.items, 0..) |entry, entry_index| {
            if (!try stringValuesEqual(runtime, entry.key, roots[1])) continue;
            if (!valueTruthy(entry.value)) return .{};
            const old = entries.orderedRemove(entry_index);
            return old.value;
        }
        return .{};
    }
    return error.ArrayCutReceiver;
}

fn arrayTakeBuiltin(runtime: *Runtime, source: Value, index: Value, count: Value) !Value {
    var roots = [_]Value{ source, index, count };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayTakeReceiver;
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    const delete_count = try spliceCountRuntime(runtime, roots[2], items.items.len - start);
    return spliceArrayBuiltin(runtime, roots[0], start, delete_count);
}

fn arrayPopBuiltin(_: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPopReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    return object.payload.array.pop() orelse .{};
}

fn arrayPushBuiltin(runtime: *Runtime, source: Value, item: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPushReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    try items.ensureTotalCapacity(runtime.allocator, std.math.add(usize, items.items.len, 1) catch return error.ArrayTooLarge);
    items.appendAssumeCapacity(item);
    return source;
}

fn arrayMutationBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    const index: Value = if (arguments.len > 1) arguments[1] else .{};
    const item: Value = if (arguments.len > 2) arguments[2] else .{};
    return switch (command) {
        .array_insert => arrayInsertBuiltin(runtime, source, index, item),
        .array_insert_many => arrayInsertManyBuiltin(runtime, source, index, item),
        .array_cut => arrayCutBuiltin(runtime, source, index),
        .array_take => arrayTakeBuiltin(runtime, source, index, if (arguments.len > 2) arguments[2] else .{}),
        .array_pop => arrayPopBuiltin(runtime, source),
        .array_push => arrayPushBuiltin(runtime, source, index),
        .array_clone => deepCloneBuiltin(runtime, source),
        .array_range_copy => arrayRangeCopyBuiltin(runtime, source, index),
        .reference => referenceBuiltin(runtime, source, index),
        .array_add => arrayAddBuiltin(runtime, source, index),
        .array_maximum => arrayExtremumBuiltin(runtime, source, true),
        .array_minimum => arrayExtremumBuiltin(runtime, source, false),
        .array_sum => arraySumBuiltin(runtime, source),
        .array_swap => arraySwapBuiltin(runtime, source, index, item),
        .array_sequence => arraySequenceBuiltin(runtime, source, index),
        .array_fill => arrayFillBuiltin(runtime, source, index),
        else => error.UnknownCommand,
    };
}

const table_length_key = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };

/// Read a row property using the same useful subset of JavaScript's
/// `row[column]` semantics used by the official table commands.  In
/// particular, strings expose UTF-16 code units and dictionaries only expose
/// own properties.  Accessing a missing row is deliberately an error: the
/// upstream implementation evaluates `a[i][col]`, so null/undefined rows do
/// not silently produce undefined.
fn tableRowProperty(runtime: *Runtime, row: Value, column: Value) !Value {
    const row_tag: Tag = @enumFromInt(row.tag);
    if (row_tag == .undefined) return error.TableRowMissing;
    if (row_tag == .null_value) return error.TableRowMissing;
    const key_units = try valueUtf16Alloc(runtime, column);
    defer runtime.allocator.free(key_units);
    if (row_tag == .array) {
        const object = row.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(object.payload.array.items.len));
        const index = tablePropertyIndex(key_units) orelse return .{};
        return if (index < object.payload.array.items.len) object.payload.array.items[index] else .{};
    }
    if (row_tag == .dictionary) {
        const object = row.object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        for (object.payload.dictionary.items) |entry| {
            if (try tablePropertyKeyEqual(runtime, entry.key, key_units)) return entry.value;
        }
        return .{};
    }
    if (isString(row)) {
        const units = try valueUtf16Alloc(runtime, row);
        defer runtime.allocator.free(units);
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(units.len));
        const index = tablePropertyIndex(key_units) orelse return .{};
        if (index >= units.len) return .{};
        return try runtime.createString(&.{units[index]});
    }
    if (row_tag == .function and std.mem.eql(u16, key_units, &table_length_key)) {
        // The official compiler exposes Nadesiko functions through a
        // rest-argument wrapper, so Function.length is zero regardless of the
        // language-level arity used by lnako's call dispatcher.
        return numberValue(0);
    }
    // Number, boolean, bigint, etc. have no relevant own indexed properties
    // in this runtime; JavaScript returns undefined here.
    return .{};
}

fn tablePropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

/// Parse only canonical array-index property names.  Number("01") is 1, but
/// JavaScript's property key "01" is not an array index, so using Number here
/// would incorrectly read row[1].
fn tablePropertyIndex(units: []const u16) ?usize {
    if (units.len == 0) return null;
    if (units.len > 1 and units[0] == '0') return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: usize = unit - '0';
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, digit) catch return null;
    }
    // Keep the ECMAScript array-index boundary exact: 2^32 - 1 is not an
    // array index (it is distinct from the length property).
    const max_array_index: usize = @as(usize, std.math.maxInt(u32)) - 1;
    if (result > max_array_index) return null;
    return result;
}

fn tableColumnCountBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, numberValue(1) };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    for (rows.items) |row| {
        const length = try tableRowProperty(runtime, row, staticStringValue("length"));
        if (try compareValues(runtime, .greater, length, roots[1])) roots[1] = length;
    }
    return roots[1];
}

fn tableSearchBuiltin(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    var roots = [_]Value{ source, column, row_value, needle, row_value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        const cell = try tableRowProperty(runtime, roots[5], roots[1]);
        if (try strictEqual(runtime, cell, roots[3])) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

fn tableColumnIterationCount(runtime: *Runtime, value: Value) !usize {
    const number = if (value.tag == @intFromEnum(Tag.bigint))
        value.object().?.payload.bigint.toF64()
    else
        try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(safe_array_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@ceil(number));
}

fn tableTransposeBuiltin(runtime: *Runtime, source: Value, rotate: bool) !Value {
    var roots = [_]Value{ source, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[1] = try tableColumnCountBuiltin(runtime, roots[0]);
    const columns = try tableColumnIterationCount(runtime, roots[1]);
    const cells = std.math.mul(usize, columns, rows.items.len) catch return error.ArraySizeLimitExceeded;
    if (cells > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    try result.ensureTotalCapacity(runtime.allocator, columns);
    for (0..columns) |column| {
        roots[3] = try runtime.createArray(&.{});
        const row_result = try arrayItems(roots[3]);
        try row_result.ensureTotalCapacity(runtime.allocator, rows.items.len);
        for (0..rows.items.len) |offset| {
            const row_index = if (rotate) rows.items.len - offset - 1 else offset;
            roots[4] = try tableRowProperty(runtime, rows.items[row_index], numberValue(@floatFromInt(column)));
            if (!rotate and roots[4].tag == @intFromEnum(Tag.undefined)) roots[4] = staticStringValue("");
            try row_result.append(runtime.allocator, roots[4]);
        }
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

fn tableDictionaryHasKey(runtime: *Runtime, dictionary: Value, key: Value) !bool {
    const entries = &dictionary.object().?.payload.dictionary;
    for (entries.items) |entry| if (try strictEqual(runtime, entry.key, key)) return true;
    return false;
}

fn tableIsObjectPrototypeKey(units: []const u16) bool {
    const keys = [_][]const u8{
        "constructor",
        "__defineGetter__",
        "__defineSetter__",
        "hasOwnProperty",
        "__lookupGetter__",
        "__lookupSetter__",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toString",
        "valueOf",
        "__proto__",
        "toLocaleString",
    };
    for (keys) |key| {
        if (units.len != key.len) continue;
        var matches = true;
        for (units, key) |unit, byte| if (unit != byte) {
            matches = false;
            break;
        };
        if (matches) return true;
    }
    return false;
}

fn tableUniqueBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createDictionary(&.{});
    const result = try arrayItems(roots[2]);
    for (rows.items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(units);
        if (tableIsObjectPrototypeKey(units)) continue;
        roots[5] = try runtime.createString(units);
        if (try tableDictionaryHasKey(runtime, roots[3], roots[5])) continue;
        try roots[3].object().?.payload.dictionary.append(runtime.allocator, .{ .key = roots[5], .value = numberValue(1) });
        try result.append(runtime.allocator, row);
    }
    return roots[2];
}

fn tableInsertColumnBuiltin(runtime: *Runtime, source: Value, column: Value, values: Value) !Value {
    var roots = [_]Value{ source, column, values, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[3] = try runtime.createArray(&.{});
    if (rows.items.len == 0) return roots[3];
    const result = try arrayItems(roots[3]);
    const positive = try compareValues(runtime, .greater, roots[1], numberValue(0));
    for (rows.items, 0..) |row, row_index| {
        roots[4] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[4]);
        const row_tag = @as(Tag, @enumFromInt(row.tag));
        if (row_tag == .array) {
            const row_items = try arrayItems(row);
            const total = std.math.add(usize, row_items.items.len, 1) catch return error.ArraySizeLimitExceeded;
            if (total > safe_array_element_limit) return error.ArraySizeLimitExceeded;
            try new_row.ensureTotalCapacity(runtime.allocator, total);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
                try new_row.appendSlice(runtime.allocator, row_items.items[0..prefix]);
            }
        } else if (isString(row)) {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            try new_row.ensureTotalCapacity(runtime.allocator, 3);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
                roots[5] = try runtime.createString(row_units[0..prefix]);
                try new_row.append(runtime.allocator, roots[5]);
            }
        } else return error.ArrayExpected;
        if (roots[2].tag == @intFromEnum(Tag.array)) {
            const value_items = try arrayItems(roots[2]);
            roots[6] = if (row_index < value_items.items.len) value_items.items[row_index] else .{};
        } else {
            roots[6] = try tableRowProperty(runtime, roots[2], numberValue(@floatFromInt(row_index)));
        }
        try new_row.append(runtime.allocator, roots[6]);
        if (row_tag == .array) {
            const row_items = try arrayItems(row);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
            try new_row.appendSlice(runtime.allocator, row_items.items[suffix..]);
        } else {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
            roots[5] = try runtime.createString(row_units[suffix..]);
            try new_row.append(runtime.allocator, roots[5]);
        }
        try result.append(runtime.allocator, roots[4]);
    }
    return roots[3];
}

fn tableDeleteColumnBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    for (rows.items) |row| {
        const row_items = try arrayItems(row);
        const index = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
        roots[3] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[3]);
        try new_row.ensureTotalCapacity(runtime.allocator, row_items.items.len - @intFromBool(index < row_items.items.len));
        for (row_items.items, 0..) |item, item_index| if (item_index != index) try new_row.append(runtime.allocator, item);
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

fn tableColumnSumBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, numberValue(0), .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for ((try arrayItems(roots[0])).items) |row| {
        roots[3] = try tableRowProperty(runtime, row, roots[1]);
        roots[2] = try jsAdd(runtime, roots[2], roots[3]);
    }
    return roots[2];
}

/// The table regex commands use `new RegExp(s)`, unlike the general regexp
/// commands whose `/pattern/flags` notation is part of their public API.
/// Keep this validation outside the row loop so an invalid pattern fails even
/// for an empty table or an already-out-of-range start row.
fn tableRegexpPatternUnitsAlloc(runtime: *Runtime, pattern: Value) ![]u16 {
    if (pattern.tag == @intFromEnum(Tag.undefined)) return runtime.allocator.alloc(u16, 0);
    return valueUtf16Alloc(runtime, pattern);
}

fn tableRegexpSearchBuiltin(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, row_value, pattern, row_value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[3]);
    defer runtime.allocator.free(pattern_units);
    var compiled = try regexp.RawPattern.init(runtime.allocator, pattern_units, false);
    defer compiled.deinit();
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        roots[6] = try tableRowProperty(runtime, roots[5], roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[6]);
        defer runtime.allocator.free(source_units);
        if (try compiled.matches(source_units)) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

fn tableRegexpPickupBuiltin(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, pattern, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[2]);
    defer runtime.allocator.free(pattern_units);
    var compiled = try regexp.RawPattern.init(runtime.allocator, pattern_units, false);
    defer compiled.deinit();
    roots[3] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[3]);
    for ((try arrayItems(roots[0])).items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(source_units);
        if (!(try compiled.matches(source_units))) continue;
        // Upstream uses row.slice(0): create a new shallow array and retain
        // each element's identity. String.slice(0) returns the same immutable
        // string value; rows without slice fail only after they match.
        if (row.tag == @intFromEnum(Tag.array)) {
            roots[5] = try runtime.createArray(&.{});
            const copy = try arrayItems(roots[5]);
            const row_items = try arrayItems(row);
            try copy.ensureTotalCapacity(runtime.allocator, row_items.items.len);
            try copy.appendSlice(runtime.allocator, row_items.items);
        } else if (isString(row)) {
            roots[5] = row;
        } else return error.ArrayExpected;
        try result.append(runtime.allocator, roots[5]);
    }
    return roots[3];
}

fn incrementTableSearchRow(runtime: *Runtime, row: Value) !Value {
    if (row.tag == @intFromEnum(Tag.bigint)) {
        var one = try BigInt.init(runtime.allocator, 1);
        defer one.deinit();
        return runtime.ownBigInt(try row.object().?.payload.bigint.add(runtime.allocator, one));
    }
    return numberValue(try valueToNumberRuntime(runtime, row) + 1);
}

fn tableBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    switch (command) {
        .table_row_count => return numberValue(@floatFromInt((try arrayItems(source)).items.len)),
        .table_column_count => return tableColumnCountBuiltin(runtime, source),
        .table_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[2] = try runtime.createArray(&.{});
            const result = try arrayItems(roots[2]);
            for ((try arrayItems(roots[0])).items) |row| try result.append(runtime.allocator, try tableRowProperty(runtime, row, roots[1]));
            return roots[2];
        },
        .table_pickup, .table_exact_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], arguments[2], .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[3] = try runtime.createArray(&.{});
            const result = try arrayItems(roots[3]);
            for ((try arrayItems(roots[0])).items) |row| {
                const cell = try tableRowProperty(runtime, row, roots[1]);
                const matches = if (command == .table_exact_pickup)
                    try strictEqual(runtime, cell, roots[2])
                else blk: {
                    const cell_units = try valueUtf16Alloc(runtime, cell);
                    defer runtime.allocator.free(cell_units);
                    const needle_units = try valueUtf16Alloc(runtime, roots[2]);
                    defer runtime.allocator.free(needle_units);
                    break :blk std.mem.indexOf(u16, cell_units, needle_units) != null;
                };
                if (matches) try result.append(runtime.allocator, row);
            }
            return roots[3];
        },
        .table_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableRegexpSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableRegexpPickupBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_transpose, .table_rotate => return tableTransposeBuiltin(runtime, source, command == .table_rotate),
        .table_unique => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableUniqueBuiltin(runtime, source, arguments[1]);
        },
        .table_insert_column => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableInsertColumnBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_delete_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableDeleteColumnBuiltin(runtime, source, arguments[1]);
        },
        .table_column_sum => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableColumnSumBuiltin(runtime, source, arguments[1]);
        },
        else => return error.UnknownCommand,
    }
}

const CloneState = struct {
    active: std.ArrayList(*Object) = .empty,

    fn deinit(self: *CloneState, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
    }
};

/// `配列複製` is the upstream JSON.stringify/JSON.parse operation.  Keep the
/// JSON-specific rules here instead of using the general value copier: NaN and
/// infinities become null, undefined/functions disappear from objects (and
/// become null in arrays), and cycles/BigInt are errors.
fn deepCloneBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag == @intFromEnum(Tag.undefined) or source.tag == @intFromEnum(Tag.function)) return error.InvalidJsonCloneValue;
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    return deepCloneValue(runtime, source, &state);
}

fn deepCloneValue(runtime: *Runtime, source: Value, state: *CloneState) !Value {
    return switch (@as(Tag, @enumFromInt(source.tag))) {
        .undefined, .function => .{},
        .null_value, .boolean => source,
        .number => blk: {
            const number: f64 = @bitCast(source.payload);
            break :blk if (std.math.isFinite(number)) numberValue(if (number == 0) 0 else number) else .{ .tag = @intFromEnum(Tag.null_value) };
        },
        .bigint => error.CannotSerializeBigInt,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, source);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        .array => {
            const object = source.object() orelse return error.InvalidArray;
            if (object.payload != .array) return error.InvalidArray;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createArray(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            const values = object.payload.array.items;
            try roots[0].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
            for (values) |item| {
                var cloned = try deepCloneValue(runtime, item, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
                try roots[0].object().?.payload.array.append(runtime.allocator, cloned);
            }
            return roots[0];
        },
        .dictionary => {
            const object = source.object() orelse return error.InvalidDictionary;
            if (object.payload != .dictionary) return error.InvalidDictionary;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createDictionary(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            for (object.payload.dictionary.items) |entry| {
                const cloned = try deepCloneValue(runtime, entry.value, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) continue;
                try runtime.setDictionary(&roots[0].object().?.payload.dictionary, entry.key, cloned);
            }
            return roots[0];
        },
        .iterator => runtime.createDictionary(&.{}),
        .binding_cell => unreachable,
    };
}

const SliceRange = struct { start: usize, end: usize };

fn sliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    if (number == std.math.inf(f64)) return length;
    if (number == -std.math.inf(f64)) return 0;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

fn directIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

fn bigIntPropertyIndex(value: BigInt, length: usize) ?usize {
    const integer = value.toI64() catch return null;
    if (integer < 0) return null;
    const index = std.math.cast(usize, integer) orelse return null;
    return if (index < length) index else null;
}

fn charAtIndex(number: f64, length: usize) ?usize {
    if (std.math.isNan(number) or number == 0) return if (length > 0) 0 else null;
    if (!std.math.isFinite(number)) return null;
    const integer = @trunc(number);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(length))) return null;
    return @intFromFloat(integer);
}

fn sliceRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const start = sliceIndex(@bitCast(first.payload), length);
    const end_number = try explicitRangeNumber(runtime, last);
    const end = sliceIndex(end_number + 1, length);
    return .{ .start = start, .end = end };
}

fn substringRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const first_number: f64 = @bitCast(first.payload);
    const last_number = try explicitRangeNumber(runtime, last) + 1;
    const normalize = struct {
        fn apply(number: f64, size: usize) usize {
            if (std.math.isNan(number) or number <= 0 or number == -std.math.inf(f64)) return 0;
            if (number == std.math.inf(f64)) return size;
            if (number >= @as(f64, @floatFromInt(size))) return size;
            return @intFromFloat(@trunc(number));
        }
    }.apply;
    var start = normalize(first_number, length);
    var end = normalize(last_number, length);
    if (start > end) std.mem.swap(usize, &start, &end);
    return .{ .start = start, .end = end };
}

fn arrayRangeCopyBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (rooted[0].tag != @intFromEnum(Tag.array)) return error.ArrayRangeCopyReceiver;
    const items = try arrayItems(rooted[0]);
    if (rooted[1].tag == @intFromEnum(Tag.number)) {
        const position = directIndex(@bitCast(rooted[1].payload)) orelse return .{};
        if (position >= items.items.len) return .{};
        const item = items.items[position];
        return switch (@as(Tag, @enumFromInt(item.tag))) {
            .array, .dictionary, .iterator, .null_value => deepCloneBuiltin(runtime, item),
            else => item,
        };
    }
    const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
    if (range.end <= range.start) return runtime.createArray(&.{});
    rooted[2] = try runtime.createArray(&.{});
    const values = items.items[range.start..range.end];
    try rooted[2].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    for (values) |item| {
        var cloned = try deepCloneValue(runtime, item, &state);
        if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
        try rooted[2].object().?.payload.array.append(runtime.allocator, cloned);
    }
    return rooted[2];
}

fn referenceBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (isString(rooted[0])) {
        const units = try valueUtf16Alloc(runtime, rooted[0]);
        defer runtime.allocator.free(units);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = charAtIndex(@bitCast(rooted[1].payload), units.len) orelse return runtime.createString(&.{});
            return runtime.createString(units[position .. position + 1]);
        }
        const range = (try substringRange(runtime, rooted[1], units.len)) orelse return invalidStringRangeBuiltin(runtime, rooted[1]);
        const start = @min(range.start, units.len);
        const end = @min(range.end, units.len);
        return runtime.createString(units[start..end]);
    }
    if (rooted[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(rooted[0]);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = directIndex(@bitCast(rooted[1].payload)) orelse return .{};
            return if (position < items.items.len) items.items[position] else .{};
        }
        if (rooted[1].tag == @intFromEnum(Tag.bigint)) {
            const position = bigIntPropertyIndex(rooted[1].object().?.payload.bigint, items.items.len) orelse return .{};
            return items.items[position];
        }
        if (isString(rooted[1])) return tableRowProperty(runtime, rooted[0], rooted[1]);
        const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
        const start = @min(range.start, items.items.len);
        const end = @min(@max(range.end, start), items.items.len);
        return runtime.createArray(items.items[start..end]);
    }
    if (rooted[0].tag == @intFromEnum(Tag.dictionary)) {
        const key = try valueUtf16Alloc(runtime, rooted[1]);
        defer runtime.allocator.free(key);
        return dictionaryProperty(rooted[0], key);
    }
    return error.IndexableValueExpected;
}

fn invalidStringRangeBuiltin(runtime: *Runtime, index: Value) !Value {
    const encoded = try jsonEncodeBuiltin(runtime, index, false);
    var roots = [_]Value{encoded};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    var message: std.ArrayList(u16) = .empty;
    errdefer message.deinit(runtime.allocator);
    try appendUtf8Units(&message, runtime.allocator, "『参照』で文字列型の範囲指定(");
    if (roots[0].tag == @intFromEnum(Tag.undefined)) {
        try appendAsciiUnits(&message, runtime.allocator, "undefined");
    } else {
        try message.appendSlice(runtime.allocator, roots[0].object().?.payload.utf16_string);
    }
    try appendUtf8Units(&message, runtime.allocator, ")が不正です。");
    runtime.setFailureUnits(message.items);
    return error.InvalidStringRange;
}

fn arrayAddBuiltin(runtime: *Runtime, source: Value, other: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return deepCloneBuiltin(runtime, source);
    const source_items = try arrayItems(source);
    var roots = [_]Value{ source, other, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    const extra: usize = if (roots[1].tag == @intFromEnum(Tag.array)) (try arrayItems(roots[1])).items.len else 1;
    const final_length = std.math.add(usize, source_items.items.len, extra) catch return error.ArrayTooLarge;
    try result.ensureTotalCapacity(runtime.allocator, final_length);
    try result.appendSlice(runtime.allocator, source_items.items);
    if (roots[1].tag == @intFromEnum(Tag.array)) try result.appendSlice(runtime.allocator, (try arrayItems(roots[1])).items) else try result.append(runtime.allocator, roots[1]);
    return roots[2];
}

fn arrayExtremumBuiltin(runtime: *Runtime, source: Value, maximum: bool) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const items = try arrayItems(source);
    if (items.items.len == 0) return error.NonEmptyArrayExpected;
    if (items.items.len == 1) return items.items[0];
    var result = try valueToNumberRuntime(runtime, items.items[0]);
    for (items.items[1..]) |item| {
        const number = try valueToNumberRuntime(runtime, item);
        if (std.math.isNan(number) or std.math.isNan(result)) {
            result = std.math.nan(f64);
        } else if ((maximum and (number > result or (number == result and isNegativeZero(result)))) or
            (!maximum and (number < result or (number == result and isNegativeZero(number)))))
        {
            result = number;
        }
    }
    return numberValue(result);
}

fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

fn arraySumBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    var total: f64 = 0;
    for ((try arrayItems(source)).items) |item| {
        const number = try parseFloatBuiltin(runtime, item);
        if (!std.math.isNan(number)) total += number;
    }
    return numberValue(total);
}

fn arraySwapBuiltin(runtime: *Runtime, source: Value, first_value: Value, second_value: Value) !Value {
    var roots = [_]Value{ source, first_value, second_value };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const first = directIndex(try valueToNumberRuntime(runtime, roots[1])) orelse return error.InvalidArrayIndex;
    const second = directIndex(try valueToNumberRuntime(runtime, roots[2])) orelse return error.InvalidArrayIndex;
    const items = try arrayItems(roots[0]);
    const first_item: Value = if (first < items.items.len) items.items[first] else .{};
    const second_item: Value = if (second < items.items.len) items.items[second] else .{};
    const required_length = std.math.add(usize, @max(first, second), 1) catch return error.ArraySizeLimitExceeded;
    if (required_length > items.items.len and required_length > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    const length = @max(items.items.len, required_length);
    const old_length = items.items.len;
    try items.ensureTotalCapacity(runtime.allocator, length);
    try items.resize(runtime.allocator, length);
    @memset(items.items[old_length..], .{});
    items.items[first] = second_item;
    items.items[second] = first_item;
    return roots[0];
}

fn fillArrayLength(number: f64, maximum: usize) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(maximum))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@floor(number));
}

fn arraySequenceBuiltin(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
    var roots = [_]Value{ first_value, last_value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createBigInt("1n");
    const result_items = try arrayItems(roots[2]);
    var count: usize = 0;
    const lessEqual = struct {
        fn check(rt: *Runtime, left: Value, right: Value) !bool {
            if (left.tag == @intFromEnum(Tag.bigint) and right.tag == @intFromEnum(Tag.bigint)) {
                return BigInt.order(left.object().?.payload.bigint, right.object().?.payload.bigint) != .gt;
            }
            return compareValues(rt, .less_equal, left, right);
        }
    }.check;
    while (try lessEqual(runtime, roots[0], roots[1])) {
        if (count >= safe_array_element_limit) return error.ArraySizeLimitExceeded;
        if (roots[1].tag != @intFromEnum(Tag.bigint) and try valueToNumberRuntime(runtime, roots[1]) == std.math.inf(f64)) return error.ArraySizeLimitExceeded;
        try result_items.append(runtime.allocator, roots[0]);
        if (roots[0].tag == @intFromEnum(Tag.bigint)) {
            roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[3]);
        } else {
            const current_number = try valueToNumberRuntime(runtime, roots[0]);
            const next = numberValue(current_number + 1);
            if (@as(f64, @bitCast(next.payload)) == current_number and try lessEqual(runtime, next, roots[1])) return error.ArraySizeLimitExceeded;
            roots[0] = next;
        }
        count += 1;
    }
    return roots[2];
}

fn arrayFillBuiltin(runtime: *Runtime, value: Value, shape: Value) !Value {
    var roots = [_]Value{ value, shape };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[1].tag == @intFromEnum(Tag.array)) try validateFillDimensions(runtime, roots[1]);
    return arrayFillAtDepth(runtime, roots[0], roots[1], 0);
}

fn validateFillDimensions(runtime: *Runtime, shape: Value) !void {
    const dimensions = try arrayItems(shape);
    var product: usize = 1;
    var total: usize = 1;
    for (dimensions.items) |dimension| {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimension), safe_array_element_limit);
        product = std.math.mul(usize, product, count) catch return error.ArraySizeLimitExceeded;
        total = std.math.add(usize, total, product) catch return error.ArraySizeLimitExceeded;
        if (total > safe_array_element_limit) return error.ArraySizeLimitExceeded;
        if (product == 0) break;
    }
}

fn cloneFillValue(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return if (value.tag == @intFromEnum(Tag.dictionary)) deepCloneBuiltin(runtime, value) else value;
    const source = try arrayItems(value);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const destination = try arrayItems(roots[1]);
    try destination.ensureTotalCapacity(runtime.allocator, source.items.len);
    for (source.items) |item| try destination.append(runtime.allocator, try cloneFillValue(runtime, item));
    return roots[1];
}

fn arrayFillAtDepth(runtime: *Runtime, value: Value, shape: Value, depth: usize) !Value {
    if (shape.tag != @intFromEnum(Tag.array)) {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, shape), safe_array_element_limit - 1);
        const result = try runtime.createArray(&.{});
        var roots = [_]Value{ value, result };
        var frame: RootFrame = .{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        const items = try arrayItems(roots[1]);
        try items.ensureTotalCapacity(runtime.allocator, count);
        for (0..count) |_| try items.append(runtime.allocator, try cloneFillValue(runtime, roots[0]));
        return roots[1];
    }
    const dimensions = try arrayItems(shape);
    if (dimensions.items.len == 0 and depth == 0) return runtime.createArray(&.{});
    if (depth >= dimensions.items.len) return cloneFillValue(runtime, value);
    const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimensions.items[depth]), safe_array_element_limit);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, shape, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const items = try arrayItems(roots[2]);
    try items.ensureTotalCapacity(runtime.allocator, count);
    for (0..count) |_| try items.append(runtime.allocator, try arrayFillAtDepth(runtime, roots[0], roots[1], depth + 1));
    return roots[2];
}

fn explodeBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        roots[1] = try runtime.createString(units[index .. index + length]);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
        index += length;
    }
    return roots[0];
}

fn refrainBuiltin(runtime: *Runtime, value: Value, count_value: Value) !Value {
    const count_number = try valueToNumberRuntime(runtime, count_value);
    if (std.math.isNan(count_number) or count_number <= 0) return runtime.createString(&.{});
    if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RepetitionTooLarge;
    const count: usize = @intFromFloat(@ceil(count_number));
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const length = std.math.mul(usize, units.len, count) catch return error.RepetitionTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    for (0..count) |index| @memcpy(output[index * units.len ..][0..units.len], units);
    return runtime.ownString(output);
}

fn occurrenceBuiltin(runtime: *Runtime, source: Value, needle: Value) !bool {
    if (source.tag == @intFromEnum(Tag.array)) {
        for (source.object().?.payload.array.items) |item| {
            if (try sameValueZero(runtime, item, needle)) return true;
        }
        return false;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    return indexOfUnitsBuiltin(source_units, needle_units, 0) != null;
}

fn occurrenceCountBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value) !i64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    if (needle.len == 0) return @as(i64, @intCast(source.len)) - 1;
    var count: i64 = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        count += 1;
        start = found + needle.len;
    }
    return count;
}

fn substringBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    var start: usize = 0;
    var end: usize = length;
    switch (command) {
        .substring_mid => {
            var start_number = try substringNumberBuiltin(runtime, arguments[1]);
            const count_number = try substringNumberBuiltin(runtime, arguments[2]);
            if (count_number <= 0) return runtime.createString(&.{});
            if (start_number < 0) {
                start_number = @as(f64, @floatFromInt(length)) + start_number + 1;
                if (start_number < 0) start_number = 1;
            }
            start = sliceIndexBuiltin(start_number - 1, length);
            end = sliceIndexBuiltin(start_number + count_number - 1, length);
            if (end <= start) return runtime.createString(&.{});
        },
        .substring_left => end = sliceIndexBuiltin(try valueToNumberRuntime(runtime, arguments[1]), length),
        .substring_right => {
            var index_number = @as(f64, @floatFromInt(length)) - try valueToNumberRuntime(runtime, arguments[1]);
            if (index_number < 0) index_number = 0;
            start = sliceIndexBuiltin(index_number, length);
        },
        else => unreachable,
    }
    return runtime.createString(source[codePointOffsetBuiltin(source, start)..codePointOffsetBuiltin(source, end)]);
}

fn substringNumberBuiltin(runtime: *Runtime, value: Value) !f64 {
    return if (isString(value)) parseIntBuiltin(runtime, value) else valueToNumberRuntime(runtime, value);
}

fn sliceIndexBuiltin(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    const length_number: f64 = @floatFromInt(length);
    if (number >= length_number) return length;
    if (number <= -length_number) return 0;
    if (number < 0) return length - @as(usize, @intFromFloat(-@trunc(number)));
    return @intFromFloat(@trunc(number));
}

fn splitBuiltin(runtime: *Runtime, source_value: Value, delimiter_value: Value, first_only: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const delimiter = try valueUtf16Alloc(runtime, delimiter_value);
    defer runtime.allocator.free(delimiter);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    if (first_only) {
        if (std.mem.indexOf(u16, source, delimiter)) |found| {
            try appendStringPart(runtime, &roots, source[0..found]);
            try appendStringPart(runtime, &roots, source[found + delimiter.len ..]);
        } else try appendStringPart(runtime, &roots, source);
        return roots[0];
    }
    if (delimiter.len == 0) {
        for (source) |unit| try appendStringPart(runtime, &roots, &.{unit});
        return roots[0];
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, delimiter)) |found| {
        try appendStringPart(runtime, &roots, source[start..found]);
        start = found + delimiter.len;
    }
    try appendStringPart(runtime, &roots, source[start..]);
    return roots[0];
}

fn appendStringPart(runtime: *Runtime, roots: *[2]Value, units: []const u16) !void {
    roots[1] = try runtime.createString(units);
    try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
}

fn stringRemoveBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, count_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    const start = sliceIndexBuiltin(try valueToNumberRuntime(runtime, start_value) - 1, length);
    const count = spliceDeleteCountBuiltin(try valueToNumberRuntime(runtime, count_value), length - start);
    const unit_start = codePointOffsetBuiltin(source, start);
    const unit_end = codePointOffsetBuiltin(source, start + count);
    const output = try runtime.allocator.alloc(u16, source.len - (unit_end - unit_start));
    @memcpy(output[0..unit_start], source[0..unit_start]);
    @memcpy(output[unit_start..], source[unit_end..]);
    return runtime.ownString(output);
}

fn spliceDeleteCountBuiltin(number: f64, remaining: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(remaining))) return remaining;
    return @intFromFloat(@trunc(number));
}

fn trimBuiltin(runtime: *Runtime, value: Value, trim_left: bool, trim_right: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var start: usize = 0;
    var end = units.len;
    if (trim_left) {
        while (start < end and string_mod.isEcmaWhitespace(units[start])) : (start += 1) {}
    }
    if (trim_right) {
        while (end > start and string_mod.isEcmaWhitespace(units[end - 1])) : (end -= 1) {}
    }
    return runtime.createString(units[start..end]);
}

fn unicodeCaseBuiltin(runtime: *Runtime, value: Value, uppercase: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(runtime.allocator);
    var unit_index: usize = 0;
    while (unit_index < units.len) {
        const length = codePointLength(units, unit_index);
        const codepoint: u21 = if (length == 2)
            @intCast(0x10000 + ((@as(u32, units[unit_index]) - 0xd800) << 10) + (@as(u32, units[unit_index + 1]) - 0xdc00))
        else
            @intCast(units[unit_index]);
        try codepoints.append(runtime.allocator, codepoint);
        unit_index += length;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (codepoints.items, 0..) |codepoint, index| {
        if (!uppercase and codepoint == 0x03a3 and isFinalSigmaBuiltin(codepoints.items, index)) {
            try output.append(runtime.allocator, 0x03c2);
            continue;
        }
        const mapped = if (uppercase) unicode_case.upper(codepoint) else unicode_case.lower(codepoint);
        if (mapped) |values| {
            for (values) |mapped_codepoint| try appendCodePointBuiltin(runtime.allocator, &output, mapped_codepoint);
        } else {
            try appendCodePointBuiltin(runtime.allocator, &output, codepoint);
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

fn isFinalSigmaBuiltin(codepoints: []const u21, index: usize) bool {
    var before = index;
    var has_cased_before = false;
    while (before > 0) {
        before -= 1;
        if (unicode_case.isCaseIgnorable(codepoints[before])) continue;
        has_cased_before = unicode_case.isCased(codepoints[before]);
        break;
    }
    if (!has_cased_before) return false;
    var after = index + 1;
    while (after < codepoints.len) : (after += 1) {
        if (unicode_case.isCaseIgnorable(codepoints[after])) continue;
        return !unicode_case.isCased(codepoints[after]);
    }
    return true;
}

fn appendCodePointBuiltin(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const offset: u32 = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (offset >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (offset & 0x3ff)));
}

fn kanaOffsetBuiltin(runtime: *Runtime, value: Value, to_katakana: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    errdefer runtime.allocator.free(output);
    const first: u16 = if (to_katakana) 0x3041 else 0x30a1;
    const last: u16 = if (to_katakana) 0x3096 else 0x30f6;
    const offset: i32 = if (to_katakana) 0x60 else -0x60;
    for (output) |*unit| {
        if (unit.* >= first and unit.* <= last) unit.* = @intCast(@as(i32, unit.*) + offset);
    }
    return runtime.ownString(output);
}

fn asciiWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool, symbols: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const output = try runtime.allocator.dupe(u16, units);
    for (output) |*unit| {
        if (to_full) {
            if (symbols and unit.* == 0x20) {
                unit.* = 0x3000;
            } else if ((symbols and unit.* >= 0x21 and unit.* <= 0x7e) or
                (!symbols and ((unit.* >= 'A' and unit.* <= 'Z') or
                    (unit.* >= 'a' and unit.* <= 'z') or
                    (unit.* >= '0' and unit.* <= '9'))))
            {
                unit.* += 0xfee0;
            }
        } else if (symbols and unit.* == 0x3000) {
            unit.* = 0x20;
        } else if ((symbols and unit.* >= 0xff00 and unit.* <= 0xff5f) or
            (!symbols and ((unit.* >= 0xff21 and unit.* <= 0xff3a) or
                (unit.* >= 0xff41 and unit.* <= 0xff5a) or
                (unit.* >= 0xff10 and unit.* <= 0xff19))))
        {
            unit.* -= 0xfee0;
        }
    }
    return runtime.ownString(output);
}

fn kanaWidthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    return kanaMapBuiltin(runtime, value, to_full);
}

fn widthBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    // 公式実装と同じく、全角化はカナ→英数記号、半角化もカナ→英数記号の順に行う。
    var roots = [_]Value{.{}};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try kanaMapBuiltin(runtime, value, to_full);
    return asciiWidthBuiltin(runtime, roots[0], to_full, true);
}

fn currencyBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < units.len) {
        if (!isAsciiDigitBuiltin(units[index])) {
            try output.append(runtime.allocator, units[index]);
            index += 1;
            continue;
        }
        const start = index;
        while (index < units.len and isAsciiDigitBuiltin(units[index])) : (index += 1) {}
        const end = index;
        // 公式の可変長後読みは、ドット直後の数字run全体を除外する。
        if (start > 0 and units[start - 1] == '.') {
            try output.appendSlice(runtime.allocator, units[start..end]);
            continue;
        }
        var group = (end - start) % 3;
        if (group == 0) group = 3;
        var cursor = start;
        while (cursor < end) {
            const next = std.math.add(usize, cursor, @min(end - cursor, group)) catch return error.StringTooLarge;
            try output.appendSlice(runtime.allocator, units[cursor..next]);
            cursor = next;
            if (cursor < end) try output.append(runtime.allocator, ',');
            group = 3;
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

fn padBuiltin(runtime: *Runtime, value: Value, width_value: Value, fill: u16) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const original_number = switch (@as(Tag, @enumFromInt(width_value.tag))) {
        .bigint => width_value.object().?.payload.bigint.toF64(),
        else => try valueToNumberRuntime(runtime, width_value),
    };
    const parsed = try parseIntBuiltin(runtime, width_value);
    // 公式はparseInt前に `for (i = 0; i < A; i++)` で埋め文字を作る。
    // したがってAが数値化不能でも、parseInt後の幅とは別に1文字が残る。
    const fill_count = if (std.math.isNan(original_number) or original_number <= 0) @as(usize, 1) else blk: {
        // Infinityでは公式のループが終了しないため、AOTでは安全に拒否する。
        if (!std.math.isFinite(original_number) or original_number >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.OutOfMemory;
        const iterations: usize = @intFromFloat(@ceil(original_number));
        break :blk iterations + 1;
    };
    if (std.math.isNan(parsed)) {
        const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
        const output = try runtime.allocator.alloc(u16, source_len);
        errdefer runtime.allocator.free(output);
        @memset(output[0..fill_count], fill);
        @memcpy(output[fill_count..], units);
        return runtime.ownString(output);
    }
    const requested: usize = if (parsed <= 0) 0 else blk: {
        if (!std.math.isFinite(parsed) or parsed >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.OutOfMemory;
        break :blk @intFromFloat(@trunc(parsed));
    };
    const target = @max(units.len, requested);
    const source_len = std.math.add(usize, fill_count, units.len) catch return error.OutOfMemory;
    const result_len = @min(target, source_len);
    const output = try runtime.allocator.alloc(u16, result_len);
    errdefer runtime.allocator.free(output);
    const result_fill_count = result_len - units.len;
    @memset(output[0..result_fill_count], fill);
    @memcpy(output[result_fill_count..], units);
    return runtime.ownString(output);
}

fn stringPredicateBuiltin(runtime: *Runtime, value: Value, command: aot_builtin.Command) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const first = if (units.len == 0) 0 else units[0];
    const result = switch (command) {
        .hiragana_predicate => first >= 0x3041 and first <= 0x309f,
        .katakana_predicate => first >= 0x30a1 and first <= 0x30fa,
        .digit_predicate => isSequenceDigitBuiltin(first),
        .number_sequence_predicate => if (isString(value) and units.len == 0) false else numberSequenceBuiltin(units),
        else => unreachable,
    };
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
}

fn numberSequenceBuiltin(units: []const u16) bool {
    var index: usize = 0;
    if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
    while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
    if (index < units.len and (units[index] == '.' or units[index] == 0xff0e)) {
        index += 1;
        const fraction_start = index;
        while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
        if (index == fraction_start) return false;
        if (index < units.len and (units[index] == 'e' or units[index] == 'E' or units[index] == 0xff45 or units[index] == 0xff25)) {
            index += 1;
            if (index < units.len and isSequenceSignBuiltin(units[index])) index += 1;
            const exponent_start = index;
            while (index < units.len and isSequenceDigitBuiltin(units[index])) : (index += 1) {}
            if (index == exponent_start) return false;
        }
    }
    // 公式正規表現は空文字列だけを別扱いにし、符号単独も受理する。
    return index == units.len;
}

fn isAsciiDigitBuiltin(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

fn isSequenceDigitBuiltin(unit: u16) bool {
    return isAsciiDigitBuiltin(unit) or (unit >= 0xff10 and unit <= 0xff19);
}

fn isSequenceSignBuiltin(unit: u16) bool {
    return unit == '+' or unit == '-' or unit == 0xff0b or unit == 0xff0d;
}

fn kanaMapBuiltin(runtime: *Runtime, value: Value, to_full: bool) !Value {
    var roots = [_]Value{value};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var allocated_source: ?[]u16 = null;
    defer if (allocated_source) |source| runtime.allocator.free(source);
    const source: []const u16 = blk: {
        if (isString(roots[0])) {
            allocated_source = try valueUtf16Alloc(runtime, roots[0]);
            break :blk allocated_source.?;
        }
        if (!to_full) switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaHalfWidthSplitNull,
            .undefined => return error.KatakanaHalfWidthSplitUndefined,
            else => return error.KatakanaHalfWidthSplitReceiver,
        };

        switch (@as(Tag, @enumFromInt(roots[0].tag))) {
            .null_value => return error.KatakanaFullWidthLengthNull,
            .undefined => return error.KatakanaFullWidthLengthUndefined,
            .array => {
                if (roots[0].object().?.payload.array.items.len > 0) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .dictionary => {
                const length = dictionaryProperty(roots[0], &.{ 'l', 'e', 'n', 'g', 't', 'h' });
                // `0 < s.length` uses JavaScript's abstract relational
                // comparison. Undefined/NaN therefore takes the empty path.
                if (try compareValues(runtime, .less, numberValue(0), length)) return error.KatakanaFullWidthSubstringReceiver;
                break :blk &.{};
            },
            .function => break :blk &.{},
            else => break :blk &.{},
        }
    };
    const full_utf8 = system_constant.lookupString("全角カナ一覧").?;
    const full_voiced_utf8 = system_constant.lookupString("全角カナ濁音一覧").?;
    const half_utf8 = system_constant.lookupString("半角カナ一覧").?;
    const half_voiced_utf8 = system_constant.lookupString("半角カナ濁音一覧").?;
    const full = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_utf8);
    defer runtime.allocator.free(full);
    const half = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_utf8);
    defer runtime.allocator.free(half);
    const full_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, full_voiced_utf8);
    defer runtime.allocator.free(full_voiced);
    const half_voiced = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, half_voiced_utf8);
    defer runtime.allocator.free(half_voiced);

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (to_full) {
            const candidate_end = @min(source.len, index + 2);
            // The official implementation searches the half-width voiced table
            // with the two-unit candidate. This intentionally also maps a lone
            // dakuten/handakuten to the first matching voiced kana entry.
            if (indexOfUnitsBuiltin(half_voiced, source[index..candidate_end], 0)) |position| {
                try output.append(runtime.allocator, full_voiced[position / 2]);
                index = candidate_end;
                continue;
            }
            if (unitIndexBuiltin(half, source[index])) |half_index| {
                if (half_index < full.len) try output.append(runtime.allocator, full[half_index]);
            } else {
                try output.append(runtime.allocator, source[index]);
            }
        } else if (unitIndexBuiltin(full, source[index])) |full_index| {
            try output.append(runtime.allocator, half[full_index]);
        } else if (unitIndexBuiltin(full_voiced, source[index])) |voiced_index| {
            try output.append(runtime.allocator, half_voiced[voiced_index * 2]);
            try output.append(runtime.allocator, half_voiced[voiced_index * 2 + 1]);
        } else {
            try output.append(runtime.allocator, source[index]);
        }
        index += 1;
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

fn unitIndexBuiltin(units: []const u16, needle: u16) ?usize {
    for (units, 0..) |unit, index| if (unit == needle) return index;
    return null;
}

fn indexOfUnitsBuiltin(haystack: []const u16, needle: []const u16, start: usize) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.mem.eql(u16, haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn replaceBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value, replacement_value: Value, all: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    // split(undefined) returns the source as its sole element, so join never
    // observes the replacement separator. replace(undefined, ...) still
    // searches for the literal string "undefined" and must use the path below.
    if (all and needle_value.tag == @intFromEnum(Tag.undefined)) return runtime.createString(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var allocated_replacement: ?[]u16 = null;
    const replacement: []const u16 = if (all and replacement_value.tag == @intFromEnum(Tag.undefined))
        // Array.prototype.join(undefined) uses its default comma separator.
        &.{','}
    else blk: {
        allocated_replacement = try valueUtf16Alloc(runtime, replacement_value);
        break :blk allocated_replacement.?;
    };
    defer if (allocated_replacement) |allocated| runtime.allocator.free(allocated);
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (!all) {
        const found = std.mem.indexOf(u16, source, needle) orelse return runtime.createString(source);
        try output.appendSlice(runtime.allocator, source[0..found]);
        try appendFirstReplacementBuiltin(runtime, &output, source, found, found + needle.len, replacement);
        try output.appendSlice(runtime.allocator, source[found + needle.len ..]);
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    if (needle.len == 0) {
        for (source, 0..) |unit, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, replacement);
            try output.append(runtime.allocator, unit);
        }
        return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        try output.appendSlice(runtime.allocator, source[start..found]);
        try output.appendSlice(runtime.allocator, replacement);
        start = found + needle.len;
    }
    try output.appendSlice(runtime.allocator, source[start..]);
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

fn appendFirstReplacementBuiltin(runtime: *Runtime, output: *std.ArrayList(u16), source: []const u16, match_start: usize, match_end: usize, replacement: []const u16) !void {
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try output.append(runtime.allocator, replacement[index]);
            index += 1;
            continue;
        }
        switch (replacement[index + 1]) {
            '$' => try output.append(runtime.allocator, '$'),
            '&' => try output.appendSlice(runtime.allocator, source[match_start..match_end]),
            '`' => try output.appendSlice(runtime.allocator, source[0..match_start]),
            '\'' => try output.appendSlice(runtime.allocator, source[match_end..]),
            else => {
                try output.append(runtime.allocator, '$');
                index += 1;
                continue;
            },
        }
        index += 2;
    }
}

test "UTF-16文字列をルートから正確にmark-and-sweepする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createString(&.{ 0x3042, 0xd83d, 0xde00 })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 1), runtime.object_count);
    try std.testing.expectEqualSlices(u16, &.{ 0x3042, 0xd83d, 0xde00 }, values[0].object().?.payload.utf16_string);
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 1), runtime.collect());
    try std.testing.expectEqual(@as(usize, 0), runtime.object_count);
}

test "LLVM側の値ABIと同じ16バイト配置を保つ" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "payload"));
}

test "公開AOT ABIは動的値をポインタで受け渡す" {
    try std.testing.expectEqual(*const fn (*Value, *anyopaque, ?[*]const Value, usize) callconv(.c) void, FunctionCallback);
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_array_new));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_index_get));
    try std.testing.expectEqual(*const fn (*const Value, *const Value, *const Value) callconv(.c) c_int, @TypeOf(&lnako_aot_index_set));
    try std.testing.expectEqual(*const fn (*Value, *const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_destructure_get));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_arithmetic));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_compare));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_shift));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_concat));
    try std.testing.expectEqual(*const fn (*Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_increment));
    try std.testing.expectEqual(*const fn (*const Value, bool) callconv(.c) void, @TypeOf(&lnako_aot_print_collection));
    try std.testing.expectEqual(*const fn (*Value, ?*const Value) callconv(.c) void, @TypeOf(&lnako_aot_binding_cell_new));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) *Value, @TypeOf(&lnako_aot_binding_cell_value));
    try std.testing.expectEqual(*const fn (*Value, FunctionCallback, usize, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_new));
    try std.testing.expectEqual(*const fn (*Value, *anyopaque, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_capture));
    try std.testing.expectEqual(*const fn (*Value, *const Value, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_call));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u8) callconv(.c) void, @TypeOf(&lnako_aot_cut));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u8, u64) callconv(.c) void, @TypeOf(&lnako_aot_cut_site));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, u16) callconv(.c) void, @TypeOf(&lnako_aot_builtin_call));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_builtin_call_site));
    try std.testing.expectEqual(*const fn (*Value, ?*Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_regexp_call_site));
    try std.testing.expectEqual(*const fn (u64) callconv(.c) u64, @TypeOf(&lnako_aot_dispatch_display_begin));
    try std.testing.expectEqual(*const fn (u64, *u64) callconv(.c) u64, @TypeOf(&lnako_aot_dispatch_display_begin_with_epoch));
    try std.testing.expectEqual(*const fn (u64, u64, u64) callconv(.c) void, @TypeOf(&lnako_aot_dispatch_result));
    try std.testing.expectEqual(*const fn (*const Value, bool) callconv(.c) void, @TypeOf(&lnako_aot_print_number));
    try std.testing.expectEqual(*const fn (*const Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_set));
    try std.testing.expectEqual(*const fn () callconv(.c) c_int, @TypeOf(&lnako_aot_exception_pending));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_take));
}

test "AOT dispatchのfailure epochは過去のpending exceptionを再利用しない" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const first_dispatch_epoch = runtime.failure_epoch;
    runtime.setFailure(error.InvalidArgumentCount);
    try std.testing.expectEqual(first_dispatch_epoch +% 1, runtime.failure_epoch);
    try std.testing.expect(runtime.has_pending_exception);

    // The pending exception intentionally remains set. A successful dispatch
    // beginning here observes the new epoch and therefore is not attributed
    // the earlier failure merely because the slot is still occupied.
    const second_dispatch_epoch = runtime.failure_epoch;
    try std.testing.expectEqual(second_dispatch_epoch, runtime.failure_epoch);
    try std.testing.expect(second_dispatch_epoch != first_dispatch_epoch);

    _ = runtime.takeException();
    try std.testing.expectEqual(second_dispatch_epoch, runtime.failure_epoch);
    try std.testing.expect(!runtime.has_pending_exception);
}

test "AOT切取はUTF-16検索と元値lengthの遅延評価を再現する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try active_runtime.?.createString(&.{ 'a', ':', 'b', ':', 'c' });
    roots[1] = try active_runtime.?.createString(&.{':'});
    var cut_arguments = [_]Value{ roots[0], roots[1] };
    roots[2] = try active_runtime.?.createString(&.{ 'k', 'e', 'e', 'p' });
    lnako_aot_cut(&roots[3], &roots[2], &cut_arguments, cut_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{'a'}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'b', ':', 'c' }, roots[2].object().?.payload.utf16_string);

    roots[4] = try active_runtime.?.createString(&.{ 'a', '[', 'b', ']', 'c', '[', 'd', ']', 'e' });
    roots[5] = try active_runtime.?.createString(&.{'['});
    roots[6] = try active_runtime.?.createString(&.{']'});
    var range_arguments = [_]Value{ roots[4], roots[5], roots[6] };
    lnako_aot_cut(&roots[7], &roots[2], &range_arguments, range_arguments.len, 1);
    try std.testing.expectEqualSlices(u16, &.{'b'}, roots[7].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'c', '[', 'd', ']', 'e' }, roots[2].object().?.payload.utf16_string);

    roots[8] = try active_runtime.?.createString(&.{ '1', '2', '3', 'X' });
    const number_arguments = [_]Value{ roots[8], numberValue(123) };
    lnako_aot_cut(&roots[9], &roots[2], &number_arguments, number_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[9].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '3', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[10] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    roots[11] = try active_runtime.?.createString(&.{ '1', ',', '2', 'X' });
    const array_arguments = [_]Value{ roots[11], roots[10] };
    lnako_aot_cut(&roots[12], &roots[2], &array_arguments, array_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[12].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ '2', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[18] = try active_runtime.?.createString(&.{ 't', 'r', 'u', 'e', 'X' });
    const boolean_arguments = [_]Value{ roots[18], .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 } };
    lnako_aot_cut(&roots[19], &roots[2], &boolean_arguments, boolean_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[19].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'r', 'u', 'e', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[13] = try active_runtime.?.createDictionary(&.{ staticStringValue("length"), numberValue(2) });
    roots[14] = try active_runtime.?.createString(&.{ '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' });
    const dictionary_arguments = [_]Value{ roots[14], roots[13] };
    lnako_aot_cut(&roots[15], &roots[2], &dictionary_arguments, dictionary_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[15].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' }, roots[2].object().?.payload.utf16_string);

    lnako_aot_function_new(&roots[10], testAotFunction, 1, null, 0);
    const function_arguments = [_]Value{ staticStringValue("function () { [native code] }X"), roots[10] };
    lnako_aot_cut(&roots[11], &roots[2], &function_arguments, function_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[11].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'u', 'n', 'c', 't', 'i', 'o', 'n', ' ', '(', ')', ' ', '{', ' ', '[', 'n', 'a', 't', 'i', 'v', 'e', ' ', 'c', 'o', 'd', 'e', ']', ' ', '}', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[16] = try active_runtime.?.createString(&.{ 0xd83d, 0xde00, 0, 0xd800 });
    roots[17] = try active_runtime.?.createString(&.{ 0xd83d, 0xde00 });
    const unicode_arguments = [_]Value{ roots[16], roots[17] };
    try std.testing.expectEqual(@as(?usize, 0), indexOfUnitsBuiltin(roots[16].object().?.payload.utf16_string, roots[17].object().?.payload.utf16_string, 0));
    try std.testing.expectEqual(@as(usize, 2), try cutEndIndex(&active_runtime.?, 0, roots[17], 4));
    active_runtime.?.next_collection = active_runtime.?.object_count;
    lnako_aot_cut(&roots[3], &roots[2], &unicode_arguments, unicode_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0xd800 }, roots[2].object().?.payload.utf16_string);

    const absent_range_arguments = [_]Value{ roots[16], staticStringValue("missing"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_cut(&roots[3], &roots[2], &absent_range_arguments, absent_range_arguments.len, 1);
    try std.testing.expect(!active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 0, 0xd800 }, roots[2].object().?.payload.utf16_string);

    const undefined_nonmatch_arguments = [_]Value{ staticStringValue("abc"), .{} };
    lnako_aot_cut(&roots[3], &roots[2], &undefined_nonmatch_arguments, undefined_nonmatch_arguments.len, 0);
    try std.testing.expect(!active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{}, roots[2].object().?.payload.utf16_string);

    roots[2] = try active_runtime.?.createString(&.{ 'k', 'e', 'e', 'p' });
    const null_match_arguments = [_]Value{ staticStringValue("null"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_cut(&roots[3], &roots[2], &null_match_arguments, null_match_arguments.len, 0);
    try std.testing.expect(active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'k', 'e', 'e', 'p' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_exception_take(&roots[1]);
    try std.testing.expect(!active_runtime.?.has_pending_exception);

    const undefined_match_arguments = [_]Value{ staticStringValue("undefined"), .{} };
    lnako_aot_cut(&roots[3], &roots[2], &undefined_match_arguments, undefined_match_arguments.len, 0);
    try std.testing.expect(active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'k', 'e', 'e', 'p' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_exception_take(&roots[1]);
    try std.testing.expect(!active_runtime.?.has_pending_exception);
}

fn testAotFunction(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 1) .{} else arguments.?[0];
}

fn testAotSecondArgument(out: *Value, _: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = if (arguments == null or len != 2) .{} else arguments.?[1];
}

fn testAotCapturedIncrement(out: *Value, context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    const function: *Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    const next = numberValue(valueToNumber(cell.payload.binding_cell) + 1);
    cell.payload.binding_cell = next;
    out.* = next;
}

test "AOT関数値を呼び出しGCで回収する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var function: Value = .{};
    lnako_aot_function_new(&function, testAotFunction, 1, null, 0);
    var argument = numberValue(7);
    var result: Value = .{};
    lnako_aot_function_call(&result, &function, @ptrCast(&argument), 1);
    try std.testing.expectEqual(argument.payload, result.payload);
    try std.testing.expectEqual(@as(usize, 1), active_runtime.?.object_count);
    try std.testing.expectEqual(@as(usize, 1), lnako_aot_collect());
}

test "AOT関数値の文字列化は生成ABIの関数名を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const name = "試験123";
    const expected = "function 試験123() { [native code] }";
    lnako_aot_function_new_named(&roots[0], testAotFunction, 0, name.ptr, name.len, null, 0);
    const text = try valueUtf16Alloc(&active_runtime.?, roots[0]);
    defer active_runtime.?.allocator.free(text);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, text);

    roots[1] = try valueToPrimitive(&active_runtime.?, roots[0]);
    try std.testing.expectEqualSlices(u16, expected_units, roots[1].object().?.payload.utf16_string);
}

test "AOT動的関数の不足引数へ共有システム文脈を追加し超過引数を無視する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, numberValue(3), numberValue(4), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_function_new(&roots[0], testAotFunction, 1, null, 0);
    lnako_aot_function_new(&roots[1], testAotSecondArgument, 2, null, 0);
    lnako_aot_function_call(&roots[4], &roots[0], null, 0);
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[4].tag)));
    const system_context = roots[4].payload;
    lnako_aot_function_call(&roots[4], &roots[1], @ptrCast(&roots[2]), 1);
    try std.testing.expectEqual(system_context, roots[4].payload);
    lnako_aot_function_call(&roots[4], &roots[0], @ptrCast(&roots[2]), 2);
    try std.testing.expectEqual(roots[2].payload, roots[4].payload);
}

test "AOT標準命令ディスパッチで値を文字列へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.to_string));
    try std.testing.expectEqualSlices(u16, &.{ 't', 'r', 'u', 'e' }, roots[1].object().?.payload.utf16_string);
}

test "AOT型確認は動的値をJavaScript型名へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.type_of));
    try std.testing.expectEqualStrings("number", staticUtf8(roots[1]));
}

test "AOT数学命令dispatchは数値・配列・別名を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(0);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.math_sin));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(roots[1].payload)));

    roots[2] = numberValue(2);
    roots[3] = numberValue(8);
    var logarithm_arguments = [_]Value{ roots[2], roots[3] };
    lnako_aot_builtin_call(&roots[4], &logarithm_arguments, logarithm_arguments.len, @intFromEnum(aot_builtin.Command.math_logn));
    try std.testing.expectApproxEqAbs(@as(f64, 3), @as(f64, @bitCast(roots[4].payload)), 1e-14);

    roots[5] = try active_runtime.?.createArray(&.{ numberValue(0), numberValue(1) });
    lnako_aot_builtin_call(&roots[6], @ptrCast(&roots[5]), 1, @intFromEnum(aot_builtin.Command.math_coordinate_angle));
    try std.testing.expectApproxEqAbs(@as(f64, 90), @as(f64, @bitCast(roots[6].payload)), 1e-12);

    roots[7] = numberValue(-1.2);
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[7]), 1, @intFromEnum(aot_builtin.Command.math_floor));
    try std.testing.expectEqual(@as(f64, -2), @as(f64, @bitCast(roots[8].payload)));

    roots[9] = numberValue(-1.5);
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[9]), 1, @intFromEnum(aot_builtin.Command.math_round));
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(roots[10].payload)));
}

test "AOT乱数命令は固定シードの数値・配列・辞書・範囲を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .random_state = default_random_seed };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(10);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(roots[1].payload)));

    roots[2] = try active_runtime.?.createArray(&.{ numberValue(2), numberValue(4) });
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[3].payload)));

    roots[4] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(7), staticStringValue("末尾"), numberValue(9) });
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(roots[5].payload)));

    roots[6] = numberValue(10);
    roots[7] = numberValue(12);
    var range_arguments = [_]Value{ roots[6], roots[7] };
    lnako_aot_builtin_call(&roots[8], &range_arguments, range_arguments.len, @intFromEnum(aot_builtin.Command.math_random_range));
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(roots[8].payload)));
}

test "AOT日時の現在時刻・日付・年月命令を固定時計で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .clock_milliseconds = 1_735_689_845_678 };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 12;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try datetimeBuiltin(&runtime, .datetime_now, &.{});
    try expectUtf16String(&runtime, roots[0], "09:04:05");
    roots[1] = try datetimeBuiltin(&runtime, .datetime_system_time, &.{});
    try std.testing.expectEqual(@as(f64, 1_735_689_845), @as(f64, @bitCast(roots[1].payload)));
    roots[2] = try datetimeBuiltin(&runtime, .datetime_system_time_milliseconds, &.{});
    try std.testing.expectEqual(@as(f64, 1_735_689_845_678), @as(f64, @bitCast(roots[2].payload)));
    roots[3] = try datetimeBuiltin(&runtime, .datetime_today, &.{});
    try expectUtf16String(&runtime, roots[3], "2025/01/01");
    roots[4] = try datetimeBuiltin(&runtime, .datetime_tomorrow, &.{});
    try expectUtf16String(&runtime, roots[4], "2025/01/02");
    roots[5] = try datetimeBuiltin(&runtime, .datetime_yesterday, &.{});
    try expectUtf16String(&runtime, roots[5], "2024/12/31");
    roots[6] = try datetimeBuiltin(&runtime, .datetime_current_year, &.{});
    try std.testing.expectEqual(@as(f64, 2025), @as(f64, @bitCast(roots[6].payload)));
    roots[7] = try datetimeBuiltin(&runtime, .datetime_next_year, &.{});
    try std.testing.expectEqual(@as(f64, 2026), @as(f64, @bitCast(roots[7].payload)));
    roots[8] = try datetimeBuiltin(&runtime, .datetime_last_year, &.{});
    try std.testing.expectEqual(@as(f64, 2024), @as(f64, @bitCast(roots[8].payload)));
    roots[9] = try datetimeBuiltin(&runtime, .datetime_current_month, &.{});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[9].payload)));
    roots[10] = try datetimeBuiltin(&runtime, .datetime_next_month, &.{});
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[10].payload)));
    roots[11] = try datetimeBuiltin(&runtime, .datetime_previous_month, &.{});
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[11].payload)));
}

test "AOT対応ブラウザ一覧取得はv3.7.24の辞書をキャッシュする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try caniuseBrowsersBuiltin(&runtime);
    roots[1] = try caniuseBrowsersBuiltin(&runtime);
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(@as(usize, 16), roots[0].object().?.payload.dictionary.items.len);
    roots[2] = dictionaryProperty(roots[0], &.{ 'c', 'h', 'r', 'o', 'm', 'e' });
    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[2].tag)));
    try std.testing.expectEqual(@as(usize, 10), roots[2].object().?.payload.array.items.len);
    try expectUtf16String(&runtime, roots[2].object().?.payload.array.items[0], "145");
}

test "AOT整数実数変換はJavaScript接頭辞規則を共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue(" -0x10rest"), .{}, staticStringValue("12.5xyz"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.to_int));
    try std.testing.expectEqual(@as(f64, -16), @as(f64, @bitCast(roots[1].payload)));
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.to_float));
    try std.testing.expectEqual(@as(f64, 12.5), @as(f64, @bitCast(roots[3].payload)));
}

test "AOTのNAN判定と非数判定はNumber変換の有無を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("12x"), .{}, numberValue(std.math.nan(f64)), .{}, staticStringValue("NaN"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.is_nan));
    try std.testing.expectEqual(@as(u64, 1), roots[1].payload);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.is_number_nan));
    try std.testing.expectEqual(@as(u64, 1), roots[3].payload);
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.is_number_nan));
    try std.testing.expectEqual(@as(u64, 0), roots[5].payload);
}

test "AOT進数変換は小数基数を切り捨てて不正基数を例外にする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("31px"), numberValue(16.9), .{}, numberValue(-10.9), .{}, numberValue(31), .{}, .{}, numberValue(31), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expectEqualSlices(u16, &.{ '1', 'f' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[3]), 1, @intFromEnum(aot_builtin.Command.radix2));
    try std.testing.expectEqualSlices(u16, &.{ '-', '1', '0', '1', '0' }, roots[4].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[5]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expectEqualSlices(u16, &.{ '3', '1' }, roots[7].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[8]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    const message = try valueUtf16Alloc(&active_runtime.?, active_runtime.?.takeException());
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g', '(', ')', ' ', 'r', 'a', 'd', 'i', 'x', ' ', 'a', 'r', 'g', 'u', 'm', 'e', 'n', 't', ' ', 'm', 'u', 's', 't', ' ', 'b', 'e', ' ', 'b', 'e', 't', 'w', 'e', 'e', 'n', ' ', '2', ' ', 'a', 'n', 'd', ' ', '3', '6' }, message);
}

test "AOTのRGBは各16進表現の末尾2文字を連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ numberValue(-1), numberValue(std.math.nan(f64)), staticStringValue("Infinity"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 3, @intFromEnum(aot_builtin.Command.rgb));
    try std.testing.expectEqualSlices(u16, &.{ '#', '-', '1', 'a', 'N', 'a', 'N' }, roots[3].object().?.payload.utf16_string);
}

test "AOTビット命令はNumberの32bit化とBigInt演算を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("5"), numberValue(3), .{}, staticStringValue("3"), numberValue(2), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.bit_and));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.shift_left));
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[5].payload)));
    roots[6] = try active_runtime.?.createBigInt("0n");
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.bit_not));
    const bigint_text = try roots[7].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(bigint_text);
    try std.testing.expectEqualStrings("-1", bigint_text);
}

test "AOT算術比較命令は奇数の符号とNumber限定べき乗を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ numberValue(-3), .{}, numberValue(2), numberValue(8), .{}, numberValue(2), numberValue(1), numberValue(3), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.is_odd));
    try std.testing.expectEqual(@as(u64, 0), roots[1].payload);
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[2]), 2, @intFromEnum(aot_builtin.Command.power_number));
    try std.testing.expectEqual(@as(f64, 256), @as(f64, @bitCast(roots[4].payload)));
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[5]), 3, @intFromEnum(aot_builtin.Command.in_range));
    try std.testing.expectEqual(@as(u64, 1), roots[8].payload);
    roots[9] = try active_runtime.?.createBigInt("2n");
    roots[10] = try active_runtime.?.createBigInt("3n");
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[9]), 2, @intFromEnum(aot_builtin.Command.power_number));
    try std.testing.expect(active_runtime.?.has_pending_exception);
}

test "AOT集約論理範囲命令は動的値と辞書を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ numberValue(1), numberValue(9), numberValue(3), .{}, numberValue(0), staticStringValue("右"), .{}, numberValue(1), numberValue(3), .{}, .{}, .{}, numberValue(std.math.nan(f64)), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 3, @intFromEnum(aot_builtin.Command.maximum));
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(roots[3].payload)));
    lnako_aot_builtin_call(&roots[6], @ptrCast(&roots[4]), 2, @intFromEnum(aot_builtin.Command.logical_or));
    try std.testing.expectEqualStrings("右", staticUtf8(roots[6]));
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[7]), 2, @intFromEnum(aot_builtin.Command.range));
    roots[10] = try active_runtime.?.createString(&.{ 0x5148, 0x982d });
    roots[11] = try active_runtime.?.createString(&.{ 0x672b, 0x5c3e });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(active_runtime.?.indexGet(roots[9], roots[10]).payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(active_runtime.?.indexGet(roots[9], roots[11]).payload)));
    lnako_aot_builtin_call(&roots[14], @ptrCast(&roots[12]), 2, @intFromEnum(aot_builtin.Command.maximum));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(roots[14].payload))));
}

test "AOT空コレクション命令は独立値を返し真偽判定は日本語ラベルにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, numberValue(0), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[0], null, 0, @intFromEnum(aot_builtin.Command.empty_array));
    lnako_aot_builtin_call(&roots[1], null, 0, @intFromEnum(aot_builtin.Command.empty_array));
    try std.testing.expect(roots[0].payload != roots[1].payload);
    lnako_aot_builtin_call(&roots[2], null, 0, @intFromEnum(aot_builtin.Command.empty_dictionary));
    lnako_aot_builtin_call(&roots[3], null, 0, @intFromEnum(aot_builtin.Command.empty_dictionary));
    try std.testing.expect(roots[2].payload != roots[3].payload);
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.truth_label));
    try std.testing.expectEqualSlices(u16, &.{0x507d}, roots[5].object().?.payload.utf16_string);
    roots[6] = try active_runtime.?.createArray(&.{});
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.truth_label));
    try std.testing.expectEqualSlices(u16, &.{0x771f}, roots[7].object().?.payload.utf16_string);
}

test "AOT掛命令は文字列配列反復と数値乗算を切り替える" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("ab"), staticStringValue("2x"), .{}, .{}, numberValue(2), .{}, numberValue(3), numberValue(4), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'a', 'b' }, roots[2].object().?.payload.utf16_string);
    roots[3] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqual(@as(usize, 4), roots[5].object().?.payload.array.items.len);
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[6]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[8].payload)));
}

test "AOT文字長検索と要素数はUnicode scalarとUTF-16を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    roots[0] = try active_runtime.?.createString(&.{ 'A', 0xd83d, 0xde00, 'B' });
    roots[1] = try active_runtime.?.createString(&.{ 0xd83d, 0xde00, 'B' });
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.unicode_length));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(roots[2].payload)));
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.codepoint_find));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[3].payload)));
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.element_count));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[4].payload)));
    roots[5] = staticStringValue("A");
    const starts_arguments = [_]Value{ roots[0], roots[5] };
    lnako_aot_builtin_call(&roots[6], &starts_arguments, starts_arguments.len, @intFromEnum(aot_builtin.Command.string_starts));
    try std.testing.expect(roots[6].payload != 0);
    roots[7] = staticStringValue("B");
    const ends_arguments = [_]Value{ roots[0], roots[7] };
    lnako_aot_builtin_call(&roots[8], &ends_arguments, ends_arguments.len, @intFromEnum(aot_builtin.Command.string_ends));
    try std.testing.expect(roots[8].payload != 0);
    roots[9] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[9]), 1, @intFromEnum(aot_builtin.Command.element_count));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[10].payload)));
}

test "AOT何文字目はArray.from要素境界と辞書ToLengthを再現する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 24;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{staticStringValue("a")});
    roots[1] = try runtime.createArray(&.{ staticStringValue("a"), .{ .tag = @intFromEnum(Tag.null_value) } });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[1]));
    roots[2] = try runtime.createArray(&.{
        staticStringValue("a"),
        .{},
    });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[2]));

    roots[3] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(12), numberValue(3) });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[3], staticStringValue("123")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[3], staticStringValue("12")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, numberValue(123), numberValue(123)));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), numberValue(123)));
    roots[17] = try runtime.createBigInt("1n");
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[17], roots[17]));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), roots[17]));

    roots[4] = try runtime.createArray(&.{ staticStringValue("a"), staticStringValue("b") });
    roots[5] = try runtime.createArray(&.{ roots[4], staticStringValue("c") });
    roots[6] = try runtime.createArray(&.{roots[4]});
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[5], staticStringValue("a,b")));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[5], roots[6]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[5], staticStringValue("b,c")));

    roots[7] = try runtime.createDictionary(&.{ staticStringValue("length"), staticStringValue("2"), staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[7], staticStringValue("y")));
    roots[8] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(1.9), staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[8], staticStringValue("x")));
    roots[9] = try runtime.createDictionary(&.{ staticStringValue("length"), .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[9], staticStringValue("x")));
    roots[10] = try runtime.createArray(&.{numberValue(2)});
    roots[11] = try runtime.createDictionary(&.{ staticStringValue("length"), roots[10], staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[11], staticStringValue("y")));
    roots[12] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(-1), staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[12], staticStringValue("x")));
    roots[13] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(std.math.nan(f64)), staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[13], staticStringValue("x")));
    roots[14] = try runtime.createDictionary(&.{ staticStringValue("length"), .{ .tag = @intFromEnum(Tag.null_value) }, staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[14], staticStringValue("x")));

    roots[15] = try runtime.createFunction(testAotFunction, 1, &.{});
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), roots[15]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[15], staticStringValue("a")));

    const null_value: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    try std.testing.expectError(error.NakoException, codePointFindBuiltin(&runtime, null_value, staticStringValue("a")));
    const null_message = try valueUtf16Alloc(&runtime, runtime.takeException());
    defer runtime.allocator.free(null_message);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_message);
    const undefined_value: Value = .{};
    try std.testing.expectError(error.NakoException, codePointFindBuiltin(&runtime, undefined_value, staticStringValue("a")));
    const undefined_message = try valueUtf16Alloc(&runtime, runtime.takeException());
    defer runtime.allocator.free(undefined_message);
    const expected_undefined = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_undefined);
    try std.testing.expectEqualSlices(u16, expected_undefined, undefined_message);
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), staticStringValue("a")));

    roots[16] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(@floatFromInt(search_element_limit + 1)), staticStringValue("0"), staticStringValue("hit") });
    try std.testing.expectError(error.ArraySizeLimitExceeded, codePointFindBuiltin(&runtime, roots[16], staticStringValue("hit")));
}

fn codePointFindAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    const source = try runtime.createArray(&.{ staticStringValue("A"), staticStringValue("😀"), staticStringValue("B") });
    const needle = try runtime.createArray(&.{staticStringValue("😀")});
    const result = try codePointFindBuiltin(&runtime, source, needle);
    try std.testing.expectEqual(@as(usize, 2), result);
    const string_source = try runtime.createString(&.{ 'A', 0xd83d, 0xde00, 'B' });
    const string_needle = try runtime.createString(&.{ 0xd83d, 0xde00, 'B' });
    const string_result = try codePointFindBuiltin(&runtime, string_source, string_needle);
    try std.testing.expectEqual(@as(usize, 2), string_result);
}

test "AOT何文字目の要素列構築は割当失敗で入力を壊さない" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, codePointFindAllocationTest, .{});
}

test "AOT何文字目の文字列fast pathはスカラーwindowを比較する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, staticStringValue("A😀B"), staticStringValue("😀B")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, staticStringValue(""), staticStringValue("x")));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("x"), staticStringValue("")));

    roots[0] = try runtime.createString(&.{ 0xd83d, 0xde00 });
    roots[1] = try runtime.createString(&.{0xd83d});
    roots[2] = try runtime.createString(&.{0xde00});
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[0]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[0], roots[1]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[0], roots[2]));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[1], roots[1]));

    var long_units: [2048]u16 = undefined;
    @memset(long_units[0..2046], 'a');
    long_units[2046] = 0xd83d;
    long_units[2047] = 0xde00;
    roots[3] = try runtime.createString(&long_units);
    try std.testing.expectEqual(@as(usize, 2047), try codePointFindBuiltin(&runtime, roots[3], roots[0]));
}

test "AOT何文字目のdispatch例外は文言を保持し次の呼出しへ回復する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const command = @intFromEnum(aot_builtin.Command.codepoint_find);
    roots[0] = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    lnako_aot_exception_take(&roots[3]);
    const null_message = try valueUtf16Alloc(&runtime, roots[3]);
    defer runtime.allocator.free(null_message);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_message);

    roots[0] = staticStringValue("abc");
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));

    roots[0] = .{};
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    lnako_aot_exception_take(&roots[3]);
    const undefined_message = try valueUtf16Alloc(&runtime, roots[3]);
    defer runtime.allocator.free(undefined_message);
    const expected_undefined = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_undefined);
    try std.testing.expectEqualSlices(u16, expected_undefined, undefined_message);

    roots[0] = staticStringValue("abc");
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));
}

test "AOT加算系命令はparseFloatとBigIntとJavaScript加算を分離する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    roots[0] = staticStringValue("1.5rest");
    roots[1] = numberValue(2);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.add_parsed));
    try std.testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast(roots[2].payload)));
    roots[3] = staticStringValue("2");
    roots[4] = try active_runtime.?.createBigInt("3n");
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.add_parsed));
    const bigint_text = try roots[5].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(bigint_text);
    try std.testing.expectEqualStrings("5", bigint_text);
    const sum_arguments = [_]Value{ numberValue(1), staticStringValue("2.5x"), numberValue(3) };
    lnako_aot_builtin_call(&roots[6], &sum_arguments, sum_arguments.len, @intFromEnum(aot_builtin.Command.sum_parsed));
    try std.testing.expectEqual(@as(f64, 6.5), @as(f64, @bitCast(roots[6].payload)));
    roots[7] = try active_runtime.?.createArray(&.{ numberValue(1), staticStringValue("x"), numberValue(2) });
    const array_sum_arguments = [_]Value{ roots[7], numberValue(100) };
    lnako_aot_builtin_call(&roots[8], &array_sum_arguments, array_sum_arguments.len, @intFromEnum(aot_builtin.Command.sum_parsed));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(roots[8].payload)));
    const sequential_arguments = [_]Value{ staticStringValue("a"), staticStringValue("b"), staticStringValue("c") };
    lnako_aot_builtin_call(&roots[9], &sequential_arguments, sequential_arguments.len, @intFromEnum(aot_builtin.Command.sequential_add));
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'c', 'a' }, roots[9].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[10], null, 0, @intFromEnum(aot_builtin.Command.sequential_add));
    lnako_aot_builtin_call(&roots[11], null, 0, @intFromEnum(aot_builtin.Command.sequential_add));
    try std.testing.expectEqual(roots[10].payload, roots[11].payload);
}

test "AOT文字コード命令は補助平面と配列と動的例外文言を扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(0x1f600);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.chr));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, roots[1].object().?.payload.utf16_string);

    roots[2] = try active_runtime.?.createArray(&.{ numberValue(65), numberValue(0x1f600), numberValue(66) });
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.chr));
    const characters = roots[3].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), characters.len);
    try std.testing.expectEqualSlices(u16, &.{'A'}, characters[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, characters[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'B'}, characters[2].object().?.payload.utf16_string);

    roots[4] = staticStringValue("😀");
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.asc));
    try std.testing.expectEqual(@as(f64, 0x1f600), @as(f64, @bitCast(roots[5].payload)));
    roots[6] = try active_runtime.?.createArray(&.{ staticStringValue("A"), staticStringValue("😀"), staticStringValue(""), .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(12) });
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.asc));
    const codes = roots[7].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 5), codes.len);
    try std.testing.expectEqualSlices(f64, &.{ 65, 0x1f600, 0, 110, 49 }, &.{ valueToNumber(codes[0]), valueToNumber(codes[1]), valueToNumber(codes[2]), valueToNumber(codes[3]), valueToNumber(codes[4]) });

    roots[8] = numberValue(-1);
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[8]), 1, @intFromEnum(aot_builtin.Command.chr));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const message = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("Invalid code point -1", message);
}

test "AOT文字列挿入検索はUnicode scalar位置と小数開始値を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const insert_arguments = [_]Value{ staticStringValue("A😀B"), numberValue(2), staticStringValue("X") };
    lnako_aot_builtin_call(&roots[0], &insert_arguments, insert_arguments.len, @intFromEnum(aot_builtin.Command.string_insert));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'X', 0xd83d, 0xde00, 'B' }, roots[0].object().?.payload.utf16_string);
    const nan_position_arguments = [_]Value{ staticStringValue("ABC"), staticStringValue("2rest"), staticStringValue("X") };
    lnako_aot_builtin_call(&roots[1], &nan_position_arguments, nan_position_arguments.len, @intFromEnum(aot_builtin.Command.string_insert));
    try std.testing.expectEqualSlices(u16, &.{ 'X', 'A', 'B', 'C' }, roots[1].object().?.payload.utf16_string);

    const fractional_search = [_]Value{ staticStringValue("A😀B😀"), numberValue(2.9), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[2], &fractional_search, fractional_search.len, @intFromEnum(aot_builtin.Command.string_search));
    try std.testing.expectEqual(@as(f64, 2.9), valueToNumber(roots[2]));
    const nan_search = [_]Value{ staticStringValue("A😀B😀"), staticStringValue("2rest"), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[3], &nan_search, nan_search.len, @intFromEnum(aot_builtin.Command.string_search));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[3]));
}

test "AOT出現命令は文字列検索と配列のSameValueZeroを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    active_runtime = runtime;
    active_runtime.?.next_collection = 1;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const nan = numberValue(std.math.nan(f64));
    const minus_zero = numberValue(-0.0);
    const undefined_value: Value = .{};
    const null_value: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[0] = try active_runtime.?.createArray(&.{ nan, numberValue(0), undefined_value, null_value, staticStringValue("1") });
    const array_cases = [_]struct { needle: Value, expected: bool }{
        .{ .needle = numberValue(std.math.nan(f64)), .expected = true },
        .{ .needle = minus_zero, .expected = true },
        .{ .needle = undefined_value, .expected = true },
        .{ .needle = null_value, .expected = true },
        .{ .needle = numberValue(1), .expected = false },
        .{ .needle = staticStringValue("1"), .expected = true },
    };
    for (array_cases, 1..) |case, index| {
        const arguments = [_]Value{ roots[0], case.needle };
        lnako_aot_builtin_call(&roots[index], &arguments, arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
        try std.testing.expectEqual(case.expected, roots[index].payload != 0);
    }

    roots[8] = try active_runtime.?.createArray(&.{numberValue(1)});
    roots[9] = try active_runtime.?.createArray(&.{roots[8]});
    const same_array_arguments = [_]Value{ roots[9], roots[8] };
    lnako_aot_builtin_call(&roots[7], &same_array_arguments, same_array_arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
    try std.testing.expect(roots[7].payload != 0);

    const string_cases = [_]struct { source: Value, needle: Value, expected: bool }{
        .{ .source = staticStringValue("A😀B"), .needle = staticStringValue("😀"), .expected = true },
        .{ .source = staticStringValue("A😀B"), .needle = staticStringValue(""), .expected = true },
        .{ .source = staticStringValue("A\x00B"), .needle = staticStringValue("\x00"), .expected = true },
        .{ .source = .{ .tag = @intFromEnum(Tag.null_value) }, .needle = staticStringValue("null"), .expected = true },
        .{ .source = .{}, .needle = staticStringValue("undefined"), .expected = true },
    };
    for (string_cases) |case| {
        const arguments = [_]Value{ case.source, case.needle };
        lnako_aot_builtin_call(&roots[6], &arguments, arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
        try std.testing.expectEqual(case.expected, roots[6].payload != 0);
    }
}

test "AOT配列結合と配列検索は公式のArray境界とGCを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    active_runtime = runtime;
    active_runtime.?.next_collection = 1;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[1] = try active_runtime.?.createArray(&.{ numberValue(4), numberValue(5) });
    roots[2] = try active_runtime.?.createArray(&.{});
    try active_runtime.?.indexSet(roots[2], numberValue(0), roots[2]);
    roots[0] = try active_runtime.?.createArray(&.{
        numberValue(1),
        .{ .tag = @intFromEnum(Tag.null_value) },
        .{},
        numberValue(3),
        roots[1],
        roots[2],
    });
    const join_arguments = [_]Value{ roots[0], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[3], &join_arguments, join_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '1', '|', '|', '|', '3', '|', '4', ',', '5', '|' }, roots[3].object().?.payload.utf16_string);
    const only_join_arguments = [_]Value{roots[0]};
    lnako_aot_builtin_call(&roots[4], &only_join_arguments, only_join_arguments.len, @intFromEnum(aot_builtin.Command.array_join_only));
    try std.testing.expectEqualSlices(u16, &.{ '1', '3', '4', ',', '5' }, roots[4].object().?.payload.utf16_string);

    const non_array_arguments = [_]Value{ staticStringValue("A\n😀\n"), staticStringValue("-") };
    lnako_aot_builtin_call(&roots[5], &non_array_arguments, non_array_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ 'A', '-', 0xd83d, 0xde00, '-' }, roots[5].object().?.payload.utf16_string);
    roots[6] = try active_runtime.?.createString(&.{ 'A', 0xd800, 0, 'B' });
    const lone_surrogate_arguments = [_]Value{ roots[6], staticStringValue("-") };
    lnako_aot_builtin_call(&roots[7], &lone_surrogate_arguments, lone_surrogate_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, roots[6].object().?.payload.utf16_string, roots[7].object().?.payload.utf16_string);

    roots[8] = try active_runtime.?.createBigInt("12n");
    roots[9] = try active_runtime.?.createDictionary(&.{});
    roots[10] = try active_runtime.?.createArray(&.{ roots[8], roots[9], .{ .tag = @intFromEnum(Tag.null_value) }, .{} });
    const object_values_arguments = [_]Value{ roots[10], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[11], &object_values_arguments, object_values_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '|', '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', '|', '|' }, roots[11].object().?.payload.utf16_string);
    const bigint_separator_arguments = [_]Value{ roots[1], roots[8] };
    lnako_aot_builtin_call(&roots[12], &bigint_separator_arguments, bigint_separator_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '4', '1', '2', '5' }, roots[12].object().?.payload.utf16_string);
    lnako_aot_function_new(&roots[18], testAotFunction, 1, null, 0);
    roots[19] = try active_runtime.?.createArray(&.{roots[18]});
    const function_value_arguments = [_]Value{ roots[19], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[12], &function_value_arguments, function_value_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n', ' ', '(', ')', ' ', '{', ' ', '[', 'n', 'a', 't', 'i', 'v', 'e', ' ', 'c', 'o', 'd', 'e', ']', ' ', '}' }, roots[12].object().?.payload.utf16_string);

    const sparse = try active_runtime.?.createArray(&.{});
    roots[13] = sparse;
    try active_runtime.?.indexSet(sparse, numberValue(2), numberValue(3));
    const sparse_join_arguments = [_]Value{ roots[13], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[14], &sparse_join_arguments, sparse_join_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '|', '|', '3' }, roots[14].object().?.payload.utf16_string);

    const nan = numberValue(std.math.nan(f64));
    roots[15] = try active_runtime.?.createArray(&.{ nan, numberValue(0), staticStringValue("1"), numberValue(1), .{ .tag = @intFromEnum(Tag.null_value) }, .{}, roots[1] });
    roots[17] = try active_runtime.?.createArray(&.{ numberValue(4), numberValue(5) });
    const search_cases = [_]struct { needle: Value, expected: f64 }{
        .{ .needle = nan, .expected = -1 },
        .{ .needle = numberValue(-0.0), .expected = 1 },
        .{ .needle = staticStringValue("1"), .expected = 2 },
        .{ .needle = numberValue(1), .expected = 3 },
        .{ .needle = .{ .tag = @intFromEnum(Tag.null_value) }, .expected = 4 },
        .{ .needle = .{}, .expected = 5 },
        .{ .needle = roots[1], .expected = 6 },
        .{ .needle = roots[17], .expected = -1 },
    };
    var search_result: Value = .{};
    for (search_cases) |case| {
        const arguments = [_]Value{ roots[15], case.needle };
        lnako_aot_builtin_call(&search_result, &arguments, arguments.len, @intFromEnum(aot_builtin.Command.array_search));
        try std.testing.expectEqual(case.expected, valueToNumber(search_result));
    }
    const non_array_search = [_]Value{ staticStringValue("abc"), staticStringValue("a") };
    lnako_aot_builtin_call(&roots[16], &non_array_search, non_array_search.len, @intFromEnum(aot_builtin.Command.array_search));
    try std.testing.expectEqual(@as(f64, -1), valueToNumber(roots[16]));
}

test "AOT配列変更命令はspliceの数値化と辞書のtruthy規則を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    active_runtime = runtime;
    active_runtime.?.next_collection = 1;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2), numberValue(3) });
    const insert_arguments = [_]Value{ roots[0], numberValue(-1.5), numberValue(9) };
    lnako_aot_builtin_call(&roots[1], &insert_arguments, insert_arguments.len, @intFromEnum(aot_builtin.Command.array_insert));
    try std.testing.expectEqual(@as(usize, 0), roots[1].object().?.payload.array.items.len);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2), numberValue(9), numberValue(3) }, roots[0].object().?.payload.array.items);

    roots[2] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(4) });
    roots[3] = try active_runtime.?.createArray(&.{ numberValue(2), numberValue(3) });
    const many_arguments = [_]Value{ roots[2], numberValue(1), roots[3] };
    lnako_aot_builtin_call(&roots[4], &many_arguments, many_arguments.len, @intFromEnum(aot_builtin.Command.array_insert_many));
    try std.testing.expectEqual(roots[2].payload, roots[4].payload);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2), numberValue(3), numberValue(4) }, roots[2].object().?.payload.array.items);

    // The upstream loop would never terminate when a and b are the same
    // array.  The native runtime copies b before mutating a.
    roots[5] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    const self_arguments = [_]Value{ roots[5], numberValue(1), roots[5] };
    lnako_aot_builtin_call(&roots[6], &self_arguments, self_arguments.len, @intFromEnum(aot_builtin.Command.array_insert_many));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(1), numberValue(2), numberValue(2) }, roots[5].object().?.payload.array.items);

    roots[7] = try active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    const take_arguments = [_]Value{ roots[7], staticStringValue("1.9"), staticStringValue("2.9") };
    lnako_aot_builtin_call(&roots[8], &take_arguments, take_arguments.len, @intFromEnum(aot_builtin.Command.array_take));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[8].object().?.payload.array.items);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(0), numberValue(3) }, roots[7].object().?.payload.array.items);

    roots[9] = try active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    roots[10] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(2) });
    const range_arguments = [_]Value{ roots[9], roots[10] };
    lnako_aot_builtin_call(&roots[11], &range_arguments, range_arguments.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[11].object().?.payload.array.items);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(0), numberValue(3) }, roots[9].object().?.payload.array.items);

    roots[12] = try active_runtime.?.createDictionary(&.{
        staticStringValue("zero"),  numberValue(0),
        staticStringValue("yes"),   numberValue(7),
        staticStringValue("false"), .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 },
    });
    const zero_key = [_]Value{ roots[12], staticStringValue("zero") };
    lnako_aot_builtin_call(&roots[13], &zero_key, zero_key.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[13].tag)));
    try std.testing.expectEqual(@as(usize, 3), roots[12].object().?.payload.dictionary.items.len);
    const yes_key = [_]Value{ roots[12], staticStringValue("yes") };
    lnako_aot_builtin_call(&roots[14], &yes_key, yes_key.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[14]));
    try std.testing.expectEqual(@as(usize, 2), roots[12].object().?.payload.dictionary.items.len);

    roots[15] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    const pop_arguments = [_]Value{roots[15]};
    lnako_aot_builtin_call(&roots[16], &pop_arguments, pop_arguments.len, @intFromEnum(aot_builtin.Command.array_pop));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[16]));
    const push_arguments = [_]Value{ roots[15], numberValue(3) };
    lnako_aot_builtin_call(&roots[17], &push_arguments, push_arguments.len, @intFromEnum(aot_builtin.Command.array_push));
    try std.testing.expectEqual(roots[15].payload, roots[17].payload);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(3) }, roots[15].object().?.payload.array.items);
    lnako_aot_builtin_call(&roots[18], &push_arguments, push_arguments.len, @intFromEnum(aot_builtin.Command.array_push));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(3), numberValue(3) }, roots[15].object().?.payload.array.items);

    roots[19] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    roots[20] = try active_runtime.?.createBigInt("1n");
    const bigint_insert = [_]Value{ roots[19], roots[20], numberValue(9) };
    lnako_aot_builtin_call(&roots[21], &bigint_insert, bigint_insert.len, @intFromEnum(aot_builtin.Command.array_insert));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);
    const bigint_take = [_]Value{ roots[19], numberValue(0), roots[20] };
    lnako_aot_builtin_call(&roots[21], &bigint_take, bigint_take.len, @intFromEnum(aot_builtin.Command.array_take));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);

    const null_index: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    const null_cut = [_]Value{ roots[19], null_index };
    lnako_aot_builtin_call(&roots[21], &null_cut, null_cut.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);

    roots[23] = try active_runtime.?.createArray(&.{});
    const empty_pop = [_]Value{roots[23]};
    lnako_aot_builtin_call(&roots[24], &empty_pop, empty_pop.len, @intFromEnum(aot_builtin.Command.array_pop));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[24].tag)));
}

test "AOT配列複製範囲参照と配列足は深さと参照を公式どおり分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{.{}} ** 36;
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try active_runtime.?.createArray(&.{ numberValue(1), try active_runtime.?.createArray(&.{numberValue(2)}) });
    roots[1] = try deepCloneBuiltin(&active_runtime.?, roots[0]);
    try active_runtime.?.indexSet(roots[1], numberValue(1), try active_runtime.?.createArray(&.{numberValue(9)}));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[0].object().?.payload.array.items[1].object().?.payload.array.items[0]));
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(roots[1].object().?.payload.array.items[1].object().?.payload.array.items[0]));
    try std.testing.expectError(error.CannotSerializeBigInt, deepCloneBuiltin(&active_runtime.?, try active_runtime.?.createBigInt("1n")));

    roots[2] = try active_runtime.?.createArray(&.{ numberValue(0), roots[0], numberValue(3) });
    roots[3] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[2], try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(1) }));
    try std.testing.expect(roots[3].object().?.payload.array.items[0].payload != roots[2].object().?.payload.array.items[1].payload);
    roots[4] = try referenceBuiltin(&active_runtime.?, roots[2], numberValue(1));
    try std.testing.expectEqual(roots[2].object().?.payload.array.items[1].payload, roots[4].payload);
    roots[5] = try referenceBuiltin(&active_runtime.?, staticStringValue("A😀B"), numberValue(1));
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, roots[5].object().?.payload.utf16_string);
    roots[6] = try referenceBuiltin(&active_runtime.?, roots[2], try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(2) }));
    try std.testing.expectEqual(@as(usize, 2), roots[6].object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[2].object().?.payload.array.items[1].payload, roots[6].object().?.payload.array.items[0].payload);
    roots[7] = try active_runtime.?.createDictionary(&.{ staticStringValue("x"), numberValue(7) });
    roots[8] = try referenceBuiltin(&active_runtime.?, roots[7], staticStringValue("x"));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[8]));
    roots[9] = try arrayAddBuiltin(&active_runtime.?, roots[0], try active_runtime.?.createArray(&.{ numberValue(3), numberValue(4) }));
    try std.testing.expectEqual(@as(usize, 4), roots[9].object().?.payload.array.items.len);
    try std.testing.expect(roots[9].payload != roots[0].payload);

    try std.testing.expectError(error.InvalidJsonCloneValue, deepCloneBuiltin(&active_runtime.?, .{}));
    roots[10] = try active_runtime.?.createArray(&.{.{}});
    roots[11] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), numberValue(0) });
    roots[12] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[10], roots[11]);
    try std.testing.expectEqual(Tag.null_value, @as(Tag, @enumFromInt(roots[12].object().?.payload.array.items[0].tag)));
    roots[13] = try referenceBuiltin(&active_runtime.?, staticStringValue("ABC"), numberValue(1.9));
    try std.testing.expectEqualSlices(u16, &.{'B'}, roots[13].object().?.payload.utf16_string);
    roots[14] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1e100), staticStringValue("末尾"), numberValue(1e100) });
    roots[15] = try referenceBuiltin(&active_runtime.?, staticStringValue("ABC"), roots[14]);
    try std.testing.expectEqual(@as(usize, 0), roots[15].object().?.payload.utf16_string.len);

    roots[16] = try active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    roots[17] = try active_runtime.?.createBigInt("0n");
    roots[18] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[17] });
    roots[19] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[18]);
    try std.testing.expectEqual(@as(usize, 1), roots[19].object().?.payload.array.items.len);
    roots[20] = try active_runtime.?.createBigInt("1n");
    roots[21] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[20] });
    roots[22] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[21]);
    try std.testing.expectEqual(@as(usize, 2), roots[22].object().?.payload.array.items.len);
    roots[23] = try active_runtime.?.createBigInt("-2n");
    roots[24] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[23] });
    roots[25] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[24]);
    try std.testing.expectEqual(@as(usize, 3), roots[25].object().?.payload.array.items.len);
    roots[26] = try active_runtime.?.createBigInt("9007199254740993n");
    roots[27] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[26] });
    roots[28] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[27]);
    try std.testing.expectEqual(@as(usize, 4), roots[28].object().?.payload.array.items.len);
    roots[29] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), roots[20], staticStringValue("末尾"), numberValue(2) });
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[29])).tag)));
    roots[30] = try active_runtime.?.createBigInt("-9007199254740993n");
    roots[31] = try active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[30] });
    roots[32] = try arrayRangeCopyBuiltin(&active_runtime.?, roots[16], roots[31]);
    try std.testing.expectEqual(@as(usize, 0), roots[32].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(try referenceBuiltin(&active_runtime.?, roots[16], roots[17])));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&active_runtime.?, roots[16], roots[20])));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&active_runtime.?, roots[16], roots[23])).tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&active_runtime.?, roots[16], roots[26])).tag)));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(try referenceBuiltin(&active_runtime.?, roots[16], staticStringValue("0"))));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&active_runtime.?, roots[16], staticStringValue("1"))));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(try referenceBuiltin(&active_runtime.?, roots[16], staticStringValue("length"))));
    const invalid_keys = [_]Value{
        staticStringValue("01"),
        staticStringValue("-0"),
        staticStringValue("-1"),
        staticStringValue("1.0"),
        staticStringValue(""),
        staticStringValue("4294967295"),
        staticStringValue("900719925474099999999999999"),
    };
    for (invalid_keys) |key| {
        try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&active_runtime.?, roots[16], key)).tag)));
    }
    try std.testing.expectEqual(@as(?usize, 0), tablePropertyIndex(&.{'0'}));
    try std.testing.expectEqual(@as(?usize, 4294967294), tablePropertyIndex(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '4' }));
    try std.testing.expectEqual(@as(?usize, null), tablePropertyIndex(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '5' }));
}

test "AOT参照の配列文字列添字はGC後も配列とキーを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = 1;
    roots[0] = try runtime.createArray(&.{ numberValue(10), numberValue(20) });
    roots[1] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    roots[2] = try runtime.createString(&.{'1'});
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = runtime.collect();
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[1])));
    try std.testing.expectEqual(@as(f64, 20), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[2])));
}

fn referenceAotArrayStringKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 2;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{ numberValue(1), numberValue(2) });
    roots[1] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    const result = try referenceBuiltin(&runtime, roots[0], roots[1]);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(result));
}

test "AOT参照の配列文字列添字は割当失敗でも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceAotArrayStringKeyAllocationTest, .{});
}

fn aotBigintRangeAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 7;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(0), numberValue(1), numberValue(2) });
    roots[1] = try runtime.createBigInt("1n");
    roots[2] = try runtime.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[1] });
    runtime.next_collection = runtime.object_count;
    roots[3] = try arrayRangeCopyBuiltin(&runtime, roots[0], roots[2]);
    try std.testing.expectEqual(@as(usize, 2), roots[3].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[1])));
    roots[4] = try runtime.createString(&.{ 'A', 'B', 'C' });
    roots[5] = try runtime.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[1] });
    runtime.next_collection = runtime.object_count;
    roots[6] = try referenceBuiltin(&runtime, roots[4], roots[5]);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, roots[6].object().?.payload.utf16_string);
}

test "AOT BigInt範囲終端は割当失敗とGCストレスでも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotBigintRangeAllocationTest, .{});
}

fn expectAotReferenceStringRangeMessage(runtime: *Runtime, index: Value, expected: []const u8) !void {
    _ = referenceBuiltin(runtime, staticStringValue("ABC"), index) catch |failure| {
        try std.testing.expectEqual(error.InvalidStringRange, failure);
        const message = runtime.takeException();
        const actual = try valueUtf16Alloc(runtime, message);
        defer runtime.allocator.free(actual);
        const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
        defer runtime.allocator.free(expected_units);
        try std.testing.expectEqualSlices(u16, expected_units, actual);
        return;
    };
    try std.testing.expect(false);
}

test "AOT参照の文字列範囲エラーはJSON値・UTF-16・保留例外を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    try expectAotReferenceStringRangeMessage(&active_runtime.?, .{}, "『参照』で文字列型の範囲指定(undefined)が不正です。");
    roots[0] = try active_runtime.?.createString(&.{ 'A', 'B', 'C' });
    try expectAotReferenceStringRangeMessage(&active_runtime.?, roots[0], "『参照』で文字列型の範囲指定(\"ABC\")が不正です。");
    roots[1] = try active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    try expectAotReferenceStringRangeMessage(&active_runtime.?, roots[1], "『参照』で文字列型の範囲指定([1,2])が不正です。");
    roots[2] = try active_runtime.?.createDictionary(&.{});
    try expectAotReferenceStringRangeMessage(&active_runtime.?, roots[2], "『参照』で文字列型の範囲指定({})が不正です。");
    roots[3] = try active_runtime.?.createString(&.{0xd800});
    try expectAotReferenceStringRangeMessage(&active_runtime.?, roots[3], "『参照』で文字列型の範囲指定(\"\\ud800\")が不正です。");
    roots[4] = try active_runtime.?.createFunction(testAotFunction, 1, &.{});
    try expectAotReferenceStringRangeMessage(&active_runtime.?, roots[4], "『参照』で文字列型の範囲指定(undefined)が不正です。");

    roots[5] = try active_runtime.?.createBigInt("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, referenceBuiltin(&active_runtime.?, staticStringValue("ABC"), roots[5]));
    roots[6] = try active_runtime.?.createDictionary(&.{});
    try active_runtime.?.indexSet(roots[6], staticStringValue("self"), roots[6]);
    const circular_args = [_]Value{ staticStringValue("ABC"), roots[6] };
    var result: Value = .{};
    lnako_aot_builtin_call(&result, &circular_args, circular_args.len, @intFromEnum(aot_builtin.Command.reference));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    const circular_message = active_runtime.?.takeException();
    const circular_units = try valueUtf16Alloc(&active_runtime.?, circular_message);
    defer active_runtime.?.allocator.free(circular_units);
    try std.testing.expect(std.mem.startsWith(u16, circular_units, &.{ 'C', 'o', 'n', 'v' }));

    const null_args = [_]Value{ staticStringValue("ABC"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_builtin_call(&result, &null_args, null_args.len, @intFromEnum(aot_builtin.Command.reference));
    try std.testing.expect(active_runtime.?.has_pending_exception);
    const null_message = active_runtime.?.takeException();
    const null_units = try valueUtf16Alloc(&active_runtime.?, null_message);
    defer active_runtime.?.allocator.free(null_units);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(active_runtime.?.allocator, "Cannot read properties of null (reading '先頭')");
    defer active_runtime.?.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_units);
}

test "AOT文字列連結分解反復出現命令は公式の型変換を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try active_runtime.?.createArray(&.{numberValue(1)});
    const append_arguments = [_]Value{ roots[0], numberValue(2) };
    lnako_aot_builtin_call(&roots[1], &append_arguments, append_arguments.len, @intFromEnum(aot_builtin.Command.append));
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(@as(usize, 2), roots[0].object().?.payload.array.items.len);

    const line_arguments = [_]Value{ staticStringValue("a"), staticStringValue("b") };
    lnako_aot_builtin_call(&roots[2], &line_arguments, line_arguments.len, @intFromEnum(aot_builtin.Command.append_line));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', '\n' }, roots[2].object().?.payload.utf16_string);
    const join_arguments = [_]Value{ staticStringValue("a"), numberValue(1), .{ .tag = @intFromEnum(Tag.null_value) }, .{} };
    lnako_aot_builtin_call(&roots[3], &join_arguments, join_arguments.len, @intFromEnum(aot_builtin.Command.concat_join));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '1' }, roots[3].object().?.payload.utf16_string);

    const explode_arguments = [_]Value{staticStringValue("A😀B")};
    lnako_aot_builtin_call(&roots[4], &explode_arguments, explode_arguments.len, @intFromEnum(aot_builtin.Command.explode));
    const characters = roots[4].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), characters.len);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, characters[1].object().?.payload.utf16_string);

    const refrain_arguments = [_]Value{ staticStringValue("x"), numberValue(2.1) };
    lnako_aot_builtin_call(&roots[5], &refrain_arguments, refrain_arguments.len, @intFromEnum(aot_builtin.Command.refrain));
    try std.testing.expectEqualSlices(u16, &.{ 'x', 'x', 'x' }, roots[5].object().?.payload.utf16_string);
    const empty_count_arguments = [_]Value{ staticStringValue(""), staticStringValue("") };
    lnako_aot_builtin_call(&roots[6], &empty_count_arguments, empty_count_arguments.len, @intFromEnum(aot_builtin.Command.occurrence_count));
    try std.testing.expectEqual(@as(f64, -1), valueToNumber(roots[6]));
    const emoji_count_arguments = [_]Value{ staticStringValue("😀"), staticStringValue("") };
    lnako_aot_builtin_call(&roots[7], &emoji_count_arguments, emoji_count_arguments.len, @intFromEnum(aot_builtin.Command.occurrence_count));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[7]));
}

test "AOT部分文字列命令は数値小数と文字列小数を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const numeric_mid = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[0], &numeric_mid, numeric_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 'B', 'C' }, roots[0].object().?.payload.utf16_string);
    const string_mid = [_]Value{ staticStringValue("A😀BCD"), staticStringValue("2.9"), staticStringValue("2.9") };
    lnako_aot_builtin_call(&roots[1], &string_mid, string_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 'B' }, roots[1].object().?.payload.utf16_string);
    const zero_mid = [_]Value{ staticStringValue("ABCDE"), numberValue(0), numberValue(2) };
    lnako_aot_builtin_call(&roots[2], &zero_mid, zero_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqual(@as(usize, 0), roots[2].object().?.payload.utf16_string.len);
    const left_arguments = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[3], &left_arguments, left_arguments.len, @intFromEnum(aot_builtin.Command.substring_left));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xde00 }, roots[3].object().?.payload.utf16_string);
    const right_arguments = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[4], &right_arguments, right_arguments.len, @intFromEnum(aot_builtin.Command.substring_right));
    try std.testing.expectEqualSlices(u16, &.{ 'B', 'C', 'D' }, roots[4].object().?.payload.utf16_string);
}

test "AOT文字列分割削除はUTF-16空区切りとsplice位置を扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const split_arguments = [_]Value{ staticStringValue("A😀B😀C"), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[0], &split_arguments, split_arguments.len, @intFromEnum(aot_builtin.Command.split_all));
    const parts = roots[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualSlices(u16, &.{'A'}, parts[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'B'}, parts[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'C'}, parts[2].object().?.payload.utf16_string);
    const empty_split = [_]Value{ staticStringValue("😀"), staticStringValue("") };
    lnako_aot_builtin_call(&roots[1], &empty_split, empty_split.len, @intFromEnum(aot_builtin.Command.split_all));
    const units = roots[1].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, units[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{0xde00}, units[1].object().?.payload.utf16_string);

    lnako_aot_builtin_call(&roots[2], &empty_split, empty_split.len, @intFromEnum(aot_builtin.Command.split_first));
    const first_parts = roots[2].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), first_parts.len);
    try std.testing.expectEqual(@as(usize, 0), first_parts[0].object().?.payload.utf16_string.len);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, first_parts[1].object().?.payload.utf16_string);

    const remove_arguments = [_]Value{ staticStringValue("ABCDE"), numberValue(-1), numberValue(2) };
    lnako_aot_builtin_call(&roots[3], &remove_arguments, remove_arguments.len, @intFromEnum(aot_builtin.Command.string_remove));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B', 'C' }, roots[3].object().?.payload.utf16_string);
}

test "AOTトリム命令はECMAScript空白だけを左右別に除去する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    const source = [_]Value{staticStringValue("﻿　\t A  \u{2029}")};
    lnako_aot_builtin_call(&roots[0], &source, source.len, @intFromEnum(aot_builtin.Command.trim_both));
    try std.testing.expectEqualSlices(u16, &.{'A'}, roots[0].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[1], &source, source.len, @intFromEnum(aot_builtin.Command.trim_right));
    try std.testing.expectEqualSlices(u16, &.{ 0xfeff, 0x3000, '\t', ' ', 'A' }, roots[1].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[2], &source, source.len, @intFromEnum(aot_builtin.Command.trim_left));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', 0x00a0, 0x2029 }, roots[2].object().?.payload.utf16_string);
}

test "AOT置換命令は全置換の空検索と単置換の置換パターンを分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    const empty_all = [_]Value{ staticStringValue("abc"), staticStringValue(""), staticStringValue("-") };
    lnako_aot_builtin_call(&roots[0], &empty_all, empty_all.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '-', 'b', '-', 'c' }, roots[0].object().?.payload.utf16_string);
    const special_first = [_]Value{ staticStringValue("abc"), staticStringValue("b"), staticStringValue("[$$][$&][$`][$']") };
    lnako_aot_builtin_call(&roots[1], &special_first, special_first.len, @intFromEnum(aot_builtin.Command.replace_first));
    const expected = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "a[$][b][a][c]c");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u16, expected, roots[1].object().?.payload.utf16_string);
    const literal_all = [_]Value{ staticStringValue("abc"), staticStringValue("b"), staticStringValue("[$&]") };
    lnako_aot_builtin_call(&roots[2], &literal_all, literal_all.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '[', '$', '&', ']', 'c' }, roots[2].object().?.payload.utf16_string);
    const undefined_separator = [_]Value{ staticStringValue("xundefinedy"), .{}, staticStringValue("z") };
    lnako_aot_builtin_call(&roots[3], &undefined_separator, undefined_separator.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'x', 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd', 'y' }, roots[3].object().?.payload.utf16_string);
    const undefined_join = [_]Value{ staticStringValue("a-a"), staticStringValue("a"), .{} };
    lnako_aot_builtin_call(&roots[4], &undefined_join, undefined_join.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ ',', '-', ',' }, roots[4].object().?.payload.utf16_string);
    const undefined_first_replacement = [_]Value{ staticStringValue("x-x"), staticStringValue("x"), .{} };
    lnako_aot_builtin_call(&roots[5], &undefined_first_replacement, undefined_first_replacement.len, @intFromEnum(aot_builtin.Command.replace_first));
    try std.testing.expectEqualSlices(u16, &.{ 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd', '-', 'x' }, roots[5].object().?.payload.utf16_string);
}

test "AOT幅変換は英数記号とカナの合成順序および公式の濁点端挙動を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const ascii_full = [_]Value{staticStringValue("Az09!")};
    lnako_aot_builtin_call(&roots[0], &ascii_full, ascii_full.len, @intFromEnum(aot_builtin.Command.ascii_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0xff5a, 0xff10, 0xff19, '!' }, roots[0].object().?.payload.utf16_string);
    const symbols_full = [_]Value{staticStringValue("A 1!")};
    lnako_aot_builtin_call(&roots[1], &symbols_full, symbols_full.len, @intFromEnum(aot_builtin.Command.ascii_symbol_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0x3000, 0xff11, 0xff01 }, roots[1].object().?.payload.utf16_string);
    const symbols_half = [_]Value{staticStringValue("Ａ　１！")};
    lnako_aot_builtin_call(&roots[2], &symbols_half, symbols_half.len, @intFromEnum(aot_builtin.Command.ascii_symbol_half_width));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', '1', '!' }, roots[2].object().?.payload.utf16_string);

    const kana_full = [_]Value{staticStringValue("ｶﾞｯﾂ")};
    lnako_aot_builtin_call(&roots[3], &kana_full, kana_full.len, @intFromEnum(aot_builtin.Command.katakana_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0x30ac, 0x30c3, 0x30c5 }, roots[3].object().?.payload.utf16_string);
    const kana_half = [_]Value{staticStringValue("ガッツ")};
    lnako_aot_builtin_call(&roots[4], &kana_half, kana_half.len, @intFromEnum(aot_builtin.Command.katakana_half_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff76, 0xff9e, 0xff6f, 0xff82 }, roots[4].object().?.payload.utf16_string);
    const odd_voiced = [_]Value{staticStringValue("ｶﾞﾊﾟﾞﾟ")};
    lnako_aot_builtin_call(&roots[5], &odd_voiced, odd_voiced.len, @intFromEnum(aot_builtin.Command.katakana_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0x30ac, 0x30d1, 0x30d1 }, roots[5].object().?.payload.utf16_string);

    const full = [_]Value{staticStringValue("A ｶﾞ!")};
    lnako_aot_builtin_call(&roots[6], &full, full.len, @intFromEnum(aot_builtin.Command.full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0x3000, 0x30ac, 0xff01 }, roots[6].object().?.payload.utf16_string);
    const half = [_]Value{staticStringValue("Ａ　ガ！")};
    lnako_aot_builtin_call(&roots[7], &half, half.len, @intFromEnum(aot_builtin.Command.half_width));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', 0xff76, 0xff9e, '!' }, roots[7].object().?.payload.utf16_string);
}

test "AOT幅変換のカナ系は生レシーバ分岐と保留例外を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    const rt = &active_runtime.?;
    var roots = [_]Value{.{}} ** 8;
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    rt.next_collection = 1;

    roots[0] = try rt.createArray(&.{});
    roots[1] = try rt.createArray(&.{numberValue(1)});
    roots[2] = try rt.createDictionary(&.{ staticStringValue("length"), numberValue(1) });
    roots[3] = try rt.createDictionary(&.{});
    try std.testing.expectEqualSlices(u16, &.{}, (try kanaMapBuiltin(rt, roots[0], true)).object().?.payload.utf16_string);
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(rt, roots[1], true));
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(rt, roots[2], true));
    try std.testing.expectEqualSlices(u16, &.{}, (try kanaMapBuiltin(rt, roots[3], true)).object().?.payload.utf16_string);
    try std.testing.expectError(error.KatakanaFullWidthLengthNull, kanaMapBuiltin(rt, .{ .tag = @intFromEnum(Tag.null_value) }, true));
    try std.testing.expectError(error.KatakanaHalfWidthSplitUndefined, kanaMapBuiltin(rt, .{}, false));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, kanaMapBuiltin(rt, numberValue(1), false));

    const failing = [_]Value{numberValue(1)};
    lnako_aot_builtin_call(&roots[4], &failing, failing.len, @intFromEnum(aot_builtin.Command.half_width));
    const failure_units = try valueUtf16Alloc(rt, rt.takeException());
    defer rt.allocator.free(failure_units);
    try std.testing.expectEqualSlices(u16, &.{ 's', '.', 's', 'p', 'l', 'i', 't', ' ', 'i', 's', ' ', 'n', 'o', 't', ' ', 'a', ' ', 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n' }, failure_units);
    const succeeding = [_]Value{staticStringValue("ガ")};
    lnako_aot_builtin_call(&roots[5], &succeeding, succeeding.len, @intFromEnum(aot_builtin.Command.half_width));
    try std.testing.expect(!rt.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 0xff76, 0xff9e }, roots[5].object().?.payload.utf16_string);
}

fn aotWidthAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 4;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createString(&.{ 'A', 0x20, 0xff76, 0xff9e });
    roots[2] = try runtime.createArray(&.{numberValue(1)});
    roots[3] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(1) });
    runtime.next_collection = 1;

    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], true, false);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], false, false);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], true, true);
    runtime.next_collection = 1;
    roots[1] = try asciiWidthBuiltin(&runtime, roots[0], false, true);
    runtime.next_collection = 1;
    roots[1] = try kanaMapBuiltin(&runtime, roots[0], true);
    runtime.next_collection = 1;
    roots[1] = try kanaMapBuiltin(&runtime, roots[0], false);
    runtime.next_collection = 1;
    roots[1] = try widthBuiltin(&runtime, roots[0], true);
    runtime.next_collection = 1;
    roots[1] = try widthBuiltin(&runtime, roots[0], false);
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(&runtime, roots[2], true));
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(&runtime, roots[3], true));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, kanaMapBuiltin(&runtime, numberValue(1), false));
}

test "AOT幅変換は入力をGCルート化し全割当失敗を処理する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotWidthAllocationTest, .{});
}

test "AOTクロージャがGC管理の可変セルを共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    active_runtime.?.pushRoots(&frame, &roots, roots.len);
    var initial = numberValue(4);
    lnako_aot_binding_cell_new(&roots[0], &initial);
    lnako_aot_function_new(&roots[1], testAotCapturedIncrement, 0, @ptrCast(&roots[0]), 1);
    try std.testing.expectEqual(@as(usize, 0), active_runtime.?.collect());
    var result: Value = .{};
    lnako_aot_function_call(&result, &roots[1], null, 0);
    try std.testing.expectEqual(@as(f64, 5), valueToNumber(result));
    lnako_aot_function_call(&result, &roots[1], null, 0);
    try std.testing.expectEqual(@as(f64, 6), valueToNumber(result));
    lnako_aot_binding_cell_value(&roots[0]).* = roots[1];
    active_runtime.?.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), active_runtime.?.collect());
}

test "保留例外をGCルートとして保持し一度だけ取り出す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    const message = try active_runtime.?.createString(&.{ '失', '敗' });
    lnako_aot_exception_set(&message);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(usize, 0), active_runtime.?.collect());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    try std.testing.expectEqual(message.payload, taken.payload);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(usize, 1), active_runtime.?.collect());
}

test "AOT未捕捉例外の本文をUTF-16から安全にUTF-8へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    try std.testing.expectError(error.NoPendingException, pendingExceptionMessageUtf8Alloc(&runtime));

    runtime.setFailureText("object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    const null_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(null_message);
    try std.testing.expectEqualStrings("object null is not iterable (cannot read property Symbol(Symbol.iterator))", null_message);
    _ = runtime.takeException();

    runtime.setFailureText("undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    const undefined_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(undefined_message);
    try std.testing.expectEqualStrings("undefined is not iterable (cannot read property Symbol(Symbol.iterator))", undefined_message);
    _ = runtime.takeException();

    const units = [_]u16{ 'a', 0xd83d, 0xde00, 0xd800, 'b', 0xdc00 };
    const surrogate_message = try utf16FailureMessageUtf8Alloc(runtime.allocator, &units);
    defer runtime.allocator.free(surrogate_message);
    try std.testing.expectEqualStrings("a😀�b�", surrogate_message);
}

test "AOT算術失敗を公式文言の保留例外へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var values = [_]Value{ try active_runtime.?.createBigInt("1n"), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &values, values.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_arithmetic(&values[2], &values[0], &values[1], @intFromEnum(Arithmetic.add));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("Cannot mix BigInt and other types, use explicit conversions", utf8);
}

test "AOTのnull添字代入をキー付きの保留例外へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    active_runtime = runtime;
    defer {
        runtime = active_runtime.?;
        active_runtime = null;
    }
    var values = [_]Value{ .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(0), numberValue(2) };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &values, values.len);
    defer lnako_aot_pop_roots(&frame);
    try std.testing.expectEqual(@as(c_int, -1), lnako_aot_index_set(&values[0], &values[1], &values[2]));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("Cannot set properties of null (setting '0')", utf8);
}

test "ルートフレームをLIFOで連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var outer: RootFrame = .{};
    var inner: RootFrame = .{};
    runtime.pushRoots(&outer, null, 0);
    runtime.pushRoots(&inner, null, 0);
    try std.testing.expect(runtime.roots == &inner);
    runtime.popRoots(&inner);
    try std.testing.expect(runtime.roots == &outer);
    runtime.popRoots(&outer);
    try std.testing.expect(runtime.roots == null);
}

test "配列と辞書の子を反復走査し循環参照を回収する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var array = try runtime.createArray(&.{});
    const dictionary = try runtime.createDictionary(&.{});
    try runtime.indexSet(array, numberValue(0), dictionary);
    try runtime.indexSet(dictionary, staticStringValue("array"), array);
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, @ptrCast(&array), 1);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 2), runtime.object_count);
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), runtime.collect());
    try std.testing.expectEqual(@as(usize, 0), runtime.object_count);
}

test "配列の伸長と辞書の挿入位置を保った更新を行う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const array = try runtime.createArray(&.{numberValue(1)});
    try runtime.indexSet(array, numberValue(2), numberValue(3));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), runtime.indexGet(array, numberValue(2)).payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.indexGet(array, numberValue(1)).tag)));
    const dictionary = try runtime.createDictionary(&.{ staticStringValue("x"), numberValue(1), staticStringValue("y"), numberValue(2) });
    try runtime.indexSet(dictionary, staticStringValue("x"), numberValue(7));
    const entries = dictionary.object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 7))), entries[0].value.payload);
}

test "プリミティブへの添字代入を無視し非反復値を空として扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try runtime.indexSet(numberValue(1), numberValue(0), numberValue(2));
    try runtime.indexSet(.{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, numberValue(0), numberValue(2));
    const text = try runtime.createString(&.{ 'a', 'b', 'c' });
    try runtime.indexSet(text, numberValue(0), numberValue(2));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, text.object().?.payload.utf16_string);
    const iterator = try runtime.createIterator(&.{.{ .tag = @intFromEnum(Tag.null_value) }}, false, 0);
    try std.testing.expect(!runtime.iteratorHasNext(iterator));
}

test "AOT分割宣言は非配列を1要素の値として扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const scalar = numberValue(7);
    try std.testing.expectEqual(scalar.payload, runtime.destructureGet(scalar, 0).payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.destructureGet(scalar, 1).tag)));
    const array = try runtime.createArray(&.{ numberValue(2), numberValue(3) });
    try std.testing.expectEqual(numberValue(3).payload, runtime.destructureGet(array, 1).payload);
}

test "UTF-16文字列の添字と反復をコード単位で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createString(&.{ 'A', 0xd83d, 0xde00, 'B' })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    const high = runtime.indexGet(values[0], numberValue(1));
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, high.object().?.payload.utf16_string);
    values[0] = try runtime.createIterator(&.{values[0]}, false, 0);
    var target: Value = .{};
    var key: Value = .{};
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expectEqualSlices(u16, &.{'A'}, target.object().?.payload.utf16_string);
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, target.object().?.payload.utf16_string);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), key.payload);
    runtime.popRoots(&frame);
}

test "AOT BigIntを任意精度で生成して真偽判定する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const large = try runtime.createBigInt("123456789012345678901234567890n");
    const zero = try runtime.createBigInt("0n");
    try std.testing.expect(!large.object().?.payload.bigint.isZero());
    try std.testing.expect(zero.object().?.payload.bigint.isZero());
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_bigint_truthy(&large));
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_bigint_truthy(&zero));
}

test "AOT BigInt算術とNumber混在エラーを処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const left = try runtime.createBigInt("123456789012345678901234567890n");
    const right = try runtime.createBigInt("10n");
    var roots = [_]Value{ left, right, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    roots[2] = try bigIntArithmetic(&runtime, .add, roots[0], roots[1]);
    const text = try roots[2].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("123456789012345678901234567900", text);
    try std.testing.expectError(error.CannotMixBigIntAndNumber, bigIntArithmetic(&runtime, .add, roots[0], numberValue(1)));
    try std.testing.expectError(error.CannotConvertBigIntToNumber, bigIntArithmetic(&runtime, .integer_divide, roots[0], roots[1]));
    runtime.popRoots(&frame);
}

test "AOT動的数値演算は文字列・配列・辞書を公式規則で変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createString(&.{'5'});
    roots[1] = try runtime.createArray(&.{numberValue(5)});
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createDictionary(&.{});

    const string_result = try arithmetic(&runtime, .subtract, roots[0], numberValue(2));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(string_result.payload)));
    const singleton_result = try arithmetic(&runtime, .multiply, roots[1], numberValue(2));
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(singleton_result.payload)));
    const empty_result = try arithmetic(&runtime, .add, roots[2], numberValue(1));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(empty_result.payload))));
    const dictionary_result = try arithmetic(&runtime, .add, roots[3], numberValue(1));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(dictionary_result.payload))));
    const whitespace_result = try arithmetic(&runtime, .power, try runtime.createString(&.{ 0x3000, '2', 0x3000 }), numberValue(3));
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(whitespace_result.payload)));
    const prefix_result = try arithmetic(&runtime, .add, try runtime.createString(&.{ '5', 'x' }), numberValue(2));
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(prefix_result.payload)));
    const floor_result = try arithmetic(&runtime, .integer_divide, numberValue(-5), numberValue(2));
    try std.testing.expectEqual(@as(f64, -3), @as(f64, @bitCast(floor_result.payload)));
}

test "AOT BigInt比較をNumberとの間でも精度を落とさず処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const bigint = try runtime.createBigInt("9007199254740993n");
    try std.testing.expect(try compareValues(&runtime, .greater, bigint, numberValue(9007199254740992.0)));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, try runtime.createBigInt("1n"), numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, try runtime.createBigInt("1n"), numberValue(1))));
}

test "AOT動的比較は文字列変換と参照同一性を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createArray(&.{numberValue(1)}),
        try runtime.createArray(&.{numberValue(1)}),
        try runtime.createString(&.{'1'}),
        try runtime.createDictionary(&.{}),
        try runtime.createArray(&.{staticStringValue("[object Object]")}),
    };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, roots[0], numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, roots[0], numberValue(1))));
    try std.testing.expect(try compareValues(&runtime, .strict_equal, roots[0], roots[0]));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, roots[0], roots[1])));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, staticStringValue("1"), roots[2]));
    try std.testing.expect(!(try compareValues(&runtime, .abstract_equal, roots[3], roots[4])));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, .{ .tag = @intFromEnum(Tag.null_value) }, .{}));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, .{ .tag = @intFromEnum(Tag.null_value) }, .{})));
    try std.testing.expect(try compareValues(&runtime, .greater, staticStringValue("2"), numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .greater, staticStringValue("A"), numberValue(1))));
}

test "AOTのNumberとBigIntシフトを公式規則で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 240))), (try shift(&runtime, .left, numberValue(15), numberValue(4))).payload);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2147483647))), (try shift(&runtime, .right_unsigned, numberValue(-1), numberValue(1))).payload);
    const value = try runtime.createBigInt("8n");
    const negative = try runtime.createBigInt("-2n");
    const shifted = try shift(&runtime, .left, value, negative);
    const text = try shifted.object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2", text);
    try std.testing.expectError(error.UnsignedShiftOfBigInt, shift(&runtime, .right_unsigned, value, try runtime.createBigInt("1n")));
}

test "AOTの値をUTF-16文字列として連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createBigInt("12345678901234567890n"),
        try runtime.createArray(&.{ numberValue(1), numberValue(2) }),
        try runtime.createDictionary(&.{}),
        try runtime.createArray(&.{}),
    };
    try runtime.indexSet(roots[3], numberValue(0), roots[3]);
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const joined = try concat(&runtime, roots[0], staticStringValue("個"));
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, joined.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("12345678901234567890個", utf8);
    const number_joined = try concat(&runtime, numberValue(3), staticStringValue("個"));
    const number_utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, number_joined.object().?.payload.utf16_string);
    defer std.testing.allocator.free(number_utf8);
    try std.testing.expectEqualStrings("3個", number_utf8);
    const array_joined = try concat(&runtime, roots[1], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{ '1', ',', '2', 0x500b }, array_joined.object().?.payload.utf16_string);
    const dictionary_joined = try concat(&runtime, roots[2], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{ '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 0x500b }, dictionary_joined.object().?.payload.utf16_string);
    const cycle_joined = try concat(&runtime, roots[3], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{0x500b}, cycle_joined.object().?.payload.utf16_string);
}

test "AOT増減は未定義・文字列・BigIntをNumberへ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const value = incrementValue(&runtime, .{}, numberValue(1));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), value.payload);
    const bigint = try runtime.createBigInt("5n");
    try std.testing.expectEqual(@as(f64, 7), incrementNumber(&runtime, bigint) + incrementNumber(&runtime, numberValue(2)));
    const string = try runtime.createString(&.{'5'});
    try std.testing.expectEqual(@as(f64, 7), incrementNumber(&runtime, string) + incrementNumber(&runtime, numberValue(2)));
}

test "回数・範囲・配列・辞書の反復状態と元コレクションを追跡する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createArray(&.{ numberValue(3), numberValue(4) })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    values[0] = try runtime.createIterator(&.{values[0]}, false, 0);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 2), runtime.object_count);
    var target: Value = .{};
    var key: Value = .{};
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), runtime.iteratorNext(values[0], null, &target, &key, null).payload);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0))), key.payload);
    try std.testing.expect(runtime.iteratorHasNext(values[0]));
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expect(!runtime.iteratorHasNext(values[0]));
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), runtime.collect());

    var repeat = try runtime.createIterator(&.{numberValue(2)}, false, 0);
    runtime.pushRoots(&frame, @ptrCast(&repeat), 1);
    var repeat_target: Value = .{};
    _ = runtime.iteratorNext(repeat, &repeat_target, null, null, null);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), repeat_target.payload);
    runtime.popRoots(&frame);
    const non_iterable = try runtime.createIterator(&.{try runtime.createBigInt("1n")}, false, 0);
    try std.testing.expect(!runtime.iteratorHasNext(non_iterable));
}

test "AOT配列の集約・入替・連番・要素生成を公式境界で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 14;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{staticStringValue("9")});
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt((try arrayExtremumBuiltin(&runtime, roots[0], true)).tag)));
    roots[3] = try runtime.createBigInt("1n");
    roots[1] = try runtime.createArray(&.{roots[3]});
    try std.testing.expectEqual(roots[3].payload, (try arrayExtremumBuiltin(&runtime, roots[1], false)).payload);
    try std.testing.expectError(error.ArrayExpected, arrayExtremumBuiltin(&runtime, numberValue(1), true));

    roots[0] = try runtime.createArray(&.{ numberValue(-0.0), numberValue(0.0) });
    const maximum = try arrayExtremumBuiltin(&runtime, roots[0], true);
    try std.testing.expect(!isNegativeZero(@bitCast(maximum.payload)));
    roots[1] = try runtime.createArray(&.{ numberValue(0.0), numberValue(-0.0) });
    const minimum = try arrayExtremumBuiltin(&runtime, roots[1], false);
    try std.testing.expect(isNegativeZero(@bitCast(minimum.payload)));
    roots[2] = try runtime.createArray(&.{ numberValue(2), numberValue(std.math.nan(f64)), numberValue(3) });
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast((try arrayExtremumBuiltin(&runtime, roots[2], true)).payload))));
    roots[4] = try runtime.createArray(&.{ numberValue(0), roots[3] });
    try std.testing.expectError(error.CannotConvertBigIntToNumber, arrayExtremumBuiltin(&runtime, roots[4], true));

    roots[5] = try runtime.createArray(&.{ roots[3], staticStringValue("2.5x"), staticStringValue("x") });
    try std.testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast((try arraySumBuiltin(&runtime, roots[5])).payload)));
    roots[6] = try runtime.createArray(&.{ numberValue(0), numberValue(1), numberValue(2) });
    _ = try arraySwapBuiltin(&runtime, roots[6], numberValue(0), numberValue(4));
    const swapped = try arrayItems(roots[6]);
    try std.testing.expectEqual(@as(usize, 5), swapped.items.len);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(swapped.items[0].tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(swapped.items[3].tag)));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(swapped.items[4].payload)));
    try std.testing.expectError(error.ArraySizeLimitExceeded, arraySwapBuiltin(&runtime, roots[6], numberValue(0), numberValue(@floatFromInt(safe_array_element_limit))));

    roots[7] = try arraySequenceBuiltin(&runtime, staticStringValue("2"), numberValue(4));
    const sequence = try arrayItems(roots[7]);
    try std.testing.expectEqual(@as(usize, 3), sequence.items.len);
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(sequence.items[0].tag)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(sequence.items[1].payload)));
    roots[8] = try runtime.createBigInt("2n");
    roots[9] = try runtime.createBigInt("4n");
    roots[10] = try arraySequenceBuiltin(&runtime, roots[8], roots[9]);
    try std.testing.expectEqual(@as(usize, 3), (try arrayItems(roots[10])).items.len);
    try std.testing.expectError(error.ArraySizeLimitExceeded, arraySequenceBuiltin(&runtime, numberValue(0), numberValue(std.math.inf(f64))));
    try std.testing.expectError(error.ArraySizeLimitExceeded, arraySequenceBuiltin(&runtime, numberValue(-std.math.inf(f64)), numberValue(-1)));

    roots[11] = try runtime.createArray(&.{ numberValue(@floatFromInt(safe_array_element_limit)), numberValue(2) });
    try std.testing.expectError(error.ArraySizeLimitExceeded, arrayFillBuiltin(&runtime, numberValue(0), roots[11]));
    roots[11] = try runtime.createArray(&.{});
    roots[12] = try arrayFillBuiltin(&runtime, numberValue(7), roots[11]);
    try std.testing.expectEqual(@as(usize, 0), (try arrayItems(roots[12])).items.len);
    roots[13] = try arrayFillBuiltin(&runtime, .{}, numberValue(2));
    const undefined_fill = try arrayItems(roots[13]);
    try std.testing.expectEqual(@as(usize, 2), undefined_fill.items.len);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(undefined_fill.items[0].tag)));
    try std.testing.expectError(error.ArraySizeLimitExceeded, arrayFillBuiltin(&runtime, numberValue(0), numberValue(std.math.inf(f64))));

    roots[11] = try runtime.createArray(&.{numberValue(1)});
    roots[12] = try arrayFillBuiltin(&runtime, roots[11], numberValue(2));
    const cloned = try arrayItems(roots[12]);
    try runtime.indexSet(cloned.items[0], numberValue(0), numberValue(9));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(runtime.indexGet(cloned.items[1], numberValue(0)).payload)));
}

test "AOT配列ソート系は安定mergeとundefined末尾と同一配列を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createString(&.{0xe000});
    roots[1] = try runtime.createArray(&.{ roots[0], .{}, staticStringValue("😀"), staticStringValue("A") });
    const identity = roots[1].payload;
    try std.testing.expectEqual(identity, (try arrayOrderingBuiltin(&runtime, .array_sort, roots[1])).payload);
    const sorted = (try arrayItems(roots[1])).items;
    const first = try valueUtf16Alloc(&runtime, sorted[0]);
    defer runtime.allocator.free(first);
    try std.testing.expectEqualSlices(u16, &.{'A'}, first);
    const second = try valueUtf16Alloc(&runtime, sorted[1]);
    defer runtime.allocator.free(second);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, second);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(sorted[3].tag)));

    roots[2] = try runtime.createBigInt("2n");
    roots[3] = try runtime.createArray(&.{ staticStringValue("10"), .{}, roots[2], numberValue(std.math.nan(f64)), numberValue(-0.0), numberValue(0.0) });
    try std.testing.expectEqual(roots[3].payload, (try arrayOrderingBuiltin(&runtime, .array_numeric_sort, roots[3])).payload);
    const numeric = (try arrayItems(roots[3])).items;
    try std.testing.expect(isNegativeZero(valueToNumber(numeric[0])));
    try std.testing.expect(!isNegativeZero(valueToNumber(numeric[1])));
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(numeric[2].tag)));
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(numeric[3].tag)));
    try std.testing.expect(std.math.isNan(valueToNumber(numeric[4])));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(numeric[5].tag)));
    _ = try arrayOrderingBuiltin(&runtime, .array_numeric_convert, roots[3]);
    try std.testing.expectEqual(Tag.number, @as(Tag, @enumFromInt((try arrayItems(roots[3])).items[2].tag)));
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[3])).items[5])));
    try std.testing.expectEqual(roots[3].payload, (try arrayOrderingBuiltin(&runtime, .array_reverse, roots[3])).payload);
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[3])).items[0])));
}

test "AOT表検索系は行プロパティとraw開始値を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ staticStringValue("alice"), numberValue(10) });
    roots[1] = try runtime.createArray(&.{ staticStringValue("bob"), numberValue(20) });
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    roots[3] = try runtime.createDictionary(&.{});
    roots[4] = try runtime.createString(&.{ 'a', 0xd83d, 0xde00 });
    roots[5] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    roots[6] = try runtime.createString(&.{'3'});
    try roots[3].object().?.payload.dictionary.append(runtime.allocator, .{ .key = roots[5], .value = roots[6] });
    roots[9] = try runtime.createArray(&.{});
    roots[7] = try runtime.createArray(&.{ roots[9], roots[4], roots[3] });
    const columns = try tableBuiltin(&runtime, .table_column_count, roots[7..8]);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(columns.payload)));

    const picked = try tableBuiltin(&runtime, .table_pickup, &.{ roots[2], numberValue(0), staticStringValue("ali") });
    try std.testing.expectEqual(@as(usize, 1), picked.object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[0].payload, picked.object().?.payload.array.items[0].payload);
    const exact = try tableBuiltin(&runtime, .table_exact_pickup, &.{ roots[2], numberValue(0), staticStringValue("alice") });
    try std.testing.expectEqual(@as(usize, 1), exact.object().?.payload.array.items.len);
    const found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), numberValue(1), staticStringValue("bob") });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(found.payload)));
    const not_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), .{}, staticStringValue("alice") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(not_found.payload)));
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), numberValue(-1), staticStringValue("alice") }));
    roots[8] = try runtime.createBigInt("1n");
    const bigint_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), roots[8], staticStringValue("bob") });
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_found.tag)));
    try std.testing.expectEqual(@as(i64, 1), bigint_found.object().?.payload.bigint.toI64());
    const string_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), staticStringValue("1"), staticStringValue("bob") });
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(string_found.tag)));
    const incremented_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), staticStringValue("0"), staticStringValue("bob") });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(incremented_found.payload)));
    const object_start = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), roots[3], staticStringValue("alice") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(object_start.payload)));
    roots[10] = try runtime.createArray(&.{.{}});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_column, &.{ roots[10], numberValue(0) }));
    roots[11] = try runtime.createArray(&.{.{ .tag = @intFromEnum(Tag.null_value), .payload = 0 }});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_column, &.{ roots[11], numberValue(0) }));
    roots[12] = try runtime.createDictionary(&.{ staticStringValue("length"), staticStringValue("7") });
    roots[13] = try runtime.createArray(&.{roots[12]});
    const text_columns = try tableBuiltin(&runtime, .table_column_count, roots[13..14]);
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(text_columns.tag)));
    roots[14] = try runtime.createBigInt("2n");
    roots[15] = try runtime.createDictionary(&.{ staticStringValue("length"), roots[14] });
    roots[16] = try runtime.createArray(&.{roots[15]});
    const bigint_columns = try tableBuiltin(&runtime, .table_column_count, roots[16..17]);
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_columns.tag)));
    try std.testing.expectEqual(@as(i64, 2), bigint_columns.object().?.payload.bigint.toI64());
    roots[17] = try runtime.createFunction(testAotFunction, 2, &.{});
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast((try tableRowProperty(&runtime, roots[17], staticStringValue("length"))).payload)));
}

test "AOT表正規表現系はraw RegExpと浅いコピーを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 16;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ staticStringValue("alice"), staticStringValue("payload") });
    roots[1] = try runtime.createArray(&.{staticStringValue("bob")});
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    const raw = staticStringValue("^ali");
    const found = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], numberValue(0), numberValue(0), raw });
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(found.payload)));
    const slash = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], numberValue(0), numberValue(0), staticStringValue("/^ali/i") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(slash.payload)));

    roots[3] = try runtime.createBigInt("1n");
    const bigint_found = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], roots[3], numberValue(0), staticStringValue("bob") });
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_found.tag)));
    try std.testing.expectEqual(@as(i64, 1), bigint_found.object().?.payload.bigint.toI64());

    roots[4] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[2], numberValue(0), raw });
    try std.testing.expect(roots[4].object() != roots[2].object());
    try std.testing.expect(roots[4].object().?.payload.array.items[0].object() != roots[0].object());
    try std.testing.expectEqual(roots[0].object().?.payload.array.items[1].payload, roots[4].object().?.payload.array.items[0].object().?.payload.array.items[1].payload);

    roots[7] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[2], numberValue(0), .{} });
    try std.testing.expectEqual(@as(usize, 2), roots[7].object().?.payload.array.items.len);
    roots[8] = try runtime.createArray(&.{staticStringValue("alice")});
    roots[9] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[8], numberValue(0), staticStringValue("^a") });
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(roots[9].object().?.payload.array.items[0].tag)));

    roots[5] = try runtime.createArray(&.{.{ .tag = @intFromEnum(Tag.null_value), .payload = 0 }});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_search, &.{ roots[5], numberValue(0), numberValue(0), raw }));
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[5], numberValue(0), raw }));
    roots[6] = try runtime.createArray(&.{});
    try std.testing.expectError(error.UnclosedCharacterClass, tableBuiltin(&runtime, .table_regexp_search, &.{ roots[6], numberValue(0), numberValue(0), staticStringValue("[") }));
    try std.testing.expectError(error.UnclosedCharacterClass, tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[6], numberValue(0), staticStringValue("[") }));
}

test "AOT表変換系は欠損列・負位置・JS加算を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 18;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(1), numberValue(2), numberValue(3) });
    roots[1] = try runtime.createArray(&.{ numberValue(4), numberValue(5), numberValue(6) });
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    roots[3] = try tableBuiltin(&runtime, .table_transpose, &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[3])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast((try arrayItems(roots[3])).items[0].object().?.payload.array.items[1].payload)));
    roots[4] = try tableBuiltin(&runtime, .table_rotate, &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast((try arrayItems(roots[4])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[4])).items[0].object().?.payload.array.items[1].payload)));

    roots[5] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(1) });
    roots[6] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(2) });
    roots[7] = try runtime.createArray(&.{ staticStringValue("b"), numberValue(3) });
    roots[8] = try runtime.createArray(&.{ roots[5], roots[6], roots[7] });
    roots[9] = try tableBuiltin(&runtime, .table_unique, &.{ roots[8], numberValue(0) });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[9])).items.len);
    try std.testing.expectEqual(roots[5].payload, (try arrayItems(roots[9])).items[0].payload);

    roots[10] = try tableBuiltin(&runtime, .table_insert_column, &.{ roots[2], numberValue(-1), roots[0] });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[10])).items[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[10])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast((try arrayItems(roots[10])).items[0].object().?.payload.array.items[1].payload)));
    roots[11] = try tableBuiltin(&runtime, .table_delete_column, &.{ roots[2], numberValue(-1) });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[11])).items[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast((try arrayItems(roots[11])).items[0].object().?.payload.array.items[1].payload)));

    roots[12] = try tableBuiltin(&runtime, .table_column_sum, &.{ roots[2], numberValue(1) });
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(roots[12].payload)));
    roots[13] = try runtime.createArray(&.{ staticStringValue("x"), numberValue(1) });
    roots[14] = try runtime.createArray(&.{ staticStringValue("y"), numberValue(2) });
    roots[15] = try runtime.createArray(&.{ roots[13], roots[14] });
    roots[16] = try tableBuiltin(&runtime, .table_column_sum, &.{ roots[15], numberValue(0) });
    const sum_text = try valueUtf16Alloc(&runtime, roots[16]);
    defer runtime.allocator.free(sum_text);
    try std.testing.expectEqualSlices(u16, &.{ '0', 'x', 'y' }, sum_text);
}

test "AOT一般正規表現命令は共有エンジンと抽出副作用を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const all = try regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("aa,bb,cc"), staticStringValue("[a-z]+") });
    roots[0] = all.value;
    roots[1] = all.captures.?;
    try std.testing.expectEqual(@as(usize, 3), roots[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), roots[1].object().?.payload.array.items.len);

    const one = try regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("12-34"), staticStringValue("/([0-9]+)/") });
    roots[2] = one.value;
    roots[3] = one.captures.?;
    try std.testing.expectEqualSlices(u16, &.{ '1', '2' }, roots[2].object().?.payload.utf16_string);
    try std.testing.expectEqual(@as(usize, 1), roots[3].object().?.payload.array.items.len);

    const extracted = try regexpBuiltin(&runtime, .regexp_extract, &.{ staticStringValue("a1 b2"), staticStringValue("/(?<letter>[a-z])([0-9])/g") });
    roots[4] = extracted.value;
    roots[5] = extracted.captures.?;
    try std.testing.expectEqual(@as(usize, 2), roots[4].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), roots[5].object().?.payload.array.items.len);
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[5].object().?.payload.array.items[0].tag)));

    const replaced = try regexpBuiltin(&runtime, .regexp_replace, &.{ staticStringValue("aa,bb"), staticStringValue("/[a-z]+/g"), staticStringValue("<$&>") });
    roots[6] = replaced.value;
    const replaced_units = try valueUtf16Alloc(&runtime, roots[6]);
    defer runtime.allocator.free(replaced_units);
    try std.testing.expectEqualSlices(u16, &.{ '<', 'a', 'a', '>', ',', '<', 'b', 'b', '>' }, replaced_units);

    const split = try regexpBuiltin(&runtime, .regexp_split, &.{ staticStringValue("a,b"), staticStringValue("/(,)/") });
    roots[7] = split.value;
    try std.testing.expectEqual(@as(usize, 3), roots[7].object().?.payload.array.items.len);
}

test "AOT JSONエンコードはcompact prettyとECMAScript境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try jsonEncodeBuiltin(&runtime, .{}, false)).tag)));
    roots[0] = try runtime.createFunction(testAotFunction, 1, &.{});
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try jsonEncodeBuiltin(&runtime, roots[0], false)).tag)));

    roots[1] = try runtime.createArray(&.{ .{}, roots[0], .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(std.math.nan(f64)) });
    try expectJsonAotString(&runtime, roots[1], false, "[null,null,null,null]");

    roots[2] = try runtime.createDictionary(&.{
        staticStringValue("undefined"), .{},
        staticStringValue("function"),  roots[0],
        staticStringValue("present"),   numberValue(1),
    });
    try expectJsonAotString(&runtime, roots[2], false, "{\"present\":1}");
    try expectJsonAotString(&runtime, roots[2], true, "{\n  \"present\": 1\n}");

    roots[3] = try runtime.createArray(&.{numberValue(7)});
    roots[4] = try runtime.createArray(&.{ roots[3], roots[3] });
    try expectJsonAotString(&runtime, roots[4], false, "[[7],[7]]");

    roots[5] = try runtime.createDictionary(&.{
        staticStringValue("2"),          staticStringValue("b"),
        staticStringValue("1"),          staticStringValue("a"),
        staticStringValue("x"),          staticStringValue("c"),
        staticStringValue("01"),         staticStringValue("d"),
        staticStringValue("4294967294"), staticStringValue("f"),
        staticStringValue("0"),          staticStringValue("z"),
    });
    try expectJsonAotString(&runtime, roots[5], false, "{\"0\":\"z\",\"1\":\"a\",\"2\":\"b\",\"4294967294\":\"f\",\"x\":\"c\",\"01\":\"d\"}");
    try expectJsonAotString(&runtime, roots[5], true, "{\n  \"0\": \"z\",\n  \"1\": \"a\",\n  \"2\": \"b\",\n  \"4294967294\": \"f\",\n  \"x\": \"c\",\n  \"01\": \"d\"\n}");
    roots[10] = try runtime.createDictionary(&.{ numberValue(1), staticStringValue("number"), staticStringValue("1"), staticStringValue("string"), staticStringValue("2"), staticStringValue("two") });
    try expectJsonAotString(&runtime, roots[10], false, "{\"1\":\"string\",\"2\":\"two\"}");

    roots[6] = try runtime.createString(&.{0xd800});
    try expectJsonAotString(&runtime, roots[6], false, "\"\\ud800\"");
    roots[7] = try runtime.createArray(&.{ numberValue(-0.0), numberValue(1e21), numberValue(1e-6), numberValue(1e-7) });
    try expectJsonAotString(&runtime, roots[7], false, "[0,1e+21,0.000001,1e-7]");

    roots[8] = try runtime.createBigInt("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, jsonEncodeBuiltin(&runtime, roots[8], false));
    roots[9] = try runtime.createArray(&.{});
    try roots[9].object().?.payload.array.append(runtime.allocator, roots[9]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[9], false));
    const message = runtime.takeException();
    const message_units = try valueUtf16Alloc(&runtime, message);
    defer runtime.allocator.free(message_units);
    const expected_message = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Array'\n    --- index 0 closes the circle");
    defer runtime.allocator.free(expected_message);
    try std.testing.expectEqualSlices(u16, expected_message, message_units);

    roots[11] = try runtime.createDictionary(&.{});
    roots[12] = try runtime.createDictionary(&.{});
    try runtime.indexSet(roots[11], staticStringValue("a"), roots[12]);
    try runtime.indexSet(roots[12], staticStringValue("self"), roots[12]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[11], false));
    const nested_message = runtime.takeException();
    const nested_units = try valueUtf16Alloc(&runtime, nested_message);
    defer runtime.allocator.free(nested_units);
    const expected_nested = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Object'\n    --- property 'self' closes the circle");
    defer runtime.allocator.free(expected_nested);
    try std.testing.expectEqualSlices(u16, expected_nested, nested_units);

    roots[13] = try runtime.createDictionary(&.{});
    roots[14] = try runtime.createString(&.{0xd800});
    try runtime.indexSet(roots[13], roots[14], roots[13]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[13], false));
    const surrogate_message = runtime.takeException();
    const surrogate_units = try valueUtf16Alloc(&runtime, surrogate_message);
    defer runtime.allocator.free(surrogate_units);
    const expected_surrogate = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Object'\n    --- property '�' closes the circle");
    defer runtime.allocator.free(expected_surrogate);
    try std.testing.expectEqualSlices(u16, expected_surrogate, surrogate_units);

    var dictionary_values: [160]Value = undefined;
    for (0..80) |index| {
        dictionary_values[index * 2] = numberValue(@floatFromInt(index));
        dictionary_values[index * 2 + 1] = numberValue(@floatFromInt(index));
    }
    roots[15] = try runtime.createDictionary(&dictionary_values);
    var expected_gc: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer expected_gc.deinit();
    try expected_gc.writer.writeByte('{');
    for (0..80) |index| {
        if (index > 0) try expected_gc.writer.writeByte(',');
        try expected_gc.writer.print("\"{d}\":{d}", .{ index, index });
    }
    try expected_gc.writer.writeByte('}');
    // Force collections while normalized property-key objects are being built.
    // The source dictionary remains in the caller root frame, and keys already
    // produced by the serializer remain in its temporary root frame.
    runtime.next_collection = runtime.object_count;
    try expectJsonAotString(&runtime, roots[15], false, expected_gc.written());
}

test "AOT辞書・配列のキー命令は順序とBigIntキーを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createDictionary(&.{
            staticStringValue("b"), numberValue(1),
            staticStringValue("2"), numberValue(2),
            staticStringValue("1"), numberValue(3),
        }),
        try runtime.createArray(&.{ numberValue(10), numberValue(20) }),
        try runtime.createBigInt("1n"),
        .{},
        .{},
    };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[0]);
    try std.testing.expectEqual(@as(usize, 3), roots[3].object().?.payload.array.items.len);
    const dictionary_keys = roots[3].object().?.payload.array.items;
    try std.testing.expectEqualSlices(u16, &.{'1'}, dictionary_keys[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'2'}, dictionary_keys[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'b'}, dictionary_keys[2].object().?.payload.utf16_string);
    roots[4] = try dictionaryKeysBuiltin(&runtime, roots[1]);
    try std.testing.expectEqualSlices(u16, &.{'0'}, roots[4].object().?.payload.array.items[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'1'}, roots[4].object().?.payload.array.items[1].object().?.payload.utf16_string);
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], roots[2]));
    try std.testing.expectError(error.ArrayLengthDelete, dictionaryRemoveBuiltin(&runtime, roots[1], staticStringValue("length")));
    try runtime.indexSet(roots[0], roots[2], numberValue(9));
    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[0]);
    try std.testing.expectEqual(@as(usize, 3), roots[3].object().?.payload.array.items.len);
}

fn aotDictionaryPropertyKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{ try runtime.createBigInt("1n"), .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = runtime.object_count;
    roots[1] = try runtime.createDictionary(&.{ roots[0], numberValue(1), staticStringValue("1"), numberValue(2), numberValue(2), numberValue(3), staticStringValue("2"), numberValue(4) });
    const entries = roots[1].object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(entries[0].value));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(entries[1].value));
    roots[2] = try dictionaryKeysBuiltin(&runtime, roots[1]);
    try std.testing.expectEqualSlices(u16, &.{'1'}, roots[2].object().?.payload.array.items[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'2'}, roots[2].object().?.payload.array.items[1].object().?.payload.utf16_string);
}

test "AOT辞書リテラルは非文字列キーをproperty keyへ正規化する" {
    try aotDictionaryPropertyKeyAllocationTest(std.testing.allocator);
}

fn aotDictionaryBigIntPropertyKeyAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime{ .allocator = allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createBigInt("1n");
    roots[1] = try runtime.createBigInt("2n");
    runtime.next_collection = runtime.object_count;
    roots[2] = try runtime.createDictionary(&.{ roots[0], numberValue(1), staticStringValue("1"), numberValue(2), roots[1], numberValue(3), staticStringValue("2"), numberValue(4) });
    const entries = roots[2].object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(entries[0].value));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(entries[1].value));
}

test "AOT辞書リテラルのproperty key正規化は割当失敗を安全に処理する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotDictionaryBigIntPropertyKeyAllocationTest, .{});
}

test "AOT辞書キー存在の型エラーは動的な公式文言を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const invalid_key = try runtime.createString(&.{ 'x', 0xd800 });
    try std.testing.expectError(error.DictionaryHasReceiver, dictionaryHasBuiltin(&runtime, .{ .tag = @intFromEnum(Tag.null_value) }, invalid_key));
    const message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(message);
    try std.testing.expectEqualStrings("Cannot use 'in' operator to search for 'x�' in null", message);
}

fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}
