const std = @import("std");
const aot_abi = @import("aot_abi.zig");
const aot_builtin = @import("aot_builtin.zig");
const BigInt = @import("bigint.zig").BigInt;
const error_message = @import("error_message.zig");
const unicode_case = @import("unicode_case");
const number_mod = @import("number.zig");
const string_mod = @import("string.zig");
const system_constant = @import("system_constant.zig");

pub const Tag = aot_abi.Tag;

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
    system_context: Value = .{},

    fn deinit(self: *Runtime) void {
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
        try self.beforeAllocation();
        var entries: std.ArrayList(DictionaryEntry) = .empty;
        errdefer entries.deinit(self.allocator);
        var index: usize = 0;
        while (index + 1 < values.len) : (index += 2) {
            try self.setDictionary(&entries, values[index], values[index + 1]);
        }
        return self.createObject(.{ .dictionary = entries }, .dictionary);
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
        var frame: RootFrame = .{};
        self.pushRoots(&frame, if (captures.len > 0) @constCast(captures.ptr) else null, captures.len);
        defer self.popRoots(&frame);
        try self.beforeAllocation();
        const owned_captures = try self.allocator.dupe(Value, captures);
        errdefer self.allocator.free(owned_captures);
        return self.createObject(.{ .function = .{ .callback = callback, .arity = arity, .captures = owned_captures } }, .function);
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
    }

    fn setFailure(self: *Runtime, failure: anyerror) void {
        self.setFailureText(error_message.forFailure(failure));
    }

    fn setFailureText(self: *Runtime, text: []const u8) void {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |allocation_failure| runtimeFailure(allocation_failure);
        defer self.allocator.free(units);
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
            .function => |function| self.allocator.free(function.captures),
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
            .dictionary => |*entries| try self.setDictionary(entries, key, value),
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

fn valueUtf16Alloc(runtime: *Runtime, value: Value) anyerror![]u16 {
    if (value.tag == @intFromEnum(Tag.utf16_string)) return runtime.allocator.dupe(u16, value.object().?.payload.utf16_string);
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
        .function => try runtime.allocator.dupe(u8, "function () { [native code] }"),
        .binding_cell => unreachable,
    };
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
        .function => staticStringValue("function () { [native code] }"),
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
    if (active_runtime == null) active_runtime = .{ .allocator = std.heap.c_allocator };
    return 0;
}

pub export fn lnako_aot_runtime_deinit() callconv(.c) void {
    if (active_runtime) |*runtime| runtime.deinit();
    active_runtime = null;
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
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
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
}

pub export fn lnako_aot_builtin_call(out: *Value, arguments: ?[*]const Value, len: usize, opcode: u16) callconv(.c) void {
    out.* = .{};
    const runtime = if (active_runtime) |*active| active else return;
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        runtime.setFailure(error.UnknownCommand);
        return;
    };
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    if (len == 0 and command != .empty_array and command != .empty_dictionary and command != .sum_parsed and command != .sequential_add and command != .concat_join) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const value = if (len > 0) arguments.?[0] else Value{};
    switch (command) {
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
                runtime.setFailure(failure);
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
        .array_insert, .array_insert_many, .array_cut, .array_take, .array_pop, .array_push, .array_clone, .array_range_copy, .reference, .array_add => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = arrayMutationBuiltin(runtime, command, actual) catch |failure| {
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

fn codePointFindBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    if (source_units.len == 0) return 0;
    var codepoint_index: usize = 0;
    var unit_index: usize = 0;
    while (unit_index < source_units.len) {
        if (needle_units.len <= source_units.len - unit_index and std.mem.eql(u16, source_units[unit_index..][0..needle_units.len], needle_units)) return codepoint_index + 1;
        unit_index += codePointLength(source_units, unit_index);
        codepoint_index += 1;
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
        else => error.UnknownCommand,
    };
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
    const end_number = try valueToNumberRuntime(runtime, last);
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
    const last_number = try valueToNumberRuntime(runtime, last) + 1;
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
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayRangeCopyReceiver;
    const items = try arrayItems(source);
    if (index.tag == @intFromEnum(Tag.number)) {
        const position = directIndex(@bitCast(index.payload)) orelse return .{};
        if (position >= items.items.len) return .{};
        const item = items.items[position];
        return switch (@as(Tag, @enumFromInt(item.tag))) {
            .array, .dictionary, .iterator, .null_value => deepCloneBuiltin(runtime, item),
            else => item,
        };
    }
    const range = (try sliceRange(runtime, index, items.items.len)) orelse return .{};
    if (range.end <= range.start) return runtime.createArray(&.{});
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{result};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const values = items.items[range.start..range.end];
    try roots[0].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    for (values) |item| {
        var cloned = try deepCloneValue(runtime, item, &state);
        if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
        try roots[0].object().?.payload.array.append(runtime.allocator, cloned);
    }
    return roots[0];
}

fn referenceBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    if (isString(source)) {
        const units = try valueUtf16Alloc(runtime, source);
        defer runtime.allocator.free(units);
        if (index.tag == @intFromEnum(Tag.number)) {
            const position = charAtIndex(@bitCast(index.payload), units.len) orelse return runtime.createString(&.{});
            return runtime.createString(units[position .. position + 1]);
        }
        const range = (try substringRange(runtime, index, units.len)) orelse return error.InvalidStringRange;
        const start = @min(range.start, units.len);
        const end = @min(range.end, units.len);
        return runtime.createString(units[start..end]);
    }
    if (source.tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(source);
        if (index.tag == @intFromEnum(Tag.number)) {
            const position = directIndex(@bitCast(index.payload)) orelse return .{};
            return if (position < items.items.len) items.items[position] else .{};
        }
        const range = (try sliceRange(runtime, index, items.items.len)) orelse return .{};
        const start = @min(range.start, items.items.len);
        const end = @min(@max(range.end, start), items.items.len);
        return runtime.createArray(items.items[start..end]);
    }
    if (source.tag == @intFromEnum(Tag.dictionary)) {
        const key = try valueUtf16Alloc(runtime, index);
        defer runtime.allocator.free(key);
        return dictionaryProperty(source, key);
    }
    return error.IndexableValueExpected;
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
    errdefer runtime.allocator.free(output);
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
    const source = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(source);
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
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, u16) callconv(.c) void, @TypeOf(&lnako_aot_builtin_call));
    try std.testing.expectEqual(*const fn (*const Value, bool) callconv(.c) void, @TypeOf(&lnako_aot_print_number));
    try std.testing.expectEqual(*const fn (*const Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_set));
    try std.testing.expectEqual(*const fn () callconv(.c) c_int, @TypeOf(&lnako_aot_exception_pending));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_take));
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
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
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

fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}
