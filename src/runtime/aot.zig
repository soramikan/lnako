const std = @import("std");
const BigInt = @import("bigint.zig").BigInt;
const error_message = @import("error_message.zig");
const string_mod = @import("string.zig");

pub const Tag = enum(u8) {
    undefined = 0,
    null_value = 1,
    boolean = 2,
    number = 3,
    static_utf8_string = 4,
    utf16_string = 5,
    array = 6,
    dictionary = 7,
    iterator = 8,
    bigint = 9,
    function = 10,
    binding_cell = 11,
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

const FunctionCallback = *const fn (*anyopaque, ?[*]const Value, usize) callconv(.c) Value;
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
            else => return error.NotIterable,
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
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, error_message.forFailure(failure)) catch |allocation_failure| runtimeFailure(allocation_failure);
        defer self.allocator.free(units);
        self.setException(self.createString(units) catch |allocation_failure| runtimeFailure(allocation_failure));
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
        const object = container.object() orelse return error.InvalidContainer;
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
            else => return error.InvalidContainer,
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
    if (std.math.isNan(number)) return allocator.dupe(u8, "NaN");
    if (number == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (number == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    if (number == 0) return allocator.dupe(u8, "0");
    return std.fmt.allocPrint(allocator, "{d}", .{number});
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
    const result = switch (operator) {
        .add => left_number + right_number,
        .subtract => left_number - right_number,
        .multiply => left_number * right_number,
        .divide => left_number / right_number,
        .remainder => @rem(left_number, right_number),
        .power => std.math.pow(f64, left_number, right_number),
        .integer_divide => @floor(left_number / right_number),
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
    const left_is_bigint = left.tag == @intFromEnum(Tag.bigint);
    const right_is_bigint = right.tag == @intFromEnum(Tag.bigint);
    if (left_is_bigint or right_is_bigint) {
        if (!left_is_bigint or !right_is_bigint) return error.CannotMixBigIntAndNumber;
        if (operator == .right_unsigned) return error.UnsignedShiftOfBigInt;
        const left_bigint = left.object().?.payload.bigint;
        const amount = right.object().?.payload.bigint.toI64() catch return error.BigIntShiftTooLarge;
        const magnitude = if (amount < 0) @as(u64, @intCast(-(amount + 1))) + 1 else @as(u64, @intCast(amount));
        const shift_amount: usize = std.math.cast(usize, magnitude) orelse return error.BigIntShiftTooLarge;
        const shift_left = (operator == .left) != (amount < 0);
        const result = if (shift_left)
            try left_bigint.shiftLeft(runtime.allocator, shift_amount)
        else
            try left_bigint.shiftRight(runtime.allocator, shift_amount);
        return runtime.ownBigInt(result);
    }
    const amount: u5 = @truncate(toUint32(valueToNumber(right)) & 31);
    const shifted: f64 = switch (operator) {
        .left => @floatFromInt(toInt32(valueToNumber(left)) << amount),
        .right => @floatFromInt(toInt32(valueToNumber(left)) >> amount),
        .right_unsigned => @floatFromInt(toUint32(valueToNumber(left)) >> amount),
    };
    return numberValue(shifted);
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
    if (callable.tag != @intFromEnum(Tag.function)) runtimeFailure(error.NotCallable);
    const object = callable.object() orelse runtimeFailure(error.NotCallable);
    if (object.payload != .function) runtimeFailure(error.NotCallable);
    const function = object.payload.function;
    if (function.arity != len) runtimeFailure(error.InvalidArgumentCount);
    if (arguments == null and len != 0) runtimeFailure(error.InvalidArguments);
    out.* = function.callback(@ptrCast(object), arguments, len);
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
    try std.testing.expectEqual(*const fn (*const Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_set));
    try std.testing.expectEqual(*const fn () callconv(.c) c_int, @TypeOf(&lnako_aot_exception_pending));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_take));
}

fn testAotFunction(_: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) Value {
    if (arguments == null or len != 1) return .{};
    return arguments.?[0];
}

fn testAotCapturedIncrement(context: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) Value {
    const function: *Object = @ptrCast(@alignCast(context));
    const cell = function.payload.function.captures[0].object().?;
    const next = numberValue(valueToNumber(cell.payload.binding_cell) + 1);
    cell.payload.binding_cell = next;
    return next;
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
    try std.testing.expectError(error.NotIterable, runtime.createIterator(&.{try runtime.createBigInt("1n")}, false, 0));
}

fn numberValue(number: f64) Value {
    return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
}

fn staticStringValue(comptime text: [:0]const u8) Value {
    return .{ .tag = @intFromEnum(Tag.static_utf8_string), .payload = @intFromPtr(text.ptr) };
}
